#!/usr/bin/env bash
# Detect whether a gnoland node's block height has stopped advancing while it
# reports catching_up=false. Pure read: no side effect beyond updating its own
# state file. When STUCK_THRESHOLD consecutive stuck samples are seen, it hands
# off to autoheal.sh (same directory) to actually restore the node.
#
# Usage:
#   ./check-stuck.sh <node-service> [rpc_url]
#   ./check-stuck.sh validator2 http://localhost:26659
#
# A node whose RPC is unreachable is DOWN, not "stuck" (restoring a snapshot
# won't fix a container that won't start) — logged, never triggers autoheal.
set -euo pipefail

cd "$(dirname "$0")"

NODE="${1:-}"
RPC="${2:-}"
if [ -z "$NODE" ]; then
  echo "Usage: $0 <node-service> [rpc_url]" >&2
  exit 2
fi

STATE_DIR="${STATE_DIR:-.autoheal}"
STATE_FILE="$STATE_DIR/${NODE}.state"
STUCK_THRESHOLD="${STUCK_THRESHOLD:-3}"

mkdir -p "$STATE_DIR"

# Resolve RPC from the node name if not given (see devnet/docker-compose.yml).
if [ -z "$RPC" ]; then
  case "$NODE" in
    validator)   RPC="http://localhost:26658" ;;
    validator2)  RPC="http://localhost:26659" ;;
    validator3)  RPC="http://localhost:26660" ;;
    validator4)  RPC="http://localhost:26661" ;;
    snapshotter) RPC="http://localhost:26662" ;;
    *) echo "❌ unknown node '$NODE' and no rpc_url given" >&2; exit 2 ;;
  esac
fi

STATUS="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
  echo "⚠️  $NODE: RPC unreachable at $RPC — node is DOWN, not stuck. No action taken."
  exit 0
fi

HEIGHT="$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height // empty')"
CATCHING_UP="$(echo "$STATUS" | jq -r '.result.sync_info.catching_up | tostring')"

if [ -z "$HEIGHT" ] || [ -z "$CATCHING_UP" ]; then
  echo "⚠️  $NODE: malformed /status response — skipping this check." >&2
  exit 0
fi

PREV_HEIGHT=""
STUCK_COUNT=0
if [ -f "$STATE_FILE" ]; then
  PREV_HEIGHT="$(jq -r '.height // empty' "$STATE_FILE" 2>/dev/null || true)"
  STUCK_COUNT="$(jq -r '.stuck_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if [ "$CATCHING_UP" = "true" ]; then
  echo "ℹ️  $NODE: catching_up=true (height=$HEIGHT) — syncing normally, not stuck."
  STUCK_COUNT=0
elif [ -n "$PREV_HEIGHT" ] && [ "$HEIGHT" = "$PREV_HEIGHT" ]; then
  STUCK_COUNT=$((STUCK_COUNT + 1))
  echo "⚠️  $NODE: height unchanged at $HEIGHT (catching_up=false) — stuck_count=$STUCK_COUNT/$STUCK_THRESHOLD"
else
  echo "✅ $NODE: height=$HEIGHT, progressing normally."
  STUCK_COUNT=0
fi

jq -n --arg h "$HEIGHT" --arg ts "$(date -u +%s)" --arg c "$STUCK_COUNT" \
  '{height: $h, ts: ($ts|tonumber), stuck_count: ($c|tonumber)}' > "$STATE_FILE"

if [ "$STUCK_COUNT" -ge "$STUCK_THRESHOLD" ]; then
  echo "🚨 $NODE: stuck for $STUCK_COUNT consecutive checks (>= $STUCK_THRESHOLD) — triggering autoheal."
  exec "$(dirname "$0")/autoheal.sh" "$NODE"
fi
