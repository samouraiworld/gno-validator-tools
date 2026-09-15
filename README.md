# Gnoland Validator & Sentry Node Deployment

Infrastructure-as-Code to prepare Gnoland validator/sentry servers with
Docker, Alloy (logs + metrics) and UFW. Ansible only manages the **server
foundation**; deploying the gnoland nodes themselves (docker-compose,
`entrypoint.sh`, `config.toml`, `genesis.json`) is done by hand, described in
a dedicated runbook.

**Target environment:** Ubuntu or Debian (tested on Scaleway).

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
│ Validator Node (private VLAN)              │     │ Sentry Node (public)                       │
│                                             │     │                                             │
│   gnoland (Docker) ── private P2P :26656 ──┼─────┼──► gnoland (Docker) ◄── public P2P :26656   │
│   otel-collector → 127.0.0.1:9464          │     │   node_exporter  → 127.0.0.1:9100           │
│   node_exporter  → 127.0.0.1:9100          │     │                                             │
│   Alloy: local scrape + push (relay/direct)│     │   Alloy: local scrape + push (direct)       │
└───────────────────┬─────────────────────────┘   └───────────────────┬─────────────────────────┘
                    │                                                   │
                    └── Docker logs + metrics (remote_write) ───────────┘
                                          │
                               MANUAL reverse proxy
                            (out of Ansible scope —
                          see NETWORK_AND_REVERSE_PROXY.md)
                                          │
                                          ▼
                          Logs + metrics backend (VictoriaMetrics
                          remote_write, or equivalent — not deployed
                          by this repo)
```

Ansible no longer deploys any reverse proxy, TLS, or monitoring stack
(Loki/Prometheus/Grafana): see [`legacy/`](legacy/README.md) for what was
removed and why, and [`NETWORK_AND_REVERSE_PROXY.md`](NETWORK_AND_REVERSE_PROXY.md)
for the manual private VLAN and reverse proxy setup.

### Data flows

**Logs and metrics:** Grafana Alloy (`alloy` role, included in
`base_setup.yml`) scrapes `node_exporter`/`otel-collector` locally (bound to
`127.0.0.1`, never exposed) and the gnoland containers' Docker logs, then
pushes everything via remote_write/push:

- **`direct` mode** — pushes straight to the backend, with its own bearer
  token (typically the sentry, which has direct Internet egress);
- **`relay` mode** — pushes to a reverse proxy set up by hand on the sentry
  (typically the validator, isolated on the private VLAN), which then relays
  to the backend and alone holds the bearer token.

No inbound scrape port is needed: no more Prometheus pulling metrics, no
more Promtail, no more per-validator NGINX vhost.

---

## Prerequisites

### Control machine (where Ansible runs)

- Ansible >= 2.14
- Python >= 3.10
- Install: `pip install ansible`

### Target hosts (validator, sentry)

- Ubuntu 22.04 LTS or Debian 12+
- Key-based SSH access as `root`
- Internet access during deployment (private network isolation comes in a
  later step, see `NETWORK_AND_REVERSE_PROXY.md`)

---

## Inventory setup

```bash
cp inventory.yaml.example inventory.yaml
# edit inventory.yaml: IPs, ufw_ports_app, alloy_*/tmkms_* variables as needed
```

`inventory.yaml` is gitignored — it holds real IPs and possibly tokens. See
`inventory.yaml.example` for the variable details (`alloy_*`, `ufw_*`,
`tmkms_*`).

---

## Deployment workflow

### Step 1 — Server foundation

```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

Installs: system packages + shell aliases (`base_setup`), Docker Engine +
Compose v2 (`docker`), Go 1.25.0 + gnoland binary built from source
(`gnoland`), UFW firewall (`ufw`), Node Exporter on `127.0.0.1:9100`
(`node_exporter`), Grafana Alloy — local scrape + push logs/metrics
(`alloy`).

Deploys **no** application docker-compose, no reverse proxy, no secret.

### Step 2 — Manual gnoland node deployment

See **[`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md)** for the full
procedure: secrets initialization (`gnoland secrets init`, never done by
Ansible), picking one of the topologies in [`compose/`](#docker-compose-targets),
pushing the stable files (`deploy-compose.yml` — compose + `entrypoint.sh` +
`check_status.sh` + `otel-config.yaml`), manually adding
`config.toml`/`genesis.json`/`.env`, startup, validation (`check_status.sh`).

### Step 3 — Private network (optional, once nodes are validated)

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<vlan_id>
```

See [`NETWORK_AND_REVERSE_PROXY.md`](NETWORK_AND_REVERSE_PROXY.md) for the
detail (including manual reverse proxy setup if needed) and
`validator/Network_control.md` to drop/restore the validator's public
Internet access without breaking the VLAN.

### Step 4 — tmkms (optional)

Same-host sidecar (`compose/validator-sentry-tmkms/`) or dedicated signer
host over TCP (`compose/tmkms-alone/` + `compose/validator-alone/`) — see
`TMKMS.md` §3/§4:

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain-id>
```

Reusing an existing tmkms deployment on a **new chain** (directory copied
from the previous testnet): `TMKMS.md` §10 — chain-bound files to reset.

### Step 5 — Cold log retention (optional, independent of Alloy)

```bash
ansible-playbook -i inventory.yaml backup-logs.yaml
```

### Step 6 — Snapshotter (optional)

```bash
ansible-playbook -i inventory.yaml install-snapshotter.yml --tags snapshotter
```

See `roles/snapshotter/README.md`.

---

## Playbook reference

### `base_setup.yml`

**Purpose:** Prepare the server foundation (no application docker-compose).

```bash
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory.yaml base_setup.yml -e target=gno-validator
```

**Roles:** `base_setup`, `docker`, `gnoland`, `ufw`, `node_exporter`, `alloy`.

---

### `deploy-compose.yml`

**Purpose:** Push the stable, non-secret files maintained in this repo onto
a host — the chosen `compose/<compose_target>/` (`docker-compose.yml` +
`.env.example`), `entrypoint.sh`, `check_status.sh`, and `otel-config.yaml`
when the topology has an otel-collector.

```bash
ansible-playbook -i inventory.yaml deploy-compose.yml \
  -e target=gno-sentry -e compose_target=sentry-alone
```

**Never touches** `.env` (only ships `.env.example`), nor
`config.toml`/`genesis.json`/secrets — those stay fully manual, see
`DEPLOYMENT_RUNBOOK.md` §0/§2. `compose_target` is one of `sentry-alone`,
`validator-alone`, `validator-sentry-tmkms`.

---

### `setup-tmkms.yml`

**Purpose:** Prepare the tmkms sidecar (softsign), same host (uds, default)
or dedicated signer host (tcp) — before the manual `docker compose up -d`.

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain-id>
```

**Prerequisites:** the relevant gnoland secrets already initialized
(`gnoland secrets init` manual) — the role fails explicitly otherwise, it
never generates a secret. See `TMKMS.md` and `roles/tmkms/README.md`.

---

### `setup-private-network.yml`

**Purpose:** Activate the private VLAN interface on a host.

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>
```

Run once nodes are validated on their public IP. See
`NETWORK_AND_REVERSE_PROXY.md`.

---

### `backup-logs.yaml`

**Purpose:** Cold log retention, independent of Alloy (different retention
window than the logs/metrics backend).

```bash
ansible-playbook -i inventory.yaml backup-logs.yaml
```

Deploys `backup.sh` on the validator (24h Docker log extraction,
compression, daily SCP to the sentry) and `rotate.sh` on the sentry (30-day
retention), plus an auto-generated validator→sentry SSH key pair.

---

### `install-snapshotter.yml`

**Purpose:** Non-signing node dedicated to snapshots + hourly push to
Scaleway Object Storage. See `roles/snapshotter/README.md`.

```bash
ansible-playbook -i inventory.yaml install-snapshotter.yml --tags snapshotter
```

---

## Docker Compose targets

Four static topologies, 100% configurable via `.env` (see
[`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md) for the full procedure):

| Directory | Usage |
|---|---|
| `compose/sentry-alone/` | Public sentry only |
| `compose/validator-alone/` | Validator only + otel-collector (no co-located sentry) |
| `compose/validator-sentry-tmkms/` | Sentry + validator + tmkms sidecar (softsign) on the same host |
| `compose/tmkms-alone/` | Dedicated tmkms signer host (TCP mode), paired with `compose/validator-alone/` |

These files are **not** Jinja2 templates: they're plain docker-compose files
(`${VAR}`), pushed by hand to the server with a `.env` filled in from the
matching `.env.example` — the same logic as
`roles/snapshotter/templates/docker-compose.snapshotter.yml.j2` (which stays
Ansible-managed, since its need differs: non-signing node, fully staged by a
dedicated role).

---

## Tools & scripts

### check_status.sh

**Location:** `validator/check_status.sh` (copied by hand, see
`DEPLOYMENT_RUNBOOK.md`)

**Usage:**
```bash
bash check_status.sh <node-directory>
```

Checks: `image`/`MONIKER`/`PERSISTENT_PEERS` (+ `SEEDS`/`PRIVATE_PEER_IDS`
for a sentry) in `docker-compose.yml`, gnoland secrets
(`gnoland secrets get`), validator state (`priv_validator_state.json`),
presence of `gnoland-data/db`+`wal`, `genesis.json` (SHA256), and
`config.toml`.

### check-missed-blocks.py

**Location:** `tools/check-missed-blocks.py` (runs from any
machine with access to a gnoland RPC — requires Python 3 and `requests`)

**Usage:**
```bash
python3 tools/check-missed-blocks.py <g1-validator-address> \
  [--blocks 500] [--rpc https://rpc.mainnet.samourai.live]
```

Walks the last `--blocks` blocks (default 500) and checks, for each height H,
that the validator's precommit is present in the `last_commit` of block H+1.
Prints every missed height, then a summary: checked / signed / missed /
errors and the uptime percentage over the window. One RPC call per block, so
keep the window reasonable against public endpoints.

---

## Variables reference

### `inventory.yaml` (see `inventory.yaml.example`)

| Variable | Description |
| --- | --- |
| `public_ip` / `private_ip` | Host IPs |
| `ufw_ports_app` | Publicly opened application ports (e.g. `[26656]`) |
| `ufw_ports_moni` / `ufw_allow_ip` | Optional — port(s) restricted to a single IP. Empty by default: no inbound scrape port is required anymore since the switch to Alloy |
| `ufw_tmkms_port` / `ufw_tmkms_signer_ip` | Optional — tmkms TCP signer port, restricted to the signer host's IP (see `TMKMS.md` §4) |
| `alloy_logs_enabled` | Enables the Docker logs pipeline (Alloy) |
| `alloy_log_mode` | `"direct"` (hardcoded token) or `"relay"` (via a manual reverse proxy) |
| `alloy_logs_remote_write_url` | Target URL for logs |
| `alloy_remote_write_mode` | `"direct"` or `"relay"`, for metrics |
| `alloy_remote_write_url` | Target URL for metrics (remote_write) |
| `alloy_bearer_token` | Token for `"direct"` mode |
| `alloy_containers_filter` | Regex of the Docker containers whose logs are kept |
| `alloy_job_name` | `job` label on logs/metrics |
| `alloy_metrics_targets` | List of `{job, service, address}` scraped locally by Alloy |
| `tmkms_chain_id` / `tmkms_connection_mode` / `tmkms_validator_peer_id` / `tmkms_validator_ip` | Optional — see `setup-tmkms.yml` and `TMKMS.md` |

### `compose/*/.env.example`

See each file — `IMAGES`, `MONIKER(_*)`, `SEEDS`, `PERSISTENT_PEERS(_*)`,
`PRIVATE_PEER_IDS`, `TMKMS_*` depending on the topology.

---

## Security considerations

### gnoland secrets

Never generated by Ansible. Manual initialization, once per node:

```bash
ssh root@<node-ip>
gnoland secrets init
gnoland secrets get  # note node_id, p2p_address, validator_address
```

### Non-secret files per deployment

`entrypoint.sh`, `config.toml`, `genesis.json` change with every gno version
(build, genesis, download links) — they are pushed by hand at each
deployment (see `DEPLOYMENT_RUNBOOK.md`), never rendered by an Ansible
template.

### Network

- P2P (`:26656`): the only port open publicly by default.
- RPC (`:26657`) and metrics (`:9100`, `:9464`): always bound to
  `127.0.0.1` in the `compose/` composes — never exposed.
- Validator private VLAN isolation: see `NETWORK_AND_REVERSE_PROXY.md` and
  `validator/Network_control.md`.

### tmkms

The `tmkms` role (used by `setup-tmkms.yml`) fails explicitly if the
required gnoland/tmkms key material doesn't exist yet — it never generates
it. See `TMKMS.md` and `roles/tmkms/README.md`.

---

## Vagrant testing

Test configuration in `inventory-vagrant.yaml`:

| Host | IP | Role |
| --- | --- | --- |
| `gno-validator` | 192.168.56.10 | Validator |
| `gno-sentry` | 192.168.56.11 | Sentry |
| `gno-tmkms` | 192.168.56.11 | tmkms (lab) |

```bash
vagrant up

ansible-playbook -i inventory-vagrant.yaml base_setup.yml -e target=gno-sentry
ansible-playbook -i inventory-vagrant.yaml base_setup.yml -e target=gno-validator

# Secrets (manual SSH into each VM)
vagrant ssh gno-sentry -c 'gnoland secrets init && gnoland secrets get'
vagrant ssh gno-validator -c 'gnoland secrets init && gnoland secrets get'

# Node deployment: see DEPLOYMENT_RUNBOOK.md
```

---

## Local environments (devnet & tmkms-lab)

Two Docker sandboxes live alongside the production Ansible flow. Both are
**self-contained, throwaway `dev` chains** that never commit secrets —
everything generated (keys, genesis, `.env`, state) is gitignored and
regenerated on each setup.

### devnet

[`devnet/`](devnet/) is a **3-validator Gno.land devnet** entirely driven by
Docker (validator/validator2/validator3, plus a 4th identity reserved for
the GovDAO onboarding scenario, a tx-indexer and a gnoweb explorer). Its
purpose: exercise every **gnomonitoring** feature end-to-end — block
participation tracking, downtime/halt alerts, the GovDAO watcher, Prometheus
metrics and Telegram bots — before merging changes to production. It also
hosts the reference **tmkms softsign + Unix-socket sidecar** configuration.

One-time setup: `GNO_REPO_PATH=/path/to/gno ./bootstrap.sh`, then
`docker compose up -d`. See [`devnet/README.md`](devnet/README.md) for the
full detail (reset, local dev accounts, scripted test scenarios via
`make help`).

### tmkms-lab

[`tmkms-lab/`](tmkms-lab/) is a smaller, **2-VM** experiment that stands up a
single-validator chain (plus a sentry) and **externalizes consensus signing
to [tmkms](https://github.com/iqlusioninc/tmkms)** over TCP: the private
consensus key lives on a second VM, not in the gnoland container. Its
purpose: understand and validate the remote-signer path before rolling it
into production. `roles/tmkms` (`tmkms_connection_mode: "tcp"`) reuses this
exact pattern for production deployment (see `TMKMS.md` §4).

See [`tmkms-lab/README.md`](tmkms-lab/README.md) for the full 2-VM
walkthrough (image requirements, bootstrap, key exchange, verification).

---

## legacy/

[`legacy/`](legacy/README.md) groups what was removed from the active
Ansible scope during the repo simplification (nginx/TLS/OAuth-proxy, the
Loki/Prometheus/Grafana stack, automated compose deployment, Promtail).
Nothing there is maintained — it's a historical reference, not code meant to
be replayed as-is. See `legacy/README.md` for the detail and the reasons for
each removal.
