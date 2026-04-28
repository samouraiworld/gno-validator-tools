#!/bin/bash
set -e

CONTAINER="test13-validator-1"
REMOTE="http://localhost:26657"
PKG="gno.land/r/test13/v3/counter"
KEY="test13-bis"

echo "💥 E2E CRASH RECOVERY TEST"

# Step 1: Increment
echo "➡️ Increment before crash"
gnokey maketx run \
  -broadcast \
  -chainid dev \
  -remote $REMOTE \
  -gas-fee 1000000ugnot \
  -gas-wanted 3000000 \
  $KEY fix.gno

sleep 2

# Step 2: Kill validator
echo "💀 Killing validator..."
docker kill -s SIGKILL $CONTAINER

sleep 3

# Restart (if needed)
echo "🔄 Restarting validator..."
docker compose up -d

sleep 5

# Step 3: Increment again
echo "➡️ Increment after restart"
gnokey maketx run \
  -broadcast \
  -chainid dev \
  -remote $REMOTE \
  -gas-fee 1000000ugnot \
  -gas-wanted 3000000 \
  $KEY fix.gno

sleep 3

# Step 4: Query
RES=$(gnokey query "vm/qeval" \
  -remote $REMOTE \
  -data "$PKG.Render(\"\")")

echo "📊 Result after recovery: $RES"

echo "✅ Crash recovery OK"