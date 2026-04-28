#  DOCS: Test13 Devnet Setup & Smart Contract Testing on [Gno.land](http://Gno.land) (LOURS)

This guide explains how to properly set up a local Gno infrastructure with a validator + sentry architecture.

---

## 1. Project Structure

```bash
mkdir -p validator sentry otel
```

```
.
├── docker-compose.yml
├── genesis.json
├── genesis_balances.txt
├── validator/
│   ├── config.toml
│   ├── entrypoint.sh
│   ├── genesis.json
│   └── gnoland-data/
├── sentry/
│   ├── config.toml
│   ├── entrypoint.sh
│   ├── genesis.json
│   └── gnoland-data/
```

---

## 2. Generate Genesis (FIRST STEP)

```bash
gnogenesis generate
```

### Add balances

```bash
gnogenesis balances add -balance-sheet ./genesis_balances.txt
gnogenesis txs add sheets ./../gno/gno.land/genesis/genesis_txs.jsonl

```
### Create User Key

```bash
gnokey add test13-bis
```
### Enable unrestricted mode (local only)

```bash
gnogenesis params set auth.unrestricted_addrs test13-bis_ADDRESS -genesis-path ./genesis.json
```

---

## 3. Generate Node Configs

```bash
gnoland config init 
cp config.toml sentry/
cp config.toml validator/

```

---

## 4. Initialize Node Secrets

```bash
cd sentry
gnoland secrets init 
cd validator 
gnoland secrets init 
```

---

## 5. Distribute Genesis

```bash
cp ./genesis.json ./validator/genesis.json
cp ./genesis.json ./sentry/genesis.json
```

---

## 6. Start Infrastructure

```bash
docker-compose up -d
```
---

## 8. Reset Workflow

For sentry and validator repository 
```bash
cd gnoland-data
rm -rf db wal config genesis.json
```
and reset priv_validator_state.json for validator. Keep a direcotry secret for not change a compose


```bash
docker-compose up -d
```


## 3. Develop the Realm (Counter)

Create a folder for your project. The `gnomod.toml` file defines the module path.

`gnomod.toml`:

```toml
module = "gno.land/r/test/counter"
gno = "0.9"
```

`counter.gno`:

Using a struct with attached methods is the recommended pattern to avoid VM read/write lock errors.

```go
package counter

import "strconv"

type Counter struct {
    Value int
}

var c Counter

func Increment() {
    c.Inc()
}

func (c *Counter) Inc() {
    c.Value++
}

func Render(path string) string {
    return "Samourai counter: " + strconv.Itoa(c.Value)
}
```

## 4. Deploy and Interact

### Step 1: Publish the Package

Use `addpkg` to send the code to the blockchain.

```bash
gnokey maketx addpkg \
    -pkgpath "gno.land/r/test13/v1/counter" \
    -pkgdir "." \
    -gas-fee 1000000ugnot \
    -gas-wanted 5000000 \
    -broadcast \
    -chainid dev \
    -remote http://localhost:26657 \
    test13-bis
```
⚠️ Packages are immutable.
To deploy a new version, you MUST change the pkgpath:

Example:
gno.land/r/test13/v2/counter

### Step 2: Call Increment

To modify the value, use a trigger script `fix.gno` via the `run` command.

`fix.gno`:

```go
package main

import "gno.land/r/test13/v3/counter"

func main() {
    counter.Increment()
}
```

Run command:

```bash
gnokey maketx run \
    -gas-fee 1000000ugnot \
    -gas-wanted 3000000 \
    -broadcast \
    -chainid dev \
    -remote http://localhost:26657 \
    test13-bis \
    fix.gno
```

#### Why not `maketx call`?

`call` uses MsgCall, which requires a crossing function.
Our `Increment()` function is not crossing, so it cannot be called this way.

Use `maketx run` instead, which executes a script with MsgRun.

### Step 3: Verify the Result

Use `vm/qeval` to call the `Render` function and see the current value:

```bash
gnokey query "vm/qeval" \
    -data "gno.land/r/test13/v3/counter.Render(\"\")" \
    -remote http://localhost:26657
```
`vm/qeval` is a read-only query.
It does not create a transaction and does not modify state.

## Key Takeaways

- **Genesis:** `unrestricted_addrs` bypasses the default security protections.
- **Gno pattern:** Always use structs and methods to manipulate state.
- **MsgRun:** The `run` command is ideal during development to test functions without setting up complex crossing functions.

## 5. Crash Test (Validator Resilience)

This section validates how a local Gno validator behaves under abrupt failures.

### Test 1 — Kill the Internal Process

Retrieve the PID of the validator process:

```bash
docker inspect -f '{{.State.Pid}}' test13-validator-1
```

Kill the process inside the container:

```bash
 kill -9 <PID>
```

**Expected result:**
- The container automatically restarts  
- The blockchain continues producing blocks  
- No state corruption occurs  

This confirms that the node can recover from a brutal process crash.

---

### Test 2 — Kill the Container

```bash
docker kill -s SIGKILL test13-validator-1
```

**Expected result:**
- The container stops completely  
- It does NOT restart automatically (with default `on-failure` policy)  

Manual restart is required:

```bash
docker compose up -d
```

---

### Recommended Improvement

To ensure automatic recovery even after a container kill, update your `docker-compose.yml`:

```yaml
restart: always
```

This makes the validator more resilient in real-world conditions.

---

### ⚠️ Limitations of This Test

This test is performed with a **single validator only**, which means:

- No distributed consensus is involved  
- It does NOT test network-level fault tolerance  
- It only validates local node recovery and state persistence  

---

## 6. Next Steps — Multi-Validator & Advanced E2E Testing

The current setup is based on a single validator + sentry architecture, which is sufficient to validate:

- local deployment workflow
- contract execution
- - state persistence
node crash recovery

However, this setup does not fully test consensus behavior or network-level resilience.

---

### Planned Improvements

The next step is to extend this environment to a multi-validator network in order to simulate more realistic conditions.

This will include:

- running multiple validators
- configuring peer-to-peer networking between nodes
- validating block propagation and consensus behavior
- testing validator synchronization and recovery

---

### E2E Testing Strategy

In addition to infrastructure improvements, dedicated End-to-End (E2E) test scripts will be introduced.

These scripts aim to simulate real user activity by interacting with the chain through RPC.

Planned scenarios include:

1. Deployment & Interaction
    - deploy multiple packages
    - call contract functions repeatedly
    - verify state evolution
2. Persistence Testing
    - restart nodes during execution
    - verify that state is preserved after restart
3. Failure Scenarios
    - invalid transactions (wrong gas, wrong function, etc.)
    - malformed requests
    - concurrent transaction submission
4. Stress Testing
    - batch transaction execution
    - parallel calls to the same contract
    - mempool pressure simulation

---

### Objective

The goal of these tests is to:

- identify edge cases in the Gno VM
- detect RPC inconsistencies
- validate node robustness under stress
- ensure reproducibility of bugs

---
### Status

These advanced tests are planned and will be executed next as part of the ongoing validation process.