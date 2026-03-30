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
   - [Base setup](#51-base-setup)
   - [Node deployment](#52-node-deployment-upload-betanet-deploymentyaml)
   - [Log backup](#53-log-backup-backup_logsshyaml)
   - [Loki stack](#54-loki-stack-deploy-lokiyaml)
   - [Promtail — sentry relay mode](#55-promtail--sentry-relay-mode-deploy-promtail-sentryyaml)
   - [Promtail — direct mode](#56-promtail--direct-mode-deploy-promtail-directyaml)
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
- `gnoland` binary in `PATH` — installed by the `gnoland` role or `base_setup_validator.yaml`

**DNS:**
- A record for `loki_domain` pointing to your monitoring server (required for Let's Encrypt)

---

## 3. Inventory setup

Add your hosts to `inventory.yaml`. The playbooks expect these exact host names for internal `hostvars` cross-references:

```yaml
all:
  vars:
    ansible_user: root

  children:
    # Validator and sentry — used by upload-betanet-deployment.yaml
    betanet:
      hosts:
        gno-sentry:
          ansible_host: 51.159.14.234      # public IP
          private_ip: 172.16.12.4
        gno-validator:
          ansible_host: 10.0.0.2           # private VLAN IP (set by pre_tasks)
          public_ip: 51.159.14.235
          private_ip: 172.16.12.2

    # Monitoring server — used by deploy-loki.yaml
    monitoring:
      hosts:
        monitoring-server:
          ansible_host: ""                 # fill in: public IP
```

**Copy and configure your group vars:**

```bash
cp deployment/group_vars/betanet.yml.example    deployment/group_vars/betanet.yml
cp deployment/group_vars/monitoring.yml.example deployment/group_vars/monitoring.yml
```

> Add both files to `.gitignore` — they will contain real IPs and secrets.

---

## 4. Deployment workflow

Run playbooks in this order on a fresh infrastructure:

```bash
# Step 1 — Prepare base system on sentry and validator
ansible-playbook -i inventory.yaml deployment/base_setup_sentry.yaml    -e target=gno-sentry
ansible-playbook -i inventory.yaml deployment/base_setup_validator.yaml  -e target=gno-validator

# Step 2 — Deploy validator and sentry nodes (first run: generate secrets)
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml \
  -e gno_secrets_init=true

# Step 3 — Deploy log backup scripts (optional)
ansible-playbook -i inventory.yaml deployment/backup_logs.sh.yaml

# Step 4 — Deploy Loki on monitoring server + loki-proxy on sentry (optional)
ansible-playbook -i inventory.yaml deployment/deploy-loki.yaml

# Step 5 — Deploy Promtail on validator (choose one mode)
ansible-playbook -i inventory.yaml deployment/deploy-promtail-sentry.yaml  # sentry relay mode
ansible-playbook -i inventory.yaml deployment/deploy-promtail-direct.yaml  # direct mode
```

**Re-deploy without resetting secrets:**

```bash
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml
# gno_secrets_init defaults to false — existing keys are preserved
```

---

## 5. Playbook reference

### 5.1 Base setup

| Playbook | Target | Purpose |
| --- | --- | --- |
| `base_setup_validator.yaml` | `{{ target }}` | Installs base packages, Docker, UFW, Node Exporter, gnoland binary, configures private VLAN interface |
| `base_setup_sentry.yaml` | `{{ target }}` | Same as validator + NGINX for reverse proxy |

Both playbooks accept a `target` variable to select which host or group to configure:

```bash
ansible-playbook -i inventory.yaml deployment/base_setup_validator.yaml -e target=gno-validator
ansible-playbook -i inventory.yaml deployment/base_setup_sentry.yaml    -e target=gno-sentry
```

**Roles applied:**

| Role | What it does |
| --- | --- |
| `roles/base_setup` | `apt` packages, shell aliases |
| `roles/docker` | Docker Engine + Compose v2 |
| `roles/gnoland` | Go 1.25.0 + builds `gnoland` binary from source |
| `roles/ufw` | UFW firewall rules |
| `roles/node_exporter` | Prometheus Node Exporter (port 9100) |
| `roles/nginx` | NGINX reverse proxy (sentry only) |

---

### 5.2 Node deployment (`upload-betanet-deployment.yaml`)

Deploys gnoland validator and sentry via Docker Compose. Two-play structure:
- **Play 1** (`gno-sentry`): skipped when `gno_use_sentry: false`
- **Play 2** (`gno-validator`): always runs

#### Deployment modes

| `gno_network_mode` | `gno_use_sentry` | Description |
| --- | --- | --- |
| `private` | `true` | Validator on private VLAN, SSH jump through sentry. **Recommended for production.** |
| `public` | `false` | Standalone validator, public IP, no sentry. |
| `public` | `true` | Validator reachable publicly, sentry for peer management. |

#### Secrets management

Controlled by `gno_secrets_init`:

- `false` (default): existing secrets are preserved. Fails with a clear error if `/root/<gno_dir>/secrets` is missing — restore your secrets before re-running.
- `true`: runs `gnoland secrets init`. **Resets the validator identity — the existing key is permanently lost.** Use only on first deployment or intentional key rotation. Set back to `false` immediately after.

#### Docker image transfer

Controlled by `gno_validator_has_internet`:

- `false` (default): images pulled on the control machine, saved as `.tar`, transferred to the host. Requires Docker Engine on the control machine.
- `true`: `docker pull` runs directly on the target host. Requires outbound internet access.

#### Usage

```bash
# First deployment — private network, airgapped validator
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml \
  -e gno_secrets_init=true

# Re-deploy — preserve secrets, validator has internet
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml \
  -e gno_validator_has_internet=true

# Standalone validator — public IP, no sentry
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml \
  -e gno_use_sentry=false \
  -e gno_network_mode=public \
  -e gno_extra_persistent_peers="<nodeid>@<host>:26656"

# Run specific steps only
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml --tags secrets
ansible-playbook -i inventory.yaml deployment/upload-betanet-deployment.yaml --tags compose
```

Available tags: `secrets`, `config`, `docker`, `compose`.

---

### 5.3 Log backup (`backup_logs.sh.yaml`)

Deploys log backup and rotation scripts via cron (runs daily at 00:10):

- **Validator**: `backup.sh` — extracts last 24h of gnoland Docker logs, compresses with `xz`, copies to sentry via SCP.
- **Sentry**: `rotate.sh` — enforces 30-day retention on the backup directory.

```bash
ansible-playbook -i inventory.yaml deployment/backup_logs.sh.yaml
```

Scripts are installed to `{{ backup_dir }}` (default: `/opt/backup_logs`).

---

### 5.4 Loki stack (`deploy-loki.yaml`)

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
ansible-playbook -i inventory.yaml deployment/deploy-loki.yaml

# Loki server only
ansible-playbook -i inventory.yaml deployment/deploy-loki.yaml --tags loki

# loki-proxy on sentry only
ansible-playbook -i inventory.yaml deployment/deploy-loki.yaml --tags proxy
```

**Prerequisites:**
- `group_vars/monitoring.yml` configured with `loki_domain`, `loki_bearer_token`, `loki_allowed_ips`
- Domain DNS record pointing to monitoring server
- NGINX installed on monitoring server (`base_setup` or the `nginx` role)
- NGINX installed on sentry (`base_setup_sentry.yaml` run first)

**Grafana:** not deployed by this playbook. Install Grafana separately and add a Loki data source pointing to `http://localhost:3100` (if co-located) or `https://{{ loki_domain }}/loki`.

---

### 5.5 Promtail — sentry relay mode (`deploy-promtail-sentry.yaml`)

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
ansible-playbook -i inventory.yaml deployment/deploy-promtail-sentry.yaml

# Target a specific validator
ansible-playbook -i inventory.yaml deployment/deploy-promtail-sentry.yaml \
  -e target=gno-validator-1
```

Scraped logs:
- `/var/lib/docker/containers/*/*.log` — gnoland container logs (label: `job: {{ promtail_job_name }}`)
- `/var/log/syslog` — system logs

---

### 5.6 Promtail — direct mode (`deploy-promtail-direct.yaml`)

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
ansible-playbook -i inventory.yaml deployment/deploy-promtail-direct.yaml

# Target a specific validator
ansible-playbook -i inventory.yaml deployment/deploy-promtail-direct.yaml \
  -e target=gno-validator-1
```

> The Bearer token is written to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Encrypt it with `ansible-vault` before committing to version control.

---

## 6. Variables reference

### Betanet (`group_vars/betanet.yml`)

| Variable | Default | Description |
| --- | --- | --- |
| `gno_secrets_init` | `false` | `true` = generate new secrets (destructive). First deploy only. |
| `gno_use_sentry` | `true` | `false` = standalone validator, no sentry play. |
| `gno_network_mode` | `private` | `private` = SSH jump + VLAN. `public` = direct SSH. |
| `gno_validator_has_internet` | `false` | `false` = tar transfer. `true` = `docker pull` on target. |
| `gno_validator_private_ip` | `""` | Validator private VLAN IP. Required when `private`. |
| `gno_validator_public_ip` | `""` | Validator public IP. Required when `public`. |
| `gno_sentry_ip` | `""` | Sentry public IP (SSH jump host). |
| `gno_extra_persistent_peers` | `""` | Peers for standalone mode. |
| `gno_dir` | `gnoland1` | Working directory under `/root/` on remote hosts. |
| `gno_image` | `ghcr.io/gnolang/gno/gnoland:chain-gnoland1` | Gnoland Docker image. |
| `otel_image` | `otel/opentelemetry-collector-contrib:latest` | OTEL Collector image. |
| `moniker_validator` | `samourai-crew-1` | Validator node moniker. |
| `moniker_sentry` | `samourai-dev-sentry-1` | Sentry node moniker. |
| `pex_validator` | `"False"` | Peer Exchange on validator. Keep `"False"` behind a sentry. |
| `seeds` | `""` | Seed nodes for sentry P2P bootstrap. |
| `persistent_peers_sentry` | `""` | Persistent peers for sentry. |
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
- Encrypt secrets with `ansible-vault`:
  ```bash
  # Encrypt the bearer token inline
  ansible-vault encrypt_string 'your-token-here' --name 'loki_bearer_token'

  # Encrypt an entire vars file
  ansible-vault encrypt group_vars/monitoring.yml
  ```
- `gno_secrets_init: true` **permanently destroys** the existing validator key. Set it back to `false` immediately after the first successful deployment.
- In production, always use `gno_network_mode: private` with `gno_use_sentry: true` — the validator should never be reachable directly from the public internet.
- Loki's `auth_enabled: false` means security relies entirely on NGINX (IP whitelist + Bearer token). Do not expose port 3100 directly.
- The Bearer token is written in plaintext to `/etc/promtail/config.yml` on the validator (mode `0600`, root only). Rotate it periodically.
