🛡️ auth2-proxy — Ansible Role
=========

Deploy OAuth2 Proxy (oauth2-proxy) as a systemd service

This Ansible role installs and configures OAuth2 Proxy on a Debian server.
It downloads the official binary release, sets up the configuration files, installs a systemd service, and ensures the service is enabled and running.

This role is typically used to protect internal services (Grafana, Prometheus, Jaeger, custom dashboards, etc.) behind Google OAuth authentication.

All settings can be found in the Google console at the email address <alert@samourai.coop>

---

### 🚀 Features

- Downloads OAuth2 Proxy release (v7.12.0)
- Extracts and installs the binary under /opt/auth-proxy
- Creates OAuth2 Proxy configuration from template
- Installs Google Service Account credentials (sa.json)
- Sets correct ownership (www-data)
- Installs and enables a systemd service (auth-proxy.service)
- Starts the OAuth2 Proxy daemon

---

### 📁 Role Structure

```bash
auth2-proxy/
├── files/
│   ├── auth-proxy.service      # systemd service definition
│   └── sa.json                 # Google service account credentials
├── templates/
│   └── oauth2_proxy.cfg.j2     # OAuth2 Proxy configuration template
├── tasks/
│   └── main.yml                # Main tasks file
└── README.md                   # This documentation

```

---

### ⚙️ Requirements

- Debian/Ubuntu server
- systemd
- A valid sa.json Google Service Account file
- Valid OAuth2 Proxy configuration values in oauth2_proxy.cfg.j2

---

### 🔧 Configuration

You should define your OAuth2 Proxy settings in the template:
`templates/oauth2_proxy.cfg.j2`

Typical variables include:

- client_id
- client_secret
- redirect_url
- email_domains
- cookie_secret
- Upstream targets (example: Grafana or internal dashboards)
- Port binding (http_address = "0.0.0.0:4180")

---

### ▶️ Usage

In your playbook:

```yaml
- hosts: myserver

  vars:
    domain_name: "jaeger.zenao.io"
    group_google: "dev@samourai.coop"
    app_port: 4242
    redirect_uri: "https://jaeger.zenao.io/oauth2/callback" # add uri to google console 

  roles:
    - auth2-proxy
```

---

### 📤 What This Role Installs

1. OAuth2 Proxy binary

Downloaded from GitHub:

```bash
/opt/auth-proxy
```

2. Configuration file:

```bash
/opt/auth-proxy/oauth2_proxy.cfg
```

3. Service account file:

```bash
/opt/auth-proxy/sa.json
```

4. Systemd service:

```switch
/etc/systemd/system/auth-proxy.service
```

---

### ▶️ Managing the Service

Start:

```bash
systemctl start auth-proxy
```

Enable on boot:

```bash
systemctl enable auth-proxy
```

Check logs:

```bash
journalctl -u auth-proxy -f
```

---

### 📝 Notes

- Make sure your redirect URLs match your OAuth settings in Google Cloud Console.
- Ensure your firewall / reverse proxy allows traffic to the OAuth2 Proxy port (4180 by default).
- You can integrate this with NGINX for TLS and routing.
