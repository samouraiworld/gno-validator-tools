# Deployment Guide

This directory contains all Ansible playbooks and roles to deploy and operate a Gnoland validator node, including optional monitoring (Loki + Promtail) and log backup.

> **OS requirement:** Ubuntu / Debian only.
> **Grafana** is not deployed by these playbooks — configure it separately and point it at your Loki instance.

---

## Table of Contents

1. [Architecture overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Inventory setup](#3-inventory-setup)
4. [Deployment workflow](#4-deployment-workflow)
5. [Playbook reference](#5-playbook-reference)
   - [1 — Base setup](#51-1--base-setup-1-base_setupyml)
   - [2 — Sentry node deployment](#52-2--sentry-node-deployment-2-install-sentry-nodeyml)
   - [3 — Validator node deployment](#53-3--validator-node-deployment-3-install-validator-nodeyml)
   - [4 — Log backup](#54-4--log-backup-4-backup_logsshyaml)
   - [5 — Loki stack](#55-5--loki-stack-5-deploy-lokiyaml)
   - [6 — Promtail — direct mode](#56-6--promtail--direct-mode-6-deploy-promtail-directyaml)
   - [6 — Promtail — sentry relay mode](#57-6--promtail--sentry-relay-mode-6-deploy-promtail-sentryyaml)
   - [7 — Private network setup](#58-7--private-network-setup-7-setup-private-networkyml)
6. [Variables reference](#6-variables-reference)
7. [Security notes](#7-security-notes)

---

## 1. Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│ Validator node (private VLAN)                                   │
│   gnoland (Docker)                                              │
│   OTEL Collector → Prometheus :9464                             │
│   Node Exporter  → :9100                                        │
│   Promtail ──────────────────────────────────────┐             │
└──────────────────────────────┬──────────────────────────────────┘
                               │ P2P (private VLAN)
┌──────────────────────────────▼──────────────────────────────────┐
│ Sentry node (public)                                            │
│   gnoland (Docker) ←──── public P2P :26656                     │
│   Node Exporter    → :9100                                      │
│   NGINX loki-proxy :80 ──────────────────────────┘             │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTPS (injects Bearer token)
┌──────────────────────────────▼──────────────────────────────────┐
│ Monitoring server                                               │
│   Loki :3100 (localhost only)                                   │
│   NGINX :443 → /loki/ (IP whitelist + Bearer token auth)        │
│   ← Grafana (deployed separately, points to Loki)              │
└─────────────────────────────────────────────────────────────────┘
```

**Log shipping — two modes:**

| Mode | Path | Use case |
| --- | --- | --- |
| Sentry relay | Validator → sentry loki-proxy (HTTP, VLAN) → Loki (HTTPS) | Validator has no internet access |
| Direct | Validator → Loki (HTTPS + Bearer token) | Standalone validator with internet access |

---

## 2. Prerequisites

**Control machine (where you run Ansible):**

- Ansible >= 2.14
- Python >= 3.10
- `pip install ansible`

**Target hosts:**

- Ubuntu or Debian
- SSH key-based access as `root`
- `gnoland` binary will be installed by `1-base_setup.yml` (no pre-installation required)
- Internet access required during deployment (private network is activated in a later step)

**DNS:**

- A record for `loki_domain` pointing to your monitoring server (required for Let's Encrypt)

---

## 3. Inventory setup

Add your hosts to `inventory.yaml`. The playbooks expect these exact host names for internal cross-references:

```yaml
all:
  vars:
    ansible_user: root

  children:
    betanet:
      hosts:
        gno-sentry:
          ansible_host: x.x.x.x      # public IP
          private_ip: 172.16.12.4
        gno-validator:
          ansible_host: x.x.x.x      # public IP (for initial deployment access)
          public_ip: x.x.x.x
          private_ip: 172.16.12.2

    monitoring:
      hosts:
        monitoring-server:
          ansible_host: x.x.x.x      # public IP
```

**Required inventory variables:**

Each node must have:

- `ansible_host`: reachable IP for SSH (public IP during initial deployment)
- `public_ip`: node's public IP
- `private_ip`: VLAN IP for node-to-node communication (used after private network activation)

**Copy and configure your group vars:**

```bash
cp group_vars/betanet.yml.example    group_vars/betanet.yml
cp group_vars/monitoring.yml.example group_vars/monitoring.yml
```

> Add both files to `.gitignore` — they will contain real IPs and secrets.

---

## 4. Deployment workflow

### Step 1 — Prepare base system

```bash
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-sentry -e install_nginx=true
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-validator
```

### Step 2 — MANUAL: Initialize gnoland secrets on each node

SSH to each node and run:

```bash
gnoland secrets init
gnoland secrets get   # save the node_id output
```

Exchange node IDs:
- Validator `node_id` → needed for sentry (`private_peer_ids` + `validator_p2p_ip`)
- Retrieve seed(s) from gnocore for the sentry (`seeds` variable)

### Step 3 — Deploy sentry node

```bash
ansible-playbook -i inventory.yaml 2-install-sentry-node.yml \
  -e private_peer_ids=<validator_node_id> \
  -e validator_p2p_ip=<validator_public_ip>
```

### Step 4 — Deploy validator node

```bash
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e persistent_peers_sentry=<sentry_node_id>@<sentry_ip>:26656
```

### Step 5 — Validate nodes are running and connected

```bash
ssh root@<node-ip>
docker logs <container-id>
bash /root/check_status.sh
```

### Step 6 — Deploy log backup scripts

```bash
ansible-playbook -i inventory.yaml 4-backup_logs.sh.yaml
```

### Step 7 — Deploy Loki stack

```bash
ansible-playbook -i inventory.yaml 5-deploy-loki.yaml
```

### Step 8 — Deploy Promtail on validator

```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-direct.yaml   # direct mode
# OR
ansible-playbook -i inventory.yaml 6-deploy-promtail-sentry.yaml   # sentry relay mode
```

### Step 9 — Activate private VLAN

> The `vlan_id` is assigned by your hosting provider when you create a private network (e.g. Scaleway Private Networks). Retrieve it from your provider's console before running this step.

```bash
ansible-playbook -i inventory.yaml 7-setup-private-network.yml -e target=gno-sentry -e vlan_id=<your_vlan_id>
ansible-playbook -i inventory.yaml 7-setup-private-network.yml -e target=gno-validator -e vlan_id=<your_vlan_id>
```

---

## 5. Playbook reference

### 5.1 1 — Base setup (`1-base_setup.yml`)

Prepares the base system for gnoland validator or sentry nodes. Accepts a `target` variable to select which host or group to configure.

```bash
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-sentry -e install_nginx=true
ansible-playbook -i inventory.yaml 1-base_setup.yml -e target=gno-validator
```

**Roles applied to all targets:**

| Role | What it does |
| --- | --- |
| `roles/base_setup` | `apt` packages, shell aliases |
| `roles/node_exporter` | Prometheus Node Exporter (port 9100) |
| `roles/docker` | Docker Engine + Compose v2 |
| `roles/ufw` | UFW firewall rules |
| `roles/gnoland` | Go 1.25.0 + builds `gnoland` binary from source |

**Roles applied when `install_nginx=true` (sentry):**

| Role | What it does |
| --- | --- |
| `roles/nginx` | NGINX reverse proxy (for loki-proxy, monitoring dashboards) |

---

### 5.2 2 — Sentry node deployment (`2-install-sentry-node.yml`)

Deploys the gnoland sentry node via Docker Compose. Assumes `1-base_setup.yml` has completed and secrets have been initialized manually on the validator.

**Prerequisites:**

- `1-base_setup.yml` run on sentry
- Secrets initialized on validator: `gnoland secrets init` + `gnoland secrets get`
- `genesis.json` and `config.toml` URLs configured via vars

**Key variables:**

| Variable | Description |
| --- | --- |
| `private_peer_ids` | Validator node ID (from `gnoland secrets get`) |
| `validator_p2p_ip` | Validator IP reachable from sentry |
| `seeds` | Seed node(s) provided by gnocore |

```bash
ansible-playbook -i inventory.yaml 2-install-sentry-node.yml \
  -e private_peer_ids=<validator_node_id> \
  -e validator_p2p_ip=<validator_ip>
```

Available tags: `config`, `docker`, `compose`.

---

### 5.3 3 — Validator node deployment (`3-install-validator-node.yml`)

Deploys the gnoland validator node via Docker Compose. Assumes `1-base_setup.yml` has completed and secrets have been initialized manually.

**Prerequisites:**

- `1-base_setup.yml` run on validator
- Secrets initialized: `gnoland secrets init` + `gnoland secrets get`
- Sentry node ID and IP available

**Key variables:**

| Variable | Description |
| --- | --- |
| `persistent_peers_sentry` | Sentry p2p address (`node_id@ip:26656`) |
| `gno_use_sentry` | `true` to use sentry mode (default), `false` for standalone |

```bash
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e persistent_peers_sentry=<sentry_node_id>@<sentry_ip>:26656
```

Available tags: `config`, `docker`, `compose`.

> `Network_control.md` is deployed to `/root/Network_control.md` — see section 7 for internet access control on the validator.

---

### 5.4 4 — Log backup (`4-backup_logs.sh.yaml`)

Deploys log backup and rotation scripts via cron (runs daily at 00:10):

- **Validator**: `backup.sh` — extracts last 24h of gnoland Docker logs, compresses with `xz`, copies to sentry via SCP.
- **Sentry**: `rotate.sh` — enforces 30-day retention on the backup directory.

Generates an SSH key pair on the validator and authorizes it on the sentry automatically.

```bash
ansible-playbook -i inventory.yaml 4-backup_logs.sh.yaml
```

Scripts are installed to `{{ backup_dir }}` (default: `/opt/backup_logs`).

---

### 5.5 5 — Loki stack (`5-deploy-loki.yaml`)

Two-play playbook. Deploys the full Loki log aggregation stack.

**Play 1 — monitoring server:**

- Downloads Loki binary (v`{{ loki_version }}`) to `/opt/loki/`
- Creates `loki` system user and `/var/lib/loki/` data directories
- Deploys `/etc/loki/config.yml` from template
- Creates `loki.service` systemd unit
- Deploys NGINX vhost with IP whitelist + Bearer token authentication
- Requests Let's Encrypt TLS certificate for `{{ loki_domain }}`

**Play 2 — sentry:**

- Deploys `loki-proxy` NGINX vhost on port 80
- Accepts log push from validator VLAN IPs only
- Injects the Bearer token before forwarding to Loki — **validators never need the token**

```bash
ansible-playbook -i inventory.yaml 5-deploy-loki.yaml
```

**Prerequisites:**

- `group_vars/monitoring.yml` configured with `loki_domain`, `loki_bearer_token`, `loki_allowed_ips`
- Domain DNS record pointing to monitoring server
- NGINX installed on sentry (`1-base_setup.yml -e install_nginx=true` run first)

---

### 5.6 6 — Promtail — direct mode (`6-deploy-promtail-direct.yaml`)

Deploys Promtail on the validator. Logs are pushed directly to Loki over HTTPS using the Bearer token.

```
Validator → https://{{ loki_domain }}/loki/api/v1/push (Bearer token) → Loki
```

**Prerequisites:**

- `5-deploy-loki.yaml` run first
- `loki_domain` and `loki_bearer_token` set in `group_vars/betanet.yml`
- Validator has outbound internet access on port 443

```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-direct.yaml
```

> The Bearer token is written to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Encrypt it with `ansible-vault` before committing to version control.

---

### 5.7 6 — Promtail — sentry relay mode (`6-deploy-promtail-sentry.yaml`)

Deploys Promtail on the validator. Logs are pushed to the sentry's loki-proxy over the private VLAN (HTTP, no auth on the validator side — the sentry injects the token).

```
Validator → http://{{ sentry_private_ip }}/loki/api/v1/push
         → sentry loki-proxy (injects Bearer token)
         → https://{{ loki_domain }}/loki/api/v1/push → Loki
```

**Prerequisites:**

- `5-deploy-loki.yaml` run first (loki-proxy must be active on sentry)
- `sentry_private_ip` set in `group_vars/betanet.yml`

```bash
ansible-playbook -i inventory.yaml 6-deploy-promtail-sentry.yaml
```

> If the private network is already activated on the validator, use `gno_network_mode=private` with `gno_sentry_ip` and `gno_validator_private_ip` to connect via SSH jump through the sentry.

---

### 5.8 7 — Private network setup (`7-setup-private-network.yml`)

Configures private VLAN network interfaces for validator and sentry nodes. **Run this after** all nodes are running and connected.

**Parameters:**

- `target`: host or group to target (required)
- `vlan_id`: VLAN identifier (default: `1938`)
- `private_ip`: static IP for the VLAN interface (must be set in inventory)

```bash
ansible-playbook -i inventory.yaml 7-setup-private-network.yml -e target=gno-sentry -e vlan_id=1938
ansible-playbook -i inventory.yaml 7-setup-private-network.yml -e target=gno-validator -e vlan_id=2772
```

---

## 6. Variables reference

### Betanet (`group_vars/betanet.yml`)

| Variable | Default | Description |
| --- | --- | --- |
| `gno_dir` | `gnoland1` | Working directory under `/root/` on remote hosts. |
| `gno_image` | `ghcr.io/gnolang/gno/gnoland:chain-test11` | Gnoland Docker image. |
| `otel_image` | `otel/opentelemetry-collector-contrib:latest` | OTEL Collector image. |
| `moniker_validator` | `samourai-crew-1` | Validator node moniker. |
| `moniker_sentry` | `samourai-dev-sentry-1` | Sentry node moniker. |
| `pex_validator` | `"False"` | Peer Exchange on validator. Keep `"False"` behind a sentry. |
| `seeds` | `""` | Seed nodes for sentry P2P bootstrap (provided by gnocore). |
| `private_peer_ids` | `""` | Validator node ID — used by sentry to hide it from peer exchange. |
| `validator_p2p_ip` | `""` | Validator IP reachable from sentry (for PERSISTENT_PEERS). |
| `persistent_peers_sentry` | `""` | Sentry p2p address used by validator (`node_id@ip:26656`). |
| `install_nginx` | `false` | Install NGINX role (pass `true` for sentry in `1-base_setup.yml`). |
| `container_name` | `gnoland1-validator-1` | Docker container name on validator (used by `backup.sh`). |
| `genesis_url` | S3 URL | URL to download `genesis.json`. |
| `config_url` | GitHub URL | URL to download `config.toml`. |
| `sentry_private_ip` | `""` | Sentry VLAN IP — used by Promtail in sentry relay mode. |
| `promtail_job_name` | `{{ moniker_validator }}` | Loki job label for validator logs. |
| `loki_domain` | `""` | Loki domain — used by Promtail in direct mode. |
| `loki_bearer_token` | `""` | Bearer token — direct mode only. Encrypt with `ansible-vault`. |

### Monitoring (`group_vars/monitoring.yml`)

| Variable | Default | Description |
| --- | --- | --- |
| `loki_version` | `3.4.2` | Loki binary version to install. |
| `promtail_version` | `3.4.2` | Promtail binary version to install. Must match `loki_version`. |
| `loki_http_port` | `3100` | Loki local listen port. Never exposed directly. |
| `loki_domain` | `""` | FQDN for the Loki NGINX vhost. DNS must point to this server. |
| `letsencrypt_email` | `""` | Email for Let's Encrypt registration and renewal alerts. |
| `loki_bearer_token` | `""` | Bearer token for push authentication. Encrypt with `ansible-vault`. |
| `loki_allowed_ips` | `[]` | Public IPs allowed to push to `/loki/` (sentry IPs). |
| `loki_validator_ips` | `[]` | VLAN IPs allowed through loki-proxy (validator IPs). |
| `loki_retention_hours` | `1440` | Log retention in hours (default: 60 days). |

---

## 7. Security notes

- **Never commit** `group_vars/betanet.yml` or `group_vars/monitoring.yml` — add both to `.gitignore`.

- **Gnoland secrets initialization:** Secrets must be generated manually via SSH before playbook deployment. **This is intentional** — it ensures you have a copy of the node IDs for exchange between validator and sentry:

  ```bash
  ssh root@<node-ip>
  gnoland secrets init
  gnoland secrets get  # save validator node ID for sentry config
  ```

  Once initialized, `/root/gnoland1/secrets/` will be preserved across playbook re-runs.

- **Validator internet access control:** The validator has internet access during initial deployment. After private network activation (`7-setup-private-network.yml`), you can isolate it from the public internet without breaking the private VLAN. See `/root/Network_control.md` on the validator:

  ```bash
  # Disable internet access (keeps private VLAN operational)
  ip addr flush dev eno1

  # Re-enable internet access (e.g. for playbook re-run)
  dhclient eno1
  ```

- Encrypt secrets with `ansible-vault`:

  ```bash
  ansible-vault encrypt_string 'your-token-here' --name 'loki_bearer_token'
  ansible-vault encrypt group_vars/monitoring.yml
  ```

- In production, the validator should never be reachable directly from the public internet — use `7-setup-private-network.yml` to restrict validator↔sentry communication to the private VLAN.
- Loki's `auth_enabled: false` means security relies entirely on NGINX (IP whitelist + Bearer token). Do not expose port 3100 directly.
- The Bearer token is written in plaintext to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Rotate it periodically.
