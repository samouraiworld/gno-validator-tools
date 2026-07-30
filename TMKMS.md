# TMKMS — Externalized Validator Signing

Operational reference for [tmkms](https://github.com/iqlusioninc/tmkms) on Gnoland
validators in this repo: what it is, how to deploy it (one host or two), what
must be backed up, what's safe to delete, and how to restore — including
restoring a validator from a `roles/snapshotter` chain snapshot without
double-signing.

Backend used everywhere in this repo: **softsign** (key in a file, `0600`).
Cloud instances (Scaleway) have no USB passthrough, so YubiHSM/Ledger are not
an option — see `.claude/tmkms-migration-plan.md` §2 for the reasoning.

---

## 1. What tmkms changes

Normally gnoland signs its own consensus votes/proposals with
`priv_validator_key.json`. With `tmkms_listener` mode:

- **gnoland listens** on a privval socket (UDS or TCP); it no longer signs.
- **tmkms dials in and signs**, holding the consensus key instead.
- `priv_validator_key.json` becomes unused for signing once tmkms takes over
  (only `node_key.json`, the P2P identity, still matters on the gnoland side).

Three distinct ed25519 keys — don't confuse them:

| Key | Lives in | Role |
|---|---|---|
| consensus | tmkms (`consensus.key`, softsign) | signs votes/proposals; its pubkey = validator identity in genesis |
| kms-identity | tmkms (`kms-identity.key`) | tmkms's SecretConnection identity; pubkey goes in `allowed_kms_pubkeys` (**TCP only** — ignored in `unix://`) |
| node key | gnoland (`node_key.json`) | gnoland's P2P identity (peer-id); unrelated to signing |

Config: 4 fields under `consensus.priv_validator.tmkms_listener.*`
(`chain_id`, `protocol_version`, `allowed_kms_pubkeys`, `listen_addr`).
`validator/entrypoint.sh` sets them at container start, **`listen_addr` last**
— setting it before the other three is silently rejected.

`1 tmkms softsign process = 1 consensus key = 1 validator` (verified
empirically — a second `[[providers.softsign]]` on the same `chain_id`
errors at startup). N validators need N tmkms instances; this is not a
load-balancing/HA mechanism (see Horcrux for that, out of scope here).

---

## 2. Two topologies

| | Same host (UDS) | Two hosts (TCP) |
|---|---|---|
| Transport | Unix socket, shared Docker volume | TCP, firewalled |
| Isolation | Process isolation only — key still lives on the exposed validator box | Real host isolation — key lives on a separate, non-P2P-exposed box |
| Auth | Socket file perms (`0600`) | `allowed_kms_pubkeys` (tmkms's pubkey) **+** peer-id pinned in tmkms's `addr` |
| Ansible support | ✅ `roles/tmkms/` + `3-install-validator-node.yml` (`tmkms_enabled: true`) | ❌ not yet a role — manual procedure, see §4 |
| Reference impl | This repo, prod | `tmkms-lab/` (lab, 2 Vagrant/cloud VMs) + `.claude/tmkms-tcp-test-runbook.md` |

UDS is what's deployed on `gno-test14` today. TCP is the documented upgrade
path when you want the signer off the validator box (the real security win
on cloud, since softsign is "key in a file" either way — see
`.claude/tmkms-migration-plan.md` §5-6).

---

## 3. Deploying on one machine (UDS sidecar)

Prerequisites: `1-base_setup.yml` already ran on the target (docker, ufw,
gnoland binary). A `gno_image` that includes `tmkms_listener` support (PR
[#5718](https://github.com/gnolang/gno/pull/5718), commit `a870686e4` —
merged in `chain/topaz`; check any other chain branch before assuming it's
there).

```bash
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e target=gno-validator \
  -e tmkms_enabled=true \
  -e tmkms_chain_id=<chain_id-matching-genesis> \
  --tags tmkms,config,compose
```

- `--tags config` is required (not just `tmkms,compose`) so
  `docker-validator*.yml.j2` gets **re-rendered** with the `tmkms:` service +
  `TMKMS_*` env — otherwise `docker compose up` reuses a stale compose file
  without the sidecar. `config` also re-downloads `genesis_url`/`config_url`
  — **back up `genesis.json`/`config.toml` first** if you hand-crafted them
  (e.g. a `-lazy` throwaway genesis), then restore them after the run.
- `include_role: tmkms` must carry `apply: tags: [tmkms]` (fixed in this
  repo) — without it, `--tags tmkms` selects the include statement but
  **silently skips every task inside the role** (dynamic includes don't
  propagate tags to their children by default), including the image build.
  Symptom if this regresses: `docker compose up` tries to `pull tmkms:local`
  and fails with "repository does not exist".

What the role does (`roles/tmkms/tasks/main.yml`, idempotent, safe to re-run):
assert `tmkms_chain_id`, install `jq`, create `tmkms/{,secrets,run}`, ensure
`priv_validator_key.json` exists (via `gnoland secrets init` in a throwaway
container if missing), build `tmkms:local` from `files/Dockerfile` (or use a
pre-pushed image if `tmkms_build_image: false`), render `tmkms.toml`, reslice
the 32-byte seed out of `priv_validator_key.json` into `secrets/consensus.key`
(`creates:` guarded — never silently overwritten), generate
`secrets/kms-identity.key` once.

Verify: `docker compose logs tmkms` → `signed Proposal/Prevote/Precommit`;
`docker compose logs validator` → `Committed state`. Kill the `tmkms`
container → the chain stalls at the next round; restart it → resumes. That's
proof signing is externalized.

---

## 4. Deploying on two machines (TCP signer)

Not yet an Ansible role — reproduce the proven manual flow in
`tmkms-lab/README.md` (lab naming: VM1 = validator+sentry, VM2 = signer;
in prod, use your real validator host as "VM1" and a dedicated non-P2P-exposed
box as "VM2"):

1. **Validator host**: bootstrap secrets + genesis (or, in prod, already has
   them from a normal install). Get the validator's **hex peer-id**
   (`gnoland secrets get` / printed by `bootstrap.sh` in the lab).
2. **Copy the consensus key to the signer host**: reslice it there (same
   `roles/tmkms` reslice logic, or `tmkms-lab/tmkms/setup-vm2-tmkms.sh` as a
   reference script) — `scp` the resliced `consensus.key`, never the raw
   `priv_validator_key.json`, over a channel you control.
3. **Signer host**: build/run `tmkms:local`, render `tmkms.toml` with
   `addr = "tcp://<peer-id>@<validator-ip>:26659"` (peer-id is **mandatory**
   in TCP — an unpinned `addr` lets tmkms sign for an impostor). Start it,
   note the printed `ed25519:...` — that's the `kms-identity` pubkey.
4. **Validator host**: set `TMKMS_ALLOWED_KMS_PUBKEYS` (a.k.a. `TMKMS_ALLOW`)
   to that `ed25519:...` value (**required** in TCP — empty = fail-open,
   accepts any signer), open the firewall to the signer IP only on 26659,
   deny it globally otherwise, start the validator.
5. Verify the same way as §3 (stop/start the signer, watch the chain stall
   and resume).

Full walkthrough with exact commands: `tmkms-lab/README.md`. TCP-specific
pitfalls (image tag drift, peer-id, allowlist): `.claude/tmkms-tcp-test-runbook.md`.

---

## 5. What to back up — out-of-band, never in a chain snapshot

`roles/snapshotter` archives are **chain data only**
(`gnoland-data/db`, wal excluded) — deliberately free of secrets so archives
can sit in object storage. tmkms material is a **separate, encrypted, offline**
backup (e.g. Vaultwarden — see `.claude/tmkms-migration-plan.md` §8).

| File | Where (same-host UDS) | Criticality | If lost |
|---|---|---|---|
| `tmkms/secrets/consensus.key` | validator host | 🔴 **the validator identity** | irrecoverable — the validator can never sign again under that pubkey |
| `tmkms/secrets/consensus_state.json` | validator host | 🔴 anti-double-sign high-water mark (height/round/step) | restoring an **older** copy risks a double-sign / slashing |
| `gnoland-data/secrets/node_key.json` | validator host | 🟠 P2P peer-id | peer-id changes → update `PERSISTENT_PEERS`/`PRIVATE_PEER_IDS` on the sentry side |
| `tmkms/secrets/kms-identity.key` | validator host | 🟡 low in UDS (auth is socket perms, not this key); 🟠 in TCP (= `allowed_kms_pubkeys`) | regenerate; in TCP, update the allowlist afterward |
| `gnoland-data/secrets/priv_validator_key.json` | validator host | source of `consensus.key` (reslice) — becomes non-authoritative once tmkms signs | fine, as long as `consensus.key` is already backed up (see §6) |

Two-host TCP topology: same table but `consensus.key` /
`consensus_state.json` / `kms-identity.key` live on the **signer** host, not
the validator — see `tmkms-lab/README.md` §"Backup — what to save absolutely"
for the exact 4-row table used there.

**Golden rule:** never restore `consensus_state.json` from an older backup
than what the key has already signed. When in doubt, treat it as
append-only.

---

## 6. What's safe to delete

Only **after** confirming tmkms signs (§3/§4 "Verify") **and** `consensus.key`
is safely backed up out-of-band:

- ✅ `gnoland-data/secrets/priv_validator_key.json` — unused for signing once
  `tmkms_listener` is active. Record the validator pubkey first
  (`gnoland secrets get validator_key.pub_key` reads this file before you
  delete it; it's also in `genesis.json`).
- ❌ keep `node_key.json`, `genesis.json`, `config.toml` — always.
- `priv_validator_state.json` (the old local HRS file) stops being
  authoritative once tmkms's `consensus_state.json` takes over — harmless to
  leave in place, no need to back it up.
- `tmkms/run/*.sock` — ephemeral socket, recreated on start, never back up.

---

## 7. Key rotation

The reslice task is `creates:`-guarded on `tmkms/secrets/consensus.key`, so
re-running the role **never** silently rotates the key. To force a refresh
from the *same* `priv_validator_key.json` (e.g. after fixing a corrupted
`consensus.key`):

```bash
rm /root/<gno_dir>/tmkms/secrets/consensus.key
ansible-playbook -i inventory.yaml 3-install-validator-node.yml \
  -e target=gno-validator -e tmkms_enabled=true -e tmkms_chain_id=<chain_id> \
  --tags tmkms
```

This re-derives the **same** key — it is not a true rotation. A genuine
identity change (new pubkey) means generating a fresh
`priv_validator_key.json` (new `gnoland secrets init` in a clean dir) and
getting that new pubkey accepted into the active validator set — a
chain-level/governance action outside this repo's Ansible, not just a file
swap.

---

## 8. Restoring a validator from a snapshot (no double-sign)

Chain-data restore uses `roles/snapshotter/files/restore.sh` — it stops the
service, wipes `gnoland-data/{db,wal}`, extracts the archive, restarts. It
has a **built-in guard** when the target service is `validator`:

```bash
./restore.sh /root/<gno_dir> <archive>.tar.zst validator
```

It prints an anti-double-sign checklist and asks for confirmation before
proceeding. The checklist (enforce it manually — the script cannot verify
these for you):

1. **The old validator + its tmkms must be fully dead** — never run two
   signers off the same `consensus.key` at once, even briefly.
2. Restore the validator's **own** key material from your out-of-band backup
   (§5) **before** restarting: `node_key.json` (gnoland side), and
   `tmkms/secrets/consensus.key` + `consensus_state.json` +
   `kms-identity.key` (tmkms side). None of these come from the snapshot
   archive — the archive is chain data only.
3. The restored `consensus_state.json`'s height/round/step must be **≥**
   whatever that key last signed. If unsure which copy is newer, treat the
   most recent one you have as authoritative and never go backwards.

Sequence:

```bash
# 1. Fetch the archive (see roles/snapshotter/README.md for the S3 pull)
rclone copy scw:$S3_BUCKET/$S3_PREFIX/<height>-<ts>.tar.zst ./snapshots/

# 2. Make sure old validator + tmkms are stopped everywhere
docker compose stop tmkms validator     # on whichever host(s) were running

# 3. Put back the validator's own secrets from your encrypted backup
#    (tmkms/secrets/{consensus.key,consensus_state.json,kms-identity.key},
#    gnoland-data/secrets/node_key.json) — do this BEFORE step 4.

# 4. Restore chain data
./restore.sh /root/<gno_dir> ./snapshots/<height>-<ts>.tar.zst validator

# 5. Bring the stack up and verify (§3 "Verify")
docker compose up -d
docker compose logs -f tmkms       # "signed Precommit..."
docker compose logs -f validator   # "Committed state", height climbing
```

Cold (GLACIER-tier) archives need thawing first — see
`roles/snapshotter/README.md` "Restore" section for the lifecycle/RTO notes.

---

## 9. File map (same-host UDS deploy)

```
/root/<gno_dir>/
├── docker-compose.yml            # rendered from docker-validator[-standalone].yml.j2
├── genesis.json, config.toml     # regenerable — keep for convenience, not secret
├── gnoland-data/
│   └── secrets/
│       ├── node_key.json         # 🟠 back up (P2P identity)
│       └── priv_validator_key.json  # deletable once tmkms confirmed + consensus.key backed up
└── tmkms/
    ├── tmkms.toml                 # regenerable (rendered by the role)
    ├── run/                       # ephemeral socket dir — never back up
    └── secrets/
        ├── consensus.key          # 🔴 back up — THE validator key
        ├── consensus_state.json   # 🔴 back up — anti-double-sign gate
        └── kms-identity.key       # 🟡/🟠 back up — regenerable but convenient
```

## References

- `roles/tmkms/README.md` — role internals, variables.
- `roles/snapshotter/README.md` — snapshot capture/push/restore, S3 lifecycle.
- `tmkms-lab/README.md` — full 2-VM TCP walkthrough + its own backup table.
- `.claude/tmkms-migration-plan.md` — design rationale, decisions, pitfalls log.
- `.claude/tmkms-tcp-test-runbook.md` — TCP-specific test runbook.
