# Alloy + VictoriaMetrics Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `promtail` (log shipping) and the pull-based Prometheus scraping of `node_exporter`/`otel-collector`/`nginx_exporter` with Grafana Alloy (push), and replace Prometheus with VictoriaMetrics as the metrics backend — while keeping the sentry as the sole holder of push bearer tokens (same security boundary as today's Loki relay).

**Architecture:** `node_exporter`, `otel-collector`, `nginx_exporter` keep collecting metrics exactly as they do today but get rebound to `127.0.0.1` (no longer network-exposed). A new Alloy agent, installed via the official Grafana APT repo, scrapes those local endpoints and remote_writes them out, and (on the validator) tails Docker container logs and ships them to Loki — replacing promtail. The sentry gains a new `vm-proxy` NGINX vhost (mirroring the existing `loki-proxy`) that injects the VictoriaMetrics bearer token so the validator's Alloy never holds it. VictoriaMetrics replaces Prometheus in the monitoring server's Docker Compose stack, fronted by a new `vm-http` NGINX vhost (mirroring `nginx-loki-http.conf.j2`) that authenticates inbound pushes.

**Tech Stack:** Ansible (roles + playbooks), Jinja2 templates, Docker Compose, NGINX, systemd, Grafana Alloy (APT package), VictoriaMetrics (Docker image).

## Global Constraints

- Every new secret (`vm_bearer_token`) follows the existing convention: generate with `openssl rand -hex 32`, store only in `group_vars/monitoring.yml` (gitignored), document with an `ansible-vault encrypt_string` example in the `.example` file — never commit a real value.
- Roles must stay idempotent (re-running any playbook produces `changed=0` on the second run), matching the existing project convention (see `.claude/vagrant-test-plan.md` T11).
- All new Ansible files must pass `ansible-lint` with no `ERROR`-level violations before being committed, matching `.claude/vagrant-test-plan.md` T12.
- Test everything against `inventory-vagrant.yaml` (hosts `gno-validator-test` 192.168.56.10, `gno-sentry-test` 192.168.56.9, `gno-monitoring-test` 192.168.56.12) before it is considered done — this repo's established practice per `.claude/vagrant-test-plan.md`.
- Never touch `inventory.yaml` (production) in this plan — only `inventory.yaml.example`, `inventory-vagrant.yaml`, and `group_vars/*.example`.
- Follow existing template/role conventions exactly (see `Loki/templates/nginx-loki-proxy.conf.j2`, `Loki/templates/nginx-loki-http.conf.j2`, `Loki/templates/grafana-loki-datasource.yml.j2`) rather than inventing new patterns.

---

## Phase 1 — VictoriaMetrics on the monitoring server

### Task 1: Add VictoriaMetrics service to the monitoring Docker Compose stack

**Files:**
- Modify: `Loki/templates/docker-monitoring-stack.yml.j2`
- Modify: `group_vars/monitoring.yml.example`

**Interfaces:**
- Produces: a `victoriametrics` service reachable at `127.0.0.1:{{ victoriametrics_http_port | default(8428) }}` on the monitoring host, and at `http://victoriametrics:8428` from other containers in the same Compose network (consumed by Task 3's Grafana datasource).

- [ ] **Step 1: Add the service block to the compose template**

In `Loki/templates/docker-monitoring-stack.yml.j2`, add this service alongside the existing `loki`, `prometheus`, and `grafana` services (Prometheus stays untouched in this phase — it keeps running so nothing breaks):

```yaml
  victoriametrics:
    image: victoriametrics/victoria-metrics:v{{ victoriametrics_version }}
    restart: unless-stopped
    user: "0"
    ports:
      - "127.0.0.1:{{ victoriametrics_http_port | default(8428) }}:8428"
    volumes:
      - /opt/monitoring/victoriametrics/data:/storage
    command:
      - "--storageDataPath=/storage"
      - "--retentionPeriod={{ victoriametrics_retention | default('3') }}"
      - "--httpListenAddr=:8428"
```

Also add `- victoriametrics` to the existing `grafana` service's `depends_on` list (which today reads `depends_on: [loki, prometheus]`), so it becomes `[loki, prometheus, victoriametrics]`.

- [ ] **Step 2: Document the new variables in the example group_vars**

In `group_vars/monitoring.yml.example`, add a new section right after the existing `Prometheus (9-deploy-prometheus.yaml)` section:

```yaml
# =============================================================================
# VictoriaMetrics (5-deploy-monitoring-stack.yaml)
# =============================================================================

# --- VictoriaMetrics version ---------------------------------------------------
# Docker image tag. Check https://hub.docker.com/r/victoriametrics/victoria-metrics/tags
victoriametrics_version: "1.102.0"

# --- VictoriaMetrics port -------------------------------------------------------
# Listens locally only — reached by Grafana via the internal Compose network,
# and by validators/sentries via the vm-http NGINX vhost (see below).
victoriametrics_http_port: 8428

# --- Retention ------------------------------------------------------------------
# In months (VictoriaMetrics native format), e.g. "3" = 3 months.
victoriametrics_retention: "3"

# --- VictoriaMetrics domain and TLS ----------------------------------------------
# Fully qualified domain name pointing to this monitoring server.
# A Let's Encrypt certificate will be issued for this domain.
# For Vagrant testing (no real domain), set this to the VM IP and use --skip-tags tls.
victoriametrics_domain: "sentinel.example.com"
# Vagrant example (nip.io — resolves to monitoring VM IP, no DNS needed):
# victoriametrics_domain: "sentinel.192.168.56.12.nip.io"

# Scheme used by the sentry vm-proxy to push metrics to this server.
# Use "http" for Vagrant (no TLS), "https" in production (default).
victoriametrics_scheme: "https"
# Vagrant example: victoriametrics_scheme: "http"

# --- Authentication ---------------------------------------------------------------
# Bearer token used to authenticate remote_write pushes to VictoriaMetrics.
#
# WARNING: Never store this value in plaintext in a file committed to git.
# Generate a strong random token:
#   openssl rand -hex 32
#
# Then encrypt it with ansible-vault:
#   ansible-vault encrypt_string 'your-token-here' --name 'vm_bearer_token'
#
# For Vagrant testing only (never in production):
vm_bearer_token: "changeme"

# --- IP whitelist for the vm-http endpoint (monitoring server side) ---------------
# Add the PUBLIC IP of each sentry node.
vm_allowed_ips:
  - "51.159.14.234"     # gno-sentry-1 production
# Vagrant example:
# vm_allowed_ips:
#   - "192.168.56.9"    # gno-sentry Vagrant VM
```

- [ ] **Step 3: Lint the changed files**

Run: `ansible-lint Loki/templates/docker-monitoring-stack.yml.j2 || true` (Jinja templates aren't playbooks, so ansible-lint may skip it — this is a sanity check, not a hard gate for this file type). Then verify the Jinja renders with valid YAML:

```bash
python3 -c "
import jinja2, yaml
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('Loki/templates/docker-monitoring-stack.yml.j2').read())
rendered = tpl.render(loki_version='3.4.2', prometheus_version='3.1.0', grafana_admin_password='x', grafana_domain='g.example.com', victoriametrics_version='1.102.0', victoriametrics_http_port=8428, victoriametrics_retention='3')
yaml.safe_load(rendered)
print('OK')
"
```

Expected: `OK` printed, no exception.

- [ ] **Step 4: Commit**

```bash
git add Loki/templates/docker-monitoring-stack.yml.j2 group_vars/monitoring.yml.example
git commit -m "feat(monitoring): add VictoriaMetrics service to the monitoring stack"
```

---

### Task 2: Add the VictoriaMetrics NGINX vhosts (inbound push endpoint, HTTP + TLS)

**Files:**
- Create: `Loki/templates/nginx-vm-http.conf.j2`
- Create: `Loki/templates/nginx-vm-monitoring.conf.j2`

**Interfaces:**
- Consumes: `victoriametrics_domain`, `vm_allowed_ips`, `vm_bearer_token`, `victoriametrics_http_port` (from Task 1).
- Produces: two vhost templates for `victoriametrics_domain`, mirroring exactly how Loki does it — an HTTP-only vhost used both for Vagrant and for the initial certbot HTTP-01 challenge, and a TLS vhost deployed once the certificate exists (consumed by Task 4).

Loki uses this exact two-template pattern (`nginx-loki-http.conf.j2` then `nginx-loki-monitoring.conf.j2` after certbot runs) — read both files before starting, they're the template for this task.

- [ ] **Step 1: Write the HTTP-only template**

Model it exactly on `Loki/templates/nginx-loki-http.conf.j2`:

```nginx
server {
    listen 80;
    server_name {{ victoriametrics_domain }};

    location / {
        # IP whitelist — only sentry nodes are allowed to push metrics
{% for ip in vm_allowed_ips %}
        allow {{ ip }};
{% endfor %}
        deny all;

        # Bearer token authentication
        if ($http_authorization != "Bearer {{ vm_bearer_token }}") {
            return 403;
        }

        proxy_pass http://127.0.0.1:{{ victoriametrics_http_port | default(8428) }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 300s;
    }
}
```

- [ ] **Step 2: Write the TLS template**

Model it exactly on `Loki/templates/nginx-loki-monitoring.conf.j2`:

```nginx
server {
    server_name {{ victoriametrics_domain }};

    location / {
        # IP whitelist — only sentry nodes are allowed to push metrics
{% for ip in vm_allowed_ips %}
        allow {{ ip }};
{% endfor %}
        deny all;

        # Bearer token authentication
        if ($http_authorization != "Bearer {{ vm_bearer_token }}") {
            return 403;
        }

        proxy_pass http://127.0.0.1:{{ victoriametrics_http_port | default(8428) }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 300s;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/{{ victoriametrics_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ victoriametrics_domain }}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if ($host = {{ victoriametrics_domain }}) {
        return 301 https://$host$request_uri;
    }

    listen 80;
    server_name {{ victoriametrics_domain }};
    return 404;
}
```

- [ ] **Step 3: Verify the Jinja syntax of both templates**

```bash
python3 -c "
import jinja2
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
for f in ['Loki/templates/nginx-vm-http.conf.j2', 'Loki/templates/nginx-vm-monitoring.conf.j2']:
    tpl = env.from_string(open(f).read())
    print(tpl.render(victoriametrics_domain='sentinel.example.com', vm_allowed_ips=['1.2.3.4'], vm_bearer_token='x', victoriametrics_http_port=8428))
"
```

Expected: valid NGINX config printed for both files, no exception.

- [ ] **Step 4: Commit**

```bash
git add Loki/templates/nginx-vm-http.conf.j2 Loki/templates/nginx-vm-monitoring.conf.j2
git commit -m "feat(monitoring): add VictoriaMetrics NGINX vhosts (HTTP + TLS) for push ingestion"
```

---

### Task 3: Add the Grafana VictoriaMetrics datasource

**Files:**
- Create: `Loki/templates/grafana-victoriametrics-datasource.yml.j2`

**Interfaces:**
- Consumes: `victoriametrics_http_port` (from Task 1).
- Produces: a Grafana provisioning file at `/opt/monitoring/grafana/provisioning/datasources/victoriametrics.yml` (wired up in Task 4).

- [ ] **Step 1: Write the template**

Model it on `Loki/templates/grafana-prometheus-datasource.yml.j2`, but point at the `victoriametrics` Compose service name (VictoriaMetrics exposes a Prometheus/MetricsQL-compatible query API, so the `prometheus` datasource type works unchanged):

```yaml
apiVersion: 1

datasources:
  - name: VictoriaMetrics
    type: prometheus
    access: proxy
    url: http://victoriametrics:{{ victoriametrics_http_port | default(8428) }}
    isDefault: false
    editable: false
```

- [ ] **Step 2: Commit**

```bash
git add Loki/templates/grafana-victoriametrics-datasource.yml.j2
git commit -m "feat(monitoring): add Grafana datasource for VictoriaMetrics"
```

---

### Task 4: Wire VictoriaMetrics into the monitoring deployment playbook

**Files:**
- Modify: `5-deploy-monitoring-stack.yaml`

**Interfaces:**
- Consumes: templates from Tasks 1-3.
- Produces: a working `victoriametrics` container + HTTP/TLS vhosts + Grafana datasource, deployable with `ansible-playbook -i inventory.yaml 5-deploy-monitoring-stack.yaml`.

This file's PLAY 1 already deploys Loki and Grafana this same way — an HTTP-only vhost first (works for Vagrant and for the certbot HTTP-01 challenge), then a certbot request, then the TLS vhost overwrite, all gated behind the `[tls]` tag so `--skip-tags tls` (the documented Vagrant invocation) stops after the HTTP vhost. Mirror that exact sequence for VictoriaMetrics.

- [ ] **Step 1: Add the storage directory**

Find the existing `Create monitoring stack directories` task and add `/opt/monitoring/victoriametrics/data` to its loop, alongside `/opt/monitoring/prometheus/data` etc.

- [ ] **Step 2: Deploy the Grafana datasource**

Add, next to the existing `Deploy Grafana Prometheus datasource provisioning` task:

```yaml
    - name: Deploy Grafana VictoriaMetrics datasource provisioning
      ansible.builtin.template:
        src: Loki/templates/grafana-victoriametrics-datasource.yml.j2
        dest: /opt/monitoring/grafana/provisioning/datasources/victoriametrics.yml
        mode: "0644"
      notify: Restart stack
      tags: [stack, config]
```

- [ ] **Step 3: Deploy the HTTP-only vhost**

Add, next to the existing `Deploy Loki NGINX vhost (HTTP)` / `Enable Loki NGINX vhost` pair, using the same `dest: /etc/nginx/sites-available/{{ <domain> }}` filename convention (not a fixed name — this lets the later TLS step overwrite the same file in place, exactly like Loki does):

```yaml
    - name: Deploy VictoriaMetrics NGINX vhost (HTTP)
      ansible.builtin.template:
        src: Loki/templates/nginx-vm-http.conf.j2
        dest: /etc/nginx/sites-available/{{ victoriametrics_domain }}
        mode: "0644"
      notify: Reload nginx
      tags: [victoriametrics]

    - name: Enable VictoriaMetrics NGINX vhost
      ansible.builtin.file:
        src: /etc/nginx/sites-available/{{ victoriametrics_domain }}
        dest: /etc/nginx/sites-enabled/{{ victoriametrics_domain }}
        state: link
        force: true
      notify: Reload nginx
      tags: [victoriametrics]
```

- [ ] **Step 4: Add the Let's Encrypt certificate + TLS vhost**

Add, next to the existing `Check if Loki TLS certificate exists` / `Request Let's Encrypt certificate for Loki` / `Deploy Loki NGINX vhost with TLS` block, same `[tls]` tag:

```yaml
    - name: Check if VictoriaMetrics TLS certificate exists
      ansible.builtin.stat:
        path: /etc/letsencrypt/live/{{ victoriametrics_domain }}/fullchain.pem
      register: vm_cert_stat
      tags: [tls]

    - name: Request Let's Encrypt certificate for VictoriaMetrics
      ansible.builtin.command:
        cmd: >
          certbot certonly --nginx
          -d {{ victoriametrics_domain }}
          --non-interactive
          --agree-tos
          --email {{ letsencrypt_email }}
      when: not vm_cert_stat.stat.exists
      tags: [tls]

    - name: Deploy VictoriaMetrics NGINX vhost with TLS
      ansible.builtin.template:
        src: Loki/templates/nginx-vm-monitoring.conf.j2
        dest: /etc/nginx/sites-available/{{ victoriametrics_domain }}
        mode: "0644"
      notify: Reload nginx
      tags: [tls]
```

These fall naturally inside the same `Validate NGINX configuration (TLS vhosts)` / `Force NGINX reload with TLS vhosts` handler-flush pair that already closes out PLAY 1 — no new validation tasks needed.

- [ ] **Step 5: Run ansible-lint**

```bash
ansible-lint 5-deploy-monitoring-stack.yaml
```

Expected: no `ERROR`-level violations.

- [ ] **Step 6: Commit**

```bash
git add 5-deploy-monitoring-stack.yaml
git commit -m "feat(monitoring): deploy VictoriaMetrics alongside Prometheus"
```

---

### Task 5: Verify VictoriaMetrics end-to-end on Vagrant

**Files:** none (verification only)

- [ ] **Step 1: Bring up the monitoring VM**

```bash
cd vagrant && vagrant up monitoring
```

- [ ] **Step 2: Deploy the stack**

```bash
ansible-playbook -i inventory-vagrant.yaml 5-deploy-monitoring-stack.yaml \
  -e target=gno-monitoring-test \
  -e @group_vars/monitoring.yml \
  --skip-tags tls
```

(Use a copy of `group_vars/monitoring.yml.example` with `victoriametrics_domain: "sentinel.192.168.56.12.nip.io"` and `victoriametrics_scheme: "http"` for this run.)

Expected: `failed=0`.

- [ ] **Step 3: Verify the container is up**

```bash
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "docker ps --filter name=victoriametrics --format '{{.Names}}\t{{.Status}}'"
```

Expected: one line, status `Up`.

- [ ] **Step 4: Verify the vm-http vhost rejects unauthenticated pushes**

```bash
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "curl -s -o /dev/null -w '%{http_code}' -H 'Host: sentinel.192.168.56.12.nip.io' http://127.0.0.1/api/v1/write"
```

Expected: `403`.

- [ ] **Step 5: Verify an authenticated push lands and is queryable**

```bash
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 "
  curl -s -X POST -H 'Host: sentinel.192.168.56.12.nip.io' \
    -H 'Authorization: Bearer changeme' \
    'http://127.0.0.1/api/v1/import/prometheus' \
    --data-binary 'test_metric_plan_task5 42'
  sleep 1
  curl -s 'http://127.0.0.1:8428/api/v1/query?query=test_metric_plan_task5' | grep -o '42'
"
```

Expected: `42` printed (the metric round-tripped through the vhost into VictoriaMetrics).

- [ ] **Step 6: No commit needed** — this task is verification-only. If any step fails, fix the underlying template/task from Tasks 1-4 and re-run this task before continuing.

---

## Phase 2 — Sentry push relay

### Task 6: Add the vm-proxy NGINX vhost on the sentry

**Files:**
- Create: `Loki/templates/nginx-vm-proxy.conf.j2`

**Interfaces:**
- Consumes: `vm_validator_ips`, `victoriametrics_scheme`, `victoriametrics_domain`, `vm_bearer_token`, `vm_proxy_port` (new inventory vars, defined in Task 7).
- Produces: a dedicated NGINX server block listening on `vm_proxy_port` (default `8429`) that validators' Alloy (Task 11) points its `remote_write` at.

- [ ] **Step 1: Write the template**

`vm-proxy` gets its own port rather than sharing port 80 with `loki-proxy`, because NGINX only allows one `default_server` per port and `loki-proxy` already claims `80 default_server`:

```nginx
server {
    listen {{ vm_proxy_port | default(8429) }};
    server_name _;

    location / {
        # Allow only validator nodes (private VLAN IPs)
{% for ip in vm_validator_ips %}
        allow {{ ip }};
{% endfor %}
        deny all;

        # Forward to VictoriaMetrics on monitoring server, inject Bearer token
        proxy_pass {{ victoriametrics_scheme | default('https') }}://{{ victoriametrics_domain }};
        proxy_set_header Host {{ victoriametrics_domain }};
        proxy_set_header Authorization "Bearer {{ vm_bearer_token }}";

        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }
}
```

- [ ] **Step 2: Verify the Jinja syntax**

```bash
python3 -c "
import jinja2
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('Loki/templates/nginx-vm-proxy.conf.j2').read())
print(tpl.render(vm_validator_ips=['172.16.12.2'], victoriametrics_scheme='https', victoriametrics_domain='sentinel.example.com', vm_bearer_token='x', vm_proxy_port=8429))
"
```

Expected: valid NGINX config, no exception.

- [ ] **Step 3: Commit**

```bash
git add Loki/templates/nginx-vm-proxy.conf.j2
git commit -m "feat(sentry): add vm-proxy NGINX vhost to relay validator metrics pushes"
```

---

### Task 7: Deploy the vm-proxy vhost and UFW rule on the sentry

**Files:**
- Modify: `5-deploy-monitoring-stack.yaml`
- Modify: `inventory.yaml.example` (add `vm_validator_ips` and `vm_proxy_port` under the `gno-sentry` host)

**Interfaces:**
- Consumes: `Loki/templates/nginx-vm-proxy.conf.j2` (Task 6).
- Produces: `vm-proxy` listening on the sentry, reachable from `vm_validator_ips` only — the endpoint Alloy's relay mode will push to (Task 11).

`5-deploy-monitoring-stack.yaml` already has **PLAY 2 — "loki-proxy relay on sentry"** at the bottom of the file, targeting `hosts: gno-sentry`, deploying `Loki/templates/nginx-loki-proxy.conf.j2` to `/etc/nginx/sites-available/loki-proxy`, tagged `[proxy]`. Add a **PLAY 3** right after it, following the exact same shape (not a new playbook file — `5b-deploy-validator-proxies.yaml` is a different, older mechanism being retired in Phase 4, don't confuse the two).

- [ ] **Step 1: Add PLAY 3 to `5-deploy-monitoring-stack.yaml`**

Append after PLAY 2:

```yaml
# ---------------------------------------------------------------------------
# PLAY 3 — vm-proxy relay on sentry
# ---------------------------------------------------------------------------
- name: Deploy vm-proxy on sentry
  hosts: gno-sentry
  become: false

  handlers:
    - name: Reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded

  tasks:
    - name: Deploy vm-proxy NGINX vhost
      ansible.builtin.template:
        src: Loki/templates/nginx-vm-proxy.conf.j2
        dest: /etc/nginx/sites-available/vm-proxy
        mode: "0644"
      notify: Reload nginx
      tags: [proxy]

    - name: Enable vm-proxy NGINX vhost
      ansible.builtin.file:
        src: /etc/nginx/sites-available/vm-proxy
        dest: /etc/nginx/sites-enabled/vm-proxy
        state: link
        force: true
      notify: Reload nginx
      tags: [proxy]

    - name: Validate NGINX configuration
      ansible.builtin.command: nginx -t
      changed_when: false
      tags: [proxy]

    - name: Force NGINX reload
      ansible.builtin.meta: flush_handlers
      tags: [proxy]

    - name: Allow vm-proxy port from validator nodes
      community.general.ufw:
        rule: allow
        from_ip: "{{ item }}"
        to_port: "{{ vm_proxy_port | default(8429) | string }}"
        proto: tcp
      loop: "{{ vm_validator_ips }}"
      tags: [ufw]
```

- [ ] **Step 2: Document the new inventory vars**

In `inventory.yaml.example`, under the `sentries.hosts.gno-sentry` block, add next to `validator_proxies`:

```yaml
          # Validator private IPs allowed to push metrics through vm-proxy.
          # UFW rules managed by 5-deploy-monitoring-stack.yaml (PLAY 3).
          vm_validator_ips:
            - <VALIDATOR_PRIVATE_IP>
          vm_proxy_port: 8429
```

- [ ] **Step 3: Run ansible-lint**

```bash
ansible-lint 5-deploy-monitoring-stack.yaml
```

Expected: no `ERROR`-level violations.

- [ ] **Step 4: Commit**

```bash
git add 5-deploy-monitoring-stack.yaml inventory.yaml.example
git commit -m "feat(sentry): add vm-proxy relay play and inventory vars"
```

---

### Task 8: Verify the vm-proxy relay end-to-end on Vagrant

**Files:** none (verification only)

- [ ] **Step 1: Bring up the sentry VM**

```bash
cd vagrant && vagrant up sentry
```

- [ ] **Step 2: Deploy vm-proxy**

`5-deploy-monitoring-stack.yaml` contains three plays (PLAY 1 targets `monitoring`, PLAY 2 and PLAY 3 target `gno-sentry`) — `--limit gno-sentry-test` skips PLAY 1 automatically and runs only the sentry-side relays:

```bash
ansible-playbook -i inventory-vagrant.yaml 5-deploy-monitoring-stack.yaml \
  -e vm_validator_ips='["192.168.56.10"]' \
  -e vm_proxy_port=8429 \
  -e victoriametrics_domain=sentinel.192.168.56.12.nip.io \
  -e victoriametrics_scheme=http \
  -e vm_bearer_token=changeme \
  --limit gno-sentry-test \
  --tags proxy,ufw
```

Expected: `failed=0`.

- [ ] **Step 3: Push a test metric through the relay from the sentry itself**

```bash
ssh -i vagrant/.vagrant/machines/sentry/virtualbox/private_key root@192.168.56.9 "
  curl -s -X POST 'http://127.0.0.1:8429/api/v1/import/prometheus' \
    --data-binary 'test_metric_plan_task8 99'
"
```

Expected: empty response body, HTTP 204 (VictoriaMetrics import default success).

- [ ] **Step 4: Confirm it landed in VictoriaMetrics**

```bash
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "curl -s 'http://127.0.0.1:8428/api/v1/query?query=test_metric_plan_task8' | grep -o '99'"
```

Expected: `99` printed.

- [ ] **Step 5: Confirm the allowlist blocks other IPs**

From the monitoring VM (an IP not in `vm_validator_ips`):

```bash
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "curl -s -o /dev/null -w '%{http_code}' http://192.168.56.9:8429/api/v1/write"
```

Expected: connection refused or `403` (NGINX `deny all`).

- [ ] **Step 6: No commit needed** — verification only.

---

## Phase 3 — Alloy role

### Task 9: Scaffold the `roles/alloy` role and its APT-based install

**Files:**
- Create: `roles/alloy/tasks/main.yml`
- Create: `roles/alloy/handlers/main.yml`
- Create: `roles/alloy/defaults/main.yml`
- Create: `roles/alloy/meta/main.yml`

**Interfaces:**
- Produces: an `alloy` systemd service, installed and enabled, ready for Task 10 to template its config.

- [ ] **Step 1: Write `defaults/main.yml`**

```yaml
---
# defaults file for roles/alloy
alloy_version: "1.6.1"
alloy_logs_enabled: false
alloy_metrics_targets: []
alloy_environment: "prod"
```

- [ ] **Step 2: Write `meta/main.yml`**

```yaml
---
galaxy_info:
  description: Installs and configures Grafana Alloy for metrics scraping and log shipping
  author: gno-validator-tools
  min_ansible_version: "2.15"
dependencies: []
```

- [ ] **Step 3: Write `tasks/main.yml`**

```yaml
---
# tasks file for roles/alloy
- name: Install prerequisites for Grafana APT repo
  ansible.builtin.apt:
    name:
      - apt-transport-https
      - software-properties-common
      - gpg
    state: present
    update_cache: true

- name: Create APT keyrings directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Download Grafana APT GPG key
  ansible.builtin.get_url:
    url: https://apt.grafana.com/gpg.key
    dest: /etc/apt/keyrings/grafana.asc
    mode: "0644"

- name: Add Grafana APT repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main"
    filename: grafana
    state: present

- name: Install Alloy package
  ansible.builtin.apt:
    name: "alloy={{ alloy_version }}*"
    state: present
    update_cache: true

- name: Deploy Alloy configuration
  ansible.builtin.template:
    src: config.alloy.j2
    dest: /etc/alloy/config.alloy
    owner: root
    group: root
    mode: "0640"
  notify: Restart alloy

- name: Enable and start Alloy service
  ansible.builtin.systemd:
    name: alloy
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 4: Write `handlers/main.yml`**

```yaml
---
- name: Restart alloy
  ansible.builtin.systemd:
    name: alloy
    state: restarted
```

- [ ] **Step 5: Commit**

(No template exists yet — Task 10 adds it. This step alone won't run cleanly end-to-end, so just verify syntax.)

```bash
ansible-lint roles/alloy/tasks/main.yml roles/alloy/handlers/main.yml
```

Expected: no `ERROR`-level violations (a missing template warning is expected and fixed in Task 10).

```bash
git add roles/alloy/tasks/main.yml roles/alloy/handlers/main.yml roles/alloy/defaults/main.yml roles/alloy/meta/main.yml
git commit -m "feat(alloy): scaffold roles/alloy with APT-based install"
```

---

### Task 10: Write the Alloy config template — logs pipeline

**Files:**
- Create: `roles/alloy/templates/config.alloy.j2`

**Interfaces:**
- Consumes: `alloy_logs_enabled`, `alloy_log_mode`, `alloy_containers_filter`, `alloy_job_name`, `alloy_logs_remote_write_url`, `alloy_bearer_token` (new host vars, defined in Task 13).
- Produces: `/etc/alloy/config.alloy` (deployed by Task 9's role tasks), reproducing the logs pipeline already proven on `gno-test14`.

- [ ] **Step 1: Write the template's logs section**

```jinja
logging {
  level = "warn"
}

{% if alloy_logs_enabled %}
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "docker_logs" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }

  rule {
    source_labels = ["container"]
    regex         = "{{ alloy_containers_filter }}"
    action        = "keep"
  }

  rule {
    target_label = "job"
    replacement  = "{{ alloy_job_name }}"
  }

  rule {
    target_label = "instance"
    replacement  = "{{ inventory_hostname }}"
  }
}

loki.source.docker "docker" {
  host             = "unix:///var/run/docker.sock"
  targets          = discovery.relabel.docker_logs.output
  forward_to       = [loki.write.default.receiver]
  refresh_interval = "5s"
}

loki.write "default" {
  endpoint {
    url = "{{ alloy_logs_remote_write_url }}"
{% if alloy_log_mode == "direct" %}
    headers = {
      "Authorization" = "Bearer {{ alloy_bearer_token }}",
    }
{% endif %}
  }
}
{% endif %}
```

- [ ] **Step 2: Verify it renders for the direct-mode devnet case (gno-test14-equivalent)**

```bash
python3 -c "
import jinja2
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('roles/alloy/templates/config.alloy.j2').read())
print(tpl.render(
  alloy_logs_enabled=True, alloy_log_mode='direct',
  alloy_containers_filter='topaz-validator-1|topaz-sentry-1|topaz-tmkms-1',
  alloy_job_name='samourai-crew-1-topaz',
  alloy_logs_remote_write_url='https://mirador.samourai.live/loki/api/v1/push',
  alloy_bearer_token='xyz', inventory_hostname='gno-test14',
  alloy_metrics_targets=[]
))
"
```

Expected: output structurally matches the proven `discovery.docker`/`discovery.relabel`/`loki.source.docker`/`loki.write` blocks already running on gno-test14, no exception.

- [ ] **Step 3: Commit**

```bash
git add roles/alloy/templates/config.alloy.j2
git commit -m "feat(alloy): template the Docker logs pipeline"
```

---

### Task 11: Extend the Alloy config template — metrics pipeline

**Files:**
- Modify: `roles/alloy/templates/config.alloy.j2`

**Interfaces:**
- Consumes: `alloy_metrics_targets` (list of `{job, service, address}` dicts), `alloy_remote_write_mode`, `alloy_remote_write_url`, `alloy_bearer_token`, `alloy_environment` (new host vars, defined in Task 13).
- Produces: the `prometheus.scrape` + `prometheus.remote_write` blocks appended to the same config file.

- [ ] **Step 1: Append the metrics section to the template**

Add this block at the end of `roles/alloy/templates/config.alloy.j2`, after the logs section from Task 10:

```jinja
{% if alloy_metrics_targets | length > 0 %}
prometheus.scrape "local" {
  targets = [
{% for t in alloy_metrics_targets %}
    {
      job           = "{{ t.job }}",
      service       = "{{ t.service }}",
      environment   = "{{ alloy_environment | default('prod') }}",
      instance      = "{{ inventory_hostname }}",
      "__address__" = "{{ t.address }}",
    },
{% endfor %}
  ]

  forward_to = [prometheus.remote_write.default.receiver]
}

prometheus.remote_write "default" {
  endpoint {
    url = "{{ alloy_remote_write_url }}"
{% if alloy_remote_write_mode == "direct" %}
    headers = {
      "Authorization" = "Bearer {{ alloy_bearer_token }}",
    }
{% endif %}
  }
}
{% endif %}
```

- [ ] **Step 2: Verify it renders for the sentry case (direct remote_write, own token)**

```bash
python3 -c "
import jinja2
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('roles/alloy/templates/config.alloy.j2').read())
print(tpl.render(
  alloy_logs_enabled=False, alloy_log_mode='direct',
  alloy_containers_filter='', alloy_job_name='', alloy_logs_remote_write_url='',
  alloy_metrics_targets=[
    {'job': 'gno-sentry', 'service': 'node_exporter', 'address': '127.0.0.1:9100'},
    {'job': 'gno-sentry', 'service': 'nginx_exporter', 'address': '127.0.0.1:9113'},
  ],
  alloy_remote_write_mode='direct',
  alloy_remote_write_url='https://sentinel.samourai.live/api/v1/write',
  alloy_bearer_token='xyz', alloy_environment='prod',
  inventory_hostname='gno-sentry'
))
"
```

Expected: valid Alloy config with both `prometheus.scrape` targets and no logs block, no exception.

- [ ] **Step 3: Verify it renders for the validator case (relay mode, no token)**

```bash
python3 -c "
import jinja2
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('roles/alloy/templates/config.alloy.j2').read())
print(tpl.render(
  alloy_logs_enabled=True, alloy_log_mode='relay',
  alloy_containers_filter='samourai-crew-1', alloy_job_name='samourai-crew-1',
  alloy_logs_remote_write_url='http://172.16.12.1/loki/api/v1/push',
  alloy_metrics_targets=[
    {'job': 'samourai-crew-1', 'service': 'node_exporter', 'address': '127.0.0.1:9100'},
    {'job': 'samourai-crew-1', 'service': 'otel', 'address': '127.0.0.1:9464'},
  ],
  alloy_remote_write_mode='relay',
  alloy_remote_write_url='http://172.16.12.1:8429/api/v1/write',
  alloy_bearer_token='', alloy_environment='prod',
  inventory_hostname='gno-validator-1'
))
"
```

Expected: valid Alloy config, no `Authorization` header in either the `loki.write` or `prometheus.remote_write` blocks (relay mode carries no token on the validator).

- [ ] **Step 4: Commit**

```bash
git add roles/alloy/templates/config.alloy.j2
git commit -m "feat(alloy): template the local metrics scrape + remote_write pipeline"
```

---

### Task 12: Rebind node_exporter, nginx_exporter, and otel-collector to localhost

**Files:**
- Modify: `roles/node_exporter/files/node_exporter.service`
- Modify: `roles/nginx-prometheus/files/nginx_exporter.service`
- Modify: `validator/otel/otel-config.yaml`

**Interfaces:**
- Produces: three exporters no longer reachable over the network — only Alloy's local `prometheus.scrape` (Task 11) can reach them.

- [ ] **Step 1: Rebind node_exporter**

In `roles/node_exporter/files/node_exporter.service`, change:

```
ExecStart=/opt/node_exporter/node_exporter  \
--collector.cpu \
--collector.meminfo \
--collector.loadavg \
--collector.filesystem
```

to:

```
ExecStart=/opt/node_exporter/node_exporter  \
--collector.cpu \
--collector.meminfo \
--collector.loadavg \
--collector.filesystem \
--web.listen-address=127.0.0.1:9100
```

- [ ] **Step 2: Rebind nginx_exporter**

In `roles/nginx-prometheus/files/nginx_exporter.service`, change:

```
--web.listen-address=:9113
```

to:

```
--web.listen-address=127.0.0.1:9113
```

- [ ] **Step 3: Rebind otel-collector's Prometheus exporter**

In `validator/otel/otel-config.yaml`, change:

```yaml
exporters:
  prometheus:
    endpoint: "0.0.0.0:9464"
```

to:

```yaml
exporters:
  prometheus:
    endpoint: "127.0.0.1:9464"
```

- [ ] **Step 4: Commit**

```bash
git add roles/node_exporter/files/node_exporter.service roles/nginx-prometheus/files/nginx_exporter.service validator/otel/otel-config.yaml
git commit -m "fix(exporters): bind node_exporter, nginx_exporter, otel to localhost only"
```

---

### Task 13: Wire the alloy role into base setup and define per-host variables

**Files:**
- Modify: `1-base_setup.yml`
- Modify: `inventory.yaml.example`

**Interfaces:**
- Consumes: `roles/alloy` (Tasks 9-11), rebound exporters (Task 12).
- Produces: `alloy` deployed as part of the standard base-setup workflow, with validator and sentry each getting their own mode (`relay` vs `direct`).

- [ ] **Step 1: Add the alloy role to base setup**

In `1-base_setup.yml`, add `alloy` to the `roles:` list, after `node_exporter`:

```yaml
  roles:
    - base_setup
    - node_exporter
    - alloy
    - docker
    - ufw
    - gnoland
    - role: nginx
      when: install_nginx | default(false) | bool
```

- [ ] **Step 2: Define validator host vars in `inventory.yaml.example`**

Under `validators.hosts.gno-validator`, add:

```yaml
          # --- Alloy (replaces promtail + node_exporter/otel network exposure) ---
          alloy_logs_enabled: true
          alloy_log_mode: "relay"
          alloy_containers_filter: "<VALIDATOR_MONIKER>"
          alloy_job_name: "<VALIDATOR_MONIKER>"
          alloy_logs_remote_write_url: "http://<SENTRY_PRIVATE_IP>/loki/api/v1/push"
          alloy_remote_write_mode: "relay"
          alloy_remote_write_url: "http://<SENTRY_PRIVATE_IP>:8429/api/v1/write"
          alloy_metrics_targets:
            - { job: "<VALIDATOR_MONIKER>", service: "node_exporter", address: "127.0.0.1:9100" }
            - { job: "<VALIDATOR_MONIKER>", service: "otel", address: "127.0.0.1:9464" }
```

- [ ] **Step 3: Define sentry host vars in `inventory.yaml.example`**

Under `sentries.hosts.gno-sentry`, add:

```yaml
          # --- Alloy (direct mode — sentry holds the VictoriaMetrics token) ------
          alloy_logs_enabled: false
          alloy_remote_write_mode: "direct"
          alloy_remote_write_url: "https://<VICTORIAMETRICS_DOMAIN>/api/v1/write"
          alloy_bearer_token: "<VM_BEARER_TOKEN>"
          alloy_metrics_targets:
            - { job: "gno-sentry", service: "node_exporter", address: "127.0.0.1:9100" }
            - { job: "gno-sentry", service: "nginx_exporter", address: "127.0.0.1:9113" }
```

- [ ] **Step 4: Run ansible-lint**

```bash
ansible-lint 1-base_setup.yml
```

Expected: no `ERROR`-level violations.

- [ ] **Step 5: Commit**

```bash
git add 1-base_setup.yml inventory.yaml.example
git commit -m "feat(alloy): wire alloy role into base setup with per-host variables"
```

---

### Task 14: Verify the Alloy role end-to-end on Vagrant

**Files:** none (verification only)

- [ ] **Step 1: Bring up validator and sentry VMs**

```bash
cd vagrant && vagrant up validator sentry
```

- [ ] **Step 2: Run base setup on the sentry (direct mode)**

```bash
ansible-playbook -i inventory-vagrant.yaml 1-base_setup.yml \
  -e target=gno-sentry-test \
  -e install_nginx=true \
  -e alloy_logs_enabled=false \
  -e alloy_remote_write_mode=direct \
  -e alloy_remote_write_url=http://192.168.56.12/api/v1/write \
  -e alloy_bearer_token=changeme \
  -e 'alloy_metrics_targets=[{"job":"gno-sentry-test","service":"node_exporter","address":"127.0.0.1:9100"},{"job":"gno-sentry-test","service":"nginx_exporter","address":"127.0.0.1:9113"}]' \
  --limit gno-sentry-test
```

Expected: `failed=0`.

- [ ] **Step 3: Verify node_exporter is no longer network-reachable but Alloy is scraping it**

```bash
ssh -i vagrant/.vagrant/machines/sentry/virtualbox/private_key root@192.168.56.9 "
  systemctl is-active alloy
  curl -s -o /dev/null -w 'node_exporter local: %{http_code}\n' http://127.0.0.1:9100/metrics
  systemctl status alloy --no-pager | grep -i 'active'
"
```

Expected: `active`, `node_exporter local: 200`.

- [ ] **Step 4: Confirm the sentry's metrics reach VictoriaMetrics (requires Phase 1's monitoring VM up)**

```bash
sleep 20
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "curl -s 'http://127.0.0.1:8428/api/v1/query?query=up{job=\"gno-sentry-test\"}' | grep -o 'gno-sentry-test'"
```

Expected: `gno-sentry-test` printed (Alloy's remote_write reached VictoriaMetrics directly).

- [ ] **Step 5: Run base setup on the validator (relay mode)**

```bash
ansible-playbook -i inventory-vagrant.yaml 1-base_setup.yml \
  -e target=gno-validator-test \
  -e alloy_logs_enabled=true \
  -e alloy_log_mode=relay \
  -e alloy_containers_filter=betanet-validator \
  -e alloy_job_name=betanet-validator-1 \
  -e alloy_logs_remote_write_url=http://192.168.56.9/loki/api/v1/push \
  -e alloy_remote_write_mode=relay \
  -e alloy_remote_write_url=http://192.168.56.9:8429/api/v1/write \
  -e 'alloy_metrics_targets=[{"job":"betanet-validator-1","service":"node_exporter","address":"127.0.0.1:9100"},{"job":"betanet-validator-1","service":"otel","address":"127.0.0.1:9464"}]' \
  --limit gno-validator-test
```

Expected: `failed=0`.

- [ ] **Step 6: Confirm the validator's metrics reach VictoriaMetrics via the sentry relay**

```bash
sleep 20
ssh -i vagrant/.vagrant/machines/monitoring/virtualbox/private_key root@192.168.56.12 \
  "curl -s 'http://127.0.0.1:8428/api/v1/query?query=up{job=\"betanet-validator-1\"}' | grep -o 'betanet-validator-1'"
```

Expected: `betanet-validator-1` printed.

- [ ] **Step 7: Idempotency check**

```bash
ansible-playbook -i inventory-vagrant.yaml 1-base_setup.yml \
  -e target=gno-sentry-test -e install_nginx=true \
  -e alloy_remote_write_mode=direct -e alloy_remote_write_url=http://192.168.56.12/api/v1/write \
  -e alloy_bearer_token=changeme \
  -e 'alloy_metrics_targets=[{"job":"gno-sentry-test","service":"node_exporter","address":"127.0.0.1:9100"}]' \
  --limit gno-sentry-test
```

Expected: `changed=0` for the `alloy` role's tasks (config template unchanged, service already started).

- [ ] **Step 8: No commit needed** — verification only. If any step fails, fix the underlying role/template from Tasks 9-13 and re-run.

---

## Phase 4 — Cutover and cleanup

> Run this phase only after Tasks 1-14 are verified end-to-end and the team has confirmed real production dashboards look correct against VictoriaMetrics/Alloy running in parallel with the old pipeline for a reasonable observation window.

### Task 15: Retire promtail

**Files:**
- Delete: `6-deploy-promtail-direct.yaml`
- Delete: `6-deploy-promtail-sentry.yaml`
- Delete: `Loki/templates/promtail-config-direct.yml.j2`
- Delete: `Loki/templates/promtail-config.yml.j2`

- [ ] **Step 1: Confirm promtail is no longer referenced**

```bash
grep -rl "promtail" --include="*.yaml" --include="*.yml" --include="*.j2" . | grep -v "\.git/"
```

Expected: no results (only historical references in the deleted files themselves, which is fine since they're being removed).

- [ ] **Step 2: Delete the files**

```bash
git rm 6-deploy-promtail-direct.yaml 6-deploy-promtail-sentry.yaml Loki/templates/promtail-config-direct.yml.j2 Loki/templates/promtail-config.yml.j2
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(monitoring): remove promtail playbooks and configs, superseded by Alloy"
```

(On already-running production nodes, stop/disable/purge the promtail systemd service and `/opt/promtail` binary manually as part of the ops cutover — this is a one-time manual step per node, not something a deleted playbook can automate.)

---

### Task 16: Retire the pull-based Prometheus proxy and Prometheus itself

**Files:**
- Delete: `5b-deploy-validator-proxies.yaml`
- Delete: `Loki/templates/nginx-validator-proxy.conf.j2`
- Modify: `Loki/templates/docker-monitoring-stack.yml.j2` (remove the `prometheus` service)
- Delete: `Loki/templates/prometheus-config.yml.j2`
- Delete: `Loki/templates/grafana-prometheus-datasource.yml.j2`
- Modify: `5-deploy-monitoring-stack.yaml` (remove Prometheus config deployment tasks)
- Modify: `group_vars/monitoring.yml.example` (remove `prometheus_scrape_jobs`, `prometheus_version`, `prometheus_http_port`, `prometheus_retention`)

- [ ] **Step 1: Remove the Prometheus service from the compose template**

In `Loki/templates/docker-monitoring-stack.yml.j2`, delete the `prometheus:` service block entirely.

- [ ] **Step 2: Remove Prometheus config deployment from the playbook**

In `5-deploy-monitoring-stack.yaml`, delete the tasks that template `Loki/templates/prometheus-config.yml.j2` and `Loki/templates/grafana-prometheus-datasource.yml.j2`, and remove `/opt/monitoring/prometheus/data` from the directory-creation loop.

- [ ] **Step 3: Delete the now-unused files**

```bash
git rm 5b-deploy-validator-proxies.yaml Loki/templates/nginx-validator-proxy.conf.j2 Loki/templates/prometheus-config.yml.j2 Loki/templates/grafana-prometheus-datasource.yml.j2
```

- [ ] **Step 4: Clean up group_vars**

In `group_vars/monitoring.yml.example`, remove the entire `Prometheus (9-deploy-prometheus.yaml)` section (`prometheus_version`, `prometheus_http_port`, `prometheus_retention`, `prometheus_scrape_jobs`).

- [ ] **Step 5: Run ansible-lint**

```bash
ansible-lint 5-deploy-monitoring-stack.yaml
```

Expected: no `ERROR`-level violations.

- [ ] **Step 6: Commit**

```bash
git add Loki/templates/docker-monitoring-stack.yml.j2 5-deploy-monitoring-stack.yaml group_vars/monitoring.yml.example
git commit -m "chore(monitoring): remove Prometheus and the pull-based validator proxy, superseded by VictoriaMetrics + vm-proxy"
```

---

### Task 17: Update documentation

**Files:**
- Modify: `.claude/CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update the architecture diagram in CLAUDE.md**

Replace the `## Architecture Overview` diagram to reflect Alloy as the transport agent and VictoriaMetrics as the backend:

```
Validator Node ──private VLAN──► Sentry Node ──► Public P2P Network
     │                               │
     ▼                               ▼
OTEL Collector (127.0.0.1:4317)   OTEL Collector (127.0.0.1:4317)
     │                               │
     ▼                               ▼
node_exporter (127.0.0.1:9100)   node_exporter (127.0.0.1:9100)
nginx_exporter (127.0.0.1:9113)  nginx_exporter (127.0.0.1:9113)
     │                               │
     ▼                               ▼
  Alloy (scrape + remote_write)   Alloy (scrape + remote_write)
     │                               │
     └──(relay via sentry)──►  vm-proxy / loki-proxy ──► Monitoring Server
                                                          (VictoriaMetrics, Loki, Grafana)
```

- [ ] **Step 2: Update the Directory Structure and Deployment Workflow sections**

Remove `roles/node_exporter/` bullet's implication of network exposure, add `roles/alloy/` to the roles list, remove references to `6-deploy-promtail-*.yaml` and `5b-deploy-validator-proxies.yaml`, and note that `5-deploy-monitoring-stack.yaml` now has three plays (monitoring stack, loki-proxy relay, vm-proxy relay).

- [ ] **Step 3: Update README.md**

Search for any mention of `promtail`, `node_exporter` (exposed), or `Prometheus` in the deployment instructions and update to reference Alloy + VictoriaMetrics, following whatever section structure the README already uses.

```bash
grep -n "promtail\|Prometheus\|node_exporter" README.md
```

Update each matched section accordingly.

- [ ] **Step 4: Commit**

```bash
git add .claude/CLAUDE.md README.md
git commit -m "docs: update architecture docs for Alloy + VictoriaMetrics migration"
```

---

## Post-plan: production rollout (manual, not automated by this plan)

This plan produces tested, idempotent Ansible automation. Applying it to `inventory.yaml` (real validator/sentry/monitoring nodes) and decommissioning promtail/Prometheus on those specific machines is a manual ops action outside this plan's scope — run each phase's playbooks against production only after its Vagrant verification task has passed, observe dashboards for a full day per phase before advancing, and keep the old pipeline (promtail, Prometheus) running until Task 14's production-equivalent verification confirms Alloy/VictoriaMetrics carry real traffic correctly.
