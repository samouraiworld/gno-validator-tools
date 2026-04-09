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
   - [Base setup](#51-base-setupyml)
   - [Sentry node deployment](#52-sentry-node-deployment-install-sentry-nodeyml)
   - [Validator node deployment](#53-validator-node-deployment-install-validator-nodeyml)
   - [Private network setup](#54-private-network-setup-setup-private-networkyml)
   - [Log backup](#55-log-backup-backup_logsshyaml)
   - [Loki stack](#56-loki-stack-deploy-lokiyaml)
   - [Promtail — sentry relay mode](#57-promtail--sentry-relay-mode-deploy-promtail-sentryyaml)
   - [Promtail — direct mode](#58-promtail--direct-mode-deploy-promtail-directyaml)
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
- Docker Engine (required when `gno_validator_has_internet: false` — images are pulled locally and transferred as `.tar`)

**Target hosts:**

- Ubuntu or Debian
- SSH key-based access as `root`
- `gnoland` binary will be installed by `base_setup.yml` (no pre-installation required)

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
          ansible_host: x.x.x.x           # public IP (for base_setup access)
          public_ip: x.x.x.x
          private_ip: 172.16.12.2

    monitoring:
      hosts:
        monitoring-server:
          ansible_host: x.x.x.x            # public IP
```

**Required inventory variables:**

Each node must have:

- `ansible_host`: reachable IP for SSH (public or jump host)
- `public_ip`: node's public IP
- `private_ip`: VLAN IP for node-to-node communication

**Copy and configure your group vars:**

```bash
cp group_vars/betanet.yml.example    group_vars/betanet.yml
cp group_vars/monitoring.yml.example group_vars/monitoring.yml
```

> Add both files to `.gitignore` — they will contain real IPs and secrets.

---

## 4. Deployment workflow

Run playbooks in this order on a fresh infrastructure:

```bash
# Step 1 — Prepare base system on sentry and validator
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator

# Step 2 — MANUAL: Initialize gnoland secrets on each node
# SSH to each node and run:
#   ssh root@<sentry-ip>
#   cd /root/gnoland1
#   gnoland secrets init
#   gnoland secrets get
#
# Exchange node IDs: save the validator node ID for use in step 3

# Step 3 — Deploy sentry and validator nodes
ansible-playbook -i inventory.yaml install-sentry-node.yml
ansible-playbook -i inventory.yaml install-validator-node.yml

# Step 4 — Validate nodes are running and connected
#   docker logs <container-id>
#   gnoland status

# Step 5 — Configure private VLAN interfaces (after validating nodes)
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-sentry -e vlan_id=1938
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-validator -e vlan_id=2772

# Step 6 — Deploy log backup scripts (optional)
ansible-playbook -i inventory.yaml backup_logs.sh.yaml

# Step 7 — Deploy Loki on monitoring server + loki-proxy on sentry (optional)
ansible-playbook -i inventory.yaml deploy-loki.yaml

# Step 8 — Deploy Promtail on validator (choose one mode)
ansible-playbook -i inventory.yaml deploy-promtail-sentry.yaml  # sentry relay mode
ansible-playbook -i inventory.yaml deploy-promtail-direct.yaml  # direct mode
```

---

## 5. Playbook reference

### 5.1 Base setup (`base_setup.yml`)

Prepares the base system for gnoland validator or sentry nodes. Accepts a `target` variable to select which host or group to configure:

```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

**Roles applied to all targets:**

| Role | What it does |
| --- | --- |
| `roles/base_setup` | `apt` packages, shell aliases |
| `roles/node_exporter` | Prometheus Node Exporter (port 9100) |
| `roles/docker` | Docker Engine + Compose v2 |
| `roles/ufw` | UFW firewall rules |
| `roles/gnoland` | Go 1.25.0 + builds `gnoland` binary from source |

**Roles applied to sentry only:**

| Role | What it does |
| --- | --- |
| `roles/nginx` | NGINX reverse proxy (for loki-proxy, monitoring dashboards) |

**Post-deployment manual step:**

After `base_setup.yml` completes, SSH to each node and initialize secrets:

```bash
ssh root@<sentry-ip>
cd /root/gnoland1
gnoland secrets init
gnoland secrets get  # save the output for later
```

---

### 5.2 Sentry node deployment (`install-sentry-node.yml`)

Deploys the gnoland sentry node via Docker Compose. Assumes `base_setup.yml` has completed and secrets have been initialized manually.

**Prerequisites:**

- `base_setup.yml` run on sentry
- Secrets initialized: `gnoland secrets init` run on sentry
- `genesis.json` and `config.toml` URLs available (configured via vars)

**Tasks:**

- Downloads `genesis.json` and `config.toml` from configured URLs
- Validates genesis.json
- Deploys docker-compose stack for sentry
- Starts gnoland sentry container

**Usage:**

```bash
# Deploy sentry node
ansible-playbook -i inventory.yaml install-sentry-node.yml

# Specific tags
ansible-playbook -i inventory.yaml install-sentry-node.yml --tags config
ansible-playbook -i inventory.yaml install-sentry-node.yml --tags docker
ansible-playbook -i inventory.yaml install-sentry-node.yml --tags compose
```

Available tags: `config`, `docker`, `compose`.

---

### 5.3 Validator node deployment (`install-validator-node.yml`)

Deploys the gnoland validator node via Docker Compose. Assumes `base_setup.yml` has completed and secrets have been initialized manually.

**Prerequisites:**

- `base_setup.yml` run on validator
- Secrets initialized: `gnoland secrets init` run on validator
- Validator node ID retrieved and stored for sentry configuration
- `genesis.json` and `config.toml` URLs available (configured via vars)

**Tasks:**

- Downloads `genesis.json` and `config.toml` from configured URLs
- Validates genesis.json
- Deploys docker-compose stack for validator
- Starts gnoland validator container

**Usage:**

```bash
# Deploy validator node
ansible-playbook -i inventory.yaml install-validator-node.yml

# Specific tags
ansible-playbook -i inventory.yaml install-validator-node.yml --tags config
ansible-playbook -i inventory.yaml install-validator-node.yml --tags docker
ansible-playbook -i inventory.yaml install-validator-node.yml --tags compose
```

Available tags: `config`, `docker`, `compose`.

---

### 5.4 Private network setup (`setup-private-network.yml`)

Configures private VLAN network interfaces for validator and sentry nodes after successful deployment and validation. **Run this after** all nodes are running and connected.

**Parameters:**

- `target`: host or group to target (required)
- `vlan_id`: VLAN identifier (default: `1938`)
- `private_ip`: static IP for the VLAN interface (must be set in inventory)

**Usage:**

```bash
# Configure sentry VLAN interface
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-sentry -e vlan_id=1938

# Configure validator VLAN interface
ansible-playbook -i inventory.yaml setup-private-network.yml -e target=gno-validator -e vlan_id=2772
```

**What it does:**

- Creates VLAN subinterface: `eno1.<vlan_id>`
- Assigns static IP: `{{ private_ip }}`
- Subnet: `255.255.252.0`
- Brings up the interface

---

### 5.5 Log backup (`backup_logs.sh.yaml`)

Deploys log backup and rotation scripts via cron (runs daily at 00:10):

- **Validator**: `backup.sh` — extracts last 24h of gnoland Docker logs, compresses with `xz`, copies to sentry via SCP.
- **Sentry**: `rotate.sh` — enforces 30-day retention on the backup directory.

```bash
ansible-playbook -i inventory.yaml backup_logs.sh.yaml
```

Scripts are installed to `{{ backup_dir }}` (default: `/opt/backup_logs`).

---

### 5.6 Loki stack (`deploy-loki.yaml`)

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
# Full deploy
ansible-playbook -i inventory.yaml deploy-loki.yaml

# Loki server only
ansible-playbook -i inventory.yaml deploy-loki.yaml --tags loki

# loki-proxy on sentry only
ansible-playbook -i inventory.yaml deploy-loki.yaml --tags proxy
```

**Prerequisites:**

- `group_vars/monitoring.yml` configured with `loki_domain`, `loki_bearer_token`, `loki_allowed_ips`
- Domain DNS record pointing to monitoring server
- NGINX installed on monitoring server (`base_setup.yml` or the `nginx` role)
- NGINX installed on sentry (`base_setup.yml` run first)

**Grafana:** not deployed by this playbook. Install Grafana separately and add a Loki data source pointing to `http://localhost:3100` (if co-located) or `https://{{ loki_domain }}/loki`.

---

### 5.7 Promtail — sentry relay mode (`deploy-promtail-sentry.yaml`)

Deploys Promtail on the validator. Logs are pushed to the sentry's loki-proxy over the private VLAN (HTTP, no auth on the validator side — the sentry injects the token).

```
Validator → http://{{ sentry_private_ip }}/loki/api/v1/push
         → sentry loki-proxy (injects Bearer token)
         → https://{{ loki_domain }}/loki/api/v1/push
         → Loki
```

**Prerequisites:**

- `deploy-loki.yaml` run first (loki-proxy must be active on sentry)
- `sentry_private_ip` set in `group_vars/betanet.yml`

```bash
ansible-playbook -i inventory.yaml deploy-promtail-sentry.yaml

# Target a specific validator
ansible-playbook -i inventory.yaml deploy-promtail-sentry.yaml \
  -e target=gno-validator-1
```

Scraped logs:

- `/var/lib/docker/containers/*/*.log` — gnoland container logs (label: `job: {{ promtail_job_name }}`)
- `/var/log/syslog` — system logs

---

### 5.8 Promtail — direct mode (`deploy-promtail-direct.yaml`)

Deploys Promtail on the validator. Logs are pushed directly to Loki over HTTPS using the Bearer token. Use this when the validator has direct internet access and no sentry.

```
Validator → https://{{ loki_domain }}/loki/api/v1/push (Bearer token)
         → Loki
```

**Prerequisites:**

- `deploy-loki.yaml` run first
- `loki_domain` and `loki_bearer_token` set in `group_vars/betanet.yml`
- Validator has outbound internet access on port 443

```bash
ansible-playbook -i inventory.yaml deploy-promtail-direct.yaml

# Target a specific validator
ansible-playbook -i inventory.yaml deploy-promtail-direct.yaml \
  -e target=gno-validator-1
```

> The Bearer token is written to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Encrypt it with `ansible-vault` before committing to version control.

---

## 6. Variables reference

### Betanet (`group_vars/betanet.yml`)

| Variable | Default | Description |
| --- | --- | --- |
| `gno_dir` | `gnoland1` | Working directory under `/root/` on remote hosts. |
| `gno_image` | `ghcr.io/gnolang/gno/gnoland:chain-gnoland1` | Gnoland Docker image. |
| `otel_image` | `otel/opentelemetry-collector-contrib:latest` | OTEL Collector image. |
| `moniker_validator` | `samourai-crew-1` | Validator node moniker. |
| `moniker_sentry` | `samourai-dev-sentry-1` | Sentry node moniker. |
| `pex_validator` | `"False"` | Peer Exchange on validator. Keep `"False"` behind a sentry. |
| `seeds` | `""` | Seed nodes for sentry P2P bootstrap. |
| `persistent_peers_sentry` | `""` | Persistent peers for sentry. |
| `private_peer_ids` | `""` | Peer IDs to hide from peer exchange (sentry). |
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
  cd /root/gnoland1
  gnoland secrets init
  gnoland secrets get  # save validator node ID for sentry config
  ```

  Once initialized, `/root/gnoland1/secrets/` will be preserved across playbook re-runs.

- Encrypt secrets with `ansible-vault`:

  ```bash
  # Encrypt the bearer token inline
  ansible-vault encrypt_string 'your-token-here' --name 'loki_bearer_token'

  # Encrypt an entire vars file
  ansible-vault encrypt group_vars/monitoring.yml
  ```

- In production, the validator should never be reachable directly from the public internet — use `setup-private-network.yml` to restrict validator↔sentry communication to the private VLAN.
- Loki's `auth_enabled: false` means security relies entirely on NGINX (IP whitelist + Bearer token). Do not expose port 3100 directly.
- The Bearer token is written in plaintext to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Rotate it periodically.
