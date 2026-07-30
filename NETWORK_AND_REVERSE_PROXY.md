# Private network & reverse proxy — manual setup

Ansible does not deploy the private VLAN beyond the network interface
itself, nor any reverse proxy, nor TLS. This document explains what's left
to do by hand, and why that choice is deliberate.

## 1. Private network (VLAN)

The `setup-private-network.yml` playbook only configures the network
interface (`/etc/network/interfaces` + `ifup`) on a given host:

```bash
ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-sentry -e vlan_id=<vlan_id>

ansible-playbook -i inventory.yaml setup-private-network.yml \
  -e target=gno-validator -e vlan_id=<vlan_id>
```

`vlan_id` is provided by the hosting provider (e.g. Scaleway Private
Networks). Run this playbook **after** confirming the nodes run correctly on
their public IP — activating the VLAN mid-deployment can cut SSH access if
misconfigured.

Once the VLAN is active, the validator can drop its public Internet access
while keeping the private VLAN operational — see `validator/Network_control.md`
(copied manually onto the validator, see `DEPLOYMENT_RUNBOOK.md`):

```bash
ssh root@<validator-ip>
ip addr flush dev eno1      # drop Internet, keep the VLAN
dhclient eno1                # re-enable Internet (useful to re-run a playbook)
```

## 2. Why no reverse proxy / TLS via Ansible

The `nginx`, `nginx-prometheus`, `auth2-proxy` and `generate_cert_tls` roles
have been removed from the active scope (moved to history under `legacy/`,
see `legacy/README.md`). This isn't an oversight: it's a deliberate choice to
keep this repo focused on the strict server foundation (`base_setup.yml`)
and the application deployment (`compose/`). Accepted consequence: **no
automated Let's Encrypt renewal for now**.

If a reverse proxy is needed (typically on the sentry, as the public
front-end), it is installed and maintained by hand by the operator — nginx,
Caddy, or anything else, your choice. Concrete use cases:

- **Exposing a dashboard or HTTPS API** in front of the sentry.
- **Relaying Alloy's push** if the validator is isolated on the private VLAN
  without direct Internet egress: the `alloy` role already natively supports
  this relay mode (`alloy_log_mode` / `alloy_remote_write_mode: "relay"`, see
  `roles/alloy/templates/config.alloy.j2` and the commented examples in
  `inventory.yaml.example`). In this mode, Alloy on the validator pushes to
  an internal URL (e.g. `http://<sentry_private_ip>/vm/...` or
  `.../loki/...`); it's this hand-configured reverse proxy on the sentry that
  then relays to the real destination (VictoriaMetrics / logs backend),
  adding a token held only by the sentry if needed — the validator never
  holds this secret.
- In `"direct"` mode, Alloy pushes straight to the final URL with its own
  token (`alloy_bearer_token`) — no reverse proxy needed on the validator
  side, but it then needs direct Internet egress.

Neither mode requires any change to the `alloy` role: both are already fully
driven by inventory variables.

## 3. Firewall (UFW)

The `ufw` role (included in `base_setup.yml`) only opens:

- the SSH port (22),
- the application ports declared in `ufw_ports_app` (typically `26656` for
  gnoland P2P),
- optionally, ports restricted to a single IP via `ufw_ports_moni` +
  `ufw_allow_ip` — a generic mechanism kept available but **empty by
  default**, since no metrics port (node_exporter, otel, nginx_exporter)
  needs to be exposed for inbound listening anymore since the switch to the
  push model (Alloy → remote_write). node_exporter and otel-collector's
  Prometheus export stay bound to `127.0.0.1`.
- optionally, the tmkms TCP signer port via `ufw_tmkms_port` +
  `ufw_tmkms_signer_ip`, restricted to the dedicated signer host's IP only
  (same pattern as above) — see `roles/tmkms` (`tmkms_connection_mode: "tcp"`)
  and `TMKMS.md` §4.

If a manual reverse proxy is set up in front of a service, it's up to the
operator to open the matching port (`ufw allow <port>` by hand, or via
`ufw_ports_app`/`ufw_ports_moni` as needed).
