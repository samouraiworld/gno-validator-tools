#!/usr/bin/env bash
# Tests for the voted-halt guard of roles/autoheal (check-stuck.sh, autoheal.sh).
#
# Renders the role templates with Jinja2, puts a fake `curl` first in PATH
# that serves canned RPC responses, and runs the scripts against a temp state
# dir. Nothing touches a real node, Docker or S3: autoheal.sh is replaced by a
# recorder for the check-stuck.sh cases, and pull-from-s3.sh by a recorder
# that fails (so autoheal.sh stops before any stop/restore step) for the
# autoheal.sh cases.
#
# Requirements: bash, jq, base64, python3 with jinja2. Optional: shellcheck
# (rendered scripts are linted when it is on PATH).
#
# Usage: roles/autoheal/tests/test-halt-guard.sh
set -euo pipefail

ROLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

# --- Render the templates ----------------------------------------------------
render() {
  local out_dir="$1" node_type="$2"
  mkdir -p "$out_dir"
  python3 - "$ROLE_DIR/templates" "$out_dir" "$node_type" "$WORK/state-$node_type" <<'PY'
import os, sys
import jinja2
tpl_dir, out_dir, node_type, state_dir = sys.argv[1:5]
env = jinja2.Environment(loader=jinja2.FileSystemLoader(tpl_dir), keep_trailing_newline=True,
                         undefined=jinja2.StrictUndefined)
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
}
for name in ("check-stuck.sh", "autoheal.sh"):
    path = os.path.join(out_dir, name)
    with open(path, "w") as f:
        f.write(env.get_template(name + ".j2").render(**ctx))
    os.chmod(path, 0o755)
PY
}

# --- Fake RPC (curl stub) ----------------------------------------------------
# Reads its answers from $FAKE_RPC: status.json, halt_height.json,
# halt_min_version.json. A missing file makes the stub fail like an
# unreachable endpoint (curl exit 7, empty output).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */status) f="$FAKE_RPC/status.json" ;;
  *node:p:halt_height*) f="$FAKE_RPC/halt_height.json" ;;
  *node:p:halt_min_version*) f="$FAKE_RPC/halt_min_version.json" ;;
  *) exit 0 ;;  # webhook POSTs and anything else: accept silently
esac
[ -f "$f" ] || exit 7
cat "$f"
SH
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

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
STATE_FILE="$WORK/state-sentry/sentry.state"

reset_case() { rm -f "$WORK/heal.log" "$STATE_FILE"; }
healed() { [ -f "$WORK/heal.log" ]; }
stuck_count() { jq -r .stuck_count "$STATE_FILE"; }
run_cs() { "$CS_DIR/check-stuck.sh" > "$WORK/out.log" 2>&1; }
# run_samples N: run check-stuck.sh N times (first sample seeds the state).
run_samples() { local i; for ((i = 0; i < $1; i++)); do run_cs; done; }

# 1. Normal progress: never stuck, never heals.
reset_case
set_rpc 100 false '"5000"'; run_cs
set_rpc 101 false '"5000"'; run_cs
set_rpc 102 false '"5000"'; run_cs
if ! healed && [ "$(stuck_count)" = 0 ] && grep -q "progressing normally" "$WORK/out.log"; then
  pass "progressing node: no stuck sample, no heal"
else fail "progressing node"; fi

# 2. Stuck, no halt configured (param unset): heals at the threshold.
reset_case
set_rpc 100 false null; run_samples 4
if healed; then pass "stuck, halt_height unset: heals"; else fail "stuck, halt_height unset"; fi

# 3. Stuck below a future halt (H-1 included): still heals.
reset_case
set_rpc 999 false '"1000"'; run_samples 4
if healed; then pass "stuck at H-1 of a future halt: heals"; else fail "stuck at H-1"; fi

# 4. Stuck past an old halt (gnoland-1 today: H=1651500): still heals.
reset_case
set_rpc 1813493 false '"1651500"' '"v1.8.0"'; run_samples 4
if healed; then pass "stuck past an old halt: heals"; else fail "stuck past an old halt"; fi

# 5. Frozen at the voted halt height H: no action, counter reset, log.
reset_case
set_rpc 1000 false '"1000"' '"v1.9.0"'; run_samples 6
if ! healed && [ "$(stuck_count)" = 0 ] \
  && grep -q "voted halt at 1000 (height=1000), waiting for upgrade to v1.9.0" "$WORK/out.log"; then
  pass "frozen at H: no heal, counter reset, logged"
else fail "frozen at H"; cat "$WORK/out.log"; fi

# 6. Upgraded node waiting for quorum at H+1: no action.
reset_case
set_rpc 1001 false '"1000"'; run_samples 6
if ! healed && [ "$(stuck_count)" = 0 ]; then pass "waiting at H+1: no heal"; else fail "waiting at H+1"; fi

# 7. A counter already at threshold-1 is reset by a halt sample.
reset_case
jq -n '{height: "1000", ts: 0, stuck_count: 2}' > "$STATE_FILE"
set_rpc 1000 false '"1000"'; run_cs
if ! healed && [ "$(stuck_count)" = 0 ]; then pass "halt sample resets a pending counter"; else fail "halt resets counter"; fi

# 8. halt_height query fails (unreachable): keeps the pre-guard behavior.
reset_case
set_rpc 1000 false fail; run_samples 4
if healed && grep -q "could not read halt_height" "$WORK/out.log"; then
  pass "halt query unreachable: heals, failure logged"
else fail "halt query unreachable"; fi

# 9. halt_height query returns an ABCI error: same as a failure.
reset_case
set_rpc 1000 false error; run_samples 4
if healed && grep -q "could not read halt_height" "$WORK/out.log"; then
  pass "halt query ABCI error: heals, failure logged"
else fail "halt query ABCI error"; fi

# 10. halt_min_version unset at a halt: still no action.
reset_case
set_rpc 1000 false '"1000"' null; run_samples 4
if ! healed && grep -q "halt_min_version unset" "$WORK/out.log"; then
  pass "halt without halt_min_version: no heal"
else fail "halt without halt_min_version"; fi

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
LOCK_FILE="$WORK/state-validator/validator.lock"
run_ah() { rm -f "$WORK/pull.log" "$LOCK_FILE"; "$AH_DIR/autoheal.sh" > "$WORK/out.log" 2>&1 || true; }

set_rpc 1000 false '"1000"'; run_ah
if [ ! -f "$WORK/pull.log" ] && [ ! -f "$LOCK_FILE" ] && grep -q "restore-skipped" "$WORK/out.log"; then
  pass "autoheal.sh at H: refuses, no pull, no lock"
else fail "autoheal.sh at H"; cat "$WORK/out.log"; fi

set_rpc 1001 false '"1000"'; run_ah
if [ ! -f "$WORK/pull.log" ]; then pass "autoheal.sh at H+1: refuses"; else fail "autoheal.sh at H+1"; fi

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
