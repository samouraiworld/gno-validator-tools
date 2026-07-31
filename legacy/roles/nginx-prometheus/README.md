# 📊 nginx-prometheus — Ansible Role

This Ansible role installs and configures the NGINX Prometheus Exporter, enabling metrics collection from NGINX for Prometheus/Grafana monitoring stacks.

It also deploys a lightweight NGINX sub-status endpoint required by the exporter.

---

## 📌 Features

### ✔️ Creates dedicated directory

/opt/nginx_exporter is created to store the exporter files.

### ✔️ Installs NGINX Prometheus Exporter

Downloads and extracts:

```bash
nginx-prometheus-exporter v1.4.2 (linux-amd64)
```

### ✔️ Creates dedicated user

A non-privileged nginx-exporter user is created for better security.

### ✔️ Sets proper permissions

Ensures the exporter directory is owned by the exporter user.

### ✔️ Installs a systemd service

Deploys:

```bash
/etc/systemd/system/nginx_exporter.service
```

This ensures automatic startup and service supervision.

### ✔️ Configures NGINX sub_status endpoint

Deploys a reverse proxy / status endpoint via:

```bash
templates/nginx_site.conf.j2
```

Typically exposes:

```bash
http://<host>/sub_status
```

And integrates with the Prometheus exporter.

### ✔️ Enables the site and reloads NGINX

Ensures the endpoint is live.

### ✔️ Starts and enables the exporter

The exporter is registered, enabled, and started automatically.

---

## 📁 File Structure

```bash
roles/nginx-prometheus/
├── tasks/
│   └── main.yml                      # Installation workflow
├── templates/
│   └── nginx_site.conf.j2            # NGINX status endpoint config
└── files/
    └── nginx_exporter.service        # Systemd service definition

```

---

### 🚀 Usage

Example playbook:

```bash
- hosts: monitoring_targets
  become: yes
  roles:
    - nginx-prometheus
```

After running this role, you should have:

- NGINX running with /sub_status enabled
- Prometheus Exporter running at the configured port (default is usually 9113)

---

### 🧪 Verification

1. Check exporter service status

```bash
systemctl status nginx_exporter
```

2. Check metrics endpoint

```bash
curl http://localhost:9113/metrics
```

You should see Prometheus metrics like:

```bash
nginx_http_requests_total{}
nginx_connections_active
nginx_upstream_response_ms
```

3. Check NGINX sub_status

```bash
curl http://localhost/sub_status
```

4. Check NGINX configuration

```bash
nginx -t
```

---

## 📝 Notes

- NGINX must already be installed before running this role (or you can combine it with your nginx role).
- Default exporter port depends on your nginx_exporter.service file configuration.
- This role is fully compatible with Prometheus, Grafana, and Alertmanager setups.
- Designed for Debian systems using systemd.
