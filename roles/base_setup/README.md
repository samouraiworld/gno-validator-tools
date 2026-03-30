# 🧱 base_setup — Ansible Role

This role performs the initial base system configuration on a fresh debian 12 server.
It installs essential packages, updates the system, and enables useful shell aliases for the root user.

---

## 📌 Features

This role provides:

### ✔️ System updates

- Runs apt update
- Performs a full system upgrade (dist-upgrade)

### ✔️ Installation of base packages

The following utilities are installed by default:

- htop
- curl
- ufw
- jq
- net-tools
- sudo
- wget
- unzip
- git
- yq
- certbot
- sqlite3
- rclone
- awscli

(You can customize the list in defaults/main.yml.)

### ✔️ Shell enhancements for root

The role uncomments default aliases and color settings inside /root/.bashrc:

- LS_OPTIONS
- dircolors
- alias ls
- alias ll
- alias l

This makes the shell more user-friendly out of the box.

---

## 📁 File Structure

```bash
roles/base_setup/
├── tasks/
│   └── main.yml               # Main tasks (updates, installs, aliases)
└── defaults/
    └── main.yml               # Default package list
```

---

## 🚀 Usage

Add the role to your playbook:

```yaml
- hosts: servers
  become: yes
  roles:
    - base_setup
```

---

## 📝 Notes

This role is designed for Debian systems.
It should be one of the first roles applied to a new server.
It prepares the environment for the rest of your infrastructure (docker, gnoland, monitoring, etc.).
