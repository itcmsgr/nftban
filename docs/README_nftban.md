# nftban - Complete Documentation

**Modular Linux Firewall Management System based on nftables & Fail2Ban**

[![Version](https://img.shields.io/badge/version-0.9.0--beta-orange)](https://github.com/itcmsgr/nftban)
[![Architecture](https://img.shields.io/badge/architecture-dual--table-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A comprehensive, production-ready firewall management system that combines nftables (modern Linux firewall) with Fail2Ban (intrusion prevention) to provide enterprise-grade security with simple, user-friendly management tools.

> **📌 v0.9.0 ARCHITECTURE UPDATE**
>
> This document contains examples using the OLD v0.8.5 architecture for reference.
> Many code examples show `inet nftban_global` table structure.
>
> **For v0.9.0:**
> - Tables: `ip nftban_v4` + `ip6 nftban_v6` (NOT `inet nftban_global`)
> - Sets: `whitelist`, `temp_ban` (NO `_v4/_v6` suffix)
> - Rules simplified (no `ip saddr`/`ip6 saddr` selectors)
>
> See [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md) for migration guide.
> See [ARCHITECTURE.md](ARCHITECTURE.md) for updated technical details.

---

## 📖 Table of Contents

1. [What is nftban?](#what-is-nftban)
2. [Why nftban?](#why-nftban)
3. [System Architecture](#system-architecture)
4. [Core Components](#core-components)
5. [Installation Guide](#installation-guide)
6. [Configuration System](#configuration-system)
7. [Control Panel Integration](#control-panel-integration)
8. [Security Features](#security-features)
9. [Management Tools](#management-tools)
10. [Advanced Features](#advanced-features)
11. [Troubleshooting](#troubleshooting)
12. [Technical Reference](#technical-reference)
13. [License](#license)
14. [Support](#support)

---

## What is nftban?

nftban is a **complete firewall management ecosystem** for Linux servers that makes advanced network security accessible to everyone - from beginners to system administrators. It bridges the gap between raw nftables commands and user-friendly operations.

### The Problem nftban Solves

**Traditional approach:**
```bash
# Complex nftables syntax - hard to remember
nft add rule inet filter input tcp dport 8080 accept

# Manual fail2ban configuration - time-consuming
vim /etc/fail2ban/jail.local

# No coordination between components
# No unified management interface
# Error-prone manual configuration
```

**nftban approach:**
```bash
# Simple installation
sudo nftban_init.sh --github -y

# Add custom port with one line
echo "8080T" >> /etc/nftban/config/ports-allow.conf.local

# Apply changes
sudo nftban_init_nftables_conf.sh --install-final

# Ban an attacker
sudo nftban --temp-ban 192.0.2.50 "SSH brute-force"

# Everything works together automatically
```

### What Makes nftban Different

| Feature | Traditional Setup | nftban |
|---------|------------------|---------|
| **Setup Time** | Hours of manual config | 5-10 minutes automated |
| **Configuration** | Edit raw config files | Simple .conf.local files |
| **Control Panels** | Manual port discovery | Automatic detection |
| **Fail2Ban Integration** | Complex manual setup | Automatic integration |
| **IP Management** | Command-line nft/iptables | Simple CLI commands |
| **Validation** | Manual syntax checking | Automatic validation |
| **Updates** | Manual re-configuration | Auto-update support |
| **Learning Curve** | Steep (weeks) | Gentle (hours) |

---

## Why nftban?

### For System Administrators

✅ **Time Savings**
- 10-minute setup vs hours of manual configuration
- Automated control panel detection
- Pre-configured security rules
- One-command operations

✅ **Reliability**
- Tested on 9+ Linux distributions
- Battle-tested in production environments
- Automatic configuration validation
- Safe rollback mechanisms

✅ **Maintainability**
- Separated concerns (base vs user config)
- Clear documentation for every component
- Auto-update capability
- Version-controlled configurations

### For Security Engineers

✅ **Defense in Depth**
- nftables (packet filtering)
- Fail2Ban (intrusion prevention)
- Login monitoring
- Rate limiting
- Whitelist/blacklist management

✅ **Comprehensive Logging**
- All operations logged
- Ban/unban tracking
- Login monitoring logs
- Configuration change history

✅ **Flexibility**
- Modular architecture
- Extensible jail system
- Custom filter support
- API-like CLI interface

### For Hosting Providers

✅ **Multi-Panel Support**
- DirectAdmin
- cPanel/WHM
- Plesk
- Generic (any panel or no panel)

✅ **Template System**
- Pre-configured panel ports
- Easy customization
- Version-controlled templates
- Safe upgrades

✅ **Client Safety**
- Whitelist protection prevents lockouts
- Current IP auto-detection
- Validation before applying changes
- Emergency recovery procedures

---

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        nftban System                         │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │            Installation & Setup Layer               │    │
│  │                                                      │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │   nftban_init.sh                            │  │    │
│  │  │   • Package installation                    │  │    │
│  │  │   • Directory structure                     │  │    │
│  │  │   • Control panel detection                 │  │    │
│  │  │   • Template creation                       │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────┘    │
│                          ↓                                   │
│  ┌────────────────────────────────────────────────────┐    │
│  │         Firewall Configuration Layer               │    │
│  │                                                      │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │   nftban_init_nftables_conf.sh              │  │    │
│  │  │   • Reads templates + .conf.local           │  │    │
│  │  │   • Generates nftables rules                │  │    │
│  │  │   • Creates global table & sets             │  │    │
│  │  │   • Applies firewall configuration          │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────┘    │
│                          ↓                                   │
│  ┌────────────────────────────────────────────────────┐    │
│  │       Intrusion Prevention Layer                   │    │
│  │                                                      │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │   nftban_init_fail2ban_conf.sh              │  │    │
│  │  │   • Fail2Ban with nftables backend          │  │    │
│  │  │   • Jail configuration                      │  │    │
│  │  │   • Login monitoring                        │  │    │
│  │  │   • Email alerts                            │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────┘    │
│                          ↓                                   │
│  ┌────────────────────────────────────────────────────┐    │
│  │            Daily Operations Layer                  │    │
│  │                                                      │    │
│  │  ┌─────────────────────────────────────────────┐  │    │
│  │  │   nftban CLI                                 │  │    │
│  │  │   • Ban/unban operations                    │  │    │
│  │  │   • Whitelist/blacklist management          │  │    │
│  │  │   • Status monitoring                       │  │    │
│  │  │   • Validation & sync                       │  │    │
│  │  └─────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Configuration Files                    Active System
─────────────────                     ─────────────

Templates/                             nftables
  control-panels/        ─────┐          │
    directadmin.conf          │          │
    cpanel.conf               │          ├─ Table: inet nftban_global
    generic.conf              │          │    ├─ Sets (whitelist_v4/v6)
                              ├──────────┤    ├─ Sets (blacklist_v4/v6)
.conf.local files             │          │    └─ Sets (temp_ban_v4/v6)
  ports-allow.conf.local      │          │
  whitelist_ips.conf.local ───┘          ├─ Chains (input/output/forward)
  blacklist_ips.conf.local               └─ Rules (drop/accept)

                                       Fail2Ban
nftban.conf                              │
nftban.conf.local        ─────────────> ├─ Jails (ssh, wordpress, etc)
                                         ├─ Filters (regex patterns)
                                         └─ Actions (nftban-global)

                                       Login Monitor
                                         │
                                         ├─ Live service (real-time)
                                         ├─ Periodic timer (digest)
                                         └─ Email alerts
```

### Component Interaction

```
User Action                     System Response
───────────                    ────────────────

nftban --temp-ban IP ────────> 1. Validates IP
                                2. Checks whitelist
                                3. Adds to temp_ban_v4/v6 set
                                4. Logs action
                                5. IP blocked immediately

SSH attack detected ──────────> 1. Fail2Ban sees failed login
                                2. Increments counter
                                3. Reaches threshold
                                4. Calls nftban-global action
                                5. IP added to temp_ban set
                                6. Email alert sent (optional)

Edit .conf.local ──────────────> 1. User edits configuration
                                2. Runs --install-final
                                3. Script validates syntax
                                4. Merges with base config
                                5. Generates nftables rules
                                6. Applies atomically
                                7. Backups created
```

---

## Core Components

### 1. nftban_init.sh - System Preparation

**Purpose**: Bootstrap the nftban system

**What It Does**:
- Installs required packages (nftables, fail2ban, utilities)
- Creates directory structure (`/etc/nftban/`)
- Detects installed control panel
- Creates templates for ALL panels
- Initializes empty `.conf.local` files
- Sets up auto-update system (optional)

**Does NOT Do**:
- Configure firewall
- Apply any rules
- Modify system files
- Start services

**Key Features**:
- Multiple installation methods (GitHub/ZIP/Local)
- Automatic control panel detection
- Template creation for future use
- Safe re-runs (preserves customizations)

**When to Use**:
- First-time setup
- After clean OS installation
- When adding nftban to existing server
- After major system updates

**Example**:
```bash
# Basic installation
sudo ./nftban_init.sh --github -y

# With auto-update
sudo ./nftban_init.sh --github -y --enable-auto-update

# Custom installation path
sudo ./nftban_init.sh --github -y --target /opt/nftban
```

**Output Structure**:
```
/etc/nftban/
├── config/                           # Empty .conf.local files
├── templates/
│   └── control-panels/               # All panel templates
│       ├── directadmin.conf
│       ├── cpanel.conf
│       ├── plesk.conf
│       └── generic.conf
├── scripts/                          # Management scripts
├── bin/                              # nftban CLI
└── logs/                             # Log files
```

[Full Documentation: README_nftban_init.md](README_nftban_init.md)

---

### 2. nftban_init_nftables_conf.sh - Firewall Configuration

**Purpose**: Configure and manage nftables firewall

**What It Does**:
- Reads control panel template
- Merges with `.conf.local` files
- Generates nftables rules
- Creates global table structure
- Applies firewall configuration
- Validates before applying

**Key Concepts**:

**Two-File System**:
```
Base Configuration              User Configuration
(from template)          +      (.conf.local)
──────────────────              ─────────────────
SSH: 22                         Custom: 8080
HTTP: 80                        Custom: 3000
Panel: 2222                     Custom: 9090
                                
                    ↓ Merged ↓
                    
Applied Configuration
─────────────────────
22, 80, 2222, 8080, 3000, 9090
```

**Global Table Structure**:
```
table inet nftban_global {
    # Whitelist sets (IPv4 & IPv6)
    set whitelist_v4 { type ipv4_addr; }
    set whitelist_v6 { type ipv6_addr; }
    
    # Blacklist sets (IPv4 & IPv6)
    set user_blacklist_v4 { type ipv4_addr; }
    set user_blacklist_v6 { type ipv6_addr; }
    set system_blacklist_v4 { type ipv4_addr; }
    set system_blacklist_v6 { type ipv6_addr; }
    
    # Temporary ban sets (with timeout)
    set temp_ban_v4 { type ipv4_addr; flags timeout; }
    set temp_ban_v6 { type ipv6_addr; flags timeout; }
    
    # Input chain (incoming traffic)
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established connections
        ct state established,related accept
        
        # Allow loopback
        iif lo accept
        
        # Whitelist check (highest priority)
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
        
        # Blacklist check
        ip saddr @temp_ban_v4 drop
        ip6 saddr @temp_ban_v6 drop
        ip saddr @user_blacklist_v4 drop
        ip6 saddr @user_blacklist_v6 drop
        
        # Allow specific ports
        tcp dport { 22, 80, 443, 2222, 8080 } accept
        udp dport { 53 } accept
        
        # ICMP
        icmp type echo-request limit rate 5/second accept
    }
    
    # Output chain (outgoing traffic)
    chain output {
        type filter hook output priority 0; policy accept;
    }
    
    # Forward chain (routing)
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
}
```

**Key Features**:
- Atomic rule application (all-or-nothing)
- Automatic backup before changes
- Syntax validation
- Lock file protection
- Dry-run mode

**When to Use**:
- After nftban_init.sh
- When adding custom ports
- When changing configuration
- After updating templates

**Common Commands**:
```bash
# Initial setup (applies firewall)
sudo nftban_init_nftables_conf.sh --install-final

# Show what would be applied (dry-run)
sudo nftban_init_nftables_conf.sh --dry-run

# List current IP sets
sudo nftban_init_nftables_conf.sh --list-ipsets

# Flush and restart
sudo nftban_init_nftables_conf.sh --flush --install-final
```

[Full Documentation: README_nftban_init_nftables_conf.md](README_nftban_init_nftables_conf.md)

---

### 3. nftban_init_fail2ban_conf.sh - Intrusion Prevention

**Purpose**: Configure Fail2Ban to automatically ban attackers

**What It Does**:
- Configures Fail2Ban with nftables backend
- Creates jail configurations for services
- Sets up email alerts
- Installs login monitoring
- Manages ban/unban actions

**Architecture**:

```
Attack Scenario:
──────────────

Attacker → SSH Brute Force
    ↓
Journal Logs: "Failed password for root from 192.0.2.50"
    ↓
Fail2Ban Filter: Detects pattern
    ↓
Fail2Ban Counter: Increments (3 failures)
    ↓
Threshold Reached (maxretry = 3)
    ↓
Fail2Ban Action: nftban-global
    ↓
nftables: Add 192.0.2.50 to temp_ban_v4 set (1 hour)
    ↓
Email Alert: "IP 192.0.2.50 banned in jail sshd"
    ↓
Attacker Blocked at Firewall Level
```

**Configuration Hierarchy**:
```
System Configuration                User Configuration
────────────────────               ───────────────────
nftban.conf (base)          +      nftban.conf.local
- Default ban times                - Your email
- Default thresholds               - Custom ban times
- Default jails                    - Enabled jails
- Reference values                 - Your settings

                ↓ Merged ↓

Active Configuration
───────────────────
User settings override base
```

**Available Jails**:

| Jail | Service | Default | Ban Time | Max Retry | Find Time |
|------|---------|---------|----------|-----------|-----------|
| **SSH** | SSH daemon | ✅ | 30 min | 3 | 10 min |
| **Apache** | Apache web server | ❌ | 1 hour | 5 | 10 min |
| **Nginx** | Nginx web server | ❌ | 1 hour | 5 | 10 min |
| **Postfix** | Mail server | ❌ | 1 hour | 5 | 10 min |
| **WordPress** | WP login | ✅ | 2 hours | 3 | 10 min |
| **XML-RPC** | WP API | ✅ | 3 hours | 2 | 5 min |
| **DirectAdmin** | DA panel | ✅ | 4 hours | 3 | 10 min |

**Login Monitoring**:

nftban includes advanced login monitoring with three modes:

**Mode 1: Live Service (Real-Time)**
```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable service
```
- Monitors journald in real-time
- Immediate email alerts
- Tracks failed logins, SSH access, sudo usage, root logins
- Can auto-ban with aggressive mode

**Mode 2: Periodic Timer (Digest)**
```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable timer
```
- Runs every 10 minutes (configurable)
- Sends digest email reports
- Lower resource usage
- Historical analysis

**Mode 3: Hybrid (Both)**
```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable hybrid
```
- Real-time critical alerts
- Plus periodic digests
- Best for production

**Key Features**:
- Base + local configuration pattern
- Email alert system with multi-MTA support
- Login monitoring (3 modes)
- Ban rate limiting
- Configuration validation
- Backup and restore

**When to Use**:
- After nftban_init_nftables_conf.sh
- When enabling intrusion prevention
- When setting up email alerts
- When configuring login monitoring

**Common Commands**:
```bash
# Initial setup
sudo nftban_init_fail2ban_conf.sh setup

# Validate configuration
sudo nftban_init_fail2ban_conf.sh validate-config

# Test email
sudo nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Check status
sudo nftban_init_fail2ban_conf.sh status

# Show statistics
sudo nftban_init_fail2ban_conf.sh stats

# Backup configuration
sudo nftban_init_fail2ban_conf.sh backup-config
```

[Full Documentation: README_nftban_fail2ban.md](README_nftban_fail2ban.md)

---

### 4. nftban CLI - Daily Operations Tool

**Purpose**: User-friendly interface for daily firewall management

**What It Does**:
- Ban/unban IP addresses
- Manage whitelist/blacklist
- Check system status
- Validate synchronization
- View banned IPs
- Integrate with Fail2Ban

**Command Categories**:

**IP Management**:
```bash
# Whitelist your current IP
nftban --add-ip

# Whitelist specific IP
nftban --add-ip 203.0.113.50

# Check IP status
nftban --info

# Comprehensive IP check
nftban --verify-ip 192.0.2.50
```

**Ban Operations**:
```bash
# Temporary ban (1 hour)
nftban --temp-ban 192.0.2.50 "SSH brute-force"

# Permanent ban
nftban --perm-ban 192.0.2.50 "Confirmed attacker"

# List temp bans
nftban --list-temp

# View all bans
nftban --view-banned

# Remove from everywhere
nftban --remove-ip 192.0.2.50
```

**Validation & Sync**:
```bash
# Check if files match active sets
nftban --validate-sync

# Show all nftables sets
nftban --show-sets

# Reload from configuration files
nftban --sync
```

**Service Management**:
```bash
# Check status
nftban status

# Start services
nftban --start

# Restart services
nftban --restart

# Stop services
nftban --stop
```

**Fail2Ban Integration**:
```bash
# List jails
nftban --fail2ban-jails

# Show banned IPs
nftban --fail2ban-banned

# View jail rules
nftban --fail2ban-rules sshd
```

**Key Features**:
- Protection against locking yourself out
- Whitelist checking before banning
- Multi-source IP verification (files + active sets + fail2ban)
- Comprehensive error messages
- Color-coded output
- Detailed logging

**Safety Mechanisms**:
```bash
# Prevents banning your own IP
nftban --temp-ban YOUR_CURRENT_IP
# Error: Cannot ban your own login IP

# Prevents banning whitelisted IPs
nftban --temp-ban WHITELISTED_IP
# Error: Cannot ban whitelisted IP

# Validates before applying
nftban --temp-ban INVALID_IP
# Error: Invalid IP address format
```

**Common Workflows**:

**Scenario 1: New Server Setup**
```bash
# 1. Whitelist your management IPs
nftban --add-ip 203.0.113.100
nftban --add-ip 203.0.113.101

# 2. Check status
nftban status

# 3. Enable services
nftban --enable
```

**Scenario 2: Handling an Attack**
```bash
# 1. Verify the attacker IP
nftban --verify-ip 192.0.2.50

# 2. Temp ban to stop attack
nftban --temp-ban 192.0.2.50 "SSH brute-force"

# 3. If attack persists, permanent ban
nftban --perm-ban 192.0.2.50

# 4. Check other banned IPs
nftban --view-banned
```

**Scenario 3: Configuration Sync**
```bash
# 1. Edit configuration
nano /etc/nftban/config/ports-allow.conf.local

# 2. Validate changes
nftban --validate-sync

# 3. Apply changes
nftban --sync

# 4. Verify
nftban status
```

[Full Documentation: README_nftban_cli.md](README_nftban_cli.md)

---

## Installation Guide

### Complete Installation Workflow

```
Step 1: System Preparation
───────────────────────────
$ sudo ./nftban_init.sh --github -y

What happens:
✓ Installs nftables, fail2ban, utilities
✓ Creates /etc/nftban/ structure
✓ Detects control panel (e.g., DirectAdmin)
✓ Creates ALL control panel templates
✓ Creates empty .conf.local files
✓ System ready but NOT configured

Result: Foundation prepared
├── Directory structure: ✓
├── Required packages: ✓
├── Templates created: ✓
├── Configuration files initialized: ✓
└── Next step required: Configure firewall

───────────────────────────

Step 2: Firewall Configuration
───────────────────────────────
$ sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

What happens:
✓ Reads detected control panel template
✓ Reads your .conf.local customizations
✓ Merges both sources
✓ Generates nftables rules
✓ Creates inet nftban_global table
✓ Creates all sets (whitelist, blacklist, temp_ban)
✓ Applies firewall configuration
✓ Validates syntax
✓ Creates backup

Result: Firewall active
├── nftables table created: ✓
├── Port rules applied: ✓
├── Whitelist/blacklist loaded: ✓
├── Configuration backed up: ✓
└── Server protected: ✓

───────────────────────────

Step 3: Intrusion Prevention (Optional but Recommended)
────────────────────────────────────────────────────────
$ sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

What happens:
✓ Configures Fail2Ban with nftables backend
✓ Creates jail configurations
✓ Sets up email alerts (if MTA available)
✓ Prepares login monitoring

Result: Intrusion prevention ready
├── Fail2Ban configured: ✓
├── Jails created: ✓
├── Email alerts configured: ✓
└── Ready to enable: ✓

Optional: Enable login monitoring
$ sudo nftban_init_fail2ban_conf.sh login-monitor enable service

Optional: Start Fail2Ban
$ sudo systemctl restart fail2ban

───────────────────────────

Step 4: Daily Management
─────────────────────────
Use the nftban CLI for all operations:

$ sudo nftban status              # Check system
$ sudo nftban --add-ip            # Whitelist your IP
$ sudo nftban --temp-ban IP       # Ban attacker
$ sudo nftban --validate-sync     # Verify configuration

Result: System fully operational
```

### Quick Start (3 Commands)

```bash
# 1. Install and prepare
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# 2. Configure firewall
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# 3. Setup intrusion prevention
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban

# Done! Your server is protected.
```

### Detailed Installation

#### Prerequisites

**Operating System**:
- Debian 10+ / Ubuntu 20.04+
- RHEL 8+ / CentOS 8+ / Rocky Linux 8+ / AlmaLinux 8+
- Fedora 35+
- openSUSE Leap 15+
- Alpine Linux 3.15+

**Requirements**:
- Root access (sudo)
- Internet connection (for GitHub/ZIP methods)
- 1 GB free disk space
- systemd

**Optional**:
- Control panel (DirectAdmin, cPanel, Plesk)
- MTA for email alerts (Postfix, Exim, MSMTP)
- Python 3.x for login monitoring

#### Step-by-Step Installation

**1. Download nftban**

Option A: GitHub Clone
```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
chmod +x nftban_init.sh
```

Option B: Direct Download
```bash
wget https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh
chmod +x nftban_init.sh
```

Option C: Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y
```

**2. Run System Preparation**

```bash
# Basic installation
sudo ./nftban_init.sh --github -y

# With auto-update (recommended)
sudo ./nftban_init.sh --github -y --enable-auto-update

# Custom installation path
sudo ./nftban_init.sh --github -y --target /opt/nftban

# Verify installation
ls -la /etc/nftban/
```

**3. Customize Configuration (Optional)**

```bash
# Add custom ports
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
echo "3000T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Add your office IP to whitelist
echo "203.0.113.100 # Office IP" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# View template that will be used
cat /etc/nftban/templates/control-panels/directadmin.conf
```

**4. Configure Firewall**

```bash
# Apply configuration
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify nftables is running
sudo systemctl status nftables

# Verify table created
sudo nft list table inet nftban_global

# Test connectivity
# Try SSHing from another terminal
# Make sure you can still connect!
```

**5. Setup Fail2Ban**

```bash
# Configure Fail2Ban
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

# Edit configuration
sudo nano /etc/nftban/config/nftban.conf.local

# Key settings to change:
NFTBAN_F2B_RECIPIENT="your-email@example.com"
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"

# Test email (if MTA configured)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail your-email@example.com

# Restart Fail2Ban
sudo systemctl restart fail2ban

# Verify jails
sudo fail2ban-client status
```

**6. Enable Login Monitoring (Optional)**

```bash
# Install login monitor
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor install

# Enable live monitoring (real-time)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable service

# Or enable periodic digest (every 10 minutes)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable timer

# Or both (hybrid)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable hybrid

# Check status
sudo systemctl status nftban_lfd.service
```

**7. Verify Installation**

```bash
# Check system status
sudo nftban status

# Should show:
# ✓ nftables: active
# ✓ fail2ban: active
# ✓ Global table: exists
# ✓ Configuration: valid

# Add your IP to whitelist
sudo nftban --add-ip

# Test ban (use a non-critical IP!)
sudo nftban --temp-ban 192.0.2.1 "Test ban"

# Verify ban
sudo nftban --list-temp

# Remove test ban
sudo nftban --remove-ban 192.0.2.1
```

---

## Configuration System

### Configuration Philosophy

nftban uses a **two-file configuration pattern**:

```
Base Configuration (System)     User Configuration (You)
──────────────────────────  +   ─────────────────────────
.conf (auto-managed)             .conf.local (preserved)
- Created by scripts             - Your customizations
- Updated on upgrades            - Never overwritten
- Reference defaults             - Override base settings
- Template-derived               - Survive updates
```

### Configuration Hierarchy

```
Priority (Highest to Lowest):

1. .conf.local (User Configuration)
   └─ /etc/nftban/config/*.conf.local
      - Your custom settings
      - Highest priority
      - Never touched by scripts

2. .conf (Base Configuration)
   └─ /etc/nftban/config/*.conf
      - System defaults
      - Auto-managed
      - Can be regenerated

3. Templates
   └─ /etc/nftban/templates/control-panels/
      - Control panel defaults
      - Used to generate .conf files
      - Detected on setup
```

### Configuration Files

#### Firewall Configuration

**Port Configuration**:
```
Base (from template):
/etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf

User (your additions):
/etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

Format:
22T              # TCP port 22
80T              # TCP port 80
53U              # UDP port 53
3306B            # Both TCP and UDP port 3306
8000-8010T       # TCP port range 8000-8010
```

**IP Whitelist**:
```
User whitelist:
/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

System whitelist (auto-managed):
/etc/nftban/config/nftban-configuration-system_whitelist_ips.conf.local

Format:
203.0.113.100              # Single IPv4
2001:db8::1                # Single IPv6
192.168.1.0/24             # IPv4 subnet
2001:db8::/32              # IPv6 subnet
```

**IP Blacklist**:
```
User blacklist:
/etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local

System blacklists:
/etc/nftban/config/nftban-configuration-ipv4-blacklist_ips.conf.local
/etc/nftban/config/nftban-configuration-ipv6-blacklist_ips.conf.local

Format: Same as whitelist
```

#### Fail2Ban Configuration

**Base Configuration**:
```
/etc/nftban/config/nftban.conf

# DO NOT EDIT THIS FILE
# It's regenerated by scripts
# Put your changes in nftban.conf.local
```

**User Configuration**:
```
/etc/nftban/config/nftban.conf.local

# Your settings - this file is preserved

# Email Settings
NFTBAN_F2B_RECIPIENT="admin@example.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ALERT_ENABLED="true"

# Default Settings
NFTBAN_F2B_DEF_BAN_TIME="3600"        # 1 hour
NFTBAN_F2B_DEF_FIND_TIME="600"        # 10 minutes
NFTBAN_F2B_DEF_MAX_RETRY="5"          # 5 attempts

# Enable/Disable Jails
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_APACHE_JAIL="false"

# Login Monitoring
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"
```

### Configuration Examples

#### Example 1: Adding Custom Web Server Port

```bash
# Add port 8080 for custom application
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify
sudo nft list ruleset | grep 8080
```

#### Example 2: Whitelisting Office Network

```bash
# Add office subnet to whitelist
cat >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local <<EOF
# Office Network
203.0.113.0/24
2001:db8:1::/48
EOF

# Reload configuration
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Or use nftban CLI
sudo nftban --sync
```

#### Example 3: Custom Fail2Ban Settings

```bash
# Edit user configuration
sudo nano /etc/nftban/config/nftban.conf.local

# Change settings
NFTBAN_F2B_SSH_BAN_TIME="7200"        # 2 hours instead of 30 min
NFTBAN_F2B_SSH_MAX_RETRY="2"          # 2 attempts instead of 3
NFTBAN_F2B_WORDPRESS_JAIL="true"      # Enable WordPress protection

# Validate
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh validate-config

# Apply
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban
```

#### Example 4: Multiple Services on Non-Standard Ports

```bash
# Application uses multiple ports
cat >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local <<EOF
# Custom Application
8080T            # HTTP alternative
8443T            # HTTPS alternative
9000T            # API endpoint
9001T            # WebSocket
5432T            # PostgreSQL
6379T            # Redis
11211T           # Memcached
EOF

# Apply
sudo nftban --sync

# Verify
sudo nft list table inet nftban_global | grep -E '8080|8443|9000|9001|5432|6379|11211'
```

---

## Control Panel Integration

nftban automatically detects and configures for popular control panels.

### Supported Panels

#### DirectAdmin

**Detection**: `/usr/local/directadmin/`

**Pre-configured Ports**:
```
TCP Input:
- 20, 21          # FTP
- 22              # SSH (auto-detected)
- 25              # SMTP
- 53              # DNS
- 80, 443         # HTTP/HTTPS
- 110             # POP3
- 143             # IMAP
- 465             # SMTPS
- 587             # Submission
- 993             # IMAPS
- 995             # POP3S
- 2222            # DirectAdmin Panel
- 35000-35999     # FTP Passive Range

UDP Input:
- 53              # DNS
```

**Template**: `/etc/nftban/templates/control-panels/directadmin.conf`

#### cPanel/WHM

**Detection**: `/var/cpanel/`

**Pre-configured Ports**:
```
TCP Input:
- 20, 21          # FTP
- 22              # SSH
- 25, 465, 587    # Mail
- 53              # DNS
- 80, 443         # HTTP/HTTPS
- 110, 143, 993, 995  # Mail
- 2082, 2083      # cPanel
- 2086, 2087      # WHM
- 2089            # cPHulk
- 2095, 2096      # Webmail
- 3306            # MySQL (local)

UDP Input:
- 53              # DNS
```

**Template**: `/etc/nftban/templates/control-panels/cpanel.conf`

#### Plesk

**Detection**: `/usr/local/psa/`

**Pre-configured Ports**:
```
TCP Input:
- 20, 21          # FTP
- 22              # SSH
- 25, 465, 587    # Mail
- 53              # DNS
- 80, 443         # HTTP/HTTPS
- 110, 143, 993, 995  # Mail
- 3306            # MySQL
- 5432            # PostgreSQL
- 8443            # Plesk Panel (HTTPS)
- 8880            # Plesk Panel (HTTP)

UDP Input:
- 53              # DNS
```

**Template**: `/etc/nftban/templates/control-panels/plesk.conf`

#### Generic (No Panel)

**Detection**: No control panel found

**Pre-configured Ports**:
```
TCP Input:
- 22              # SSH (auto-detected)
- 25              # SMTP
- 53              # DNS
- 80, 443         # HTTP/HTTPS

UDP Input:
- 53              # DNS
```

**Template**: `/etc/nftban/templates/control-panels/generic.conf`

### How Panel Detection Works

```
nftban_init.sh runs
    ↓
Check /usr/local/directadmin/ → Found? → DirectAdmin
    ↓ No
Check /var/cpanel/ → Found? → cPanel/WHM
    ↓ No
Check /usr/local/psa/ → Found? → Plesk
    ↓ No
Use Generic → No panel detected
    ↓
Create ALL templates regardless
    ↓
Store detection result for later use
    ↓
nftban_init_nftables_conf.sh reads result
    ↓
Uses appropriate template
```

### Customizing Panel Configuration

**Option 1: Edit Template (Before Setup)**
```bash
# Edit template before applying
sudo nano /etc/nftban/templates/control-panels/directadmin.conf

# Change as needed
TCP_IN = "20,21,22,25,53,80,443,2222,8080,35000-35999"

# Apply
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**Option 2: Add to .conf.local (After Setup)**
```bash
# Add extra ports without modifying template
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply
sudo nftban --sync
```

### Multi-Panel or Custom Panel

If you have a custom or unsupported panel:

**Method 1: Create Custom Template**
```bash
# Copy generic template
sudo cp /etc/nftban/templates/control-panels/generic.conf \
        /etc/nftban/templates/control-panels/mycustompanel.conf

# Edit with your ports
sudo nano /etc/nftban/templates/control-panels/mycustompanel.conf

# Manually specify in configuration
# (Requires modifying detection logic)
```

**Method 2: Use .conf.local Files**
```bash
# List all required ports
cat >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local <<EOF
# Custom Panel Ports
8000T
8001T
8002T
9000T
EOF

# Apply
sudo nftban --sync
```

---

## Security Features

### Multi-Layer Protection

```
Layer 1: Whitelist (Highest Priority)
─────────────────────────────────────
Purpose: Allow trusted IPs unconditionally
Sources:
  • User whitelist (.conf.local)
  • System whitelist (server IPs, auto-managed)
Action: ACCEPT packet immediately
Priority: Checked FIRST

Layer 2: Temporary Bans
───────────────────────
Purpose: Block IPs for limited time
Sources:
  • Fail2Ban automatic bans
  • Manual temp-ban commands
Timeout: Default 1 hour, configurable
Action: DROP packet
Sets: temp_ban_v4, temp_ban_v6

Layer 3: Permanent Bans
───────────────────────
Purpose: Block confirmed malicious IPs
Sources:
  • Manual perm-ban commands
  • System blacklist (populated by admin)
Timeout: None (permanent until removed)
Action: DROP packet
Sets: user_blacklist_v4/v6, system_blacklist_v4/v6

Layer 4: Port Rules
───────────────────
Purpose: Allow/deny specific services
Sources:
  • Control panel template
  • User configuration
Action: ACCEPT if port open, DROP otherwise

Layer 5: Default Policy
───────────────────────
Purpose: Fallback for unconfigured traffic
Policy: DROP (deny all not explicitly allowed)
```

### Fail2Ban Jails

Each jail monitors specific log patterns and bans repeat offenders:

**SSH Jail**:
```
Monitors: /var/log/auth.log, journald
Pattern: Failed password attempts
Threshold: 3 failures in 10 minutes
Action: Ban for 30 minutes
Protection: Brute-force attacks
```

**WordPress Jail**:
```
Monitors: Apache/Nginx access logs
Pattern: Failed login to wp-login.php
Threshold: 3 failures in 10 minutes
Action: Ban for 2 hours
Protection: WP login brute-force
```

**XML-RPC Jail**:
```
Monitors: Apache/Nginx access logs
Pattern: Excessive xmlrpc.php requests
Threshold: 2 requests in 5 minutes
Action: Ban for 3 hours
Protection: WP API abuse
```

### Login Monitoring

Tracks and alerts on:

**Failed Logins**:
- SSH authentication failures
- Multiple attempts from same IP
- Threshold-based alerting (default: 5 failures)
- Can auto-ban with aggressive mode

**Successful Logins**:
- Root login alerts (optional)
- All SSH logins (optional)
- Location tracking (via GeoIP)

**Privilege Escalation**:
- Sudo command usage
- Root session openings
- User switching (su)

**Email Alert Example**:
```
Subject: [nftban-login] Failed login threshold from 192.0.2.50 (5/5)

IP: 192.0.2.50
Attempts: 5
User: root
Time: 2025-01-10 15:30:45
GeoIP: Russia

Recent failures:
  15:30:40 - Failed password for root from 192.0.2.50
  15:30:42 - Failed password for root from 192.0.2.50
  15:30:43 - Failed password for root from 192.0.2.50
  15:30:44 - Failed password for root from 192.0.2.50
  15:30:45 - Failed password for root from 192.0.2.50

Action: Automatically banned for 1 hour (aggressive mode enabled)
```

### Rate Limiting

Built-in rate limiting prevents abuse:

**ICMP (Ping)**:
```
Limit: 5 packets per second
Action: DROP excess packets
Purpose: Prevent ping flood
```

**Ban Operations**:
```
Limit: 10 bans per minute
Action: Refuse ban, log warning
Purpose: Prevent ban storms
```

**Fail2Ban Actions**:
```
Retry: 3 attempts
Timeout: 10 seconds per attempt
Purpose: Prevent action failures from cascading
```

### Validation & Safety

**Before Applying Changes**:
- ✅ Syntax validation (nft -c)
- ✅ Backup current configuration
- ✅ Lock file prevents concurrent changes
- ✅ Whitelist verification
- ✅ Dry-run mode available

**Protection Mechanisms**:
- ✅ Cannot ban your own login IP
- ✅ Cannot ban whitelisted IPs
- ✅ Invalid IPs rejected
- ✅ Dangerous characters sanitized from comments
- ✅ Path traversal prevention

**Recovery**:
- ✅ Automatic backups (30-day retention)
- ✅ Emergency flush command
- ✅ Restore from backup
- ✅ Configuration rollback

---

## Management Tools

### System Status

```bash
sudo nftban status
```

**Output**:
```
=== nftban Status ===
nftban path: /etc/nftban
nftables: v1.0.6 (Lester Gooch)
fail2ban: Fail2Ban v1.0.2

systemd unit: present
nftables service: active
Fail2Ban service: active
Global table: exists
  Temp bans: 3 IPv4, 1 IPv6

Configuration: valid
Enabled Jails: ssh, wordpress, xmlrpc, directadmin
```

### Validation Tools

**Configuration Syntax**:
```bash
sudo nftban --check
```

**Sync Status**:
```bash
sudo nftban --validate-sync
```

**Output**:
```
=== Sync Status: Files vs Active nftables Sets ===

Whitelist Synchronization:
  IPv4 Whitelist: 5 in files, 5 in whitelist_v4
    ✓ IPv4 whitelist in sync
  IPv6 Whitelist: 2 in files, 2 in whitelist_v6
    ✓ IPv6 whitelist in sync

Blacklist Synchronization:
  IPv4 User Blacklist: 10 in files, 8 in user_blacklist_v4
    ⚠  2 IPs in files but not in active set

⚠  Found 1 sync issue(s)
Run 'nftban --sync' to reload nftables configuration
```

### Monitoring

**Active Bans**:
```bash
# List temporary bans
sudo nftban --list-temp

# View all banned IPs (temp + perm + fail2ban)
sudo nftban --view-banned

# Show all nftables sets
sudo nftban --show-sets
```

**Fail2Ban Status**:
```bash
# List active jails
sudo nftban --fail2ban-jails

# Show banned IPs in specific jail
sudo nftban --fail2ban-banned sshd

# Show banned IPs in all jails
sudo nftban --fail2ban-banned
```

**Ban Statistics**:
```bash
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh stats
```

**Output**:
```
=== Ban Statistics ===

Top 10 Banned IPs:
   15  192.0.2.50
   12  203.0.113.100
    8  198.51.100.25
    5  192.0.2.75

Bans by Jail:
   20  ssh
   10  wordpress
    5  directadmin
    2  xmlrpc

Ban Timeline (last 7 days):
  2025-01-10: 12
  2025-01-09: 8
  2025-01-08: 15
  2025-01-07: 5
```

### Backup & Restore

**Create Backup**:
```bash
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh backup-config
```

**List Backups**:
```bash
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh list-backups
```

**Restore**:
```bash
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh restore-config /path/to/backup.tar.gz
```

### Logging

**Log Locations**:
```
/var/log/nftban/
├── nftban.log                        # CLI operations
├── nftban-bans.log                   # Ban/unban actions
├── nftban-setup.log                  # Setup/configuration
├── login-monitor.log                 # Login monitoring
└── login-monitor-debug.log           # Debug info
```

**View Logs**:
```bash
# Recent operations
sudo tail -f /var/log/nftban/nftban.log

# Ban history
sudo tail -f /var/log/nftban/nftban-bans.log

# Login activity
sudo tail -f /var/log/nftban/login-monitor.log
```

---

## Advanced Features

### Auto-Update System

Keep nftban up to date automatically:

```bash
# Enable auto-update (every 12 hours)
sudo ./nftban_init.sh --enable-auto-update

# Schedule daily at 3:30 AM
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"

# Check status
sudo ./nftban_init.sh --auto-update-status

# Disable
sudo ./nftban_init.sh --remove-auto-update
```

**What Gets Updated**:
- ✅ Scripts (init, nftables, fail2ban)
- ✅ CLI tool
- ✅ Templates
- ✅ Bug fixes

**What's Preserved**:
- ✅ All .conf.local files
- ✅ Whitelist/blacklist files
- ✅ Active bans
- ✅ Custom configurations

### Aggressive Mode

Automatically ban IPs that exceed thresholds:

```bash
# Enable in configuration
sudo nano /etc/nftban/config/nftban.conf.local

NFTBAN_F2B_AGGRESSIVE_MODE="true"
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"
NFTBAN_F2B_DEF_BAN_TIME="3600"

# Restart login monitor
sudo systemctl restart nftban_lfd.service
```

**How It Works**:
```
Failed Login Detected
    ↓
Counter Incremented
    ↓
Threshold Reached (5 failures)
    ↓
Automatic Ban (1 hour)
    ↓
Email Alert Sent
    ↓
Attacker Blocked
```

### GeoIP Integration

Track IP locations for better threat intelligence:

```bash
# Enable GeoIP
sudo nano /etc/nftban/config/nftban.conf.local

NFTBAN_F2B_GEOIP_ENABLE="true"
NFTBAN_F2B_WHOIS_ENABLE="true"

# Install GeoIP tools
sudo apt-get install geoip-bin geoip-database  # Debian/Ubuntu
sudo dnf install GeoIP GeoIP-data              # RHEL/CentOS
```

**Email Alerts Include**:
- Country
- City
- Organization
- ISP
- Threat intelligence (if available)

### Custom Jails

Create custom Fail2Ban jails for your applications:

**1. Create Filter**:
```bash
sudo nano /etc/fail2ban/filter.d/myapp.conf
```

```ini
[Definition]
failregex = Authentication failed for <HOST>
            Invalid token from <HOST>
ignoreregex =
```

**2. Create Jail**:
```bash
sudo nano /etc/fail2ban/jail.d/myapp.conf
```

```ini
[myapp]
enabled = true
port = 8080
filter = myapp
logpath = /var/log/myapp/access.log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-global
```

**3. Restart Fail2Ban**:
```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status myapp
```

### Integration with Monitoring Systems

**Export Metrics**:
```bash
# Get ban count
sudo nft list set inet nftban_global temp_ban_v4 | wc -l

# Get whitelist count
sudo nft list set inet nftban_global whitelist_v4 | wc -l

# Get fail2ban status
sudo fail2ban-client status | grep "Currently banned"
```

**Prometheus Integration Example**:
```bash
#!/bin/bash
# /usr/local/bin/nftban_metrics.sh

cat <<EOF
# HELP nftban_temp_bans Current temporary bans
# TYPE nftban_temp_bans gauge
nftban_temp_bans{version="ipv4"} $(nft list set inet nftban_global temp_ban_v4 | grep -c '.')
nftban_temp_bans{version="ipv6"} $(nft list set inet nftban_global temp_ban_v6 | grep -c '.')

# HELP nftban_fail2ban_jails Active Fail2Ban jails
# TYPE nftban_fail2ban_jails gauge
nftban_fail2ban_jails $(fail2ban-client status | grep -c 'Jail list')
EOF
```

---

## Troubleshooting

### Common Issues

#### Issue 1: "Global table not found"

**Symptom**:
```
ERROR: Table inet nftban_global not found
```

**Cause**: nftables initialization not run

**Solution**:
```bash
# Run nftables configuration
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify
sudo nft list table inet nftban_global
```

#### Issue 2: Cannot SSH After Setup

**Symptom**: SSH connection refused or times out

**Cause**: SSH port not in configuration or whitelist issue

**Solution**:
```bash
# From console or another server
# Check if SSH port is open
sudo nft list ruleset | grep "22"

# Add SSH port
echo "22T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Reload
sudo nftban --sync

# Or flush and reinstall (from console)
sudo nft flush ruleset
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### Issue 3: Fail2Ban Not Banning

**Symptom**: Attacks visible in logs but no bans

**Causes & Solutions**:

**Check 1: Fail2Ban Running**
```bash
sudo systemctl status fail2ban
sudo systemctl start fail2ban
```

**Check 2: Jails Enabled**
```bash
sudo fail2ban-client status
sudo nano /etc/nftban/config/nftban.conf.local
# Set NFTBAN_F2B_SSH_JAIL="true"
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban
```

**Check 3: nftables Action Working**
```bash
sudo fail2ban-client get sshd actions
# Should show: nftban-global

# Test action manually
sudo fail2ban-client set sshd banip 192.0.2.1
sudo nftban --list-temp
# Should show 192.0.2.1
```

#### Issue 4: Sync Issues

**Symptom**: Changes in .conf.local not applied

**Solution**:
```bash
# Validate sync
sudo nftban --validate-sync

# If issues found, reload
sudo nftban --sync

# Or full reload
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### Issue 5: Email Alerts Not Working

**Cause**: No MTA installed or misconfigured

**Solution**:
```bash
# Check mail system
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh check-mail

# If no MTA, install one
sudo apt-get install postfix      # Debian/Ubuntu
sudo dnf install postfix          # RHEL/CentOS

# Configure
sudo dpkg-reconfigure postfix     # Debian/Ubuntu
# Select "Internet Site"

# Test
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Check logs
sudo tail -f /var/log/mail.log
```

### Diagnostic Commands

```bash
# Comprehensive system check
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh self-test

# Check nftables syntax
sudo nft -c -f /etc/nftables.conf

# Check fail2ban syntax
sudo fail2ban-client --test

# View all configurations
sudo nftban config

# Check services
sudo systemctl status nftables
sudo systemctl status fail2ban
sudo systemctl status nftban_lfd.service

# View recent logs
sudo journalctl -u nftables -n 50
sudo journalctl -u fail2ban -n 50
```

### Emergency Recovery

#### Lost SSH Access

**From Console or VNC**:
```bash
# 1. Add your IP to whitelist
echo "YOUR_IP" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# 2. Reload firewall
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Or temporarily flush rules
sudo nft flush ruleset
# Then fix configuration and reload
```

#### Corrupted Configuration

```bash
# Restore from backup
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh list-backups
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh restore-config /path/to/backup.tar.gz

# Or regenerate from templates
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### Complete Reset

```bash
# 1. Stop services
sudo systemctl stop fail2ban
sudo systemctl stop nftables

# 2. Flush rules
sudo nft flush ruleset

# 3. Reinstall
sudo ./nftban_init.sh --github -y
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

# 4. Start services
sudo systemctl start nftables
sudo systemctl start fail2ban
```

---

## Technical Reference

### System Requirements

**Minimum**:
- CPU: 1 core
- RAM: 512 MB
- Disk: 1 GB free
- Network: Internet connection (for installation)

**Recommended**:
- CPU: 2+ cores
- RAM: 2 GB
- Disk: 5 GB free
- SSD storage

### File Structure

```
/etc/nftban/
├── bin/
│   └── nftban                    # CLI executable
├── config/
│   ├── *.conf                    # Base configurations (auto-managed)
│   └── *.conf.local              # User configurations (preserved)
├── templates/
│   ├── control-panels/           # Panel templates
│   └── fail2ban/                 # Fail2Ban templates
├── scripts/
│   ├── nftban_init.sh
│   ├── nftban_init_nftables_conf.sh
│   ├── nftban_init_fail2ban_conf.sh
│   └── nftban_auto_update.sh
├── logs/ → /var/log/nftban/      # Symlink to logs
└── backups/                      # Configuration backups

/var/log/nftban/
├── nftban.log
├── nftban-bans.log
├── nftban-setup.log
├── login-monitor.log
└── login-monitor-debug.log

/etc/nftables.conf                # Main nftables configuration
/etc/systemd/system/
├── nftban_lfd.service            # Login monitor (live)
├── nftban-login-scan.service     # Login monitor (scan)
└── nftban-login-scan.timer       # Login monitor (timer)

/usr/local/bin/
└── nftban → /etc/nftban/bin/nftban  # Symlink
```

### Port Numbering

```
Control Panel Ports:
────────────────────
DirectAdmin:  2222
cPanel:       2082, 2083, 2086, 2087, 2095, 2096
Plesk:        8443, 8880

Standard Services:
─────────────────
SSH:          22
HTTP:         80
HTTPS:        443
SMTP:         25
SMTPS:        465
Submission:   587
POP3:         110
POP3S:        995
IMAP:         143
IMAPS:        993
DNS:          53 (TCP/UDP)
FTP:          20, 21
FTP Passive:  35000-35999 (DirectAdmin)
MySQL:        3306
PostgreSQL:   5432
```

### Performance Tuning

**For High Traffic Servers**:
```bash
# Increase connection tracking
sudo nano /etc/sysctl.conf

net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120

# Apply
sudo sysctl -p
```

**For Large Ban Lists**:
```bash
# Use hash tables for better performance
# nftables automatically optimizes sets > 10 elements
# No manual tuning needed
```

**For Login Monitoring**:
```bash
# Use timer mode for high-traffic servers
sudo nftban_init_fail2ban_conf.sh login-monitor enable timer

# Adjust interval if needed
sudo nano /etc/nftban/config/nftban.conf.local
NFTBAN_F2B_LOGIN_TIMER_INTERVAL="15m"  # Check every 15 minutes
```

### API-Like Usage

nftban can be used programmatically:

```bash
#!/bin/bash
# Example: Automated IP management script

# Ban IP with error handling
ban_ip() {
    local ip="$1"
    local comment="$2"
    
    if sudo nftban --temp-ban "$ip" "$comment"; then
        echo "✓ Banned $ip"
        return 0
    else
        echo "✗ Failed to ban $ip"
        return 1
    fi
}

# Check if IP is banned
is_banned() {
    local ip="$1"
    sudo nftban --verify-ip "$ip" | grep -q "temp_ban"
}

# Usage
if is_banned "192.0.2.50"; then
    echo "IP already banned"
else
    ban_ip "192.0.2.50" "Automated ban from security script"
fi
```

---

## License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025  
**Antonios Voulvoulis – ITCMS** (IT Consulting Managed Services)  
https://itcms.gr

### 📋 Summary

You can **freely use, modify, and deploy** this software for personal or commercial purposes. You can charge for **services** that use this software, but you **cannot sell the software itself**.

### ✅ What You CAN Do

- Use for personal or commercial projects
- Modify and customize
- Deploy on unlimited systems
- Charge clients for services such as:
  - Installation, setup, and configuration fees
  - Ongoing hosting, monitoring, or maintenance
  - Consulting, training, or technical support
  - Custom development using the Software as a component
- Include in managed service offerings

### ❌ What You CANNOT Do

- Sell, resell, or sublicense the Software itself as a standalone product
- Bundle and sell the Software where the Software is the primary value
- Distribute the Software for a direct fee
- Remove or modify copyright notices
- Claim the Software as your own creation

### 🤔 Still Unclear? Here's the Test

**Ask yourself:** *"Am I charging for the Software itself, or for my expertise/service using the Software?"*

**Allowed:**
- Charging $500 to set up and configure firewall management on a client's server using nftban
- Monthly $100 fee for managed security services that include nftban

**NOT Allowed:**
- Selling "nftban Ultimate Edition" for $299
- Charging $50 for a "server security software bundle" where nftban is the main component

### Need Permission to Resell?

📧 Email: contact@itcms.gr  
🌐 Web: https://itcms.gr

We're open to partnership discussions and commercial arrangements!

See [LICENSE.md](./LICENSE.md) for complete legal text.

---

## Support

### Community Support

- **GitHub Issues**: [github.com/itcmsgr/nftban/issues](https://github.com/itcmsgr/nftban/issues)
- **GitHub Discussions**: [github.com/itcmsgr/nftban/discussions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation**: [github.com/itcmsgr/nftban/wiki](https://github.com/itcmsgr/nftban/wiki)

### Professional Support

- **Author**: Antonios Voulvoulis (ITCMS Team)
- **Company**: IT Consulting Managed Services
- **Email**: support@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)

### Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch
3. Test thoroughly (multiple distributions)
4. Update documentation
5. Submit pull request

### Reporting Issues

Include:
- Operating system and version
- nftban version
- Control panel (if any)
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Complete firewall management system for Linux servers</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Bug</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>
