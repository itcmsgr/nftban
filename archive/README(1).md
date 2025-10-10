# nftban_init.sh – Package Bootstrapper

**Cross-distro bootstrapper and installer for the nftban stack (packages, files, auto-update)**

[![Version](https://img.shields.io/badge/version-3.1.0-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A production-ready Bash script that **prepares and maintains** the prerequisites for the nftban firewall stack and installs/refreshes the nftban files themselves.  
It detects your distro, ensures the right packages are present (with proper command mapping), can fetch/update from GitHub or ZIP, provides status (with versions), and supports a safe uninstall flow.

---

## 🎯 What This Script Does

Provides a **single command** to prepare and manage the nftban environment:

| Component | Purpose |
|-----------|---------|
| **Package Ensure** | Installs/validates: `nftables`, `fail2ban`, `whois`, DNS tools (`dnsutils`/`bind-utils`/`bind-tools`), `ipcalc`, `sipcalc` |
| **Smart Detection** | Maps package keys → correct commands (`fail2ban-client`, `dig/host/nslookup`, etc.) |
| **Install Sources** | Install/refresh nftban files from **GitHub** or from a **ZIP** archive |
| **Status Report** | Clear status table (installed/missing + version) and optional `--json` output |
| **Auto-Update (optional)** | Cron-driven refresh, with `--auto-update-status` to inspect |
| **Uninstall** | Safe cleanup: removes symlink, target dir; can also purge logs/state |

---

## 🚀 Quick Start

```bash
# Recommended (GitHub fetch)
sudo ./nftban_init_rewrite.sh --github -y

# Keep it up to date daily at 03:30
sudo ./nftban_init_rewrite.sh --github -y --enable-auto-update --daily-time "03:30"
```

If GitHub is blocked:

```bash
sudo ./nftban_init_rewrite.sh --zip -y
```

Beginner mode (extra guidance):

```bash
sudo ./nftban_init_rewrite.sh --github -y --beginner
```

---

## 📋 Command-Line Options

```text
--github                    Install/refresh nftban from GitHub
--zip                       Install/refresh nftban from a ZIP archive
--target <dir>              Target directory (default: /etc/nftban)
--branch <name>             Git branch to use when fetching from GitHub

--status [--json]           Show overall status (packages, paths, versions)
--uninstall                 Uninstall nftban (safe removal)
--purge                     With --uninstall: also remove logs/state
--enable-auto-update        Enable daily auto-update via cron
--remove-auto-update        Disable auto-update and remove cron entries
--auto-update-status        Show whether auto-update is enabled and entries
--daily-time HH:MM          Schedule time for auto-update (with --enable-auto-update)

--beginner                  Friendlier, step-by-step output
--quiet                     Reduce console INFO logs
--dry-run                   Print the commands without executing
--no-color                  Disable ANSI colors
--no-unicode                Use ASCII instead of emoji/icons

-y                          Assume “yes” to prompts
-h, --help                  Show help
```

> Notes  
> • The script detects your package manager (**apt / dnf / yum / zypper / apk**).  
> • On RHEL-like systems, it can **enable EPEL** automatically if needed for `fail2ban`.  
> • DNS tools are mapped per distro (Debian/Ubuntu: `dnsutils`, RHEL/Fedora: `bind-utils`, Alpine: `bind-tools`).

---

## 💡 Usage Examples

```bash
# 1) Install from GitHub (idempotent)
sudo ./nftban_init_rewrite.sh --github -y

# 2) Install from ZIP (when GitHub access is limited)
sudo ./nftban_init_rewrite.sh --zip -y

# 3) Status only (human readable)
sudo ./nftban_init_rewrite.sh --status

# 4) Status as JSON (for CI/automation)
sudo ./nftban_init_rewrite.sh --status --json

# 5) Enable daily auto-update at 02:10
sudo ./nftban_init_rewrite.sh --enable-auto-update --daily-time "02:10"

# 6) Disable auto-update
sudo ./nftban_init_rewrite.sh --remove-auto-update

# 7) Safe uninstall (keep logs/state)
sudo ./nftban_init_rewrite.sh --uninstall -y

# 8) Full uninstall (purge logs/state)
sudo ./nftban_init_rewrite.sh --uninstall --purge -y
```

---

## 📦 Managed Package Set

| Key        | Debian/Ubuntu        | RHEL/Fedora             | Alpine         | Commands detected |
|------------|----------------------|-------------------------|----------------|-------------------|
| nftables   | `nftables`           | `nftables`              | `nftables`     | `nft`             |
| fail2ban   | `fail2ban`           | `fail2ban`              | `fail2ban`     | `fail2ban-client` |
| whois      | `whois`              | `whois`                 | `whois`        | `whois`           |
| dnsutils   | `dnsutils`           | `bind-utils`            | `bind-tools`   | `dig`, `host`, `nslookup` |
| ipcalc     | `ipcalc`             | `ipcalc`                | `ipcalc`*      | `ipcalc` (*or `ipcalc-ng`) |
| sipcalc    | `sipcalc`            | `sipcalc`               | `sipcalc`      | `sipcalc`         |

> *Some Alpine images ship `ipcalc-ng`; detection treats that as a valid `ipcalc` provider.

---

## 📊 Example Output

### Status Table
```
+-----------+--------------+-----------+-----------+
| Key       | Package      | Installed | Version   |
+-----------+--------------+-----------+-----------+
| nftables  | nftables     | yes       | 1.0.9     |
| fail2ban  | fail2ban     | yes       | 1.0.2     |
| whois     | whois        | yes       | 5.5.17    |
| dnsutils  | bind-utils   | yes       | 9.18.24   |
| ipcalc    | ipcalc       | no        | -         |
| sipcalc   | sipcalc      | no        | -         |
+-----------+--------------+-----------+-----------+
```

### Completion Summary
```
Summary:
  nftables        (already present)
  fail2ban        (already present)
  whois           (already present)
  dnsutils        (already present)
  ipcalc          (installed now)
  sipcalc         (installed now)
```

---

## ⚙️ Directory & Files

By default the script manages:

```
/etc/nftban/
├─ bin/
│  └─ nftban                 # main helper binary (managed by this installer)
├─ scripts/
│  └─ nftban_auto_update.sh  # cron-invoked update helper
└─ .version                  # installed version marker
/usr/local/bin/nftban -> /etc/nftban/bin/nftban  # symlink (created/removed as needed)
```

Systemd service is **not** installed by default; uninstall flow will remove an existing `nftban.service` if present.

---

## 🧪 Exit Codes

| Code | Meaning |
|------|--------|
| `0`  | Success (including “nothing to do”) |
| `1`  | Package manager or unrecoverable error |

---

## 🧠 Tips

- Safe to run multiple times (idempotent).  
- For non-interactive environments (Docker/CI) you may set:  
  `export DEBIAN_FRONTEND=noninteractive`
- Use `--dry-run` to preview actions without making changes.

---

## 📜 License

**Custom MIT-NoResale License v1.1**

- ✅ Free to use (personal & commercial)
- 🖊️ Attribution required
- 💰 No resale without permission
- ⚠️ No warranty

**SPDX:** `LicenseRef-CustomMIT-NoResale-1.1`

See [LICENSE.md](./LICENSE.md) for full text.

---

## 🤝 Contributing

1. Fork the repository  
2. Create a feature branch  
3. Test on both Debian and RHEL-based systems  
4. Submit a pull request

---

## 📞 Support

- **Issues:** [GitHub Issues](https://github.com/itcmsgr/nftban/issues)  
- **Author:** Antonios Voulvoulis (ITCMS Team)  
- **Website:** [https://itcms.gr](https://itcms.gr)

---

<p align="center">
  Made with ❤️ by <a href="https://itcms.gr">ITCMS</a>
</p>
