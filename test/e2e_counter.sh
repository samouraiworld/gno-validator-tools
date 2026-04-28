#!/bin/bash
set -e

REMOTE_1="http://localhost:26657"
REMOTE_2="http://localhost:26658"
PKG="gno.land/r/test13/v3/counter"
KEY="test13-bis"

echo "🚀 E2E COUNTER TEST"

# Increment
echo "➡️ Sending Increment tx..."
gnokey maketx run \
  -broadcast \
  -chainid dev \
  -remote $REMOTE_1 \
  -gas-fee 1000000ugnot \
  -gas-wanted 3000000 \
  $KEY fix.gno

sleep 2

# Query both validators
echo "🔍 Query validator1"
RES1=$(gnokey query "vm/qeval" \
  -remote $REMOTE_1 \
  -data "$PKG.Render(\"\")")

echo "🔍 Query validator2"
RES2=$(gnokey query "vm/qeval" \
  -remote $REMOTE_2 \
  -data "$PKG.Render(\"\")")

echo "V1: $RES1"
echo "V2: $RES2"

if [ "$RES1" != "$RES2" ]; then
  echo "❌ Mismatch between validators"
  exit 1
fi

echo "✅ E2E COUNTER OK"