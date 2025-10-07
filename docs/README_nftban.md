# NFTBan — nftables & Fail2Ban helper

[![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/platform-Linux-33aadd?logo=linux&logoColor=white)](#)
[![Firewall](https://img.shields.io/badge/firewall-nftables-ef7a0a)](#)
[![Intrusion%20Prevention](https://img.shields.io/badge/IPS-Fail2Ban-4caf50)](#)
[![Status](https://img.shields.io/badge/status-production_ready-blue)](#)

A single, self‑contained CLI that helps you **manage nftables & Fail2Ban** and maintain **allow/deny IP lists** from the command line. It supports **temporary bans** via nftables timeout sets and **permanent bans** via on‑disk blacklists that your nftables init rules consume.

> **Version:** 3.1.1  
> **Author:** ITCMS Team (Antonios Voulvoulis)

---

## ✨ Features
- Start/stop/enable/restart **nftables** and **Fail2Ban** safely after a config check.
- One‑command **allowlist** management (add your current login IP or any IP/CIDR).
- **Temporary bans** (IPv4/IPv6) with timeouts for immediate effect.
- **Permanent bans** written to system blacklist files (and auto temp‑ban seed).
- **Inspect**: list temporary bans, view all banned IPs, show Fail2Ban jails & bans.
- **Clean up**: remove an IP from temp sets, blacklist files, and all Fail2Ban jails.
- Helpful **logging** and **backups** of your nftables configuration.

## 🏗️ How it works (high level)
- Uses a global nftables table `inet nftban_global` with two timeout sets:  
  `temp_ban_v4` (IPv4) and `temp_ban_v6` (IPv6) for **temporary bans**.
- **Permanent bans** are appended to:
  - `/etc/nftban/config/nftban-configuration-ipv4-blacklist_ips.conf.local`
  - `/etc/nftban/config/nftban-configuration-ipv6-blacklist_ips.conf.local`
- **Allowlist** is kept in:  
  `/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local`
- The nftables init script you use is expected to load those files into the ruleset.

## ✅ Prerequisites
- Linux with **nftables** and **systemd**.  
- **Fail2Ban** (optional, but recommended).  
- Run commands as **root**.

### Install dependencies
**Debian/Ubuntu**
```bash
sudo apt update
sudo apt install -y nftables fail2ban
```

**RHEL/CentOS/Fedora**
```bash
sudo dnf install -y nftables fail2ban
```

## ⚙️ Setup
1) **Place the script** somewhere in your PATH and make it executable:
```bash
sudo install -m 0755 nftban.sh /usr/local/sbin/nftban
```

2) **Initialize nftables layout** (creates table & sets expected by the script):
```bash
sudo nftban_init_nftables_conf.sh --install-final
# This must create: table `inet nftban_global` and sets `temp_ban_v4` / `temp_ban_v6`
```

3) *(Optional)* **Fail2Ban integration** so your jails use the nftables action.

4) **Add your current login IP** to the allowlist (highly recommended):
```bash
sudo nftban --add-ip
```

5) **Start & enable** services (with config checks):
```bash
sudo nftban --enable
# or
sudo nftban --start
```

## 🧰 CLI reference
> Run `nftban --help` to print the built‑in help.

### Core
- `-e, --enable` — Enable & start nftables and Fail2Ban **after config check**
- `-d, --disable` — Disable & stop both services
- `-s, --start` — Start both services **after config check**
- `-r, --restart` — Restart both services **after config check**
- `-x, --stop` — Stop both services
- `-l, --list` — List current nftables ruleset
- `-c, --check` — Check nftables & Fail2Ban configuration syntax
- `-a, --add-ip [IP]` — Add the given IP (or **your current login IP** if omitted) to allowlist
- `-i, --info` — Show current login IP, allowlist status & services status
- `-tb, --temp-ban [IP] [COMMENT]` — Temp‑ban IP (**1 hour**) with optional comment
- `-pb, --perm-ban [IP] [COMMENT]` — Permanently ban IP with optional comment (also seeds a 1h temp‑ban for immediate enforcement)
- `-rb, --remove-ban [IP]` — Remove an IP from temporary sets and Fail2Ban (best‑effort)
- `-lt, --list-temp` — List temporarily banned IPs (IPv4 & IPv6)
- `--enable-logging` / `--disable-logging` — Toggle file logging
- `-h, --help` — Show help

### Fail2Ban utilities
- `-fj, --fail2ban-jails` — List available jails
- `-fr, --fail2ban-rules [JAIL]` — Show action/rules for a jail
- `-fb, --fail2ban-banned [JAIL]` — Show banned IPs (for a jail or all)
- `-fc, --fail2ban-check` — Check Fail2Ban config only

### Advanced
- `-vb, --view-banned` — View **all** banned IPs: nftables temp sets + permanent blacklist files + Fail2Ban bans
- `-ri, --remove-ip [IP]` — Remove IP from **everywhere** (temp sets, blacklist files, and all Fail2Ban jails)

## 🚀 Common examples
Add your **current login IP** to the allowlist:
```bash
sudo nftban --add-ip
```

Temp‑ban an IPv4 for **1h** with a note:
```bash
sudo nftban --temp-ban 203.0.113.9 "SSH brute-force"
```

Permanently ban an IPv6 (also seeds a 1h temp‑ban):
```bash
sudo nftban --perm-ban 2001:db8::dead:beef "Abusive client"
```

Remove an IP from everywhere (temp, blacklists, Fail2Ban):
```bash
sudo nftban --remove-ip 203.0.113.9
```

Show current temporary bans:
```bash
sudo nftban --list-temp
```

List Fail2Ban jails and see bans:
```bash
sudo nftban --fail2ban-jails
sudo nftban --fail2ban-banned            # all jails
sudo nftban --fail2ban-banned sshd       # specific jail
```

## 📁 Files & directories
- Main nftables conf (validated): `/etc/nftables.conf`
- Allowlist: `/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local`
- IPv4 blacklist: `/etc/nftban/config/nftban-configuration-ipv4-blacklist_ips.conf.local`
- IPv6 blacklist: `/etc/nftban/config/nftban-configuration-ipv6-blacklist_ips.conf.local`
- Backups dir: `/etc/nftables/backups`
- Log file: `/var/log/nftban.log`
- Fail2Ban: `/etc/fail2ban`, jails under `/etc/fail2ban/jail.d`

## 🔧 Environment toggles
- `REQUIRE_F2B=true` — Make `--check/--start/--enable/--restart` **fail** if Fail2Ban is missing or misconfigured. Default: *not required*.
- `ENABLE_LOGGING=false` — Disable file logging without changing CLI flags. Default: *enabled*.

## 🔙 Exit codes (high‑level)
- `0` — Success
- `1` — Generic failure (invalid input, failed checks, etc.)
- `2` — No change (e.g., IP already present in allowlist)

## 🧭 Troubleshooting
- **“Global table not found”** — Run the nftables init script with `--install-final` to create `inet nftban_global` and the temp sets.
- **Fail2Ban not installed** — nftables operations still work. Set `REQUIRE_F2B=true` if you want strict checks.
- Use `--list` and `--list-temp` to quickly inspect current state.

## 🔐 Security notes
- The script **refuses to ban your current login IP**.
- Run the tool as **root**. Review the blacklist & whitelist files before enabling on production systems.

## 🗺️ Roadmap / ideas
- Configurable temp‑ban duration (per command).
- Optional JSON/CSV dump of current bans for reporting.
- Git‑backed history of blacklist/allowlist.

## 🤝 Contributing
PRs/issues welcome. Please keep shellcheck compatibility and test on both IPv4/IPv6.

## 📄 License
Choose a license (e.g., MIT, Apache‑2.0) and add a `LICENSE` file.

## 🙌 Credits
- Original work & consolidation: **ITCMS Team (Antonios Voulvoulis)**.
