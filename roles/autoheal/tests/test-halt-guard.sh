#!/usr/bin/env bash
# Tests for the voted-halt guard of roles/autoheal (check-stuck.sh, autoheal.sh).
#
# Renders the role templates with Jinja2 (trim_blocks, as Ansible's template
# module does), puts fake `curl` and `docker` first in PATH, and runs the
# scripts against a temp state dir. Nothing touches a real node, Docker or S3:
# the fake curl serves canned RPC responses and records webhook POSTs, the
# fake docker records its call and fails, autoheal.sh is replaced by a
# recorder for the check-stuck.sh cases, and pull-from-s3.sh by a recorder
# that fails (so autoheal.sh stops before any stop/restore step) for the
# autoheal.sh cases.
#
# Requirements: bash, GNU coreutils (base64 -w0), jq, python3 with jinja2.
# Optional: shellcheck (rendered scripts are linted when it is on PATH).
#
# Usage: roles/autoheal/tests/test-halt-guard.sh
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); sed 's/^/    | /' "$WORK/out.log" 2>/dev/null || true; }

# --- Render the templates ----------------------------------------------------
render() {
  local out_dir="$1" node_type="$2"
  mkdir -p "$out_dir"
  python3 - "$ROLE_DIR/templates" "$out_dir" "$node_type" "$WORK/state-$node_type" <<'PY'
import os, sys
import jinja2
tpl_dir, out_dir, node_type, state_dir = sys.argv[1:5]
env = jinja2.Environment(loader=jinja2.FileSystemLoader(tpl_dir), keep_trailing_newline=True,
                         trim_blocks=True, undefined=jinja2.StrictUndefined)
ctx = {
    "autoheal_node_type": node_type,
    "autoheal_rpc_bind": "127.0.0.1:26657",
    "autoheal_state_dir": state_dir,
    "autoheal_stuck_threshold": 3,
    "autoheal_deploy_dir": os.path.join(out_dir, "deploy"),
    "autoheal_compose_service": node_type,
    "autoheal_cooldown_seconds": 1800,
    "autoheal_catchup_timeout_seconds": 1200,
    "autoheal_incident_keep_last": 3,
    "autoheal_halt_alert_interval_seconds": 3600,
}
for name in ("check-stuck.sh", "autoheal.sh"):
    path = os.path.join(out_dir, name)
    with open(path, "w") as f:
        f.write(env.get_template(name + ".j2").render(**ctx))
    os.chmod(path, 0o755)
PY
}

# --- Fakes -------------------------------------------------------------------
# Fake curl: answers from $FAKE_RPC (status.json, halt_height.json,
# halt_min_version.json); a missing file fails like an unreachable endpoint
# (exit 7, no output). URLs must match exactly what the scripts should send.
# POSTs to the fake webhook are appended to $WORK/webhook.log.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) data="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  "http://127.0.0.1:26657/status") f="$FAKE_RPC/status.json" ;;
  'http://127.0.0.1:26657/abci_query?path=%22params/node:p:halt_height%22') f="$FAKE_RPC/halt_height.json" ;;
  'http://127.0.0.1:26657/abci_query?path=%22params/node:p:halt_min_version%22') f="$FAKE_RPC/halt_min_version.json" ;;
  "$FAKE_WEBHOOK_URL") printf '%s' "$data" | jq -c . >> "$WEBHOOK_LOG"; exit 0 ;;
  *) echo "unexpected curl URL: $url" >> "$WEBHOOK_LOG.unexpected"; exit 22 ;;
esac
[ -f "$f" ] || exit 7
cat "$f"
SH
cat > "$WORK/bin/docker" <<SH
#!/usr/bin/env bash
echo "docker \$*" >> "$WORK/docker.log"
exit 1
SH
chmod +x "$WORK/bin/curl" "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
# The scripts must read WEBHOOK_URL from the .env next to them, not from the
# environment: unset it here and write it into each rendered dir's .env.
unset WEBHOOK_URL
export FAKE_WEBHOOK_URL="http://webhook.test/hook"
export WEBHOOK_LOG="$WORK/webhook.log"

status_json() {  # height catching_up
  jq -n --arg h "$1" --argjson c "$2" '{result: {sync_info: {latest_block_height: $h, catching_up: $c}}}'
}
param_json() {  # raw JSON value of the param, or "null" for an unset param
  local data=null
  if [ "$1" != "null" ]; then
    data="\"$(printf '%s' "$1" | base64 -w0)\""
  fi
  printf '{"jsonrpc":"2.0","id":"","result":{"response":{"ResponseBase":{"Error":null,"Data":%s,"Events":null,"Log":"","Info":""},"Key":null,"Value":null,"Proof":null,"Height":"0"}}}\n' "$data"
}
param_error_json() {
  printf '{"jsonrpc":"2.0","id":"","result":{"response":{"ResponseBase":{"Error":{"@type":"/std.UnknownRequestError"},"Data":null,"Events":null,"Log":"","Info":""}}}}\n'
}

# set_rpc HEIGHT CATCHING_UP HALT_HEIGHT_JSON [MIN_VERSION_JSON]
# HALT_HEIGHT_JSON: a JSON value such as '"1000"', "null" (unset), "fail"
# (unreachable) or "error" (ABCI error response).
set_rpc() {
  export FAKE_RPC="$WORK/rpc"
  rm -rf "$FAKE_RPC" && mkdir -p "$FAKE_RPC"
  status_json "$1" "$2" > "$FAKE_RPC/status.json"
  case "$3" in
    fail) ;;
    error) param_error_json > "$FAKE_RPC/halt_height.json" ;;
    *) param_json "$3" > "$FAKE_RPC/halt_height.json" ;;
  esac
  param_json "${4:-\"v1.9.0\"}" > "$FAKE_RPC/halt_min_version.json"
}

# --- check-stuck.sh cases ----------------------------------------------------
CS_DIR="$WORK/sentry"
render "$CS_DIR" sentry
# Replace autoheal.sh by a recorder: check-stuck.sh execs it at the threshold.
cat > "$CS_DIR/autoheal.sh" <<SH
#!/usr/bin/env bash
echo "AUTOHEAL TRIGGERED" >> "$WORK/heal.log"
SH
chmod +x "$CS_DIR/autoheal.sh"
printf 'SCW_ACCESS_KEY=x\nWEBHOOK_URL="%s"\n' "$FAKE_WEBHOOK_URL" > "$CS_DIR/.env"
STATE_FILE="$WORK/state-sentry/sentry.state"

reset_case() { rm -f "$WORK/heal.log" "$STATE_FILE" "$WEBHOOK_LOG" "$WORK/out.log"; }
healed() { [ -f "$WORK/heal.log" ]; }
stuck_count() { jq -r .stuck_count "$STATE_FILE"; }
alerts() { if [ -f "$WEBHOOK_LOG" ]; then wc -l < "$WEBHOOK_LOG"; else echo 0; fi; }
run_cs() {
  if ! "$CS_DIR/check-stuck.sh" >> "$WORK/out.log" 2>&1; then
    echo "check-stuck.sh exited non-zero" >> "$WORK/out.log"
  fi
}
crashed() { grep -q "exited non-zero" "$WORK/out.log"; }
# run_samples N: run check-stuck.sh N times (first sample seeds the state).
run_samples() { local i; for ((i = 0; i < $1; i++)); do run_cs; done; }

# Real abci_query answer of gnoland-1 (rpc.gno.land, 2026-11-25), past v1.8.0 halt.
GNOLAND1_HALT_HEIGHT='{"jsonrpc":"2.0","id":"","result":{"response":{"ResponseBase":{"Error":null,"Data":"IjE2NTE1MDAi","Events":null,"Log":"","Info":""},"Key":null,"Value":null,"Proof":null,"Height":"0"}}}'

# 1. Normal progress: never stuck, never heals.
reset_case
set_rpc 100 false '"5000"'; run_cs
set_rpc 101 false '"5000"'; run_cs
set_rpc 102 false '"5000"'; run_cs
if ! healed && ! crashed && [ "$(stuck_count)" = 0 ] && grep -q "progressing normally" "$WORK/out.log"; then
  pass "progressing node: no stuck sample, no heal"
else fail "progressing node"; fi

# 2. Stuck, no halt configured (param unset, or "0"): heals at the threshold.
reset_case
set_rpc 100 false null; run_samples 4
if healed && ! crashed; then pass "stuck, halt_height unset: heals"; else fail "stuck, halt_height unset"; fi
reset_case
set_rpc 100 false '"0"'; run_samples 4
if healed && ! crashed; then pass "stuck, halt_height 0: heals"; else fail "stuck, halt_height 0"; fi

# 3. Stuck next to a halt but not at H or H+1: still heals.
for h in 999 1002; do
  reset_case
  set_rpc "$h" false '"1000"'; run_samples 4
  if healed && ! crashed; then pass "stuck at $h, halt at 1000: heals"; else fail "stuck at $h, halt at 1000"; fi
done

# 4. Stuck past an old halt, real gnoland-1 response: still heals.
reset_case
set_rpc 1813493 false null; echo "$GNOLAND1_HALT_HEIGHT" > "$FAKE_RPC/halt_height.json"; run_samples 4
if healed && ! crashed; then pass "stuck past an old halt (gnoland-1 fixture): heals"; else fail "stuck past an old halt"; fi

# 5. Frozen at the voted halt height H: no action, counter reset, log, one alert.
reset_case
set_rpc 1000 false '"1000"' '"v1.9.0"'; run_samples 6
if ! healed && ! crashed && [ "$(stuck_count)" = 0 ] \
  && grep -q "voted halt at 1000 (height=1000), waiting for upgrade to v1.9.0" "$WORK/out.log" \
  && [ "$(alerts)" = 1 ] && grep -q '"event":"voted-halt-wait"' "$WEBHOOK_LOG"; then
  pass "frozen at H: no heal, counter reset, logged, alerted once"
else fail "frozen at H"; fi

# 6. Halt alert repeats once the interval has passed.
jq '.halt_alert_ts = 1' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
run_cs
if ! healed && [ "$(alerts)" = 2 ]; then pass "halt alert repeats after the interval"; else fail "halt alert repeat"; fi

# 7. Real gnoland-1 response at its halt height H=1651500.
reset_case
set_rpc 1651500 false null '"v1.8.0"'; echo "$GNOLAND1_HALT_HEIGHT" > "$FAKE_RPC/halt_height.json"; run_samples 4
if ! healed && ! crashed && grep -q "voted halt at 1651500" "$WORK/out.log"; then
  pass "frozen at H (gnoland-1 fixture): no heal"
else fail "frozen at H (gnoland-1 fixture)"; fi

# 8. Upgraded node waiting for quorum at H+1: no action.
reset_case
set_rpc 1001 false '"1000"'; run_samples 6
if ! healed && ! crashed && [ "$(stuck_count)" = 0 ]; then pass "waiting at H+1: no heal"; else fail "waiting at H+1"; fi

# 9. A counter already at threshold-1 is reset by a halt sample.
reset_case
mkdir -p "$(dirname "$STATE_FILE")"
jq -n '{height: "1000", ts: 0, stuck_count: 2}' > "$STATE_FILE"
set_rpc 1000 false '"1000"'; run_cs
if ! healed && ! crashed && [ "$(stuck_count)" = 0 ]; then pass "halt sample resets a pending counter"; else fail "halt resets counter"; fi

# 10. Value variants at H: leading zeros, unquoted number.
for v in '"01000"' '1000'; do
  reset_case
  set_rpc 1000 false "$v"; run_samples 4
  if ! healed && ! crashed; then pass "halt_height $v at 1000: no heal"; else fail "halt_height $v at 1000"; fi
done

# 11. halt_height unreadable (unreachable, ABCI error, non-numeric, too long):
#     keeps the pre-guard behavior, failure logged.
for v in fail error '"abc"' '"-1000"' '"1234567890123456789"'; do
  reset_case
  set_rpc 1000 false "$v"; run_samples 4
  if healed && ! crashed && grep -q "could not read halt_height" "$WORK/out.log"; then
    pass "halt_height $v: heals, failure logged"
  else fail "halt_height $v"; fi
done

# 12. halt_min_version unset or not a plain version tag at a halt.
reset_case
set_rpc 1000 false '"1000"' null; run_samples 4
if ! healed && ! crashed && grep -q "halt_min_version unset" "$WORK/out.log"; then
  pass "halt without halt_min_version: no heal"
else fail "halt without halt_min_version"; fi
reset_case
set_rpc 1000 false '"1000"' '"v1.9.0\nFAKE LOG LINE"'; run_samples 4
if ! healed && grep -q "<invalid halt_min_version>" "$WORK/out.log" && ! grep -q "FAKE LOG LINE" "$WORK/out.log"; then
  pass "halt_min_version with a newline: replaced"
else fail "halt_min_version sanitizing"; fi

# 13. catching_up=true at H: normal sync, not stuck.
reset_case
set_rpc 1000 true '"1000"'; run_samples 4
if ! healed && ! crashed && [ "$(stuck_count)" = 0 ]; then pass "catching_up at H: no heal"; else fail "catching_up at H"; fi

# --- autoheal.sh cases (manual run) ------------------------------------------
AH_DIR="$WORK/validator"
render "$AH_DIR" validator
# pull-from-s3.sh is the first side-effecting step: record the call and fail
# so autoheal.sh aborts before stopping anything.
cat > "$AH_DIR/pull-from-s3.sh" <<SH
#!/usr/bin/env bash
echo "PULL CALLED" >> "$WORK/pull.log"
exit 1
SH
chmod +x "$AH_DIR/pull-from-s3.sh"
printf 'WEBHOOK_URL=%s\n' "$FAKE_WEBHOOK_URL" > "$AH_DIR/.env"
LOCK_FILE="$WORK/state-validator/validator.lock"
AH_STATE="$WORK/state-validator/validator.state"
run_ah() {
  rm -f "$WORK/pull.log" "$LOCK_FILE" "$WORK/out.log" "$WEBHOOK_LOG"
  mkdir -p "$(dirname "$AH_STATE")"
  jq -n '{height: "1000", ts: 0, stuck_count: 3}' > "$AH_STATE"
  "$AH_DIR/autoheal.sh" > "$WORK/out.log" 2>&1 || true
}
refused() {
  [ ! -f "$WORK/pull.log" ] && [ ! -f "$LOCK_FILE" ] && [ ! -f "$AH_STATE" ] \
    && grep -q "restore-skipped" "$WORK/out.log" && grep -q '"event":"restore-skipped"' "$WEBHOOK_LOG"
}

set_rpc 1000 false '"1000"'; run_ah
if refused; then pass "autoheal.sh at H: refuses, alerts, no pull, no lock, counter reset"
else fail "autoheal.sh at H"; fi

set_rpc 1001 false '"1000"'; run_ah
if refused; then pass "autoheal.sh at H+1: refuses"; else fail "autoheal.sh at H+1"; fi

set_rpc 500 false '"1000"'; run_ah
if [ -f "$WORK/pull.log" ]; then pass "autoheal.sh not at halt: proceeds to pull"; else fail "autoheal.sh not at halt"; fi

set_rpc 1000 false fail; run_ah
if [ -f "$WORK/pull.log" ] && grep -q "could not read halt_height" "$WORK/out.log"; then
  pass "autoheal.sh, halt query fails: proceeds, failure logged"
else fail "autoheal.sh, halt query fails"; fi

rm -f "$WORK/rpc/status.json"; run_ah
if [ -f "$WORK/pull.log" ] && grep -q "voted-halt guard skipped" "$WORK/out.log"; then
  pass "autoheal.sh, RPC down: proceeds, guard skipped"
else fail "autoheal.sh, RPC down"; fi

if [ ! -f "$WORK/docker.log" ]; then pass "docker never called"; else fail "docker was called"; fi
if [ ! -f "$WEBHOOK_LOG.unexpected" ]; then pass "no unexpected curl URL"
else fail "unexpected curl URL"; cat "$WEBHOOK_LOG.unexpected"; fi

# --- shellcheck on the rendered scripts -------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  render "$WORK/lint" sentry
  if shellcheck -S warning "$WORK/lint/check-stuck.sh" "$WORK/lint/autoheal.sh"; then
    pass "shellcheck on rendered scripts"
  else fail "shellcheck on rendered scripts"; fi
else
  echo "skip - shellcheck not installed"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "all tests passed"
