# Gno Auto-heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a stuck sentry or validator node (block height frozen,
`catching_up=false`) and automatically restore it from the latest chain
snapshot, then verify it caught back up — no human in the loop.

**Architecture:** `check-stuck.sh` (pure detection, state file, threshold
debounce) hands off to `autoheal.sh` (incident backup → fetch latest snapshot
→ validator-only local anti-double-sign check → `restore.sh --yes` → restart
in the right order → poll for catch-up), guarded by a lock-file cooldown.
Built and proven on **devnet** first (local snapshots, `Makefile` scenarios,
no external dependency), then ported to **prod** as a new Ansible role
`roles/autoheal` deployed on both the sentry and the validator host (pulling
from Scaleway Object Storage via `rclone`, since only the sentry host has a
local snapshotter).

**Tech Stack:** bash (`set -euo pipefail`), `jq`, `curl`, `zstd`/`tar`,
`docker compose`, `rclone` (prod only), Ansible (prod only), the existing
devnet `Makefile` scenario pattern.

## Global Constraints

- Never touch `priv_validator_*` / tmkms secrets during a restore — archives
  contain chain data only (`gnoland-data/db`), per the existing
  `restore.sh` contract. [spec §7]
- Validator restore requires, before any wipe, a **local** verification that
  the validator + tmkms containers are actually `exited` — no distant lock,
  no human confirmation in the automated path. [spec §7]
- Anti-flapping: a lock file with a cooldown (default 1800s) blocks repeated
  auto-restores; a blocked attempt alerts instead of silently retrying.
  [spec §8]
- A node with an unreachable RPC is DOWN, not "stuck" — never triggers
  autoheal. [spec §6]
- No snapshot available → abort before touching any data, alert critical.
  [spec §11]
- Every key step (triggered, succeeded, failed, aborted, cooldown-blocked)
  sends a webhook alert if `WEBHOOK_URL` is set. [spec §9]
- Follow the existing repo convention of two parallel implementations: a
  plain devnet copy (`devnet/*.sh`, Makefile-driven) and a Jinja-templated
  prod copy (`roles/autoheal/templates/*.sh.j2`, Ansible-rendered) — same
  pattern already used for `snapshot.sh` / `restore.sh`.

---

## Part A — Devnet (build + prove the logic)

### Task 1: `devnet/check-stuck.sh` — detection

**Files:**
- Create: `devnet/check-stuck.sh`
- Modify: `devnet/Makefile` (add `check-stuck` target + `.PHONY` entry)
- Modify: `devnet/.gitignore` (ignore `.autoheal/`)

**Interfaces:**
- Produces: `./check-stuck.sh <node-service> [rpc_url]` — exits 0 always
  (detection is never itself an error condition); on
  `stuck_count >= STUCK_THRESHOLD` it `exec`s
  `"$(dirname "$0")/autoheal.sh" "$NODE"` (Task 3), so its own exit code
  becomes `autoheal.sh`'s exit code in that case.
- State file: `.autoheal/<node>.state`, JSON `{height, ts, stuck_count}`.

- [ ] **Step 1: Write `devnet/check-stuck.sh`**

```bash
#!/usr/bin/env bash
# Detect whether a gnoland node's block height has stopped advancing while it
# reports catching_up=false. Pure read: no side effect beyond updating its own
# state file. When STUCK_THRESHOLD consecutive stuck samples are seen, it hands
# off to autoheal.sh (same directory) to actually restore the node.
#
# Usage:
#   ./check-stuck.sh <node-service> [rpc_url]
#   ./check-stuck.sh validator2 http://localhost:26659
#
# A node whose RPC is unreachable is DOWN, not "stuck" (restoring a snapshot
# won't fix a container that won't start) — logged, never triggers autoheal.
set -euo pipefail

cd "$(dirname "$0")"

NODE="${1:-}"
RPC="${2:-}"
if [ -z "$NODE" ]; then
  echo "Usage: $0 <node-service> [rpc_url]" >&2
  exit 2
fi

STATE_DIR="${STATE_DIR:-.autoheal}"
STATE_FILE="$STATE_DIR/${NODE}.state"
STUCK_THRESHOLD="${STUCK_THRESHOLD:-3}"

mkdir -p "$STATE_DIR"

# Resolve RPC from the node name if not given (see devnet/docker-compose.yml).
if [ -z "$RPC" ]; then
  case "$NODE" in
    validator)   RPC="http://localhost:26658" ;;
    validator2)  RPC="http://localhost:26659" ;;
    validator3)  RPC="http://localhost:26660" ;;
    validator4)  RPC="http://localhost:26661" ;;
    snapshotter) RPC="http://localhost:26662" ;;
    *) echo "❌ unknown node '$NODE' and no rpc_url given" >&2; exit 2 ;;
  esac
fi

STATUS="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
  echo "⚠️  $NODE: RPC unreachable at $RPC — node is DOWN, not stuck. No action taken."
  exit 0
fi

HEIGHT="$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || true)"
CATCHING_UP="$(echo "$STATUS" | jq -r '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"

if [ -z "$HEIGHT" ] || [ -z "$CATCHING_UP" ]; then
  echo "⚠️  $NODE: malformed /status response — skipping this check." >&2
  exit 0
fi

PREV_HEIGHT=""
STUCK_COUNT=0
if [ -f "$STATE_FILE" ]; then
  PREV_HEIGHT="$(jq -r '.height // empty' "$STATE_FILE" 2>/dev/null || true)"
  STUCK_COUNT="$(jq -r '.stuck_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if [ "$CATCHING_UP" = "true" ]; then
  echo "ℹ️  $NODE: catching_up=true (height=$HEIGHT) — syncing normally, not stuck."
  STUCK_COUNT=0
elif [ -n "$PREV_HEIGHT" ] && [ "$HEIGHT" = "$PREV_HEIGHT" ]; then
  STUCK_COUNT=$((STUCK_COUNT + 1))
  echo "⚠️  $NODE: height unchanged at $HEIGHT (catching_up=false) — stuck_count=$STUCK_COUNT/$STUCK_THRESHOLD"
else
  echo "✅ $NODE: height=$HEIGHT, progressing normally."
  STUCK_COUNT=0
fi

jq -n --arg h "$HEIGHT" --arg ts "$(date -u +%s)" --arg c "$STUCK_COUNT" \
  '{height: $h, ts: ($ts|tonumber), stuck_count: ($c|tonumber)}' > "$STATE_FILE"

if [ "$STUCK_COUNT" -ge "$STUCK_THRESHOLD" ]; then
  echo "🚨 $NODE: stuck for $STUCK_COUNT consecutive checks (>= $STUCK_THRESHOLD) — triggering autoheal."
  exec "$(dirname "$0")/autoheal.sh" "$NODE"
fi
```

```bash
chmod +x devnet/check-stuck.sh
```

- [ ] **Step 2: Add the Makefile target**

In `devnet/Makefile`, add `check-stuck` to the `.PHONY` list (alongside
`snapshot snapshots restore-fullnode restore-validator`) and add the target
next to `snapshot`/`snapshots`:

```makefile
check-stuck: ## make check-stuck NODE=validator2
	./check-stuck.sh $(NODE)
```

- [ ] **Step 3: Ignore the state dir**

In `devnet/.gitignore`, under the "Chain snapshot archives" section, add:

```
# Auto-heal state (detection counters, locks, incident backups)
.autoheal/
incidents/
```

- [ ] **Step 4: Smoke-test detection on a healthy node**

```bash
cd devnet
make up
sleep 15   # let the chain produce a few blocks
./check-stuck.sh validator2
cat .autoheal/validator2.state
```

Expected: `✅ validator2: height=<N>, progressing normally.` and
`.autoheal/validator2.state` shows `"stuck_count":0`.

- [ ] **Step 5: Smoke-test detection on an unreachable node**

```bash
docker compose stop validator3
./check-stuck.sh validator3
docker compose start validator3
```

Expected: `⚠️  validator3: RPC unreachable ... No action taken.`, exit 0, no
`.autoheal/validator3.state` stuck-count increment (state file may not even
be created — that's fine, it returns before reaching the state logic).

- [ ] **Step 6: Commit**

```bash
git add devnet/check-stuck.sh devnet/Makefile devnet/.gitignore
git commit -m "feat(devnet): add check-stuck.sh — stuck-node detection"
```

---

### Task 2: `devnet/restore.sh` — add `--yes`

**Files:**
- Modify: `devnet/restore.sh`

**Interfaces:**
- Produces: `./restore.sh <node-service> <snapshot.tar.zst> [--yes]` — with
  `--yes`, skips the interactive confirmation for a validator restore.
  Consumed by `devnet/autoheal.sh` (Task 3).

- [ ] **Step 1: Add the `--yes` bypass**

In `devnet/restore.sh`, change:

```bash
NODE="${1:-}"
ARCHIVE="${2:-}"
if [ -z "$NODE" ] || [ -z "$ARCHIVE" ]; then
  echo "Usage: $0 <node-service> <snapshot.tar.zst>" >&2
  exit 2
fi
```

to:

```bash
NODE="${1:-}"
ARCHIVE="${2:-}"
YES="${3:-}"
if [ -z "$NODE" ] || [ -z "$ARCHIVE" ]; then
  echo "Usage: $0 <node-service> <snapshot.tar.zst> [--yes]" >&2
  exit 2
fi
```

and change the validator confirmation block from:

```bash
  read -r -p "Proceed with validator restore? [y/N] " ans
  case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi
```

to:

```bash
  if [ "$YES" = "--yes" ]; then
    echo "--yes passed: skipping interactive confirmation (caller already verified the checklist above)." >&2
  else
    read -r -p "Proceed with validator restore? [y/N] " ans
    case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
  fi
fi
```

- [ ] **Step 2: Verify the flag works non-interactively**

```bash
cd devnet
make snapshot   # produce a fresh local snapshot from the snapshotter
LATEST="$(ls -1t snapshots/*.tar.zst | head -n1)"
./restore.sh validator4 "$LATEST" --yes < /dev/null
```

Expected: no prompt (stdin is `/dev/null`, so a hang here means `--yes` isn't
taking effect), ends with `✅ Restore done. ...`.

- [ ] **Step 3: Verify the default (no `--yes`) behavior is unchanged**

```bash
echo n | ./restore.sh validator "$LATEST"
```

Expected: prints the anti-double-sign checklist, prompts, `n` → `Aborted.`,
exit 1, validator untouched.

- [ ] **Step 4: Commit**

```bash
git add devnet/restore.sh
git commit -m "feat(devnet): restore.sh --yes flag for automated callers"
```

---

### Task 3: `devnet/autoheal.sh` — orchestrator

**Files:**
- Create: `devnet/autoheal.sh`
- Modify: `devnet/Makefile` (add `autoheal` target + `.PHONY` entry)

**Interfaces:**
- Consumes: `./restore.sh <node-service> <archive> [--yes]` (Task 2).
- Produces: `./autoheal.sh <node-service>` — exit 0 on confirmed catch-up,
  exit 1 on any failure (no snapshot, restore failure, safety-check abort,
  cooldown block, catch-up timeout). Called by `check-stuck.sh` (Task 1) or
  directly for manual/testing use.

- [ ] **Step 1: Write `devnet/autoheal.sh`**

```bash
#!/usr/bin/env bash
# Orchestrate a full auto-heal restore of <node-service>: incident backup,
# pick the latest local snapshot, restore, restart (tmkms-aware ordering for
# the validator), verify catch-up. Invoked by check-stuck.sh once a node has
# been confirmed stuck for STUCK_THRESHOLD consecutive checks.
#
# Devnet-only: snapshots are read from ./snapshots/ (produced by snapshot.sh)
# — no Scaleway pull here, that's the prod (roles/autoheal) variant's job.
#
# Usage: ./autoheal.sh <node-service>
set -euo pipefail

cd "$(dirname "$0")"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-gnoland-test}"

NODE="${1:-}"
if [ -z "$NODE" ]; then
  echo "Usage: $0 <node-service>" >&2
  exit 2
fi

LOCK_DIR=".autoheal"
LOCK_FILE="$LOCK_DIR/${NODE}.lock"
COOLDOWN="${AUTOHEAL_COOLDOWN:-1800}"                  # seconds, default 30 min
CATCHUP_TIMEOUT="${AUTOHEAL_CATCHUP_TIMEOUT:-1200}"    # seconds, default 20 min
INCIDENT_DIR="incidents"
SNAP_DIR="snapshots"
DATA_DIR="$NODE/gnoland-data"

mkdir -p "$LOCK_DIR" "$INCIDENT_DIR"

compose() { docker compose --profile phase2 --profile snapshot "$@"; }

alert() {
  local event="$1" message="$2"
  echo "[ALERT] $event: $message"
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -s --max-time 5 -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$NODE" --arg e "$event" --arg m "$message" \
            '{node:$n, event:$e, message:$m}')" >/dev/null 2>&1 || true
  fi
}

# --- Anti-flapping: refuse to run again inside the cooldown window ----------
if [ -f "$LOCK_FILE" ]; then
  LOCK_TS="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
  ELAPSED=$(( $(date -u +%s) - LOCK_TS ))
  if [ "$ELAPSED" -lt "$COOLDOWN" ]; then
    alert "cooldown-blocked" "$NODE: a restore already ran ${ELAPSED}s ago (cooldown ${COOLDOWN}s) — refusing to run again automatically. Needs human investigation."
    exit 1
  fi
fi
date -u +%s > "$LOCK_FILE"

alert "restore-triggered" "$NODE: stuck detected, starting auto-heal restore."

# --- 1. Incident backup (full gnoland-data, secrets included, forensic only) ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
INCIDENT_ARCHIVE="$INCIDENT_DIR/${NODE}-${TS}.tar.zst"
echo "==> Incident backup: $DATA_DIR -> $INCIDENT_ARCHIVE"
if ! tar -C "$NODE" -c gnoland-data | zstd -q -T0 -o "$INCIDENT_ARCHIVE"; then
  alert "restore-failed" "$NODE: incident backup failed — aborting before touching data."
  exit 1
fi

# --- 2. Pick the latest local snapshot (highest block height) ---------------
# List bare filenames from inside SNAP_DIR (not ls "$SNAP_DIR"/*.tar.zst, which
# would need sort -t twice — once to skip the dir prefix, once for the
# height/timestamp separator — and GNU sort rejects more than one -t).
LATEST=""
if [ -d "$SNAP_DIR" ]; then
  LATEST="$(cd "$SNAP_DIR" && ls -1 *.tar.zst 2>/dev/null | sort -t- -k1,1n | tail -n1 || true)"
fi
if [ -n "$LATEST" ]; then
  LATEST="$SNAP_DIR/$LATEST"
fi
if [ -z "$LATEST" ]; then
  alert "restore-failed" "$NODE: no snapshot available in $SNAP_DIR — aborting, node left untouched."
  exit 1
fi
echo "==> Using snapshot: $LATEST"

# --- 3. Validator-only local safety check (anti-double-sign) ----------------
if [ "$NODE" = "validator" ]; then
  echo "==> Stopping validator + tmkms"
  compose stop validator tmkms >/dev/null 2>&1 || true
  for svc in validator tmkms; do
    # -a is required: a plain 'compose ps' only lists RUNNING containers, so a
    # cleanly-stopped (exited) container would otherwise report empty state,
    # not "exited" — making this check fail-closed on every clean stop.
    STATE="$(compose ps -a --format '{{.State}}' "$svc" 2>/dev/null || echo missing)"
    if [ "$STATE" != "exited" ] && [ "$STATE" != "missing" ]; then
      alert "restore-aborted" "$NODE: $svc did not stop cleanly (state=$STATE) — refusing to wipe data, possible live signer. Manual intervention required."
      exit 1
    fi
  done
fi

# --- 4. Restore (delegates to restore.sh --yes; it also restarts $NODE) -----
echo "==> Restoring $NODE from $LATEST"
if ! ./restore.sh "$NODE" "$LATEST" --yes; then
  alert "restore-failed" "$NODE: restore.sh failed — see logs."
  exit 1
fi

# --- 5. Validator only: start tmkms too (restore.sh only starts $NODE) ------
if [ "$NODE" = "validator" ]; then
  echo "==> restore.sh already started $NODE; starting tmkms now"
  sleep 5
  if ! compose start tmkms >/dev/null; then
    alert "restore-failed" "$NODE: tmkms failed to start after restore — validator is up WITHOUT a signer attached. Manual intervention required."
    exit 1
  fi
fi

# --- 6. Verify catch-up -------------------------------------------------------
case "$NODE" in
  validator)   RPC="http://localhost:26658" ;;
  validator2)  RPC="http://localhost:26659" ;;
  validator3)  RPC="http://localhost:26660" ;;
  validator4)  RPC="http://localhost:26661" ;;
  snapshotter) RPC="http://localhost:26662" ;;
  *) alert "restore-failed" "$NODE: unknown node, cannot verify catch-up."; exit 1 ;;
esac

echo "==> Waiting for catch-up (timeout ${CATCHUP_TIMEOUT}s)"
ELAPSED=0
while [ "$ELAPSED" -lt "$CATCHUP_TIMEOUT" ]; do
  CATCHING_UP="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null | jq -r '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"
  if [ "$CATCHING_UP" = "false" ]; then
    alert "restore-succeeded" "$NODE: restored from $LATEST and caught up."
    rm -f "$LOCK_DIR/${NODE}.state"
    exit 0
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

alert "restore-timeout" "$NODE: restored from $LATEST but did not catch up within ${CATCHUP_TIMEOUT}s — needs investigation."
exit 1
```

```bash
chmod +x devnet/autoheal.sh
```

- [ ] **Step 2: Add the Makefile target**

```makefile
autoheal: ## make autoheal NODE=validator2  (manual trigger, bypasses detection)
	./autoheal.sh $(NODE)
```

Add `autoheal` to `.PHONY`.

- [ ] **Step 3: Manual smoke test — no snapshot yet**

```bash
cd devnet
mkdir -p /tmp/empty-snapshots
SNAP_DIR_BACKUP=snapshots.bak
mv snapshots "$SNAP_DIR_BACKUP" 2>/dev/null || true
mkdir snapshots
./autoheal.sh validator4; echo "exit=$?"
rm -rf snapshots
mv "$SNAP_DIR_BACKUP" snapshots
```

Expected: `[ALERT] restore-failed: validator4: no snapshot available ...`,
`exit=1`, `validator4/gnoland-data` untouched (still has its original db).

- [ ] **Step 4: Manual smoke test — happy path on a follower**

```bash
make snapshot
./autoheal.sh validator4
```

Expected: incident backup written to `incidents/`, restore succeeds, catch-up
verified quickly (validator4 was already near the snapshot height),
`[ALERT] restore-succeeded: ...`.

- [ ] **Step 5: Commit**

```bash
git add devnet/autoheal.sh devnet/Makefile
git commit -m "feat(devnet): add autoheal.sh — auto-restore orchestrator"
```

---

### Task 4: Devnet scenarios + systemd timer + docs

**Files:**
- Modify: `devnet/Makefile` (4 new scenario targets)
- Create: `devnet/systemd/gno-autoheal-check.service`
- Create: `devnet/systemd/gno-autoheal-check.timer`
- Modify: `devnet/SNAPSHOT-RESTORE.md`

**Interfaces:**
- Consumes: `check-stuck.sh` (Task 1), `autoheal.sh` (Task 3), the existing
  `scenario3` / `scenario3-restart` targets (halt/resume the chain by
  stopping/starting `validator2` + `validator3`).

- [ ] **Step 1: Add the scenario targets**

In `devnet/Makefile`, add to `.PHONY`:
`scenario-autoheal-follower scenario-autoheal-validator scenario-autoheal-no-snapshot scenario-autoheal-cooldown`

```makefile
# Halts the chain (stop validator2+validator3, same as scenario3) so a still-
# running node's height freezes with catching_up=false — the exact condition
# check-stuck.sh looks for. This proves the detect -> backup -> restore ->
# restart pipeline runs correctly; it can't "fix" a network-wide halt (no
# client-side restore can) — scenario3-restart below proves the restored node
# then rejoins cleanly once the network resumes.
scenario-autoheal-follower: up-validator4
	@echo "==> Halting the chain (stop validator2+validator3)"
	docker compose stop validator2 validator3
	@echo "==> Waiting for validator4's height to freeze..."
	sleep 20
	@echo "==> Running check-stuck.sh 3x (STUCK_THRESHOLD=3 default)"
	./check-stuck.sh validator4 || true
	sleep 5
	./check-stuck.sh validator4 || true
	sleep 5
	./check-stuck.sh validator4
	@echo "==> autoheal should have fired above. Resuming the chain:"
	docker compose start validator2 validator3
	@echo "==> Watch validator4 catch up to the resumed chain: make status"

scenario-autoheal-validator:
	@echo "==> Halting the chain (stop validator2+validator3)"
	docker compose stop validator2 validator3
	@echo "==> Waiting for validator's height to freeze..."
	sleep 20
	@echo "==> Running check-stuck.sh 3x against the tmkms validator"
	./check-stuck.sh validator || true
	sleep 5
	./check-stuck.sh validator || true
	sleep 5
	./check-stuck.sh validator
	@echo "==> Check tmkms did not refuse to sign (no 'double sign' in logs):"
	docker compose logs tmkms --tail 50 | grep -i "sign" || echo "(no sign-related log lines yet)"
	@echo "==> Resuming the chain:"
	docker compose start validator2 validator3
	@echo "==> Watch validator resume signing: make status; docker compose logs -f tmkms"

scenario-autoheal-no-snapshot:
	@echo "==> Temporarily hiding snapshots/ to force a no-snapshot failure"
	mv snapshots snapshots.scenario-bak 2>/dev/null || true
	mkdir snapshots
	./autoheal.sh validator4; echo "exit=$$?  (expect 1)"
	rm -rf snapshots
	mv snapshots.scenario-bak snapshots

scenario-autoheal-cooldown:
	@echo "==> First run (expect success or a real failure, but the lock gets written)"
	-./autoheal.sh validator4
	@echo "==> Second run immediately after (expect cooldown-blocked, exit 1)"
	./autoheal.sh validator4; echo "exit=$$?  (expect 1)"
```

- [ ] **Step 2: Add the help text**

In the `help:` target, under "Snapshots & restore", add:

```makefile
	@echo "  make check-stuck NODE=<svc>   - run one stuck-detection check on <svc>"
	@echo "  make autoheal NODE=<svc>      - manually trigger the auto-heal restore on <svc>"
	@echo ""
	@echo "Auto-heal scenarios:"
	@echo "  make scenario-autoheal-follower  - halt chain, detect+restore validator4, resume"
	@echo "  make scenario-autoheal-validator - halt chain, detect+restore validator (tmkms), resume"
	@echo "  make scenario-autoheal-no-snapshot - autoheal aborts cleanly with no snapshot available"
	@echo "  make scenario-autoheal-cooldown  - second auto-heal within cooldown is blocked"
```

- [ ] **Step 3: Devnet systemd templates**

Create `devnet/systemd/gno-autoheal-check.service`:

```ini
# Oneshot service that runs one stuck-detection check. Triggered by
# gno-autoheal-check.timer. Install as a --user unit (see gno-snapshot.service
# for the install recipe — same pattern, just point at check-stuck.sh).
#
# NODE must be exported before installing (sed it in, same as __DEVNET_DIR__).
[Unit]
Description=Check if a gno devnet node is stuck and auto-heal it
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory=__DEVNET_DIR__
ExecStart=/usr/bin/env bash -c './check-stuck.sh __NODE__'
SuccessExitStatus=0
```

Create `devnet/systemd/gno-autoheal-check.timer`:

```ini
[Unit]
Description=Run gno-autoheal-check.service every 3 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Document in `devnet/SNAPSHOT-RESTORE.md`**

Append a new section:

```markdown
## Auto-heal (detect + auto-restore)

`check-stuck.sh <node>` samples `/status` on a timer (see
`systemd/gno-autoheal-check.{service,timer}`); after 3 consecutive checks
with an unchanged height and `catching_up=false`, it hands off to
`autoheal.sh <node>`, which backs up the current data (`incidents/`), restores
the latest local snapshot, restarts (tmkms-aware for `validator`), and waits
for catch-up. A lock file (`.autoheal/<node>.lock`) enforces a 30 min cooldown
between automatic restores.

Manual trigger (bypasses detection): `make autoheal NODE=<svc>`.

See `make scenario-autoheal-follower` / `scenario-autoheal-validator` /
`scenario-autoheal-no-snapshot` / `scenario-autoheal-cooldown` for the test
scenarios.
```

- [ ] **Step 5: Run all four scenarios**

```bash
cd devnet
make full-reinit
make up-validator4
make scenario-autoheal-follower
make status   # confirm validator4 caught up to the resumed chain
```

```bash
make scenario-autoheal-validator
make status   # confirm validator caught up and is signing again
```

```bash
make scenario-autoheal-no-snapshot
make scenario-autoheal-cooldown
```

Expected: all four match the "Expected" notes in Tasks 1/3's manual smoke
tests and this task's target comments above.

- [ ] **Step 6: Commit**

```bash
git add devnet/Makefile devnet/systemd/gno-autoheal-check.service devnet/systemd/gno-autoheal-check.timer devnet/SNAPSHOT-RESTORE.md
git commit -m "feat(devnet): auto-heal scenarios, systemd timer, docs"
```

---

## Part B — Prod (`roles/autoheal`, Ansible)

This ports Part A's logic to a new role deployed on **both** the sentry and
the validator host, pulling snapshots from Scaleway instead of a local
`snapshots/` dir (only the sentry host has a co-located snapshotter).

### Task 5: Role skeleton — defaults, meta, env example

**Files:**
- Create: `roles/autoheal/defaults/main.yml`
- Create: `roles/autoheal/meta/main.yml`
- Create: `roles/autoheal/templates/autoheal.env.example.j2`
- Create: `roles/autoheal/handlers/main.yml`

**Interfaces:**
- Produces the Ansible variables every later task's template renders with:
  `autoheal_node_type`, `autoheal_deploy_dir`, `autoheal_compose_service`,
  `autoheal_rpc_bind`, `autoheal_state_dir`, `autoheal_stuck_threshold`,
  `autoheal_check_interval`, `autoheal_cooldown_seconds`,
  `autoheal_catchup_timeout_seconds`, `autoheal_s3_bucket`,
  `autoheal_s3_endpoint`, `autoheal_s3_region`, `autoheal_s3_prefix`.

- [ ] **Step 1: `roles/autoheal/defaults/main.yml`**

```yaml
---
# defaults file for roles/autoheal
# Deploys stuck-node detection + auto-restore on a node this role is applied
# to (sentry OR validator — set autoheal_node_type per host in inventory).
# Snapshots are always pulled from Scaleway (roles/snapshotter's push target),
# even on the sentry host that has a local snapshotter co-located: one code
# path, one thing to test, negligible freshness cost (one push cycle).

autoheal_enabled: false

# "sentry" or "validator" — set per host (host_vars / group_vars), never here.
autoheal_node_type: ""

# The node's OWN deploy dir (its docker-compose.yml lives here) — e.g.
# /root/gno-node for the sentry, /root/gno-node for the validator (same
# gno_dir convention, different host).
autoheal_deploy_dir: "/root/{{ gno_dir }}"

# The compose service name for the node itself. tmkms (when node_type is
# validator) is always literally "tmkms" — see docker-compose templates.
autoheal_compose_service: "{{ 'sentry' if autoheal_node_type == 'sentry' else 'validator' }}"

autoheal_rpc_bind: "127.0.0.1:26657"

autoheal_state_dir: "/var/lib/gno-autoheal"
autoheal_stuck_threshold: 3
autoheal_check_interval: "*:0/3"          # systemd OnCalendar: every 3 min
autoheal_cooldown_seconds: 1800           # 30 min
autoheal_catchup_timeout_seconds: 1200    # 20 min

autoheal_chain_id: ""

# --- Scaleway Object Storage (rclone, READ-ONLY pull) ---------------------
# MUST match the sentry's roles/snapshotter variables (snapshotter_s3_bucket /
# snapshotter_s3_prefix) — both node types pull from the SAME bucket/prefix,
# the one the sentry's push-to-s3.sh writes to. Credentials go in .env on the
# host (SCW_ACCESS_KEY/SCW_SECRET_KEY) — a read-only Scaleway API key is
# recommended, especially on the validator host.
autoheal_s3_bucket: ""
autoheal_s3_endpoint: "s3.fr-par.scw.cloud"
autoheal_s3_region: "fr-par"
autoheal_s3_prefix: ""
```

- [ ] **Step 2: `roles/autoheal/meta/main.yml`**

```yaml
---
galaxy_info:
  description: Stuck-node detection and automatic snapshot restore for gno validator/sentry nodes.
  min_ansible_version: "2.14"
dependencies: []
```

- [ ] **Step 3: `roles/autoheal/handlers/main.yml`**

```yaml
---
- name: reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

- [ ] **Step 4: `roles/autoheal/templates/autoheal.env.example.j2`**

```
# autoheal environment — COPY THIS TO .env AND FILL IT IN, THEN chmod 600 .env
#
#   cp autoheal.env.example .env && chmod 600 .env
#
# .env holds the ONLY secrets on this host for auto-heal (Scaleway read-only
# keys). Never committed, never pushed anywhere.

# --- Scaleway Object Storage (rclone) — READ-ONLY pull ---------------------
# A read-only API key is enough (this host never writes/deletes). Must point
# at the SAME bucket/prefix the sentry's roles/snapshotter pushes to.
SCW_ACCESS_KEY=__FILL_ME__
SCW_SECRET_KEY=__FILL_ME__
S3_BUCKET={{ autoheal_s3_bucket }}
S3_ENDPOINT={{ autoheal_s3_endpoint }}
S3_REGION={{ autoheal_s3_region }}
S3_PREFIX={{ autoheal_s3_prefix }}

# --- Alerting ---------------------------------------------------------------
# Generic webhook, POSTed JSON {node, event, message} at each key step
# (triggered, succeeded, failed, aborted, cooldown-blocked, timeout).
WEBHOOK_URL=__FILL_ME__
```

- [ ] **Step 5: Commit**

```bash
git add roles/autoheal/defaults/main.yml roles/autoheal/meta/main.yml roles/autoheal/handlers/main.yml roles/autoheal/templates/autoheal.env.example.j2
git commit -m "feat(ansible): roles/autoheal skeleton (defaults, meta, env example)"
```

---

### Task 6: `check-stuck.sh.j2`

**Files:**
- Create: `roles/autoheal/templates/check-stuck.sh.j2`

**Interfaces:**
- Same behavior/state-file shape as devnet's `check-stuck.sh` (Task 1), but
  reads `autoheal_rpc_bind` / `autoheal_state_dir` / `autoheal_node_type` /
  `autoheal_stuck_threshold` from Jinja instead of CLI args, and hands off to
  `./autoheal.sh` (no args — the prod orchestrator is single-node-type per
  host).

- [ ] **Step 1: Write the template**

```bash
#!/usr/bin/env bash
# Rendered by roles/autoheal. Detect whether THIS node ({{ autoheal_node_type }})
# has stopped advancing while catching_up=false. Pure read — no side effect
# beyond updating its own state file. After {{ autoheal_stuck_threshold }}
# consecutive stuck samples, hands off to autoheal.sh to restore the node.
set -euo pipefail

cd "$(dirname "$0")"

RPC="http://{{ autoheal_rpc_bind }}"
STATE_DIR="{{ autoheal_state_dir }}"
STATE_FILE="$STATE_DIR/{{ autoheal_node_type }}.state"
STUCK_THRESHOLD="{{ autoheal_stuck_threshold }}"

mkdir -p "$STATE_DIR"

STATUS="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
  echo "⚠️  {{ autoheal_node_type }}: RPC unreachable at $RPC — node is DOWN, not stuck. No action taken."
  exit 0
fi

HEIGHT="$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height // empty' 2>/dev/null || true)"
CATCHING_UP="$(echo "$STATUS" | jq -r '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"

if [ -z "$HEIGHT" ] || [ -z "$CATCHING_UP" ]; then
  echo "⚠️  malformed /status response — skipping this check." >&2
  exit 0
fi

PREV_HEIGHT=""
STUCK_COUNT=0
if [ -f "$STATE_FILE" ]; then
  PREV_HEIGHT="$(jq -r '.height // empty' "$STATE_FILE" 2>/dev/null || true)"
  STUCK_COUNT="$(jq -r '.stuck_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if [ "$CATCHING_UP" = "true" ]; then
  echo "ℹ️  catching_up=true (height=$HEIGHT) — syncing normally, not stuck."
  STUCK_COUNT=0
elif [ -n "$PREV_HEIGHT" ] && [ "$HEIGHT" = "$PREV_HEIGHT" ]; then
  STUCK_COUNT=$((STUCK_COUNT + 1))
  echo "⚠️  height unchanged at $HEIGHT (catching_up=false) — stuck_count=$STUCK_COUNT/$STUCK_THRESHOLD"
else
  echo "✅ height=$HEIGHT, progressing normally."
  STUCK_COUNT=0
fi

jq -n --arg h "$HEIGHT" --arg ts "$(date -u +%s)" --arg c "$STUCK_COUNT" \
  '{height: $h, ts: ($ts|tonumber), stuck_count: ($c|tonumber)}' > "$STATE_FILE"

if [ "$STUCK_COUNT" -ge "$STUCK_THRESHOLD" ]; then
  echo "🚨 stuck for $STUCK_COUNT consecutive checks (>= $STUCK_THRESHOLD) — triggering autoheal."
  exec "$(dirname "$0")/autoheal.sh"
fi
```

- [ ] **Step 2: Commit**

```bash
git add roles/autoheal/templates/check-stuck.sh.j2
git commit -m "feat(ansible): roles/autoheal check-stuck.sh.j2"
```

---

### Task 7: `pull-from-s3.sh.j2`

**Files:**
- Create: `roles/autoheal/templates/pull-from-s3.sh.j2`

**Interfaces:**
- Produces: `./pull-from-s3.sh` — prints **only** the downloaded archive's
  absolute path on stdout (all progress/errors go to stderr), so
  `autoheal.sh` can do `LATEST="$(./pull-from-s3.sh)"`. Exits non-zero if no
  snapshot is found or the download fails.

- [ ] **Step 1: Write the template**

```bash
#!/usr/bin/env bash
# Rendered by roles/autoheal. Download the most recent chain snapshot (highest
# block height) from Scaleway Object Storage into ./snapshots/. Read-only:
# never deletes or uploads anything (pruning is push-to-s3.sh's job, on the
# sentry host that produces the snapshots). Prints ONLY the downloaded file's
# absolute path on stdout; everything else goes to stderr.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "❌ .env missing — copy autoheal.env.example to .env and fill it in." >&2
  exit 1
fi
set -a
. ./.env
set +a

: "${SCW_ACCESS_KEY:?set SCW_ACCESS_KEY in .env}"
: "${SCW_SECRET_KEY:?set SCW_SECRET_KEY in .env}"
: "${S3_BUCKET:?set S3_BUCKET in .env}"
: "${S3_ENDPOINT:?set S3_ENDPOINT in .env}"
: "${S3_REGION:?set S3_REGION in .env}"
: "${S3_PREFIX:?set S3_PREFIX in .env (must match the sentry's snapshotter_s3_prefix)}"

export RCLONE_CONFIG_SCW_TYPE="s3"
export RCLONE_CONFIG_SCW_PROVIDER="aws"
export RCLONE_CONFIG_SCW_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export RCLONE_CONFIG_SCW_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_SCW_REGION="$S3_REGION"

SRC="scw:${S3_BUCKET}/${S3_PREFIX}"
mkdir -p snapshots

echo "==> Listing $SRC" >&2
LATEST="$(rclone lsf "$SRC" --files-only --include '*.tar.zst' | sort -t '-' -k1,1n | tail -n1)"
if [ -z "$LATEST" ]; then
  echo "❌ no snapshot found at $SRC" >&2
  exit 1
fi

echo "==> Downloading $LATEST" >&2
rclone copy "$SRC/$LATEST" snapshots/ --s3-chunk-size 64M --stats-one-line >&2

echo "$PWD/snapshots/$LATEST"
```

- [ ] **Step 2: Commit**

```bash
git add roles/autoheal/templates/pull-from-s3.sh.j2
git commit -m "feat(ansible): roles/autoheal pull-from-s3.sh.j2"
```

---

### Task 8: `restore.sh` (prod copy)

**Files:**
- Create: `roles/autoheal/files/restore.sh`

**Interfaces:**
- Produces: `./restore.sh <deploy_dir> <archive.tar.zst> <compose_service> [--yes]`
  — same signature as `roles/snapshotter/files/restore.sh` (that file is left
  untouched, for its existing manual use on the sentry host), with the
  `--yes` bypass built in from the start. Consumed by `autoheal.sh.j2`
  (Task 9).

- [ ] **Step 1: Write the file**

```bash
#!/usr/bin/env bash
# Restore a node's chain data from a snapshot archive (produced by snapshot.sh
# on the sentry's snapshotter, or pulled from Scaleway by pull-from-s3.sh).
# Stops the compose service, wipes gnoland-data/{db,wal}, extracts the
# archive's db, restarts. The node rejoins over P2P and replays only the delta
# (no genesis replay). Never touches node_key or the validator's consensus
# key/tmkms state — the archive holds chain data only.
#
# Usage:
#   ./restore.sh <deploy_dir> <archive.tar.zst> <compose_service> [--yes]
#   ./restore.sh /root/gno-node snapshots/1234-...tar.zst sentry
#   ./restore.sh /root/gno-node snapshots/1234-...tar.zst validator --yes
#
# --yes skips the interactive confirmation for a validator restore. Only pass
# it from an automated caller (autoheal.sh) that has ALREADY verified the old
# validator + tmkms are stopped — see the checklist below.
set -euo pipefail

DEPLOY_DIR="${1:-}"
ARCHIVE="${2:-}"
SERVICE="${3:-}"
YES="${4:-}"
if [ -z "$DEPLOY_DIR" ] || [ -z "$ARCHIVE" ] || [ -z "$SERVICE" ]; then
  echo "Usage: $0 <deploy_dir> <archive.tar.zst> <compose_service> [--yes]" >&2
  exit 2
fi
[ -d "$DEPLOY_DIR" ] || { echo "❌ deploy dir not found: $DEPLOY_DIR" >&2; exit 1; }
[ -f "$ARCHIVE" ]    || { echo "❌ archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"
DATA_DIR="$DEPLOY_DIR/gnoland-data"
[ -d "$DATA_DIR" ]   || { echo "❌ $DATA_DIR not found" >&2; exit 1; }

if [ "$SERVICE" = "validator" ]; then
  cat >&2 <<'WARN'
⚠️  VALIDATOR RESTORE — anti-double-sign checklist:
    1. The old validator + its tmkms MUST be fully dead (never two signers).
    2. Keep the validator's OWN keys/state, restored out-of-band (NOT in this
       archive): gnoland node_key + tmkms consensus.key, kms-identity.key and
       consensus_state.json. Its height must NOT go backwards.
    3. This restores CHAIN DATA only; it does NOT touch tmkms secrets.
WARN
  if [ "$YES" = "--yes" ]; then
    echo "--yes passed: skipping interactive confirmation (caller already verified the checklist above)." >&2
  else
    read -r -p "Proceed with validator restore? [y/N] " ans
    case "$ans" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
  fi
fi

cd "$DEPLOY_DIR"
echo "==> Stopping $SERVICE"
docker compose stop "$SERVICE" >/dev/null 2>&1 || true

echo "==> Wiping gnoland-data/{db,wal}"
rm -rf gnoland-data/db gnoland-data/wal

echo "==> Extracting $ARCHIVE"
zstd -dc "$ARCHIVE" | tar -C gnoland-data -x

echo "==> Starting $SERVICE"
docker compose start "$SERVICE" >/dev/null

echo "✅ Restore done. Watch it catch up (latest_block_height climbs, catching_up -> false)."
```

- [ ] **Step 2: Commit**

```bash
git add roles/autoheal/files/restore.sh
git commit -m "feat(ansible): roles/autoheal restore.sh (--yes from the start)"
```

---

### Task 9: `autoheal.sh.j2` — orchestrator

**Files:**
- Create: `roles/autoheal/templates/autoheal.sh.j2`

**Interfaces:**
- Consumes: `./pull-from-s3.sh` (Task 7, stdout = path), `./restore.sh
  <deploy_dir> <archive> <service> --yes` (Task 8).
- Produces: `./autoheal.sh` (no args) — exit 0 on confirmed catch-up, exit 1
  on any failure. Called by `check-stuck.sh.j2` (Task 6) or manually.

- [ ] **Step 1: Write the template**

```bash
#!/usr/bin/env bash
# Rendered by roles/autoheal. Orchestrates a full auto-heal restore of this
# node ({{ autoheal_node_type }}): incident backup, pull the latest snapshot
# from Scaleway, restore, restart (tmkms-aware ordering for the validator),
# verify catch-up. Invoked by check-stuck.sh once the node has been confirmed
# stuck for {{ autoheal_stuck_threshold }} consecutive checks.
set -euo pipefail

cd "$(dirname "$0")"

NODE_TYPE="{{ autoheal_node_type }}"
DEPLOY_DIR="{{ autoheal_deploy_dir }}"
SERVICE="{{ autoheal_compose_service }}"
RPC="http://{{ autoheal_rpc_bind }}"
STATE_DIR="{{ autoheal_state_dir }}"
LOCK_FILE="$STATE_DIR/${NODE_TYPE}.lock"
COOLDOWN="{{ autoheal_cooldown_seconds }}"
CATCHUP_TIMEOUT="{{ autoheal_catchup_timeout_seconds }}"
INCIDENT_DIR="$STATE_DIR/incidents"

[ -f .env ] && set -a && . ./.env && set +a

mkdir -p "$STATE_DIR" "$INCIDENT_DIR"

alert() {
  local event="$1" message="$2"
  echo "[ALERT] $event: $message"
  if [ -n "${WEBHOOK_URL:-}" ]; then
    curl -s --max-time 5 -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$NODE_TYPE" --arg e "$event" --arg m "$message" \
            '{node:$n, event:$e, message:$m}')" >/dev/null 2>&1 || true
  fi
}

# --- Anti-flapping ------------------------------------------------------------
if [ -f "$LOCK_FILE" ]; then
  LOCK_TS="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
  ELAPSED=$(( $(date -u +%s) - LOCK_TS ))
  if [ "$ELAPSED" -lt "$COOLDOWN" ]; then
    alert "cooldown-blocked" "${NODE_TYPE}: a restore already ran ${ELAPSED}s ago (cooldown ${COOLDOWN}s) — refusing to run again. Needs human investigation."
    exit 1
  fi
fi
date -u +%s > "$LOCK_FILE"

alert "restore-triggered" "${NODE_TYPE}: stuck detected, starting auto-heal restore."

# --- 1. Incident backup (full gnoland-data, secrets included, forensic only) --
TS="$(date -u +%Y%m%dT%H%M%SZ)"
INCIDENT_ARCHIVE="$INCIDENT_DIR/${NODE_TYPE}-${TS}.tar.zst"
echo "==> Incident backup: $DEPLOY_DIR/gnoland-data -> $INCIDENT_ARCHIVE"
if ! tar -C "$DEPLOY_DIR" -c gnoland-data | zstd -q -T0 -o "$INCIDENT_ARCHIVE"; then
  alert "restore-failed" "${NODE_TYPE}: incident backup failed — aborting before touching data."
  exit 1
fi

# --- 2. Pull the latest snapshot from Scaleway ---------------------------------
echo "==> Pulling latest snapshot from Scaleway"
if ! LATEST="$(./pull-from-s3.sh)"; then
  alert "restore-failed" "${NODE_TYPE}: pull-from-s3.sh failed — aborting, node left untouched."
  exit 1
fi
echo "==> Using snapshot: $LATEST"

# --- 3. Validator-only local safety check (anti-double-sign) -------------------
if [ "$NODE_TYPE" = "validator" ]; then
  echo "==> Stopping gnoland + tmkms"
  (cd "$DEPLOY_DIR" && docker compose stop "$SERVICE" tmkms >/dev/null 2>&1 || true)
  for svc in "$SERVICE" tmkms; do
    # -a is required: a plain 'compose ps' only lists RUNNING containers, so a
    # cleanly-stopped (exited) container would otherwise report empty state,
    # not "exited" — making this check fail-closed on every clean stop.
    STATE="$(cd "$DEPLOY_DIR" && docker compose ps -a --format '{% raw %}{{.State}}{% endraw %}' "$svc" 2>/dev/null || echo missing)"
    if [ "$STATE" != "exited" ] && [ "$STATE" != "missing" ]; then
      alert "restore-aborted" "${NODE_TYPE}: $svc did not stop cleanly (state=$STATE) — refusing to wipe data, possible live signer. Manual intervention required."
      exit 1
    fi
  done
fi

# --- 4. Restore (delegates to restore.sh --yes; it also restarts $SERVICE) -----
echo "==> Restoring $DEPLOY_DIR from $LATEST"
if ! ./restore.sh "$DEPLOY_DIR" "$LATEST" "$SERVICE" --yes; then
  alert "restore-failed" "${NODE_TYPE}: restore.sh failed — see logs."
  exit 1
fi

# --- 5. Validator only: start tmkms too (restore.sh only starts $SERVICE) ------
if [ "$NODE_TYPE" = "validator" ]; then
  echo "==> restore.sh already started $SERVICE; starting tmkms now"
  sleep 5
  if ! (cd "$DEPLOY_DIR" && docker compose start tmkms >/dev/null); then
    alert "restore-failed" "${NODE_TYPE}: tmkms failed to start after restore — validator is up WITHOUT a signer attached. Manual intervention required."
    exit 1
  fi
fi

# --- 6. Verify catch-up ----------------------------------------------------------
echo "==> Waiting for catch-up (timeout ${CATCHUP_TIMEOUT}s)"
ELAPSED=0
while [ "$ELAPSED" -lt "$CATCHUP_TIMEOUT" ]; do
  CATCHING_UP="$(curl -s --max-time 5 "$RPC/status" 2>/dev/null | jq -r '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"
  if [ "$CATCHING_UP" = "false" ]; then
    alert "restore-succeeded" "${NODE_TYPE}: restored from $LATEST and caught up."
    rm -f "$STATE_DIR/${NODE_TYPE}.state"
    exit 0
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

alert "restore-timeout" "${NODE_TYPE}: restored from $LATEST but did not catch up within ${CATCHUP_TIMEOUT}s — needs investigation."
exit 1
```

- [ ] **Step 2: Commit**

```bash
git add roles/autoheal/templates/autoheal.sh.j2
git commit -m "feat(ansible): roles/autoheal autoheal.sh.j2 orchestrator"
```

---

### Task 10: systemd templates + `tasks/main.yml`

**Files:**
- Create: `roles/autoheal/templates/gno-autoheal-check.service.j2`
- Create: `roles/autoheal/templates/gno-autoheal-check.timer.j2`
- Create: `roles/autoheal/tasks/main.yml`

**Interfaces:**
- Consumes: every file from Tasks 5–9 (renders/copies them into
  `autoheal_deploy_dir`) plus `roles/snapshotter`'s existing `jq`/`zstd`/
  `curl`/`rclone` apt-dependency pattern (same packages, installed
  idempotently again here since this role may land on a host
  `roles/snapshotter` never touched — the validator).

- [ ] **Step 1: `roles/autoheal/templates/gno-autoheal-check.service.j2`**

```ini
# Rendered by roles/autoheal. Oneshot: run one stuck-detection check (and,
# if the node is confirmed stuck, the auto-heal restore it triggers).
# Triggered by gno-autoheal-check.timer.
[Unit]
Description=Check if the {{ autoheal_node_type }} node is stuck and auto-heal it
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
WorkingDirectory={{ autoheal_deploy_dir }}
ExecStart={{ autoheal_deploy_dir }}/check-stuck.sh
```

- [ ] **Step 2: `roles/autoheal/templates/gno-autoheal-check.timer.j2`**

```ini
[Unit]
Description=Run gno-autoheal-check.service periodically

[Timer]
OnCalendar={{ autoheal_check_interval }}
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: `roles/autoheal/tasks/main.yml`**

```yaml
---
# tasks file for roles/autoheal — deploy stuck-node detection + auto-restore
# on THIS host (sentry or validator, per autoheal_node_type). Stages
# everything but does NOT start the timer: the operator fills .env (Scaleway
# read-only keys + webhook URL) and enables it. No secret is ever rendered by
# this role (only autoheal.env.example).

- name: Assert required variables are set
  ansible.builtin.assert:
    that:
      - autoheal_node_type in ['sentry', 'validator']
      - autoheal_chain_id | length > 0
      - autoheal_s3_bucket | length > 0
      - autoheal_s3_prefix | length > 0
    fail_msg: >-
      autoheal_node_type must be 'sentry' or 'validator', and
      autoheal_chain_id/autoheal_s3_bucket/autoheal_s3_prefix must be set
      (s3_bucket/s3_prefix must match the sentry's roles/snapshotter values).

- name: Ensure auto-heal dependencies are installed
  ansible.builtin.apt:
    name: [jq, zstd, curl, rclone]
    state: present
    update_cache: true

- name: Assert the deploy dir exists (the node must already be deployed)
  ansible.builtin.stat:
    path: "{{ autoheal_deploy_dir }}/gnoland-data"
  register: _data_dir

- name: Fail if the node isn't deployed yet
  ansible.builtin.fail:
    msg: >-
      {{ autoheal_deploy_dir }}/gnoland-data not found. Deploy the
      {{ autoheal_node_type }} node first (see DEPLOYMENT_RUNBOOK.md).
  when: not _data_dir.stat.exists

- name: Create state dir
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: "0700"
  loop:
    - "{{ autoheal_state_dir }}"
    - "{{ autoheal_state_dir }}/incidents"

- name: Stage restore.sh
  ansible.builtin.copy:
    src: restore.sh
    dest: "{{ autoheal_deploy_dir }}/restore.sh"
    mode: "0755"

- name: Render check-stuck.sh + pull-from-s3.sh + autoheal.sh
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "{{ autoheal_deploy_dir }}/{{ item }}"
    mode: "0755"
  loop:
    - check-stuck.sh
    - pull-from-s3.sh
    - autoheal.sh

# .env.example only — placeholders, no secret. The operator copies it to .env.
- name: Render autoheal.env.example
  ansible.builtin.template:
    src: autoheal.env.example.j2
    dest: "{{ autoheal_deploy_dir }}/autoheal.env.example"
    mode: "0644"

- name: Render systemd units (service + timer)
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    mode: "0644"
  loop:
    - gno-autoheal-check.service
    - gno-autoheal-check.timer
  notify: reload systemd

# Deliberately NOT started/enabled here — see the debug message.
- name: Auto-heal staged
  ansible.builtin.debug:
    msg: >-
      Auto-heal staged in {{ autoheal_deploy_dir }} for node_type
      {{ autoheal_node_type }}. Next (operator):
      1) cp autoheal.env.example .env && chmod 600 .env  (fill a READ-ONLY
         Scaleway key matching the sentry's bucket/prefix, + webhook URL)
      2) systemctl enable --now gno-autoheal-check.timer
      3) systemctl list-timers gno-autoheal-check.timer
```

- [ ] **Step 4: Syntax-check**

```bash
ansible-playbook --syntax-check -i inventory-vagrant.yaml install-autoheal.yml
```

(This will fail until Task 11 creates `install-autoheal.yml` — run this step
again at the end of Task 11 instead if working strictly task-by-task.)

- [ ] **Step 5: Commit**

```bash
git add roles/autoheal/templates/gno-autoheal-check.service.j2 roles/autoheal/templates/gno-autoheal-check.timer.j2 roles/autoheal/tasks/main.yml
git commit -m "feat(ansible): roles/autoheal systemd units + tasks/main.yml"
```

---

### Task 11: `install-autoheal.yml` playbook

**Files:**
- Create: `install-autoheal.yml`
- Modify: `inventory.yaml.example` (document the two new per-host vars)

**Interfaces:**
- Consumes: `roles/autoheal` (Task 10), applied to both the `sentries` and
  `validators` inventory groups, each host setting its own
  `autoheal_node_type`.

- [ ] **Step 1: Write `install-autoheal.yml`**

```yaml
---
# =============================================================================
# Install stuck-node detection + auto-restore on the sentry AND the validator.
# Snapshots come from Scaleway Object Storage (roles/snapshotter, sentry-only,
# must already be running and pushing).
#
#   ansible-playbook -i inventory.yaml install-autoheal.yml --tags autoheal
#
# The role stages the scripts + systemd timer but does NOT enable it. Finish
# on each host: fill .env (read-only Scaleway key + webhook URL), then
# `systemctl enable --now gno-autoheal-check.timer`. See roles/autoheal/README.md.
# =============================================================================

- name: Install auto-heal on the sentry
  hosts: "{{ target | default('gno-sentry') }}"
  become: false

  vars:
    gno_dir: devnet
    autoheal_enabled: true
    autoheal_node_type: sentry
    autoheal_chain_id: "dev"                # <-- set to the deployed chain id
    # Must match roles/snapshotter's snapshotter_s3_bucket / snapshotter_s3_prefix.
    autoheal_s3_bucket: gno-snapshots-prod
    autoheal_s3_prefix: "gno-sentry/snapshotter"

  tasks:
    - name: Deploy autoheal role (sentry)
      ansible.builtin.include_role:
        name: autoheal
      when: autoheal_enabled | default(false) | bool
      tags: [autoheal]

- name: Install auto-heal on the validator
  hosts: "{{ target | default('gno-validator') }}"
  become: false

  vars:
    gno_dir: devnet
    autoheal_enabled: true
    autoheal_node_type: validator
    autoheal_chain_id: "dev"                # <-- set to the deployed chain id
    autoheal_s3_bucket: gno-snapshots-prod
    autoheal_s3_prefix: "gno-sentry/snapshotter"

  tasks:
    - name: Deploy autoheal role (validator)
      ansible.builtin.include_role:
        name: autoheal
      when: autoheal_enabled | default(false) | bool
      tags: [autoheal]
```

- [ ] **Step 2: Document the vars in `inventory.yaml.example`**

Add a comment near the `sentries`/`validators` group blocks pointing at
`install-autoheal.yml` for the `autoheal_*` vars — these stay in the
playbook's own `vars:` (single source per environment) rather than the
inventory, since `autoheal_s3_prefix` must match `roles/snapshotter`'s value
1:1 and is easiest to keep correct next to it. No inventory change is
strictly required; skip this step if it doesn't clarify anything once Task
11 Step 1 is in place.

- [ ] **Step 3: Syntax-check + dry-run against the vagrant inventory**

```bash
ansible-playbook --syntax-check -i inventory-vagrant.yaml install-autoheal.yml
ansible-playbook -i inventory-vagrant.yaml install-autoheal.yml --check --diff
```

Expected: syntax-check passes; `--check` run either succeeds (if the vagrant
boxes have a deployed node) or fails cleanly at the "Fail if the node isn't
deployed yet" assertion (Task 10) — both are acceptable proof the playbook
and role logic are sound; a raw Ansible traceback is not.

- [ ] **Step 4: Commit**

```bash
git add install-autoheal.yml
git commit -m "feat(ansible): install-autoheal.yml playbook (sentry + validator)"
```

---

### Task 12: Docs

**Files:**
- Create: `roles/autoheal/README.md`
- Modify: `roles/snapshotter/README.md` (fix the now-stale lifecycle
  mention)

**Interfaces:** none (docs only).

- [ ] **Step 1: `roles/autoheal/README.md`**

```markdown
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
                    {{ autoheal_state_dir }}/<node_type>.state
        │ after autoheal_stuck_threshold (default 3) consecutive hits
        ▼
autoheal.sh      — lock+cooldown (default 30 min) → incident backup →
                    pull-from-s3.sh → [validator only: verify gnoland+tmkms
                    exited] → restore.sh --yes → restart (tmkms after
                    gnoland) → poll for catch-up (default 20 min timeout)
```

A node whose RPC is unreachable is treated as DOWN, not stuck, and never
triggers an auto-restore — a container that won't start needs investigation,
not a data restore.

## Anti-double-sign (validator)

The archive restored is chain data only (`gnoland-data/db`) — it never
touches `node_key`, tmkms's `consensus.key`, `kms-identity.key` or
`consensus_state.json` (the double-sign HRS gate). Before wiping anything,
`autoheal.sh` stops `validator`+`tmkms` and verifies via `docker compose ps`
that both are `exited`; if either isn't, it aborts and alerts instead of
touching data.

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
ls {{ autoheal_state_dir }}/incidents/   # pre-restore backups (forensic; not uploaded anywhere)
```
```

- [ ] **Step 2: Fix `roles/snapshotter/README.md`**

Replace the lifecycle-rule paragraph (the one describing "STANDARD → GLACIER
after 7 days, expiration after 90 days" bucket lifecycle) with a description
of the script-owned pruning introduced by `push-to-s3.sh`'s `KEEP_LAST`
(read the current file first — the exact paragraph to replace is under
"Scaleway setup (operator, one-time)", point 3, and the "lifecycle" line in
`defaults/main.yml`'s trailing comment):

```markdown
3. No bucket lifecycle rule needed: `push-to-s3.sh` prunes the remote itself
   after each push, keeping only the `KEEP_LAST` (default 2, see `.env`)
   snapshots with the highest block height.
```

Also update the "Restore" section's `rclone lsf`/`rclone copy` example if it
references the old lifecycle-based retention story, and drop the
`defaults/main.yml` trailing comment about "Lifecycle (STANDARD → GLACIER
after 7 d...) is configured by the operator" since it's no longer accurate.

- [ ] **Step 3: Commit**

```bash
git add roles/autoheal/README.md roles/snapshotter/README.md roles/snapshotter/defaults/main.yml
git commit -m "docs: roles/autoheal README + fix stale snapshotter lifecycle mention"
```
