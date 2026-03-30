# 🪪 gnoland — Ansible Role

This Ansible role installs Go, clones the Gno repository, and builds the required binaries for running Gnoland and gnogenesis.
It is designed to prepare any server to run Gno-related components (validators, tools, local dev environments, etc.).

---

## 📌 Features

This role automates the full installation workflow:

### ✔️ Install Go 1.25.0

- Downloads the official Go tarball
- Removes any old installation (/usr/local/go)
- Extracts Go into /usr/local
- Adds Go to the system PATH

### ✔️ Clone the Gno repository

Pulls the latest version of:

```bash
https://github.com/gnolang/gno.git
```

into the directory defined by gno_dir.

### ✔️ Build Gnoland

Runs:

```bash
make -C gno.land install.gnoland
```

This compiles and installs:

- gnoland
- related Gno binaries

### ✔️ Build gnogenesis

Runs:

```bash
make -C contribs/gnogenesis install
```

This installs the generator tool used for:

- genesis creation
- validator addition
- chain configuration

### ✔️Add Gno binaries to PATH

Ensures /root/go/bin is added to the shell environment.

---

### 🔧 Variables

gno_dir (required)

Directory where the Gno repository will be cloned.

Example:

```bash
gno_dir: /opt/gno
```

---

### 🚀 Usage

Add the role in your playbook:

```yaml
- hosts: validators
  become: yes
  vars:
    gno_dir: /opt/gno
  roles:
    - gnoland
```

---

### 🧪 Verification

After execution:

#### Check Go version

```bash
go version
```

#### Try running Gnoland

```bash
gnoland version
```

---

### 📝 Notes

- This role is designed for Debian/Ubuntu servers.
- It always installs Go 1.25.0, matching the current Gnoland requirements.
- If you want, we can:
  - Pin Gno to a specific branch
  - Build only certain binaries
  - Install Go from apt instead of tarball
  - Cache the Gno repo to speed up deployments
  - Add version checks before reinstalling Go
