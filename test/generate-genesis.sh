#!/bin/bash

set -e

echo "🧬 Generating genesis..."

GENESIS_FILE="genesis.json"
BALANCE_FILE="genesis_balances.txt"
GNO_REPOS="/root/gno/examples/gno.land"
# ============================================
# 🔧 Validators configuration
# Format: "ADDRESS|PUBKEY|NAME"
# ============================================

VALIDATORS=(
  "g1k7asng8uzf74xs0tsrfwytldl76hs4l3asglym|gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zq690glfmzn8nn9gatw9fjc0jvpeklrgrlcpz26a47rmk40763dwv309t0q|samourai-crew"
  "g1a4r57443nqsa4j7esjhldznfujqparcq5l3sgu|gpub1pggj7ard9eg82cjtv4u52epjx56nzwgjyg9zqdntpm4jm0lyg8ag2kkx94s9xlv7ncjffg9q7p555wuew6gl63ryfq8f0a|samourai-crew-1"
)

# ============================================
# 🔓 Unrestricted address (dev only)
# ============================================

UNRESTRICTED_ADDR="g1ytk8g4zcmr8l3gghfkj4cfnh3secd2mnpvc62s"

# ============================================
# 🧹 Clean previous genesis
# ============================================

if [ -f "$GENESIS_FILE" ]; then
  echo "🧹 Removing existing genesis.json"
  rm -f "$GENESIS_FILE"
fi

# ============================================
# ⚙️ Generate base genesis
# ============================================

echo "⚙️ Running gnogenesis generate..."
gnogenesis generate

# ============================================
# 👥 Add validators
# ============================================

echo "👥 Adding validators..."

for val in "${VALIDATORS[@]}"; do
  IFS="|" read -r ADDR PUBKEY NAME <<< "$val"

  echo "   → $NAME"

  gnogenesis validator add \
    --address "$ADDR" \
    --pub-key "$PUBKEY" \
    --name "$NAME"
done

# ============================================
# 💰 Add balances
# ============================================

if [ ! -f "$BALANCE_FILE" ]; then
  echo "❌ genesis_balances.txt not found"
  exit 1
fi

echo "💰 Adding balances..."
gnogenesis balances add -balance-sheet "$BALANCE_FILE"


# ============================================
# 📦 Add Packages
# ============================================

if [ ! -d "$GNO_REPOS" ]; then
  echo "❌ GNO_REPOS directory not found: $GNO_REPOS"
  exit 1
fi

echo "📦 Adding packages from $GNO_REPOS..."
gnogenesis txs add packages \
  -genesis-path "$GENESIS_FILE" \
  "$GNO_REPOS"
# ============================================
# 🔓 Set params
# ============================================

echo "🔓 Setting unrestricted address..."
gnogenesis params set auth.unrestricted_addrs \
  "$UNRESTRICTED_ADDR" \
  -genesis-path "$GENESIS_FILE"

echo "✅ Genesis successfully generated!"

