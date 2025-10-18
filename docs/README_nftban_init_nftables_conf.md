# nftban_init_nftables_conf.sh

**Advanced nftables Firewall Configuration with Automatic Control Panel Detection**

[![Version](https://img.shields.io/badge/version-0.9.0--beta-orange)](https://github.com/itcmsgr/nftban)
[![Architecture](https://img.shields.io/badge/v0.9.0-dual--table-orange)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](../LICENSE.md)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![nftables](https://img.shields.io/badge/requires-nftables-red.svg)](https://netfilter.org/projects/nftables/)
[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)](https://github.com/itcmsgr/nftban)

> **Part of the [nftban](https://github.com/itcmsgr/nftban) ecosystem** - Modern Linux firewall management system

---

> **📌 v0.9.0 ARCHITECTURE UPDATE**
>
> This document contains architecture diagrams and examples using the OLD v0.8.5 single-table architecture (`inet nftban_global`).
>
> **Key Changes in v0.9.0:**
> - Tables: `ip nftban_v4` + `ip6 nftban_v6` (NOT `inet nftban_global`)
> - Sets: `whitelist`, `temp_ban`, `user_blacklist` (NO `_v4/_v6` suffix)
> - Commands: `nft list set ip nftban_v4 whitelist` (updated table family syntax)
> - Architecture diagrams show old unified table structure
>
> The **configuration script itself has been updated** for v0.9.0 and generates the new dual-table architecture automatically.
>
> See [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md) for command translation guide.

```bash
# Quick start: Generate and apply firewall configuration
sudo ./nftban_init_nftables_conf.sh --install-final

# Test mode: Validate without applying
sudo ./nftban_init_nftables_conf.sh --test

# Generate Fail2ban integration
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action
```

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [How It Works](#-how-it-works)
- [Installation](#-installation)
- [Usage](#-usage)
- [Command-Line Options](#-command-line-options)
- [Control Panel Support](#-control-panel-support)
- [Configuration Files](#-configuration-files)
- [Examples](#-examples)
- [Architecture](#-architecture)
- [Validation & Testing](#-validation--testing)
- [Safety Features](#-safety-features)
- [Troubleshooting](#-troubleshooting)
- [Advanced Usage](#-advanced-usage)
- [Contributing](#-contributing)
- [License](#-license)
- [Support](#-support)

---

## 🎯 Overview

`nftban_init_nftables_conf.sh` is the **firewall configuration engine** of the nftban system. It automatically detects your control panel (DirectAdmin, cPanel, Plesk, or generic), configures appropriate ports, generates optimized nftables rules, and creates a single unified table architecture for simplified management.

### What Does It Do?

```
1. 🔍 Detect Control Panel → DirectAdmin/cPanel/Plesk/Generic
2. 📁 Read Configuration Templates → System + User settings
3. 🔧 Generate nftables Rules → Single global table
4. ✅ Validate Configuration → Syntax check before applying
5. 🚀 Apply Firewall → Safe deployment with rollback
6. 🔄 Integrate Fail2ban → Temporary ban sets ready
```

### Why This Script?

| Traditional Approach | nftban_init_nftables_conf.sh |
|---------------------|------------------------------|
| Manual port discovery | ✅ Auto-detect control panel ports |
| Complex nftables syntax | ✅ Simple configuration format |
| Multiple tables/chains | ✅ Single unified table |
| Risk of lockout | ✅ Built-in safety mechanisms |
| Manual Fail2ban setup | ✅ Integrated ban sets |
| Configuration drift | ✅ Template-based consistency |

---

## ✨ Features

### 🎛️ Control Panel Intelligence

- **Automatic Detection** - Identifies DirectAdmin, cPanel, Plesk automatically
- **Pre-configured Templates** - Control panel ports ready out of the box
- **Custom Override** - User configurations merge with system defaults
- **IP Whitelisting** - Control panel IPs automatically protected

### 🏗️ Single-Table Architecture

```
inet nftban_global
├── Sets (organized by purpose)
│   ├── whitelist_v4 / whitelist_v6       (Priority 1)
│   ├── temp_ban_v4 / temp_ban_v6         (Fail2ban uses these)
│   ├── user_blacklist_v4 / v6            (Manual permanent bans)
│   └── system_blacklist_v4 / v6          (Bulk/country blocks)
├── Chain: input (incoming traffic)
└── Chain: output (outgoing traffic)
```

### 🔒 Security Layers

1. **Whitelist Priority** - Whitelisted IPs never blocked
2. **Temporary Bans** - Fail2ban integration with timeouts
3. **Permanent Bans** - Manual and bulk blacklists
4. **Port Rules** - Combined system + user configurations
5. **Default Drop** - Everything else blocked

### 🛡️ Safety Features

- ✅ **Self-Protection** - Detects and whitelists your current IP
- ✅ **Server IP Protection** - All server IPs auto-whitelisted
- ✅ **Validation Before Apply** - `nft -c` syntax check
- ✅ **Automatic Backups** - Configuration snapshots
- ✅ **Rollback Support** - Restore previous config on failure
- ✅ **Dry-Run Mode** - Preview changes without applying
- ✅ **Test Mode** - Validate without deployment

### 📊 Advanced Validation

- **Multi-Method IP Validation**
  - ipcalc/sipcalc (if available)
  - nftables syntax validation (`nft -c`)
  - Regex + numeric bounds fallback
- **Port Range Validation** - Ensures valid port numbers (1-65535)
- **CIDR Validation** - IPv4 (/0-32) and IPv6 (/0-128)
- **Interval Support** - IP range validation (e.g., 192.168.1.1-192.168.1.254)

---

## 🔄 How It Works

### Execution Flow

```
┌─────────────────────────────────────────────────────────┐
│  1. Dependency Check                                    │
│     ├─ nft, ip, awk, grep, sed (required)              │
│     └─ ipcalc, sipcalc, curl/wget (optional)           │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  2. Control Panel Detection                             │
│     ├─ Check: /usr/local/directadmin/ → DirectAdmin    │
│     ├─ Check: /usr/local/cpanel/ → cPanel              │
│     ├─ Check: /usr/local/psa/ → Plesk                  │
│     └─ Default: Generic server                         │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  3. Configuration Merge                                 │
│     ├─ Load: templates/control-panels/[panel].conf     │
│     ├─ Generate: .conf files (system-managed)          │
│     ├─ Read: .conf.local files (user customizations)   │
│     └─ Merge: System + User configurations             │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  4. IP Protection                                       │
│     ├─ Detect: Server interface IPs                    │
│     ├─ Detect: Server public IP                        │
│     ├─ Detect: Current user IP (SSH_CLIENT)            │
│     ├─ Fetch: Cloudflare IPs (optional)                │
│     └─ Generate: System whitelist                      │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  5. Rules Generation                                    │
│     ├─ Build: nftables sets (whitelist/blacklist)      │
│     ├─ Create: temp_ban sets (for Fail2ban)            │
│     ├─ Generate: Port rules (input/output)             │
│     └─ Output: /etc/nftban/config/nft_rules.conf.local │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  6. Validation & Apply                                  │
│     ├─ Syntax Check: nft -c                            │
│     ├─ Backup: Current /etc/nftables.conf              │
│     ├─ Apply: nft -f /etc/nftables.conf                │
│     ├─ Success: Seed temp bans from CSV                │
│     └─ Failure: Rollback to backup                     │
└─────────────────────────────────────────────────────────┘
```

### Configuration Priority

```
Priority 1: Whitelist (ACCEPT)
  ├─ System whitelist (server IPs, current user)
  ├─ User whitelist (.conf.local)
  └─ Cloudflare IPs (optional)

Priority 2: Blacklists (DROP)
  ├─ Temporary bans (Fail2ban with timeout)
  ├─ User blacklist (manual permanent)
  └─ System blacklist (bulk/countries)

Priority 3: Port Rules (ACCEPT if match)
  ├─ SSH (auto-detected port)
  ├─ Control panel ports (from template)
  └─ User custom ports (.conf.local)

Priority 4: Default (DROP)
  └─ Everything else blocked
```

---

## 💿 Installation

### Prerequisites

**Required:**
```bash
# Install on Debian/Ubuntu
sudo apt install nftables iproute2 coreutils util-linux

# Install on RHEL/CentOS/Rocky/AlmaLinux
sudo dnf install nftables iproute awk grep sed util-linux
```

**Optional (Recommended):**
```bash
# For better IP validation and Cloudflare fetching
sudo apt install ipcalc sipcalc curl       # Debian/Ubuntu
sudo dnf install ipcalc curl               # RHEL/CentOS
```

### Get the Script

**Option 1: Via nftban System** (Recommended)
```bash
# Installs entire nftban system including this script
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y
```

**Option 2: Standalone Download**
```bash
# Download just this script
sudo mkdir -p /etc/nftban/scripts
sudo curl -o /etc/nftban/scripts/nftban_init_nftables_conf.sh \
  https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_nftables_conf.sh
sudo chmod +x /etc/nftban/scripts/nftban_init_nftables_conf.sh
```

**Option 3: Clone Repository**
```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
sudo chmod +x nftban_init_nftables_conf.sh
```

### Quick Verification

```bash
# Check dependencies
sudo ./nftban_init_nftables_conf.sh --help

# Run tests
sudo ./nftban_init_nftables_conf.sh --run-tests
```

---

## 🚀 Usage

### Basic Workflow

```bash
# 1. Test configuration generation (safe, no changes)
sudo ./nftban_init_nftables_conf.sh --test

# 2. Preview what will be generated (dry-run)
sudo ./nftban_init_nftables_conf.sh --dry-run

# 3. Generate and apply firewall
sudo ./nftban_init_nftables_conf.sh --install-final

# 4. Generate Fail2ban integration
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action
```

### Typical Usage Scenarios

**First-Time Setup:**
```bash
# Generate firewall with Cloudflare protection
sudo ./nftban_init_nftables_conf.sh --yes-cloudflare --install-final
```

**Update After Configuration Changes:**
```bash
# Edit your custom ports
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Regenerate and apply
sudo ./nftban_init_nftables_conf.sh --install-final
```

**Validate Existing Configuration:**
```bash
# Check all config files for errors
sudo ./nftban_init_nftables_conf.sh --validate-only
```

**Non-Interactive Deployment:**
```bash
# Automated installation (CI/CD, Ansible, etc.)
sudo ./nftban_init_nftables_conf.sh -y --yes-cloudflare --install-final --silent-auto
```

---

## 🎮 Command-Line Options

### General Options

| Option | Description | Example |
|--------|-------------|---------|
| `-h, --help` | Show detailed help message | `--help` |
| `-y` | Assume "yes" for all prompts | `-y` |
| `--silent-auto` | Non-interactive mode with auto-confirmation | `--silent-auto` |

### Generation Modes

| Option | Description | Use Case |
|--------|-------------|----------|
| `--test` | Generate config and validate syntax only (no apply) | Testing before deployment |
| `--dry-run` | Generate and preview config (no apply) | See what will change |
| `--validate-only` | Validate all config files without generating | Check for errors |
| `--install-final` | Generate, validate, and apply configuration | Normal deployment |

### Cloudflare Options

| Option | Description | Default |
|--------|-------------|---------|
| `--cloudflare [yes\|no\|auto]` | Include Cloudflare IP ranges | `auto` (prompts) |
| `--yes-cloudflare` | Shortcut for `--cloudflare yes` | - |
| `--no-cloudflare` | Shortcut for `--cloudflare no` | - |

### Utility Options

| Option | Description | Output |
|--------|-------------|--------|
| `--run-tests` | Run built-in unit tests | Test results |
| `--generate-f2b-action` | Generate Fail2ban action config | `/etc/fail2ban/action.d/nftban-global.conf` |
| `--create-panel-templates` | Create example control panel templates | `/etc/nftban/config/templates/control-panels/` |

### Examples

```bash
# Interactive mode (prompts for Cloudflare)
sudo ./nftban_init_nftables_conf.sh --install-final

# Automated mode with Cloudflare IPs
sudo ./nftban_init_nftables_conf.sh -y --yes-cloudflare --install-final

# Test without applying
sudo ./nftban_init_nftables_conf.sh --test

# Preview changes
sudo ./nftban_init_nftables_conf.sh --dry-run

# Validate all config files
sudo ./nftban_init_nftables_conf.sh --validate-only

# Generate Fail2ban integration
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action

# Create control panel templates
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# Non-interactive CI/CD deployment
sudo ./nftban_init_nftables_conf.sh --silent-auto --no-cloudflare --install-final
```

---

## 🎛️ Control Panel Support

### Automatic Detection

The script automatically detects installed control panels:

```bash
# Detection order
1. DirectAdmin  → /usr/local/directadmin/
2. cPanel/WHM   → /usr/local/cpanel/
3. Plesk        → /usr/local/psa/
4. Generic      → No panel detected
```

### Pre-configured Ports

| Panel | Config File | Ports Included |
|-------|-------------|----------------|
| **DirectAdmin** | `directadmin.conf` | 2222, 20-21, 35000-35999 (FTP passive), 25, 110, 143, 465, 587, 993, 995 (Email), 53 (DNS) |
| **cPanel/WHM** | `cpanel.conf` | 2082-2083 (cPanel), 2086-2087 (WHM), 2095-2096 (Webmail), 2089 (cP License), 3306 (MySQL), Email, FTP, DNS |
| **Plesk** | `plesk.conf` | 8443 (Plesk), 8880 (HTTP), 3306 (MySQL), 5432 (PostgreSQL), Email, FTP, DNS |
| **Generic** | `generic.conf` | 22 (SSH), 25 (SMTP), 53 (DNS), 80 (HTTP), 443 (HTTPS) |

### Template Structure

**Example: DirectAdmin Template** (`/etc/nftban/config/templates/control-panels/directadmin.conf`)

```bash
# DirectAdmin Control Panel Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv4)
TCP_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# TCP Input Ports (IPv6)
TCP6_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv6)
TCP6_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# UDP Input Ports (IPv4)
UDP_IN = "53"

# UDP Output Ports (IPv4)
UDP_OUT = "53"

# UDP Input Ports (IPv6)
UDP6_IN = "53"

# UDP Output Ports (IPv6)
UDP6_OUT = "53"

# Control Panel IP Addresses (optional)
# IP_ADDRESS = "192.168.1.100,2001:db8::1"
```

### Customizing Templates

```bash
# Create control panel templates
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# Edit your panel's template
sudo nano /etc/nftban/config/templates/control-panels/directadmin.conf

# Regenerate configuration
sudo ./nftban_init_nftables_conf.sh --install-final
```

---

## 📁 Configuration Files

### File Structure

```
/etc/nftban/config/
├── templates/
│   └── control-panels/
│       ├── directadmin.conf    # DirectAdmin template
│       ├── cpanel.conf          # cPanel/WHM template
│       ├── plesk.conf           # Plesk template
│       └── generic.conf         # Generic server template
│
├── System Files (.conf) - Auto-managed by script
│   ├── nftban-configuration-ipv4-ports-input-allow.conf
│   ├── nftban-configuration-ipv4-ports-output-allow.conf
│   ├── nftban-configuration-ipv6-ports-input-allow.conf
│   ├── nftban-configuration-ipv6-ports-output-allow.conf
│   └── nftban-configuration-system_whitelist_ips.conf
│
├── User Files (.conf.local) - Your customizations
│   ├── nftban-configuration-ipv4-ports-input-allow.conf.local
│   ├── nftban-configuration-ipv4-ports-output-allow.conf.local
│   ├── nftban-configuration-ipv6-ports-input-allow.conf.local
│   ├── nftban-configuration-ipv6-ports-output-allow.conf.local
│   ├── nftban-configuration-user-whitelist_ips.conf.local
│   ├── nftban-configuration-user-blacklist_ips.conf.local
│   ├── nftban-configuration-ipv4-blacklist_ips.conf.local
│   └── nftban-configuration-ipv6-blacklist_ips.conf.local
│
├── Generated Output
│   └── nft_rules.conf.local     # Final nftables configuration
│
└── Backups
    └── *.backup.*               # Automatic backups (30-day retention)
```

### Port Configuration Format

```bash
# Format: PORTRANGE?PROTOCOL
# 
# Protocol codes:
# T = TCP only
# U = UDP only
# B = Both TCP and UDP
#
# Examples:
22T              # TCP port 22 (SSH)
80T              # TCP port 80 (HTTP)
443T             # TCP port 443 (HTTPS)
53U              # UDP port 53 (DNS)
3306B            # TCP and UDP port 3306 (MySQL)
8000-8010T       # TCP ports 8000-8010
35000-35999B     # Both TCP and UDP ports 35000-35999
```

### IP Configuration Format

```bash
# Single IPv4
192.168.1.100

# IPv4 CIDR
10.0.0.0/8

# Single IPv6
2001:db8::1

# IPv6 CIDR
2001:db8::/48

# IPv4 Range (interval)
192.168.1.1-192.168.1.254

# IPv6 Range (interval)
2001:db8::1-2001:db8::ffff

# Comments allowed
203.0.113.50  # Office IP
```

### Adding Custom Ports

```bash
# Add custom application ports
cat >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local <<EOF
8080T    # Application HTTP
9000T    # Application API
5432T    # PostgreSQL
EOF

# Regenerate and apply
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Managing Whitelists

```bash
# Add IPs to user whitelist
cat >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local <<EOF
203.0.113.100        # Office main IP
198.51.100.0/24      # Office subnet
2001:db8::1          # IPv6 office
EOF

# Regenerate and apply
sudo ./nftban_init_nftables_conf.sh --install-final
```

---

## 📚 Examples

### Example 1: Fresh Server Setup

```bash
# Install nftban system
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# Configure firewall (auto-detects DirectAdmin)
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --test
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify
sudo nft list ruleset
```

### Example 2: Add Custom Application

```bash
# Application needs ports 8080 (HTTP), 8443 (HTTPS), 5432 (PostgreSQL)
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Add lines:
# 8080T    # App HTTP
# 8443T    # App HTTPS
# 5432T    # PostgreSQL

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify
sudo nft list ruleset | grep -E '8080|8443|5432'
```

### Example 3: Cloudflare Integration

```bash
# Enable Cloudflare IP whitelisting
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --yes-cloudflare --install-final

# Verify Cloudflare IPs added
sudo grep -A 20 "BEGIN CLOUDFLARE" /etc/nftban/config/nftban-configuration-system_whitelist_ips.conf.local
```

### Example 4: Custom Control Panel

```bash
# Create custom template
sudo mkdir -p /etc/nftban/config/templates/control-panels
sudo nano /etc/nftban/config/templates/control-panels/mycustompanel.conf

# Add your ports:
# TCP_IN = "22,80,443,2222,9000"
# UDP_IN = "53"

# Rename to match detection (or use generic)
# Script auto-loads based on detection

# Generate configuration
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Example 5: Whitelist Office Network

```bash
# Add office subnet to whitelist
echo "198.51.100.0/24  # Office network" | \
  sudo tee -a /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Regenerate firewall
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify
sudo nft list set inet nftban_global whitelist_v4
```

### Example 6: CI/CD Deployment

```bash
#!/bin/bash
# deploy_firewall.sh - Automated firewall deployment

set -euo pipefail

# Download and install nftban
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | \
  sudo bash -s -- --github -y

# Deploy custom configuration
sudo cp ports.conf.local /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
sudo cp whitelist.conf /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Generate and apply (non-interactive)
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh \
  --silent-auto \
  --no-cloudflare \
  --install-final

# Verify deployment
sudo nft list ruleset > /tmp/firewall-deployed.txt
echo "Firewall deployed successfully"
```

---

## 🏗️ Architecture

### nftables Table Structure

```nftables
table inet nftban_global {
    # ===== SETS =====
    
    set whitelist_v4 {
        type ipv4_addr
        flags interval
        elements = { 
            127.0.0.0/8,      # Loopback
            10.0.0.0/8,       # Private
            YOUR_IP,          # Current user
            SERVER_IP,        # Server public IP
            CF_RANGES         # Cloudflare (optional)
        }
    }
    
    set whitelist_v6 {
        type ipv6_addr
        flags interval
        elements = { ::1, YOUR_IPV6, SERVER_IPV6 }
    }
    
    set temp_ban_v4 {
        type ipv4_addr
        flags timeout
        comment "Fail2ban temporary bans"
    }
    
    set temp_ban_v6 {
        type ipv6_addr
        flags timeout
        comment "Fail2ban temporary bans"
    }
    
    set user_blacklist_v4 {
        type ipv4_addr
        flags interval
        comment "Manual permanent bans"
    }
    
    set user_blacklist_v6 {
        type ipv6_addr
        flags interval
        comment "Manual permanent bans"
    }
    
    set system_blacklist_v4 {
        type ipv4_addr
        flags interval
        comment "System-managed bulk bans"
    }
    
    set system_blacklist_v6 {
        type ipv6_addr
        flags interval
        comment "System-managed bulk bans"
    }
    
    # ===== INPUT CHAIN =====
    
    chain input {
        type filter hook input priority -150
        policy accept
        
        # 1. Loopback
        iif "lo" accept
        
        # 2. Whitelist (Priority 1)
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
        
        # 3. Blacklists (Priority 2)
        ip saddr @temp_ban_v4 drop
        ip6 saddr @temp_ban_v6 drop
        ip saddr @user_blacklist_v4 drop
        ip6 saddr @user_blacklist_v6 drop
        ip saddr @system_blacklist_v4 drop
        ip6 saddr @system_blacklist_v6 drop
        
        # 4. Established connections
        ct state established,related accept
        
        # 5. SSH
        tcp dport 22 accept
        
        # 6. Control panel + user ports
        # (Generated from templates + .conf.local files)
        
        # 7. Connection tracking rules
        # (From USER_CT_FILE_IPv4/IPv6)
    }
    
    # ===== OUTPUT CHAIN =====
    
    chain output {
        type filter hook output priority 0
        policy accept
        
        # User-defined output rules
        # (From port configuration files)
    }
}
```

### Data Flow

```
User Request
     ↓
[nftables INPUT chain]
     ↓
1. Whitelist check → ACCEPT (bypass all other rules)
     ↓
2. Blacklist check → DROP (banned IPs)
     ↓
3. Connection state → ACCEPT (established/related)
     ↓
4. Port rules → ACCEPT (if configured)
     ↓
5. Default policy → DROP (everything else)
```

### Integration Points

```
┌─────────────────────────────────────────┐
│  nftban_init_nftables_conf.sh           │
│  (This script)                          │
└─────────────┬───────────────────────────┘
              │
              ├─→ /etc/nftables.conf
              │   (Applied firewall)
              │
              ├─→ temp_ban_v4/v6 sets
              │   (Used by Fail2ban)
              │
              ├─→ /etc/fail2ban/action.d/
              │   nftban-global.conf
              │   (Fail2ban integration)
              │
              └─→ nftban CLI
                  (Uses sets for ban/unban)
```

---

## ✅ Validation & Testing

### Built-in Tests

```bash
# Run all unit tests
sudo ./nftban_init_nftables_conf.sh --run-tests

# Example output:
# === Running unit tests ===
# [OK] append_if_set ipv4 valid
# [OK] append_if_set ipv6 valid
# [OK] generate_port_rules count
# [OK] IPv4 valid
# [OK] IPv4 CIDR valid
# [OK] IPv6 valid
# [OK] IPv6 CIDR valid
# === Unit tests: 20/20 passed ===
```

### Validation Modes

**Syntax Validation:**
```bash
# Check nftables syntax only
sudo ./nftban_init_nftables_conf.sh --test
```

**Configuration Validation:**
```bash
# Validate all config files
sudo ./nftban_init_nftables_conf.sh --validate-only

# Output shows:
# - Valid/invalid IPs
# - Valid/invalid ports
# - nftables fragments check
# - Log: /var/log/nftban/validate_all_*.log
```

**Dry-Run Preview:**
```bash
# Generate config but don't apply
sudo ./nftban_init_nftables_conf.sh --dry-run

# Shows:
# - What will be generated
# - Preview of first 50 lines
# - Manual apply instructions
```

### Manual Validation

```bash
# Check syntax of generated config
sudo nft -c -f /etc/nftban/config/nft_rules.conf.local

# Test apply (clears on reboot if you get locked out)
sudo nft -f /etc/nftban/config/nft_rules.conf.local

# Verify sets
sudo nft list set inet nftban_global whitelist_v4
sudo nft list set inet nftban_global temp_ban_v4

# Check if your IP is whitelisted
sudo nft get element inet nftban_global whitelist_v4 { YOUR_IP }
```

### IP Validation Methods

The script uses multiple validation methods (in order):

1. **External Tools** (if available)
   - `ipcalc` for IPv4
   - `sipcalc` for IPv6

2. **nftables Syntax** (always available)
   - Creates test set with `nft -c`
   - Most reliable for intervals and CIDR

3. **Regex + Bounds** (fallback)
   - IPv4: Octet validation (0-255)
   - IPv6: RFC 4291 compliance
   - Port: Range validation (1-65535)

```bash
# Test IP validation
sudo ./nftban_init_nftables_conf.sh --run-tests | grep "IPv"

# Example output:
# [OK] IPv4 valid
# [OK] IPv4 invalid
# [OK] IPv4 CIDR valid
# [OK] IPv6 valid
# [OK] IPv6 interval valid
```

---

## 🛡️ Safety Features

### Automatic Protections

**1. Current User IP Protection**
```bash
# Automatically detects and whitelists:
- SSH_CLIENT variable
- who -u output
- last -i output
```

**2. Server IP Protection**
```bash
# Auto-whitelists:
- All interface IPs (ip addr show)
- Public server IP (via external API)
- IPv4 and IPv6
```

**3. Configuration Validation**
```bash
# Before applying:
- Syntax check (nft -c)
- IP validation (multiple methods)
- Port validation (range checks)
- CIDR validation (prefix bounds)
```

**4. Automatic Backups**
```bash
# Before every change:
- Backup to /etc/nftban/backups/
- Timestamped files
- 30-day retention (configurable)
- Automatic cleanup of old backups
```

**5. Rollback Support**
```bash
# If apply fails:
- Automatic rollback to previous config
- Error logging
- Clear error messages
```

### Safety Options

```bash
# Test without applying
--test

# Preview changes
--dry-run

# Validate config files
--validate-only

# Non-interactive with defaults
--silent-auto
```

### Recovery Procedures

**Locked Out via SSH?**
```bash
# From console/VNC/IPMI:
sudo nft flush ruleset
sudo systemctl stop nftables
sudo nano /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
# Add your IP
sudo ./nftban_init_nftables_conf.sh --install-final
```

**Restore Previous Configuration:**
```bash
# List backups
ls -lh /etc/nftban/backups/

# Restore specific backup
sudo cp /etc/nftban/backups/nftables.conf.backup.20250111120000 /etc/nftables.conf
sudo nft -f /etc/nftables.conf
```

**Emergency Disable:**
```bash
# Completely disable firewall (temporarily)
sudo nft flush ruleset
sudo systemctl stop nftables

# Re-enable
sudo systemctl start nftables
```

---

## 🔧 Troubleshooting

### Common Issues

**Issue: Script fails with "nft command not found"**
```bash
# Solution: Install nftables
sudo apt install nftables  # Debian/Ubuntu
sudo dnf install nftables  # RHEL/CentOS

# Verify
nft --version
```

**Issue: "Sandbox resource constraints exceeded" (ShellCheck)**
```bash
# Solution: Install ShellCheck locally (online version has limits)
sudo apt install shellcheck
shellcheck nftban_init_nftables_conf.sh
```

**Issue: Locked out after applying rules**
```bash
# Solution 1: From console/VNC
sudo nft flush ruleset
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Solution 2: Restore backup
sudo cp /etc/nftban/backups/nftables.conf.backup.* /etc/nftables.conf
sudo nft -f /etc/nftables.conf

# Solution 3: Add your IP to whitelist
sudo nano /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
# Add: YOUR_IP
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**Issue: Control panel not detected**
```bash
# Check detection
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --test 2>&1 | grep "Detected"

# Manual override: Edit template
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --create-panel-templates
sudo nano /etc/nftban/config/templates/control-panels/generic.conf
# Add your ports
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**Issue: Configuration not applied**
```bash
# Check syntax
sudo nft -c -f /etc/nftban/config/nft_rules.conf.local

# Check for errors in log
sudo tail -f /etc/nftban/logs/validation_$(date +%F).log

# Validate all files
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --validate-only
```

**Issue: Port not opening**
```bash
# Verify port in config
grep "8080" /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Check if rule exists
sudo nft list ruleset | grep 8080

# Regenerate
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Test port
sudo netstat -tlnp | grep 8080
```

**Issue: Cloudflare IPs not fetching**
```bash
# Check internet connectivity
ping -c 4 cloudflare.com

# Check curl/wget
which curl wget

# Install if missing
sudo apt install curl  # Debian/Ubuntu
sudo dnf install curl  # RHEL/CentOS

# Retry
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --yes-cloudflare --install-final
```

### Debug Mode

```bash
# Enable verbose logging
export NFTBAN_DEBUG=1
sudo ./nftban_init_nftables_conf.sh --install-final

# Check logs
sudo tail -f /etc/nftban/logs/validation_$(date +%F).log

# List all generated files
ls -lh /etc/nftban/config/

# Show configuration snapshot
cat /etc/nftban/logs/nftables_final_*.conf
```

### Validation Logs

```bash
# Location
/etc/nftban/logs/
├── validation_YYYY-MM-DD.log       # Daily validation log
└── nftables_final_*.conf           # Configuration snapshots

# View validation log
sudo tail -100 /etc/nftban/logs/validation_$(date +%F).log

# Search for errors
sudo grep -i "error\|fail\|invalid" /etc/nftban/logs/validation_$(date +%F).log
```

---

## 🚀 Advanced Usage

### Custom Connection Tracking

```bash
# Create custom CT rules
sudo nano /etc/nftban/config/nftban-nfttables-ct-ipv4.conf.local

# Example: Allow specific connection states
ct state invalid drop
ct state new tcp dport 443 ct mark set 0x1

# Apply
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Temporary Ban Seeding

```bash
# Create CSV file with temporary bans
sudo nano /etc/nftban/config/nftban-configuration-f2b-ips_temp-blacklists_conf.local

# Format: IP,HOURS,COMMENT
192.0.2.50,24,Brute force attacker
203.0.113.100,48,Suspicious activity

# Apply (automatically seeded on --install-final)
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Multi-Server Deployment

```bash
# Create base template
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# Copy to version control
cp /etc/nftban/config/templates/control-panels/*.conf ~/nftban-templates/

# Deploy to servers
for server in web1 web2 web3; do
  scp ~/nftban-templates/* $server:/etc/nftban/config/templates/control-panels/
  ssh $server "sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final"
done
```

### Custom Validation Rules

```bash
# Add custom validation function
sudo nano /etc/nftban/scripts/nftban_init_nftables_conf.sh

# Example: Validate against external database
validate_custom_ip() {
  local ip="$1"
  # Your validation logic
  curl -s "https://api.example.com/validate?ip=$ip"
}
```

### Integration with Monitoring

```bash
# Export metrics
sudo nft list ruleset > /var/log/nftban/ruleset.txt

# Count rules
sudo nft list table inet nftban_global | grep -c "accept\|drop"

# Set sizes
sudo nft list set inet nftban_global whitelist_v4 | grep -c "elements"

# Integration with monitoring tools (Prometheus, Grafana, etc.)
```

---

## 🤝 Contributing

We welcome contributions! This script is part of the larger [nftban project](https://github.com/itcmsgr/nftban).

### How to Contribute

1. **Report Issues** - Found a bug? [Open an issue](https://github.com/itcmsgr/nftban/issues)
2. **Suggest Features** - Have an idea? [Start a discussion](https://github.com/itcmsgr/nftban/discussions)
3. **Improve Documentation** - Spotted an error? Submit a PR
4. **Add Control Panel Support** - Submit new panel templates
5. **Fix Bugs** - Send a pull request

### Development Guidelines

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/nftban.git
cd nftban

# Create feature branch
git checkout -b feature/my-new-feature

# Make changes
nano nftban_init_nftables_conf.sh

# Test thoroughly
sudo ./nftban_init_nftables_conf.sh --run-tests
sudo ./nftban_init_nftables_conf.sh --test
sudo ./nftban_init_nftables_conf.sh --dry-run

# Test on multiple distributions
# - Debian 11/12
# - Ubuntu 20.04/22.04/24.04
# - Rocky Linux 8/9
# - AlmaLinux 8/9

# Commit
git add .
git commit -m "feat: Add my new feature"

# Push and create PR
git push origin feature/my-new-feature
```

### Code Style

- **ShellCheck**: Must pass with no errors
- **Indentation**: 2 spaces
- **Functions**: Clear names, documented
- **Error Handling**: Use `set -euo pipefail`
- **Comments**: Explain complex logic

### Testing Checklist

- [ ] Runs on Debian/Ubuntu
- [ ] Runs on RHEL/Rocky/AlmaLinux
- [ ] Unit tests pass (`--run-tests`)
- [ ] Syntax validation passes (`--test`)
- [ ] No ShellCheck errors
- [ ] Documentation updated
- [ ] Examples added

---

## 📜 License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025 **Antonios Voulvoulis – ITCMS**  
https://itcms.gr

### Quick Summary

✅ **You CAN:**
- Use for personal/commercial projects
- Modify and customize
- Deploy on unlimited systems
- Include in services

❌ **You CANNOT:**
- Sell the software itself
- Sublicense or resell
- Remove copyright notices

📧 **Contact**: contact@itcms.gr  
🌐 **Web**: https://itcms.gr

[Full License Text](../LICENSE.md) | [Main Project](https://github.com/itcmsgr/nftban)

---

## 📞 Support

### Community Support

- **Issues**: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation**: [Complete Guide](../docs/README_COMPLETE.md)
- **Main Project**: [nftban Repository](https://github.com/itcmsgr/nftban)

### Professional Support

- **Author**: Antonios Voulvoulis (ITCMS Team)
- **Email**: support@itcms.gr
- **Website**: https://itcms.gr

### Related Documentation

- [nftban Main README](../README.md)
- [System Preparation Script](../docs/README_nftban_init.md)
- [Fail2ban Integration](../docs/README_nftban_fail2ban.md)
- [CLI Tool](../docs/README_nftban_cli.md)
- [Complete Guide](../docs/README_COMPLETE.md)

---

## 📚 Additional Resources

- [nftables Wiki](https://wiki.nftables.org/)
- [nftables Scripting](https://wiki.nftables.org/wiki-nftables/index.php/Scripting)
- [netfilter Documentation](https://www.netfilter.org/documentation/)
- [Linux Firewall Best Practices](https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html)

---

## 🎯 Quick Reference

### Essential Commands

```bash
# Help
sudo ./nftban_init_nftables_conf.sh --help

# Test
sudo ./nftban_init_nftables_conf.sh --test

# Apply
sudo ./nftban_init_nftables_conf.sh --install-final

# Validate
sudo ./nftban_init_nftables_conf.sh --validate-only

# Fail2ban setup
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action
```

### Important Files

```bash
# Generated firewall
/etc/nftban/config/nft_rules.conf.local

# Applied firewall
/etc/nftables.conf

# User ports
/etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# User whitelist
/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Logs
/etc/nftban/logs/validation_$(date +%F).log

# Backups
/etc/nftban/backups/
```

### Quick Checks

```bash
# Check firewall status
sudo nft list ruleset

# View whitelist
sudo nft list set inet nftban_global whitelist_v4

# View banned IPs
sudo nft list set inet nftban_global temp_ban_v4

# Check if IP is whitelisted
sudo nft get element inet nftban_global whitelist_v4 { YOUR_IP }
```

---

<p align="center">
  <strong>Part of the <a href="https://github.com/itcmsgr/nftban">nftban</a> project</strong><br>
  <sub>Modern Linux firewall management system</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Main Project</a> •
  <a href="../docs/README_COMPLETE.md">📚 Complete Docs</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Issues</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 ITCMS</a>
</p>

<p align="center">
  <sub>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></sub><br>
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>

---

**⭐ If this script helps secure your servers, please [star the project](https://github.com/itcmsgr/nftban)!**
