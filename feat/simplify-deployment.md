# Plan — Simplification du déploiement

## Contexte et objectif

Le playbook `upload-betanet-deployment.yaml` est trop monolithique et complexe.
Le but est de le décomposer en playbooks simples, indépendants, avec un rôle clair chacun.

---

## Changements prévus

### 1. Supprimer `upload-betanet-deployment.yaml`

Remplacé par deux playbooks distincts.

---

### 2. Créer `install-sentry-node.yml`

**Rôle** : déployer le nœud sentry (docker-compose + config + genesis).

**Ce qu'il fait** :
- Crée le répertoire de travail `/root/{{ gno_dir }}`
- Télécharge `genesis.json` et `config.toml` si absents en local
- Copie `genesis.json`, `config.toml`, `entrypoint.sh` sur le sentry
- Rend le template `docker-sentry.yml.j2` → `docker-compose.yml`
- Pull ou charge l'image Docker (mode internet ou airgapped)
- Lance `docker compose up -d`

**Ce qu'il ne fait PAS** :
- Initialiser les secrets (voir point 4)
- Configurer le réseau privé (voir point 5)

---

### 3. Créer `install-validator-node.yml`

**Rôle** : déployer le nœud validateur.

**Ce qu'il fait** :
- Crée les répertoires `/root/{{ gno_dir }}` et `/root/{{ gno_dir }}/otel`
- Copie `genesis.json`, `config.toml`, `entrypoint.sh`, `otel-config.yaml`
- Rend le template `docker-validator.yml.j2` → `docker-compose.yml`
- Pull ou charge les images Docker (gnoland + otel)
- Lance `docker compose up -d`

**Ce qu'il ne fait PAS** :
- Initialiser les secrets (voir point 4)
- Configurer le réseau privé (voir point 5)

**Connexion SSH** :
- Initialement via IP publique (le validateur est encore accessible)
- Après activation du réseau privé, connexion via jump host sentry (géré par `setup-private-network.yml`)

---

### 4. Gestion des secrets — par les admins

**Recommandation : retirer toute gestion automatique des secrets des playbooks.**

Les secrets (`gnoland secrets init`) sont des clés cryptographiques sensibles (validator key, node key).
Les générer dans un playbook automatisé :
- crée un risque de perte ou d'exposition si le playbook est rejoué
- ne correspond pas au workflow réel (les secrets doivent être sauvegardés hors-bande)

**Procédure manuelle proposée (documentée dans le README)** :

```bash
# Sur chaque nœud (sentry et validateur), à faire manuellement une seule fois :
ssh root@<node-ip>
mkdir -p /root/gnoland1
cd /root/gnoland1
gnoland secrets init
gnoland secrets get   # → noter le node_id et p2p_address
```

Les admins notent et échangent ensuite les node IDs nécessaires pour construire les `PERSISTENT_PEERS`.

**Impact sur les playbooks** : supprimer complètement les blocs `secrets` des plays. Les playbooks supposent que les secrets existent déjà.

---

### 5. Correction du template `docker-sentry.yml.j2`

**Problème actuel** :
- `SEEDS` : vide ou non défini — doit contenir le seed fourni par gnocore
- `PERSISTENT_PEERS` : mal construit — doit contenir **seed gnocore + adresse P2P du validateur**

**Correction** :

```yaml
environment:
  MONIKER: "{{ moniker_sentry }}"
  SEEDS: "{{ seeds }}"
  # Format: <seed_gnocore>,<validator_node_id>@<validator_ip>:26656
  PERSISTENT_PEERS: "{{ seeds }},{{ private_peer_ids }}@{{ validator_p2p_ip }}:26656"
  PRIVATE_PEER_IDS: "{{ private_peer_ids }}"
```

Les variables à définir dans l'inventaire ou en extra-vars :
| Variable | Description |
|---|---|
| `seeds` | Seed(s) fournis par gnocore (format `id@ip:port`) |
| `private_peer_ids` | Node ID du validateur (récupéré manuellement via `gnoland secrets get`) |
| `validator_p2p_ip` | IP du validateur joignable depuis le sentry (privée si VLAN, publique sinon) |

---

### 6. Fusionner `base_setup_sentry.yaml` et `base_setup_validator.yaml` → `base_setup.yml`

**Objectif** : un seul playbook de setup de base qui cible le groupe voulu.

**Ce qu'il fait** :
- Rôles communs : `base_setup`, `node_exporter`, `docker`, `ufw`, `gnoland`
- Rôle `nginx` conditionnel (sentry uniquement, via variable ou group)
- Crée les répertoires de travail nécessaires

**Ce qu'il ne fait PAS** :
- Configurer les interfaces réseau privées (voir point 7)

**Usage** :
```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

---

### 7. Créer `setup-private-network.yml`

**Rôle** : configurer les interfaces VLAN privées, **à lancer séparément, après que toutes les installations sont terminées**.

**Ce qu'il fait** :
- Écrit `/etc/network/interfaces` avec l'interface VLAN
- Applique la configuration réseau (`ifup eno1.<vlan_id>`)

**Pourquoi séparé** :
- Activer le réseau privé en cours d'installation coupe l'accès SSH si mal configuré
- L'admin valide d'abord que tout tourne, puis bascule sur le réseau privé
- Plus simple à rejouer sans risque

**Usage** :
```bash
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-validator
```

---

## Ordre de déploiement cible

```
1. ansible-playbook base_setup.yml -e target=gno-sentry
2. ansible-playbook base_setup.yml -e target=gno-validator

   [MANUEL] gnoland secrets init sur chaque nœud
   [MANUEL] échanger les node IDs (validator → sentry)
   [MANUEL] récupérer les seeds auprès de gnocore

3. ansible-playbook install-sentry-node.yml
4. ansible-playbook install-validator-node.yml

   [VALIDATION] vérifier que les nœuds tournent et se voient

5. ansible-playbook setup-private-network.yml -e target=gno-sentry
6. ansible-playbook setup-private-network.yml -e target=gno-validator
```

---

## Fichiers impactés

| Action | Fichier |
|---|---|
| Supprimer | `upload-betanet-deployment.yaml` |
| Créer | `install-sentry-node.yml` |
| Créer | `install-validator-node.yml` |
| Créer | `base_setup.yml` |
| Créer | `setup-private-network.yml` |
| Supprimer | `base_setup_sentry.yaml` |
| Supprimer | `base_setup_validator.yaml` |
| Modifier | `templates/docker-sentry.yml.j2` |
| Mettre à jour | `README.md` (ordre de déploiement + procédure secrets manuelle) |
