#!/usr/bin/env sh

DIRECTORY=$1

if [ -z "$1" ]; then
  echo "[ERROR] Missing required argument: directory"
  echo "[INFO] Usage: $0 <directory>"
  exit 1
fi

error=0

check_empty () {
  name=$1
  value=$2

  if [ -z "$value" ] || [ "$value" = " " ]; then
    echo "❌ $name is empty"
    error=1
  else
    echo "✅ $name OK → $value"
  fi
}

check_secret () {
  name=$1
  value=$2

  if [ -z "$value" ]; then
    echo "❌ $name missing"
    error=1
  else
    echo "✅ $name OK → $value"
  fi
}

##################### compose
echo "---------  CHECK COMPOSE ------------------------------"
FILE="./$DIRECTORY/docker-compose.yml"

# List every validator/sentry service present. A validator-sentry-tmkms
# compose has BOTH in the same file — only checking the first declared
# match (previously `| head -n1`) silently skipped the other service
# entirely (e.g. sentry checked, validator+tmkms never verified at all).
SERVICES=$(yq -r '.services | keys[] | select(test("^(validator|sentry)$"))' "$FILE")

if [ -z "$SERVICES" ]; then
  echo "❌ No validator/sentry service found in $FILE"
  error=1
fi

for SERVICE in $SERVICES; do
  echo "--- service: $SERVICE ---"
  image=$(yq -r ".services.\"$SERVICE\".image // empty" "$FILE")
  moniker=$(yq -r ".services.\"$SERVICE\".environment.MONIKER // empty" "$FILE")
  persistent_peer=$(yq -r ".services.\"$SERVICE\".environment.PERSISTENT_PEERS // empty" "$FILE")

  check_empty "image ($SERVICE)" "$image"
  check_empty "MONIKER ($SERVICE)" "$moniker"
  check_empty "PERSISTENT_PEERS ($SERVICE)" "$persistent_peer"

  # Only required for a sentry service
  if [ "$SERVICE" = "sentry" ]; then
    seed=$(yq -r ".services.\"$SERVICE\".environment.SEEDS // empty" "$FILE")
    private_peer_ids=$(yq -r ".services.\"$SERVICE\".environment.PRIVATE_PEER_IDS // empty" "$FILE")
    check_empty "SEEDS ($SERVICE)" "$seed"
    check_empty "PRIVATE_PEER_IDS ($SERVICE)" "$private_peer_ids"
  else
    echo "[INFO] Skipping SEEDS/PRIVATE_PEER_IDS check (service=$SERVICE, not a sentry)"
  fi
done

###### tmkms mode detection #################################################
# With tmkms confirmed signing, TMKMS.md §6 recommends deleting
# priv_validator_key.json (unused once tmkms_listener is active) — `gnoland
# secrets get` then fails by design, and priv_validator_state.json stops
# being authoritative (tmkms's own consensus_state.json is, see TMKMS.md
# §5). Detect tmkms so the checks below adapt instead of hard-failing.
#   - local sidecar (validator-sentry-tmkms): a ./tmkms dir sits next to
#     this compose, or TMKMS_LISTEN_ADDR is hardcoded (unix://... or
#     tcp://...) directly in the compose.
#   - remote signer (validator-alone + compose/tmkms-alone/ elsewhere): no
#     local ./tmkms dir — only detectable via a resolved TMKMS_LISTEN_ADDR
#     in a local .env (the compose itself only has an unresolved ${VAR}
#     placeholder in that case).
TMKMS_MODE=0
if [ -d "./$DIRECTORY/tmkms" ]; then
  TMKMS_MODE=1
elif yq -r '.services[].environment.TMKMS_LISTEN_ADDR // empty' "$FILE" 2>/dev/null | grep -Eq '^(unix|tcp)://'; then
  TMKMS_MODE=1
elif [ -f "./$DIRECTORY/.env" ] && grep -Eq '^TMKMS_LISTEN_ADDR=(tcp|unix)://' "./$DIRECTORY/.env"; then
  TMKMS_MODE=1
fi
[ "$TMKMS_MODE" = "1" ] && echo "[INFO] tmkms mode detected"

cd "$DIRECTORY" || {
  echo "❌ Unable to cd into $DIRECTORY"
  exit 1
}

###### secrets ###############################################################
echo "--------- CHECK SECRETS ---------------------------------"

secrets=$(gnoland secrets get 2>/dev/null)

if ! echo "$secrets" | jq . >/dev/null 2>&1; then
  if [ "$TMKMS_MODE" = "1" ]; then
    # Expected once priv_validator_key.json has been deleted on purpose
    # (TMKMS.md §6) — check tmkms's own secrets instead of failing the
    # whole script here (this used to `exit 1` immediately, skipping the
    # DB/genesis/config checks below entirely).
    echo "[INFO] gnoland secrets unavailable (tmkms mode — priv_validator_key.json may have been deleted on purpose, see TMKMS.md §6)"
    for f in tmkms/secrets/consensus.key tmkms/secrets/kms-identity.key; do
      if [ -f "$f" ]; then
        echo "✅ $f OK"
      else
        echo "❌ $f missing"
        error=1
      fi
    done
  else
    echo "❌ Secrets invalid or missing"
    error=1
  fi
else
  node_id=$(echo "$secrets" | jq -r '.node_id.id // empty')
  validator_addr=$(echo "$secrets" | jq -r '.validator_key.address // empty')
  p2p_address=$(echo "$secrets" | jq -r '.node_id.p2p_address // empty')

  check_secret "NODE_ID" "$node_id"
  check_secret "VALIDATOR_ADDRESS" "$validator_addr"
  check_secret "P2P_ADDRESS" "$p2p_address"
fi

###################################################
echo "-------- CHECK validator state (priv_validator / tmkms) ----------"

if [ "$TMKMS_MODE" = "1" ] && [ -d "./tmkms" ]; then
  STATE_FILE="./tmkms/secrets/consensus_state.json"
elif [ "$TMKMS_MODE" = "1" ]; then
  STATE_FILE=""
  echo "[INFO] tmkms mode (remote signer) — consensus_state.json lives on the signer host, not checked here"
else
  STATE_FILE="./gnoland-data/secrets/priv_validator_state.json"
fi

if [ -n "$STATE_FILE" ]; then
  if [ ! -f "$STATE_FILE" ]; then
    echo "❌ $STATE_FILE missing"
    error=1
  else
    height=$(jq -r '.height // empty' "$STATE_FILE")
    round=$(jq -r '.round // empty' "$STATE_FILE")
    echo "STATE FILE ($STATE_FILE) → height=$height / round=$round"
  fi
fi

######### db + genesis + config, per service subdir when nested ############
# validator-sentry-tmkms nests gnoland-data/genesis.json/config.toml under
# sentry/ and validator/ (one compose, two node dirs); the other topologies
# keep them flat directly under $DIRECTORY. Check whichever layout applies,
# per service found above.
for SERVICE in $SERVICES; do
  if [ -d "./$SERVICE/gnoland-data" ] || [ -f "./$SERVICE/genesis.json" ]; then
    NODE_DIR="./$SERVICE"
  else
    NODE_DIR="."
  fi

  echo "--------- CHECK DB ($SERVICE, $NODE_DIR) -----------------------------"
  if [ -d "$NODE_DIR/gnoland-data/db" ]; then
    echo "db directory EXISTS"
  else
    echo "db directory DOES NOT EXIST"
    error=1
  fi

  if [ -d "$NODE_DIR/gnoland-data/wal" ]; then
    echo "wal directory EXISTS"
  else
    echo "wal directory DOES NOT EXIST"
    error=1
  fi

  echo "-------- CHECK GENESIS ($SERVICE, $NODE_DIR) ----------------------------------"
  if [ ! -f "$NODE_DIR/genesis.json" ]; then
    echo "❌ genesis.json missing"
    error=1
  else
    sha=$(sha256sum "$NODE_DIR/genesis.json" | awk '{print $1}')
    echo "✅ genesis.json OK → sha256: $sha"
  fi

  echo "-------- CHECK config.toml ($SERVICE, $NODE_DIR) -----------------------------"
  if [ ! -f "$NODE_DIR/config.toml" ]; then
    echo "❌ config.toml missing"
    error=1
  else
    echo "✅ config.toml OK"
  fi
done

if [ "$error" = "1" ]; then
  echo "🚨 check_status: one or more checks FAILED"
  exit 1
else
  echo "✅ check_status: all checks passed"
  exit 0
fi
