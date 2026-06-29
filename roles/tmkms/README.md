# roles/tmkms

Externalize a gnoland validator's **consensus signing** to a [tmkms] sidecar
container (softsign backend). gnoland opens a privval listener; tmkms dials in
and signs. The consensus key lives in tmkms, not in the gnoland process.

[tmkms]: https://github.com/iqlusioninc/tmkms

## What it does

Run on the validator host, before `docker compose up`:

1. ensures `jq` is present (for the key reslice);
2. creates `tmkms/{secrets,run}` under the deploy dir;
3. ensures the node secrets exist (`gnoland secrets init` if missing) — the same
   key whose pubkey is registered in genesis;
4. builds the `tmkms:local` image from `files/Dockerfile` (or uses a prebuilt
   `tmkms_image`);
5. renders `tmkms.toml`;
6. provisions the **consensus.key** (reslice of `priv_validator_key.json`, or a
   controller-staged file) and a **kms-identity.key**, both `0600`.

The compose templates (`templates/docker-validator*.yml.j2`) add the `tmkms`
service and set `TMKMS_*` env on the validator when `tmkms_enabled: true`;
`validator/entrypoint.sh` turns those into the four `tmkms_listener` config
fields (with `listen_addr` last).

## Key variables

See `defaults/main.yml`. Most important:

| var | meaning |
|---|---|
| `tmkms_enabled` | master switch (compose omits tmkms when false) |
| `tmkms_transport` | `uds` (same-host sidecar) or `tcp` (separate signer host) |
| `tmkms_chain_id` | **required**, must match genesis |
| `tmkms_consensus_key_source` | `reslice` (default) or `file` |
| `tmkms_image` / `tmkms_build_image` | prebuilt image vs build on host |

## Topologies

- **UDS (default)** — tmkms colocated with the validator. Auth = socket perms.
  No real key isolation on a single host (the softsign key is still on the box),
  but the simplest working setup.
- **TCP** — run tmkms on a separate (hardened, less-exposed) host. Set
  `tmkms_transport: tcp`, `tmkms_validator_ip`, `tmkms_validator_peer_id`
  (hex peer id) and `tmkms_allowed_kms_pubkeys`. Open UFW 26659 to the signer
  host only. This is where you remove `priv_validator_key.json` from the
  validator entirely — that is the real isolation win.

## Notes / caveats

- **softsign = key in a file.** On cloud hosts (no USB) this is the only backend;
  protect the host and back the key up out-of-band (e.g. Vaultwarden), never via
  a committed file.
- **Never restore a stale `consensus_state.json`** (double-sign). The role does
  not back it up.
- **Airgapped hosts**: building the image needs internet (cargo). Prebuild and
  push to a registry, then set `tmkms_image` + `tmkms_build_image: false`.
- Consensus key reslice is idempotent (`creates:`); after a deliberate key
  rotation, remove `tmkms/secrets/consensus.key` to regenerate it.
