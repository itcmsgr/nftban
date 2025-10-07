# nftban-fail2ban-init

**Fail2Ban + nftables (global-table model)** — a safe, idempotent setup helper that wires Fail2Ban to a single nftables table (`inet nftban_global`) and enforces bans by populating the `temp_ban_v4` / `temp_ban_v6` sets with timeouts.

---

## ✨ Features

- Generates **Fail2Ban action**: `/etc/fail2ban/action.d/nftban-global.conf`  
  (adds/removes IPs in `inet nftban_global` → `temp_ban_v4/v6` with `timeout`)
- Sets repo-safe **DEFAULTS** via `/etc/fail2ban/jail.d/00-nftban.conf`:
  - `banaction = nftban-global`
  - `ignoreip  = file:/etc/nftban/config/nftban-fail2ban-ip-whitelist.conf.local`
- Builds **ignore IP** list from system + user whitelists (deduped)
- Validates config (emails, numerics) and provides **status**, **backup/restore**, **docs**
- Optional **login-monitor** service/timer (non-intrusive install)

---

## 🧩 Architecture (Global-Table Model)

Fail2Ban jails → **nftban-global** action → nftables sets (`temp_ban_v4/v6`) → dropped by `inet nftban_global` chain `input` at priority **-150**.

> The nftables initializer (e.g., `nftban_init_nftables_conf.sh`) must create `inet nftban_global` with the sets/chains. This project wires **Fail2Ban** safely to those sets.

---

## ✅ Requirements

- Linux with **nftables** (`nft`)
- **Fail2Ban** installed
- Optional: sendmail-compatible MTA (Postfix/Exim/msmtp/nullmailer) for email alerts

---

## 📦 Installation

```bash
sudo install -m 0755 nftban_init_fail2ban_conf.sh /usr/local/sbin/nftban_init_fail2ban_conf.sh

# Non-intrusive setup: generates/validates and stages files
sudo /usr/local/sbin/nftban_init_fail2ban_conf.sh setup

# Reload Fail2Ban to pick up action/defaults
sudo fail2ban-client reload
```

Generated files:
- **Action**: `/etc/fail2ban/action.d/nftban-global.conf`
- **Defaults**: `/etc/fail2ban/jail.d/00-nftban.conf`
- **Ignore IPs**: `/etc/nftban/config/nftban-fail2ban-ip-whitelist.conf.local`
- **Docs**: `/etc/nftban/CONFIG_REFERENCE.md`

---

## ⚙️ Configuration

### Reference vs Local Overrides
- **Reference (refreshed on each `setup`)**: `/etc/nftban/config/nftban.conf`
- **Your overrides (never touched)**: `/etc/nftban/config/nftban.conf.local`

> Put your real changes in `.local`. The script prints a diff and validates values.

### Keys you’ll likely edit
- **Email**: `NFTBAN_F2B_RECIPIENT`, `NFTBAN_F2B_SENDER`
- **Defaults**: `NFTBAN_F2B_DEF_BAN_TIME`, `NFTBAN_F2B_DEF_FIND_TIME`, `NFTBAN_F2B_DEF_MAX_RETRY`
- **Jails**: `NFTBAN_F2B_SSH_JAIL`, `NFTBAN_F2B_WORDPRESS_JAIL`, etc. (`true`/`false`)
- **Ignore list** (already set by script):  
  `NFTBAN_F2B_IGNOREIP="/etc/nftban/config/nftban-fail2ban-ip-whitelist.conf.local"`

---

## 🧪 Quick Start (SSHD jail)

The script installs a `DEFAULT` so jails inherit `banaction = nftban-global` and your `ignoreip` file.  
You can keep distro defaults or create a minimal jail:

```ini
# /etc/fail2ban/jail.d/sshd-nftban.conf
[sshd]
enabled   = true
backend   = systemd
port      = ssh

# Optional tuning
findtime  = 10m
bantime   = 1h
maxretry  = 5
```

Reload and check:

```bash
sudo fail2ban-client reload
sudo fail2ban-client status sshd
```

---

## 🔧 Script CLI

```bash
# Core
setup                # generate/validate/stage (non-intrusive)
status               # show service/jail status & last bans
diff-config          # compare base vs .local
validate-config      # configuration validation
gen-docs             # write CONFIG_REFERENCE.md

# Mail helpers
check-mail
test-mail [recipient]
generate-mail-action

# Fail2Ban action & ignore list
generate-nftban-action   # (re)write action.d/nftban-global.conf
rebuild-whitelist        # rebuild ignoreip file from whitelists

# Backup / Restore (.local + lists)
backup-config
list-backups
restore-config </path/to/archive.tar.gz>

# Optional: login monitor (live/timer)
login-monitor install
login-monitor enable <service|timer|hybrid>
login-monitor status
login-monitor disable [service|timer|hybrid|all]
login-monitor uninstall
```

---

## 🔍 Verify / Test

```bash
# nftables table exists?
sudo nft list table inet nftban_global

# Test ban via Fail2Ban (IPv4 example)
sudo fail2ban-client set sshd banip 203.0.113.9
sudo nft get element inet nftban_global temp_ban_v4 '{ 203.0.113.9 }'

# Unban
sudo fail2ban-client set sshd unbanip 203.0.113.9
sudo nft get element inet nftban_global temp_ban_v4 '{ 203.0.113.9 }' && echo still || echo gone

# Check which ignore file is used
sudo /usr/local/sbin/nftban_init_fail2ban_conf.sh status
```

---

## 🧯 Troubleshooting

- **“table/set not found”**: Ensure your nftables initializer created `inet nftban_global` and the sets.
- **No email alerts**: `check-mail` shows if a sendmail-compatible MTA is present.
- **Ignore list not applied**: confirm `ignoreip = file:/etc/nftban/config/nftban-fail2ban-ip-whitelist.conf.local`.
- **Order-of-operations**: input chain priority **-150** drops before `ct state established,related accept`.

Logs:
- Script: `/var/log/nftban/nftban-setup.log`
- Ban events: `/var/log/nftban/nftban-bans.log`
- Fail2Ban: `journalctl -u fail2ban -e`

---

## 📜 License (MIT)

```
MIT License

Copyright (c) 2025 Antonios Voulvoulis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
