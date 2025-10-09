# nftban_init_nftables_conf.sh

**Single-table nftables configuration initializer with Fail2ban integration**

[![Version](https://img.shields.io/badge/version-2.2.0-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A production-ready Bash script that initializes a simplified, single-table nftables firewall architecture with built-in support for Fail2ban integration, IP whitelisting/blacklisting, and automated validation.

---

## 🎯 What This Script Does

Creates and manages a **single nftables table** (`inet nftban_global`) with:

| Component | Purpose |
|-----------|---------|
| **6 IP Sets** | Whitelists, blacklists (user/system), and temporary bans (Fail2ban) |
| **2 Chains** | Input filtering (priority -150) and optional output filtering |
| **Validation** | Multi-tier IP/port validation (ipcalc/sipcalc → nft -c → regex) |
| **Safety** | Auto-whitelists your IPs, SSH protection, rollback support |
| **Testing** | Built-in unit tests and dry-run modes |

### Created nftables Objects

```
table inet nftban_global {
  set whitelist_v4        # Never ban these IPv4 addresses
  set whitelist_v6        # Never ban these IPv6 addresses
  set user_blacklist_v4   # Manual permanent IPv4 bans
  set user_blacklist_v6   # Manual permanent IPv6 bans
  set system_blacklist_v4 # Bulk IPv4 bans (countries, ranges)
  set system_blacklist_v6 # Bulk IPv6 bans (countries, ranges)
  set temp_ban_v4         # Fail2ban temporary IPv4 bans (with timeout)
  set temp_ban_v6         # Fail2ban temporary IPv6 bans (with timeout)
  
  chain input { ... }     # Processes incoming traffic
  chain output { ... }    # Optional outbound filtering
}
```

**Priority order (input chain):**
1. Loopback → accept
2. Whitelist → accept
3. Blacklists → drop
4. Temp bans (Fail2ban) → drop
5. Established/related → accept
6. SSH → accept
7. User-defined ports → accept
8. Custom CT rules → process

---

## 🚀 Quick Start

### Prerequisites

**Debian/Ubuntu:**
```bash
sudo apt install -y nftables ipcalc sipcalc fail2ban
sudo systemctl enable --now nftables
```

**RHEL/CentOS/AlmaLinux/Rocky/Fedora:**
```bash
sudo dnf install -y epel-release
sudo dnf install -y nftables ipcalc sipcalc fail2ban
sudo systemctl enable --now nftables
```

### Basic Usage

```bash
# Download script
curl -fsSL -O https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_nftables_conf.sh
chmod +x nftban_init_nftables_conf.sh

# Run interactively
sudo ./nftban_init_nftables_conf.sh

# Or apply directly
sudo ./nftban_init_nftables_conf.sh --install-final
```

---

## 📋 Command-Line Options

```bash
Usage: nftban_init_nftables_conf.sh [options]

Configuration:
  --cloudflare [yes|no|auto]  Include Cloudflare IPs in whitelist (default: auto)
  --yes-cloudflare            Shortcut for --cloudflare yes
  --no-cloudflare             Shortcut for --cloudflare no
  -y                          Non-interactive mode (assume yes)

Execution:
  --install-final             Apply config to /etc/nftables.conf and activate
  --silent-auto               Silent mode with auto-confirmation
  
Validation & Testing:
  --validate-only             Validate config files without applying
  --dry-run                   Preview generated config without applying
  --test                      Syntax check only (nft -c), no changes
  --run-tests                 Run built-in unit tests and exit

Fail2ban:
  --generate-f2b-action       Generate Fail2ban action configuration

Help:
  -h, --help                  Show help message
```

---

## 💡 Usage Examples

### Test & Validate

```bash
# Run unit tests
sudo ./nftban_init_nftables_conf.sh --run-tests

# Validate existing configuration
sudo ./nftban_init_nftables_conf.sh --validate-only

# Syntax check only (no apply)
sudo ./nftban_init_nftables_conf.sh --test

# Preview generated config
sudo ./nftban_init_nftables_conf.sh --dry-run
```

### Generate & Apply

```bash
# Interactive mode
sudo ./nftban_init_nftables_conf.sh

# Apply without prompts
sudo ./nftban_init_nftables_conf.sh --install-final -y

# Silent install with Cloudflare IPs
sudo ./nftban_init_nftables_conf.sh --silent-auto --yes-cloudflare --install-final
```

### Fail2ban Integration

```bash
# Generate Fail2ban action files
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action

# This creates:
# /etc/fail2ban/action.d/nftban-global.conf
# /etc/fail2ban/action.d/nftban-global-jail-example.conf
```

Then configure jails in `/etc/fail2ban/jail.local`:
```ini
[sshd]
enabled = true
banaction = nftban-global[name=sshd, set="temp_ban_v4"]
```

---

## 🔧 Configuration Files

The script uses these config files in `/etc/nftban/config/`:

| File | Purpose |
|------|---------|
| `nftban-configuration-ipv4-ports-input-allow.conf.local` | IPv4 input ports (format: `22T`, `80-443B`) |
| `nftban-configuration-ipv4-ports-output-allow.conf.local` | IPv4 output ports |
| `nftban-configuration-ipv6-ports-input-allow.conf.local` | IPv6 input ports |
| `nftban-configuration-ipv6-ports-output-allow.conf.local` | IPv6 output ports |
| `nftban-configuration-user-whitelist_ips.conf.local` | User-defined whitelist |
| `nftban-configuration-user-blacklist_ips.conf.local` | User-defined blacklist |
| `nftban-configuration-ipv4-blacklist_ips.conf.local` | System IPv4 blacklist |
| `nftban-configuration-ipv6-blacklist_ips.conf.local` | System IPv6 blacklist |
| `nftban-configuration-system_whitelist_ips.conf.local` | Auto-generated system whitelist |
| `nftban-nfttables-ct-ipv4.conf.local` | Custom IPv4 connection tracking rules |
| `nftban-nfttables-ct-ipv6.conf.local` | Custom IPv6 connection tracking rules |

### Port Configuration Format

```bash
# Format: PORTRANGE?PROTOCOL
# Protocol: T=TCP, U=UDP, B=Both

22T            # TCP port 22
80-443B        # TCP+UDP ports 80-443
53U            # UDP port 53
3000-3010T     # TCP ports 3000-3010
```

### IP Configuration Format

```bash
# IPv4
192.168.1.10              # Single IP
192.168.1.0/24            # CIDR
192.168.1.1-192.168.1.254 # Range

# IPv6
2001:db8::1               # Single IP
2001:db8::/48             # CIDR
2001:db8::1-2001:db8::ff  # Range
```

---

## 🧪 Features

### Multi-Tier IP Validation

1. **External tools** (if available): `ipcalc` for IPv4, `sipcalc` for IPv6
2. **nft -c validation**: Syntax check via nftables compiler
3. **Regex + bounds**: Strict fallback validation

### Auto-Whitelisting

Automatically adds to whitelist:
- All server interface IPs (IPv4/IPv6)
- Server's public IP (if detectable)
- Current SSH connection IP (prevents lockout)
- Cloudflare IPs (optional)

### Safety Features

- Lock file prevents concurrent runs
- Automatic backups before changes
- Syntax validation before applying
- Rollback support on failure
- SSH port auto-detection

### Testing & Validation

- **Unit tests**: Test IP/port validators, rule generators
- **Syntax check**: `nft -c` validation without applying
- **Dry run**: Preview generated configuration
- **Config validation**: Check all config files

---

## 📊 Manual IP Management

```bash
# Whitelist IP (never ban)
sudo nft add element inet nftban_global whitelist_v4 { 192.168.1.10 }

# Blacklist IP (permanent)
sudo nft add element inet nftban_global user_blacklist_v4 { 203.0.113.45 }

# Temporary ban (1 hour)
sudo nft add element inet nftban_global temp_ban_v4 { 203.0.113.88 timeout 1h }

# Remove from set
sudo nft delete element inet nftban_global temp_ban_v4 { 203.0.113.88 }

# List set contents
sudo nft list set inet nftban_global whitelist_v4
sudo nft list set inet nftban_global temp_ban_v4

# Flush temporary bans
sudo nft flush set inet nftban_global temp_ban_v4
sudo nft flush set inet nftban_global temp_ban_v6
```

---

## 🔍 Verification

```bash
# View entire table
sudo nft list table inet nftban_global

# View specific sets
sudo nft list set inet nftban_global whitelist_v4
sudo nft list set inet nftban_global temp_ban_v4

# View chains
sudo nft list chain inet nftban_global input

# Check if table exists
sudo nft list tables | grep nftban_global
```

---

## 🐛 Troubleshooting

### Script locked

```bash
sudo rm -f /var/run/nftban_init.lock
```

### Missing dependencies

```bash
# Debian/Ubuntu
sudo apt install -y nftables ipcalc sipcalc

# RHEL/CentOS/Fedora
sudo dnf install -y epel-release nftables ipcalc sipcalc
```

### Configuration not persisting

```bash
# Enable nftables service
sudo systemctl enable nftables

# Save ruleset
sudo nft list ruleset > /etc/nftables.conf
```

### Locked out

**Prevention:** Script auto-whitelists your IP, but if locked out:
1. Access via console (KVM/IPMI)
2. Restore backup: `sudo nft -f /etc/nftables.conf.backup`
3. Flush rules: `sudo nft flush ruleset`

---

## 📁 Directory Structure

```
/etc/nftban/
├── config/
│   ├── *.conf.local              # Configuration files
│   └── nft_rules.conf.local      # Generated ruleset
├── templates/                     # Template files
├── backups/                       # Automatic backups
└── logs/                          # Validation logs
    └── validation_YYYY-MM-DD.log
```

---

## ⚙️ Technical Details

**Script Version:** 2.2.0  
**Shell:** Bash (requires Bash 4.0+)  
**Dependencies:** `nft`, `ip`, `awk`, `grep`, `sed`, `flock`  
**Optional:** `ipcalc`, `sipcalc`, `curl`, `wget`

**Compatibility:**
- ✅ Debian 10+
- ✅ Ubuntu 20.04+
- ✅ CentOS 8+
- ✅ AlmaLinux 8+
- ✅ Rocky Linux 8+
- ✅ Fedora 35+
- ✅ RHEL 8+

**Kernel Requirements:** Linux 4.18+ (for full nftables features)

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

## 🔗 Related Scripts

This is part of the **nftban** toolkit. Other scripts in the repository:
- `nftban` - Main management CLI
- `nftban-fail2ban-sync.sh` - Fail2ban synchronization
- Additional firewall management utilities

Each script has its own focused documentation.

---

<p align="center">
  Made with ❤️ by <a href="https://itcms.gr">ITCMS</a>
</p>
