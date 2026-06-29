#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="https://rpc.test-13-aeddi-1.gnoland.network"
PKG="gno.land/r/g19xnaenyhe88emmge4726ta43lp3n237vvuzc2n/v1/counter"
KEY="test13-me"
TX_COUNT=10

echo "⚡ STARTING SEQUENTIAL STRESS TEST ($TX_COUNT tx)"

for i in $(seq 1 $TX_COUNT); do
  echo -n "➡️ Tx #$i: "
  # Sequential — no & and no sleep between txs
echo "toto" |  gnokey maketx run \
    -broadcast \
    -chainid test-13 \
    -remote $REMOTE \
    -gas-fee 1000000ugnot \
    -gas-wanted 3000000 \
    -insecure-password-stdin \
    -quiet \
    $KEY "$SCRIPT_DIR/../realms/counter/txs/increment.gno"
  
  if [ $? -eq 0 ]; then
    echo "✅ Sent"
  else
    echo "❌ Failed"
  fi
done

echo "⏳ Waiting for final commit..."
sleep 5

FINAL_VAL=$(gnokey query "vm/qeval" -remote $REMOTE -data "$PKG.Render(\"\")" | tr -d '"')
echo "🏁 Final Counter Value: $FINAL_VAL"
