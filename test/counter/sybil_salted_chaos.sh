#!/bin/bash

# --- CONFIGURATION ---
PASSWORD="toto"
TX_PER_ACCOUNT=50 # On augmente pour le chaos
TARGETS=(
    "test13-bis:http://localhost:26658" 
    "test13-acc1:http://localhost:26659" 
    "test13-acc2:http://localhost:26660"
)

bombard_salted() {
    local KEY=$1
    local RPC=$2
    echo "🔥 Salted Chaos: $KEY on $RPC"

    for i in $(seq 1 $TX_PER_ACCOUNT); do
        # Le SALT : on génère un hash unique pour chaque TX
        SALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
        
        # On injecte le SALT via le flag -memo
        (
            echo "$PASSWORD" | gnokey maketx run \
                -broadcast -chainid dev -remote "$RPC" \
                -gas-fee 1000000ugnot -gas-wanted 3000000 \
                -memo "samourai-salt-$SALT" \
                -insecure-password-stdin -quiet \
                "$KEY" ./increment/fix.gno > /dev/null 2>&1
        ) & # Mode ultra-parallèle
        
        if (( $i % 5 == 0 )); then echo -n "!"; sleep 0.1; fi
    done
    echo " 💀 $KEY storm sent."
}

echo "🌪️  LAUNCHING SALTED SYBIL ATTACK..."

for target in "${TARGETS[@]}"; do
    KEY_NAME=${target%%:*}
    RPC_URL=${target#*:}
    bombard_salted "$KEY_NAME" "$RPC_URL" &
done

wait
echo -e "\n⏳ Chaos finished. Checking survivors..."
sleep 5
echo "🏁 FINAL COUNTER: $(gnokey query "vm/qeval" -remote "http://localhost:26658" -data "gno.land/r/test13/v1/counter.Render(\"\")" | grep -o "Compteur Samourai : [0-9]*")"
