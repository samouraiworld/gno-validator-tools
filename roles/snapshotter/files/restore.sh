#!/usr/bin/env bash
# Restore a node's chain data from a snapshot archive (produced by snapshot.sh).
# Works for any gnoland deploy dir (snapshotter / sentry / validator): stop the
# stack, wipe gnoland-data/{db,wal}, extract the archive's db, restart. The node
# rejoins over P2P and replays only the delta (no genesis replay).
#
# The archive holds chain data only — the node keeps its own node_key, and the
# validator keeps its own consensus key + tmkms state (restored out-of-band).
#
# Usage:
#   ./restore.sh <deploy_dir> <archive.tar.zst> <compose_service>
#   ./restore.sh /root/gno-node-snapshotter snapshots/1234-...tar.zst snapshotter
#   ./restore.sh /root/gno-node            /tmp/1234-...tar.zst      validator
#
# Fetch an archive from Scaleway first if needed (see README): rclone copy ...
set -euo pipefail

DEPLOY_DIR="${1:-}"
ARCHIVE="${2:-}"
SERVICE="${3:-}"
if [ -z "$DEPLOY_DIR" ] || [ -z "$ARCHIVE" ] || [ -z "$SERVICE" ]; then
  echo "Usage: $0 <deploy_dir> <archive.tar.zst> <compose_service>" >&2
  exit 2
fi
[ -d "$DEPLOY_DIR" ]   || { echo "❌ deploy dir not found: $DEPLOY_DIR" >&2; exit 1; }
[ -f "$ARCHIVE" ]      || { echo "❌ archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"
DATA_DIR="$DEPLOY_DIR/gnoland-data"
[ -d "$DATA_DIR" ]     || { echo "❌ $DATA_DIR not found" >&2; exit 1; }

# The validator is the only slashing-sensitive restore. Guard it.
if [ "$SERVICE" = "validator" ]; then
  cat >&2 <<'WARN'
⚠️  VALIDATOR RESTORE — anti-double-sign checklist (tmkms mode):
    1. The old validator + its tmkms MUST be fully dead (never two signers).
    2. Keep the validator's OWN keys/state, restored out-of-band (NOT in this
       archive): gnoland node_key + tmkms consensus.key, kms-identity.key and
       consensus_state.json. Its height must NOT go backwards.
    3. This restores CHAIN DATA only; it does NOT touch tmkms secrets.
WARN
  read -r -p "Proceed with validator restore? [y/N] " ans
  case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

cd "$DEPLOY_DIR"
echo "==> Stopping $SERVICE"
docker compose stop "$SERVICE" >/dev/null 2>&1 || true

echo "==> Wiping gnoland-data/{db,wal}"
rm -rf gnoland-data/db gnoland-data/wal

echo "==> Extracting $ARCHIVE"
zstd -dc "$ARCHIVE" | tar -C gnoland-data -x

echo "==> Starting $SERVICE"
docker compose start "$SERVICE" >/dev/null

echo "✅ Restore done. Watch it catch up (latest_block_height climbs, catching_up -> false)."
