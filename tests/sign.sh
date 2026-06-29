#!/usr/bin/env bash
set -euo pipefail
#info 
# get hash 
#gnokey query vm/qrender --data "gno.land/r/sys/cla:" --remote https://rpc.test-13-aeddi-1.gnoland.network

# Usage:
# ./sign-cla.sh <cla_hash> <account_name>
HASH="${1:?missing cla hash}"
ACCOUNT="${2:?missing account name}"

REMOTE="https://rpc.test-13-aeddi-1.gnoland.network"
CHAIN_ID="test-13"

# gnokey maketx call  \
# -pkgpath "gno.land/r/sys/cla" \
# -func func "Sign" -args $'$hash' \
# -gas-fee 1000000ugnot \
# -gas-wanted 1_000_000_000 \
# -send "" \
#  -broadcast \
#  -chainid "test-13" \
#  -remote "" $addr

 gnokey maketx call \
  -pkgpath "gno.land/r/sys/cla" \
  -func "Sign" \
  -args "${HASH}" \
  -gas-fee "1000000ugnot" \
  -gas-wanted "1000000000" \
  -broadcast \
  -chainid "${CHAIN_ID}" \
  -remote "${REMOTE}" \
  "${ACCOUNT}"