#!/usr/bin/env sh

DIRECTORY=$1

if [ -z "$1" ]; then
  echo "[ERROR] Missing required argument: directory"
  echo "[INFO] Usage: $0 <directory>"
  exit 1
fi


##################### compose 
echo "---------  CHECK COMPOSE ------------------------------"
FILE="./$DIRECTORY/docker-compose.yml"
#SERVICE=$(yq -r '.services | keys[0]' "$FILE")
SERVICE=$(yq -r '.services | keys[] | select(test("validator|sentry"))' "$FILE" | head -n1)
image=$(yq -r ".services.\"$SERVICE\".image // empty" "$FILE")
moniker=$(yq -r ".services.\"$SERVICE\".environment.MONIKER // empty" "$FILE")
seed=$(yq -r ".services.\"$SERVICE\".environment.SEEDS // empty" "$FILE")
persistent_peer=$(yq -r ".services.\"$SERVICE\".environment.PERSISTENT_PEERS // empty" "$FILE")
private_peer_ids=$(yq -r ".services.\"$SERVICE\".environment.PRIVATE_PEER_IDS // empty" "$FILE")



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




check_empty "image" "$image"
check_empty "MONIKER" "$moniker"
check_empty "PERSISTENT_PEERS" "$persistent_peer"

# Only required for sentry
if [ "$SERVICE" = "sentry" ]; then
  check_empty "SEEDS" "$seed"
  check_empty "PRIVATE_PEER_IDS" "$private_peer_ids"
else
  echo "[INFO] Skipping SEEDS and PRIVATE_PEER_IDS check (service=$SERVICE)"
fi



###### secrets
echo "--------- CHECK SECRETS ---------------------------------"


cd "$DIRECTORY" || {
  echo "❌ Unable to cd into $DIRECTORY"
  exit 1
}

secrets=$(gnoland secrets get 2>/dev/null)

# Check if JSON is valid
if ! echo "$secrets" | jq . >/dev/null 2>&1; then
  echo "❌ Secrets invalid or missing"
  exit 1
fi

moniker=
node_id=$(echo "$secrets" | jq -r '.node_id.id // empty')
validator_addr=$(echo "$secrets" | jq -r '.validator_key.address // empty')
p2p_address=$(echo "$secrets" | jq -r '.node_id.p2p_address // empty')

error=0

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

check_secret "NODE_ID" "$node_id"
check_secret "VALIDATOR_ADDRESS" "$validator_addr"
check_secret "P2P_ADDRESS" "$p2p_address"


if [ $error -eq 1 ]; then
  echo "🚨 Secrets NOT ready"
  exit 1
else
  echo "🔐 Secrets READY"
fi
###################################################
echo "-------- CHECK priv_validator_state.json  ----------------"
STATE_FILE="./gnoland-data/secrets/priv_validator_state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ priv_validator_state.json missing"
  error=1
else
  height=$(jq -r '.height // empty' "$STATE_FILE")
  round=$(jq -r '.round // empty' "$STATE_FILE")

  echo "STATE FILE → height=$height / round=$round"

  # logical check
  if [ "$height" = "0" ] && [ "$round" = "0" ]; then
    echo "Validator priv_validator_state.json (height=0)"
  fi
fi

######### db #####
echo "--------- CHECK DB IF EXIST -----------------------------"

if [ -d "./gnoland-data/db" ]; then
  echo "db directory EXISTS"
else
  echo "db directory DOES NOT EXIST"
  error=1
fi

if [ -d "./gnoland-data/wal" ]; then
  echo "wal directory EXISTS"
else
  echo "wal directory DOES NOT EXIST"
  error=1
fi

################### genesis 
echo "-------- CHECK GENESIS ----------------------------------"

if [ ! -f "./genesis.json" ]; then
  echo "❌ genesis.json missing"
  error=1
else
  sha=$(sha256sum "./genesis.json" | awk '{print $1}')
  echo "✅ genesis.json OK → sha256: $sha"  
fi

################
echo "-------- CHECK config.toml  -----------------------------"

if [ ! -f "./config.toml" ]; then
  echo "❌ config.toml missing"
  error=1
else
  echo "✅ config.toml OK"
fi
