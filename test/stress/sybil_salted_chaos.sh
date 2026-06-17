#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CONFIGURATION ---
PASSWORD="toto"
TX_PER_ACCOUNT=10 # Higher count for chaos testing
TARGETS=(
    "test13-me:https://rpc.test-13-moul-1.gnoland.network" 
    "test13-acc1:https://rpc.test-13-gfanton-1.gnoland.network/" 
    "test13-acc2:https://rpc.test-13-aeddi-1.gnoland.network/"
)

bombard_salted() {
    local KEY=$1
    local RPC=$2
    echo "🔥 Salted Chaos: $KEY on $RPC"

    for i in $(seq 1 $TX_PER_ACCOUNT); do
        # SALT: generate a unique hash per TX to prevent dedup
        SALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
        
        # Inject the SALT via the -memo flag
        (
            echo "$PASSWORD" | gnokey maketx run \
                -broadcast -chainid dev -remote "$RPC" \
                -gas-fee 1000000ugnot -gas-wanted 3000000 \
                -memo "samourai-salt-$SALT" \
                -insecure-password-stdin -quiet \
                "$KEY" "$SCRIPT_DIR/../realms/counter/txs/increment.gno" > /dev/null 2>&1
        ) & # Ultra-parallel: fire and forget
        
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
echo "🏁 FINAL COUNTER: $(gnokey query "vm/qeval" -remote "https://rpc.test-13-aeddi-1.gnoland.network" -data "gno.land/r/g19xnaenyhe88emmge4726ta43lp3n237vvuzc2n/v1/counter.Render(\"\")")"
