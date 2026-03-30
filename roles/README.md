# 🏗️ infra_roles — Ansible Roles Collection  

This repository contains a collection of reusable and production-ready **Ansible roles** used to provision and manage infrastructure components for the Samouraï ecosystem (validators, sentry nodes, monitoring stack, reverse proxies, authentication, firewall, etc.).

Each role is isolated, idempotent, and designed to work on **Debian** servers with systemd.

---

## 📦 Available Roles

Below is a summary of each role included in this repository:

- [base_setup](#1-basesetup)
- [docker](#2-docker)
- [nginx](#3-nginx)
- [generate_cert_tls](#4-generate_cert_tls)
- [node_exporter](#5-node_exporter)
- [nginx-prometheus](#6-nginx-prometheus)
- [ufw](#7-ufw)
- [gnoland](#8-gnoland)
- [auth2-proxy](#9-auth2-proxy)

---

## 🔧 1. [`base_setup`](./base_setup/README.md)

**Purpose:** Prepare a fresh server with essential tools and quality-of-life improvements.

**Main features:**

- Full system update & dist-upgrade  
- Installs base packages (`curl`, `htop`, `ufw`, `jq`, `git`, `yq`, `certbot`, `sqlite3`, `rclone`, `awscli`, etc.)  
- Enables useful shell aliases and color settings in `/root/.bashrc`  
- Provides a clean baseline for all subsequent roles  

---

## 🐳 2. [`docker`](./docker/README.md)  

**Purpose:** Install Docker Engine, CLI, `containerd` and the Docker Compose plugin using the official Docker repository.

**Main features:**

- Adds Docker’s official GPG key and APT repository  
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`  
- Prepares the system for containerized deployments (validators, indexers, exporters, etc.)  

---

## 🌐 3. [`nginx`](./nginx/README.md)

**Purpose:** Install NGINX and deploy reverse-proxy configurations using Jinja2 templates.

**Main features:**

- Installs `nginx`, `certbot`, and `python3-certbot-nginx`  
- Removes the default site from `/etc/nginx/sites-enabled`  
- Creates vhosts from the `nginx_sites` list (dynamic, per host)  
- Enables each site and restarts NGINX  
- Ideal for RPC endpoints, dashboards, exporters, etc.  

---

## 🔐 4. [`generate_cert_tls`](./generate_cert_tls/README.md)

**Purpose:** Automatically obtain and renew TLS certificates with Let’s Encrypt (Certbot), without overriding your existing HTTPS vhosts.

**Main features:**

- Ensures `nginx`, `certbot`, and `python3-certbot-nginx` are installed  
- Creates a **temporary HTTP vhost** from `nginx_http_tmp.conf.j2` for ACME HTTP-01 validation  
- Runs `certbot certonly --nginx -d <domain_name>` with non-interactive options  
- Removes the temporary vhost once the certificate is issued  
- Validates NGINX config and restarts the service  

---

## 🖥️ 5. [`node_exporter`](./node_exporter/README.md)

**Purpose:** Install the Prometheus **Node Exporter** to expose system-level metrics.

**Main features:**

- Downloads and unpacks `node_exporter` (v1.9.1) into `/opt/node_exporter`  
- Creates a dedicated `exporter` user  
- Installs a systemd unit `node_exporter.service`  
- Enables and starts the service (default port: **9100**)  

---

## 📊 6. [`nginx-prometheus`](./nginx-prometheus/README.md)

**Purpose:** Install the **NGINX Prometheus Exporter** and expose NGINX metrics to Prometheus.

**Main features:**

- Creates `/opt/nginx_exporter` directory  
- Downloads and extracts `nginx-prometheus-exporter` (v1.4.2)  
- Creates a `nginx-exporter` user and assigns permissions  
- Installs `nginx_exporter.service` systemd unit  
- Deploys an NGINX `sub_status` site from `nginx_site.conf.j2`  
- Enables the site, reloads NGINX, and starts the exporter (default port: **9113**)  

---

## 🎛️ 7. [`ufw`](./ufw/README.md)

**Purpose:** Configure the UFW firewall with a clean and controlled set of rules.

**Main features:**

- Disables and resets UFW (cleans all existing rules)  
- Allows SSH (port 22/tcp) by default  
- Opens application ports listed in `ufw_ports_app`  
- Allows monitoring ports listed in `ufw_ports_moni` **only** from `ufw_allow_ip` (Prometheus/monitoring server)  
- Enables UFW once rules are applied  

---

## 🪪 8. [`gnoland`](./gnoland/README.md)

**Purpose:** Install Go, clone the Gno repository, and build Gnoland-related binaries.

**Main features:**

- Downloads and installs Go **1.25.0** into `/usr/local/go`  
- Adds Go to root PATH (`/usr/local/go/bin`)  
- Clones `https://github.com/gnolang/gno.git` into `gno_dir`  
- Runs `make -C gno.land install.gnoland`  
- Runs `make -C contribs/gnogenesis install`  
- Adds `/root/go/bin` to PATH so `gnoland`, `gnokey`, `gnogenesis`, etc. are available  

---

## 🛡️ 9. [`auth2-proxy`](./auth2-proxy/README.md)

**Purpose:** Install and configure **OAuth2-Proxy** to protect internal services (Grafana, Prometheus, dashboards, etc.) behind OAuth2 authentication (Google, GitHub, etc.).

**Main features:**

- Downloads `oauth2-proxy` archive and extracts it into `/opt/auth-proxy`  
- Renders `oauth2_proxy.cfg` from a Jinja2 template (`oauth2_proxy.cfg.j2`)  
- Copies `sa.json` (OAuth service account / credentials file) into `/opt/auth-proxy`  
- Sets ownership of `/opt/auth-proxy` to `www-data`  
- Installs a systemd service unit `auth-proxy.service`  
- Reloads systemd, enables, and starts the `auth-proxy` service  

This role is typically used in front of internal dashboards (Grafana, Prometheus UI, etc.) together with NGINX.

---
