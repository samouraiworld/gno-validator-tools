#!/bin/bash
# Targets: fix(gnovm): proper gas consumption for mem allocation (5d5f9213f)
# Verifies that large memory allocations consume gas proportionally (per-byte model).
# Without the fix, all allocations used a flat fee — a 10MB alloc cost the same as
# a 10-byte alloc, making large-alloc DoS attacks virtually free.

PASSWORD="toto"
KEY="test13-bis"
CHAINID="dev"
RPC="http://localhost:26658"
TMPDIR=$(mktemp -d)

echo "🧪 5d5f9213f — Per-byte gas consumption for memory allocation"

# Test 1: large alloc with low gas-wanted must hit OOG
cat > "$TMPDIR/bigalloc.gno" << 'EOF'
package main

func main() {
	_ = make([]byte, 10_000_000)
}
EOF

echo -n "   10MB alloc with 100k gas (expect OOG)... "
RESULT=$(echo "$PASSWORD" | gnokey maketx run \
	-gas-fee 1000000ugnot \
	-gas-wanted 100000 \
	-broadcast -chainid "$CHAINID" -remote "$RPC" \
	-insecure-password-stdin "$KEY" \
	"$TMPDIR/bigalloc.gno" 2>&1)

if echo "$RESULT" | grep -qiE "out of gas|gas limit|exceeded"; then
	echo "✅ OOG triggered — per-byte gas model active"
elif echo "$RESULT" | grep -q "OK!"; then
	echo "❌ VULNERABLE — 10MB alloc passed with 100k gas (flat-fee model)"
else
	echo "⚠️  UNKNOWN OUTPUT"; echo "$RESULT"
fi

# Test 2: small alloc with same gas must succeed (confirms gas model is proportional, not just broken)
cat > "$TMPDIR/smallalloc.gno" << 'EOF'
package main

func main() {
	_ = make([]byte, 10)
}
EOF

echo -n "   10-byte alloc with 100k gas (expect OK)... "
RESULT2=$(echo "$PASSWORD" | gnokey maketx run \
	-gas-fee 1000000ugnot \
	-gas-wanted 100000 \
	-broadcast -chainid "$CHAINID" -remote "$RPC" \
	-insecure-password-stdin "$KEY" \
	"$TMPDIR/smallalloc.gno" 2>&1)

if echo "$RESULT2" | grep -q "OK!"; then
	echo "✅ Small alloc passed"
elif echo "$RESULT2" | grep -qiE "out of gas"; then
	echo "⚠️  Small alloc also hit OOG — raise gas-wanted threshold for this test"
else
	echo "⚠️  UNKNOWN OUTPUT"; echo "$RESULT2"
fi

rm -rf "$TMPDIR"
