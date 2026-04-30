#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE="http://localhost:26658"
PKG="gno.land/r/test13/v1/counter"
KEY="test13-bis"
TX_COUNT=10 # On descend à 10 pour tester la stabilité

echo "⚡ STARTING SEQUENTIAL STRESS TEST ($TX_COUNT tx)"

for i in $(seq 1 $TX_COUNT); do
  echo -n "➡️ Tx #$i: "
  # On enlève le & pour les faire une par une, mais sans sleep
  # On ajoute --quiet pour y voir clair
echo "toto" |  gnokey maketx run \
    -broadcast \
    -chainid dev \
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
