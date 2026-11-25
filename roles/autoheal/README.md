# roles/autoheal

Detect a stuck gnoland node (block height frozen, `catching_up=false`) and
automatically restore it from the latest chain snapshot on Scaleway Object
Storage, then verify it caught back up. Deployed on **both** the sentry and
the validator host (see `install-autoheal.yml`) — unlike `roles/snapshotter`,
which only runs on the sentry.

## How it works

```
gno-autoheal-check.timer (every 3 min, OnCalendar)
        │
        ▼
check-stuck.sh   — reads /status, tracks consecutive stuck samples in
                    /var/lib/gno-autoheal/<node_type>.state
        │ after autoheal_stuck_threshold (default 3) consecutive hits
        ▼
autoheal.sh      — lock+cooldown (default 30 min) → pull-from-s3.sh → stop
                    node (+tmkms, verify exited for the validator) →
                    incident backup (+ local prune, keep 3) → [validator:
                    re-verify exited] → restore.sh --yes → restart (tmkms
                    after gnoland) → poll for catch-up (20 min timeout)
```

The snapshot pull comes first on purpose: it is read-only, so a failed pull
(expired S3 key, network blip) aborts with the node still running and
untouched, instead of leaving it stopped with no restore.

A node whose RPC is unreachable is treated as DOWN, not stuck, and never
triggers an auto-restore — a container that won't start needs investigation,
not a data restore.

**GovDAO-voted chain halt.** A halt voted on chain (param
`node:p:halt_height` = H, with the required image in `node:p:halt_min_version`)
stops every node of the network on purpose until operators upgrade. Such a node
looks stuck, but a restore would only restart the old image, and on a
validator it is the whole-network-halt case of the limitation below. Before
counting a stuck sample, `check-stuck.sh` reads `halt_height` from the local
RPC (`abci_query path="params/node:p:halt_height"`). When the frozen height is
H (node still on the old image: gno v1.8.0 commits H, saves H+1, then panics
in BeginBlock(H+1), so `/status` reports H) or H+1 (node already on the new
image, waiting for quorum after replaying H+1), it logs `voted halt at H,
waiting for upgrade to <halt_min_version>`, resets the counter, takes no
action and sends a `voted-halt-wait` webhook alert (first time, then every
`autoheal_halt_alert_interval_seconds`, default 1 h). `autoheal.sh` runs the
same check first and refuses to restore (alert `restore-skipped`), so a manual
run is guarded too; use `restore.sh` directly if a restore at a halt is really
intended. If the `halt_height` query fails, the halt state is unknown: on the
**validator** no restore happens (the sample is not counted, `halt-unknown`
alert at most every interval, `autoheal.sh` refuses), because a restore during
a whole-network halt can deadlock consensus; on the **sentry** both scripts log
it and keep the pre-guard behavior (restore). Upgrade the node as usual (`DEPLOYMENT_RUNBOOK.md` §5);
detection resumes normally once the node moves past H+1. Limitation:
`halt_height` stays set on chain after the network resumes, and the guard does
not compare with the network head, so a node that later freezes at exactly H
or H+1 is not restored automatically; the hourly alert is the signal. Tests: `roles/autoheal/tests/test-halt-guard.sh` (fake RPC, no
node needed; needs `jq` and Python `jinja2`, runs `shellcheck` if installed).

## Anti-double-sign (validator)

The archive restored is chain data only (`gnoland-data/db`) — it never
touches `node_key`, tmkms's `consensus.key`, `kms-identity.key` or
`consensus_state.json` (the double-sign HRS gate). Before wiping anything,
`autoheal.sh` stops `validator`+`tmkms` and verifies via `docker compose ps -a`
that both are `exited`; if either isn't, it aborts and alerts instead of
touching data.

**Known limitation — validator restore during a whole-network halt.**
Auto-heal is safe for its main target: a single validator lagging behind a
*healthy, progressing* network. Restoring chain data while leaving tmkms's
`consensus_state.json` untouched never conflicts with a live round that's
already well past whatever tmkms remembers — this is the common case and
needs no special handling. It is NOT safe if the entire network has halted
(lost quorum) and the validator is restored *while still frozen mid-round*:
on resume it can rejoin at the exact same in-flight height/round tmkms
already partially signed, which tmkms correctly refuses as a step
regression — a refusal that can permanently deadlock that validator (and
the network, if its power is needed for quorum). `autoheal.sh`'s catch-up
verification requires the height to advance past the post-restore tip (not
just `catching_up=false`), so this failure mode times out and alerts rather
than going silent — but recovery from it is manual. A real fix (deliberately
advancing tmkms's state) touches double-sign protection directly and is out
of scope for this role; operators should not trigger auto-heal on a
validator while the wider network is known to be down.

## Deploy

```bash
ansible-playbook -i inventory.yaml install-autoheal.yml --tags autoheal
```

Then, on each host, in the node's own deploy dir:

```bash
cp autoheal.env.example .env && chmod 600 .env
# fill: SCW_ACCESS_KEY/SCW_SECRET_KEY (a READ-ONLY Scaleway key is enough —
# this host only ever downloads) + WEBHOOK_URL
systemctl enable --now gno-autoheal-check.timer
systemctl list-timers gno-autoheal-check.timer
```

## Variables

See `defaults/main.yml`. `autoheal_s3_bucket` / `autoheal_s3_prefix` MUST
match `roles/snapshotter`'s `snapshotter_s3_bucket` / `snapshotter_s3_prefix`
on the sentry — both node types pull from the same bucket/prefix the sentry
pushes to.

## Manual trigger / incident review

```bash
./check-stuck.sh          # one detection pass (safe, read-only)
./autoheal.sh              # force a restore now, bypassing detection
ls /var/lib/gno-autoheal/incidents/   # pre-restore backups (forensic; not uploaded anywhere)
```

Only the newest `autoheal_incident_keep_last` (default 3) archives are kept;
older ones are pruned automatically after each successful incident backup.

> **Warning — these archives contain secrets.** An incident archive is a full
> copy of `gnoland-data`, including `secrets/priv_validator_key.json`. Never
> copy one off-box unencrypted, and never point a log/backup shipping job
> (e.g. a `backup-logs.yaml`-style SCP job) at the auto-heal state directory.
