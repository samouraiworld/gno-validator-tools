#!/usr/bin/env bash
# Capture a chain snapshot from the dedicated non-signing `snapshotter` node.
#
# Why a dedicated node: LevelDB cannot be copied consistently while it is being
# written, and we must never stop a validator or a sentry. The snapshotter is a
# throwaway follower (see docker-compose.yml, profile "snapshot"); stopping it
# for a few seconds to tar its db has ZERO impact on the validators/sentries.
#
# The archive contains ONLY chain data (gnoland-data/db) — no secrets, no wal
# (wal is node-local consensus scratch, rebuilt on start), no config/genesis.
# That makes it portable: any node can restore it (see restore.sh).
#
# Usage:
#   ./snapshot.sh            # capture one snapshot + rotate
#   RETENTION=48 ./snapshot.sh
#
# Safe to run on a timer (see systemd/gno-snapshot.timer). A trap guarantees the
# snapshotter is restarted even if the tar fails, so it is never left stopped.
set -euo pipefail

cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-gnoland-test}"

NODE="snapshotter"
DATA_DIR="$NODE/gnoland-data"
SNAP_DIR="${SNAP_DIR:-snapshots}"
RPC="${SNAP_RPC:-http://localhost:26662}"
RETENTION="${RETENTION:-24}"   # keep the N most recent archives

compose() { docker compose --profile snapshot "$@"; }

if [ ! -d "$DATA_DIR/db" ]; then
  echo "❌ $DATA_DIR/db not found — is the snapshotter bootstrapped and started?" >&2
  echo "   Run: make up-snapshotter" >&2
  exit 1
fi

mkdir -p "$SNAP_DIR"

# Best-effort height for a human-readable filename. Never fatal: if the RPC is
# unreachable we still take the snapshot and label the height "unknown".
HEIGHT="$(curl -s --max-time 5 "$RPC/status" \
  | jq -r '.result.sync_info.latest_block_height // "unknown"' 2>/dev/null || echo unknown)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$SNAP_DIR/${HEIGHT}-${TS}.tar.zst"

# Always bring the snapshotter back up, even on failure — it must keep following
# the chain so the NEXT snapshot is fresh.
restart_snapshotter() { compose start "$NODE" >/dev/null 2>&1 || true; }
trap restart_snapshotter EXIT

echo "==> Stopping $NODE for a consistent LevelDB copy (height=$HEIGHT)"
compose stop "$NODE" >/dev/null

echo "==> Archiving $DATA_DIR/db -> $OUT"
# db only: wal is intentionally excluded (rebuilt on start; see restore.sh).
tar -C "$DATA_DIR" -c db | zstd -q -T0 -o "$OUT"

echo "==> Restarting $NODE"
compose start "$NODE" >/dev/null
trap - EXIT

# Rotation: keep the RETENTION most recent, delete older ones.
echo "==> Rotating (keep $RETENTION most recent)"
ls -1t "$SNAP_DIR"/*.tar.zst 2>/dev/null | tail -n +"$((RETENTION + 1))" | while read -r old; do
  echo "    rm $old"
  rm -f "$old"
done

SIZE="$(du -h "$OUT" | cut -f1)"
echo "✅ Snapshot written: $OUT ($SIZE)"
