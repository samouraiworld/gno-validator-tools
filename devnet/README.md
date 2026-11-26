# Local Gno.land devnet

The Samourai local devnet: a 3-validator Gno.land chain (chain ID `dev`), run
entirely with Docker. It is the one devnet for two kinds of tests:

- **validator operations** in this repository: tmkms remote signing, chain
  snapshots, snapshot restore and auto-heal (`make scenario-autoheal-*`);
- **gnomonitoring end to end** (block participation, alerts, GovDAO watcher,
  chain-halt notices): the gnomonitoring repository runs its backend against
  this directory (see [Used by gnomonitoring](#used-by-gnomonitoring)).

It ships:

- **validator / validator2 / validator3** — genesis validators
  (`samourai-crew-1/2/3`, voting power 10/10/11). All three sign locally by
  default; with the `tmkms` profile, `validator`'s signing moves to a tmkms
  sidecar (see below).
- **tx-indexer** — GraphQL transaction/block indexer
  (`http://localhost:8546/graphql/query`)
- **gnoweb** — block explorer UI (`http://localhost:8890`)

and, behind Docker Compose profiles (not started by a plain `make up`):

| Profile    | Service       | What it is                                                                 | Start it with |
|------------|---------------|----------------------------------------------------------------------------|---------------|
| `phase2`   | `validator4`  | a 4th identity (`samourai-crew-4`), not in genesis, onboarded by GovDAO in scenario1 | `make up-validator4` |
| `tmkms`    | `tmkms`       | remote signer for `validator` (softsign backend over a Unix socket)        | `make up TMKMS=1` |
| `snapshot` | `snapshotter` | non-signing full node, the source of `make snapshot`                       | `make up-snapshotter` |

`make up-full` starts all three: what the auto-heal scenarios need.

## Prerequisites

- Docker + Docker Compose
- A local clone of the [gno](https://github.com/gnolang/gno) repository
  (used to build the `gnoland`/`gnogenesis`/`gnokey` images and to deploy the
  `examples/gno.land` package tree into genesis)
- `gnokey`, `jq`, `curl` and `zstd` on the host. The scenarios sign
  transactions with the host `gnokey`, which must come from the same gno
  version as the chain image: a mismatch fails with
  `signature verification failed`. Build it from the same clone
  (`cd gno.land && go build -o ~/go/bin/gnokey ./cmd/gnokey`).
- The GovDAO scenarios depend on the gno version of the image:
  `scenario1`, `scenario5` and `scenario-govdao-dead-chain` call
  `gno.land/r/gov/dao/v3/init`, removed in gno v1.8.0; `scenario-halt` needs
  v1.8.0 or later (`r/sys/params.NewSetHaltRequest`, `memberstore/v0`).
  Bootstrap with the image each scenario needs (`GNO_IMAGE=... make full-reinit`).

## One-time setup

```bash
GNO_REPO_PATH=/path/to/gno ./bootstrap.sh
```

This builds the `gno-validator:local`, `gno-contribs:local` and
`gno-gnokey:local` images, generates node secrets and P2P identities for all
4 nodes, the `dev`/`v4op` gnokey accounts, the shared `config.toml`, the `.env`
file (P2P seeds), the rendered `init-govdao.gno`/`propose-validator4.gno`
scripts, and `genesis.json` (3 validators + the full `examples/gno.land`
package tree + balances + `auth.unrestricted_addrs`).

**Nothing generated is committed to git** — keys, genesis, `.env`, the
`.gnokey-dev/` keybase, `.devaddrs.mk` and the rendered `*.gno` are all
gitignored. Every fresh setup regenerates them, so the validator / `dev` /
`v4op` **addresses change between setups**. That's intentional and safe: the
genesis, `.env`, the rendered GovDAO scripts and `.devaddrs.mk` are all derived
from the same freshly generated keys, so they always stay consistent.

The script is **idempotent**: re-running it skips any step whose output already
exists. To wipe everything and regenerate from scratch (new keys + addresses),
run `make clean-all` then `make full-reinit`.

## Running the devnet

```bash
make up               # validator, validator2, validator3, tx-indexer, gnoweb (local signing)
make up TMKMS=1       # same, with validator signing through tmkms
make up-validator4    # the 4th identity for the Phase 2 GovDAO scenario
make up-snapshotter   # the snapshot source node
make up-full          # all of the above with tmkms
make down             # stop everything, every profile (keeps chain state)
```

Plain `docker compose` works too: the project name is pinned in
`docker-compose.yml`. Add `--profile <name>` for the profiled services.

**One devnet per machine.** The compose project name (`gnoland-test`), the host
ports below and the `tx-indexer` container name are fixed, and gnomonitoring's
dev stack uses the same project. Stop one devnet before starting another
(`make down`, or `make dev-down` for the gnomonitoring stack).

Useful endpoints once running:

| Service            | URL                                            |
|--------------------|------------------------------------------------|
| validator RPC      | `http://localhost:26658`                       |
| validator2 RPC     | `http://localhost:26659`                       |
| validator3 RPC     | `http://localhost:26660`                       |
| validator4 RPC     | `http://localhost:26661` (phase2 profile only) |
| snapshotter RPC    | `http://localhost:26662` (snapshot profile only) |
| tx-indexer GraphQL | `http://localhost:8546/graphql/query`          |
| gnoweb             | `http://localhost:8890`                        |

Check progress:

```bash
curl -s http://localhost:26658/status | jq '.result.sync_info'
```

## tmkms sidecar (validator consensus signing)

Opt-in: with `TMKMS=1`, `validator`'s consensus key is **not** used by
gnoland directly — signing is externalized to a **tmkms** sidecar container,
exactly as planned for production. This is the same-host, simplest variant of
the model:

- **Backend:** `softsign` (no HSM) — the consensus key sits in
  `tmkms/validator/secrets/consensus.key`.
- **Transport:** Unix-domain socket (`unix:///run/gnoland/privval.sock`) shared
  via the `./tmkms/run` volume mounted into both containers. Both run under the
  **same UID** so the `0600` socket is reachable; the socket permissions are the
  only auth boundary (no `allowed_kms_pubkeys` needed on UDS).
- **Wiring:** `TMKMS=1` makes the Makefile export
  `TMKMS_LISTEN_ADDR=unix:///run/gnoland/privval.sock` (gnoland then listens on
  that socket instead of signing locally, see
  [docker-compose.yml](docker-compose.yml) and [entrypoint.sh](entrypoint.sh))
  and `COMPOSE_PROFILES=tmkms` (starts the sidecar). tmkms dials that socket with
  `reconnect = true` ([tmkms/validator/tmkms.toml](tmkms/validator/tmkms.toml)),
  so start order doesn't matter. `protocol_version = "v0.34"` (gnoland speaks
  only v0.34).

The signer material under `tmkms/validator/secrets/` (`consensus.key`,
`kms-identity.key`, `consensus_state.json`) is **gitignored** and (re)generated
by `bootstrap.sh`: it reslices the node's `priv_validator_key.json` into the
softsign base64 format. Because it's derived from the node key, a fresh setup
(new keys) regenerates it in lock-step.

**Requires a gnoland image with tmkms support** (the `tmkms_listener` config,
merged in gno master — PR #5718 / commit `a870686e4`). Verify with:

```bash
docker run --rm --entrypoint /usr/bin/gnoland \
  gno-validator:local start -h 2>&1 | grep -c skip-genesis-sig   # must be 1
```

**Switching between local signing and tmkms.** Pass `TMKMS=1` to every
lifecycle command (`make up`, `make reinit`, ...) or `export TMKMS=1` in the
shell. `make up` refuses to run without it while tmkms is running, because
compose would recreate `validator` with local signing. Switch on a fresh chain:
`make reinit TMKMS=1`, or `make reinit` to go back to local signing. With raw
`docker compose`, set `TMKMS_LISTEN_ADDR` and `--profile tmkms` together.

> For the **2-VM TCP** variant of this setup (signer on a separate host, with
> the `allowed_kms_pubkeys` pin that TCP requires), see
> [`../tmkms-lab/`](../tmkms-lab/).

## Resetting the chain

Two levels of reset, both wrapped by the `Makefile`:

- **`make reinit`** — purges the `dev`-chain rows from the gnomonitoring DB,
  then runs `./reinit-chain.sh`: wipes each node's `config`, `db`, `wal` and
  `genesis.json` and resets `priv_validator_state.json`, while **keeping** the
  node identities (`secrets/`) and the `dev`/`v4op` keybase — so all addresses
  stay the same. Fast; use it between test scenarios.
- **`make clean-all`** — nukes *everything* generated (keys, keybase, genesis,
  config, `.env`, `.devaddrs.mk`, rendered `*.gno`). The next `make full-reinit`
  regenerates fresh keys and **new addresses**.

```bash
make reinit        # keep identities, restart chain from existing genesis
# or, full regeneration:
make clean-all
make full-reinit   # bootstrap (new keys+genesis) + purge dev DB + start
```

> **⚠️ Restart the backend after any reset.** `gnomonitoring-backend` keeps the
> last-seen block height per chain in memory. When you reset the chain under a
> running backend, it waits for the new chain to climb back past the old height
> before ingesting — so `daily_participations` for `dev` stays empty until you
> restart it:
>
> ```bash
> docker restart gnomonitoring-backend
> ```
>
> This also reconnects the **GovDAO websocket**, which is what fires "New
> Proposal" alerts (see the GovDAO note under Scenario 1).

## Local dev accounts

`bootstrap.sh` generates two throwaway gnokey accounts into `.gnokey-dev/`
(gitignored, **regenerated with new addresses on every fresh setup**). Both are
funded in genesis; `dev` is also set as `auth.unrestricted_addrs` so it can
register valopers or submit GovDAO proposals without paying realm storage
deposits.

| Key    | Role                                     |
|--------|------------------------------------------|
| `dev`  | GovDAO member, proposal submitter        |
| `v4op` | validator4 operator (must sign Register) |

- **Passphrase** (both accounts): `devpassword123`
- The current addresses are written to `.devaddrs.mk` after each setup
  (`DEV_ADDR`, `VALIDATOR4_OP_ADDR`, `VALIDATOR4_ADDR`, `VALIDATOR4_PUB`) and
  can also be listed from the keybase:

  ```bash
  cat .devaddrs.mk
  gnokey list -home "$PWD/.gnokey-dev"
  ```

Use them with the local `gnokey` binary (a plain `docker run` of
`gno-gnokey:local` can't reach `localhost:26658` unless the container joins the
devnet's docker network):

```bash
gnokey query bank/balances/$(awk '/DEV_ADDR/{print $3}' .devaddrs.mk) \
  -home "$PWD/.gnokey-dev" -remote http://localhost:26658
```

## Pointing gnomonitoring at the devnet

See also [Used by gnomonitoring](#used-by-gnomonitoring) below.

There are two ways to run gnomonitoring against this devnet, depending on
whether the backend itself runs on the host or in a container.

### Option A — gnomonitoring running on the host (`go run` / `go test`)

Copy the `chains.local` entry from
[`config.devnet.yaml.example`](config.devnet.yaml.example) into the `chains:`
section of `backend/config.yaml`, then either set `default_chain: "local"`
or query the API/Telegram bot with `?chain=local`. The devnet's RPC/GraphQL/
gnoweb ports are published on `127.0.0.1`, so `localhost:26658` etc. are
reachable directly from the host.

## Used by gnomonitoring

The gnomonitoring repository keeps no devnet of its own: its local stack and
its `make scenario*` instructions point here. gnomonitoring's
`compose_dev_chain.yml` mounts this directory through the `DEVNET_DIR`
variable, which this Makefile exports. The Makefile finds the gnomonitoring
checkout through `GNOMONITORING_DIR`, by default the sibling of
gno-validator-tools:

```text
workspace/
├── gno-validator-tools/devnet/   <- this directory (DEVNET_DIR)
└── gnomonitoring/                <- GNOMONITORING_DIR (compose_dev_chain.yml, .env, backend/)
```

Override it when the layout differs:
`make dev-up GNOMONITORING_DIR=/path/to/gnomonitoring`.
The gnomonitoring dev stack has no tmkms and no snapshotter.

### Option B — full dockerized stack (`make dev-up`, recommended)

`compose_dev_chain.yml`, at the root of the gnomonitoring repository,
runs the devnet, the gnomonitoring backend and Postgres as one compose project
(named `gnoland-test`, so every `make scenario*` target drives the same
containers). The backend reaches the devnet by service name
(`http://validator:26657`, `http://tx-indexer:8546`, `http://gnoweb:8888`).

1. **Once:** generate keys/genesis and build the validator image
   (`make full-reinit`), then create the backend config:

   ```bash
   cd "$GNOMONITORING_DIR"
   cp backend/config_dev_chain.yaml.template backend/config_dev_chain.yaml
   cp .env.example .env   # POSTGRES_PASSWORD; database.password defaults to "changeme"
   ```

2. **Start (always from block 0):**

   ```bash
   make dev-up     # down, reset, then up --build
   make dev-logs   # follow the backend
   make dev-down   # stop everything (the Postgres volume is kept)
   ```

`make dev-up` tears the stack down first, then the one-shot `chain-reset`
service ([`dev-chain-reset.sh`](dev-chain-reset.sh)) wipes every node's
`config`/`db`/`wal`, resets `priv_validator_state.json` and purges the `dev`
chain rows from the database — the in-container equivalent of `make reinit`.
Webhooks, alert contacts and Telegram subscriptions are kept. The tx-indexer
keeps its data in memory, so it follows the chain back to block 0.

Startup is ordered: the backend, tx-indexer and gnoweb wait until the
`validator` healthcheck sees the RPC answer with at least one block. Starting
the backend any earlier leaves its validator map empty (no participation
ingested until the 5-minute refresh) and fires a spurious RPC-outage alert.

#### Running it from the gnomonitoring repository root

The Makefile targets are thin wrappers; the same stack can be driven with
plain `docker compose` from the repository root. Whether `up` resets the chain
depends on the state of the stack:

| Stack state before `up -d`                  | Result                                                             |
|---------------------------------------------|--------------------------------------------------------------------|
| Never started, or all validators stopped    | Chain reset to block 0 and `dev` DB rows purged, then started      |
| Any validator running                       | Nothing is wiped — `chain-reset` sees a live validator and skips   |

So a plain `up -d` against a running stack is safe. To **force** a fresh chain
(what `make dev-up` does):

```bash
docker compose -f compose_dev_chain.yml --env-file .env --env-file "$DEVNET_DIR/.env" --profile phase2 down
docker compose -f compose_dev_chain.yml --env-file .env --env-file "$DEVNET_DIR/.env" up -d --build
```

Both `--env-file` flags are required on every command: compose interpolates
`${DOCKER_USER}` / `${GNO_IMAGE}` (from this directory's `.env`, generated by
`bootstrap.sh`) and `${POSTGRES_PASSWORD}` (gnomonitoring's `.env`) before reading any
service `env_file`. Without this directory's `.env` it would silently fall back to
`1000:1000` / `gno-validator:local`, so `chain-reset` checks and refuses to
start on a mismatch.

- `--profile phase2` on `down` also removes `validator4` if `make scenario1`
  started it; otherwise it can keep running on the old chain while its state
  is wiped.
- `--build` on `up` rebuilds the backend image after Go code changes; without
  it the previously built image is reused.

Before the first run:

- this directory's `.env` and `genesis.json` must exist
  (`make full-reinit`) — `chain-reset` exits with an error otherwise;
- gnomonitoring's `backend/config_dev_chain.yaml` must exist (see step 1 above);
- stop the local production stack if it runs
  (`docker compose -f docker-compose-prod.yml down`): both use the same
  Postgres container and volume (`gnomonitoring-postgres`,
  `gnomonitoring_pgdata`).

#### Running the test scenarios on the dev stack

The `make scenario*` targets work unchanged: the stack shares the
`gnoland-test` compose project, so they drive its containers by service name.

```bash
cd gno-validator-tools/devnet
make dev-up             # returns once the validator has produced a block
make scenario1          # onboard validator4 via GovDAO
# wait for the backend to track samourai-crew-4 (next moniker refresh, <= 5 min):
#   docker logs gnomonitoring-backend | grep 'New Validator detected'
make scenario2          # stop validator4 -> WARNING (>= 5 missed) then CRITICAL (>= 30)
make scenario2-restart  # -> RESOLVED
make dev-up             # fresh chain before scenario5 (targets proposal #0)
```

- **Reset with `make dev-up`, never `make reinit` / `make full-reinit`** while
  the dev stack runs: those restart the chain from this directory's `docker-compose.yml`,
  without the healthcheck ordering and without recreating the backend, which
  brings back the "backend ingests nothing" problem. `make full-reinit` is
  still the way to regenerate keys — then run `make dev-up`.
- Do not run `make dev-up` while a scenario is in progress: it restarts the
  whole stack and the scenario's next transaction fails with
  `connection reset by peer`.
- The `Found orphan containers (gnomonitoring-backend, ...)` warning printed by
  `scenario1`/`scenario5` is expected and harmless: those services are defined
  in `compose_dev_chain.yml`, not in this directory's compose file.
- Assertions are unchanged (see each scenario below): `docker exec
  gnomonitoring-postgres psql ...` and `docker logs gnomonitoring-backend`.

## Test scenarios

These scenarios exercise gnomonitoring end-to-end against this devnet (block
participation tracking, alerts, GovDAO watcher, Prometheus metrics). They
assume gnomonitoring is running against `chain=local` as described above and
the chain is healthy (see "Resetting the chain" if not).

Genesis validator set and voting power: samourai-crew-1/2/3 = 10/10/11 (total
31). A strict majority above 2/3 of 31 is 21, so in theory any 2 of the 3
genesis validators can keep the chain alive without the third.

A `Makefile` in this directory wraps the chain-lifecycle and scenario commands
— run `make help` for the full list. Available scenarios:

| Target | What it exercises | How to assert |
|--------|-------------------|---------------|
| `make scenario1` | New validator via GovDAO (onboard validator4) | `v3.IsValidator` = true, `voting_power` 0→1 |
| `make scenario2` / `scenario2-restart` | Validator downtime: WARNING→CRITICAL→RESOLVED (stops validator4) | `alert_logs` rows for `chain='dev'`, `addr=VALIDATOR4_ADDR` |
| `make scenario3` / `scenario3-restart` | Chain halt → stagnation alert (stops validator2+3) | `alert_logs` `addr='all'`, log `Blockchain stuck`, height frozen |
| `make scenario4` / `scenario4-restart` | Total RPC outage (stops ALL nodes) → **log-only** alert | `grep 'Error when querying latest block height'` (no DB row) |
| `make scenario5` | GovDAO proposal voted **NO** (fresh chain) | live "New Proposal" alert + render shows `NO PERCENT: 100%` |
| `make scenario-mute` | Resend dedup (keeps validator4 down) | exactly one `alert_logs` row/level + `dedup: skipping` log |
| `make scenario-govdao-dead-chain` | A 2nd chain with hanging RPCs must not delay dev's GovDAO ACCEPTED notice (dev stack, fresh chain) | **self-asserting**: prints `PASS`, or `FAIL` and exits non-zero |
| `make scenario-halt` | GovDAO vote schedules a chain halt (dev stack, gno v1.8.0+); the chain halts and resumes | **self-asserting**: `alert_logs` `addr='halt'` rows HALT_SCHEDULED, HALT_REMINDER, HALT_FINAL_REMINDER, HALT_RESUMED in order; prints `PASS` or `FAIL` |

Validator-operations scenarios (no gnomonitoring needed; run `make up-full`,
then `make snapshot` once the snapshotter has synced):

| Target | What it exercises | How to assert |
|--------|-------------------|---------------|
| `make scenario-autoheal-follower` | stop validator4, force an auto-heal restore from the latest snapshot | `[ALERT] restore-succeeded`, validator4 back in sync |
| `make scenario-autoheal-validator` | auto-heal restore of the tmkms-backed validator (needs `TMKMS=1`) | `restore-succeeded`, tmkms logs `signed ...` again, no `double sign` |
| `make scenario-autoheal-no-snapshot` | auto-heal with no snapshot available | `restore-failed`, `exit=1`, node untouched |
| `make scenario-autoheal-cooldown` | a second auto-heal within the cooldown | `cooldown-blocked`, `exit=1` |

The auto-heal scenarios share one cooldown lock per node (`.autoheal/<node>.lock`,
30 min): `scenario-autoheal-no-snapshot` and `scenario-autoheal-cooldown` leave
one for validator4, so run `scenario-autoheal-follower` first, or remove
`.autoheal/validator4.lock` before it. `make check-stuck NODE=<svc>` runs one
stuck-detection check; see [SNAPSHOT-RESTORE.md](SNAPSHOT-RESTORE.md) for the
snapshot and restore procedures.

`make scenario2` stops **validator4**, so run `make scenario1` first to put it
in the valset. The detailed walkthrough below documents what `make scenario1`
does under the hood.

> **GovDAO alerts (scenario1 / scenario5):** the "New Proposal" alert only fires
> for proposals seen **live over the websocket**, so the backend must already be
> watching `dev` when the proposal is created (reset → `docker restart
> gnomonitoring-backend` → create proposal). On a fresh devnet the alert is
> delivered via the **GovDAO Telegram bot** only (no `webhook_gov_daos` row for
> `dev`). For **scenario5**, voting NO alone does **not** reject the proposal:
> gov/dao v3 sets it Denied only inside `ExecuteProposal`, so scenario5 calls
> `ExecuteProposal` after the vote. The call returns `false` (the payload is
> not executed) and the render then shows `PROPOSAL HAS BEEN DENIED`; the
> watcher marks the proposal `REJECTED` within one 5-minute cycle.

### Scenario 1 — New validator via GovDAO

Exercises GovDAO proposal detection/alerts (`internal/govdao`), moniker
resolution via `valopers.Render()`, and the appearance of a 4th validator in
`daily_participations` / `gnoland_chain_active_validators`.

> **TL;DR:** just run **`make scenario1`** — it performs every step below using
> the live addresses from `.devaddrs.mk`. The manual walkthrough is kept for
> reference. **All `g1...`/`gpub1...` values shown below are examples**: keys are
> regenerated on every setup, so use your own from `.devaddrs.mk` /
> `gnokey list -home "$PWD/.gnokey-dev"` (the `Makefile` does this automatically).

#### What you need

- `docker compose --profile phase2 up -d validator4` (or `make up-validator4`)
- The `dev` gnokey account (see "Local dev accounts" above) — funded in genesis
  and the only `auth.unrestricted_addrs` entry.
- The `v4op` gnokey account — validator4's operator key; `Register()` requires
  the caller to be the registered operator address (anti-squat guard).

Both accounts live in `.gnokey-dev/` with passphrase `devpassword123`. All
`gnokey` commands below use the **local `gnokey` binary** with
`-home "$PWD/.gnokey-dev"`. The dockerized `gno-gnokey:local` image does *not*
work for these commands out of the box: a plain `docker run` (without
`--network`) can't reach `localhost:26658`, since the validator's RPC port is
only published on the host.

#### Steps

1. **Initialize GovDAO** (one-time on this devnet — genesis deploys the
   GovDAO v3 packages, and `r/gov/dao/v3/loader`'s automatic `init()` sets up
   empty T1/T2/T3 tiers with **0 members**, so no proposal could ever reach
   the 66.66% supermajority quorum until a member is seeded):

   `InitWithUsers(addrs ...address)` has no `cur realm` parameter (it's a
   "non-crossing" function), so it can't be called with `maketx call`
   (`MsgCall`) — it needs `maketx run` (`MsgRun`) with a small script. The
   import alias must *not* be `init` (reserved for the `func init()`
   builtin); `init-govdao.gno` (rendered by `bootstrap.sh` from
   `init-govdao.gno.tmpl`, with your live `dev` address injected) uses
   `govdaoinit` instead:

   ```go
   // init-govdao.gno (rendered from init-govdao.gno.tmpl; <DEV_ADDR> is your
   // live `dev` address, substituted by bootstrap.sh)
   package main

   import (
       govdaoinit "gno.land/r/gov/dao/v3/init"
   )

   func main(cur realm) {
       govdaoinit.InitWithUsers(cross(cur), address("<DEV_ADDR>"))
   }
   ```

   ```bash
   gnokey maketx run \
     -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
     -chainid dev -remote http://localhost:26658 \
     -home "$PWD/.gnokey-dev" dev init-govdao.gno
   ```

   This only works because the genesis `chain_id` is `"dev"`
   (`InitWithUsers` calls `assertIsDevChain()`). It resets the memberstore and
   makes `dev` the sole GovDAO "T1" member — any proposal `dev` votes YES on
   reaches the 66.66% supermajority alone.

2. **Get validator4's bech32 pubkey** from its secrets:

   ```bash
   docker run --rm --entrypoint gnoland \
     -v "$PWD/validator4/gnoland-data:/gnoroot/gnoland-data" \
     gno-validator:local secrets get -data-dir /gnoroot/gnoland-data/secrets validator_key
   ```

   This returns validator4's address + pubkey (example — yours will differ;
   they are also written to `.devaddrs.mk` as `VALIDATOR4_ADDR` /
   `VALIDATOR4_PUB`):
   - address: `g132qwl9...`
   - pub_key: `gpub1pgg...`

3. **Register validator4 as a valoper** (pays the 20 GNOT `minFee`):

   ```bash
   gnokey maketx call \
     -pkgpath gno.land/r/gnops/valopers -func Register \
     -args "samourai-crew-4" \
     -args "Phase 2 test validator for gnomonitoring" \
     -args "on-prem" \
     -args "$(awk '/VALIDATOR4_OP_ADDR/{print $3}' .devaddrs.mk)" \
     -args "$(awk '/VALIDATOR4_PUB/{print $3}' .devaddrs.mk)" \
     -send 20000000ugnot -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
     -chainid dev -remote http://localhost:26658 \
     -home "$PWD/.gnokey-dev" v4op   # Register must be signed by the operator key
   ```

   (The 4th arg is the **operator** address `VALIDATOR4_OP_ADDR` = the `v4op`
   key, which must also be the signer; the 5th is validator4's BFT pubkey.)

4. **Create the GovDAO proposal** to add validator4 to the valset. This
   chains two realm calls (`proposal.NewValidatorProposalRequest` →
   `dao.MustCreateProposal`), so it needs `maketx run` with a small script:

   ```go
   // propose-validator4.gno (rendered from propose-validator4.gno.tmpl;
   // <V4OP_ADDR> is your live `v4op` operator address)
   package main

   import (
       "gno.land/r/gov/dao"
       "gno.land/r/gnops/valopers/proposal"
   )

   func main(cur realm) {
       pr := proposal.NewValidatorProposalRequest(cross(cur), address("<V4OP_ADDR>"))
       dao.MustCreateProposal(cross(cur), pr)
   }
   ```

   `propose-validator4.gno` is rendered by `bootstrap.sh` from
   `propose-validator4.gno.tmpl` (with your live `v4op` address), so:

   ```bash
   gnokey maketx run \
     -gas-fee 1000000ugnot -gas-wanted 100000000 -broadcast \
     -chainid dev -remote http://localhost:26658 \
     -home "$PWD/.gnokey-dev" dev propose-validator4.gno
   ```

   This creates proposal `#0` (first proposal on this devnet, assuming GovDAO
   was just reinitialized in step 1).

5. **Vote YES** (as the sole T1 member, 100% ≥ 66.66% supermajority):

   ```bash
   gnokey maketx call \
     -pkgpath gno.land/r/gov/dao -func MustVoteOnProposalSimple \
     -args 0 -args YES \
     -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
     -chainid dev -remote http://localhost:26658 \
     -home "$PWD/.gnokey-dev" dev
   ```

6. **Execute the proposal** — adds validator4 to `r/sys/validators/v3`:

   ```bash
   gnokey maketx call \
     -pkgpath gno.land/r/gov/dao -func ExecuteProposal \
     -args 0 \
     -gas-fee 1000000ugnot -gas-wanted 50000000 -broadcast \
     -chainid dev -remote http://localhost:26658 \
     -home "$PWD/.gnokey-dev" dev
   ```

7. **Verify validator4 joined the valset and started signing**:

   ```bash
   gnokey query vm/qeval \
     -data "gno.land/r/sys/validators/v3.IsValidator(\"$(awk '/VALIDATOR4_ADDR/{print $3}' .devaddrs.mk)\")" \
     -remote http://localhost:26658
   curl -s http://localhost:26661/status | jq '.result.validator_info'
   ```

#### What to check in gnomonitoring

- a GovDAO "New Proposal" alert fired when the proposal was created (step 4) —
  `internal/govdao`
- `gnoland_chain_active_validators{chain="local"}` increments from 3 to 4
- validator4's address (`VALIDATOR4_ADDR` in `.devaddrs.mk`) appears in
  `daily_participations` for `chain="local"`
- the moniker for that address resolves to `samourai-crew-4` (from
  `valopers.Render()` via the MonikerMap refresh)

> **GovDAO alert delivery — important timing.** The "New Proposal" alert is only
> sent for proposals seen **live over the GovDAO websocket** (`who == "socket"`
> in `ProcessProposal`). A proposal created while the backend isn't live-watching
> `dev` (e.g. right after a chain reset, before you restarted the backend) is
> picked up by the startup catch-up scan → inserted into the `govdaos` table
> **without** an alert. So the correct order is: reset chain → **restart the
> backend** (websocket reconnects) → *then* create the proposal.
>
> Delivery channels: the alert goes to every `webhook_gov_daos` row (Discord/
> Slack) **and** to the GovDAO Telegram bot (`token_telegram_govdao`) for all
> subscribed chats. On a fresh devnet there is usually **no `webhook_gov_daos`
> row for `dev`**, so the alert only reaches Telegram — check the GovDAO bot, not
> a Discord/Slack channel. Either way the proposal is tracked in `govdaos`.

---

### Scenario 2 — Validator downtime / recovery alerts

Exercises the WARNING → CRITICAL → RESOLVED alert flow and webhook delivery
(`metric.go`, `alert_logs`).

This targets **validator4** (run `make scenario1` first so it's in the valset
with voting power 1). Its power is tiny, so stopping it lowers its own
participation rate **without halting the chain** — the clean way to trigger a
per-validator missed-block alert. (Stopping a genesis validator with power
10/11 instead risks halting consensus; that's Scenario 3.)

1. Stop validator4:

   ```bash
   make scenario2          # docker compose stop validator4
   ```

2. Wait until validator4 has missed ≥5 blocks → **WARNING**, then ≥30 →
   **CRITICAL**.

3. Restart it:

   ```bash
   make scenario2-restart  # docker compose start validator4
   ```

4. Once validator4 participates again at `end_height + 1`, expect a **RESOLVED**
   alert.

5. Check `alert_logs` for the WARNING/CRITICAL/RESOLVED rows:

   ```bash
   docker exec gnomonitoring-postgres psql -U gnomonitoring -d gnomonitoring \
     -c "SELECT level, start_height, end_height FROM alert_logs \
         WHERE chain_id='dev' AND addr='$(awk '/VALIDATOR4_ADDR/{print $3}' .devaddrs.mk)' ORDER BY id;"
   ```

---

### Scenario 3 — Halt the chain (insufficient voting power)

Exercises gnomonitoring's behavior when the chain stops producing blocks
entirely — the global stagnation/RPC-error alert path described in
`CLAUDE.md` under "Known Limitations".

With voting power 10/10/11 (total 31), more than 2/3 is 21. Stopping **any
2** of the 3 genesis validators leaves at most 11/31 ≈ 35%, well below the
66.67% supermajority CometBFT needs to commit blocks — the chain halts
deterministically:

```bash
docker compose stop validator2 validator3   # leaves only validator (power 10/31)
```

#### What to observe

- `gnoland_chain_current_height{chain="local"}` stops increasing
- the global stagnation/RPC-error alert fires
- no new `daily_participations` rows are inserted for any validator while
  halted

#### Recovery

```bash
make scenario3-restart   # docker compose start validator2 validator3
```

**Known issue:** restarting a stopped node can crash-loop with:

```text
panic: Cannot make VoteSet for height == 0, doesn't make sense.
```

This happens when `priv_validator_state.json` (the last *attempted* vote) ends
up one height ahead of the node's committed blockstore/state height. `bootstrap.sh`
now resets that state file on every run (so a fresh `full-reinit` no longer
hits it), but if a running chain gets stuck and `scenario3-restart` doesn't
recover it within a minute or two, do a reset:

```bash
make reinit        # wipe chain state, keep identities, restart
# or, if it's still wedged:
make clean-all && make full-reinit
```

This wipes chain state while keeping (reinit) or regenerating (clean-all) the
node identities. Acceptable for a devnet — there is no real data to preserve.

### Scenario — Dead second chain must not delay GovDAO notifications

Reproduces the 2026-11-09 incident. pearl-1 was enabled while its RPC endpoints
were dead: one failed DNS resolution at once, the other accepted connections and
never answered, so each call waited for the 60 s RPC timeout. The GovDAO status
watcher checked every proposal of every chain one after the other, so gnoland-1's
ACCEPTED notification went out about an hour late.

```bash
make dev-up                       # fresh chain: the scenario targets proposal #0
make scenario-govdao-dead-chain   # ~10 min, prints PASS or FAIL
```

`scenario-govdao-dead-chain.sh` does the following:

1. It restarts the backend with a second enabled chain, `deadnet`. One of its RPC
   endpoints cannot be resolved. The other is a `deadnet-rpc` container that
   accepts connections and never answers.
2. It seeds 10 `IN PROGRESS` proposals for `deadnet`.
3. It creates proposal #0 on `dev` and checks that `govdaos` tracks it as
   `IN PROGRESS`. Then it votes YES and executes the proposal (scenario1's two
   halves, `scenario1-propose` and `scenario1-execute`).
4. It waits for the status cycle that sees #0 accepted, and asserts the
   following for that cycle:
   - dev's `proposal 0 (...) accepted` line is logged;
   - `deadnet` fails once, then is given up on at its 2nd failure
     (`every RPC endpoint failed on 2 proposals in a row`), instead of being
     polled 10 times;
   - dev's line comes before `deadnet` is given up on, so dev did not wait
     behind the dead chain;
   - `govdaos` stores #0 as `ACCEPTED`.
5. When it exits, on success or failure, it restores the normal backend and
   deletes every `deadnet` row.

The scenario needs `python3` with PyYAML, which it uses to write the scenario
config. Without the fix, the cycle spends ~60 s on each of `deadnet`'s
proposals, and no skip line is ever logged.

### Scenario — GovDAO-voted chain halt

Needs the dev stack (`make dev-up`) on gno v1.8.0 or later, and a chain past
block ~50: the script measures the block pace over the last 50 blocks, and
block 1 carries the genesis time, which is older than the chain after a
`make dev-up` reset.

```bash
make dev-up
make scenario-halt   # ~10 min, prints PASS or FAIL
```

`scenario-halt.sh` shortens the reminder thresholds, makes the `dev` account a
T1 GovDAO member, proposes `r/sys/params.NewSetHaltRequest(height, MIN_VERSION)`,
votes YES and executes it, waits for the chain to halt and resume, then asserts
the `alert_logs` halt rows. See the script header for the details and the
variables it accepts (`MIN_VERSION`, `REMINDER_MINUTES`, `LEAD_SECONDS`, ...).

