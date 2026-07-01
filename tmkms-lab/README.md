# tmkms-lab — 2-VM TCP tmkms test

A **self-contained, single-validator** chain (+ 1 sentry) whose consensus
signing is externalized to **tmkms** on a second VM over **TCP**. Purpose:
understand tmkms. Independent from `devnet/` (which stays untouched).

```text
VM1  192.168.56.10            VM2  192.168.56.11
┌ docker compose ─────────┐   ┌ docker compose ───┐
│ sentry   (relay)        │   │ tmkms (softsign)  │
│ validator ─listens :26659│◄─│ signs             │
└─────────────────────────┘   └───────────────────┘
      tmkms-lab/                    tmkms-lab/tmkms/
```

Fixed parameters: `CHAIN_ID=dev`, VM1=`.10`, VM2=`.11`.

## Images (the main gotcha)

tmkms support (`consensus.priv_validator.tmkms_listener`, the
`--skip-genesis-sig-verification` flag) is **merged into gno master** (PR #5718,
commit `a870686e4`). You therefore need an image that includes it:

| Image | tmkms? | Notes |
| --- | --- | --- |
| `ghcr.io/gnolang/gno/gnoland:master` | ✅ | **use this.** Rebuilt on every merge to master. |
| `ghcr.io/gnolang/gno/gnoland:latest` | ❌ | release build, too old → `priv_validator is not a valid configuration key`. |
| `ghcr.io/gnolang/gno:master` | ❌ | wrong path (no `/gnoland`) → no `/usr/bin/gnoland`. |
| local build from `/opt/gno` on master (`≥ a870686e4`) | ✅ | alternative to GHCR. |

**⚠️ Refresh the `:master` tag before bootstrapping.** A tag already present
locally is **not** re-pulled automatically: `docker run`/`bootstrap.sh` reuses
the cached image, even if a newer master build (with tmkms) exists on GHCR.
This is the classic mistake. So on **each VM**:

```bash
docker pull ghcr.io/gnolang/gno/gnoland:master
docker pull ghcr.io/gnolang/gno/gnocontribs:master
# (the compose equivalent is: docker compose pull)
```

**Then verify the binary** (must return `1`):

```bash
docker run --rm --entrypoint /usr/bin/gnoland \
  ghcr.io/gnolang/gno/gnoland:master start -h 2>&1 | grep -c skip-genesis-sig
```

## Prerequisites (on top of `1-base_setup.yml`)

- **VM1**: Docker + `jq`. Images pulled from GHCR (or built locally).
- **VM2**: Docker (the setup builds `tmkms:local`).

## Walkthrough

### 1) VM1 — bootstrap

```bash
cd tmkms-lab
cp .env.example .env                       # GHCR :master images already set
docker compose pull                        # refresh :master BEFORE bootstrap
./bootstrap.sh
```

Generates the secrets (validator + sentry), `config.toml`, `genesis.json`
(1 validator), the `.env` (P2P peers), `tmkms-share/consensus.key`, and prints
the validator's **hex peer-id**.

> `bootstrap.sh` is idempotent: it **skips** existing secrets. If you change
> the image afterwards, start clean (see *Start from scratch*).

### 2) VM1 → VM2 — copy the consensus key

```bash
scp tmkms-share/consensus.key user@192.168.56.11:~/tmkms-lab/tmkms/secrets/consensus.key
# (also copy the tmkms/ folder to VM2 if it isn't there yet)
```

### 3) VM2 — tmkms setup + start

```bash
cd tmkms-lab/tmkms
VAL_PEERID=<hex peer-id from step 1> IP_GNO=192.168.56.10 CHAIN_ID=dev ./setup-vm2-tmkms.sh
```

Builds `tmkms:local`, generates the `kms-identity` key, renders `tmkms.toml`,
and prints the `ed25519:...` value (= the `TMKMS_ALLOW` to paste on VM1).

Then start the signer **with compose**:

```bash
docker compose up -d          # docker-compose.yml: tmkms:local, restart: always
docker compose logs -f        # expect: "signed Precommit ... at h/r/s ..."
```

### 4) VM1 — allowlist + firewall + start

```bash
# paste the ed25519:... from step 3 into TMKMS_ALLOW in .env
sudo ufw allow from 192.168.56.11 to any port 26659 proto tcp
sudo ufw deny 26659/tcp
docker compose up -d
```

> If you change `TMKMS_ALLOW` afterwards, recreate the container (a plain
> `restart` does not reload the env):
> `docker compose up -d --force-recreate validator`.

### 5) Verify

```bash
# VM2:  docker compose logs -f          → connected successfully / signed ...
# VM1:  docker compose logs -f validator → This node is a validator / Committed state height=N
# Proof: on VM2 'docker compose stop tmkms' → the chain stalls;
#        'docker compose start tmkms' → it resumes.
```

## .env files

**VM1 — `tmkms-lab/.env`** (written by `bootstrap.sh`, preserved across re-runs):

| Key | Role |
| --- | --- |
| `GNO_IMAGE` | node image (`ghcr.io/gnolang/gno/gnoland:master`). |
| `GNO_CONTRIBS_IMAGE` | gnogenesis image (`ghcr.io/gnolang/gno/gnocontribs:master`). |
| `CHAIN_ID` | `dev` — identical everywhere (genesis / config / tmkms.toml). |
| `PERSISTENT_PEERS_VALIDATOR` / `_SENTRY` | internal validator↔sentry peering. |
| `PRIVATE_PEER_IDS_SENTRY` | keeps the validator private behind the sentry. |
| `TMKMS_ALLOW` | KMS identity pubkey (`ed25519:<hex>`), filled after step 3. **Required on TCP** (an empty allowlist rejects every KMS). |

The VM1 `docker-compose.yml` reads these variables via `${...}`.

**VM2**: no `.env` — the tmkms config lives in `tmkms.toml` (rendered by
`setup-vm2-tmkms.sh`) and the `docker-compose.yml` in the `tmkms/` folder.

## Start from scratch (image change, corrupted secrets…)

Secrets from one image aren't necessarily readable by another (e.g.
`NodeKey ... cannot unmarshal object into []uint8` = secrets from an old
image). Clean reset on VM1:

```bash
cd tmkms-lab
docker compose down
rm -rf validator/gnoland-data sentry/gnoland-data \
       validator/config.toml sentry/config.toml validator/genesis.json sentry/genesis.json \
       config.toml genesis.json genesis_balances.txt tmkms-share
docker compose pull           # in case :master moved
./bootstrap.sh
```

Regenerating the secrets **changes the consensus key** → redo steps 2→4
(new `consensus.key`, new `TMKMS_ALLOW`).

## Notes

- `-lazy` is unnecessary here (genesis is produced by `gnogenesis`).
- 1 tmkms = 1 key = 1 validator (the sentry does not sign).
- `protocol_version = "v0.34"` on both sides: gnoland pins it to v0.34. tmkms
  prints a deprecation *warning* — keep it on v0.34 anyway.
- You may delete `validator/gnoland-data/secrets/priv_validator_key.json`
  after genesis (the key lives on VM2) — keep `node_key.json`.
- Nothing is committed (see `.gitignore`).
