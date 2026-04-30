#!/bin/bash
# Tests: general replay protection — sequence number enforcement
# Verifies that rebroadcasting a transaction with a sequence number that was
# already consumed is rejected with a sequence mismatch error.
# This is a baseline sanity check that underpins all Tier 1 consensus fixes.

PASSWORD="toto"
KEY="test13-bis"
CHAINID="dev"
RPC1="http://localhost:26658"
RPC2="http://localhost:26659"
RPC3="http://localhost:26660"
TMPDIR=$(mktemp -d)

echo "🧪 Replay protection — sequence number enforcement"

cat > "$TMPDIR/noop.gno" << 'EOF'
package main

func main() {}
EOF

# Tx 1: normal broadcast, auto-sequence (should succeed)
echo -n "   Tx 1 — normal broadcast... "
TX1=$(echo "$PASSWORD" | gnokey maketx run \
	-gas-fee 1000000ugnot -gas-wanted 1000000 \
	-broadcast -chainid "$CHAINID" -remote "$RPC1" \
	-insecure-password-stdin "$KEY" \
	"$TMPDIR/noop.gno" 2>&1)

if echo "$TX1" | grep -q "OK!"; then
	echo "OK"
else
	echo "FAILED (unexpected)"; echo "$TX1"; rm -rf "$TMPDIR"; exit 1
fi

# Get the sequence that was just used by querying the account
ADDR=$(gnokey list 2>/dev/null | grep -oE 'g1[a-z0-9]{38,}' | head -1)
SEQ_INFO=$(gnokey query "auth/accounts/${ADDR}" -remote "$RPC1" 2>&1)
CURRENT_SEQ=$(echo "$SEQ_INFO" | grep -oE '"sequence":"[0-9]+"' | grep -oE '[0-9]+$')
if [ -z "$CURRENT_SEQ" ] || [ "$CURRENT_SEQ" -eq 0 ]; then
	REPLAY_SEQ=0
else
	REPLAY_SEQ=$((CURRENT_SEQ - 1))
fi
echo "   Current sequence: $CURRENT_SEQ — replaying with sequence: $REPLAY_SEQ"

# Tx 2: replay with an already-used sequence number
echo -n "   Tx 2 — replay at sequence $REPLAY_SEQ (expect rejection)... "
TX2=$(echo "$PASSWORD" | gnokey maketx run \
	-gas-fee 1000000ugnot -gas-wanted 1000000 \
	-sequence "$REPLAY_SEQ" \
	-broadcast -chainid "$CHAINID" -remote "$RPC1" \
	-insecure-password-stdin "$KEY" \
	"$TMPDIR/noop.gno" 2>&1)

if echo "$TX2" | grep -qiE "sequence|wrong nonce|invalid sequence|account sequence|mempool"; then
	echo "✅ PROTECTED — replay rejected"
elif echo "$TX2" | grep -q "OK!"; then
	echo "❌ VULNERABLE — replay accepted"
else
	echo "⚠️  UNKNOWN OUTPUT"; echo "$TX2"
fi

# Cross-validator check: both other nodes should also reject
for RPC in "$RPC2" "$RPC3"; do
	echo -n "   Cross-replay check on $RPC... "
	TX3=$(echo "$PASSWORD" | gnokey maketx run \
		-gas-fee 1000000ugnot -gas-wanted 1000000 \
		-sequence "$REPLAY_SEQ" \
		-broadcast -chainid "$CHAINID" -remote "$RPC" \
		-insecure-password-stdin "$KEY" \
		"$TMPDIR/noop.gno" 2>&1)
	if echo "$TX3" | grep -qiE "sequence|wrong nonce|invalid|mempool"; then
		echo "✅ rejected"
	elif echo "$TX3" | grep -q "OK!"; then
		echo "❌ accepted"
	else
		echo "⚠️  UNKNOWN"; echo "$TX3"
	fi
done

rm -rf "$TMPDIR"
