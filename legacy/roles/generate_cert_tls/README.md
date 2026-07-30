# 🔐 generate_cert_tls — Ansible Role

This Ansible role automatically generates and renews TLS certificates using Let's Encrypt (Certbot), with a temporary NGINX HTTP vhost for domain validation.
It is designed to safely issue certificates without replacing your existing HTTPS configuration.

---

## 📌 Features

This role performs all steps required to obtain a valid Let's Encrypt certificate:

### ✔️ Installs required packages

- nginx
- certbot
- python3-certbot-nginx

### ✔️ Removes default NGINX site

Ensures no conflict with ACME validation.

### ✔️ Creates a temporary HTTP vhost

- Used only for Certbot domain validation:
- Template: nginx_http_tmp.conf.j2

### ✔️ Enables temporary site and reloads NGINX

Ensures Certbot can access http://<domain>/.well-known/acme-challenge/…

### ✔️ Issues or renews certificate

Using the NGINX authenticator without installing a new NGINX config:

```bash
certbot certonly --nginx -d <domain_name>
```

### ✔️ Removes temporary vhost

Once the certificate is obtained, the temporary config is removed cleanly.

### ✔️ Final NGINX validation & reload

Confirms the server is correctly configured.

---

### 🔧 Variables

domain_name (required)

The domain for which the TLS certificate will be generated.

```bash
domain_name: example.com
```

---

### 🚀 Usage

Add the role to your playbook:

```yaml
- hosts: webservers
  become: yes
  vars:
    domain_name: mydomain.com
  roles:
    - generate_cert_tls
```

---

### 🧪 Verification

After the role completes, verify certificate presence:

```bash
ls -l /etc/letsencrypt/live/<domain_name>/
```

Check certificate expiration:

```bash
certbot certificates
```

---

### 📝 Notes

- This role does not install an HTTPS vhost — it only obtains certificates.
- It is compatible with custom NGINX setups.
- Renewal will work automatically if Certbot timers are enabled (default on Debian/Ubuntu).
- Make sure DNS records for the domain are already pointing to this server. (Gandi)
