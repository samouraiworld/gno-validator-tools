# Test Suite — Issues & Fix Recommendations

Analysis of the scripts in `test/counter/`. Separates intentional design choices
from real bugs that should be fixed.

---

## Design clarifications

### Sybil / stress tests — no counter assertion is intentional

`sybil_chaos.sh`, `sybil_precision.sh`, `sybil_salted_chaos.sh`, `e2e_mempool_stress.sh`
do not assert a final counter value. **This is by design.**

The goal of these scripts is not to verify arithmetic correctness but to:
- Flood the mempool with parallel transactions from multiple accounts
- Verify that the nodes do not crash, stall, or diverge under load
- Confirm that the consensus mechanism survives attack patterns (parallel, salted, synchronous)

Success = the chain is still running and responding after the storm.
The final counter value is printed for human observation, not automated validation.

---

## Real issues to fix

### 1. Port inconsistency — `e2e_crash_recovery.sh` and `e2e_state_sync.sh`

**Severity: high — will silently fail on standard setup**

`e2e_counter.sh` correctly uses the host-exposed ports (`26658`, `26659`).
`e2e_crash_recovery.sh` and `e2e_state_sync.sh` use port `26657`, which is the
**internal container port**, not the host-mapped one.

```bash
# e2e_crash_recovery.sh — wrong
RPC="http://localhost:26657"

# e2e_state_sync.sh — wrong
RPC1="http://localhost:26657"
RPC2="http://localhost:26658"

# correct (per docker-compose.yml)
# validator1 → 26658, validator2 → 26659, validator3 → 26660
```

**Fix:** Replace `26657` with `26658` in `e2e_crash_recovery.sh` and `26657`/`26658`
with `26658`/`26659` in `e2e_state_sync.sh`.

---

### 2. `sybil_precision.sh` — French regex never matches

**Severity: medium — final query always returns empty**

The final query uses a regex for the old French render text:
```bash
grep -o "Compteur Samourai : [0-9]*"
```

`counter.gno` now returns `"Samourai counter: N"` (English). The grep never matches,
so the final output is always empty.

**Fix:** Update the regex to match the current `Render()` output format.

---

### 3. `audit_*` scripts — no verification that the state-writing call actually executed

**Severity: medium — risk of false PATCHED result**

Scripts that deploy a realm, call a setter, then query the result do not verify
that the setter tx was actually committed before querying. If the `maketx run`
fails silently (wrong key, low gas, network error), the state remains at its
initial value (`0`), and the query returns `0`, which triggers `✅ PATCHED`
even though nothing was tested.

Affected: `audit_array_alias.sh`, `audit_byteslice.sh`,
`audit_cross_realm_recover.sh`, `audit_var_init_order.sh`.

**Fix:** After each `maketx run`, check the output for `OK!` and exit with an
explicit error if not found — the same pattern already used for the deploy step.

Example:
```bash
if ! echo "$SET" | grep -q "OK!"; then
    echo "❌ setter tx failed — cannot conclude"; rm -rf "$TMPDIR"; exit 1
fi
```

---

### 4. `e2e_nonce_replay.sh` — sequence extraction is fragile

**Severity: low — works by chance, breaks on format change**

The address extraction from `gnokey list`:
```bash
grep -oE 'addr: g1[a-z0-9]+' | head -1 | awk '{print $2}'
```

`grep -oE 'addr: g1[a-z0-9]+'` captures the full string `"addr: g1xxx"`.
`awk '{print $2}'` then extracts the second whitespace-separated word, which
happens to be `g1xxx`. This works today but is fragile: a change in spacing or
label format breaks the extraction silently (ADDR becomes empty, the auth query
fails, CURRENT_SEQ stays empty, REPLAY_SEQ defaults to 0 — which may or may not
be a valid replay scenario).

**Fix:** Extract only the address directly:
```bash
ADDR=$(gnokey list 2>/dev/null | grep -oE 'g1[a-z0-9]{38,}' | head -1)
```

---

### 5. `e2e_crash_recovery.sh` and `e2e_state_sync.sh` — no final state assertion

**Severity: low — tests always pass even if chain is broken**

Both tests end by printing or comparing values but do not fail when the
post-recovery state is wrong. `e2e_crash_recovery.sh` only prints the final
counter. `e2e_state_sync.sh` compares the two validators but does not validate
that the value is meaningful (two empty strings compare as equal).

This is different from the sybil tests: here the goal IS correctness (state
survived the crash / sync worked), so an assertion makes sense.

**Fix:** Add a check that the final counter is a non-empty number and, for
`e2e_state_sync.sh`, that both values are non-empty before comparing.

---

## Summary

| Issue | Severity | Intentional? | Needs fix |
| --- | --- | --- | --- |
| Sybil/stress — no counter assertion | — | ✅ By design | No |
| Port 26657 in crash/sync scripts | High | No | **Yes** |
| French regex in sybil_precision.sh | Medium | No | **Yes** |
| No setter-tx validation in audit_* | Medium | No | **Yes** |
| Fragile sequence extraction | Low | No | Yes |
| No final assertion in crash/sync | Low | No | Yes |
