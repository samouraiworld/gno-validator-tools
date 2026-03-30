## 🖥️ node_exporter — Ansible Role

This Ansible role installs and configures the Prometheus Node Exporter, enabling system-level metrics collection (CPU, RAM, disk, network, filesystem, etc.) for integration with Prometheus and Grafana.

---

### 📌 Features

#### ✔️ Downloads Node Exporter

Fetches version 1.9.1 from the official GitHub release page:

```bash
node_exporter-1.9.1.linux-amd64.tar.gz
```

#### ✔️ Extracts and installs

- Unpacks the archive into /opt/
- Renames the directory to /opt/node_exporter
- Removes the original tar.gz to keep the system clean

#### ✔️ Creates a dedicated user

Creates the exporter user for improved security when running the service.

#### ✔️ Sets correct permissions

Ensures the exporter directory belongs to the exporter user.

#### ✔️ Installs systemd service

Copies the following file:

```bash
/etc/systemd/system/node_exporter.service
```

This provides:

- Automatic startup at boot
- Service supervision via systemd

#### ✔️ Enables and starts the service

Activates Node Exporter immediately and ensures it will start on boot.

---

## 📁 File Structure

```bash
roles/node_exporter/
├── tasks/
│   └── main.yml                 # Download, unpack, configure, start exporter
└── files/
    └── node_exporter.service    # Systemd service definition

```

---

### 🚀 Usage

Example playbook:

```bash
- hosts: servers
  become: yes
  roles:
    - node_exporter
```

Node Exporter will be running and listening on port 9100 (default).

---

#### 🧪 Verification

**Check service status**

```bash
systemctl status node_exporter
```

**View metrics endpoint**

```bash
curl http://localhost:9100/metrics
```

**You should see metrics such as:**

```bash
node_cpu_seconds_total
node_memory_MemAvailable_bytes
node_filesystem_size_bytes
node_network_receive_bytes_total
```

---

#### 📝 Notes

- This role is designed for Debian/Ubuntu and requires systemd.
- Node Exporter is a key component of any Prometheus monitoring ecosystem.
- Combine this role with:
      - nginx-prometheus (for NGINX metrics)
      - docker (if you run containers)
      - ⚠️ Update the Prometheus configuration on the monitoring server to add this server’s metrics so they can be displayed in Grafana.
