# 🐳 Docker — Ansible Role

This role installs and configures Docker Engine, Docker CLI, containerd, and the Docker Compose plugin on Debian-based systems.
It adds the official Docker repository, installs prerequisites, and prepares the system for production-grade container deployments.

---

## 📌 Features

### ✔️ System update

Runs an APT cache update with:

```yaml
apt:
  update_cache: yes
  cache_valid_time: 3600
```

### ✔️ Installation of prerequisite packages

Installs the packages required before adding the Docker repository:

- ca-certificates
- curl
- gnupg
- lsb-release
- (customizable via docker_packages variable)

### ✔️ Setup of the official Docker repository

The role:

- Creates /etc/apt/keyrings/
- Downloads Docker’s GPG key
- Adds the official Docker APT repository
- Updates the package index

### ✔️ Installation of Docker components

Installs the full Docker stack:

- docker-ce
- docker-ce-cli
- containerd.io
- docker-buildx-plugin
- docker-compose-plugin

---

## 🚀 Usage

Example playbook:

```yaml
- hosts: all
  become: yes
  roles:
    - docker
```

---

### 📝 Notes

- This role is designed for Debian systems.
- It uses the official Docker repository, not distribution-provided packages.
- docker-compose-plugin (v2) is installed, not the deprecated docker-compose v1.
- If you need to add user permissions (e.g., add a user to the docker group), I can extend the role.
