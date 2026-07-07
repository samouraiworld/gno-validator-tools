#!/usr/bin/env sh

LOG_LEVEL=${LOG_LEVEL:-"info"}
MONIKER=${MONIKER:-"gnode"}
PEX=${PEX:-"true"}
PERSISTENT_PEERS=${PERSISTENT_PEERS:-""}
PRIVATE_PEER_IDS=${PRIVATE_PEER_IDS:-""}
SEEDS=${SEEDS:-""}
MAX_PEERS=${MAX_PEERS:-"40"}
INBOUND=${INBOUND:-"40"}


# Gen secrets if not exits

if [ ! -f ./gnoland-data/secrets/priv_validator_key.json ]; then
  gnoland secrets init
fi

# Copy base config

mkdir -p ./gnoland-data/config
cp config.toml ./gnoland-data/config/config.toml

# Set the config values
gnoland config init --force
gnoland config set moniker  "${MONIKER}"
gnoland config set p2p.pex  "${PEX}"
gnoland config set p2p.persistent_peers       "${PERSISTENT_PEERS}"
gnoland config set p2p.private_peer_ids       "${PRIVATE_PEER_IDS}"
gnoland config set p2p.seeds "${SEEDS}"
gnoland config set p2p.max_num_outbound_peers  "${MAX_PEERS}"
gnoland config set p2p.max_num_inbound_peers "${INBOUND}"
gnoland config set telemetry.metrics_enabled true
gnoland config set rpc.laddr "tcp://0.0.0.0:26657"

gnoland config set telemetry.service_instance_id "${MONIKER}"
gnoland config set telemetry.exporter_endpoint "otel-collector:4317"

# tmkms mode (opt-in via TMKMS_LISTEN_ADDR): externalize consensus signing to a
# tmkms sidecar instead of signing locally with priv_validator_key.json.
# Write the 4 tmkms_listener fields with listen_addr LAST — a non-empty
# listen_addr enables validation of the whole block, so setting it first is
# silently rejected while the others are still empty. On a unix:// listener the
# allowlist is neither required nor enforced (the 0600 socket is the boundary),
# so TMKMS_ALLOWED_KMS_PUBKEYS is optional.
if [ -n "${TMKMS_LISTEN_ADDR}" ]; then
  echo "[entrypoint] tmkms mode enabled → listen_addr=${TMKMS_LISTEN_ADDR}"
  gnoland config set consensus.priv_validator.tmkms_listener.chain_id "${TMKMS_CHAIN_ID}"
  gnoland config set consensus.priv_validator.tmkms_listener.protocol_version "v0.34"
  if [ -n "${TMKMS_ALLOWED_KMS_PUBKEYS}" ]; then
    gnoland config set consensus.priv_validator.tmkms_listener.allowed_kms_pubkeys "${TMKMS_ALLOWED_KMS_PUBKEYS}"
  fi
  gnoland config set consensus.priv_validator.tmkms_listener.listen_addr "${TMKMS_LISTEN_ADDR}"
fi

exec gnoland start --skip-genesis-sig-verification --genesis="./gnoland-data/genesis.json" --log-level=${LOG_LEVEL} --log-format=json
