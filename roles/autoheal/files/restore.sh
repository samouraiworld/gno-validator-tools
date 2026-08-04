#!/usr/bin/env bash
# Restore a node's chain data from a snapshot archive (produced by snapshot.sh
# on the sentry's snapshotter, or pulled from Scaleway by pull-from-s3.sh).
# Stops the compose service, wipes gnoland-data/{db,wal}, extracts the
# archive's db, restarts. The node rejoins over P2P and replays only the delta
# (no genesis replay). Never touches node_key or the validator's consensus
# key/tmkms state — the archive holds chain data only.
#
# Usage:
#   ./restore.sh <deploy_dir> <archive.tar.zst> <compose_service> [--yes]
#   ./restore.sh /root/gno-node snapshots/1234-...tar.zst sentry
#   ./restore.sh /root/gno-node snapshots/1234-...tar.zst validator --yes
#
# --yes skips the interactive confirmation for a validator restore. Only pass
# it from an automated caller (autoheal.sh) that has ALREADY verified the old
# validator + tmkms are stopped — see the checklist below.
set -euo pipefail

DEPLOY_DIR="${1:-}"
ARCHIVE="${2:-}"
SERVICE="${3:-}"
YES="${4:-}"
if [ -z "$DEPLOY_DIR" ] || [ -z "$ARCHIVE" ] || [ -z "$SERVICE" ]; then
  echo "Usage: $0 <deploy_dir> <archive.tar.zst> <compose_service> [--yes]" >&2
  exit 2
fi
[ -d "$DEPLOY_DIR" ] || { echo "❌ deploy dir not found: $DEPLOY_DIR" >&2; exit 1; }
[ -f "$ARCHIVE" ]    || { echo "❌ archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"
DATA_DIR="$DEPLOY_DIR/gnoland-data"
[ -d "$DATA_DIR" ]   || { echo "❌ $DATA_DIR not found" >&2; exit 1; }

if [ "$SERVICE" = "validator" ]; then
  cat >&2 <<'WARN'
⚠️  VALIDATOR RESTORE — anti-double-sign checklist:
    1. The old validator + its tmkms MUST be fully dead (never two signers).
    2. Keep the validator's OWN keys/state, restored out-of-band (NOT in this
       archive): gnoland node_key + tmkms consensus.key, kms-identity.key and
       consensus_state.json. Its height must NOT go backwards.
    3. This restores CHAIN DATA only; it does NOT touch tmkms secrets.
WARN
  if [ "$YES" = "--yes" ]; then
    echo "--yes passed: skipping interactive confirmation (caller already verified the checklist above)." >&2
  else
    read -r -p "Proceed with validator restore? [y/N] " ans
    case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
  fi
fi

cd "$DEPLOY_DIR"
echo "==> Stopping $SERVICE"
docker compose stop "$SERVICE" >/dev/null 2>&1 || true

echo "==> Wiping gnoland-data/{db,wal}"
rm -rf gnoland-data/db gnoland-data/wal

echo "==> Extracting $ARCHIVE"
zstd -dc --long=31 "$ARCHIVE" | tar -C gnoland-data -x

echo "==> Starting $SERVICE"
docker compose start "$SERVICE" >/dev/null

echo "✅ Restore done. Watch it catch up (latest_block_height climbs, catching_up -> false)."
