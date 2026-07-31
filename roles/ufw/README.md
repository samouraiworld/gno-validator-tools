# 🔥 ufw — Ansible Role

This Ansible role configures UFW (Uncomplicated Firewall) on a server.
It resets existing rules, applies a clean firewall policy, and opens only the ports required by your application and monitoring system.

---

## 📌 Features

### ✔️ Disables and resets UFW

Ensures a clean baseline:

- Disables UFW
- Clears all existing rules (ufw reset)

### ✔️ Allows SSH

Automatically opens port 22/tcp to prevent lockout.

### ✔️ Opens application ports

Uses a list of ports defined in ufw_ports_app (defined in your inventory).

Example (inventory):

```yaml
ufw_ports_app:
  - 26656
  - 26657
  - 1317

```

### ✔️ Allows monitoring access

Allows specific ports only from a monitoring server IP using:

- ufw_allow_ip → monitoring server IP
- ufw_ports_moni → ports allowed from monitoring only

Example (inventory):

```yaml
ufw_allow_ip: 10.10.0.5
ufw_ports_moni:
  - 9100   # Node Exporter
  - 9113   # Nginx exporter
```

### ✔️ Allows the tmkms TCP signer port (optional)

Restricted to a single IP (the dedicated signer host), same pattern as the
monitoring ports above — see `roles/tmkms` (`tmkms_connection_mode: "tcp"`)
and `compose/tmkms-alone/`. No-op unless both are set.

```yaml
ufw_tmkms_port: 26659
ufw_tmkms_signer_ip: 10.10.0.20 # signer host IP
```

### ✔️ Enables UFW

Activates the firewall after all rules are applied.

---

## 🚀 Usage

**Example playbook:**

```yaml
- hosts: servers
  become: yes
  roles:
    - ufw
```

**Inventory example:**

```yaml
all:
  vars:
    ufw_ports_app:
      - 26656
      - 26657
    ufw_ports_moni:
      - 9100
      - 9113
    ufw_allow_ip: 10.10.0.5 # change me with ip of monitoring server 
```

---

## 🧪 Verification

Check UFW status:

```bash
ufw status verbose
```

You should see rules like:

```bash
22/tcp                     ALLOW       Anywhere
26656/tcp                 ALLOW       Anywhere
9100/tcp                  ALLOW       10.10.0.5
```

Check systemd:

```bash
systemctl status ufw
```

---

## 📝 Notes

    - This role must run with sudo (become: yes).
    - UFW rules are applied in a strict order: SSH → app ports → monitoring ports → enable.
    - This ensures you do not accidentally block SSH access.
    - Works on Ubuntu/Debian systems with UFW installed.
---
