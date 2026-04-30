#!/bin/bash
# Targets: fix(gnovm): reject chan type at preprocess/runtime (4bcd9828e)
# Verifies that chan types are rejected at preprocess time (before execution).
# Without the fix, deployment succeeded and the node panicked only at runtime
# when the channel was actually used.

PASSWORD="toto"
KEY="test13-bis"
CHAINID="dev"
RPC="http://localhost:26658"
TMPDIR=$(mktemp -d)

echo "🧪 4bcd9828e — chan type rejection at preprocess"

cat > "$TMPDIR/chan.gno" << 'EOF'
package main

func main() {
	ch := make(chan int, 1)
	ch <- 42
}
EOF

echo -n "   Submitting script with chan type... "
RESULT=$(echo "$PASSWORD" | gnokey maketx run \
	-gas-fee 1000000ugnot \
	-gas-wanted 5000000 \
	-broadcast -chainid "$CHAINID" -remote "$RPC" \
	-insecure-password-stdin "$KEY" \
	"$TMPDIR/chan.gno" 2>&1)

if echo "$RESULT" | grep -qiE "chan|unsupported|not supported|invalid type"; then
	echo "✅ PATCHED — chan type rejected at preprocess"
elif echo "$RESULT" | grep -qiE "panic|runtime error"; then
	echo "❌ VULNERABLE — chan accepted at preprocess, panicked at runtime"
elif echo "$RESULT" | grep -q "OK!"; then
	echo "❌ VULNERABLE — chan type accepted with no error"
else
	echo "⚠️  UNKNOWN OUTPUT"; echo "$RESULT"
fi

rm -rf "$TMPDIR"
