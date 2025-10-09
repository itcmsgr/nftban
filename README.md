<p align="center">
  <img src="https://itcms.gr/wp-content/uploads/2022/08/ITCMSA_smalv1.png" alt="ITCMS Logo" width="200"/>
</p>

# 🛡️ nftban – Modular Linux Firewall Management
**Based on nftables & Fail2Ban**

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Linux-blue">
  <img alt="Status" src="https://img.shields.io/badge/status-active-brightgreen">
  <img alt="Compatibility" src="https://img.shields.io/badge/compatibility-Debian%2FUbuntu%20%7C%20RHEL%2FCentOS%2FFedora-orange">
  <a href="./LICENSE.md"><img alt="License" src="https://img.shields.io/badge/License-CustomMIT--NoResale%20v1.1-lightgrey"></a>
  <a href="./LICENSE.md"><img alt="SPDX" src="https://img.shields.io/badge/SPDX-LicenseRef--CustomMIT--NoResale--1.1-lightgrey"></a>
</p>

**nftban** is a modular, automation-friendly firewall & ban-management toolkit built on **nftables** and **Fail2Ban**.  
Ideal for sysadmins and security engineers who want a robust, scriptable, policy-driven setup.

---

## 🔍 Overview

- High-performance packet filtering via **nftables**
- Dynamic IP blocking via **Fail2Ban** (global table integration)
- Modular layout under `/etc/nftban` with clear `.local` overrides
- Safe defaults; designed to be reviewed before enforcement

---

## ✨ Features
- 🌐 **Dual-stack** IPv4/IPv6
- 🎯 **Customizable filtering** (TCP/UDP, ranges)
- 🔍 **Stateful inspection** via `conntrack`
- 🚫 **Dynamic bans** & whitelisting through Fail2Ban integration
- 🧩 **Granular control** (interfaces, modular config)
- 📁 **Structured layout** under `/etc/nftban` (see below)
- 🖥️ **Compatibility**: RHEL/CentOS/Fedora, Debian/Ubuntu (others untested)

---

## 🚀 Quick Start (installer)
Use the unified installer to fetch/sync the repo and create structure.

```bash
curl -fsSL -o nftban_init.sh https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_userfriendly.sh
chmod +x nftban_init.sh
sudo ./nftban_init.sh --github -y --beginner
```

- `--github` keeps `/etc/nftban` synced with the repo
- `-y` assumes “yes” on safe prompts
- `--beginner` prints friendlier guidance
- Add `--no-color` / `--no-unicode` if your terminal needs it

### Other flows
- ZIP: `sudo ./nftban_init.sh --zip -y`  
- Local/basic (no sync): `sudo ./nftban_init.sh -y`

---

## 📂 Directory Structure (installed)
```text
/etc/nftban
├─ bin/
│  └─ nftban                   # CLI shim
├─ scripts/                    # helpers (init, fail2ban, etc.)
├─ config/                     # your *.conf.local overrides
├─ templates/
│  └─ control-panels/          # directadmin / cpanel / plesk / generic
├─ rules/ conf.d/ systemd/ ...
└─ logs -> /var/log/nftban     # convenience symlink
```
> The installer is **non-intrusive**: it does not start/enable services by itself.

---

## 🧩 nftables + Fail2Ban (global-table model)
Fail2Ban actions update nftables sets (`temp_ban_v4` / `temp_ban_v6`) within table `inet nftban_global`, dropped in `input` at priority **-150**.  
Use `nftban_init_nftables_conf.sh` to create the base table/sets before enabling jails.

---

## 🧪 Compatibility Matrix

| Distribution      | Status        |
|-------------------|---------------|
| Debian / Ubuntu   | ✅ Supported  |
| RHEL / CentOS     | ✅ Supported  |
| Fedora            | ✅ Supported  |
| AlmaLinux / Rocky | ✅ Compatible |
| Arch Linux        | ⚠️ Not tested |

---

## 🧷 CLI (placeholder)
A helper CLI is installed at `/usr/local/bin/nftban` → `/etc/nftban/bin/nftban`:

```bash
nftban --help
nftban status
nftban list
nftban init
nftban reload
nftban flush    # prompts before flush
```

Full features arrive when the repo is synced.

---

## 📜 License Summary
- ✅ **Free to Use** — personal & commercial
- 🖊️ **Attribution Required** — credit ITCMS and the author
- 💰 **No Resale** — selling/sublicensing requires written permission
- 🚫 **No Misrepresentation** — don’t claim as your own
- 📦 **Third-Party Code** — under their licenses
- ⚠️ **No Warranty** — provided “as is”

Full text: see [LICENSE.md](./LICENSE.md)
