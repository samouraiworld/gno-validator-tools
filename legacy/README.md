# legacy/ — history, out of active Ansible scope

This directory groups what was removed from the active Ansible flow during
the repo simplification (nginx/TLS/OAuth-proxy out of scope, Loki/Prometheus
replaced by Alloy → VictoriaMetrics in push mode, gnoland compose deployment
turned manual). Nothing is lost: everything remains browsable here and in
the git history (`git log --follow -- legacy/...`).

**These files are no longer maintained nor guaranteed to work as-is.** Some
relative paths broke during the move (e.g. the playbooks in
`legacy/playbooks/` reference templates via paths relative to their former
location at the repo root, not to `legacy/templates/`). These are frozen
references, not code meant to be replayed as-is.

## Contents

### `roles/`
- `nginx/` — generic reverse proxy (per-site vhosts).
- `nginx-prometheus/` — Prometheus exporter for NGINX (`:9113`).
- `auth2-proxy/` — OAuth2 Proxy (Google OAuth protection for dashboards).
- `generate_cert_tls/` — Let's Encrypt automation (certbot + nginx).

Removed from scope because: no reverse proxy or TLS is managed by Ansible
anymore (deliberate choice, see `NETWORK_AND_REVERSE_PROXY.md` at the repo
root — manual setup if needed). `nginx-prometheus`, `auth2-proxy` and
`generate_cert_tls` were already unused by any active playbook before this
move.

### `playbooks/`
- `2-install-sentry-node.yml`, `3-install-validator-node.yml` — automated
  (Ansible) deployment of the sentry/validator docker-compose. Replaced by
  the manual deployment described in `DEPLOYMENT_RUNBOOK.md` (the
  per-deployment files — `entrypoint.sh`, `config.toml`, `genesis.json` —
  change with every gno version and are pushed by hand, not templated by
  Ansible).
- `5-deploy-monitoring-stack.yaml` — Loki + Prometheus + Grafana stack behind
  NGINX/Let's Encrypt on a dedicated monitoring server. Depended entirely on
  `roles/nginx` + certbot, hence out of scope.
- `5b-deploy-validator-proxies.yaml` — NGINX vhosts on the sentry to relay
  the validator's metrics to Prometheus in pull mode. Obsolete: Alloy now
  pushes metrics via remote_write, no more need for a pull relay per
  validator/port.
- `6-deploy-promtail-direct.yaml`, `6-deploy-promtail-sentry.yaml` —
  Promtail deployment (direct or relayed through the sentry). Replaced by
  the `alloy` role (active, included in `base_setup.yml`), which covers both
  Docker logs and metrics.

### `templates/`
- `docker-compose.yml.j2`, `docker-sentry.yml.j2`, `docker-validator.yml.j2`,
  `docker-validator-standalone.yml.j2` — Jinja2 templates rendered by the
  playbooks above. Replaced by the static, `.env`-configurable composes in
  `compose/` at the repo root (no more Ansible rendering).
- `nginx_site.conf.j2`, `nginx_site_otel.conf.j2` — generic NGINX vhosts,
  already orphaned (not referenced by any active playbook) before this move.

### `Loki/`
Templates for the monitoring stack (Loki, Prometheus, Grafana, associated
NGINX vhosts, Promtail configs). Depended on
`5-deploy-monitoring-stack.yaml` and `roles/nginx` — see above.

### `group_vars/monitoring.yml.example`
Variables for the monitoring stack (`5-deploy-monitoring-stack.yaml`):
Loki/Prometheus/Grafana versions, domains, tokens, allowed IP lists,
Prometheus scrape jobs. No active playbook targets a `monitoring` group
anymore.

## What is NOT here

- `validator/backup.sh`, `validator/rotate.sh` and `backup-logs.yaml` remain
  **active** at the repo root: they provide cold log retention independent
  of the Alloy pipeline (different retention window) — a deliberate choice
  not to deprecate them.
- The `snapshotter` role and `install-snapshotter.yml` remain active and
  unchanged.
