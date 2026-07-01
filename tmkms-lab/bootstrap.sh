#!/usr/bin/env bash
# tmkms-lab — VM1 (validator + sentry) bootstrap for the 2-VM TCP tmkms test.
# Self-contained 1-validator chain. Generates secrets, base config, genesis,
# the .env (P2P peers), reslices the validator consensus key for tmkms, and
# prints the validator peer-id (hex) needed by tmkms on VM2.
#
# Idempotent: re-runs skip existing secrets/genesis. To start fresh, delete
# validator/ sentry/ gnoland-data, genesis.json, config.toml, .env.
#
# Usage (VM1):  GNO_IMAGE=chain:latest ./bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")"

# Settings can come from (priority): shell env > existing .env > defaults.
# So you can pre-seed a .env with local image names and just run ./bootstrap.sh.
# Re-runs preserve TMKMS_ALLOW (the kms pubkey you filled in after VM2 setup).
envget() { [ -f .env ] && grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }
GNO_IMAGE="${GNO_IMAGE:-$(envget GNO_IMAGE)}";                   GNO_IMAGE="${GNO_IMAGE:-chain:latest}"
GNO_CONTRIBS_IMAGE="${GNO_CONTRIBS_IMAGE:-$(envget GNO_CONTRIBS_IMAGE)}"; GNO_CONTRIBS_IMAGE="${GNO_CONTRIBS_IMAGE:-gno-contribs:local}"
CHAIN_ID="${CHAIN_ID:-$(envget CHAIN_ID)}";                     CHAIN_ID="${CHAIN_ID:-dev}"
TMKMS_ALLOW_KEEP="$(envget TMKMS_ALLOW)"
DOCKER_USER="$(id -u):$(id -g)"
NODES=(validator sentry)
echo "    images: GNO_IMAGE=$GNO_IMAGE  GNO_CONTRIBS_IMAGE=$GNO_CONTRIBS_IMAGE  chain=$CHAIN_ID"

echo "==> [1/5] Generating node secrets (validator + sentry)"
for n in "${NODES[@]}"; do
  mkdir -p "$n/gnoland-data/secrets"
  if [ -f "$n/gnoland-data/secrets/priv_validator_key.json" ]; then
    echo "    -> $n (existing, skip)"
    printf '{"height":"0","round":"0","step":0}\n' > "$n/gnoland-data/secrets/priv_validator_state.json"
  else
    docker run --rm --user "$DOCKER_USER" --entrypoint /usr/bin/gnoland \
      -v "$PWD/$n/gnoland-data:/gnoroot/gnoland-data" "$GNO_IMAGE" secrets init
  fi
done

echo "==> [2/5] Base config.toml"
if [ ! -f config.toml ]; then
  docker run --rm --user "$DOCKER_USER" --entrypoint /usr/bin/gnoland \
    -v "$PWD:/work" -w /work "$GNO_IMAGE" config init -config-path config.toml
fi
for n in "${NODES[@]}"; do cp config.toml "$n/config.toml"; done

echo "==> [3/5] Addresses / pubkeys / node IDs"
get() { docker run --rm --user "$DOCKER_USER" --entrypoint /usr/bin/gnoland \
  -v "$PWD/$1/gnoland-data:/gnoroot/gnoland-data" "$GNO_IMAGE" secrets get "$2" -raw; }
VAL_ADDR=$(get validator validator_key.address)
VAL_PUB=$(get validator validator_key.pub_key)
VAL_NODEID=$(get validator node_id.id)
SENTRY_NODEID=$(get sentry node_id.id)
# Validator peer-id in HEX (what tmkms pins in its addr) — sha256(pubkey)[:20].
# priv_key may be a flat base64 string (older builds) or an Any-wrapper object
# {"@type":..,"value":..} (newer builds) — handle both.
priv_b64() { jq -r 'if (.priv_key|type)=="object" then .priv_key.value else .priv_key end' "$1"; }
VAL_PEERID_HEX=$(priv_b64 validator/gnoland-data/secrets/node_key.json \
  | base64 -d | tail -c 32 | sha256sum | head -c 40)

echo "==> [4/5] Writing .env"
cat > .env <<EOF
GNO_IMAGE=${GNO_IMAGE}
GNO_CONTRIBS_IMAGE=${GNO_CONTRIBS_IMAGE}
DOCKER_USER=${DOCKER_USER}
CHAIN_ID=${CHAIN_ID}
PERSISTENT_PEERS_VALIDATOR=${SENTRY_NODEID}@sentry:26656
PERSISTENT_PEERS_SENTRY=${VAL_NODEID}@validator:26656
# Sentry keeps the validator private (don't gossip its address to the network).
PRIVATE_PEER_IDS_SENTRY=${VAL_NODEID}
# tmkms kms-identity pubkey (ed25519:<hex>) from VM2. Required (TCP refuses an
# empty allowlist). Preserved across bootstrap re-runs once filled.
TMKMS_ALLOW=${TMKMS_ALLOW_KEEP}
EOF

echo "==> [5/5] Genesis + reslice consensus key for tmkms"
cat > genesis_balances.txt <<EOF
${VAL_ADDR}=10000000000000ugnot # validator
EOF
if [ ! -f genesis.json ]; then
  GNOGENESIS_IMG="$GNO_CONTRIBS_IMAGE" \
  VALIDATOR1_ADDR="$VAL_ADDR" VALIDATOR1_PUBKEY="$VAL_PUB" VALIDATOR1_NAME="validator" \
  UNRESTRICTED_ADDR="$VAL_ADDR" ./generate-genesis.sh
fi
for n in "${NODES[@]}"; do cp genesis.json "$n/genesis.json"; done

mkdir -p tmkms-share
priv_b64 validator/gnoland-data/secrets/priv_validator_key.json \
  | base64 -d | head -c 32 | base64 -w0 > tmkms-share/consensus.key
echo "$VAL_PEERID_HEX" > tmkms-share/validator-peerid-hex.txt

cat <<EOF

================= VM1 prêt =================
Validator peer-id (HEX) : $VAL_PEERID_HEX

Sur VM2 (192.168.56.11) :
  1) scp tmkms-share/consensus.key vers tmkms/secrets/consensus.key
  2) cd tmkms && VAL_PEERID=$VAL_PEERID_HEX IP_GNO=192.168.56.10 ./setup-vm2-tmkms.sh
  3) note le 'ed25519:...' affiché (= TMKMS_ALLOW)

De retour sur VM1 :
  4) mets ce ed25519:... dans TMKMS_ALLOW du .env
  5) démarre tmkms sur VM2, PUIS:  docker compose up -d
===========================================
EOF
