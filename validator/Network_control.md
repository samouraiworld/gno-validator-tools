# Network Control – Public Internet Access

This node uses a dual network setup:

* `eno1` → Public network (DHCP, Internet access)
* `eno1.vlanid` → Private VLAN (internal infrastructure)

⚠️ Important:
The VLAN interface (`eno1.vlanid`) depends on the physical interface (`eno1`).
**Do NOT bring `eno1` down**, or you will lose access to the private network.

---

## 🔌 Disable Internet Access

To disable public Internet access while keeping the private VLAN operational:

```bash
ip addr flush dev eno1
```

### What this does:

* Removes the IP address assigned via DHCP on `eno1`
* Removes associated routes (including default route)
* Keeps `eno1` interface **UP**
* Keeps `eno1.vlanid` (private VLAN) fully functional ✅

---

## 🌐 Enable Internet Access

To restore Internet connectivity:

```bash
dhclient eno1
```

### What this does:

* Requests a new IP address via DHCP
* Restores default route and external connectivity

---

## ⚠️ Do NOT use

```bash
ip link set eno1 down
```

This will:

* Bring down the physical interface
* Break the VLAN interface (`eno1.vlanid`)
* Cause loss of internal network connectivity ❌

---

## 🔍 Verification

Check interface status:

```bash
ip addr
```

Check routing:

```bash
ip route
```

---

## 🧠 Summary

| Action                   | Internet   | Private VLAN |
| ------------------------ | ---------- | ------------ |
| `ip addr flush dev eno1` | ❌ Disabled | ✅ OK         |
| `dhclient eno1`          | ✅ Enabled  | ✅ OK         |
| `ip link set eno1 down`  | ❌ Disabled | ❌ Broken     |

---

## 💡 Notes

* These changes are **not persistent** (reset on reboot or network restart)
* Safe to use in production if you need to temporarily isolate the node from the Internet
* Does not affect internal communication over VLAN

---
