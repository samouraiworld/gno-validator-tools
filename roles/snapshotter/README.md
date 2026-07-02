# roles/snapshotter

Deploy a dedicated **non-signing** gnoland full node (the *snapshotter*) on the
sentry host, plus an hourly job that captures chain snapshots and pushes them to
**Scaleway Object Storage**.

## Why a dedicated node

LevelDB cannot be copied consistently while it is being written, and we must
never stop the validator or the sentry. The snapshotter is a throwaway follower:
it syncs the chain over P2P via the local sentry, and `snapshot.sh` stops it for
a few seconds to `tar` its `db` — **zero impact** on the validator/sentry.

```
validator (private, tmkms) ──VLAN──► sentry (public P2P)
                                        │
                                        └── snapshotter (same host, non-signing)
                                               hourly: snapshot.sh (stop→tar db→start)
                                                       push-to-s3.sh (rclone, STANDARD)
                                               ▼
                                        Scaleway Object Storage (private bucket)
                                          lifecycle: STANDARD → GLACIER 7d → expire 90d
```

## What it deploys (into `snapshotter_dir`, default `/root/{{ gno_dir }}-snapshotter`)

| File | Role |
|---|---|
| `docker-compose.yml` | the snapshotter service (RPC bound to localhost) |
| `entrypoint.sh` | plain follower init (no tmkms, no otel) |
| `config.toml`, `genesis.json` | copied from the sentry dir on the same host |
| `snapshot.sh` | capture: stop → tar `db` (wal excluded) → start → rotate |
| `push-to-s3.sh` | upload archives to Scaleway with rclone (STANDARD class) |
| `restore.sh` | restore any node dir from an archive |
| `snapshotter.env.example` | **template to copy to `.env`** — the only place secrets live |
| `/etc/systemd/system/gno-snapshot.{service,timer}` | hourly capture + push |

The role **stages** everything but does **not** start the node or enable the
timer — that's the operator's step (needs the filled `.env`).

## Secrets — where they live

The archive contains **chain data only** (`gnoland-data/db`): no keys, no
`priv_validator_*`, no tmkms material. Nothing secret is ever uploaded.

The **only** secret file on the host is `.env` (Scaleway API keys), which the
operator creates from `snapshotter.env.example`, `chmod 600`. It is never
committed and never rendered by Ansible. `push-to-s3.sh` reads the keys from
`.env` and exports them as `RCLONE_CONFIG_*` env vars, so they never appear in
the process list either.

## Variables

See `defaults/main.yml`. Key ones:

| Variable | Default | Notes |
|---|---|---|
| `snapshotter_enabled` | `false` | master switch |
| `snapshotter_chain_id` | `""` | must match genesis |
| `snapshotter_image` | `gno-validator:local` | same image as the nodes |
| `snapshotter_dir` | `/root/{{ gno_dir }}-snapshotter` | separate deploy dir |
| `snapshotter_source_node_dir` | `/root/{{ gno_dir }}` | where genesis.json/config.toml are copied from |
| `snapshotter_rpc_bind` | `127.0.0.1:26662` | localhost only |
| `snapshotter_retention_local` | `24` | local archives kept (`.env` RETENTION_LOCAL overrides) |
| `snapshotter_timer_oncalendar` | `hourly` | capture cadence |
| `snapshotter_s3_endpoint` | `s3.fr-par.scw.cloud` | Scaleway region endpoint |
| `snapshotter_s3_region` | `fr-par` | |

## Deploy

```bash
ansible-playbook -i inventory.yaml 8-install-snapshotter.yml --tags snapshotter
```

Then, on the sentry host, in `snapshotter_dir`:

```bash
cp snapshotter.env.example .env && chmod 600 .env
# fill: SEEDS/PERSISTENT_PEERS (at least the local sentry node_id) + Scaleway keys
docker compose --env-file .env up -d
# wait until synced: curl -s 127.0.0.1:26662/status | jq '.result.sync_info'
systemctl enable --now gno-snapshot.timer
systemctl list-timers gno-snapshot.timer
```

## Scaleway setup (operator, one-time)

1. Create a **private bucket** (name + region, e.g. `fr-par`).
2. Create an **API key** (Access/Secret) in IAM → put in `.env`.
3. Add a **lifecycle rule** on the bucket (console → Lifecycle):
   - transition `STANDARD → GLACIER` after **7 days** (cheap cold archive),
   - expiration (delete) after **90 days** (retention cap).
   Recent snapshots stay STANDARD = instant restore; old ones go cold.

## Restore

Pull an archive from Scaleway, then restore it onto a node dir:

```bash
# list remote archives
rclone lsf scw:$S3_BUCKET/$S3_PREFIX/     # (rclone remote configured as in push-to-s3.sh)
# download one
rclone copy scw:$S3_BUCKET/$S3_PREFIX/<height>-<ts>.tar.zst ./snapshots/
# restore onto a node (stop → wipe db+wal → extract → start)
./restore.sh /root/<gno_dir>-snapshotter ./snapshots/<file>.tar.zst snapshotter
```

- **Cold archive (GLACIER):** a `GLACIER`-class object must be **restored/thawed**
  first (several hours) before it can be downloaded. Only recent (STANDARD)
  snapshots restore immediately — this drives your RTO on older restore points.
- **Validator DR:** restore chain data from the snapshot **plus** the validator's
  own consensus key + double-sign state from your **out-of-band, encrypted** key
  backup (never in the snapshot). `restore.sh validator` prints the tmkms
  anti-double-sign checklist and asks for confirmation.

### Files to back up out-of-band (NOT in the snapshot)

| Mode | Critical files (encrypted, offline) |
|---|---|
| Without tmkms | `gnoland-data/secrets/priv_validator_key.json` (consensus key), `priv_validator_state.json` (HRS gate), `node_key.json` |
| With tmkms | `tmkms/secrets/consensus.key` (consensus key), `consensus_state.json` (HRS gate), `kms-identity.key`, `node_key.json` |

Never let the HRS state (`priv_validator_state.json` / tmkms `consensus_state.json`)
go backwards, or you risk a double-sign.
