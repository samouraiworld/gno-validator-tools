#!/usr/bin/env bash
# Orchestrate a full auto-heal restore of <node-service>: incident backup,
# pick the latest local snapshot, restore, restart (tmkms-aware ordering for
# the validator), verify catch-up. Invoked by check-stuck.sh once a node has
# been confirmed stuck for STUCK_THRESHOLD consecutive checks.
#
# Devnet-only: snapshots are read from ./snapshots/ (produced by snapshot.sh)
# — no Scaleway pull here, that's the prod (roles/autoheal) variant's job.
#
# Usage: ./autoheal.sh <node-service>
set -euo pipefail

cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-gnoland-test}"

NODE="${1:-}"
if [ -z "$NODE" ]; then
  echo "Usage: $0 <node-service>" >&2
  exit 2
fi

LOCK_DIR=".autoheal"
LOCK_FILE="$LOCK_DIR/${NODE}.lock"
COOLDOWN="${AUTOHEAL_COOLDOWN:-1800}"                  # seconds, default 30 min
CATCHUP_TIMEOUT="${AUTOHEAL_CATCHUP_TIMEOUT:-1200}"    # seconds, default 20 min
INCIDENT_DIR="incidents"
SNAP_DIR="snapshots"
DATA_DIR="$NODE/gnoland-data"

mkdir -p "$LOCK_DIR" "$INCIDENT_DIR"

compose() { docker compose --profile phase2 --profile snapshot "$@"; }

alert() {
  local event="$1" message="$2"
  echo "[ALERT] $event: $message"
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -s --max-time 5 -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$NODE" --arg e "$event" --arg m "$message" \
            '{node:$n, event:$e, message:$m}')" >/dev/null 2>&1 || true
  fi
}

# --- Anti-flapping: refuse to run again inside the cooldown window ----------
if [ -f "$LOCK_FILE" ]; then
  LOCK_TS="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
  ELAPSED=$(( $(date -u +%s) - LOCK_TS ))
  if [ "$ELAPSED" -lt "$COOLDOWN" ]; then
    alert "cooldown-blocked" "$NODE: a restore already ran ${ELAPSED}s ago (cooldown ${COOLDOWN}s) — refusing to run again automatically. Needs human investigation."
    exit 1
  fi
fi
date -u +%s > "$LOCK_FILE"

alert "restore-triggered" "$NODE: stuck detected, starting auto-heal restore."

# --- 1. Incident backup (full gnoland-data, secrets included, forensic only) ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
INCIDENT_ARCHIVE="$INCIDENT_DIR/${NODE}-${TS}.tar.zst"
echo "==> Incident backup: $DATA_DIR -> $INCIDENT_ARCHIVE"
if ! tar -C "$NODE" -c gnoland-data | zstd -q -T0 -o "$INCIDENT_ARCHIVE"; then
  alert "restore-failed" "$NODE: incident backup failed — aborting before touching data."
  exit 1
fi

# --- 2. Pick the latest local snapshot (highest block height) ---------------
# List bare filenames from inside SNAP_DIR (not ls "$SNAP_DIR"/*.tar.zst, which
# would need sort -t twice — once to skip the dir prefix, once for the
# height/timestamp separator — and GNU sort rejects more than one -t).
LATEST=""
if [ -d "$SNAP_DIR" ]; then
  LATEST="$(cd "$SNAP_DIR" && ls -1 *.tar.zst 2>/dev/null | sort -t- -k1,1n | tail -n1 || true)"
fi
if [ -n "$LATEST" ]; then
  LATEST="$SNAP_DIR/$LATEST"
fi
if [ -z "$LATEST" ]; then
  alert "restore-failed" "$NODE: no snapshot available in $SNAP_DIR — aborting, node left untouched."
  exit 1
fi
echo "==> Using snapshot: $LATEST"

# --- 3. Validator-only local safety check (anti-double-sign) ----------------
if [ "$NODE" = "validator" ]; then
  echo "==> Stopping validator + tmkms"
  compose stop validator tmkms >/dev/null 2>&1 || true
  for svc in validator tmkms; do
    # -a is required: a plain 'compose ps' only lists RUNNING containers, so a
    # cleanly-stopped (exited) container would otherwise report empty state,
    # not "exited" — making this check fail-closed on every clean stop.
    STATE="$(compose ps -a --format '{{.State}}' "$svc" 2>/dev/null || echo missing)"
    if [ "$STATE" != "exited" ] && [ "$STATE" != "missing" ]; then
      alert "restore-aborted" "$NODE: $svc did not stop cleanly (state=$STATE) — refusing to wipe data, possible live signer. Manual intervention required."
      exit 1
    fi
  done
fi

# --- 4. Restore (delegates to restore.sh --yes; it also restarts $NODE) -----
echo "==> Restoring $NODE from $LATEST"
if ! ./restore.sh "$NODE" "$LATEST" --yes; then
  alert "restore-failed" "$NODE: restore.sh failed — see logs."
  exit 1
fi

# --- 5. Validator only: start tmkms too (restore.sh only starts $NODE) ------
if [ "$NODE" = "validator" ]; then
  echo "==> restore.sh already started $NODE; starting tmkms now"
  sleep 5
  if ! compose start tmkms >/dev/null; then
    alert "restore-failed" "$NODE: tmkms failed to start after restore — validator is up WITHOUT a signer attached. Manual intervention required."
    exit 1
  fi
fi

# --- 6. Verify catch-up -------------------------------------------------------
case "$NODE" in
  validator)   RPC="http://localhost:26658" ;;
  validator2)  RPC="http://localhost:26659" ;;
  validator3)  RPC="http://localhost:26660" ;;
  validator4)  RPC="http://localhost:26661" ;;
  snapshotter) RPC="http://localhost:26662" ;;
  *) alert "restore-failed" "$NODE: unknown node, cannot verify catch-up."; exit 1 ;;
esac

echo "==> Waiting for catch-up (timeout ${CATCHUP_TIMEOUT}s)"
ELAPSED=0
while [ "$ELAPSED" -lt "$CATCHUP_TIMEOUT" ]; do
  CATCHING_UP="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null | jq -r '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"
  if [ "$CATCHING_UP" = "false" ]; then
    alert "restore-succeeded" "$NODE: restored from $LATEST and caught up."
    rm -f "$LOCK_DIR/${NODE}.state"
    exit 0
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

alert "restore-timeout" "$NODE: restored from $LATEST but did not catch up within ${CATCHUP_TIMEOUT}s — needs investigation."
exit 1
