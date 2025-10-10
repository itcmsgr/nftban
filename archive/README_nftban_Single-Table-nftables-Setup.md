# 🚀 nftban: Single-Table nftables Setup

This project provides a **unified nftables configuration** using a single table: `inet nftban_global`.  
It manages **whitelists**, **blacklists**, and **temporary bans** for both **IPv4** and **IPv6** — optimized for speed, simplicity, and automation with the `nftban` management script.

✅ Whitelist always takes priority · ⚡ Fast set lookups · 🛡️ Centralized v4/v6 control

---

## 🧭 NFTables Structure Explained

The firewall configuration follows a simple structure:

```
Family → Table → {
  Chain
  Set
}
```

- **Family (inet):** Scope covering both IPv4 and IPv6 traffic.  
- **Table (`nftban_global`):** Container that holds all chains and sets for NFTBAN.  
- **Set (e.g., `system_blacklist_v4`):** A data structure inside the table containing IPs or networks. Sets are highly optimized for fast lookups.

### 📚 The Table's Components

| Component | Type  | Name                | Family | Purpose |
|-----------|-------|---------------------|--------|---------|
| Table     | table | `nftban_global`     | inet   | Container for all firewall rules/sets |
| Set       | set   | `whitelist_v4`      | (impl.)| IPv4 addresses always allowed |
| Set       | set   | `whitelist_v6`      | (impl.)| IPv6 addresses always allowed |
| Set       | set   | `user_blacklist_v4` | (impl.)| IPv4 manual user bans |
| Set       | set   | `user_blacklist_v6` | (impl.)| IPv6 manual user bans |
| Set       | set   | `system_blacklist_v4`| (impl.)| IPv4 bulk bans (country blocks, ranges) |
| Set       | set   | `system_blacklist_v6`| (impl.)| IPv6 bulk bans (ranges) |
| Set       | set   | `temp_ban_v4`       | (impl.)| IPv4 temporary bans (timeout) |
| Set       | set   | `temp_ban_v6`       | (impl.)| IPv6 temporary bans (timeout) |
| Chain     | chain | `input`             | (impl.)| Processes incoming traffic (whitelist → blacklists → temp_ban → state/ports) |
| Chain     | chain | `forward`           | (impl.)| Same logic applied to forwarded traffic |
| Chain     | chain | `output`            | (impl.)| Processes outgoing traffic |

---

## 📦 IP Address Sets (The Lists)

Six primary sets (three for IPv4 and three for IPv6) store/lookup addresses for **whitelisting** and **blacklisting**.

| Set Name              | IP Version | Flags    | Purpose                                                                 | Example (Add IP) |
|-----------------------|-----------:|----------|-------------------------------------------------------------------------|------------------|
| `whitelist_v4`        | IPv4       | `interval` | IPs that are always allowed (system, user, Cloudflare). Whitelist wins. | `sudo nft add element inet nftban_global whitelist_v4 { 192.0.2.1 }` |
| `whitelist_v6`        | IPv6       | `interval` | IPs that are always allowed.                                            | `sudo nft add element inet nftban_global whitelist_v6 { 2001:db8::1 }` |
| `user_blacklist_v4`   | IPv4       | `interval` | IPs banned manually by the user.                                        | `sudo nft add element inet nftban_global user_blacklist_v4 { 203.0.113.10 }` |
| `user_blacklist_v6`   | IPv6       | `interval` | IPv6 addresses banned manually by the user.                             | `sudo nft add element inet nftban_global user_blacklist_v6 { 2001:db8:abc::1 }` |
| `system_blacklist_v4` | IPv4       | `interval` | IPs banned in bulk (country blocks, large ranges).                       | `sudo nft add element inet nftban_global system_blacklist_v4 { 198.51.100.0/24 }` |
| `system_blacklist_v6` | IPv6       | `interval` | IPv6 addresses banned in bulk.                                          | `sudo nft add element inet nftban_global system_blacklist_v6 { 2001:db8:deaf::/48 }` |
| `temp_ban_v4`         | IPv4       | `timeout`  | IPs banned temporarily (e.g., by the main nftban script).               | `sudo nft add element inet nftban_global temp_ban_v4 { 192.0.2.5 timeout 1h }` |
| `temp_ban_v6`         | IPv6       | `timeout`  | IPv6 addresses banned temporarily.                                      | `sudo nft add element inet nftban_global temp_ban_v6 { 2001:db8:cafe::1 timeout 1h }` |

---

## 🛠️ How to Access and Modify Sets

To interact with a set, specify its **Family** and **Table**.

**General Syntax:**
```bash
nft [add | delete | list] element [family] [table] [set] { element(s) }
```

**Examples:**
```bash
# 1) Check current contents of system blacklist
sudo nft list set inet nftban_global system_blacklist_v4

# 2) Add an IP to system blacklist
sudo nft add element inet nftban_global system_blacklist_v4 { 203.0.113.5 }

# 3) Remove an IP from system blacklist
sudo nft delete element inet nftban_global system_blacklist_v4 { 203.0.113.5 }
```

---

## 🏗️ Architecture Overview

- **Table:** `inet nftban_global`  
- **Chains:**
  - `input` (priority **-150**) → incoming traffic  
  - `output` (priority **0**) → outgoing traffic  
  - `forward` → forwarded traffic  
- **Sets:** Optimized IP lists for whitelist, blacklist, and temporary bans

---

## ⚙️ Example Commands

```bash
# Add to whitelist
sudo nft add element inet nftban_global whitelist_v4 { 192.0.2.1 }

# Add to user blacklist
sudo nft add element inet nftban_global user_blacklist_v4 { 203.0.113.10 }

# Add to system blacklist
sudo nft add element inet nftban_global system_blacklist_v4 { 198.51.100.0/24 }

# Add temporary ban
sudo nft add element inet nftban_global temp_ban_v4 { 192.0.2.5 timeout 1h }
```

---

## 🔄 Rule Processing Order

1. **Whitelist** → ✅ ACCEPT  
2. **User/System Blacklists** → ⛔ DROP  
3. **Temporary Ban** → ⏳ DROP  
4. If none match → continue with normal nftables rules

---

## 🗺️ Diagram

```
inet nftban_global
├── Sets:
│   ├── whitelist_v4 / whitelist_v6
│   ├── user_blacklist_v4 / user_blacklist_v6
│   ├── system_blacklist_v4 / system_blacklist_v6
│   └── temp_ban_v4 / temp_ban_v6
└── Chains:
    ├── input (priority -150)
    │   ├── whitelist → ACCEPT
    │   ├── blacklists → DROP
    │   └── temp_ban → DROP
    ├── forward (same logic)
    └── output (priority 0)
```

---

With this setup, nftables remains **modular**, **script‑friendly**, and **safe**.
