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
| Ansible support | ✅ `roles/tmkms/` + `setup-tmkms.yml` (`tmkms_connection_mode: "uds"`, default) | ✅ `roles/tmkms/` + `setup-tmkms.yml` (`tmkms_connection_mode: "tcp"`), on the dedicated signer host |
| Compose | `compose/validator-sentry-tmkms/` | `compose/validator-alone/` (validator host) + `compose/tmkms-alone/` (signer host) |
| Reference impl | This repo, prod | `tmkms-lab/` (proven 2-VM lab pattern, reused as-is by the role) + `.claude/tmkms-tcp-test-runbook.md` |

UDS is what's deployed on `gno-test14` today. TCP is the upgrade path when
you want the signer off the validator box (the real security win on cloud,
since softsign is "key in a file" either way — see
`.claude/tmkms-migration-plan.md` §5-6), now equally supported by
`roles/tmkms/` — see §4.

---

## 3. Deploying on one machine (UDS sidecar)

Prerequisites: `base_setup.yml` already ran on the target (docker, ufw,
gnoland binary). A `gno_image` that includes `tmkms_listener` support (PR
[#5718](https://github.com/gnolang/gno/pull/5718), commit `a870686e4` —
merged in `chain/topaz`; check any other chain branch before assuming it's
there).

```bash
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator \
  -e tmkms_chain_id=<chain_id-matching-genesis>
```

`tmkms_connection_mode` defaults to `"uds"`, no need to pass it explicitly.
No `--tags`/re-render gotcha here anymore: `compose/validator-sentry-tmkms/`
is a static compose file that already includes the `tmkms` service and the
`TMKMS_*` env unconditionally — nothing to re-render before
`docker compose up -d` (see `DEPLOYMENT_RUNBOOK.md` for the full manual
deployment sequence: secrets, non-secret files, `.env`, start).

What the role does (`roles/tmkms/tasks/main.yml`, idempotent, safe to re-run,
never generates gnoland secrets): assert `tmkms_chain_id`, install `jq`,
create `tmkms/{,secrets,run}`, assert `priv_validator_key.json` already
exists (fails with a clear message otherwise — run `gnoland secrets init`
manually first), build `tmkms:local` from `files/Dockerfile` (or use a
pre-pushed image if `tmkms_build_image: false`), render `tmkms.toml`, reslice
the 32-byte seed out of `priv_validator_key.json` into `secrets/consensus.key`
(`creates:` guarded — never silently overwritten), generate
`secrets/kms-identity.key` once. Full detail: `roles/tmkms/README.md`.

Verify: `docker compose logs tmkms` → `signed Proposal/Prevote/Precommit`;
`docker compose logs validator` → `Committed state`. Kill the `tmkms`
container → the chain stalls at the next round; restart it → resumes. That's
proof signing is externalized.

---

## 4. Deploying on two machines (TCP signer)

Now a first-class mode of `roles/tmkms/` (`tmkms_connection_mode: "tcp"`),
reusing the proven `tmkms-lab/` pattern rather than reinventing it. The role
runs on the **dedicated signer host** (not the validator), which needs
`base_setup.yml`'s `docker` role but not the rest of the gnoland stack.

1. **Validator host**: secrets already initialized (`gnoland secrets init`
   manual, see `DEPLOYMENT_RUNBOOK.md`). Get the validator's **hex peer-id**
   (`gnoland secrets get` → `node_id.id`).
2. **Reslice the consensus key on the validator host and copy it to the
   signer host** — the role does not do this for you in tcp mode (the
   validator's `priv_validator_key.json` lives on a different host than the
   one the role runs on):

   ```bash
   # on the validator host
   jq -r '.priv_key.value' gnoland-data/secrets/priv_validator_key.json \
     | base64 -d | head -c 32 | base64 -w0 > consensus.key
   scp consensus.key <signer-host>:/root/<gno_dir>/tmkms/secrets/consensus.key
   ```

   (same one-liner `roles/tmkms` uses internally for uds mode; see also
   `tmkms-lab/tmkms/setup-vm2-tmkms.sh` step 2 for the reference lab flow).
3. **Signer host**: run the role —

   ```bash
   ansible-playbook -i inventory.yaml setup-tmkms.yml \
     -e target=<signer-host> \
     -e tmkms_connection_mode=tcp \
     -e tmkms_chain_id=<chain_id-matching-genesis> \
     -e tmkms_validator_peer_id=<hex-from-step-1> \
     -e tmkms_validator_ip=<validator-ip>
   ```

   Builds `tmkms:local`, asserts `secrets/consensus.key` is present (from
   step 2, fails with the exact `scp` command otherwise), generates
   `kms-identity.key`, renders `tmkms.toml` with
   `addr = "tcp://<peer-id>@<validator-ip>:26659"` (peer-id pin is
   **mandatory** in TCP — an unpinned `addr` lets tmkms sign for an
   impostor), derives and prints the `ed25519:...` kms-identity pubkey.
   Then deploy `compose/tmkms-alone/` manually (`docker compose up -d`).
4. **Validator host**: fill `TMKMS_CHAIN_ID`, `TMKMS_LISTEN_ADDR`
   (`tcp://0.0.0.0:26659`) and `TMKMS_ALLOWED_KMS_PUBKEYS` (the
   `ed25519:...` printed in step 3 — **required** in TCP, empty = fail-open,
   accepts any signer) in `compose/validator-alone/.env`. Open the firewall
   to the signer host's IP only on port 26659 (`ufw_tmkms_port` +
   `ufw_tmkms_signer_ip` in `base_setup.yml`'s `ufw` role — see
   `roles/ufw/README.md`), start the validator.
5. Verify the same way as §3 (stop/start the signer, watch the chain stall
   and resume).

Full manual reference walkthrough (useful to understand every step in
isolation, or for a non-Ansible host): `tmkms-lab/README.md`. TCP-specific
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
ansible-playbook -i inventory.yaml setup-tmkms.yml \
  -e target=gno-validator -e tmkms_chain_id=<chain_id>
```

(add `-e tmkms_connection_mode=tcp -e tmkms_validator_peer_id=... -e
tmkms_validator_ip=...` and target the signer host instead, for the TCP
topology — but note step 2 in §4 must be redone too in that case: the
signer host doesn't reslice locally, the fresh key must be copied there
again from the validator host.)

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

## 9. File map

### Same-host UDS deploy (`compose/validator-sentry-tmkms/`, validator host)

```
/root/<gno_dir>/
├── docker-compose.yml            # static, compose/validator-sentry-tmkms/docker-compose.yml
├── .env                          # IMAGES, MONIKER(_*), PERSISTENT_PEERS(_*), TMKMS_CHAIN_ID...
├── sentry/
│   ├── entrypoint.sh, config.toml, genesis.json   # pushed by hand — see DEPLOYMENT_RUNBOOK.md
│   └── gnoland-data/
├── validator/
│   ├── entrypoint.sh, config.toml, genesis.json   # pushed by hand
│   ├── otel/otel-config.yaml
│   └── gnoland-data/
│       └── secrets/
│           ├── node_key.json         # 🟠 back up (P2P identity)
│           └── priv_validator_key.json  # deletable once tmkms confirmed + consensus.key backed up
└── tmkms/                         # staged by setup-tmkms.yml, NOT by hand
    ├── tmkms.toml                 # regenerable (rendered by the role)
    ├── run/                       # ephemeral socket dir — never back up
    └── secrets/
        ├── consensus.key          # 🔴 back up — THE validator key
        ├── consensus_state.json   # 🔴 back up — anti-double-sign gate
        └── kms-identity.key       # 🟡/🟠 back up — regenerable but convenient
```

### Two-host TCP deploy — signer host (`compose/tmkms-alone/`)

```
/root/<gno_dir>/                   # gno_dir here is just a directory name —
│                                  # no gnoland node runs on this host
├── docker-compose.yml            # static, compose/tmkms-alone/docker-compose.yml
├── tmkms.toml                     # regenerable (rendered by setup-tmkms.yml)
├── kmsgen.go                      # pubkey derivation helper, staged by the role
└── secrets/
    ├── consensus.key              # 🔴 back up — THE validator key (copied in from the validator host, §4 step 2)
    ├── consensus_state.json       # 🔴 back up — anti-double-sign gate
    └── kms-identity.key           # 🟠 back up — TCP identity (= TMKMS_ALLOWED_KMS_PUBKEYS)
```

The validator host in this topology only needs `compose/validator-alone/`
with `TMKMS_*` filled in — no `tmkms/` directory there at all.

## References

- `roles/tmkms/README.md` — role internals, variables.
- `roles/snapshotter/README.md` — snapshot capture/push/restore, S3 lifecycle.
- `tmkms-lab/README.md` — full 2-VM TCP walkthrough + its own backup table.
- `.claude/tmkms-migration-plan.md` — design rationale, decisions, pitfalls log.
- `.claude/tmkms-tcp-test-runbook.md` — TCP-specific test runbook.
