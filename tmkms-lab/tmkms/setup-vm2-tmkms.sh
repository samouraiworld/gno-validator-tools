#!/usr/bin/env bash
# tmkms-lab — VM2 (tmkms) setup. Builds the tmkms image, generates the
# kms-identity key (and prints its pubkey for VM1's TMKMS_ALLOW), renders
# tmkms.toml, and prints the run command.
#
# Prereq: scp the validator's consensus.key into ./secrets/consensus.key first.
#
# Usage (VM2):
#   VAL_PEERID=<hex> IP_GNO=192.168.56.10 CHAIN_ID=dev ./setup-vm2-tmkms.sh
#   ./setup-vm2-tmkms.sh show   # affiche seulement le ed25519 kms-identity en place
set -euo pipefail
cd "$(dirname "$0")"

# Helper kms-identity : dérive l'ed25519:<hex> (= TMKMS_ALLOW de VM1). La pubkey
# est une fonction déterministe du seed, donc une clé existante est relue (jamais
# régénérée) ; en mode génération, le seed est créé s'il manque.
cat > /tmp/kmsgen.go <<'GO'
package main
import ("crypto/ed25519";"crypto/rand";"encoding/base64";"encoding/hex";"fmt";"os")
func main(){
 path:=os.Args[1]
 var s []byte
 if b,err:=os.ReadFile(path); err==nil { // clé existante -> redérive
  s,err=base64.StdEncoding.DecodeString(string(b))
  if err!=nil || len(s)!=ed25519.SeedSize { fmt.Fprintln(os.Stderr,"seed kms-identity invalide"); os.Exit(1) }
 } else { // absente -> génère
  s=make([]byte,ed25519.SeedSize); rand.Read(s)
  os.WriteFile(path,[]byte(base64.StdEncoding.EncodeToString(s)),0o600)
 }
 p:=ed25519.NewKeyFromSeed(s).Public().(ed25519.PublicKey)
 fmt.Println("ed25519:"+hex.EncodeToString(p)) }
GO
kms_pubkey() {
  docker run --rm -v "$PWD/secrets:/s" -v /tmp/kmsgen.go:/kmsgen.go:ro \
    golang:1-alpine go run /kmsgen.go /s/kms-identity.key
}

# Sous-commande 'show' : affiche seulement le ed25519 de la clé déjà en place.
# Pas de build, pas de VAL_PEERID, pas de rendu tmkms.toml, et surtout aucune
# génération (erreur si la clé est absente, pour ne pas créer d'identité par
# accident quand on voulait juste la consulter).
if [ "${1:-}" = "show" ]; then
  [ -f secrets/kms-identity.key ] || { echo "kms-identity.key absente (rien à afficher)" >&2; exit 1; }
  kms_pubkey
  exit 0
fi

: "${VAL_PEERID:?set VAL_PEERID=<validator peer-id hex from VM1>}"
IP_GNO="${IP_GNO:-192.168.56.10}"
CHAIN_ID="${CHAIN_ID:-dev}"

mkdir -p secrets
[ -f secrets/consensus.key ] || { echo "ERREUR: secrets/consensus.key manquant (scp depuis VM1: tmkms-share/consensus.key)"; exit 1; }

echo "==> Building tmkms:local (si absent)"
docker image inspect tmkms:local >/dev/null 2>&1 || docker build -t tmkms:local .

echo "==> kms-identity : dérivation de la pubkey (génère la clé si absente)"
ALLOW=$(kms_pubkey)

echo "==> Rendu de tmkms.toml"
sed -e "s/__CHAIN__/$CHAIN_ID/g" -e "s/__PEERID__/$VAL_PEERID/g" -e "s#__IP_GNO__#$IP_GNO#g" \
  tmkms.toml.tmpl > tmkms.toml

cat <<EOF

================= VM2 prêt =================
TMKMS_ALLOW (à coller dans le .env de VM1) :
  $ALLOW

Démarre tmkms en compose (restart: always) :
  docker compose up -d
  docker compose logs -f          # attendu: "signed Precommit ... at h/r/s ..."
===========================================
EOF
