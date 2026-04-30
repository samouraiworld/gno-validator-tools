#!/bin/bash

# --- CONFIGURATION ---
PASSWORD="toto"
RPC="http://localhost:26658"
KEY="test13-bis"
CHAINID="dev"

# --- PRÉPARATION DES FICHIERS ---
# On utilise des noms simples sans underscores au début pour éviter les soucis de path
cat <<EOF > ovf.gno
package main
func main() {
    const huge = 18446744073709551615 + 1
    println(huge)
}
EOF

cat <<EOF > kami.gno
package main
func main() {
    Recursive()
}
func Recursive() {
    Recursive()
}
EOF

echo "🛡️  STARTING SAMOURAI SECURITY AUDIT (V2)..."
echo "------------------------------------"

# --- TEST 1 : INTEGER OVERFLOW ---
echo -n "🧪 Testing Tier 1 (Integer Overflow)... "
# On capture tout le flux (stdout et stderr)
RESULT_OVF=$(echo "$PASSWORD" | gnokey maketx run -broadcast -remote "$RPC" -chainid "$CHAINID" -gas-fee 1000000ugnot -gas-wanted 2000000 -insecure-password-stdin "$KEY" ./ovf.gno 2>&1)

if echo "$RESULT_OVF" | grep -qiE "overflows|cannot use huge"; then
    echo "✅ PATCHED"
elif echo "$RESULT_OVF" | grep -q "InvalidPkgPathError"; then
    echo "⚠️  PATH ERROR - retry manually with: gnokey maketx run ... ./ovf.gno"
else
    echo "❌ VULNERABLE"
    echo "$RESULT_OVF" | grep "Error" | head -n 5
fi

# --- TEST 2 : STACK RECURSION ---
echo -n "🧪 Testing Tier 1 (Stack Recursion)... "
RESULT_KAM=$(echo "$PASSWORD" | gnokey maketx run -broadcast -remote "$RPC" -chainid "$CHAINID" -gas-fee 1000000ugnot -gas-wanted 5000000 -insecure-password-stdin "$KEY" ./kami.gno 2>&1)

if echo "$RESULT_KAM" | grep -qi "out of gas"; then
    echo "✅ PATCHED (Gas limit hit)"
elif echo "$RESULT_KAM" | grep -qi "stack overflow"; then
    echo "✅ PATCHED (Stack limit hit)"
else
    echo "❌ CRITICAL"
    echo "$RESULT_KAM" | grep "Error" | head -n 5
fi

echo "------------------------------------"
echo "🧹 Cleaning up..."
rm ovf.gno kami.gno
echo "🏁 Audit Complete."
