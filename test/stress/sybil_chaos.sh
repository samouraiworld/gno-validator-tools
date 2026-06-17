#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CONFIGURATION ---
PASSWORD="toto"
TX_PER_ACCOUNT=10
# List of (Key:RPC) pairs
TARGETS=(
    "test13-me:https://rpc.test-13-moul-1.gnoland.network" 
    "test13-acc1:https://rpc.test-13-gfanton-1.gnoland.network/" 
    "test13-acc2:https://rpc.test-13-aeddi-1.gnoland.network/"
)

# Robust JSON cleanup helper
get_json_val() {
    echo "$1" | grep -o '{.*}' | jq -r "$2" 2>/dev/null
}

# Broadcast function for one account
bombard() {
    local KEY=$1
    local RPC=$2
    echo "🚀 Start: $KEY on $RPC"

    for i in $(seq 1 $TX_PER_ACCOUNT); do
        echo "$PASSWORD" | gnokey maketx run \
            -broadcast -chainid dev -remote "$RPC" \
            -gas-fee 1000000ugnot -gas-wanted 3000000 \
            -insecure-password-stdin -quiet \
            "$KEY" "$SCRIPT_DIR/../realms/counter/txs/increment.gno" > /dev/null 2>&1
        echo -n "."
    done
    echo " ✅ $KEY done."
}

echo "🌪️  LAUNCHING SYBIL ATTACK SIMULATION..."

# Launch in parallel
for target in "${TARGETS[@]}"; do
    KEY_NAME=${target%%:*}
    RPC_URL=${target#*:}
    bombard "$KEY_NAME" "$RPC_URL" &
done

wait # Wait for all 3 accounts to finish

echo -e "\n⏳ All accounts finished. Waiting for consensus to settle..."
sleep 10

# Final result (query the first RPC endpoint)
FINAL=$(gnokey query "vm/qeval" -remote "https://rpc.test-13-aeddi-1.gnoland.network" -data "gno.land/r/g19xnaenyhe88emmge4726ta43lp3n237vvuzc2n/v1/counter.Render(\"\")")
echo "🏁 FINAL COUNTER: $FINAL"
