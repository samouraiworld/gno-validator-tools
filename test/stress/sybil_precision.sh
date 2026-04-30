#!/bin/bash

# --- CONFIGURATION ---
PASSWORD="toto"
TX_PER_ACCOUNT=20
TARGETS=(
    "test13-bis:http://localhost:26658" 
    "test13-acc1:http://localhost:26659" 
    "test13-acc2:http://localhost:26660"
)

bombard_sync() {
    local KEY=$1
    local RPC=$2
    echo "⚖️  Precision Mode: $KEY on $RPC"

    for i in $(seq 1 $TX_PER_ACCOUNT); do
        # Pas de '&' ici : on attend le retour du binaire gnokey
        echo "$PASSWORD" | gnokey maketx run \
            -broadcast -chainid dev -remote "$RPC" \
            -gas-fee 1000000ugnot -gas-wanted 3000000 \
            -insecure-password-stdin -quiet \
            "$KEY" ./increment/fix.gno > /dev/null 2>&1
        
        echo -n "."
        # Un léger délai pour laisser le bloc se confirmer
        sleep 0.8
    done
    echo " ✅ $KEY done."
}

echo "🎯 STARTING PRECISION SYBIL TEST..."

# On lance les comptes en parallèle, mais l'intérieur est séquentiel
for target in "${TARGETS[@]}"; do
    KEY_NAME=${target%%:*}
    RPC_URL=${target#*:}
    bombard_sync "$KEY_NAME" "$RPC_URL" &
done

wait
echo -e "\n🏁 FINAL COUNTER: $(gnokey query "vm/qeval" -remote "http://localhost:26658" -data "gno.land/r/test13/v1/counter.Render(\"\")")"