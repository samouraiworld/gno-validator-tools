#!/usr/bin/env bash
# Generates a self-contained 1-validator genesis.json for the tmkms-lab chain.
# Adapted from devnet/generate-genesis.sh. Called by bootstrap.sh with the
# validator address/pubkey exported as env vars.
set -euo pipefail
cd "$(dirname "$0")"

GENESIS_FILE="genesis.json"
BALANCE_FILE="genesis_balances.txt"
GNO_REPOS="/gnoroot/examples/gno.land"
GNOGENESIS_IMG="${GNOGENESIS_IMG:-gno-contribs:local}"

: "${VALIDATOR1_ADDR:?}" "${VALIDATOR1_PUBKEY:?}" "${VALIDATOR1_NAME:?}" "${UNRESTRICTED_ADDR:?}"

run_gnogenesis() {
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work \
    --entrypoint sh "$GNOGENESIS_IMG" -c "gnogenesis $*"
}

echo "Generating genesis (1 validator)..."
rm -f "$GENESIS_FILE"
run_gnogenesis generate
run_gnogenesis "validator add --address $VALIDATOR1_ADDR --pub-key $VALIDATOR1_PUBKEY --name $VALIDATOR1_NAME --power 10 --genesis-path $GENESIS_FILE"
[ -f "$BALANCE_FILE" ] || { echo "genesis_balances.txt not found" >&2; exit 1; }
run_gnogenesis "balances add --balance-sheet $BALANCE_FILE --genesis-path $GENESIS_FILE"
run_gnogenesis "txs add packages --genesis-path $GENESIS_FILE $GNO_REPOS"
run_gnogenesis "params set auth.unrestricted_addrs $UNRESTRICTED_ADDR --genesis-path $GENESIS_FILE"
echo "Genesis generated at $GENESIS_FILE"
