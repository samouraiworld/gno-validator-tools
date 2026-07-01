# Snapshot & Restore — devnet runbook

Regular chain snapshots + fast node restore, tested on the local devnet.

## How it works

Snapshots are taken from a **dedicated non-signing full node** (`snapshotter`),
never from a validator or a sentry. It follows the chain over P2P like any
follower; `snapshot.sh` briefly stops it, tars its LevelDB, and restarts it — so
snapshotting has **zero impact** on the validators.

An archive contains **chain data only** (`gnoland-data/db`): no secrets, no
`wal/`, no config/genesis. That makes it **portable** — any node can restore it.
Each node keeps its own `node_key`, and the validator keeps its own consensus
key + tmkms state.

```
validator (tmkms) ─┐
validator2 / 3 ────┼─ P2P ─► snapshotter (non-signing)
                    │              │  stop → tar db → start
                    │              ▼
                    │   snapshots/<height>-<UTCts>.tar.zst   (keeps 24 most recent)
```

Prerequisites on the host: `docker`, `jq`, `zstd`, `curl`.

## 1. Start the snapshot node

```bash
make up-snapshotter        # starts the snapshotter (compose profile "snapshot")
make status                # wait until the chain is producing blocks
```

The snapshotter is not started by `make up`; it only runs when you want
snapshots. Give it time to sync (`catching_up: false` on port 26662).

## 2. Capture a snapshot

```bash
make snapshot              # one capture + rotation (keeps 24)
make snapshots             # list archives
```

Output: `snapshots/<height>-<UTCts>.tar.zst`. Override retention with
`RETENTION=48 make snapshot`.

### Automate (hourly, systemd --user)

```bash
mkdir -p ~/.config/systemd/user
sed "s#__DEVNET_DIR__#$PWD#g" systemd/gno-snapshot.service > ~/.config/systemd/user/gno-snapshot.service
cp systemd/gno-snapshot.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gno-snapshot.timer
systemctl --user list-timers gno-snapshot.timer
```

## 3. Restore — Procedure A: full node (fast bootstrap)

Bring any full node up to date from a snapshot instead of replaying from
genesis. No slashing risk.

```bash
make restore-fullnode NODE=snapshotter SNAP=snapshots/<height>-<ts>.tar.zst
make status     # latest_block_height climbs, catching_up -> false
```

The script stops the node, wipes `db/` + `wal/`, extracts the snapshot's `db`,
restarts it; the node replays only the blocks produced since the snapshot over
P2P.

## 4. Restore — Procedure B: validator (disaster recovery, tmkms mode)

> **Anti-double-sign rule #1:** the old validator **and** its tmkms must be
> fully dead before you restore. Two instances signing the same chain = slashing.

In tmkms mode the double-sign gate is **not** `gnoland-data/secrets/
priv_validator_state.json` but tmkms's `tmkms/validator/secrets/
consensus_state.json`. Never let its height go backwards.

Checklist:

1. Confirm the dead validator + tmkms are stopped.
2. Restore the validator's **own** material (the snapshot does NOT contain it):
   - gnoland `node_key`
   - tmkms `consensus.key`, `kms-identity.key`
   - tmkms `consensus_state.json` — if it survived, reuse as-is; if lost, set its
     height to **(current chain head + margin)** before starting tmkms.
3. Restore chain data:

   ```bash
   make restore-validator SNAP=snapshots/<height>-<ts>.tar.zst
   ```

   (prompts the checklist, then restores `db` only — it does not touch tmkms
   secrets).
4. Verify: the validator catches up and resumes signing **new** heights, with no
   "double sign" refusal in the tmkms logs.

## 5. End-to-end test on devnet

**Bootstrap test**

```bash
make up && make up-snapshotter        # chain + snapshot node
# wait for snapshotter to sync, then:
make snapshot
make restore-fullnode NODE=snapshotter SNAP=$(ls -t snapshots/*.tar.zst | head -1)
make status                           # snapshotter rejoins from the snapshot height
```

**Validator DR test** (simulate disk loss, keep tmkms state)

```bash
make snapshot
docker compose stop validator
rm -rf validator/gnoland-data/db validator/gnoland-data/wal   # keep secrets + tmkms
make restore-validator SNAP=$(ls -t snapshots/*.tar.zst | head -1)
make status
docker compose logs tmkms | grep -i "double sign" || echo "no double-sign refusal — OK"
```

## Production (later)

On the host running the sentry, add the same `snapshotter` via a
`docker-compose.backup.yml`, reuse `snapshot.sh` + the systemd timer, and copy
archives **off-box** (scp/rsync), mirroring `4-backup_logs.sh.yaml`.
