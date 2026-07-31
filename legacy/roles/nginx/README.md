# 🌐 nginx — Ansible Role

This Ansible role installs NGINX, removes the default configuration, and deploys custom reverse-proxy virtual hosts using Jinja2 templates.
It is designed to manage multiple NGINX sites dynamically through the variable nginx_sites.

---

## 📌 Features

### ✔️ Installs required packages

- nginx
- certbot
- python3-certbot-nginx
( Useful if you later want to integrate Let’s Encrypt TLS)

### ✔️ Removes default NGINX configuration

Disables /etc/nginx/sites-enabled/default to avoid conflicts.

### ✔️ Deploys reverse-proxy configurations

For each entry in nginx_sites, the role:

1 Renders a config file using a template (default: nginx_site.conf.j2)
2 Places the file into /etc/nginx/sites-available/<domain>
3 Creates a symbolic link in /etc/nginx/sites-enabled/

### ✔️ Validates configuration

Runs:

```bash
nginx -t
```

to ensure syntax correctness.

### ✔️ Restarts NGINX

Applies the configuration safely.

---

## 📁 File Structure

```bash
roles/nginx/
├── tasks/
│   └── main.yml                   # Site creation, enabling, service restart
└── templates/
    └── nginx_site.conf.j2         # Default site template (customizable)
```

---

## 🔧 Variables

nginx_sites (required)
A list of NGINX vhosts to deploy.

Each entry accepts:

- domain_name – the filename for the site
- template (optional) – custom template file to use

Example:

```yaml
nginx_sites:
  - domain_name: rpc.mydomain.com
    template: nginx_rpc.conf.j2

  - domain_name: explorer.mydomain.com
    template: nginx_explorer.conf.j2

  - domain_name: metrics.mydomain.com
    # uses default template nginx_site.conf.j2

```

---

## 🚀 Usage

Include the role in your playbook:

```yaml
- hosts: webservers
  become: yes
  vars:
    nginx_sites:
      - domain_name: node_exporter
      - domain_name: otel
        template: nginx_otel.conf.j2
  roles:
    - nginx

```

---

## 🧪 Verification

After running the role:

**Check that sites are enabled:**

```bash
ls /etc/nginx/sites-enabled/
 ```

**Test NGINX syntax manually:**

```bash
nginx -t
 ```

**Check if NGINX is running:**

```bash
systemctl status nginx
 ```

---

## 📝 Notes

- This role does not handle TLS certificates by itself.
(Pair it with your generate_cert_tls role if needed.)
- Any number of sites can be deployed using the nginx_sites list.
- Templates allow complete flexibility: reverse proxies, static hosting, API gateways, etc.
