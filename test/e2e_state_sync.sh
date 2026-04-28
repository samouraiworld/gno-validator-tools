#!/bin/bash
set -e

CONTAINER="test13-validator-2"
REMOTE_1="http://localhost:26657"
REMOTE_2="http://localhost:26658"
PKG="gno.land/r/test13/v3/counter"
KEY="test13-bis"

echo "🔄 E2E STATE SYNC TEST"

# Step 1: Stop validator2
echo "⛔ Stopping validator2..."
docker stop $CONTAINER

sleep 2

# Step 2: Send multiple tx
echo "➡️ Sending transactions on validator1..."
for i in {1..3}; do
  gnokey maketx run \
    -broadcast \
    -chainid dev \
    -remote $REMOTE_1 \
    -gas-fee 1000000ugnot \
    -gas-wanted 3000000 \
    $KEY fix.gno
done

sleep 3

# Step 3: Restart validator2
echo "🔄 Restarting validator2..."
docker start $CONTAINER

sleep 6

# Step 4: Compare state
RES1=$(gnokey query "vm/qeval" \
  -remote $REMOTE_1 \
  -data "$PKG.Render(\"\")")

RES2=$(gnokey query "vm/qeval" \
  -remote $REMOTE_2 \
  -data "$PKG.Render(\"\")")

echo "V1: $RES1"
echo "V2: $RES2"

if [ "$RES1" != "$RES2" ]; then
  echo "❌ State sync failed"
  exit 1
fi

echo "✅ State sync OK"