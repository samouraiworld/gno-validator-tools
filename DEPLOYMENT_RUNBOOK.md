# Runbook de déploiement manuel — gnoland (sentry / validator / tmkms)

Ansible ne déploie plus les nœuds gnoland eux-mêmes : seul le socle serveur
(`base_setup.yml`) est automatisé. Les fichiers propres à chaque déploiement
(`entrypoint.sh`, `config.toml`, `genesis.json`) changent à chaque version de
gno (build, genesis, liens de téléchargement) — les pousser à la main plutôt
que de maintenir une automatisation qui devrait être mise à jour à chaque
release évite un faux sentiment de sécurité et garde le déploiement explicite.

Ce document est le runbook de référence. Pas d'automatisation ici : juste des
commandes à exécuter, dans l'ordre, sur les bons hôtes.

## 0. Pré-requis

1. `base_setup.yml` déjà exécuté sur chaque hôte (sentry, validateur) :
   ```bash
   ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
   ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
   ```
2. Choisir la topologie parmi les trois disponibles dans `compose/` :
   - `compose/sentry-alone/` — sentry seule.
   - `compose/validator-alone/` — validateur seul + otel-collector.
   - `compose/validator-sentry-tmkms/` — sentry + validateur + sidecar tmkms
     (softsign) sur le même hôte.

## 1. Secrets gnoland — jamais générés par Ansible

Sur **chaque** nœud gnoland (sentry et/ou validateur), à faire manuellement,
une seule fois :

```bash
ssh root@<node-ip>
mkdir -p /root/<gno_dir>          # ex: /root/gnoland1
cd /root/<gno_dir>
# Pour validator-sentry-tmkms, faire ceci séparément dans ./sentry/ et ./validator/
gnoland secrets init
gnoland secrets get                # noter node_id, p2p_address, validator_address
```

Notez les `node_id`/adresses P2P nécessaires pour construire les
`PERSISTENT_PEERS`/`PRIVATE_PEER_IDS` des autres nœuds. Récupérez également
les `SEEDS` auprès de l'opérateur du réseau (gnocore ou équivalent).

## 2. Fichiers non-secrets à pousser à la main

Pour chaque nœud gnoland (répertoire à plat pour `sentry-alone` et
`validator-alone` ; sous-répertoires `sentry/` et `validator/` pour
`validator-sentry-tmkms`) :

| Fichier | Origine |
|---|---|
| `entrypoint.sh` | `validator/entrypoint.sh` de ce dépôt (copier tel quel, ou adapter si la version de gno l'exige) |
| `config.toml` | fourni par le réseau (URL de déploiement gno.land pour la chaîne visée) |
| `genesis.json` | fourni par le réseau (URL de genesis pour la chaîne visée) |
| `check_status.sh` | `validator/check_status.sh` (optionnel mais recommandé, script de vérification pré-démarrage) |

Exemple (sentry-alone) :

```bash
scp validator/entrypoint.sh validator/check_status.sh root@<sentry-ip>:/root/gnoland1/
scp compose/sentry-alone/docker-compose.yml compose/sentry-alone/.env.example root@<sentry-ip>:/root/gnoland1/
ssh root@<sentry-ip> 'cd /root/gnoland1 && curl -fsSL <config_url> -o config.toml && curl -fsSL <genesis_url> -o genesis.json'
```

Pour `validator-alone`, copier en plus `validator/otel/otel-config.yaml` dans
`otel/otel-config.yaml` à côté du compose.

Pour `validator-sentry-tmkms`, répéter les copies `entrypoint.sh`/
`config.toml`/`genesis.json`/`otel/otel-config.yaml` dans `sentry/` **et**
`validator/` (deux nœuds gnoland distincts sur le même hôte). Le
sous-répertoire `tmkms/` n'est PAS à pousser à la main : voir §4.

## 3. `.env` et démarrage

Sur l'hôte, dans le répertoire du compose choisi :

```bash
cp .env.example .env && chmod 600 .env
# remplir IMAGES, MONIKER(_*), SEEDS, PERSISTENT_PEERS(_*), PRIVATE_PEER_IDS, TMKMS_CHAIN_ID...
docker compose pull
docker compose up -d
```

Valider :

```bash
bash check_status.sh .        # ou le chemin du répertoire du nœud
docker compose logs -f
```

## 4. Cas `validator-sentry-tmkms` — sidecar tmkms

Le sidecar tmkms (image, `tmkms.toml`, clé de signature reslicée) est préparé
par Ansible, **après** l'étape 1 (les secrets gnoland du validateur doivent
déjà exister) et **avant** le `docker compose up -d` de l'étape 3 :

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain-id>
```

Ce playbook échoue explicitement (sans jamais générer de secret) si
`priv_validator_key.json` n'existe pas encore sur le validateur — revenir à
l'étape 1 dans ce cas. Voir `roles/tmkms/README.md` pour le détail du
fonctionnement (reslice de la clé, génération de la clé d'identité tmkms).

## 5. Mise à jour d'une chaîne (nouvelle version de gno / nouveau réseau)

1. Arrêter le nœud : `docker compose down` (ou juste le service concerné).
2. Remplacer `entrypoint.sh`/`config.toml`/`genesis.json` par les nouvelles
   versions (étape 2 ci-dessus), mettre à jour `IMAGES` dans `.env`.
3. Selon la nature du changement (reset de chaîne vs. upgrade compatible),
   vider ou non `gnoland-data/` — **ne jamais toucher** à
   `gnoland-data/secrets/` (ou `tmkms/secrets/` en mode tmkms) sans une
   politique de sauvegarde/rotation de clé délibérée.
4. `docker compose pull && docker compose up -d`, puis `check_status.sh`.

## 6. Journaux et métriques

Rien à faire ici au-delà de `base_setup.yml` : le rôle `alloy` (déjà inclus)
scrape localement `node_exporter`/`otel-collector` et pousse les logs Docker
des conteneurs gnoland en remote_write/push. Voir
`NETWORK_AND_REVERSE_PROXY.md` pour le mode relais via la sentry si le
validateur est isolé sur un VLAN privé.

## 7. Rétention froide des logs (optionnel, indépendant d'Alloy)

`backup-logs.yaml` reste actif et indépendant de ce runbook : il déploie
`backup.sh` (validateur, extraction 24h + SCP vers la sentry) et `rotate.sh`
(sentry, rétention 30 jours), en plus du pipeline Alloy — utile en
rétention froide au-delà de la fenêtre de rétention du backend de logs.

```bash
ansible-playbook -i inventory.yaml backup-logs.yaml
```
