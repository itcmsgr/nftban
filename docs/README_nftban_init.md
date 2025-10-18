# nftban_init.sh - System Preparation & Installation

**Bootstrap script for nftban firewall management system**

[![Version](https://img.shields.io/badge/version-0.9.0--beta-orange)](https://github.com/itcmsgr/nftban)
[![Architecture](https://img.shields.io/badge/v0.9.0-dual--table-orange)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](../LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

> **Part of the nftban toolkit** - This document covers the system preparation script. See [Main README](../README.md) for the complete project overview.
>
> **📌 v0.9.0 Note**: This init script prepares the system for nftban v0.9.0's dual-table architecture. The subsequent configuration scripts will create `ip nftban_v4` and `ip6 nftban_v6` tables. See [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md) for architecture details.

```bash
# Quick install from GitHub
sudo ./nftban_init.sh --github -y

# Quick install from ZIP
sudo ./nftban_init.sh --zip -y

# With auto-update enabled
sudo ./nftban_init.sh --github -y --enable-auto-update --daily-time "03:30"
```

---

## 📋 Table of Contents

- [What is nftban_init.sh?](#-what-is-nftban_initsh)
- [Key Features](#-key-features)
- [Quick Start](#-quick-start)
- [Installation Methods](#-installation-methods)
- [Command-Line Options](#-command-line-options)
- [What It Does](#-what-it-does)
- [Control Panel Detection](#-control-panel-detection)
- [Package Management](#-package-management)
- [Directory Structure](#-directory-structure)
- [IP Validation](#-ip-validation)
- [Auto-Update System](#-auto-update-system)
- [Usage Examples](#-usage-examples)
- [Configuration Files Created](#-configuration-files-created)
- [System Requirements](#-system-requirements)
- [Troubleshooting](#-troubleshooting)
- [Integration](#-integration)
- [License](#-license)
- [Support](#-support)

---

## 🎯 What is nftban_init.sh?

`nftban_init.sh` is the **first component** of the nftban security suite. It's a comprehensive installation and maintenance script that prepares your Linux server for nftban deployment.

### Purpose

This script handles the **foundation** of your security setup:

- ✅ Installs required packages (nftables, fail2ban, utilities)
- ✅ Creates complete directory structure
- ✅ Detects control panels automatically (DirectAdmin, cPanel, Plesk)
- ✅ Generates configuration templates
- ✅ Sets up IP validation tools (ipcalc, sipcalc)
- ✅ Configures optional auto-updates
- ✅ Creates the nftban CLI tool
- ✅ Never starts services automatically (you stay in control)

### When to Use

- **First-time setup** on a new server
- **Reinstallation** after system changes
- **Updates** to get latest features
- **Configuration refresh** to regenerate templates

### What It Doesn't Do

- ❌ Does NOT configure firewall rules (use `nftban_init_nftables_conf.sh`)
- ❌ Does NOT setup Fail2Ban (use `nftban_init_fail2ban_conf.sh`)
- ❌ Does NOT enable/start services automatically
- ❌ Does NOT modify existing firewall rules

---

## ✨ Key Features

### 🚀 Three Installation Methods

| Method | Speed | Use Case | Requirements |
|--------|-------|----------|--------------|
| **GitHub** | Fast | Production, Development | Git installed |
| **ZIP** | Medium | Git-blocked networks | curl, unzip |
| **Local** | Instant | Air-gapped systems | None |

### 🎛️ Smart Control Panel Detection

```
Automatic Detection & Configuration
├── DirectAdmin (/usr/local/directadmin/)
│   └── Ports: 2222, 21, 35000-35999, Email, DNS
├── cPanel/WHM (/var/cpanel/)
│   └── Ports: 2082-2087, 2095-2096, MySQL, Email, DNS
├── Plesk (/usr/local/psa/)
│   └── Ports: 8443, 8880, MySQL, PostgreSQL, Email
└── Generic (No panel)
    └── Ports: SSH (auto-detect), 80, 443, DNS, NTP
```

### 🔧 Universal Package Management

Supports all major Linux distributions:
- **Debian/Ubuntu**: `apt-get`
- **RHEL/CentOS/Rocky/Alma**: `dnf`/`yum` (with EPEL)
- **Fedora**: `dnf`
- **openSUSE**: `zypper`
- **Alpine**: `apk`

### 🛡️ Enhanced IP Validation

- **ipcalc**: Primary IPv4 validation tool
- **sipcalc**: Enhanced IPv6 validation
- **Regex fallback**: Works even without tools
- **CIDR support**: Validates network ranges (192.168.1.0/24)
- **Statistics**: Shows validation results during setup

### 🔄 Auto-Update System

```bash
# Enable auto-updates (every 12 hours)
sudo ./nftban_init.sh --enable-auto-update

# Schedule daily at specific time
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"

# Check status
sudo ./nftban_init.sh --auto-update-status

# Remove auto-updates
sudo ./nftban_init.sh --remove-auto-update
```

### 📊 Status Reporting

```bash
# Human-readable status
sudo ./nftban_init.sh --status

# JSON output for automation
sudo ./nftban_init.sh --status --json
```

### 🔒 Safety Features

- ✅ Automatic backups before changes
- ✅ Dry-run mode for testing
- ✅ Version tracking
- ✅ Validation before applying
- ✅ Cannot break existing setup
- ✅ Rollback capability

---

## 🚀 Quick Start

### One-Line Install (Recommended)

```bash
# From GitHub (always latest)
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# From ZIP (if GitHub blocked)
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --zip -y
```

### Standard Install (Three Steps)

```bash
# Step 1: Download script
wget https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh
chmod +x nftban_init.sh

# Step 2: Run installation
sudo ./nftban_init.sh --github -y

# Step 3: Verify installation
sudo nftban --version
ls -la /etc/nftban/
```

### With Auto-Update

```bash
# Enable auto-update during install
sudo ./nftban_init.sh --github -y --enable-auto-update

# Or enable after installation
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"
```

---

## 🔧 Installation Methods

### Method 1: GitHub Clone (Recommended)

**Advantages:**
- Always gets latest version
- Easy updates (git pull)
- Full repository history
- Best for development

**Installation:**
```bash
sudo ./nftban_init.sh --github -y
```

**What happens:**
1. Checks for git, installs if needed
2. Clones repository to `/etc/nftban/`
3. Sets up for future updates
4. Runs post-installation tasks

**Update later:**
```bash
cd /etc/nftban
sudo git pull
```

### Method 2: ZIP Download

**Advantages:**
- Works without git
- Faster download
- Good for restricted networks
- One-time setup

**Installation:**
```bash
sudo ./nftban_init.sh --zip -y
```

**What happens:**
1. Downloads ZIP archive
2. Extracts to `/etc/nftban/`
3. Removes archive
4. Runs post-installation tasks

**Update later:**
```bash
sudo ./nftban_init.sh --zip -y  # Re-download and extract
```

### Method 3: Local Installation

**Advantages:**
- No network needed
- Air-gapped systems
- Manual control
- Quick setup

**Installation:**
```bash
sudo ./nftban_init.sh -y
# Or interactive mode
sudo ./nftban_init.sh
```

**What happens:**
1. Creates directory structure
2. Installs packages
3. Creates basic configuration
4. No repository sync

---

## 📝 Command-Line Options

### Installation Options

| Option | Description | Example |
|--------|-------------|---------|
| `--github` | Install from GitHub repository | `--github` |
| `--zip` | Install from ZIP archive | `--zip` |
| `--target DIR` | Custom installation directory | `--target /opt/nftban` |
| `--branch NAME` | Git branch to use | `--branch develop` |
| `-y` | Assume yes to all prompts | `-y` |

### Control Panel Options

| Option | Description | Example |
|--------|-------------|---------|
| `--skip-cp-detect` | Skip control panel detection | `--skip-cp-detect` |

### Auto-Update Options

| Option | Description | Example |
|--------|-------------|---------|
| `--enable-auto-update` | Enable cron-based updates | `--enable-auto-update` |
| `--remove-auto-update` | Disable auto-updates | `--remove-auto-update` |
| `--auto-update-status` | Show auto-update status | `--auto-update-status` |
| `--daily-time HH:MM` | Schedule daily update time | `--daily-time "03:30"` |

### Status & Maintenance Options

| Option | Description | Example |
|--------|-------------|---------|
| `--status` | Show system status | `--status` |
| `--json` | Output in JSON format | `--status --json` |
| `--version` | Show version information | `--version` |

### Uninstall Options

| Option | Description | Example |
|--------|-------------|---------|
| `--uninstall` | Remove nftban | `--uninstall -y` |
| `--purge` | Remove logs and state | `--uninstall --purge -y` |

### Advanced Options

| Option | Description | Example |
|--------|-------------|---------|
| `--dry-run` | Preview without changes | `--dry-run --github` |
| `--quiet` | Suppress non-error output | `--quiet --github -y` |
| `--beginner` | Friendlier output | `--beginner --github` |
| `--no-color` | Disable colored output | `--no-color` |
| `--no-unicode` | Use ASCII instead of Unicode | `--no-unicode` |

---

## 🔍 What It Does

### Phase 1: Pre-Installation Checks

```
1. Root privilege check
   └── Ensures script runs with sudo/root

2. Package manager detection
   └── Identifies: apt-get, dnf, yum, zypper, or apk

3. Network connectivity check
   └── Verifies access to GitHub/download sources

4. Version check
   └── Compares installed vs available versions
```

### Phase 2: System Preparation

```
1. Backup existing installation (if present)
   ├── Creates timestamped backup: /var/backups/nftban_YYYYMMDD_HHMMSS.tgz
   └── Preserves all configuration and data

2. Create directory structure
   ├── /etc/nftban/
   │   ├── config/          # Configuration files
   │   ├── scripts/         # Management scripts
   │   ├── templates/       # Control panel templates
   │   ├── bin/            # CLI tool
   │   ├── rules/          # Custom rules
   │   ├── conf.d/         # Additional configs
   │   └── systemd/        # Service files
   └── /var/log/nftban/    # Log files
```

### Phase 3: Package Installation

```
1. Update package cache (apt-get only)
2. Install EPEL repository (RHEL-like systems)
3. Install required packages:
   ├── nftables           # Firewall engine
   ├── fail2ban          # Intrusion prevention
   ├── whois             # IP lookup
   ├── dnsutils/bind-utils  # DNS tools
   ├── ipcalc            # IP validation
   └── sipcalc           # IPv6 validation
4. Verify installations
```

### Phase 4: Control Panel Detection

```
1. Check for control panels
   ├── DirectAdmin: /usr/local/directadmin/
   ├── cPanel: /var/cpanel/
   ├── Plesk: /usr/local/psa/
   └── Generic: (none found)

2. Load appropriate template
   ├── Contains pre-configured ports
   └── Optimized for panel requirements

3. Process configuration
   ├── Generate port files
   │   ├── IPv4 input/output ports
   │   └── IPv6 input/output ports
   └── Create IP whitelist
       └── Validates all IPs during processing
```

### Phase 5: IP Validation Setup

```
1. Verify ipcalc installation
   └── Primary tool for IPv4 validation

2. Verify sipcalc installation
   └── Enhanced IPv6 support

3. Configure validation mode
   ├── Tools available: Use ipcalc/sipcalc
   └── Tools unavailable: Regex fallback

4. Test validation
   └── Sample IP checks to ensure functionality
```

### Phase 6: Tool Creation

```
1. Create nftban CLI binary
   ├── Source: Repository or stub
   ├── Location: /etc/nftban/bin/nftban
   └── Symlink: /usr/local/bin/nftban

2. Set permissions
   ├── Make scripts executable
   └── Set proper ownership

3. SELinux context (if enabled)
   └── Restore security contexts
```

### Phase 7: Auto-Update (Optional)

```
1. Create update script
   └── /etc/nftban/scripts/nftban_auto_update.sh

2. Add cron entry
   ├── Default: Every 12 hours
   └── Custom: Daily at specified time

3. Verify cron service
   └── Check if cron/crond is active
```

### Phase 8: Post-Installation

```
1. Create version file
   └── /etc/nftban/.version

2. Generate completion summary
   ├── Packages installed
   ├── Configuration files created
   ├── Control panel detected
   └── Next steps

3. Create log file
   └── /var/log/nftban/nftban_init_YYYYMMDD_HHMMSS_PID.log
```

---

## 🎛️ Control Panel Detection

### How Detection Works

```bash
# DirectAdmin detection
if [ -d "/usr/local/directadmin/" ]; then
    PANEL="directadmin"
fi

# cPanel detection
if [ -d "/var/cpanel/" ]; then
    PANEL="cpanel"
fi

# Plesk detection
if [ -d "/usr/local/psa/" ]; then
    PANEL="plesk"
fi
```

### DirectAdmin Configuration

**Auto-detected ports:**
```
TCP_IN="2222,80,443,21,25,587,465,993,995,110,143"
TCP_OUT="53,80,443,21,25,587"
TCP6_IN="2222,80,443,25,587,465,993,995,110,143"
TCP6_OUT="53,80,443,25,587"
IP_ADDRESS=""  # Your IPs here
```

**What gets configured:**
- SSH: 2222 (DirectAdmin default)
- Web: 80, 443
- FTP: 21, 35000-35999 (passive range)
- Email: 25, 587, 465, 993, 995, 110, 143
- DNS: 53

### cPanel/WHM Configuration

**Auto-detected ports:**
```
TCP_IN="22,80,443,2082,2083,2086,2087,2095,2096,21,25,587,465,993,995,110,143"
TCP_OUT="53,80,443,2089,25,587"
TCP6_IN="22,80,443,2082,2083,2086,2087,2095,2096,25,587,465,993,995,110,143"
TCP6_OUT="53,80,443,25,587"
IP_ADDRESS=""
```

**What gets configured:**
- SSH: 22
- cPanel: 2082 (HTTP), 2083 (HTTPS)
- WHM: 2086 (HTTP), 2087 (HTTPS)
- Webmail: 2095 (HTTP), 2096 (HTTPS)
- Email, FTP, DNS: Standard ports

### Plesk Configuration

**Auto-detected ports:**
```
TCP_IN="22,80,443,8443,8880,21,25,587,465,993,995,110,143,3306,5432"
TCP_OUT="53,80,443,25,587"
TCP6_IN="22,80,443,8443,8880,25,587,465,993,995,110,143"
TCP6_OUT="53,80,443,25,587"
IP_ADDRESS=""
```

**What gets configured:**
- SSH: 22
- Plesk Panel: 8443 (HTTPS)
- Plesk Webmail: 8880
- Databases: 3306 (MySQL), 5432 (PostgreSQL)
- Email, FTP, DNS: Standard ports

### Generic Configuration

**Auto-detected ports:**
```bash
# SSH port auto-detected from /etc/ssh/sshd_config
SSH_PORT=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
# Falls back to 22 if not found

TCP_IN="<SSH_PORT>,80,443"
TCP_OUT="53,80,443,123"
TCP6_IN="<SSH_PORT>,80,443"
TCP6_OUT="53,80,443,123"
IP_ADDRESS=""
```

**What gets configured:**
- SSH: Auto-detected or 22
- Web: 80, 443
- DNS: 53
- NTP: 123

### Skipping Detection

```bash
# Skip control panel detection
sudo ./nftban_init.sh --github -y --skip-cp-detect

# Creates empty configuration files
# Manual configuration required
```

---

## 📦 Package Management

### Supported Package Managers

| Distribution | Package Manager | Command |
|--------------|----------------|---------|
| Debian/Ubuntu | apt-get | `apt-get install -y` |
| RHEL/CentOS | dnf/yum | `dnf install -y` |
| Rocky/AlmaLinux | dnf | `dnf install -y` |
| Fedora | dnf | `dnf install -y` |
| openSUSE | zypper | `zypper install -y` |
| Alpine | apk | `apk add --no-cache` |

### Package Installation Process

```
1. Detect package manager
   └── Checks: apt-get, dnf, yum, zypper, apk

2. Update package cache (apt-get only)
   └── apt-get update -y

3. Install EPEL (RHEL-like systems)
   ├── Check if EPEL already installed
   ├── Try: dnf/yum install epel-release
   └── Fallback: Direct RPM download

4. Install packages sequentially
   ├── nftables
   ├── fail2ban
   ├── whois
   ├── dnsutils/bind-utils
   ├── ipcalc
   └── sipcalc (optional)

5. Verify installations
   └── Check each command: nft, fail2ban-client, whois
```

### Package Naming Differences

| Package | Debian/Ubuntu | RHEL/CentOS | Alpine |
|---------|---------------|-------------|--------|
| DNS Utils | dnsutils | bind-utils | bind-tools |
| IP Calc | ipcalc | ipcalc | ipcalc |
| SIP Calc | sipcalc | sipcalc | sipcalc |

### EPEL Repository

**Why needed:**
- Required for fail2ban on RHEL-like systems
- Required for sipcalc on RHEL-like systems

**Installation methods:**
```bash
# Method 1: Package manager
dnf install -y epel-release

# Method 2: Direct RPM (fallback)
# Detected OS version: 8 or 9
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
```

### Package Verification

```bash
# After installation, script verifies:
command -v nft >/dev/null 2>&1           # nftables
command -v fail2ban-client >/dev/null    # fail2ban
command -v whois >/dev/null              # whois
command -v dig >/dev/null                # dnsutils
command -v ipcalc >/dev/null             # ipcalc (preferred)
command -v sipcalc >/dev/null            # sipcalc (optional)
```

---

## 📁 Directory Structure

### Complete Layout

```
/etc/nftban/
├── config/                          # Configuration files
│   ├── nftban-configuration-ipv4-ports-input-allow.conf       # Base IPv4 input
│   ├── nftban-configuration-ipv4-ports-input-allow.conf.local # User IPv4 input
│   ├── nftban-configuration-ipv4-ports-output-allow.conf      # Base IPv4 output
│   ├── nftban-configuration-ipv4-ports-output-allow.conf.local # User IPv4 output
│   ├── nftban-configuration-ipv6-ports-input-allow.conf       # Base IPv6 input
│   ├── nftban-configuration-ipv6-ports-input-allow.conf.local # User IPv6 input
│   ├── nftban-configuration-ipv6-ports-output-allow.conf      # Base IPv6 output
│   ├── nftban-configuration-ipv6-ports-output-allow.conf.local # User IPv6 output
│   ├── nftban-configuration-user-whitelist_ips.conf           # Base whitelist
│   ├── nftban-configuration-user-whitelist_ips.conf.local     # User whitelist
│   ├── nftban-configuration-user-blacklist_ips.conf           # Base blacklist
│   ├── nftban-configuration-user-blacklist_ips.conf.local     # User blacklist
│   ├── nftban-configuration-f2b-ips_temp-blacklists_conf.local # Fail2Ban temp bans
│   ├── nft_rules.conf                   # Generated nftables rules (base)
│   ├── nft_rules.conf.local             # Generated nftables rules (user)
│   ├── nftban.conf                      # Fail2Ban base config
│   └── nftban.conf.local                # Fail2Ban user config
│
├── scripts/                         # Management scripts
│   ├── nftban_init.sh              # This script
│   ├── nftban_init_nftables_conf.sh # Firewall configuration
│   ├── nftban_init_fail2ban_conf.sh # Fail2Ban setup
│   ├── nftban_auto_update.sh       # Auto-update script (if enabled)
│   └── [other utility scripts]
│
├── templates/                       # Configuration templates
│   └── control-panels/
│       ├── directadmin.conf        # DirectAdmin template
│       ├── cpanel.conf             # cPanel template
│       ├── plesk.conf              # Plesk template
│       └── generic.conf            # Generic server template
│
├── bin/                            # Binaries
│   └── nftban                      # CLI tool
│
├── rules/                          # Custom rules (future use)
│
├── conf.d/                         # Additional configurations
│
├── systemd/                        # Systemd service files
│   └── nftban.service             # Service definition (if repo provides)
│
├── logs -> /var/log/nftban/       # Symlink to logs
│
├── backups/                        # Backup storage
│
└── .version                        # Version tracking file

/var/log/nftban/                    # Log files
├── nftban_init_YYYYMMDD_HHMMSS_PID.log  # Init logs
├── nftban_nftables_YYYYMMDD_HHMMSS.log  # Firewall logs
├── nftban_fail2ban_YYYYMMDD_HHMMSS.log  # Fail2Ban logs
└── cp_detection_YYYYMMDD_HHMMSS.log     # Control panel detection logs

/var/backups/                       # System backups
└── nftban_YYYYMMDD_HHMMSS.tgz     # Timestamped backups

/usr/local/bin/                     # Global binaries
└── nftban -> /etc/nftban/bin/nftban    # Symlink to CLI tool
```

### File Permissions

```bash
# Directories
chmod 0755 /etc/nftban/
chmod 0755 /etc/nftban/{config,scripts,templates,bin,rules,conf.d,systemd}
chmod 0755 /var/log/nftban/

# Log files
chmod 0640 /var/log/nftban/*.log

# Scripts
chmod 0755 /etc/nftban/scripts/*.sh
chmod 0755 /etc/nftban/bin/nftban
```

### Symlinks

```bash
# Logs symlink
/etc/nftban/logs -> /var/log/nftban/

# CLI symlink
/usr/local/bin/nftban -> /etc/nftban/bin/nftban
```

---

## ✅ IP Validation

### Validation Tools

#### ipcalc (Primary for IPv4)

**Features:**
- Validates IPv4 addresses
- Supports CIDR notation
- Calculates network information
- Validates subnet masks

**Usage:**
```bash
# Validate single IP
ipcalc -c 192.168.1.1

# Validate CIDR
ipcalc -c 192.168.1.0/24

# Get detailed info
ipcalc 192.168.1.100/24
```

#### sipcalc (Enhanced for IPv6)

**Features:**
- Validates IPv6 addresses
- Validates IPv4 addresses
- Extensive network calculations
- Multiple output formats

**Usage:**
```bash
# Validate IPv6
sipcalc 2001:db8::1

# Validate IPv6 CIDR
sipcalc 2001:db8::/32

# Validate IPv4
sipcalc 192.168.1.1
```

### Validation Modes

```bash
# Auto mode (default)
# Uses ipcalc if available, sipcalc as fallback, regex as last resort
IP_VALIDATION_MODE="auto"

# Force specific tool
IP_VALIDATION_MODE="ipcalc"   # Use ipcalc only
IP_VALIDATION_MODE="sipcalc"  # Use sipcalc only
IP_VALIDATION_MODE="regex"    # Use regex only
```

### Validation Process

```
1. Clean input
   ├── Remove leading/trailing whitespace
   └── Check if empty

2. Detect IP version
   ├── Contains ':' → IPv6
   └── No ':' → IPv4

3. Choose validation method
   ├── Auto mode:
   │   ├── ipcalc available? → Use ipcalc
   │   ├── sipcalc available? → Use sipcalc
   │   └── None available → Use regex
   └── Forced mode: Use specified tool

4. Validate
   ├── Run validation tool
   └── Check return code

5. Additional checks (regex mode)
   ├── Check format (IPv4: xxx.xxx.xxx.xxx)
   ├── Validate octets (0-255)
   ├── Validate CIDR prefix (0-32 for IPv4, 0-128 for IPv6)
   └── Return result
```

### Validation Statistics

During control panel configuration, script tracks:
```bash
IP Validation Summary:
- Total IPs processed: 15
- Valid IPs: 14
- Invalid IPs: 1
- Validation method: ipcalc
```

### CIDR Validation

```bash
# IPv4 CIDR examples
192.168.1.0/24      # ✅ Valid
10.0.0.0/8          # ✅ Valid
192.168.1.1/33      # ❌ Invalid (prefix > 32)

# IPv6 CIDR examples
2001:db8::/32       # ✅ Valid
fe80::/10           # ✅ Valid
2001:db8::/129      # ❌ Invalid (prefix > 128)
```

### Regex Fallback

When tools unavailable, uses regex patterns:

**IPv4 Regex:**
```regex
^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$
```

**IPv6 Regex:**
```regex
^(([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}|::)(/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$
```

---

## 🔄 Auto-Update System

### How It Works

```
1. Creates update script
   └── /etc/nftban/scripts/nftban_auto_update.sh

2. Adds cron entry
   └── Updates via git pull

3. Runs on schedule
   ├── Default: Every 12 hours (0 */12 * * *)
   └── Custom: Daily at specified time (e.g., 30 3 * * *)

4. Logs updates
   └── Silent unless errors occur
```

### Enable Auto-Update

```bash
# Enable with default schedule (every 12 hours)
sudo ./nftban_init.sh --enable-auto-update

# Enable with daily schedule at 3:30 AM
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"

# During installation
sudo ./nftban_init.sh --github -y --enable-auto-update --daily-time "03:30"
```

### Check Auto-Update Status

```bash
# Detailed status
sudo ./nftban_init.sh --auto-update-status

# Output:
# Auto-update via crontab: ENABLED (1 entry).
#   • 30 3 * * * /etc/nftban/scripts/nftban_auto_update.sh >/dev/null 2>&1
# Auto-update script: /etc/nftban/scripts/nftban_auto_update.sh
#   size: 456 bytes, modified: 2025-01-15 03:30:00, sha256: abc123...
```

### Disable Auto-Update

```bash
# Remove auto-update
sudo ./nftban_init.sh --remove-auto-update

# Removes:
# - Cron entry
# - Auto-update script
```

### Auto-Update Script

```bash
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO_URL="https://github.com/itcmsgr/nftban"
BRANCH="main"
TARGET_DIR="/etc/nftban"

cd "$TARGET_DIR"
if [ -d .git ]; then
  git fetch --quiet
  git reset --hard "origin/$BRANCH" --quiet
  git pull --quiet --rebase
else
  git init -q
  git remote add origin "$REPO_URL" 2>/dev/null || true
  git fetch -q origin "$BRANCH"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
fi
```

### Manual Update

```bash
# Update manually
cd /etc/nftban
sudo git pull

# Or re-run init script
sudo ./nftban_init.sh --github -y
```

### Cron Sanity Check

Script checks if cron service is running:
```bash
# Checks:
systemctl is-enabled cron || systemctl is-enabled crond
systemctl is-active cron || systemctl is-active crond

# Warns if not running
```

---

## 💡 Usage Examples

### Example 1: Fresh Server Setup

```bash
# Quick GitHub install with auto-update
sudo curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | bash -s -- --github -y --enable-auto-update

# What happened:
# ✅ Downloaded and ran nftban_init.sh
# ✅ Cloned GitHub repository to /etc/nftban/
# ✅ Installed all required packages
# ✅ Detected DirectAdmin panel
# ✅ Created configuration files
# ✅ Set up auto-update every 12 hours
# ✅ Created nftban CLI tool

# Next steps:
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
```

### Example 2: Custom Installation Path

```bash
# Install to custom directory
sudo ./nftban_init.sh --github -y --target /opt/nftban

# Directory structure:
# /opt/nftban/
#   ├── config/
#   ├── scripts/
#   └── ...

# Note: Log path remains /var/log/nftban/
```

### Example 3: Skip Control Panel Detection

```bash
# Install without automatic configuration
sudo ./nftban_init.sh --github -y --skip-cp-detect

# Creates empty configuration files
# Manual configuration required

# Edit files:
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Add ports:
22T     # SSH
80T     # HTTP
443T    # HTTPS
3306T   # MySQL
```

### Example 4: Development/Testing Setup

```bash
# Install specific branch
sudo ./nftban_init.sh --github -y --branch develop

# Enable auto-updates for develop branch
sudo ./nftban_init.sh --enable-auto-update

# Update script will track develop branch
```

### Example 5: Air-Gapped Installation

```bash
# On internet-connected system:
# 1. Download nftban_init.sh
wget https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh

# 2. Download ZIP
wget https://github.com/itcmsgr/nftban/archive/refs/heads/main.zip

# Transfer both files to air-gapped system

# On air-gapped system:
# 1. Extract ZIP manually
sudo mkdir -p /etc/nftban
sudo unzip main.zip -d /tmp/
sudo cp -r /tmp/nftban-main/* /etc/nftban/

# 2. Run local installation
sudo ./nftban_init.sh -y

# Note: Package installation may fail without repository access
# Pre-install packages: nftables, fail2ban, whois, dnsutils, ipcalc, sipcalc
```

### Example 6: Update Existing Installation

```bash
# Method 1: Re-run init script
sudo /etc/nftban/nftban_init.sh --github -y

# Method 2: Manual git pull
cd /etc/nftban
sudo git pull

# Method 3: ZIP re-download
sudo /etc/nftban/nftban_init.sh --zip -y

# After update, reload services:
sudo systemctl restart nftables
sudo systemctl restart fail2ban
```

### Example 7: Check Installation Status

```bash
# Human-readable status
sudo /etc/nftban/nftban_init.sh --status

# Output:
# [INFO] nftban path: /etc/nftban
# [INFO] nftables: v1.0.2 (Lester Gooch)
# [INFO] fail2ban: Fail2Ban v0.11.2
# [INFO] IP Validation Tools:
# [INFO]   - ipcalc: ipcalc 0.41
# [INFO]   - sipcalc: sipcalc 1.1.6
# [INFO] systemd unit present: /etc/systemd/system/nftban.service
# [INFO] Auto-update via crontab: ENABLED (1 entry).

# JSON status
sudo /etc/nftban/nftban_init.sh --status --json

# Output:
# {"auto_update_enabled":true,"auto_update_lines":1,"target_dir":"/etc/nftban"}
```

### Example 8: Beginner-Friendly Mode

```bash
# Interactive with helpful messages
sudo ./nftban_init.sh --github --beginner

# Output includes:
# ℹ️  nftban Unified Installer
# 👉 We will prepare your system and set up nftban
# 💡 Nothing starts automatically; you remain in control
# ✅ Installation finished successfully!
```

### Example 9: Dry-Run (Preview Mode)

```bash
# See what would happen without making changes
sudo ./nftban_init.sh --github --dry-run

# Shows:
# - Packages that would be installed
# - Directories that would be created
# - Configuration files that would be generated
# - Commands that would be executed

# Nothing actually changes
```

### Example 10: Quiet Installation (Automation)

```bash
# Suppress non-error output
sudo ./nftban_init.sh --github -y --quiet

# Only shows:
# - Errors
# - Warnings
# - Critical information

# Perfect for:
# - Automation scripts
# - CI/CD pipelines
# - Unattended installations
```

---

## 📝 Configuration Files Created

### Port Configuration Files

#### IPv4 Input Ports (.local)
**File:** `nftban-configuration-ipv4-ports-input-allow.conf.local`

**Format:**
```bash
# Port format: <port><type>
# Types: T (TCP), U (UDP), B (Both)

22T      # SSH TCP
80T      # HTTP TCP
443T     # HTTPS TCP
53U      # DNS UDP
3306T    # MySQL TCP
```

#### IPv4 Output Ports (.local)
**File:** `nftban-configuration-ipv4-ports-output-allow.conf.local`

**Example:**
```bash
53U      # DNS queries
80T      # HTTP outbound
443T     # HTTPS outbound
123U     # NTP
```

#### IPv6 Input/Output Ports (.local)
**Files:** 
- `nftban-configuration-ipv6-ports-input-allow.conf.local`
- `nftban-configuration-ipv6-ports-output-allow.conf.local`

**Same format as IPv4**

### IP Management Files

#### User Whitelist (.local)
**File:** `nftban-configuration-user-whitelist_ips.conf.local`

**Format:**
```bash
# One IP or CIDR per line
# IPv4 examples
203.0.113.100
192.168.1.0/24
10.0.0.0/8

# IPv6 examples
2001:db8::1
2001:db8::/32
```

#### User Blacklist (.local)
**File:** `nftban-configuration-user-blacklist_ips.conf.local`

**Format:** Same as whitelist

#### Fail2Ban Temp Bans (.local)
**File:** `nftban-configuration-f2b-ips_temp-blacklists_conf.local`

**Auto-managed by Fail2Ban:**
```bash
# This file is managed by Fail2Ban
# Do not edit manually
192.0.2.50    # Banned: 2025-01-15 10:30:00
198.51.100.25 # Banned: 2025-01-15 10:35:00
```

### Configuration File Hierarchy

```
Base Files (.conf)              User Files (.conf.local)
─────────────────────           ─────────────────────────
• Auto-generated                • Your customizations
• Overwritten on updates        • Never overwritten
• Reference defaults            • Takes precedence
• Can be regenerated            • Survives updates

Both files are read and merged by nftban_init_nftables_conf.sh
```

---

## 💻 System Requirements

### Operating Systems

| Distribution | Version | Status | Notes |
|--------------|---------|--------|-------|
| Debian | 10+ (Buster, Bullseye, Bookworm) | ✅ Fully Tested | Recommended |
| Ubuntu | 20.04+ (Focal, Jammy, Noble) | ✅ Fully Tested | Recommended |
| CentOS | 8+ (Stream) | ✅ Tested | Requires EPEL |
| AlmaLinux | 8, 9 | ✅ Tested | Requires EPEL |
| Rocky Linux | 8, 9 | ✅ Tested | Requires EPEL |
| RHEL | 8, 9 | ✅ Should Work | Requires EPEL & subscription |
| Fedora | 35+ | ✅ Tested | Modern packages |
| openSUSE | Leap 15+ | ⚠️ Experimental | Community tested |
| Alpine | 3.15+ | ⚠️ Experimental | Minimal testing |

### Minimum Hardware

- **CPU**: 1 core @ 1 GHz
- **RAM**: 512 MB
- **Disk**: 1 GB free space
- **Network**: Internet connection (for installation)

### Recommended Hardware

- **CPU**: 2+ cores @ 2 GHz
- **RAM**: 2 GB
- **Disk**: 5 GB free space (SSD preferred)
- **Network**: Stable internet connection

### Software Dependencies

#### Required (auto-installed)
- nftables (0.9.3+)
- fail2ban (0.10+)
- whois
- dnsutils/bind-utils
- bash (4.0+)
- systemd

#### Recommended (auto-installed)
- ipcalc
- sipcalc
- git (for GitHub method)
- curl (for downloads)
- unzip (for ZIP method)

#### Optional
- postfix/sendmail (for email alerts)
- logwatch (for log monitoring)
- geoip databases (for GeoIP features)

### Network Requirements

- **Outbound HTTPS (443)**: GitHub access
- **Outbound HTTP (80)**: Package repositories
- **DNS (53)**: Name resolution

### Filesystem Requirements

- **Minimum**: 100 MB for nftban
- **Recommended**: 1 GB (includes logs, backups)
- **Log rotation**: Configured for 30-day retention

---

## 🔧 Troubleshooting

### Installation Issues

#### Problem: "Supported package manager not found"

**Cause:** Script doesn't recognize your package manager

**Solution:**
```bash
# Check what's available
which apt-get dnf yum zypper apk

# Manually install supported package manager
# OR report your distribution on GitHub Issues
```

#### Problem: "Failed to install nftables"

**Cause:** Package not available in repositories

**Solution:**
```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-cache search nftables

# RHEL/CentOS - enable EPEL first
sudo dnf install -y epel-release
sudo dnf search nftables

# Check if nftables is already installed
which nft
nft --version
```

#### Problem: "Failed to install fail2ban"

**Cause:** EPEL not available on RHEL-like systems

**Solution:**
```bash
# Install EPEL manually
sudo dnf install -y epel-release

# Or from direct URL (RHEL 9 example)
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Verify EPEL
dnf repolist | grep epel

# Retry fail2ban installation
sudo dnf install -y fail2ban
```

#### Problem: "Network connectivity check failed"

**Cause:** Cannot reach GitHub

**Solution:**
```bash
# Test connectivity
curl -I https://github.com

# If blocked, use ZIP method
sudo ./nftban_init.sh --zip -y

# Or use local installation
sudo ./nftban_init.sh -y
```

#### Problem: "Permission denied"

**Cause:** Not running as root

**Solution:**
```bash
# Run with sudo
sudo ./nftban_init.sh --github -y

# Or become root
sudo -i
./nftban_init.sh --github -y
```

### Control Panel Detection Issues

#### Problem: "No control panel detected but I have one"

**Cause:** Panel installed in non-standard location

**Solution:**
```bash
# Check panel paths
ls -la /usr/local/directadmin/
ls -la /var/cpanel/
ls -la /usr/local/psa/

# Skip detection and configure manually
sudo ./nftban_init.sh --github -y --skip-cp-detect

# Add ports manually
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
```

#### Problem: "Wrong ports configured"

**Cause:** Control panel uses non-standard ports

**Solution:**
```bash
# Edit configuration after installation
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Add your custom ports
2082T    # Custom cPanel port
8080T    # Custom web port

# Regenerate firewall rules
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Package Installation Issues

#### Problem: "ipcalc not found after installation"

**Cause:** Package installed but not in PATH

**Solution:**
```bash
# Find ipcalc
which ipcalc
find /usr -name ipcalc

# Add to PATH if needed
export PATH=$PATH:/usr/local/bin

# Or use sipcalc instead
which sipcalc

# Script will use regex fallback if neither found
```

#### Problem: "sipcalc installation failed"

**Cause:** Not available in distribution repositories

**Solution:**
```bash
# This is non-critical - script continues
# IPv6 validation will be limited
# IPv4 validation uses ipcalc or regex

# To install manually from source:
wget https://github.com/sii/sipcalc/archive/refs/heads/master.zip
unzip master.zip
cd sipcalc-master
./autogen.sh
./configure
make
sudo make install
```

### Auto-Update Issues

#### Problem: "Auto-update not working"

**Cause:** Cron service not running

**Solution:**
```bash
# Check cron status
systemctl status cron || systemctl status crond

# Start cron
sudo systemctl start cron || sudo systemctl start crond

# Enable cron at boot
sudo systemctl enable cron || sudo systemctl enable crond

# Verify cron entry
crontab -l | grep nftban

# Test auto-update manually
sudo /etc/nftban/scripts/nftban_auto_update.sh
```

#### Problem: "Auto-update script missing"

**Cause:** Script not created during installation

**Solution:**
```bash
# Re-enable auto-update
sudo /etc/nftban/nftban_init.sh --enable-auto-update

# Verify script created
ls -la /etc/nftban/scripts/nftban_auto_update.sh

# Check cron entry
crontab -l | grep nftban_auto_update
```

### Git Issues

#### Problem: "fatal: not a git repository"

**Cause:** ZIP method used, not git clone

**Solution:**
```bash
# Convert to git repository
cd /etc/nftban
sudo rm -rf .git
sudo git init
sudo git remote add origin https://github.com/itcmsgr/nftban.git
sudo git fetch
sudo git checkout -b main origin/main

# Or reinstall with GitHub method
sudo ./nftban_init.sh --github -y
```

### Log File Issues

#### Problem: "Log file not created"

**Cause:** Permission issues

**Solution:**
```bash
# Check log directory
ls -la /var/log/nftban/

# Create if missing
sudo mkdir -p /var/log/nftban
sudo chmod 755 /var/log/nftban

# Check disk space
df -h /var/log/

# View recent log
sudo ls -lt /var/log/nftban/ | head -5
sudo tail -50 /var/log/nftban/nftban_init_*.log
```

### Uninstall Issues

#### Problem: "Files remain after uninstall"

**Cause:** Uninstall without --purge

**Solution:**
```bash
# Complete uninstall with purge
sudo ./nftban_init.sh --uninstall --purge -y

# Manual cleanup if needed
sudo rm -rf /etc/nftban
sudo rm -rf /var/log/nftban
sudo rm -f /usr/local/bin/nftban
sudo rm -f /etc/systemd/system/nftban.service

# Remove from crontab
crontab -l | grep -v nftban | crontab -
```

### Getting Help

If you're still having issues:

1. **Check logs:**
   ```bash
   sudo tail -100 /var/log/nftban/nftban_init_*.log
   ```

2. **Run status check:**
   ```bash
   sudo ./nftban_init.sh --status
   ```

3. **Try dry-run:**
   ```bash
   sudo ./nftban_init.sh --github --dry-run
   ```

4. **Report issue:**
   - [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
   - Include: OS, version, error messages, log excerpts
   - Tag: `nftban_init`, `installation`

---

## 🔗 Integration

### Integration with Other nftban Components

```
Installation Flow:
┌──────────────────────────────────────┐
│  1. nftban_init.sh (THIS SCRIPT)    │ ← You are here
│     • Install packages               │
│     • Create directories             │
│     • Detect control panel           │
│     • Generate templates             │
└────────────┬─────────────────────────┘
             ↓
┌──────────────────────────────────────┐
│  2. nftban_init_nftables_conf.sh     │
│     • Read configuration files       │
│     • Generate nftables rules        │
│     • Apply firewall                 │
└────────────┬─────────────────────────┘
             ↓
┌──────────────────────────────────────┐
│  3. nftban_init_fail2ban_conf.sh     │
│     • Configure Fail2Ban             │
│     • Setup jails                    │
│     • Enable monitoring              │
└────────────┬─────────────────────────┘
             ↓
┌──────────────────────────────────────┐
│  4. nftban CLI                       │
│     • Daily operations               │
│     • Ban/unban IPs                  │
│     • Monitor status                 │
└──────────────────────────────────────┘
```

### Shared Resources

All components share:
- **Configuration**: `/etc/nftban/config/`
- **Logs**: `/var/log/nftban/`
- **Scripts**: `/etc/nftban/scripts/`
- **Version**: `0.5.0-final`

### Configuration File Dependencies

```
nftban_init.sh creates:
├── Port configuration files
│   └── Used by nftban_init_nftables_conf.sh
├── IP whitelist/blacklist
│   └── Used by nftban_init_nftables_conf.sh
├── Directory structure
│   └── Used by all components
└── Control panel templates
    └── Basis for all configurations

nftban_init_nftables_conf.sh reads:
└── Configuration files created by nftban_init.sh

nftban_init_fail2ban_conf.sh reads:
└── nftban.conf.local (can be created by nftban_init.sh)

nftban CLI reads:
└── All configuration files
```

### Version Compatibility

| nftban_init.sh | nftban_init_nftables_conf.sh | nftban_init_fail2ban_conf.sh | nftban CLI |
|----------------|------------------------------|------------------------------|------------|
| 0.5.0-final    | 0.5.0-final                  | 0.5.0-final                  | 0.5.0-final |

**Always use matching versions across all components.**

### External Integration

#### Ansible

```yaml
---
- name: Install nftban
  hosts: servers
  become: yes
  tasks:
    - name: Download nftban_init.sh
      get_url:
        url: https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh
        dest: /tmp/nftban_init.sh
        mode: '0755'

    - name: Run nftban installation
      command: /tmp/nftban_init.sh --github -y --enable-auto-update
      args:
        creates: /etc/nftban/.version
```

#### Terraform

```hcl
resource "null_resource" "nftban_install" {
  provisioner "remote-exec" {
    inline = [
      "curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y",
      "sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final",
      "sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup"
    ]
  }
}
```

#### Docker (Not Recommended)

nftban requires host kernel access for nftables. Not suitable for containers.

Consider: Install on Docker host, protect containers via host firewall.

---

## 📜 License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025 **Antonios Voulvoulis – ITCMS**  
https://itcms.gr

### Quick Summary

✅ **You CAN:**
- Use for personal or commercial projects
- Modify and customize
- Deploy on unlimited systems
- Charge for services using nftban
- Include in managed service offerings

❌ **You CANNOT:**
- Sell the software itself
- Sublicense or resell
- Distribute as a paid product
- Remove copyright notices

### Service Provider Examples

**Hosting Provider Setup Fee:**
```
✅ "Server Setup & Security: €€€€"
   Includes: nftban installation + configuration + monitoring
   
✅ "Managed Firewall Service: €€€€/month"
   Includes: nftban management + updates + support
```

**Security Consulting:**
```
✅ "Security Audit & Hardening: €€€€"
   Includes: nftban deployment as part of security stack
   
✅ "24/7 Security Operations: €€€€/month"
   Includes: nftban + monitoring + incident response
```

**NOT Allowed:**
```
❌ "nftban Pro License: $$$"
   Cannot sell the software itself
   
❌ "nftban Enterprise Edition: $$$"
   Cannot create paid variants
```

### The Simple Test

**Ask yourself:** *"Am I charging for the software itself, or for my service using the software?"*

- **Service using nftban** = ✅ Allowed
- **Selling nftban itself** = ❌ Not allowed

### Need Commercial Licensing?

📧 **Email:** contact@itcms.gr  
🌐 **Website:** https://itcms.gr

We're open to:
- Partnership discussions
- Custom licensing arrangements
- Enterprise agreements
- OEM licensing

[📚 Full License Text](../LICENSE.md)

---

## 📞 Support

### Community Support

- **GitHub Issues**: [Report bugs](https://github.com/itcmsgr/nftban/issues)
- **GitHub Discussions**: [Ask questions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation**: [Complete guides](../docs/)
- **Wiki**: [Community knowledge](https://github.com/itcmsgr/nftban/wiki)

### Professional Support

**ITCMS – IT Consulting Managed Services**

- **Author**: Antonios Voulvoulis
- **Email**: support@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)
- **Services**:
  - Installation assistance
  - Custom configuration
  - Security auditing
  - Managed security services
  - Training and consulting

### Documentation

- **[Main README](../README.md)** - Project overview
- **[Complete Guide](README_COMPLETE.md)** - Comprehensive documentation
- **[Firewall Configuration](README_nftban_init_nftables_conf.md)** - Next step after init
- **[Intrusion Prevention](README_nftban_fail2ban.md)** - Fail2Ban setup
- **[CLI Reference](README_nftban_cli.md)** - Daily operations
- **[Troubleshooting](TROUBLESHOOTING.md)** - Common issues

### Useful External Resources

- [nftables Wiki](https://wiki.nftables.org/) - Official nftables documentation
- [Fail2ban Manual](https://fail2ban.readthedocs.io/) - Fail2Ban documentation
- [systemd Documentation](https://www.freedesktop.org/software/systemd/man/) - System management

---

## ⭐ Show Your Support

If nftban_init.sh helps you deploy secure firewalls quickly and easily, please consider giving us a star!

[![GitHub stars](https://img.shields.io/github/stars/itcmsgr/nftban?style=for-the-badge&logo=github)](https://github.com/itcmsgr/nftban/stargazers)

**Why star this project?**
- 🔍 **Visibility**: Help other sysadmins discover nftban
- 💪 **Motivation**: Show appreciation for the development work
- 📈 **Growth**: Support the project's momentum
- 🎯 **Feedback**: Signal that automation matters to you

**Quick actions:**
- ⭐ [Star this repository](https://github.com/itcmsgr/nftban)
- 🍴 [Fork for your own modifications](https://github.com/itcmsgr/nftban/fork)
- 👁️ [Watch for updates](https://github.com/itcmsgr/nftban/subscription)
- 📢 [Share with your network](https://twitter.com/intent/tweet?text=Check%20out%20nftban%20-%20automated%20Linux%20firewall%20deployment&url=https://github.com/itcmsgr/nftban)

### Spread the Word

Help the community by sharing nftban:
- Recommend it in sysadmin forums
- Write a blog post about your deployment
- Create video tutorials
- Share in social media
- Recommend to clients and colleagues

Every star, fork, and share helps nftban reach more people who need simple, reliable security automation!

---

## 🎉 Related Documentation

### Core Components

- 📚 **[Main README](../README.md)** - Project overview and quick start
- 🛡️ **[Firewall Configuration](README_nftban_init_nftables_conf.md)** - Configure nftables (next step)
- 🔒 **[Intrusion Prevention](README_nftban_fail2ban.md)** - Setup Fail2Ban (step 3)
- 💻 **[CLI Reference](README_nftban_cli.md)** - Daily operations tool
- 📖 **[Complete Guide](README_COMPLETE.md)** - All-in-one documentation

### Additional Guides

- 🚀 **[Quick Start](QUICKSTART.md)** - 5-minute deployment
- ⚙️ **[Configuration Guide](CONFIGURATION.md)** - Detailed configuration
- 🎛️ **[Control Panels](CONTROL_PANELS.md)** - Panel-specific guides
- 🔧 **[Troubleshooting](TROUBLESHOOTING.md)** - Solutions to common issues
- 🏗️ **[Architecture](ARCHITECTURE.md)** - System design overview
- 🔐 **[Security Best Practices](SECURITY.md)** - Hardening guide

### Quick Links

- 🏠 **[Project Home](https://github.com/itcmsgr/nftban)**
- 🐛 **[Report Issue](https://github.com/itcmsgr/nftban/issues)**
- 💬 **[Discussions](https://github.com/itcmsgr/nftban/discussions)**
- 📧 **[Email Support](mailto:support@itcms.gr)**
- 🌐 **[ITCMS Website](https://itcms.gr)**

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="README_COMPLETE.md">📚 Complete Docs</a> •
  <a href="README_nftban_init_nftables_conf.md">🛡️ Next: Firewall Config</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Issue</a> •
  <a href="https://itcms.gr">🌐 ITCMS Website</a>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
