# roles/tmkms

Externalize a gnoland validator's **consensus signing** to a [tmkms] sidecar
container (softsign backend). Two transports, picked via
`tmkms_connection_mode`:

- **`uds`** (default) — same host as the validator, Unix socket. gnoland
  opens a privval listener on a Unix-domain socket; tmkms dials in and signs.
  Reference: `compose/validator-sentry-tmkms/`.
- **`tcp`** — dedicated signer host, separate from the validator, over TCP.
  Reference implementation this role reuses: `tmkms-lab/` (proven 2-VM lab
  pattern) + `compose/tmkms-alone/`.

In both modes, the consensus key lives in tmkms, not in the gnoland process.

[tmkms]: https://github.com/iqlusioninc/tmkms

---

## Purpose

Running tmkms as a sidecar gives two benefits over the default in-process
signing:

- The consensus key (`priv_validator_key.json`) is no longer loaded by the
  gnoland process at runtime; only the tmkms container holds the extracted
  32-byte seed.
- The signing code path is isolated to a dedicated container (tmkms v0.15.0,
  softsign feature only).

In `uds` mode the key material is still on the same box, so this is a
defence-in-depth measure rather than full key isolation. Full isolation
requires the `tcp` mode (dedicated signer host, not P2P-exposed).

---

## Image requirement

The gnoland image must support `tmkms_listener`. This is merged in gno master
as of PR [#5718] / commit `a870686e4`. Use a gnoland image built from gno
`master` at or after that commit.

[#5718]: https://github.com/gnolang/gno/pull/5718

---

## Variables

All variables are declared in `defaults/main.yml`. There are no required
variables except `tmkms_chain_id`.

| Variable | Default | Description |
| --- | --- | --- |
| `tmkms_enabled` | `false` | Master switch. When `false` the role is a no-op and the compose file omits the tmkms service entirely. |
| `tmkms_chain_id` | `""` | **Required.** Must match the genesis `chain_id` and the `tmkms_listener.chain_id` in config.toml. |
| `tmkms_connection_mode` | `"uds"` | `"uds"` (same host as the validator) or `"tcp"` (dedicated signer host). |
| `tmkms_remote_dir` | `/root/<gno_dir>/tmkms` | Directory created on this host to hold the tmkms config and secrets (+ `run/` in uds mode). |
| `tmkms_node_data_dir` | `/root/<gno_dir>/validator/gnoland-data` | **uds mode only.** Path to the validator's gnoland data dir on this same host (source of `priv_validator_key.json`). Not read in tcp mode. |
| `tmkms_node_secrets_dir` | `<tmkms_node_data_dir>/secrets` | Derived from `tmkms_node_data_dir`; where `priv_validator_key.json` lives (uds mode). |
| `tmkms_validator_peer_id` | `""` | **tcp mode, required.** Validator's hex peer-id (`gnoland secrets get`) — pins `addr` so tmkms only ever signs for this validator. |
| `tmkms_validator_ip` | `""` | **tcp mode, required.** IP of the validator host, reachable from this signer host. |
| `tmkms_validator_port` | `26659` | **tcp mode.** TCP port the validator's tmkms_listener listens on. |
| `tmkms_image` | `tmkms:local` | Docker image tag for the tmkms container. |
| `tmkms_build_image` | `true` | When `true`, build the image on this host from `files/Dockerfile`. Set to `false` to use a pre-pushed registry image. |
| `tmkms_socket_path` | `/run/gnoland/privval.sock` | **uds mode only.** Socket path shared between the tmkms and gnoland containers via a Docker volume mount. |

---

## What the role does

The role is invoked by `setup-tmkms.yml`, runs as root, **before**
`docker compose up`, and is safe to re-run at any time (all tasks are
idempotent). It never generates gnoland secrets — every check below asserts
and fails with a clear message instead.

**uds mode** (runs on the validator host):

1. **Assert** `tmkms_chain_id` is non-empty.
2. **Install `jq`** via apt (needed for the consensus key reslice step).
3. **Create directories**: `tmkms/`, `tmkms/secrets/`, `tmkms/run/` under
   `tmkms_remote_dir`, all mode `0700`.
4. **Assert node secrets exist**: fail with a clear message if
   `priv_validator_key.json` is absent — the operator runs
   `gnoland secrets init` manually first (see `DEPLOYMENT_RUNBOOK.md`).
5. **Build the tmkms image** (when `tmkms_build_image: true`): copy
   `files/Dockerfile` to the host and run `docker build`.
6. **Render `tmkms.toml`** from `templates/tmkms.toml.j2` (mode `0600`):
   `[[chain]]` with `tmkms_chain_id`, `[[providers.softsign]]` pointing at
   `secrets/consensus.key`, `[[validator]]` with `addr = "unix://<tmkms_socket_path>"`.
7. **Reslice the consensus key**: extract the 32-byte ed25519 seed from
   `priv_validator_key.json` (which stores the 64-byte seed‖pubkey in base64)
   and write it as `secrets/consensus.key` (base64, mode `0600`). This step
   uses `creates:` so an existing key is never silently overwritten — delete
   the file manually after a deliberate key rotation to force a refresh.
8. **Generate the kms-identity key**: write 32 random bytes (base64) to
   `secrets/kms-identity.key` (mode `0600`) once.

**tcp mode** (runs on the dedicated signer host — steps 1, 2, 5, 7 and 8
above are identical, except):

- step 3 (**create directories**): `tmkms/`, `tmkms/secrets/` only — no
  `run/` (no shared socket dir between two separate hosts).
- step 4 (**assert the consensus key was copied here**): fail with a clear
  message (including the exact `scp` command) if `secrets/consensus.key` is
  absent — it must be resliced on the validator host and copied over
  out-of-band, never generated on the signer host (see `tmkms-lab/README.md`
  step 2).
- step 6 (**render `tmkms.toml`**): `[[validator]]` gets
  `addr = "tcp://<tmkms_validator_peer_id>@<tmkms_validator_ip>:<tmkms_validator_port>"`
  instead of the `unix://` address.
- extra step 9 (**derive and print the kms-identity pubkey**): tcp mode only.
  Runs the same one-off Go program as `tmkms-lab/tmkms/setup-vm2-tmkms.sh`
  (kept identical on purpose) via `docker run golang:1-alpine`, read-only, to
  turn the `kms-identity.key` seed into its `ed25519:<hex>` pubkey — printed
  in the final debug message. That value goes into
  `TMKMS_ALLOWED_KMS_PUBKEYS` on the validator host.

After the role completes, `docker compose up -d` starts the tmkms sidecar —
`compose/validator-sentry-tmkms/` (uds) or `compose/tmkms-alone/` (tcp,
signer host) + `compose/validator-alone/` (tcp, validator host, with the
`TMKMS_*` env vars filled in). The validator's `entrypoint.sh` translates
those variables into the `tmkms_listener` config fields.

---

## `tmkms_enabled` switch

Setting `tmkms_enabled: false` (the default) makes the role a complete no-op:
no tasks run. Flip to `true` when invoking `setup-tmkms.yml` (directly with
`-e tmkms_enabled=true`, or via inventory host_vars) when you are ready to
use the sidecar.

---

## Notes and caveats

- **softsign = key in a file.** On cloud hosts without USB hardware tokens this
  is the only available backend. Protect the host carefully and back the key up
  out-of-band (e.g. a password manager or Vaultwarden). Never commit the key
  file.
- **Never restore a stale `consensus_state.json`**: this would allow double
  signing. The role does not back the state file up.
- **Airgapped or hardened hosts**: building the image requires internet access
  (cargo downloads crates). Prebuild the image elsewhere, push it to a
  registry, then set `tmkms_image` to that registry reference and
  `tmkms_build_image: false`.
- **Key rotation**: the consensus key reslice is idempotent. After a deliberate
  validator key rotation, remove `tmkms/secrets/consensus.key` on the host and
  re-run the role to regenerate it from the new `priv_validator_key.json`.
