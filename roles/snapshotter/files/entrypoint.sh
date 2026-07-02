#!/usr/bin/env sh
# Entrypoint for the snapshotter — a plain NON-signing follower. No tmkms, no
# otel export (this stack has no collector), no inbound P2P needed beyond peers.
set -e

LOG_LEVEL=${LOG_LEVEL:-"info"}
MONIKER=${MONIKER:-"snapshotter"}
PEX=${PEX:-"true"}
PERSISTENT_PEERS=${PERSISTENT_PEERS:-""}
SEEDS=${SEEDS:-""}
MAX_PEERS=${MAX_PEERS:-"40"}
INBOUND=${INBOUND:-"40"}

# Generate node secrets (node_key) if missing.
gnoland secrets init

# Copy base config, then set follower values.
mkdir -p ./gnoland-data/config
cp config.toml ./gnoland-data/config/config.toml

gnoland config init --force
gnoland config set moniker "${MONIKER}"
gnoland config set p2p.pex "${PEX}"
gnoland config set p2p.persistent_peers "${PERSISTENT_PEERS}"
gnoland config set p2p.seeds "${SEEDS}"
gnoland config set p2p.max_num_outbound_peers "${MAX_PEERS}"
gnoland config set p2p.max_num_inbound_peers "${INBOUND}"
gnoland config set rpc.laddr "tcp://0.0.0.0:26657"
# Telemetry disabled: no otel-collector in this standalone stack.
gnoland config set telemetry.metrics_enabled false

exec gnoland start --skip-genesis-sig-verification \
  --genesis="./gnoland-data/genesis.json" \
  --log-level="${LOG_LEVEL}" --log-format=json
