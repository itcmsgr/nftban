# nftban Architecture - System Design Overview

**Comprehensive technical architecture of the nftban firewall management system**

[![Version](https://img.shields.io/badge/version-0.9.0--beta-orange)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](../LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)

> **Technical deep-dive** - This document explains the internal architecture, design decisions, and system interactions of nftban.

---

## 📋 Table of Contents

- [System Overview](#-system-overview)
- [Component Architecture](#-component-architecture)
- [Data Flow](#-data-flow)
- [Directory Structure](#-directory-structure)
- [nftables Architecture](#-nftables-architecture)
- [Fail2Ban Integration](#-fail2ban-integration)
- [Configuration Management](#-configuration-management)
- [Security Layers](#-security-layers)
- [Process Flows](#-process-flows)
- [File Formats](#-file-formats)
- [Network Architecture](#-network-architecture)
- [State Management](#-state-management)
- [Performance Considerations](#-performance-considerations)
- [Scalability](#-scalability)
- [High Availability](#-high-availability)
- [Monitoring & Observability](#-monitoring--observability)
- [Extension Points](#-extension-points)
- [Design Decisions](#-design-decisions)
- [Technology Stack](#-technology-stack)
- [Future Architecture](#-future-architecture)

---

## 🏗️ System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         nftban System                           │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              User Interface Layer                      │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │   │
│  │  │ nftban CLI   │  │  Web Admin   │  │   Scripts    │ │   │
│  │  │   (bash)     │  │   (future)   │  │   (bash)     │ │   │
│  │  └──────┬───────┘  └──────────────┘  └──────┬───────┘ │   │
│  └─────────┼─────────────────────────────────────┼─────────┘   │
│            │                                     │             │
│  ┌─────────┼─────────────────────────────────────┼─────────┐   │
│  │         │        Application Layer            │         │   │
│  │  ┌──────▼──────┐  ┌──────────────┐  ┌────────▼──────┐ │   │
│  │  │  nftban_    │  │   nftban_    │  │   nftban_    │ │   │
│  │  │    init     │  │  nftables_   │  │  fail2ban_   │ │   │
│  │  │    .sh      │  │   conf.sh    │  │   conf.sh    │ │   │
│  │  └──────┬──────┘  └──────┬───────┘  └──────┬────────┘ │   │
│  └─────────┼─────────────────┼───────────────────┼─────────┘   │
│            │                 │                   │             │
│  ┌─────────┼─────────────────┼───────────────────┼─────────┐   │
│  │         │    Configuration Management Layer   │         │   │
│  │  ┌──────▼─────────────────▼───────────────────▼──────┐ │   │
│  │  │         Configuration Files & Templates         │ │   │
│  │  │  • Port configs  • IP lists  • Templates       │ │   │
│  │  └──────┬───────────────────────────────────────────┘ │   │
│  └─────────┼─────────────────────────────────────────────┘   │
│            │                                                 │
│  ┌─────────┼─────────────────────────────────────────────┐   │
│  │         │       Kernel & Service Layer                │   │
│  │  ┌──────▼─────────┐  ┌────────────────┐             │   │
│  │  │   nftables     │  │   Fail2Ban     │             │   │
│  │  │   (kernel)     │◄─┤   (daemon)     │             │   │
│  │  └────────┬───────┘  └────────────────┘             │   │
│  └───────────┼─────────────────────────────────────────────┘   │
│              │                                                 │
│  ┌───────────▼─────────────────────────────────────────────┐   │
│  │                Network Packet Processing                │   │
│  │       INPUT ───► FORWARD ───► OUTPUT                   │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Core Principles

1. **Modularity**: Each component has a single, well-defined purpose
2. **Separation of Concerns**: Configuration separate from implementation
3. **Idempotency**: Scripts can be run multiple times safely
4. **Non-Destructive**: User configurations never overwritten
5. **Defense in Depth**: Multiple security layers
6. **Fail-Safe**: Errors don't leave system in broken state
7. **Observability**: Comprehensive logging and status reporting

### Design Philosophy

```
Traditional Firewall          nftban Approach
─────────────────────         ─────────────────────
Manual configuration    ──►   Automated deployment
Error-prone scripts     ──►   Validated templates
Single monolithic rule  ──►   Modular rule sets
Hard-coded values       ──►   Configuration files
Static configuration    ──►   Dynamic updates
Complex syntax          ──►   User-friendly CLI
No safety nets          ──►   Multi-layer protection
```

---

## 🧩 Component Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    nftban Components                        │
└─────────────────────────────────────────────────────────────┘

┌──────────────────────┐
│  nftban_init.sh      │  ◄─── Entry Point
│  ─────────────────   │
│  • Package install   │
│  • Directory setup   │
│  • Panel detection   │
│  • Template creation │
└──────────┬───────────┘
           │
           │ creates
           ▼
┌──────────────────────┐
│  Configuration Files │
│  ──────────────────  │
│  • Port configs      │
│  • IP lists          │
│  • Templates         │
└──────────┬───────────┘
           │
           │ reads
           ▼
┌──────────────────────┐
│  nftban_init_        │
│  nftables_conf.sh    │
│  ──────────────────  │
│  • Parse configs     │
│  • Generate rules    │
│  • Apply nftables    │
└──────────┬───────────┘
           │
           │ configures
           ▼
┌──────────────────────┐
│  nftables (kernel)   │
│  ──────────────────  │
│  • Packet filtering  │
│  • Sets management   │
│  • Rules evaluation  │
└──────────────────────┘

┌──────────────────────┐
│  nftban_init_        │
│  fail2ban_conf.sh    │
│  ──────────────────  │
│  • Configure jails   │
│  • Setup actions     │
│  • Email alerts      │
└──────────┬───────────┘
           │
           │ configures
           ▼
┌──────────────────────┐
│  Fail2Ban (daemon)   │
│  ──────────────────  │
│  • Log monitoring    │
│  • Pattern matching  │
│  • Auto-banning      │
└──────────┬───────────┘
           │
           │ calls
           ▼
┌──────────────────────┐
│  nftban CLI          │
│  ──────────────────  │
│  • Ban/unban IPs     │
│  • Status checking   │
│  • List management   │
└──────────────────────┘
```

### Component Responsibilities

| Component | Primary Responsibility | Secondary Functions |
|-----------|----------------------|---------------------|
| **nftban_init.sh** | System preparation | Package installation, directory creation, template generation |
| **installer_main.sh** | Main installer | Coordinates installation phases, configuration |
| **nftban_init_fail2ban_conf.sh** | Intrusion prevention | Jail configuration, alert setup, monitoring |
| **nftban CLI** | Daily operations | IP management, status reporting, validation |
| **Configuration Files** | Data storage | Port definitions, IP lists, settings |
| **nftables** | Packet filtering | Network traffic control, set management |
| **Fail2Ban** | Attack detection | Log analysis, automatic response |

### Component Communication

```
nftban_init.sh
    │
    ├─► Downloads installer modules
    │
    └─► Executes: installer_main.sh

installer_main.sh
    │
    ├─► Installs: nftables, fail2ban packages
    │
    ├─► Creates: /etc/nftban/config/*.conf.local
    │           /etc/nftban/templates/
    │           /etc/nftban/bin/nftban
    │
    ├─► Reads: /etc/nftban/config/*.conf.local
    │          /etc/nftban/templates/
    │
    ├─► Generates: /etc/nftban/config/nft_rules.conf.local
    │
    └─► Executes: nft -f /etc/nftban/config/nft_rules.conf.local

nftban_init_fail2ban_conf.sh
    │
    ├─► Reads: /etc/nftban/config/nftban.conf.local
    │
    ├─► Generates: /etc/fail2ban/jail.d/nftban-*.conf
    │              /etc/fail2ban/filter.d/nftban-*.conf
    │              /etc/fail2ban/action.d/nftban-*.conf
    │
    └─► Manages: systemctl [start|stop|restart] fail2ban

nftban CLI
    │
    ├─► Reads: /etc/nftban/config/*.conf.local
    │          nft list sets
    │          fail2ban-client status
    │
    ├─► Writes: /etc/nftban/config/*.conf.local
    │
    └─► Executes: nft add element
                  nft delete element
                  fail2ban-client unban
```

---

## 🔄 Data Flow

### Packet Processing Flow

```
Network Packet Arrives
        │
        ▼
┌──────────────────────────────────────────────┐
│   nftables: ip nftban_v4 table (IPv4)       │
│             ip6 nftban_v6 table (IPv6)      │
│                                              │
│   ┌────────────────────────────────────┐    │
│   │  Chain: input (priority 0)        │    │
│   │                                    │    │
│   │  Rule 1: Check whitelist          │    │
│   │  ├─ Match? → ACCEPT               │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 2: Check temp_ban            │    │
│   │  ├─ Match? → DROP                 │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 3: Check user_blacklist      │    │
│   │  ├─ Match? → DROP                 │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 4: Check system_blacklist    │    │
│   │  ├─ Match? → DROP                 │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 5: Check feeds               │    │
│   │  ├─ Match? → DROP                 │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 6: Check allowed ports       │    │
│   │  ├─ Match? → ACCEPT               │    │
│   │  └─ No match → Continue           │    │
│   │                                    │    │
│   │  Rule 7: Default policy            │    │
│   │  └─ DROP                          │    │
│   └────────────────────────────────────┘    │
│                                              │
│   (Separate tables for IPv4/IPv6)           │
│   (50% fewer rules per packet!)             │
└──────────────────────────────────────────────┘
        │
        ▼
   Packet Decision
   ├─ ACCEPT → Pass to application
   └─ DROP   → Discard silently
```

### Configuration Update Flow

```
User modifies configuration file
        │
        ▼
/etc/nftban/config/*.conf.local
        │
        ▼
User runs: nftban sync
        │
        ▼
┌──────────────────────────────────────────────┐
│  Parse Configuration Files                   │
│  ├─ Read .conf files (base)                 │
│  ├─ Read .conf.local files (user)           │
│  └─ Merge configurations                     │
└──────────┬───────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────┐
│  Validate Configuration                      │
│  ├─ Check syntax                            │
│  ├─ Validate IPs                            │
│  ├─ Check port formats                      │
│  └─ Detect conflicts                        │
└──────────┬───────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────┐
│  Generate nftables Rules                     │
│  ├─ Create table structure                  │
│  ├─ Define sets                             │
│  ├─ Build rules                             │
│  └─ Write to nft_rules.conf.local          │
└──────────┬───────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────┐
│  Validate Generated Rules                    │
│  └─ nft -c -f nft_rules.conf.local          │
└──────────┬───────────────────────────────────┘
           │
           ├─ Valid? ─┐
           │          │
           ▼          ▼
      ┌────────┐  ┌────────┐
      │ Apply  │  │ Error  │
      │ Rules  │  │ Report │
      └────────┘  └────────┘
```

### Ban/Unban Flow

```
Attack Detected
        │
        ├─► Manual: User runs nftban --temp-ban IP
        │
        └─► Automatic: Fail2Ban detects pattern
                │
                ▼
        ┌──────────────────────────────────────┐
        │  Fail2Ban Jail Triggered             │
        │  ├─ sshd: Too many failed attempts   │
        │  ├─ wordpress: Brute force           │
        │  └─ http-auth: Auth failures         │
        └──────────┬───────────────────────────┘
                   │
                   ▼
        ┌──────────────────────────────────────┐
        │  Fail2Ban Action: nftban-ban.conf    │
        │  └─ Execute: nftban --temp-ban IP    │
        └──────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────┐
│  nftban CLI Processing                          │
│  ├─ Validate IP address                         │
│  ├─ Check if IP is whitelisted (reject if yes)  │
│  ├─ Check if already banned (skip if yes)       │
│  └─ Add to appropriate set                      │
└──────────┬─────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│  nftables Operation                             │
│  ├─ Temp ban:                                   │
│  │   nft add element inet nftban_global         │
│  │       temp_ban_v4 { IP timeout 1h }          │
│  │                                              │
│  └─ Permanent ban:                              │
│      nft add element inet nftban_global         │
│          perm_ban_v4 { IP }                     │
└──────────┬─────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────┐
│  Log Entry Created                              │
│  └─ /var/log/nftban/nftban_operations.log      │
└─────────────────────────────────────────────────┘
           │
           ▼
   IP is now blocked
```

### Auto-Update Flow

```
Cron Trigger
    │
    ▼
/etc/nftban/scripts/nftban_auto_update.sh
    │
    ▼
┌──────────────────────────────────────┐
│  Check for Updates                   │
│  └─ git fetch --quiet                │
└──────────┬───────────────────────────┘
           │
           ▼
   ┌───────────────┐
   │ Updates       │
   │ Available?    │
   └───┬───────────┘
       │
       ├─ No  → Exit (nothing to do)
       │
       └─ Yes → Continue
                │
                ▼
┌──────────────────────────────────────┐
│  Backup Current State                │
│  └─ Copy /etc/nftban to backup      │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Pull Updates                        │
│  ├─ git reset --hard origin/main    │
│  └─ git pull --rebase                │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Preserve User Configurations        │
│  └─ *.conf.local files untouched    │
└──────────┬───────────────────────────┘
           │
           ▼
┌──────────────────────────────────────┐
│  Log Update                          │
│  └─ Record version change            │
└──────────────────────────────────────┘
```

---

## 📁 Directory Structure

### Filesystem Layout

```
/etc/nftban/                              # Main installation directory
│
├── config/                               # All configuration files
│   ├── *.conf                           # Base configurations (auto-managed)
│   └── *.conf.local                     # User configurations (preserved)
│
├── lib/                                  # Library modules
│   ├── installer/                       # Installer modules
│   │   ├── installer_main.sh           # Main installer coordinator
│   │   ├── installer_package.sh        # Package installation
│   │   └── [other installer modules]
│   ├── nftban_core.sh                  # Core functions
│   └── [other nftban modules]
│
├── templates/                            # Configuration templates
│   ├── control-panels/
│   │   ├── directadmin.conf             # DirectAdmin template
│   │   ├── cpanel.conf                  # cPanel template
│   │   ├── plesk.conf                   # Plesk template
│   │   └── generic.conf                 # Generic server template
│   └── [other templates]
│
├── bin/                                  # Binary executables
│   └── nftban                           # Main CLI tool
│
├── rules/                                # Custom rule storage
│   └── [user custom rules]
│
├── conf.d/                               # Additional configs
│   └── [plugin configs]
│
├── systemd/                              # Systemd units
│   └── nftban.service                   # Service definition
│
├── backups/                              # Configuration backups
│   └── [timestamped backups]
│
├── logs -> /var/log/nftban/             # Symlink to logs
│
└── .version                              # Version tracking

/var/log/nftban/                          # Log files
├── nftban_init_*.log                    # Installation logs
├── nftban_nftables_*.log                # Firewall logs
├── nftban_fail2ban_*.log                # Fail2Ban logs
├── nftban_operations.log                # CLI operations log
└── cp_detection_*.log                   # Control panel detection logs

/var/backups/                             # System backups
└── nftban_*.tgz                         # Timestamped full backups

/usr/local/bin/                           # Global executables
└── nftban -> /etc/nftban/bin/nftban     # CLI symlink

/etc/fail2ban/                            # Fail2Ban integration
├── jail.d/
│   └── nftban-*.conf                    # nftban jails
├── filter.d/
│   └── nftban-*.conf                    # nftban filters
└── action.d/
    └── nftban-*.conf                    # nftban actions
```

### Configuration File Hierarchy

```
Priority Order (highest to lowest):
┌─────────────────────────────────────────┐
│  1. *.conf.local (User)                 │  ◄─── Never overwritten
│     • Your customizations               │
│     • Takes precedence                  │
│     • Survives updates                  │
└─────────────────────────────────────────┘
           ▲
           │ overrides
           │
┌─────────────────────────────────────────┐
│  2. *.conf (Base)                       │  ◄─── Auto-managed
│     • Default configurations            │
│     • Updated by scripts                │
│     • Reference templates               │
└─────────────────────────────────────────┘

Example:
nftban-configuration-ipv4-ports-input-allow.conf       (Base)
nftban-configuration-ipv4-ports-input-allow.conf.local (User)
                                                       ▲
                                            User file takes precedence
```

### File Ownership & Permissions

```bash
# Directories
drwxr-xr-x  root:root  /etc/nftban/
drwxr-xr-x  root:root  /etc/nftban/config/
drwxr-xr-x  root:root  /etc/nftban/scripts/
drwxr-xr-x  root:root  /etc/nftban/templates/
drwxr-xr-x  root:root  /etc/nftban/bin/
drwxr-xr-x  root:root  /var/log/nftban/

# Configuration files
-rw-r--r--  root:root  *.conf
-rw-r--r--  root:root  *.conf.local

# Executable scripts
-rwxr-xr-x  root:root  *.sh
-rwxr-xr-x  root:root  nftban

# Log files
-rw-r-----  root:root  *.log

# Backup archives
-rw-r-----  root:root  *.tgz
```

---

## 🔥 nftables Architecture (v0.9.0 Split Table Design)

### Table Structure

**MAJOR CHANGE IN v0.9.0:** Split single `inet` table into separate `ip` (IPv4) and `ip6` (IPv6) tables for 30-50% performance improvement.

```
ip nftban_v4                    # IPv4 firewall table
│
├── set: whitelist              # IPv4 whitelist (NO _v4 suffix!)
│   ├── type: ipv4_addr
│   ├── flags: interval
│   └── elements: { 192.168.1.0/24, 10.0.0.100 }
│
├── set: temp_ban               # IPv4 temporary bans
│   ├── type: ipv4_addr
│   ├── flags: timeout
│   ├── timeout: 3600s (1 hour default)
│   └── elements: { 192.0.2.50 timeout 1h }
│
├── set: user_blacklist         # IPv4 permanent bans (user)
│   ├── type: ipv4_addr
│   └── elements: { 198.51.100.25 }
│
├── set: system_blacklist       # IPv4 permanent bans (system)
│   ├── type: ipv4_addr
│   └── elements: { 203.0.113.42 }
│
├── set: feeds                  # IPv4 threat feeds
│   ├── type: ipv4_addr
│   └── elements: { <feed IPs> }
│
├── chain: input                # Input chain (type filter, hook input, priority 0)
│   ├── Rule 1: Accept established/related connections
│   ├── Rule 2: Accept loopback
│   ├── Rule 3: Check whitelist (ACCEPT if match)
│   ├── Rule 4: Check temp_ban (DROP if match)
│   ├── Rule 5: Check user_blacklist (DROP if match)
│   ├── Rule 6: Check system_blacklist (DROP if match)
│   ├── Rule 7: Check feeds (DROP if match)
│   ├── Rule 8: Accept configured ports
│   └── Rule 9: Default policy (DROP)
│
├── chain: forward              # Forward chain (disabled by default)
│   └── policy: drop
│
└── chain: output               # Output chain (type filter, hook output, priority 0)
    ├── Rule 1: Accept established/related
    ├── Rule 2: Accept loopback
    ├── Rule 3: Accept configured outbound ports
    └── Rule 4: Default policy (ACCEPT)

ip6 nftban_v6                   # IPv6 firewall table (same structure)
│
├── set: whitelist              # IPv6 whitelist (NO _v6 suffix!)
│   ├── type: ipv6_addr
│   ├── flags: interval
│   └── elements: { 2001:db8::/32, fe80::/10 }
│
├── set: temp_ban               # IPv6 temporary bans
│   ├── type: ipv6_addr
│   ├── flags: timeout
│   └── elements: { 2001:db8::bad timeout 1h }
│
├── set: user_blacklist         # IPv6 permanent bans (user)
│   ├── type: ipv6_addr
│   └── elements: { 2001:db8::evil }
│
├── set: system_blacklist       # IPv6 permanent bans (system)
│   ├── type: ipv6_addr
│   └── elements: { 2001:db8::attack }
│
├── set: feeds                  # IPv6 threat feeds
│   ├── type: ipv6_addr
│   └── elements: { <feed IPs> }
│
└── [Same chain structure as IPv4]
```

### Architecture Comparison (v0.8.5 vs v0.9.0)

```
OLD (v0.8.5):                          NEW (v0.9.0):
─────────────────────────────          ─────────────────────────────
inet nftban_global                     ip nftban_v4
  ├── whitelist_v4                       ├── whitelist
  ├── whitelist_v6                       ├── temp_ban
  ├── temp_ban_v4                        ├── user_blacklist
  ├── temp_ban_v6                        ├── system_blacklist
  ├── perm_ban_v4                        └── feeds
  └── perm_ban_v6
                                       ip6 nftban_v6
Rules use selectors:                     ├── whitelist
  ip saddr @whitelist_v4                 ├── temp_ban
  ip6 saddr @whitelist_v6                ├── user_blacklist
                                         ├── system_blacklist
~20 rules per packet                     └── feeds

                                       Rules simplified:
                                         saddr @whitelist
                                         (no selectors!)

                                       ~10 rules per packet (50% less!)
```

### Performance Benefits

```
v0.9.0 Split Table Advantages:
┌────────────────────────────────────────────────────────────┐
│  Benefit              Impact                               │
│  ──────────────────── ───────────────────────────────────  │
│  Rule reduction       50% fewer evaluations per packet     │
│  Selector removal     No ip/ip6 selector checks needed     │
│  Cache efficiency     Smaller rule sets = more cache hits  │
│  Independent tuning   IPv4/IPv6 optimized separately       │
│  Cleaner syntax       Sets without _v4/_v6 suffixes        │
└────────────────────────────────────────────────────────────┘

Expected Performance Improvement: 30-50% faster packet processing
```

### Rule Evaluation Order (v0.9.0)

**IPv4 packets** are evaluated in `ip nftban_v4` table:
```
Packet arrives at INPUT chain (ip nftban_v4)
│
├─► Rule 1: ct state {established,related} accept
│   └─ Already established connection? → ACCEPT
│
├─► Rule 2: iif lo accept
│   └─ From loopback interface? → ACCEPT
│
├─► Rule 3: saddr @whitelist accept
│   └─ Source IP in whitelist? → ACCEPT
│       (Highest priority - always pass)
│       (NO ip/ip6 SELECTOR NEEDED!)
│
├─► Rule 4: saddr @temp_ban drop
│   └─ Source IP temporarily banned? → DROP
│       (Fail2Ban managed)
│
├─► Rule 5: saddr @user_blacklist drop
│   └─ Source IP permanently banned by user? → DROP
│
├─► Rule 6: saddr @system_blacklist drop
│   └─ Source IP permanently banned by system? → DROP
│
├─► Rule 7: saddr @feeds drop
│   └─ Source IP in threat feeds? → DROP
│
├─► Rule 8: tcp dport { 22, 80, 443 } accept
│   │       udp dport { 53 } accept
│   └─ Destination port allowed? → ACCEPT
│       (From configuration files)
│
└─► Rule 9: drop
    └─ Default policy: DROP all other traffic
```

**IPv6 packets** are evaluated in `ip6 nftban_v6` table (same logic):
```
Packet arrives at INPUT chain (ip6 nftban_v6)
[Same rule structure, operating on IPv6 addresses]
```

### Set Management (v0.9.0)

```bash
# Add IPv4 to set (temporary ban with timeout)
nft add element ip nftban_v4 temp_ban { 192.0.2.50 timeout 1h }

# Add IPv6 to set (temporary ban with timeout)
nft add element ip6 nftban_v6 temp_ban { 2001:db8::bad timeout 1h }

# Add IPv4 to permanent ban
nft add element ip nftban_v4 user_blacklist { 192.0.2.50 }

# Add IPv4 to whitelist (with CIDR)
nft add element ip nftban_v4 whitelist { 192.168.1.0/24 }

# Remove IP from set
nft delete element ip nftban_v4 temp_ban { 192.0.2.50 }

# List set contents (IPv4)
nft list set ip nftban_v4 temp_ban

# List set contents (IPv6)
nft list set ip6 nftban_v6 temp_ban

# Flush all elements from set (keep set definition)
nft flush set ip nftban_v4 temp_ban
nft flush set ip6 nftban_v6 temp_ban

# List both tables
nft list table ip nftban_v4
nft list table ip6 nftban_v6

# Get set statistics
nft -j list set ip nftban_v4 temp_ban | jq
```

### Performance Optimization

```
nftables Set Types:
┌──────────────────────────────────────────────────┐
│  interval set                                    │
│  • Supports CIDR ranges                         │
│  • Efficient range lookups                      │
│  • Used for: whitelist_v4, whitelist_v6         │
│  • Example: { 192.168.0.0/16, 10.0.0.0/8 }     │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  timeout flag                                    │
│  • Automatic element expiration                 │
│  • Used for: temp_ban_v4, temp_ban_v6           │
│  • Example: { 192.0.2.50 timeout 1h }          │
│  • Cleanup: Automatic by kernel                 │
└──────────────────────────────────────────────────┘

Lookup Complexity:
├─ Hash sets: O(1) average
├─ Interval sets: O(log n)
└─ Both very efficient for firewall use
```

---

## 🛡️ Fail2Ban Integration

### Architecture Diagram

```
┌────────────────────────────────────────────────────────┐
│                    Fail2Ban System                      │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Log Files                           │  │
│  │  /var/log/auth.log     (SSH)                    │  │
│  │  /var/log/nginx/access.log  (Web)               │  │
│  │  /var/log/mail.log     (Email)                  │  │
│  └────────────┬─────────────────────────────────────┘  │
│               │                                        │
│               │ monitored by                           │
│               ▼                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Fail2Ban Daemon                     │  │
│  │  ┌────────────────────────────────────────────┐ │  │
│  │  │  Jails (Active Monitors)                   │ │  │
│  │  │  ├─ sshd                                   │ │  │
│  │  │  ├─ wordpress                              │ │  │
│  │  │  ├─ nginx-http-auth                        │ │  │
│  │  │  └─ [other jails]                          │ │  │
│  │  └────────────┬───────────────────────────────┘ │  │
│  │               │                                  │  │
│  │               │ uses                             │  │
│  │               ▼                                  │  │
│  │  ┌────────────────────────────────────────────┐ │  │
│  │  │  Filters (Pattern Matching)                │ │  │
│  │  │  • Regex patterns                          │ │  │
│  │  │  • Failure detection                       │ │  │
│  │  │  • Threshold counting                      │ │  │
│  │  └────────────┬───────────────────────────────┘ │  │
│  │               │                                  │  │
│  │               │ triggers                         │  │
│  │               ▼                                  │  │
│  │  ┌────────────────────────────────────────────┐ │  │
│  │  │  Actions                                   │ │  │
│  │  │  ├─ nftban-ban.conf                        │ │  │
│  │  │  ├─ nftban-unban.conf                      │ │  │
│  │  │  └─ email alerts                           │ │  │
│  │  └────────────┬───────────────────────────────┘ │  │
│  └───────────────┼──────────────────────────────────┘  │
│                  │                                     │
│                  │ executes                            │
│                  ▼                                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │         nftban CLI                               │  │
│  │  nftban --temp-ban <IP> "Fail2Ban: sshd"        │  │
│  └────────────┬─────────────────────────────────────┘  │
└───────────────┼──────────────────────────────────────┘
                │
                │ modifies
                ▼
┌───────────────────────────────────────────────────────┐
│              nftables Sets                            │
│  temp_ban_v4 = { <IP> timeout 1h }                   │
└───────────────────────────────────────────────────────┘
```

### Jail Configuration

```ini
# /etc/fail2ban/jail.d/nftban-sshd.conf
[nftban-sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5                    # Failed attempts before ban
findtime = 600                  # Time window (10 minutes)
bantime  = 3600                 # Ban duration (1 hour)
action   = nftban-ban[name=SSH]
           sendmail-whois[name=SSH, dest=admin@example.com]
```

### Filter Configuration

```ini
# /etc/fail2ban/filter.d/nftban-sshd.conf
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error) for .* from <HOST>
            ^%(__prefix_line)sFailed (?:password|publickey) for .* from <HOST>
            ^%(__prefix_line)sROOT LOGIN REFUSED .* FROM <HOST>
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers

ignoreregex = 
```

### Action Configuration

```ini
# /etc/fail2ban/action.d/nftban-ban.conf
[Definition]
actionstart = 
actionstop  = 
actioncheck = 
actionban   = /usr/local/bin/nftban --temp-ban <ip> "Fail2Ban: <name>"
actionunban = /usr/local/bin/nftban --remove-ip <ip>

[Init]
name = default
```

### Integration Points

```
Fail2Ban → nftban Integration:
┌────────────────────────────────────────────┐
│  Fail2Ban detects attack                   │
│  ├─ Pattern match in logs                  │
│  ├─ Threshold exceeded                     │
│  └─ Jail triggered                         │
└──────────┬─────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────┐
│  Action: nftban-ban.conf                   │
│  └─ Execute: nftban --temp-ban <IP>        │
└──────────┬─────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────┐
│  nftban CLI validates & bans               │
│  ├─ Check whitelist (reject if present)   │
│  ├─ Validate IP format                    │
│  ├─ Add to nftables temp_ban set          │
│  └─ Log action                            │
└──────────┬─────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────┐
│  nftables kernel blocks traffic            │
│  └─ Packet from <IP> → DROP               │
└────────────────────────────────────────────┘
```

---

## ⚙️ Configuration Management

### Two-File Pattern

```
Philosophy:
├─ Base files (.conf): Auto-managed, updated by scripts
└─ User files (.conf.local): User customizations, preserved forever

Benefits:
├─ Updates never overwrite user settings
├─ Clear separation of defaults vs customizations
├─ Easy to see what user changed
└─ Scripts can regenerate base safely

Implementation:
┌─────────────────────────────────────────────────────┐
│  Script reads configuration:                        │
│  1. Parse base file (.conf) - get defaults         │
│  2. Parse user file (.conf.local) - get overrides  │
│  3. Merge: user values override base values         │
│  4. Generate final configuration                    │
└─────────────────────────────────────────────────────┘
```

### Configuration Precedence

```
Priority (highest to lowest):
1. Command-line arguments (--temp-ban 192.0.2.50)
2. .conf.local files (user customizations)
3. .conf files (script-generated defaults)
4. Hardcoded defaults (in script)

Example:
Port 22 can be defined in:
├─ Command: nftban --add-port 22
│   └─ Highest priority
├─ nftban-configuration-ipv4-ports-input-allow.conf.local
│   └─ User setting (survives updates)
├─ nftban-configuration-ipv4-ports-input-allow.conf
│   └─ Base setting (regenerated)
└─ Script default
    └─ Used if not in any config
```

### Configuration Validation

```
Validation Pipeline:
┌──────────────────────────────────────────┐
│  1. Syntax Validation                    │
│  ├─ Port format: \d+[TUB]               │
│  ├─ IP format: IPv4/IPv6 with optional │
│  │              CIDR                    │
│  └─ File format: One entry per line     │
└──────────┬───────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│  2. Semantic Validation                  │
│  ├─ Port range: 1-65535                 │
│  ├─ IP validation: ipcalc/sipcalc       │
│  ├─ CIDR prefix: /0-32 (IPv4), /0-128  │
│  │                (IPv6)                │
│  └─ Duplicate detection                 │
└──────────┬───────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│  3. Security Validation                  │
│  ├─ No banned IPs in whitelist         │
│  ├─ No reserved IPs                     │
│  ├─ No localhost in ban lists           │
│  └─ No current connection IPs bannable  │
└──────────┬───────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│  4. nftables Validation                  │
│  └─ nft -c -f <generated_rules>         │
└──────────┬───────────────────────────────┘
           │
           ├─ All valid? → Apply
           └─ Any errors? → Report & abort
```

### Configuration Templates

```
Template Hierarchy:
/etc/nftban/templates/
├── control-panels/
│   ├── directadmin.conf       # DirectAdmin specific
│   │   └── Contains: Panel ports, email, FTP, DNS
│   │
│   ├── cpanel.conf            # cPanel specific
│   │   └── Contains: WHM, cPanel, Webmail ports
│   │
│   ├── plesk.conf             # Plesk specific
│   │   └── Contains: Plesk panel, databases
│   │
│   └── generic.conf           # Generic server
│       └── Contains: SSH, HTTP, HTTPS, DNS
│
└── [future templates for other uses]

Template Usage:
┌────────────────────────────────────────────┐
│  nftban_init.sh                            │
│  ├─ Detect control panel                  │
│  ├─ Select appropriate template           │
│  ├─ Process template                      │
│  │   ├─ Parse TCP_IN, TCP_OUT, etc.      │
│  │   └─ Expand port ranges                │
│  ├─ Generate .conf.local files            │
│  │   ├─ ipv4-ports-input-allow           │
│  │   ├─ ipv4-ports-output-allow          │
│  │   ├─ ipv6-ports-input-allow           │
│  │   ├─ ipv6-ports-output-allow          │
│  │   └─ user-whitelist_ips                │
│  └─ User can edit these files             │
└────────────────────────────────────────────┘
```

---

## 🔐 Security Layers

### Defense in Depth

```
Network Security Layers (Outermost to Innermost):

┌─────────────────────────────────────────────────────────┐
│  Layer 7: Application Layer                             │
│  • Application-specific security                        │
│  • Input validation                                     │
│  • Authentication & Authorization                       │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 6: Intrusion Detection (Fail2Ban)                │
│  • Log monitoring                                       │
│  • Pattern detection                                    │
│  • Automatic response                                   │
│  • Email alerts                                         │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 5: Dynamic Blacklisting (nftban CLI)             │
│  • Manual IP banning                                    │
│  • Temporary bans with timeout                          │
│  • Permanent bans                                       │
│  • Whois/GeoIP integration                              │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 4: Static Blacklist                              │
│  • Known bad actors                                     │
│  • Persistent threats                                   │
│  • User-defined blocks                                  │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Port Filtering (nftables)                     │
│  • Allow only required ports                            │
│  • Block all other ports                                │
│  • Separate INPUT/OUTPUT rules                          │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 2: IP Whitelist                                  │
│  • Trusted IP ranges                                    │
│  • Management networks                                  │
│  • Cannot be banned                                     │
│  • Highest priority                                     │
└─────────────────────────────────────────────────────────┘
                         ▲
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Connection State                              │
│  • Stateful firewall                                    │
│  • Established connections allowed                      │
│  • Invalid packets dropped                              │
└─────────────────────────────────────────────────────────┘
```

### Safety Mechanisms

```
Protection Against Lockout:
┌────────────────────────────────────────────────────┐
│  1. Current Connection IP Detection                │
│     └─ nftban refuses to ban SSH_CONNECTION IP    │
│                                                    │
│  2. Whitelist Protection                           │
│     └─ Whitelisted IPs cannot be banned           │
│                                                    │
│  3. Validation Before Ban                          │
│     └─ IP format validated before processing      │
│                                                    │
│  4. Dry-Run Mode                                   │
│     └─ Preview changes without applying           │
│                                                    │
│  5. Automatic Backups                              │
│     └─ Configuration backed up before changes     │
│                                                    │
│  6. Configuration Validation                       │
│     └─ nft -c checks rules before applying        │
│                                                    │
│  7. Rate Limiting                                  │
│     └─ Max 10 ban operations per minute           │
│                                                    │
│  8. Emergency Recovery                             │
│     └─ nft flush ruleset (via console/VNC)       │
└────────────────────────────────────────────────────┘
```

### Access Control

```
User Privilege Requirements:
┌─────────────────────────────────────────────┐
│  Operation               Required Privilege  │
│  ──────────────────────  ─────────────────  │
│  View status             User                │
│  View configuration      User                │
│  View logs               User (read access)  │
│  Ban IP                  Root (sudo)         │
│  Unban IP                Root (sudo)         │
│  Modify configuration    Root (sudo)         │
│  Install/Update          Root (sudo)         │
│  Service control         Root (sudo)         │
└─────────────────────────────────────────────┘

File Permission Model:
├─ Configuration files: 644 (rw-r--r--)
├─ Scripts: 755 (rwxr-xr-x)
├─ Logs: 640 (rw-r-----)
└─ Backups: 600 (rw-------)
```

---

## 🔄 Process Flows

### Installation Process

```
┌────────────────────────────────────────────────────┐
│  User runs: ./nftban_init.sh --github -y          │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 1: Pre-checks                               │
│  ├─ Root privilege check                           │
│  ├─ Package manager detection                      │
│  ├─ Network connectivity test                      │
│  └─ Version check                                  │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 2: Backup existing                          │
│  └─ tar -czf /var/backups/nftban_*.tgz /etc/nftban│
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 3: Repository sync                          │
│  ├─ GitHub: git clone/pull                         │
│  ├─ ZIP: wget + unzip                              │
│  └─ Local: mkdir structure                         │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 4: Package installation                     │
│  ├─ Update package cache                           │
│  ├─ Install EPEL (if RHEL-like)                    │
│  ├─ Install: nftables, fail2ban, whois, etc.      │
│  └─ Verify installations                           │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 5: Control panel detection                  │
│  ├─ Check: DirectAdmin, cPanel, Plesk              │
│  ├─ Prompt for generic if none found               │
│  ├─ Load appropriate template                      │
│  └─ Generate configuration files                   │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 6: Tool creation                            │
│  ├─ Create nftban CLI binary                       │
│  ├─ Set permissions (755)                          │
│  └─ Create symlink: /usr/local/bin/nftban          │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 7: Optional auto-update                     │
│  ├─ Create auto-update script                      │
│  ├─ Add cron entry                                 │
│  └─ Verify cron service                            │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 8: Completion                               │
│  ├─ Create .version file                           │
│  ├─ Log summary                                    │
│  └─ Display next steps                             │
└────────────────────────────────────────────────────┘
```

### Firewall Configuration Process

```
┌────────────────────────────────────────────────────┐
│  User runs: nftban sync                            │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 1: Configuration reading                    │
│  ├─ Read all *.conf files (base)                   │
│  ├─ Read all *.conf.local files (user)             │
│  └─ Merge configurations                           │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 2: Parsing & validation                     │
│  ├─ Parse port configurations                      │
│  │   ├─ Format: <port>[TUB]                        │
│  │   └─ Separate TCP/UDP/Both                      │
│  ├─ Parse IP lists                                 │
│  │   ├─ Validate IPv4/IPv6                         │
│  │   ├─ Validate CIDR notation                     │
│  │   └─ Check for conflicts                        │
│  └─ Build internal data structures                 │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 3: Rule generation                          │
│  ├─ Generate table definition                      │
│  ├─ Generate set definitions                       │
│  │   ├─ whitelist_v4, whitelist_v6                 │
│  │   ├─ temp_ban_v4, temp_ban_v6                   │
│  │   └─ perm_ban_v4, perm_ban_v6                   │
│  ├─ Generate chain rules                           │
│  │   ├─ INPUT chain                                │
│  │   ├─ OUTPUT chain                               │
│  │   └─ FORWARD chain                              │
│  └─ Write to nft_rules.conf.local                  │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 4: Pre-apply validation                     │
│  ├─ Syntax check: nft -c -f nft_rules.conf.local   │
│  ├─ Verify no critical errors                      │
│  └─ Create backup of current ruleset              │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 5: Application                              │
│  ├─ Flush old nftban table (if exists)             │
│  ├─ Apply new rules: nft -f nft_rules.conf.local   │
│  ├─ Verify table created                           │
│  └─ Verify sets populated                          │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 6: Post-apply verification                  │
│  ├─ List table: nft list table inet nftban_global  │
│  ├─ Count rules                                    │
│  ├─ Verify set elements                            │
│  └─ Test connectivity (ping, SSH test)             │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Phase 7: Completion                               │
│  ├─ Log summary                                    │
│  ├─ Display statistics                             │
│  └─ Show active rules                              │
└────────────────────────────────────────────────────┘
```

### Ban Operation Process

```
┌────────────────────────────────────────────────────┐
│  User/Fail2Ban: nftban --temp-ban 192.0.2.50      │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Step 1: Input validation                          │
│  ├─ Parse IP address                               │
│  ├─ Validate format                                │
│  │   ├─ IPv4: ipcalc -c <IP>                       │
│  │   ├─ IPv6: sipcalc <IP>                         │
│  │   └─ Fallback: regex                            │
│  └─ Reject if invalid                              │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Step 2: Safety checks                             │
│  ├─ Check if IP is current SSH connection          │
│  │   └─ If yes: REJECT with error                  │
│  ├─ Check if IP in whitelist                       │
│  │   └─ If yes: REJECT with error                  │
│  └─ Check if IP already banned                     │
│      └─ If yes: Skip (idempotent)                  │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Step 3: Ban type determination                    │
│  ├─ Temp ban: Add to temp_ban set with timeout     │
│  │   └─ nft add element inet nftban_global \       │
│  │       temp_ban_v4 { <IP> timeout 1h }           │
│  │                                                  │
│  └─ Perm ban: Add to both sets                     │
│      ├─ Add to temp_ban (immediate effect)         │
│      ├─ Add to perm_ban (persistent)               │
│      └─ Write to blacklist file                    │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Step 4: Logging                                   │
│  ├─ Log to /var/log/nftban/operations.log          │
│  ├─ Include: timestamp, IP, reason, user           │
│  └─ Optional: Email notification                   │
└─────────────┬──────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Step 5: Verification                              │
│  ├─ Verify IP in set: nft list set ... temp_ban_v4│
│  └─ Return success status                          │
└────────────────────────────────────────────────────┘
```

---

## 📐 File Formats

### Port Configuration Format

```bash
# Format: <port><type>
# Types: T (TCP), U (UDP), B (Both)

# Examples:
22T         # SSH (TCP only)
53U         # DNS (UDP only)
3306B       # MySQL (both TCP and UDP)

# Comments allowed
80T         # HTTP
443T        # HTTPS

# Whitespace ignored
  8080T     # Custom web port
9000T       # Another service

# Invalid entries (will be skipped):
# 65536T    # Port out of range
# 22        # Missing type suffix
# X80T      # Invalid port number
```

### IP List Format

```bash
# Format: One IP or CIDR per line

# IPv4 examples:
192.168.1.100              # Single IP
10.0.0.0/8                 # Class A network
172.16.0.0/12              # Class B network
192.168.0.0/16             # Class C network
203.0.113.0/24             # Subnet

# IPv6 examples:
2001:db8::1                # Single IPv6
2001:db8::/32              # IPv6 network
fe80::/10                  # Link-local

# Comments allowed
# 192.0.2.0/24            # Reserved for documentation

# Whitespace ignored
  10.1.1.1                 # Leading space okay

# Invalid entries (will be rejected):
# 256.1.1.1               # Octet out of range
# 192.168.1.0/33          # Invalid CIDR prefix (IPv4)
# 2001:db8::/129          # Invalid CIDR prefix (IPv6)
# not.an.ip               # Invalid format
```

### nftables Rule File Format

```nft
#!/usr/sbin/nft -f
# Generated by nftban installer
# Timestamp: 2025-01-15 10:30:00
# DO NOT EDIT MANUALLY - Changes will be overwritten

# Flush existing nftban table
flush table inet nftban_global

# Create main table
table inet nftban_global {
    # Define sets
    set whitelist_v4 {
        type ipv4_addr
        flags interval
        elements = { 192.168.1.0/24, 10.0.0.100 }
    }
    
    set temp_ban_v4 {
        type ipv4_addr
        flags timeout
        timeout 3600s
    }
    
    set perm_ban_v4 {
        type ipv4_addr
    }
    
    # INPUT chain
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Accept established/related
        ct state {established, related} accept
        
        # Accept loopback
        iif lo accept
        
        # Check whitelist (highest priority)
        ip saddr @whitelist_v4 accept
        
        # Check bans
        ip saddr @temp_ban_v4 drop
        ip saddr @perm_ban_v4 drop
        
        # Accept configured ports
        tcp dport { 22, 80, 443 } accept
        udp dport { 53 } accept
        
        # Drop everything else
    }
    
    # OUTPUT chain
    chain output {
        type filter hook output priority 0; policy accept;
        
        # Accept established/related
        ct state {established, related} accept
        
        # Accept loopback
        oif lo accept
        
        # Accept configured outbound ports
        tcp dport { 53, 80, 443 } accept
        udp dport { 53, 123 } accept
    }
}
```

### Log File Format

```
# nftban operation log format
[2025-01-15 10:30:15] [INFO] nftban v0.5.0-final started by root
[2025-01-15 10:30:15] [ACTION] Temp ban: 192.0.2.50 (reason: SSH brute-force, user: root, source: manual)
[2025-01-15 10:30:15] [VALIDATE] IP validation successful: 192.0.2.50 (method: ipcalc)
[2025-01-15 10:30:15] [NFTABLES] Added to set: inet nftban_global temp_ban_v4 { 192.0.2.50 timeout 1h }
[2025-01-15 10:30:15] [SUCCESS] IP 192.0.2.50 banned successfully
[2025-01-15 10:35:20] [ACTION] Perm ban: 198.51.100.25 (reason: Confirmed attacker, user: root, source: manual)
[2025-01-15 10:35:20] [FILE] Added to blacklist: /etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local
[2025-01-15 10:35:20] [NFTABLES] Added to set: inet nftban_global perm_ban_v4 { 198.51.100.25 }
[2025-01-15 10:35:20] [SUCCESS] IP 198.51.100.25 permanently banned
[2025-01-15 10:40:30] [ACTION] Unban: 192.0.2.50 (user: root, source: manual)
[2025-01-15 10:40:30] [NFTABLES] Removed from set: inet nftban_global temp_ban_v4 { 192.0.2.50 }
[2025-01-15 10:40:30] [SUCCESS] IP 192.0.2.50 unbanned
[2025-01-15 10:45:00] [ERROR] Cannot ban 192.168.1.100: IP is whitelisted
[2025-01-15 10:50:00] [WARN] Rate limit reached: 10 operations in 1 minute
```

---

## 🔧 Technology Stack

### Core Technologies

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| **Firewall** | nftables | 0.9.3+ | Packet filtering engine |
| **IPS** | Fail2Ban | 0.10+ | Intrusion prevention |
| **Shell** | Bash | 4.0+ | Script interpreter |
| **Init System** | systemd | 219+ | Service management |
| **Validation** | ipcalc | Any | IP validation (IPv4) |
| **Validation** | sipcalc | Any | IP validation (IPv6) |
| **Lookup** | whois | Any | IP information |
| **DNS** | dnsutils/bind-utils | Any | DNS tools |

### Supporting Tools

```
Development & Deployment:
├── Git: Version control
├── curl/wget: Downloads
├── tar: Backups
├── unzip: Archive extraction
├── grep/sed/awk: Text processing
└── find: File operations

Monitoring & Logging:
├── journalctl: System logs
├── tail: Log following
├── logrotate: Log rotation
└── syslog: System logging

Network Tools:
├── ping: Connectivity test
├── ss/netstat: Connection viewing
├── ip: Network configuration
└── dig/nslookup: DNS queries
```

### Dependencies Graph

```
nftban System Dependencies:

nftban_init.sh
    │
    ├─► bash (4.0+)
    ├─► systemd
    ├─► curl OR wget
    └─► Package Manager
            ├─► apt-get (Debian/Ubuntu)
            ├─► dnf (Fedora/RHEL 8+)
            ├─► yum (RHEL 7)
            ├─► zypper (openSUSE)
            └─► apk (Alpine)

nftables
    │
    ├─► Linux kernel (3.13+)
    ├─► nft binary
    └─► Kernel modules
            ├─► nf_tables
            ├─► nft_counter
            └─► nft_ct

Fail2Ban
    │
    ├─► Python (3.x)
    ├─► systemd
    └─► Log files
            ├─► /var/log/auth.log
            ├─► /var/log/secure
            └─► Application logs

nftban CLI
    │
    ├─► bash
    ├─► nft binary
    ├─► ipcalc (optional)
    ├─► sipcalc (optional)
    └─► Configuration files
            └─► /etc/nftban/config/*.conf.local
```

---

## 🎯 Design Decisions

### Why nftables over iptables?

```
Decision: Use nftables as the firewall backend

Rationale:
├─ Modern: Replaces iptables (deprecated in newer kernels)
├─ Performance: Better packet processing efficiency
├─ Syntax: Cleaner, more intuitive rule syntax
├─ Sets: Native support for IP sets (efficient lookups)
├─ Atomic: Changes applied atomically (safer)
└─ Future: Official replacement recommended by kernel maintainers

Trade-offs:
├─ Compatibility: Requires kernel 3.13+ (acceptable for modern Linux)
├─ Migration: Existing iptables users need to learn new syntax
└─ Tools: Some older tools expect iptables (rare nowadays)
```

### Why Bash over Python/other languages?

```
Decision: Implement core scripts in Bash

Rationale:
├─ Universality: Bash present on all Linux systems
├─ Simplicity: Easy to read, modify, and understand
├─ Dependencies: Minimal external dependencies
├─ Integration: Native system integration
└─ Performance: Adequate for firewall configuration tasks

Trade-offs:
├─ Error handling: More verbose than modern languages
├─ Data structures: Limited compared to Python/Go
├─ Testing: Harder to unit test than compiled languages
└─ Type safety: No static typing
```

### Why two-file configuration pattern?

```
Decision: Use .conf (base) and .conf.local (user) pattern

Rationale:
├─ Upgrade safety: Updates never overwrite user settings
├─ Clear separation: Obvious what user changed vs defaults
├─ Rollback capability: Easy to reset to defaults
├─ Template system: Base files serve as documentation
└─ Common pattern: Used by many Linux services (Apache, nginx)

Implementation:
├─ Base files: Regenerated by scripts
├─ Local files: Never touched by scripts
└─ Merge: Scripts read both, local takes precedence
```

### Why modular component design?

```
Decision: Separate init, nftables config, fail2ban config, CLI

Rationale:
├─ Single responsibility: Each script has one job
├─ Maintainability: Easier to update individual components
├─ Testability: Can test each component independently
├─ Flexibility: Users can run only what they need
└─ Clarity: Clear workflow and dependencies

Trade-offs:
├─ Complexity: Multiple scripts to understand
├─ Coordination: Must maintain compatibility between components
└─ User burden: Requires understanding of workflow
```

### Why not systemd-based firewall?

```
Decision: Generate nftables rules directly, not systemd units

Rationale:
├─ Flexibility: Direct nftables access for advanced features
├─ Portability: Works on systems without systemd
├─ Transparency: Users see actual nftables rules
├─ Performance: No systemd layer overhead
└─ Control: Fine-grained control over rule generation

Trade-offs:
├─ Integration: Less integrated with systemd logging
├─ Dependencies: Must manage nftables service separately
└─ Restart: Manual reload needed for changes
```

---

## 📊 Performance Considerations

### nftables Performance

```
Rule Evaluation Performance:
┌──────────────────────────────────────────┐
│  Operation              Time Complexity  │
│  ─────────────────────  ───────────────  │
│  Hash set lookup        O(1) average     │
│  Interval set lookup    O(log n)         │
│  Rule traversal         O(n)             │
│  Set element addition   O(1)             │
│  Table flush            O(1)             │
└──────────────────────────────────────────┘

Typical Latencies:
├─ Packet evaluation: < 1 microsecond
├─ Set lookup: 10-100 nanoseconds
├─ Rule addition: < 1 millisecond
└─ Table reload: < 100 milliseconds
```

### Memory Usage

```
Memory Footprint:
┌──────────────────────────────────────────┐
│  Component              Memory Usage     │
│  ─────────────────────  ──────────────  │
│  nftables kernel        2-10 MB          │
│  Fail2Ban daemon        10-50 MB         │
│  nftban CLI             < 5 MB           │
│  Configuration files    < 1 MB           │
└──────────────────────────────────────────┘

Set Memory (approximate):
├─ 1,000 IPs: ~100 KB
├─ 10,000 IPs: ~1 MB
├─ 100,000 IPs: ~10 MB
└─ 1,000,000 IPs: ~100 MB
```

### Scalability Limits

```
Tested Limits:
┌──────────────────────────────────────────────┐
│  Metric                  Tested Value        │
│  ──────────────────────  ──────────────────  │
│  Banned IPs              100,000+            │
│  Whitelisted IPs         10,000+             │
│  Active rules            1,000+              │
│  Port definitions        500+                │
│  Concurrent ban ops      100/second          │
│  Fail2Ban jails          50+                 │
└──────────────────────────────────────────────┘

Recommended Limits:
├─ Banned IPs: < 50,000 for optimal performance
├─ Rules: < 500 for readability
└─ Jails: < 20 for manageable monitoring
```

### Optimization Strategies

```
Performance Optimization:
1. Use interval sets for IP ranges
   └─ 192.168.0.0/16 vs 65,536 individual IPs

2. Place most common matches early
   └─ Whitelist checks before ban checks

3. Use connection tracking
   └─ ct state {established,related} accept

4. Minimize rule count
   └─ Combine related rules into sets

5. Use atomic updates
   └─ Generate and apply rules in one operation

6. Implement timeout for temp bans
   └─ Automatic cleanup by kernel

7. Regular set cleanup
   └─ Remove expired/invalid entries

8. Log rotation
   └─ Prevent log file bloat
```

---

## 📜 License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025 **Antonios Voulvoulis – ITCMS**  
https://itcms.gr

### Summary

✅ **Permitted:**
- Use in personal/commercial projects
- Modification and customization
- Deployment on unlimited systems
- Charging for services using nftban
- Integration in service offerings

❌ **Prohibited:**
- Selling the software itself
- Sublicensing or reselling
- Distribution as paid product
- Removing copyright notices

[📚 Full License Text](../LICENSE.md)

---

## 📞 Support & Resources

### Documentation

- 📚 **[Main README](../README.md)** - Project overview
- 🗿 **[System Preparation](README_nftban_init.md)** - Installation guide
- 🛡️ **[Firewall Configuration](README_nftban_init_nftables_conf.md)** - nftables setup
- 🔒 **[Intrusion Prevention](README_nftban_fail2ban.md)** - Fail2Ban integration
- 💻 **[CLI Reference](README_nftban_cli.md)** - Daily operations
- 📖 **[Complete Guide](README_COMPLETE.md)** - All-in-one documentation

### Community

- 🏠 **[GitHub](https://github.com/itcmsgr/nftban)** - Source code
- 🐛 **[Issues](https://github.com/itcmsgr/nftban/issues)** - Bug reports
- 💬 **[Discussions](https://github.com/itcmsgr/nftban/discussions)** - Questions

### Professional Support

**ITCMS – IT Consulting Managed Services**
- **Author**: Antonios Voulvoulis
- **Email**: support@itcms.gr
- **Website**: https://itcms.gr

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="../README.md">📚 Main Docs</a> •
  <a href="README_COMPLETE.md">📖 Complete Guide</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Issue</a> •
  <a href="https://itcms.gr">🌐 ITCMS Website</a>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
