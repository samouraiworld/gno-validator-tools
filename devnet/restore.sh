#!/usr/bin/env bash
# Restore a node's chain data from a snapshot produced by snapshot.sh.
#
# Mechanically identical for every node: stop it, wipe its db + wal, extract the
# snapshot's db, restart it. The node then rejoins over P2P and replays only the
# blocks produced since the snapshot (no genesis replay). The node keeps its own
# identity (node_key) and — for the validator — its own consensus key + tmkms
# state; the archive carries chain data only.
#
# Usage:
#   ./restore.sh <node-service> <snapshot.tar.zst>
#   ./restore.sh snapshotter snapshots/1234-20260701T120000Z.tar.zst   # full node
#   ./restore.sh validator    snapshots/1234-20260701T120000Z.tar.zst   # validator DR
#
# wal is wiped too (not just db): a stale wal replayed against a db restored at a
# different height would be inconsistent. gnoland recreates cs.wal on start.
set -euo pipefail

cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-gnoland-test}"

NODE="${1:-}"
ARCHIVE="${2:-}"
if [ -z "$NODE" ] || [ -z "$ARCHIVE" ]; then
  echo "Usage: $0 <node-service> <snapshot.tar.zst>" >&2
  exit 2
fi
DATA_DIR="$NODE/gnoland-data"
if [ ! -d "$DATA_DIR" ]; then
  echo "❌ $DATA_DIR not found — unknown node service '$NODE'?" >&2
  exit 1
fi
if [ ! -f "$ARCHIVE" ]; then
  echo "❌ snapshot not found: $ARCHIVE" >&2
  exit 1
fi

# Include every profile so any node (default / phase2 / snapshot) resolves.
compose() { docker compose --profile phase2 --profile snapshot "$@"; }

# The validator is the ONLY node where restoring is slashing-sensitive. Guard it
# with a reminder + confirmation. On devnet this is harmless; the prompt keeps
# the same script safe to reuse on the real host later.
if [ "$NODE" = "validator" ]; then
  cat >&2 <<'WARN'
⚠️  VALIDATOR RESTORE — anti-double-sign checklist (tmkms mode):
    1. The old validator + its tmkms MUST be fully dead (never two signers).
    2. Keep the validator's OWN keys: gnoland node_key + tmkms secrets
       (consensus.key, kms-identity.key) AND tmkms/validator/secrets/
       consensus_state.json. Its height must NOT go backwards.
       - state survived  -> reuse it as-is.
       - state lost       -> set its height to (chain head + margin) BEFORE
                             starting tmkms.
    3. This script restores CHAIN DATA only; it does NOT touch tmkms secrets.
WARN
  read -r -p "Proceed with validator restore? [y/N] " ans
  case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

echo "==> Stopping $NODE"
compose stop "$NODE" >/dev/null 2>&1 || true

echo "==> Wiping $DATA_DIR/{db,wal}"
rm -rf "$DATA_DIR/db" "$DATA_DIR/wal"

echo "==> Extracting $ARCHIVE -> $DATA_DIR"
zstd -dc "$ARCHIVE" | tar -C "$DATA_DIR" -x

echo "==> Starting $NODE"
compose start "$NODE" >/dev/null

echo "✅ Restore done. Watch it catch up:"
echo "   make status   (latest_block_height should climb, catching_up -> false)"
