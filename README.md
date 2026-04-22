# Gnoland Validator & Sentry Node Deployment

Infrastructure-as-Code for deploying and managing Gnoland validator and sentry nodes with a complete monitoring stack. Uses Ansible for orchestration and Docker for containerization.

**Target environment:** Ubuntu or Debian servers (tested on Scaleway).

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Inventory setup](#inventory-setup)
4. [Deployment workflow](#deployment-workflow)
5. [Playbook reference](#playbook-reference)
6. [Tools & scripts](#tools--scripts)
7. [Variables reference](#variables-reference)
8. [Security considerations](#security-considerations)

---

## Architecture

### System topology

```
┌──────────────────────────────────────────────────────────────────────┐
│ Validator Node (private VLAN)                                        │
│                                                                      │
│   gnoland (Docker)                                                   │
│   OTEL Collector → :9464                                             │
│   Node Exporter  → :9100                                             │
│   Promtail ─────────────────┐ (logs to sentry loki-proxy)            │
└────────────┬────────────────┼──────────────────────────────────────┘
             │                │
       P2P :26656      (private VLAN)
      (private VLAN)         │
             │                │
┌────────────▼────────────────▼──────────────────────────────────────┐
│ Sentry Node (public)                                                │
│                                                                      │
│   gnoland (Docker) ◄───── public P2P :26656                          │
│   Node Exporter      → :9100                                         │
│   NGINX Exporter     → :9113                                         │
│   NGINX loki-proxy   → :80  (relays logs to Loki with Bearer token)  │
│   NGINX proxy vhosts:                                                │
│     :9200 → validator:9100  (node_exporter relay)                    │
│     :9464 → validator:9464  (OTEL relay)                             │
└────────────┬──────────────────────────────────────────────────────┬──┘
             │                                                       │
        (private VLAN)                                      HTTPS+Bearer token
             │                                                       │
┌────────────▼───────────────────────────────────────────────────────▼──┐
│ Monitoring Server                                                      │
│                                                                        │
│   Docker Compose:                                                      │
│     Loki        :3100  (log aggregation, localhost only)               │
│     Prometheus  :9090  (metrics collection, localhost only)            │
│     Grafana     :3000  (dashboards)                                    │
│                                                                        │
│   NGINX vhosts:                                                        │
│     grafana_domain    → Grafana :3000   (HTTPS + TLS)                  │
│     loki_domain       → Loki :3100      (HTTPS + Bearer token + IPs)   │
└────────────────────────────────────────────────────────────────────────┘
```

### Data flows

**Logs:**
- **Sentry relay mode:** Validator → Sentry loki-proxy (:80, private VLAN, HTTP) → Loki (:3100, HTTPS + token)
- **Direct mode:** Validator → Loki (:443, HTTPS + token)

**Metrics:**
- Prometheus scrapes Sentry :9100 (node metrics)
- Prometheus scrapes Sentry :9113 (NGINX metrics)
- Prometheus scrapes Sentry :9200 (validator node metrics via sentry proxy)
- Prometheus scrapes Sentry :9464 (validator OTEL metrics via sentry proxy)

---

## Prerequisites

### Control machine (where Ansible runs)

- Ansible >= 2.14
- Python >= 3.10
- Install: `pip install ansible`

### Target hosts (validator, sentry, monitoring server)

- Ubuntu 22.04 LTS or Debian 12+
- SSH key-based access as `root`
- Internet access during deployment (private network isolation comes in a later step)

### DNS

- A record for `grafana_domain` pointing to monitoring server (required for Let's Encrypt)
- A record for `loki_domain` pointing to monitoring server (required for Let's Encrypt)

---

## Inventory setup

### Add hosts to inventory.yaml

```yaml
all:
  vars:
    ansible_user: root

  children:
    betanet:
      hosts:
        gno-sentry:
          ansible_host: 1.2.3.4                # public IP for SSH access
          private_ip: 172.16.12.4              # VLAN IP (set after private network activation)
        gno-validator:
          ansible_host: 1.2.3.5                # public IP for SSH access (during deployment)
          private_ip: 172.16.12.2              # VLAN IP (set after private network activation)

    monitoring:
      hosts:
        gno-monitoring:
          ansible_host: 1.2.3.6                # public IP for SSH access
```

### Copy and configure group variables

```bash
cp group_vars/betanet.yml.example group_vars/betanet.yml
cp group_vars/monitoring.yml.example group_vars/monitoring.yml
```

Edit both files with your deployment-specific values:
- IPs, monikers, domain names
- Bearer tokens (use `ansible-vault` for encryption)
- Seed nodes, peer configurations

**Important:** Add both files to `.gitignore` — they contain real IPs and secrets.

---

## Deployment workflow

### Step 1: Base system setup

Deploy base packages, Docker, firewall, and gnoland binary on both nodes:

```bash
# Sentry (with NGINX reverse proxy)
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-sentry -e install_nginx=true

# Validator
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-validator
```

This installs:
- System packages and shell aliases
- Docker Engine + Docker Compose v2
- Go 1.25.0 and gnoland binary (built from source)
- UFW firewall
- Node Exporter (port 9100)
- NGINX (sentry only)

### Step 2: Initialize gnoland secrets (manual)

SSH to each node and initialize blockchain secrets:

```bash
ssh root@<sentry-ip>
gnoland secrets init
gnoland secrets get  # save the node_id

ssh root@<validator-ip>
gnoland secrets init
gnoland secrets get  # save the node_id
```

**Use the node IDs in the next steps:**
- Validator node ID → add to sentry's `private_peer_ids` and `validator_p2p_ip`
- Get seed nodes from gnocore → add to sentry's `seeds`

### Step 3: Deploy sentry node

```bash
ansible-playbook -i inventory.yaml 2-install-sentry-node.yml \
  -e private_peer_ids=<validator_node_id> \
  -e validator_p2p_ip=<validator_ip>
```

The sentry node will:
- Accept validator as a private peer (hidden from peer exchange)
- Bootstrap from seed nodes
- Expose public P2P on :26656

### Step 4: Deploy validator node

```bash
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e persistent_peers_sentry=<sentry_node_id>@<sentry_ip>:26656
```

The validator will:
- Connect only to the sentry peer
- Operate in sentry mode (peer exchange disabled, `gno_use_sentry=true`)
- Not expose P2P publicly

### Step 5: Validate nodes are running

```bash
ssh root@<validator-ip>
bash /root/check_status.sh gnoland1

ssh root@<sentry-ip>
bash /root/check_status.sh gnoland1
docker logs <container_id>
```

### Step 6: Deploy log backup scripts

```bash
ansible-playbook -i inventory.yaml 4-backup_logs.sh.yaml
```

This deploys:
- `backup.sh` on validator — extracts 24h of logs, compresses, ships to sentry daily at 00:10
- `rotate.sh` on sentry — enforces 30-day retention on backups
- SSH key pair for validator→sentry SCP access (auto-generated)

### Step 7: Deploy monitoring stack

Deploy Loki, Prometheus, and Grafana on the monitoring server:

```bash
# Production (with TLS)
ansible-playbook -i inventory.yaml 5-deploy-monitoring-stack.yaml \
  -e @group_vars/monitoring.yml

# Vagrant (HTTP only)
ansible-playbook -i inventory-vagrant.yaml 5-deploy-monitoring-stack.yaml \
  -e target=gno-monitoring-test \
  -e @group_vars/monitoring.yml \
  --skip-tags tls
```

This deploys on the monitoring server:
- Docker Compose stack (Loki + Prometheus + Grafana)
- NGINX vhosts with TLS (Grafana + Loki)
- Grafana datasources (auto-provisioned)

And on the sentry:
- NGINX loki-proxy vhost (:80) — accepts logs from validator, injects Bearer token

### Step 8: Deploy validator metric proxies (optional)

If you want Prometheus to scrape validator metrics via the sentry (recommended for private VLAN):

```bash
ansible-playbook -i inventory.yaml 5b-deploy-validator-proxies.yaml
```

This requires `validator_proxies` list in sentry inventory:

```yaml
gno-sentry:
  validator_proxies:
    - name: validator-1
      private_ip: 172.16.12.2
      node_exporter_port: 9200
      otel_port: 9464
```

Prometheus will then scrape:
- `:9200` (validator node_exporter via sentry)
- `:9464` (validator OTEL via sentry)

### Step 9: Deploy Promtail on validator

**Option A — Sentry relay mode (recommended for private VLAN):**

```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-sentry.yaml
```

Logs flow: Validator → Sentry loki-proxy (:80) → Loki. No Bearer token stored on validator.

**Option B — Direct mode (for standalone validators):**

```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-direct.yaml
```

Logs flow: Validator → Loki (:443 HTTPS + Bearer token). Token stored on validator at `/etc/promtail/config.yml` (mode 0600).

### Step 10: Activate private VLAN (optional)

After all nodes are running and validated, activate private network isolation:

```bash
ansible-playbook -i inventory.yaml 7-setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<your_vlan_id>

ansible-playbook -i inventory.yaml 7-setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<your_vlan_id>
```

The `vlan_id` is provided by your hosting provider (e.g., Scaleway Private Networks console).

Once active, you can disable the validator's internet access while keeping the private VLAN operational:

```bash
ssh root@<validator-ip>

# Disable internet (keeps private VLAN active)
ip addr flush dev eno1

# Re-enable if needed (for playbook re-runs)
dhclient eno1
```

See `/root/Network_control.md` on the validator for detailed network isolation instructions.

---

## Playbook reference

### 1-base_setup.yml

**Purpose:** Prepare base system for gnoland nodes.

**Usage:**
```bash
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-sentry -e install_nginx=true
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-validator
```

**Roles applied to all targets:**
- `base_setup` — apt packages, shell aliases
- `docker` — Docker Engine + Compose v2
- `node_exporter` — Prometheus exporter (port 9100)
- `ufw` — UFW firewall rules
- `gnoland` — Go 1.25.0 + gnoland binary build

**Roles applied when `install_nginx=true`:**
- `nginx` — NGINX reverse proxy

**Tags:** None (applies all roles)

---

### 2-install-sentry-node.yml

**Purpose:** Deploy sentry node via Docker Compose.

**Prerequisites:**
- `1-base_setup.yml` completed on sentry
- Secrets initialized manually: `gnoland secrets init && gnoland secrets get`
- Validator node ID available

**Usage:**
```bash
ansible-playbook -i inventory.yaml 2-install-sentry-node.yml \
  -e private_peer_ids=<validator_node_id> \
  -e validator_p2p_ip=<validator_ip>
```

**Key variables:**
- `private_peer_ids` — validator node ID (hidden from peer exchange)
- `validator_p2p_ip` — validator's reachable P2P IP
- `seeds` — bootstrap seed nodes (from gnocore)

**Tags:** `config`, `docker`, `compose`

---

### 3-install-validator-node.yml

**Purpose:** Deploy validator node via Docker Compose.

**Prerequisites:**
- `1-base_setup.yml` completed on validator
- Secrets initialized manually: `gnoland secrets init && gnoland secrets get`
- Sentry node ID and IP available

**Usage:**
```bash
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e persistent_peers_sentry=<sentry_node_id>@<sentry_ip>:26656
```

**Key variables:**
- `persistent_peers_sentry` — sentry P2P address (`node_id@ip:26656`)
- `gno_use_sentry` — `true` (sentry mode, default) or `false` (standalone)

**Tags:** `config`, `docker`, `compose`

---

### 4-backup_logs.sh.yaml

**Purpose:** Deploy log backup and rotation scripts via cron.

**Usage:**
```bash
ansible-playbook -i inventory.yaml 4-backup_logs.sh.yaml
```

**What it deploys:**
- **Validator:** `backup.sh` — extracts 24h of Docker logs, compresses with xz, ships to sentry via SCP daily at 00:10
- **Sentry:** `rotate.sh` — enforces 30-day retention in backup directory

**Automation:**
- SSH key pair auto-generated on validator and authorized on sentry
- Cron job added to `/etc/cron.d/gnoland-backup`

**Tags:** None (applies all tasks)

---

### 5-deploy-monitoring-stack.yaml

**Purpose:** Deploy Loki, Prometheus, and Grafana with NGINX proxies.

**Two-play structure:**

**Play 1 — Monitoring server:**
- Docker Compose (Loki + Prometheus + Grafana)
- NGINX vhosts with Let's Encrypt TLS
- Grafana datasources (auto-provisioned)
- All services listen on localhost only (NGINX handles public access)

**Play 2 — Sentry:**
- NGINX loki-proxy vhost (:80)
- Accepts logs from validator on private VLAN
- Injects Bearer token before forwarding to Loki (validators never hold the token)

**Usage:**
```bash
# Production (TLS enabled)
ansible-playbook -i inventory.yaml 5-deploy-monitoring-stack.yaml \
  -e @group_vars/monitoring.yml

# Vagrant (HTTP only)
ansible-playbook -i inventory-vagrant.yaml 5-deploy-monitoring-stack.yaml \
  -e target=gno-monitoring-test \
  -e @group_vars/monitoring.yml \
  --skip-tags tls
```

**Prerequisites:**
- `group_vars/monitoring.yml` configured
- DNS records for `loki_domain` and `grafana_domain`
- NGINX installed on sentry (via `1-base_setup.yml -e install_nginx=true`)

**Tags:** `stack`, `config`, `grafana`, `proxy`, `tls`

**Stack directory:** `/opt/monitoring/` on monitoring server

---

### 5b-deploy-validator-proxies.yaml

**Purpose:** Deploy metric proxy vhosts on sentry for validator metrics.

**Enables Prometheus to access validator metrics via sentry (no direct validator access needed).**

**Usage:**
```bash
ansible-playbook -i inventory.yaml 5b-deploy-validator-proxies.yaml
```

**Prerequisites:**
- NGINX installed on sentry (via `1-base_setup.yml -e install_nginx=true`)
- `validator_proxies` list defined on `gno-sentry` in inventory

**Inventory configuration:**
```yaml
gno-sentry:
  validator_proxies:
    - name: validator-1
      private_ip: 172.16.12.2
      node_exporter_port: 9200
      otel_port: 9464
```

**Deployed vhosts:**
- `:9200` → validator :9100 (node metrics)
- `:9464` → validator :9464 (OTEL metrics)

**UFW rules:** Automatically adds rules to allow monitoring IP on proxy ports

**Tags:** `nginx`, `ufw`

---

### 6-deploy-promtail-sentry.yaml

**Purpose:** Deploy Promtail on validator, logs via sentry relay.

**Log path:** Validator → Sentry loki-proxy (:80, private VLAN, HTTP) → Loki

**Benefits:**
- Validator has no Bearer token (no secrets to rotate)
- Sentry injects token transparently
- Works over private VLAN (HTTP, no TLS needed on private segment)

**Usage:**
```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-sentry.yaml
```

**For pre-activated private networks (SSH jump via sentry):**
```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-sentry.yaml \
  -e gno_network_mode=private \
  -e gno_sentry_ip=<sentry_private_ip> \
  -e gno_validator_private_ip=<validator_private_ip>
```

**Prerequisites:**
- `5-deploy-monitoring-stack.yaml` completed (loki-proxy running on sentry)
- `sentry_private_ip` set in `group_vars/betanet.yml`

**Configuration:**
- `promtail_job_name` — Loki job label (default: validator moniker)

**Tags:** None (applies all tasks)

---

### 6-deploy-promtail-direct.yaml

**Purpose:** Deploy Promtail on validator, logs directly to Loki.

**Log path:** Validator → Loki (:443 HTTPS + Bearer token) → Loki

**Benefits:**
- Direct path (no sentry relay needed)
- Simpler setup for standalone validators

**Drawbacks:**
- Validator must have internet access on port 443
- Bearer token stored on validator (requires rotation policy)

**Usage:**
```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-direct.yaml
```

**Prerequisites:**
- `5-deploy-monitoring-stack.yaml` completed
- Validator has outbound HTTPS access to `loki_domain`
- `loki_domain` and `loki_bearer_token` set in `group_vars/betanet.yml`

**Security note:** Bearer token written to `/etc/promtail/config.yml` (mode 0600, root only). Encrypt the group vars with `ansible-vault`:
```bash
ansible-vault encrypt group_vars/betanet.yml
```

**Tags:** None (applies all tasks)

---

### 7-setup-private-network.yml

**Purpose:** Activate private VLAN network interfaces on validator and sentry.

**Run this after nodes are validated and running.**

**Usage:**
```bash
ansible-playbook -i inventory.yaml 7-setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>

ansible-playbook -i inventory.yaml 7-setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<vlan_id>
```

**Parameters:**
- `target` — host or group to configure (required)
- `vlan_id` — VLAN ID from hosting provider (e.g., Scaleway)

**What it configures:**
- VLAN network interface (e.g., `eth0.1938`)
- Static IP from `private_ip` inventory variable
- Persists across reboots

**Note:** Status is `NOT TESTED YET` — validate before using in production.

**Tags:** None (applies all tasks)

---

## Tools & scripts

### check_status.sh

**Location:** `/root/check_status.sh` (deployed by playbooks)

**Purpose:** Pre-flight validation before starting gnoland node.

**Usage:**
```bash
bash /root/check_status.sh gnoland1
```

**Checks performed:**

| Section | Details |
| --- | --- |
| **docker-compose.yml** | Validates `image`, `MONIKER`, `PERSISTENT_PEERS` are set. On sentry: also `SEEDS`, `PRIVATE_PEER_IDS`. |
| **Secrets** | Runs `gnoland secrets get`, verifies output JSON contains `node_id`, `validator_address`, `p2p_address`. |
| **Validator state** | Checks `priv_validator_state.json` exists, reports current `height` and `round`. |
| **Database** | Verifies `gnoland-data/db` and `gnoland-data/wal` directories exist. |
| **Genesis** | Checks `genesis.json` exists, prints SHA256 checksum. |
| **Config** | Checks `config.toml` exists. |

**Exit codes:**
- `0` — all checks passed
- `1` — at least one critical check failed

**Output:**
- `✅` for successful checks
- `❌` for failed checks

**Run after each deployment step and after any configuration change.**

---

## Variables reference

### group_vars/betanet.yml

Copy from `betanet.yml.example` and populate:

| Variable | Default | Description |
| --- | --- | --- |
| `gno_dir` | `gnoland1` | Working directory under `/root/` on all nodes. |
| `gno_image` | `ghcr.io/gnolang/gno/gnoland:chain-test11` | Gnoland Docker image tag. |
| `otel_image` | `otel/opentelemetry-collector-contrib:latest` | OTEL Collector image. |
| `moniker_validator` | `samourai-crew-1` | Validator node display name. |
| `moniker_sentry` | `samourai-dev-sentry-1` | Sentry node display name. |
| `pex_validator` | `"False"` | Peer exchange on validator. Keep `False` behind sentry. |
| `seeds` | `""` | Bootstrap seed nodes for sentry (provided by gnocore). |
| `private_peer_ids` | `""` | Validator node ID (for sentry to hide validator from peer exchange). |
| `validator_p2p_ip` | `""` | Validator P2P address reachable from sentry. |
| `persistent_peers_sentry` | `""` | Sentry P2P address for validator (`node_id@ip:26656`). |
| `sentry_private_ip` | `""` | Sentry VLAN IP (used by Promtail sentry relay mode). |
| `promtail_job_name` | `{{ moniker_validator }}` | Loki job label for validator logs. |
| `loki_domain` | `""` | Loki FQDN (used by Promtail direct mode). |
| `loki_bearer_token` | `""` | Bearer token for Promtail (direct mode only). Use `ansible-vault`. |
| `gno_use_sentry` | `true` | Deploy validator in sentry mode (`true`) or standalone (`false`). |
| `install_nginx` | `false` | Install NGINX (set `true` for sentry in `1-base_setup.yml`). |
| `container_name` | `gnoland1-validator-1` | Docker container name (used by `backup.sh`). |
| `genesis_url` | S3 URL | URL to download `genesis.json`. |
| `config_url` | GitHub URL | URL to download `config.toml`. |

### group_vars/monitoring.yml

Copy from `monitoring.yml.example` and populate:

| Variable | Default | Description |
| --- | --- | --- |
| `loki_version` | `3.4.2` | Loki Docker image version. |
| `prometheus_version` | `3.1.0` | Prometheus Docker image version. |
| `grafana_version` | `latest` | Grafana Docker image version. |
| `promtail_version` | `3.4.2` | Promtail binary version (must match `loki_version`). |
| `loki_http_port` | `3100` | Loki internal listen port (never exposed directly). |
| `loki_domain` | `""` | FQDN for Loki NGINX vhost (DNS must point to monitoring server). |
| `loki_scheme` | `https` | Protocol: `https` for production, `http` for Vagrant testing. |
| `grafana_domain` | `""` | FQDN for Grafana NGINX vhost. |
| `grafana_admin_password` | `""` | Grafana admin password. Use `ansible-vault`. |
| `prometheus_http_port` | `9090` | Prometheus internal listen port. |
| `prometheus_retention` | `30d` | Prometheus metrics retention period. |
| `prometheus_scrape_jobs` | `[]` | Scrape target list (auto-configured by playbook). |
| `letsencrypt_email` | `""` | Email for Let's Encrypt registration and renewal alerts. |
| `loki_bearer_token` | `""` | Bearer token for NGINX Loki proxy auth. Use `ansible-vault`. |
| `loki_allowed_ips` | `[]` | Sentry public IPs allowed to push to Loki (for loki-proxy). |
| `loki_validator_ips` | `[]` | Validator VLAN IPs allowed through sentry loki-proxy. |
| `loki_retention_hours` | `1440` | Log retention period in hours (default: 60 days). |
| `loki_ingestion_rate_mb` | `32` | Loki ingestion rate limit in MB/s. |
| `loki_ingestion_burst_size_mb` | `64` | Loki ingestion burst size in MB. |

### Sentry inventory variables

Required when using `5b-deploy-validator-proxies.yaml`:

```yaml
gno-sentry:
  validator_proxies:
    - name: validator-1
      private_ip: 172.16.12.2
      node_exporter_port: 9200
      otel_port: 9464
    - name: validator-2
      private_ip: 172.16.12.3
      node_exporter_port: 9201
      otel_port: 9465
```

---

## Security considerations

### Secrets management

- **Never commit** `group_vars/betanet.yml` or `group_vars/monitoring.yml` — add to `.gitignore`
- Encrypt all secrets with `ansible-vault`:
  ```bash
  ansible-vault encrypt group_vars/betanet.yml
  ansible-vault encrypt_string 'token' --name 'loki_bearer_token'
  ```

### Gnoland secrets initialization

Secrets must be initialized manually on each node before playbook deployment. This is intentional — it ensures you have a copy of the node IDs:

```bash
ssh root@<validator-ip>
gnoland secrets init
gnoland secrets get  # save the node_id and p2p_address
```

Secrets are stored in `/root/gnoland1/secrets/` and persisted across playbook re-runs.

### Validator internet isolation

After private network activation, disable validator's internet access while keeping the private VLAN operational:

```bash
ssh root@<validator-ip>

# Disable internet (preserves private VLAN)
ip addr flush dev eno1

# Re-enable (needed for playbook re-runs)
dhclient eno1
```

Full isolation instructions in `/root/Network_control.md` on the validator.

### Loki authentication

- `auth_enabled: false` in Loki config — **security relies entirely on NGINX**
- NGINX layer:
  - IP whitelist (only sentry IPs allowed)
  - Bearer token required in `Authorization: Bearer` header
  - Do not expose port 3100 directly to public internet
- Bearer token in plaintext at `/etc/promtail/config.yml` on validator (direct mode only, mode 0600, root only)

### Monitoring server access

- All services (Loki, Prometheus) listen on `127.0.0.1` (localhost only)
- NGINX handles all public access with TLS and authentication
- UFW restricts metric scraping to monitoring server IP only

### Validator network security

- P2P port (:26656) **never exposed** on validator after private VLAN activation
- Metrics (:9100, :9464) accessed only through sentry proxies
- Logs shipped through sentry relay (sentry injects Bearer token)
- No direct public internet access needed after bootstrapping

---

## Vagrant testing

Test environment configuration in `inventory-vagrant.yaml`:

| Host | IP | Role |
| --- | --- | --- |
| `gno-validator` | 192.168.56.10 | Validator node |
| `gno-sentry` | 192.168.56.11 | Sentry node |
| `gno-monitoring-test` | 192.168.56.12 | Monitoring server |

### Vagrant workflow

```bash
# Start VMs
vagrant up

# Base setup
ansible-playbook -i inventory-vagrant.yaml 1-base_setup.yml -e target=gno-sentry -e install_nginx=true
ansible-playbook -i inventory-vagrant.yaml 1-base_setup.yml -e target=gno-validator

# Manual secrets init (SSH into each VM)
vagrant ssh gno-sentry
gnoland secrets init && gnoland secrets get

vagrant ssh gno-validator
gnoland secrets init && gnoland secrets get

# Deploy nodes (use the node IDs from above)
ansible-playbook -i inventory-vagrant.yaml 2-install-sentry-node.yml -e private_peer_ids=<...> -e validator_p2p_ip=192.168.56.10
ansible-playbook -i inventory-vagrant.yaml 3-install-validator-node.yml -e persistent_peers_sentry=<...>@192.168.56.11:26656

# Deploy monitoring (HTTP only, no TLS)
ansible-playbook -i inventory-vagrant.yaml 5-deploy-monitoring-stack.yaml \
  -e target=gno-monitoring-test \
  -e @group_vars/monitoring.yml \
  --skip-tags tls
```

### Vagrant Grafana access

After `5-deploy-monitoring-stack.yaml`, access Grafana at:
```
http://grafana.192.168.56.12.nip.io
```

Use nip.io subdomains in `monitoring.yml`:
- `grafana_domain: "grafana.192.168.56.12.nip.io"`
- `loki_domain: "loki.192.168.56.12.nip.io"`
- `loki_scheme: "http"` (not `https`)
