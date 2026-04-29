# Test Suite — Coverage & Gap Analysis

Local devnet test suite for the gno-validator-tools test environment.
Maps each script against the cherry-pick fixes planned for the gnoland1 hardfork.

Scripts in `test/counter/` are the original suite.
Scripts in `test/hardfork-audit/` target specific hardfork fixes.

---

## Scripts — test/counter/

| Script | Category | What it validates |
| --- | --- | --- |
| `audit_security.sh` | Security | VM-level vulnerability protection (overflow, recursion) |
| `e2e_counter.sh` | Consensus | Cross-validator state consistency |
| `e2e_crash_recovery.sh` | Resilience | State persistence after SIGKILL + restart |
| `e2e_mempool_stress.sh` | Load | Sequential mempool throughput (10 txs) |
| `e2e_state_sync.sh` | Consensus | State catch-up after validator downtime |
| `sybil_chaos.sh` | Stress | 300 parallel txs, 3 accounts, 3 RPC endpoints |
| `sybil_precision.sh` | Stress | 60 synchronous txs, controlled cadence |
| `sybil_salted_chaos.sh` | Stress | 150 salted parallel txs, prevents dedup |

## Scripts — test/hardfork-audit/

| Script | Fix ciblé | What it validates |
| --- | --- | --- |
| `audit_byteslice.sh` | NEWTENDG-98 `a3a356e71` | Byte-slice index mutation persisted across transactions |
| `audit_array_alias.sh` | `c64feef1d` | Array copy independence (no pointer aliasing) |
| `audit_cross_realm_recover.sh` | `f87249327` | Full state rollback when panic is caught by recover() |
| `audit_chan_type.sh` | `4bcd9828e` | chan type rejected at preprocess, not at runtime |
| `audit_runtime_pkg.sh` | `afd7e4808` | `runtime` import rejected in production VM |
| `audit_var_init_order.sh` | NEWTENDG-68 `50ee56e64` | Package-level var init in dependency order |
| `audit_gas_alloc.sh` | `5d5f9213f` | Per-byte gas model for large memory allocations |
| `e2e_nonce_replay.sh` | general | Replay protection via sequence number enforcement |

---

## Test results observed (2026-04-29)

### ✅ PATCHED — `audit_byteslice.sh` (NEWTENDG-98, `a3a356e71`)

**What was tested:** A realm stores a `[]byte`. A transaction calls `state.set(0, 5)` which
does `b.data[0] = v` via a pointer method (same pattern as the counter's `c.Inc()`).
The next query reads `state.data[0]`.

**Observed:** `bs[0] = 5` persisted correctly across transactions.

**What this means:** The fix `a3a356e71` is present in the binary. `DidUpdate()` is
correctly called after `DataByte` index assignments, so byte-slice mutations are
saved to the store. Without this fix, the write would have been computed in memory
but discarded at transaction commit, and the query would have returned `0`.

**Note on Gno constraint discovered:** Direct package-level variable assignment
(`bs[0] = v` in a plain function) is blocked by the VM with "readonly tainted object".
The mutation must go through a method with a pointer receiver — the same pattern required
by the counter. This is a Gno security invariant, not a bug.

---

### ✅ PATCHED — `audit_array_alias.sh` (`c64feef1d`)

**What was tested:** A realm stores a `[3]int` array. A transaction calls
`ModifyLocalCopy()` which does `local := arr; local[0] = 999`. The next query
reads `arr[0]` via `Render()`.

**Observed:** `arr[0]` returned `0` — the original array was unchanged.

**What this means:** The fix `c64feef1d` is present in the binary. `ArrayValue.Copy()`
creates a genuine deep copy with independent backing memory. Without this fix,
`local` and `arr` would have shared the same pointer, so `local[0] = 999` would
have silently corrupted the stored array to `999`.

---

### ❌ VULNERABLE — `audit_cross_realm_recover.sh` (`f87249327`)

**What was tested:** A realm stores an int in a struct (`holder.value`). A transaction
calls `SetAndPanic(100)` which sets `holder.value = 100` then panics. The calling
script catches the panic with `recover()`.

**Observed:** After the transaction, `holder.value = 100` — the state write survived
the panic.

**What this means:** The fix `f87249327` is NOT in the binary. When `recover()` swallows
a panic that originated inside a realm function, the state changes made by that function
are **not rolled back**. The transaction commits successfully with the corrupted state.

**Impact:** An attacker can exploit this pattern to write arbitrary partial state into
any realm: call a function that modifies state + panics, wrap the call in a `recover()`,
and the state change is committed even though the function "panicked". The chain keeps
producing blocks normally — there is no crash or observable anomaly.

**Action required:** Cherry-pick `f87249327` into the hardfork branch.

---

## Coverage vs. hardfork cherry-picks

### Tier 1 — Consensus / chain safety

| Commit | Fix | Result | Script |
| --- | --- | --- | --- |
| `b97785036` | Duplicate validator removals in EndBlocker | Partial | `e2e_state_sync.sh` |
| `b56b78f1e` | Byzantine peer gossips scrambled block parts | Not tested | — |
| `f7a23f1ea` | Block header parts too big (NEWTENDG-159) | Not tested | — |
| `3be0408f0` | Stack-overflow exploit — iterative recovery (NEWTENDG-182) | ✅ | `audit_security.sh` test 2 |
| `50ee56e64` | Variable initialisation order (NEWTENDG-68) | Not run yet | `audit_var_init_order.sh` |
| `6a6fc4c71` | uint64 overflow at compile time (NEWTENDG-164) | ✅ | `audit_security.sh` test 1 |
| `a3a356e71` | `bs[i] = v` byte-slice mutation dropped (NEWTENDG-98) | ✅ PATCHED | `audit_byteslice.sh` |
| `f87249327` | Cross-realm state corruption via panic + recover | ❌ VULNERABLE | `audit_cross_realm_recover.sh` |
| `c64feef1d` | Array aliasing in ArrayValue.Copy | ✅ PATCHED | `audit_array_alias.sh` |
| `786f06ba2` | Nil checks for block/meta retrievals | Not tested | — |
| `e72b47960` | RPC index out of bounds panic | Not tested | — |
| `8d17f08e3` | Peer stall when peer lowers announced height | Not tested | — |
| `afd7e4808` | `runtime` stdlib removed from production | Not run yet | `audit_runtime_pkg.sh` |

### Tier 2 — VM correctness

| Commit | Fix | Result | Script |
| --- | --- | --- | --- |
| `e4533a45c` | Allocation limit exceeded during recursion | Partial | `audit_security.sh` test 2 |
| `4bcd9828e` | `chan` type accepted at deploy then panics at runtime | Not run yet | `audit_chan_type.sh` |
| `d27fdaff5` | `AssertOriginCall` rejected valid cross-realm closures | Not tested | — |
| `e6da9024a` | Allocation bug triggered on node restart/restore | Partial | `e2e_crash_recovery.sh` |
| `5d5f9213f` | Per-byte gas for mem allocation | Not run yet | `audit_gas_alloc.sh` |
| `81d9f806c` | `Coins.AmountOf` silently returns first on duplicate denom | Not tested | — |

---

## Summary

| Status | Count | Details |
| --- | --- | --- |
| ✅ Patched | 4 | `6a6fc4c71`, `3be0408f0`, `a3a356e71`, `c64feef1d` |
| ❌ Vulnerable | 1 | `f87249327` — **must cherry-pick before hardfork** |
| Not run yet | 6 | hardfork-audit scripts written, not executed |
| Not tested | ~15 | Network-level and RPC fixes, no local script |
