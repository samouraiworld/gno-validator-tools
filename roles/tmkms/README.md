# roles/tmkms

Externalize a gnoland validator's **consensus signing** to a [tmkms] sidecar
container (softsign backend, Unix socket transport). gnoland opens a privval
listener on a Unix-domain socket (UDS); tmkms dials in and signs every block
proposal and precommit. The consensus key lives in tmkms, not in the gnoland
process.

[tmkms]: https://github.com/iqlusioninc/tmkms

> For the 2-VM TCP variant (tmkms on a separate signer host), see
> `../../tmkms-lab/`.

---

## Purpose

Running tmkms as a same-host sidecar gives two benefits over the default
in-process signing:

- The consensus key (`priv_validator_key.json`) is no longer loaded by the
  gnoland process at runtime; only the tmkms container holds the extracted
  32-byte seed.
- The signing code path is isolated to a dedicated container (tmkms v0.15.0,
  softsign feature only).

On a single host the key material is still on the same box, so this is a
defence-in-depth measure rather than full key isolation. Full isolation requires
the 2-VM TCP topology (`tmkms-lab/`).

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
| `tmkms_remote_dir` | `/root/<gno_dir>/tmkms` | Directory created on the validator host to hold the tmkms config, secrets, and socket. |
| `tmkms_node_data_dir` | `/root/<gno_dir>/gnoland-data` | Path to the gnoland data dir (source of `priv_validator_key.json`). |
| `tmkms_node_secrets_dir` | `<tmkms_node_data_dir>/secrets` | Derived from `tmkms_node_data_dir`; where `priv_validator_key.json` lives. |
| `tmkms_image` | `tmkms:local` | Docker image tag for the tmkms container. |
| `tmkms_build_image` | `true` | When `true`, build the image on the validator host from `files/Dockerfile`. Set to `false` to use a pre-pushed registry image. |
| `tmkms_socket_path` | `/run/gnoland/privval.sock` | UDS path shared between the tmkms and gnoland containers via a Docker volume mount. |

---

## What the role does

The role runs on the validator host (as root) **before** `docker compose up`,
and is safe to re-run at any time (all tasks are idempotent):

1. **Assert** `tmkms_chain_id` is non-empty.
2. **Install `jq`** via apt (needed for the consensus key reslice step).
3. **Create directories**: `tmkms/`, `tmkms/secrets/`, `tmkms/run/` under
   `tmkms_remote_dir`, all mode `0700`.
4. **Ensure node secrets exist**: if `priv_validator_key.json` is absent, run
   `gnoland secrets init` inside a temporary gnoland container to generate the
   key. The same public key must be registered in genesis.
5. **Build the tmkms image** (when `tmkms_build_image: true`): copy
   `files/Dockerfile` to the host and run `docker build`.
6. **Render `tmkms.toml`** from `templates/tmkms.toml.j2` into
   `tmkms_remote_dir/tmkms.toml` (mode `0600`). The template configures:
   - `[[chain]]` with `tmkms_chain_id`
   - `[[providers.softsign]]` pointing at `secrets/consensus.key`
   - `[[validator]]` with `addr = "unix://<tmkms_socket_path>"`
7. **Reslice the consensus key**: extract the 32-byte ed25519 seed from
   `priv_validator_key.json` (which stores the 64-byte seed‖pubkey in base64)
   and write it as `secrets/consensus.key` (base64, mode `0600`). This step
   uses `creates:` so an existing key is never silently overwritten — delete
   the file manually after a deliberate key rotation to force a refresh.
8. **Generate the kms-identity key**: write 32 random bytes (base64) to
   `secrets/kms-identity.key` (mode `0600`) once.

After the role completes, `docker compose up -d` starts the tmkms sidecar.
The compose templates (`templates/docker-validator*.yml.j2`) add the `tmkms`
service and pass `TMKMS_*` environment variables to the validator when
`tmkms_enabled: true`. The validator's `entrypoint.sh` translates those
variables into the `tmkms_listener` config fields.

---

## `tmkms_enabled` switch

Setting `tmkms_enabled: false` (the default) makes the role a complete no-op:
no tasks run and the compose templates omit the tmkms service. Flip to `true`
in `group_vars/betanet.yml` (or the host vars) when you are ready to use the
sidecar.

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
