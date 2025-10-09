# 🧰 nftban_init_rewrite.sh – Package Bootstrapper

[![Version](https://img.shields.io/badge/version-3.1.0-blue.svg)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/license-CustomMIT--NoResale-lightgrey.svg)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-green.svg)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-Bash-orange.svg)](https://www.gnu.org/software/bash/)

---

## 📖 Overview

**`nftban_init_rewrite.sh`** is a **unified installation and maintenance script** that prepares the required environment for **nftban** and related firewall tools.

It automatically detects your Linux distribution, identifies the correct package manager, installs all required dependencies, verifies their presence and version, and can also **uninstall or cleanly remove** them later if needed.

Unlike simple “package checkers”, this script understands the difference between **package names** and **commands** across different Linux families and ensures your system is correctly equipped before you deploy `nftban`.

---

## ✨ Features

| Category | Description |
|-----------|--------------|
| 🧩 **Cross-Distribution Support** | Works seamlessly with `apt`, `dnf`, `yum`, and `apk` package managers. |
| 🔍 **Accurate Package Detection** | Matches package keys to actual executables (e.g., `fail2ban` → `fail2ban-client`, DNS tools → `dig`, `host`, `nslookup`). |
| ⚙️ **Unified Installation / Uninstallation** | Installs missing dependencies or removes managed packages safely. |
| 🧾 **Detailed Status Reporting** | Displays installed/missing state and version for each package in a clean table format. |
| 🧠 **Intelligent Mapping** | Automatically uses the correct package name per distro (`dnsutils`, `bind-utils`, `bind-tools`, etc.). |
| 📊 **Summary Output** | Shows which packages were installed now vs. already present. |
| 🔒 **Safe and Idempotent** | Re-running the script never breaks your setup — it only acts when necessary. |
| 🌐 **EPEL Auto-Enable (RHEL)** | Automatically enables the EPEL repository when required for `fail2ban`. |

---

## 📦 Managed Package Set

| Key        | Debian/Ubuntu | RHEL/Fedora | Alpine | Commands Detected |
|-------------|---------------|--------------|----------|-------------------|
| nftables   | nftables       | nftables     | nftables | `nft` |
| fail2ban   | fail2ban       | fail2ban     | fail2ban | `fail2ban-client` |
| whois      | whois          | whois        | whois    | `whois` |
| dnsutils   | dnsutils       | bind-utils   | bind-tools | `dig`, `host`, `nslookup` |
| ipcalc     | ipcalc         | ipcalc       | ipcalc or ipcalc-ng | `ipcalc` |
| sipcalc    | sipcalc        | sipcalc      | sipcalc  | `sipcalc` |

> 🛈 On Alpine Linux, `ipcalc-ng` is treated as a valid replacement for `ipcalc`.

---

## ⚙️ Requirements

- Root or sudo privileges  
- Internet access to your distro’s repositories  
- Supported Linux family: **Debian**, **Ubuntu**, **RHEL**, **Fedora**, **AlmaLinux**, **Rocky**, or **Alpine**

---

## 🚀 Quick Start

```bash
chmod +x nftban_init_rewrite.sh

# Install all required dependencies
sudo ./nftban_init_rewrite.sh --install -y

# View package status
sudo ./nftban_init_rewrite.sh --status

# Uninstall managed packages
sudo ./nftban_init_rewrite.sh --uninstall
```

To run non-interactively (e.g. CI pipelines or Docker builds):

```bash
export DEBIAN_FRONTEND=noninteractive
sudo ./nftban_init_rewrite.sh --install --yes --quiet
```

---

## 🧭 Command-Line Options

| Option | Description |
|--------|--------------|
| `--install` | Install all missing required packages. |
| `--uninstall` | Offer to remove installed packages. |
| `--purge` | With `--uninstall`: remove residual files or states. |
| `--status` | Show current installation status and versions. |
| `--status --json` | Show status in JSON format for automation. |
| `--quiet` | Suppress informational logs; keep warnings/errors. |
| `--dry-run` | Print what would happen, without executing. |
| `--beginner` | Show extra hints during operation. |
| `--no-color` | Disable ANSI color output. |
| `--no-unicode` | Disable emoji/icons for minimal terminals. |
| `-y, --yes` | Assume “yes” to all prompts. |
| `-h, --help` | Display help message and exit. |

---

## 📊 Example Output

### ✅ Status Table

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

### 📜 Summary

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

## 🧪 JSON Status Example

```bash
sudo ./nftban_init_rewrite.sh --status --json | jq
```

```json
{
  "packages": [
    {"key": "nftables", "pkg": "nftables", "installed": true, "version": "1.0.9"},
    {"key": "fail2ban", "pkg": "fail2ban", "installed": true, "version": "1.0.2"},
    {"key": "ipcalc", "pkg": "ipcalc", "installed": false, "version": null}
  ],
  "summary": {
    "installed_now": ["ipcalc", "sipcalc"],
    "already_present": ["nftables", "fail2ban", "dnsutils"]
  }
}
```

---

## 🧹 Uninstallation

Safely remove managed packages only:

```bash
sudo ./nftban_init_rewrite.sh --uninstall
```

For a complete cleanup (including logs/state files if managed):

```bash
sudo ./nftban_init_rewrite.sh --uninstall --purge -y
```

> ⚠️ The script never touches unrelated system packages or services.  
> It only manages the tools explicitly listed in its package set.

---

## 🧩 Detection Logic

Some Linux families name packages and binaries differently:

| Logical Key | Executable | Example Package |
|--------------|-------------|----------------|
| fail2ban | fail2ban-client | fail2ban |
| dnsutils | dig, host, nslookup | dnsutils / bind-utils / bind-tools |
| ipcalc | ipcalc / ipcalc-ng | ipcalc |

The script maps these internally, ensuring accurate detection across all supported distributions.

---

## 🧱 Exit Codes

| Code | Meaning |
|------|----------|
| `0` | Success (including “nothing to do”) |
| `1` | Package manager or installation failure |

---

## 🧰 Troubleshooting

- Run `sudo ./nftban_init_rewrite.sh --status` to verify installation.  
- Check tool versions manually:
  - `nft --version`
  - `fail2ban-client -V`
  - `dig -v`
- Logs (if enabled): `/var/log/nftban/nftban_init_rewrite_*.log`

---

## 🔒 Safety Notes

- No services are started, stopped, or enabled automatically.  
- No permanent system configuration is changed beyond package management.  
- Safe to rerun anytime — idempotent operations ensure consistent state.

---

## 🤝 Contributing

Contributions are welcome!  
If you find distro-specific mismatches or missing packages:

1. Fork this repository.  
2. Edit or extend the `cmds_for_pkg()` and `detect_pm()` mappings.  
3. Test on at least one Debian-based and one RHEL-based system.  
4. Submit a pull request.

---

## 🧾 License

**Custom MIT-NoResale License v1.1**

- ✅ Free for personal and commercial use  
- ✏️ Attribution required  
- 💰 Resale prohibited without author permission  
- ⚠️ No warranty  

**SPDX:** `LicenseRef-CustomMIT-NoResale-1.1`

See [LICENSE.md](./LICENSE.md) for full text.

---

## 📞 Contact & Support

- **Issues:** [GitHub Issues](https://github.com/itcmsgr/nftban/issues)  
- **Author:** Antonios Voulvoulis — ITCMS Team  
- **Website:** [https://itcms.gr](https://itcms.gr)  

---

<p align="center">
  Made with ❤️ by <a href="https://itcms.gr">ITCMS</a> &nbsp;|&nbsp; Unified Automation for nftban
</p>
