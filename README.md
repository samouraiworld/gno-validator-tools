# Gnoland Validator & Sentry Node Deployment

Infrastructure-as-Code pour préparer des serveurs Gnoland validateur/sentry
avec Docker, Alloy (logs + métriques) et UFW. Ansible ne gère que le **socle
serveur** ; le déploiement des nœuds gnoland eux-mêmes (docker-compose,
`entrypoint.sh`, `config.toml`, `genesis.json`) se fait à la main, décrit
dans un runbook dédié.

**Target environment:** Ubuntu ou Debian (testé sur Scaleway).

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Inventory setup](#inventory-setup)
4. [Deployment workflow](#deployment-workflow)
5. [Playbook reference](#playbook-reference)
6. [Docker Compose targets](#docker-compose-targets)
7. [Tools & scripts](#tools--scripts)
8. [Variables reference](#variables-reference)
9. [Security considerations](#security-considerations)
10. [Vagrant testing](#vagrant-testing)
11. [Local environments (devnet & tmkms-lab)](#local-environments-devnet--tmkms-lab)
12. [legacy/](#legacy)

---

## Architecture

### System topology

```
┌───────────────────────────────────────────┐     ┌───────────────────────────────────────────┐
│ Validator Node (VLAN privé)                │     │ Sentry Node (public)                       │
│                                             │     │                                             │
│   gnoland (Docker) ── P2P :26656 (privé) ──┼─────┼──► gnoland (Docker) ◄── public P2P :26656   │
│   otel-collector → 127.0.0.1:9464          │     │   node_exporter  → 127.0.0.1:9100           │
│   node_exporter  → 127.0.0.1:9100          │     │                                             │
│   Alloy: scrape local + push (relay/direct)│     │   Alloy: scrape local + push (direct)       │
└───────────────────┬─────────────────────────┘   └───────────────────┬─────────────────────────┘
                    │                                                   │
                    └── logs Docker + métriques (remote_write) ─────────┘
                                          │
                               reverse proxy MANUEL
                            (hors périmètre Ansible —
                          voir NETWORK_AND_REVERSE_PROXY.md)
                                          │
                                          ▼
                          Backend logs + métriques (VictoriaMetrics
                          en remote_write, ou équivalent — pas déployé
                          par ce dépôt)
```

Ansible ne déploie plus ni reverse proxy, ni TLS, ni stack de monitoring
(Loki/Prometheus/Grafana) : voir [`legacy/`](legacy/README.md) pour ce qui a
été retiré et pourquoi, et [`NETWORK_AND_REVERSE_PROXY.md`](NETWORK_AND_REVERSE_PROXY.md)
pour la mise en place manuelle du VLAN privé et du reverse proxy.

### Data flows

**Logs et métriques :** Grafana Alloy (rôle `alloy`, inclus dans
`base_setup.yml`) scrape localement `node_exporter`/`otel-collector`
(bindés en `127.0.0.1`, jamais exposés) et les logs Docker des conteneurs
gnoland, puis pousse le tout en remote_write/push :
- **mode `direct`** — pousse directement vers le backend, avec son propre
  bearer token (typiquement la sentry, qui a une sortie Internet directe) ;
- **mode `relay`** — pousse vers un reverse proxy monté à la main sur la
  sentry (typiquement le validateur, isolé sur le VLAN privé), qui relaie
  ensuite vers le backend et porte seul le bearer token.

Aucun port de scrape entrant n'est nécessaire : plus de Prometheus qui vient
tirer les métriques, plus de Promtail, plus de vhost NGINX par validateur.

---

## Prerequisites

### Control machine (where Ansible runs)

- Ansible >= 2.14
- Python >= 3.10
- Install: `pip install ansible`

### Target hosts (validator, sentry)

- Ubuntu 22.04 LTS ou Debian 12+
- Accès SSH par clé en `root`
- Accès Internet pendant le déploiement (l'isolation réseau privée vient
  dans une étape ultérieure, voir `NETWORK_AND_REVERSE_PROXY.md`)

---

## Inventory setup

```bash
cp inventory.yaml.example inventory.yaml
# éditer inventory.yaml : IPs, ufw_ports_app, variables alloy_*, tmkms_* si besoin
```

`inventory.yaml` est gitignoré — il contient de vraies IPs et éventuellement
des tokens. Voir `inventory.yaml.example` pour le détail des variables
(`alloy_*`, `ufw_*`, `tmkms_*`).

---

## Deployment workflow

### Étape 1 — Socle serveur

```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

Installe : paquets système + alias shell (`base_setup`), Docker Engine +
Compose v2 (`docker`), Go 1.25.0 + binaire gnoland compilé depuis les
sources (`gnoland`), pare-feu UFW (`ufw`), Node Exporter en `127.0.0.1:9100`
(`node_exporter`), Grafana Alloy — scrape local + push logs/métriques
(`alloy`).

Ne déploie **aucun** docker-compose applicatif, aucun reverse proxy, aucun
secret.

### Étape 2 — Déploiement manuel des nœuds gnoland

Voir **[`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md)** pour la procédure
complète : initialisation des secrets (`gnoland secrets init`, jamais fait
par Ansible), copie manuelle de `entrypoint.sh`/`config.toml`/`genesis.json`,
choix d'une des trois topologies dans [`compose/`](#docker-compose-targets),
`.env`, démarrage, vérification (`check_status.sh`).

### Étape 3 — Réseau privé (optionnel, une fois les nœuds validés)

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<vlan_id>
```

Voir [`NETWORK_AND_REVERSE_PROXY.md`](NETWORK_AND_REVERSE_PROXY.md) pour le
détail (y compris la mise en place manuelle d'un reverse proxy si besoin) et
`validator/Network_control.md` pour couper/rétablir l'accès Internet public
du validateur sans casser le VLAN.

### Étape 4 — tmkms (optionnel, uniquement pour `compose/validator-sentry-tmkms`)

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain-id>
```

### Étape 5 — Rétention froide des logs (optionnel, indépendant d'Alloy)

```bash
ansible-playbook -i inventory.yaml backup-logs.yaml
```

### Étape 6 — Snapshotter (optionnel)

```bash
ansible-playbook -i inventory.yaml install-snapshotter.yml --tags snapshotter
```

Voir `roles/snapshotter/README.md`.

---

## Playbook reference

### `base_setup.yml`

**Purpose:** Préparer le socle serveur (aucun docker-compose applicatif).

```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

**Rôles :** `base_setup`, `docker`, `gnoland`, `ufw`, `node_exporter`, `alloy`.

---

### `setup-tmkms.yml`

**Purpose:** Préparer le sidecar tmkms (softsign) sur le validateur, avant le
`docker compose up -d` manuel de `compose/validator-sentry-tmkms/`.

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain-id>
```

**Prérequis :** secrets gnoland du validateur déjà initialisés
(`gnoland secrets init` manuel) — le rôle échoue explicitement sinon, il ne
génère jamais de secret.

---

### `setup-private-network.yml`

**Purpose:** Activer l'interface VLAN privée sur un hôte.

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>
```

À lancer une fois les nœuds validés en IP publique. Voir
`NETWORK_AND_REVERSE_PROXY.md`.

---

### `backup-logs.yaml`

**Purpose:** Rétention froide des logs, indépendante d'Alloy (fenêtre de
rétention différente du backend logs/métriques).

```bash
ansible-playbook -i inventory.yaml backup-logs.yaml
```

Déploie `backup.sh` sur le validateur (extraction 24h des logs Docker,
compression, SCP quotidien vers la sentry) et `rotate.sh` sur la sentry
(rétention 30 jours), plus une paire de clés SSH validateur→sentry
auto-générée.

---

### `install-snapshotter.yml`

**Purpose:** Nœud non-signant dédié aux snapshots + push horaire vers
Scaleway Object Storage. Voir `roles/snapshotter/README.md`.

```bash
ansible-playbook -i inventory.yaml install-snapshotter.yml --tags snapshotter
```

---

## Docker Compose targets

Trois topologies statiques, 100% configurables via `.env` (voir
[`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md) pour la procédure complète) :

| Répertoire | Usage |
|---|---|
| `compose/sentry-alone/` | Sentry publique seule |
| `compose/validator-alone/` | Validateur seul + otel-collector (pas de sentry co-localisée) |
| `compose/validator-sentry-tmkms/` | Sentry + validateur + sidecar tmkms (softsign) sur le même hôte |

Ces fichiers ne sont **pas** des templates Jinja2 : ce sont des
docker-compose classiques (`${VAR}`), poussés à la main sur le serveur avec
un `.env` rempli à partir du `.env.example` correspondant — même logique que
`roles/snapshotter/templates/docker-compose.snapshotter.yml.j2` (qui reste
géré par Ansible, lui, car son besoin est différent : nœud non-signant,
staging complet par un rôle dédié).

---

## Tools & scripts

### check_status.sh

**Location:** `validator/check_status.sh` (à copier à la main, voir
`DEPLOYMENT_RUNBOOK.md`)

**Usage:**
```bash
bash check_status.sh <répertoire-du-nœud>
```

Vérifie : `image`/`MONIKER`/`PERSISTENT_PEERS` (+ `SEEDS`/`PRIVATE_PEER_IDS`
pour une sentry) dans `docker-compose.yml`, les secrets gnoland
(`gnoland secrets get`), l'état du validateur (`priv_validator_state.json`),
la présence de `gnoland-data/db`+`wal`, `genesis.json` (SHA256) et
`config.toml`.

---

## Variables reference

### `inventory.yaml` (voir `inventory.yaml.example`)

| Variable | Description |
| --- | --- |
| `public_ip` / `private_ip` | IPs de l'hôte |
| `ufw_ports_app` | Ports applicatifs ouverts publiquement (ex: `[26656]`) |
| `ufw_ports_moni` / `ufw_allow_ip` | Optionnel — port(s) restreints à une IP unique. Vide par défaut : plus aucun port de scrape entrant n'est requis depuis le passage à Alloy |
| `alloy_logs_enabled` | Active la pipeline logs Docker (Alloy) |
| `alloy_log_mode` | `"direct"` (token en dur) ou `"relay"` (via reverse proxy manuel) |
| `alloy_logs_remote_write_url` | URL cible pour les logs |
| `alloy_remote_write_mode` | `"direct"` ou `"relay"`, pour les métriques |
| `alloy_remote_write_url` | URL cible pour les métriques (remote_write) |
| `alloy_bearer_token` | Token pour le mode `"direct"` |
| `alloy_containers_filter` | Regex des conteneurs Docker dont les logs sont conservés |
| `alloy_job_name` | Label `job` sur les logs/métriques |
| `alloy_metrics_targets` | Liste `{job, service, address}` scrapée localement par Alloy |
| `tmkms_chain_id` / `tmkms_image` / `tmkms_build_image` | Optionnel — voir `setup-tmkms.yml` |

### `compose/*/.env.example`

Voir chaque fichier — `IMAGES`, `MONIKER(_*)`, `SEEDS`, `PERSISTENT_PEERS(_*)`,
`PRIVATE_PEER_IDS`, `TMKMS_CHAIN_ID` selon la topologie.

---

## Security considerations

### Secrets gnoland

Jamais générés par Ansible. Initialisation manuelle, une fois par nœud :

```bash
ssh root@<node-ip>
gnoland secrets init
gnoland secrets get  # noter node_id, p2p_address, validator_address
```

### Fichiers non-secrets par déploiement

`entrypoint.sh`, `config.toml`, `genesis.json` changent à chaque version de
gno (build, genesis, liens de téléchargement) — ils sont poussés à la main à
chaque déploiement (voir `DEPLOYMENT_RUNBOOK.md`), jamais rendus par un
template Ansible.

### Réseau

- P2P (`:26656`) : seul port ouvert publiquement par défaut.
- RPC (`:26657`) et métriques (`:9100`, `:9464`) : toujours bindés en
  `127.0.0.1` dans les composes de `compose/` — jamais exposés.
- Isolation VLAN privée du validateur : voir `NETWORK_AND_REVERSE_PROXY.md`
  et `validator/Network_control.md`.

### tmkms

Le rôle `tmkms` (utilisé par `setup-tmkms.yml`) échoue explicitement si les
secrets gnoland du validateur n'existent pas encore — il ne les génère
jamais. Voir `roles/tmkms/README.md`.

---

## Vagrant testing

Configuration de test dans `inventory-vagrant.yaml` :

| Host | IP | Rôle |
| --- | --- | --- |
| `gno-validator` | 192.168.56.10 | Validateur |
| `gno-sentry` | 192.168.56.11 | Sentry |
| `gno-tmkms` | 192.168.56.11 | tmkms (lab) |

```bash
vagrant up

ansible-playbook -i inventory-vagrant.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory-vagrant.yaml base_setup.yml -e target=gno-validator

# Secrets (SSH manuel dans chaque VM)
vagrant ssh gno-sentry -c 'gnoland secrets init && gnoland secrets get'
vagrant ssh gno-validator -c 'gnoland secrets init && gnoland secrets get'

# Déploiement des nœuds : voir DEPLOYMENT_RUNBOOK.md
```

---

## Local environments (devnet & tmkms-lab)

Deux bacs à sable Docker vivent à côté du flux Ansible de production. Les
deux sont des chaînes `dev` **autonomes et jetables** qui ne committent
jamais de secrets — tout ce qui est généré (clés, genesis, `.env`, état) est
gitignoré et régénéré à chaque setup.

### devnet

[`devnet/`](devnet/) est un **devnet Gno.land à 3 validateurs** entièrement
piloté par Docker (validator/validator2/validator3, plus une 4ᵉ identité
réservée au scénario d'onboarding GovDAO, un tx-indexer et un explorateur
gnoweb). Son but : exercer de bout en bout chaque fonctionnalité de
**gnomonitoring** — suivi de participation aux blocs, alertes
downtime/halt, watcher GovDAO, métriques Prometheus et bots Telegram — avant
de merger des changements en production. Il héberge aussi la configuration
de référence **sidecar tmkms softsign + socket Unix**.

Setup en une fois : `GNO_REPO_PATH=/path/to/gno ./bootstrap.sh`, puis
`docker compose up -d`. Voir [`devnet/README.md`](devnet/README.md) pour le
détail (reset, comptes de dev locaux, scénarios de test scriptés via
`make help`).

### tmkms-lab

[`tmkms-lab/`](tmkms-lab/) est une expérimentation plus petite, **2 VM**, qui
monte une chaîne mono-validateur (plus une sentry) et **externalise la
signature consensus vers [tmkms](https://github.com/iqlusioninc/tmkms)** en
TCP : la clé consensus privée vit sur une seconde VM, pas dans le conteneur
gnoland. Son but : comprendre et valider le chemin de signature distante
tmkms avant de le déployer en production.

Voir [`tmkms-lab/README.md`](tmkms-lab/README.md) pour le déroulé complet
(pré-requis d'image, bootstrap, échange de clés, vérification).

---

## legacy/

[`legacy/`](legacy/README.md) regroupe ce qui a été retiré du périmètre
Ansible actif lors de la simplification du dépôt (nginx/TLS/OAuth-proxy,
stack Loki/Prometheus/Grafana, déploiement automatisé des composes,
Promtail). Rien n'y est maintenu — c'est une référence historique, pas du
code à rejouer en l'état. Voir `legacy/README.md` pour le détail et les
raisons de chaque retrait.
