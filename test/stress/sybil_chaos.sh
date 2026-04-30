#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CONFIGURATION ---
PASSWORD="toto"
TX_PER_ACCOUNT=100
# Liste des couples (Clé:RPC)
TARGETS=(
    "test13-bis:http://localhost:26658" 
    "test13-acc1:http://localhost:26659" 
    "test13-acc2:http://localhost:26660"
)

# Fonction de nettoyage JSON robuste
get_json_val() {
    echo "$1" | grep -o '{.*}' | jq -r "$2" 2>/dev/null
}

# Fonction de bombardement pour un compte
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

# Lancement en parallèle
for target in "${TARGETS[@]}"; do
    KEY_NAME=${target%%:*}
    RPC_URL=${target#*:}
    bombard "$KEY_NAME" "$RPC_URL" &
done

wait # Attend que les 3 comptes aient fini

echo -e "\n⏳ All accounts finished. Waiting for consensus to settle..."
sleep 10

# Résultat final (on interroge le premier RPC)
FINAL=$(gnokey query "vm/qeval" -remote "http://localhost:26658" -data "gno.land/r/test13/v1/counter.Render(\"\")")
echo "🏁 FINAL COUNTER: $FINAL"
