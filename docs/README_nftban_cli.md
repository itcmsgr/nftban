# nftban CLI

**Command-line interface for nftables & Fail2Ban management with comprehensive IP control**

[![Version](https://img.shields.io/badge/version-3.6.0-blue)](https://github.com/itcmsgr/nftban)
[![Architecture](https://img.shields.io/badge/v0.9.0-dual--table-orange)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

The ultimate command-line tool for managing your nftban firewall setup. Ban/unban IPs, manage whitelists, check service status, validate configurations, and sync rules - all from one powerful CLI.

> **📌 v0.9.0 ARCHITECTURE UPDATE**
>
> This document contains examples using the OLD v0.8.5 architecture for reference.
>
> **Key Changes in v0.9.0:**
> - Tables: `ip nftban_v4` + `ip6 nftban_v6` (NOT `inet nftban_global`)
> - Sets: `whitelist`, `temp_ban` (NO `_v4/_v6` suffix)
> - nftban CLI commands work identically in both versions
> - Manual `nft` commands need syntax updates
>
> See [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md) for command translation guide.

---

## 🎯 What's New in v3.6.0

### 🔍 Enhanced Validation & Sync

- **Sync Status Checking**: Validates configuration files against active nftables sets
- **Comprehensive IP Verification**: Shows exactly where an IP exists (files + active sets + fail2ban)
- **Both Whitelist Sources**: Checks user AND system whitelist files
- **Improved Remove Operations**: Handles both temporary and permanent sets

### 🛡️ Better IP Management

- **Active Set Checking**: Verifies IPs in live nftables rules
- **Multi-source Validation**: Checks files, active sets, and fail2ban simultaneously
- **Smart Whitelisting**: Prevents banning of IPs in either whitelist source
- **One-command Sync**: Reload nftables configuration with `--sync`

### 📊 Enhanced Reporting

- **Show All Sets**: Display contents of all nftables sets at once
- **Detailed Status**: Comprehensive system status with set counts
- **Sync Reports**: Visual indicators showing which files need sync

---

## 🚀 Quick Start

### Installation Location

The nftban CLI is installed at:
```bash
/etc/nftban/bin/nftban
```

With a symlink at:
```bash
/usr/local/bin/nftban
```

### Basic Usage

```bash
# Show help
nftban --help

# Check system status
nftban status

# Add your current IP to whitelist
nftban --add-ip

# Temporarily ban an IP (1 hour)
nftban --temp-ban 192.0.2.100

# Permanently ban an IP
nftban --perm-ban 192.0.2.100 "Brute force attack"

# Remove an IP from all lists
nftban --remove-ip 192.0.2.100

# Check where an IP exists
nftban --verify-ip 192.0.2.100

# Validate sync between files and active rules
nftban --validate-sync

# Reload configuration (sync files → active sets)
nftban --sync
```

---

## 📋 Prerequisites

Before using the nftban CLI, ensure:

1. ✅ **System initialized** - `nftban_init.sh` has been run
2. ✅ **NFTables configured** - `nftban_init_nftables_conf.sh --install-final` completed
3. ✅ **Global table exists** - Table `inet nftban_global` with all required sets
4. ✅ **Root access** - Most commands require root privileges

### Verify Prerequisites

```bash
# Check if global table exists
sudo nft list table inet nftban_global

# Check nftban status
sudo nftban status

# Verify sets exist
sudo nftban --show-sets
```

---

## 🎛️ Command Reference

### Core Service Management

```bash
# Enable and start both services
nftban --enable

# Disable and stop both services
nftban --disable

# Start services
nftban --start

# Restart services
nftban --restart

# Stop services
nftban --stop
```

### Configuration & Validation

```bash
# Check configuration syntax
nftban --check

# List current nftables rules
nftban --list

# Show configuration directory
nftban config

# Reload nftables configuration
nftban reload

# Initialize nftables (run setup script)
nftban init
```

### IP Whitelist Management

```bash
# Add current login IP to whitelist
nftban --add-ip

# Add specific IP to whitelist
nftban --add-ip 203.0.113.50

# Show current IP info
nftban --info

# Check IP status across all sources
nftban --verify-ip 203.0.113.50
```

### Temporary Ban Operations

```bash
# Temporarily ban IP (1 hour default)
nftban --temp-ban 192.0.2.100

# Temp ban with comment
nftban --temp-ban 192.0.2.100 "SSH brute-force attempt"

# List all temporary bans
nftban --list-temp

# Remove temporary ban
nftban --remove-ban 192.0.2.100
```

### Permanent Ban Operations

```bash
# Permanently ban IP (writes to blacklist files)
nftban --perm-ban 192.0.2.100

# Permanent ban with comment
nftban --perm-ban 192.0.2.100 "Confirmed malicious actor"

# View all banned IPs (temp + permanent + fail2ban)
nftban --view-banned

# Remove IP from all lists (temp, perm, whitelist, fail2ban)
nftban --remove-ip 192.0.2.100
```

### Fail2Ban Integration

```bash
# List available fail2ban jails
nftban --fail2ban-jails

# View rules for specific jail
nftban --fail2ban-rules sshd

# View banned IPs in all jails
nftban --fail2ban-banned

# View banned IPs in specific jail
nftban --fail2ban-banned sshd

# Check fail2ban configuration
nftban --fail2ban-check
```

### New Validation & Sync Commands (v3.6.0)

```bash
# Validate sync between files and active nftables sets
nftban --validate-sync

# Show contents of all nftables sets
nftban --show-sets

# Comprehensive IP location check (files + active sets + fail2ban)
nftban --verify-ip 192.0.2.100

# Reload nftables from configuration files (sync)
nftban --sync
```

### Information & Status

```bash
# Show version
nftban version

# Show system status
nftban status

# Show current IP and whitelist status
nftban --info

# Display help
nftban --help
```

### Advanced Options

```bash
# Flush all nftables rules (DANGEROUS!)
nftban flush

# Enable file logging
nftban --enable-logging

# Disable file logging
nftban --disable-logging
```

---

## 💡 Usage Examples

### Example 1: Protecting Your Own IP

```bash
# Get your current IP and add to whitelist
sudo nftban --add-ip

# Output:
# Your current login IP is: 203.0.113.10
# Added your IP (203.0.113.10) to the allow file
# ✓ Added 203.0.113.10 to whitelist_v4 set
```

### Example 2: Handling Brute Force Attack

```bash
# Temporarily ban attacker (takes effect immediately)
sudo nftban --temp-ban 192.0.2.50 "SSH brute-force from Russia"

# Output:
# [OK] Temporarily banned IPv4 address: 192.0.2.50 (1 hour)
# Comment: SSH brute-force from Russia

# Check if ban was applied
sudo nftban --list-temp

# If attack continues, make it permanent
sudo nftban --perm-ban 192.0.2.50 "Persistent attacker"
```

### Example 3: Managing Whitelists

```bash
# Add office IPs to whitelist
sudo nftban --add-ip 203.0.113.100
sudo nftban --add-ip 203.0.113.101
sudo nftban --add-ip 203.0.113.102

# Verify IPs are whitelisted
sudo nftban --verify-ip 203.0.113.100

# Output shows:
# === IP Location Report: 203.0.113.100 ===
# 
# Whitelist Files:
#   ✓ Found in user whitelist
#   ✗ Not in system whitelist
# 
# Active nftables Sets:
#   ✓ Found in whitelist_v4
```

### Example 4: Checking Sync Status

```bash
# Check if configuration files match active sets
sudo nftban --validate-sync

# Output shows:
# === Sync Status: Files vs Active nftables Sets ===
# 
# Whitelist Synchronization:
#   IPv4 Whitelist: 5 in files, 5 in whitelist_v4
#     ✓ IPv4 whitelist in sync
#   IPv6 Whitelist: 2 in files, 2 in whitelist_v6
#     ✓ IPv6 whitelist in sync
# 
# Blacklist Synchronization:
#   IPv4 User Blacklist: 10 in files, 8 in user_blacklist_v4
#     ⚠  2 IPs in files but not in active set
# 
# ⚠  Found 1 sync issue(s)
# Run 'nftban --sync' to reload nftables configuration

# Apply the changes
sudo nftban --sync
```

### Example 5: Comprehensive IP Check

```bash
# Check where a specific IP exists
sudo nftban --verify-ip 192.0.2.75

# Output shows complete picture:
# === IP Location Report: 192.0.2.75 ===
# 
# Whitelist Files:
#   ✗ Not in user whitelist
#   ✗ Not in system whitelist
# 
# Blacklist Files:
#   ✓ Found in user blacklist
#   ✗ Not in IPv4 blacklist
# 
# Active nftables Sets:
#   ✗ Not in whitelist_v4
#   ✓ Found in user_blacklist_v4
#   ✗ Not in system_blacklist_v4
#   ✓ Found in temp_ban_v4 (temporary)
# 
# Fail2Ban Status:
#   ✓ Banned in fail2ban jail: sshd
# 
# IP found in at least one location
```

### Example 6: Viewing All Banned IPs

```bash
# See complete ban overview
sudo nftban --view-banned

# Output shows:
# === All Banned IPs (Combined View) ===
# 
# 1. nftables temporary bans (IPv4):
#   192.0.2.50
#   192.0.2.75
#   198.51.100.25
# 
# 2. nftables temporary bans (IPv6):
#   2001:db8::dead:beef
# 
# 3. Permanent blacklist (IPv4):
#   192.0.2.50 # Confirmed attacker
#   203.0.113.99 # Spam source
# 
# 4. Permanent blacklist (IPv6):
#   (empty)
# 
# 5. User blacklist:
#   192.0.2.75 # Manual ban
# 
# 6. Fail2Ban bans:
#   Jail: sshd
#     192.0.2.50
#     192.0.2.75
```

### Example 7: Removing an IP Completely

```bash
# Remove from everywhere at once
sudo nftban --remove-ip 192.0.2.50

# Output shows:
# Removing IP 192.0.2.50 from all ban lists...
# Removed temporary ban for IPv4 address: 192.0.2.50
# Removed IP 192.0.2.50 from blacklist file
# Unbanned IP 192.0.2.50 from Fail2Ban jail: sshd
# Removed IP 192.0.2.50 from all ban lists and whitelist
# Note: Permanent sets in nftables need reload. Run: nftban --sync

# Apply changes to permanent sets
sudo nftban --sync
```

### Example 8: Service Management

```bash
# Check current status
sudo nftban status

# Output:
# === nftban Status ===
# nftban path: /etc/nftban
# nftables: v1.0.6 (...)
# fail2ban: Fail2Ban v1.0.2
# systemd unit: present
# nftables service: active
# Fail2Ban service: active
# Global table: exists
#   Temp bans: 3 IPv4, 1 IPv6

# Restart services
sudo nftban --restart

# Stop services
sudo nftban --stop

# Start services again
sudo nftban --start
```

### Example 9: Fail2Ban Integration

```bash
# List available jails
sudo nftban --fail2ban-jails

# Output:
# Available Fail2Ban jails:
# sshd
# nginx-http-auth
# wordpress
# directadmin

# View banned IPs in specific jail
sudo nftban --fail2ban-banned sshd

# Output:
# Banned IPs in Fail2Ban jail 'sshd':
# 192.0.2.50 192.0.2.75 198.51.100.25
```

### Example 10: Show All nftables Sets

```bash
# Display contents of all sets
sudo nftban --show-sets

# Output shows:
# === All nftables Sets in nftban_global ===
# 
# Whitelist IPv4 (whitelist_v4):
#   5 element(s)
#     203.0.113.10
#     203.0.113.100
#     203.0.113.101
#     203.0.113.102
#     203.0.113.200
# 
# Whitelist IPv6 (whitelist_v6):
#   2 element(s)
#     2001:db8::1
#     2001:db8::2
# 
# User Blacklist IPv4 (user_blacklist_v4):
#   10 element(s)
#     192.0.2.75
#     [... more IPs ...]
# 
# Temp Ban IPv4 (temp_ban_v4):
#   3 element(s)
#     192.0.2.50
#     192.0.2.75
#     198.51.100.25
```

---

## 🗂️ File Locations

### Configuration Files

```
/etc/nftban/config/
├── nftban-configuration-user-whitelist_ips.conf.local    # User whitelist
├── nftban-configuration-system_whitelist_ips.conf.local  # System whitelist (auto)
├── nftban-configuration-user-blacklist_ips.conf.local    # User blacklist
├── nftban-configuration-ipv4-blacklist_ips.conf.local    # IPv4 system blacklist
└── nftban-configuration-ipv6-blacklist_ips.conf.local    # IPv6 system blacklist
```

### NFTables Configuration

```
/etc/nftables.conf                                         # Main nftables config
/etc/nftables/backups/                                     # Configuration backups
```

### Logs

```
/var/log/nftban/nftban.log                                 # nftban CLI log
```

---

## 🔍 How It Works

### Temporary Ban Flow

```
nftban --temp-ban 192.0.2.50
         ↓
Validates IP (not whitelisted, not current IP)
         ↓
Adds to nftables set: inet nftban_global temp_ban_v4
         ↓
Ban active immediately (1 hour timeout)
         ↓
After 1 hour: nftables automatically removes from set
```

### Permanent Ban Flow

```
nftban --perm-ban 192.0.2.50 "Reason"
         ↓
Validates IP (not whitelisted, not current IP)
         ↓
Appends to blacklist file with comment
         ↓
Also adds to temp_ban set (immediate effect)
         ↓
Run nftban --sync to load into permanent set
         ↓
Ban remains until manual removal
```

### Whitelist Priority

```
Whitelist (highest priority)
    ↓ IP checked against
User Whitelist File
    ↓ and/or
System Whitelist File
    ↓ and/or
Active whitelist_v4/v6 sets
    ↓
If found in ANY: IP cannot be banned
If not found: IP can be banned
```

---

## 🛡️ NFTables Set Structure

### All Sets in `inet nftban_global`

| Set Name | Type | Purpose | Populated By |
|----------|------|---------|--------------|
| **whitelist_v4** | IPv4 | IPs that can never be banned | User/System whitelist files |
| **whitelist_v6** | IPv6 | IPs that can never be banned | User/System whitelist files |
| **user_blacklist_v4** | IPv4 | User-defined permanent bans | User blacklist file |
| **user_blacklist_v6** | IPv6 | User-defined permanent bans | User blacklist file |
| **system_blacklist_v4** | IPv4 | System-defined permanent bans | System blacklist files |
| **system_blacklist_v6** | IPv6 | System-defined permanent bans | System blacklist files |
| **temp_ban_v4** | IPv4 | Temporary bans with timeout | fail2ban + manual temp-ban |
| **temp_ban_v6** | IPv6 | Temporary bans with timeout | fail2ban + manual temp-ban |

### Set Hierarchy

```
Packet arrives
    ↓
Check whitelist_v4/v6 → If match: ACCEPT
    ↓
Check temp_ban_v4/v6 → If match: DROP
    ↓
Check user_blacklist_v4/v6 → If match: DROP
    ↓
Check system_blacklist_v4/v6 → If match: DROP
    ↓
Continue with other rules...
```

---

## 🛠️ Troubleshooting

### Common Issues

#### "Global table not found"

**Problem**: The nftables global table doesn't exist.

```bash
# Verify table missing
sudo nft list tables

# Solution: Initialize nftables
sudo nftban init

# Or run the full setup
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### "Cannot ban your own login IP"

**Problem**: Tried to ban the IP you're logged in from.

```bash
# Check your current IP
sudo nftban --info

# If you really need to ban it, first:
# 1. Add it to whitelist
sudo nftban --add-ip

# 2. Or login from different IP
# 3. Then ban the target IP
```

#### "Cannot ban whitelisted IP"

**Problem**: IP exists in whitelist (user or system).

```bash
# Check where IP is whitelisted
sudo nftban --verify-ip 203.0.113.50

# If in user whitelist, you can remove it:
# Edit the file
sudo nano /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Remove the line with that IP, then sync
sudo nftban --sync

# System whitelist is auto-managed (server IPs, etc.)
# Don't modify system whitelist
```

#### Sync Issues (Files vs Active Sets)

**Problem**: Configuration files don't match active nftables sets.

```bash
# Check sync status
sudo nftban --validate-sync

# If issues found, reload configuration
sudo nftban --sync

# Or manually reload
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### IP Not Removed After Running --remove-ip

**Problem**: IP shows removed but still blocked.

```bash
# Remove IP
sudo nftban --remove-ip 192.0.2.50

# Note in output: "Permanent sets need reload"
# This is normal - permanent sets require sync

# Reload to apply
sudo nftban --sync

# Verify removal
sudo nftban --verify-ip 192.0.2.50
```

#### Fail2Ban Commands Not Working

**Problem**: Fail2Ban not installed or not running.

```bash
# Check status
sudo nftban status

# If shows "not installed"
# Install fail2ban first:
sudo apt-get install fail2ban  # Debian/Ubuntu
sudo dnf install fail2ban      # RHEL/CentOS

# If installed but inactive
sudo systemctl start fail2ban
sudo systemctl enable fail2ban

# Verify
sudo nftban --fail2ban-jails
```

#### Configuration Syntax Errors

**Problem**: Config check fails.

```bash
# Check configuration
sudo nftban --check

# Common causes:
# 1. Syntax error in nftables.conf
sudo nft -c -f /etc/nftables.conf

# 2. Fail2ban config error
sudo fail2ban-client --test

# 3. Missing required sets
sudo nftban --show-sets
```

### Permission Denied

```bash
# Most commands require root
sudo nftban <command>

# Check you're root
id
# Should show uid=0(root)
```

### Command Not Found

```bash
# Check if symlink exists
ls -la /usr/local/bin/nftban

# If missing, recreate
sudo ln -sf /etc/nftban/bin/nftban /usr/local/bin/nftban

# Or use full path
sudo /etc/nftban/bin/nftban status
```

---

## 🔐 Security Considerations

### Built-in Protections

- ✅ **Own IP Protection**: Cannot ban your current login IP
- ✅ **Whitelist Protection**: Cannot ban any whitelisted IP
- ✅ **Dual Whitelist Check**: Checks both user and system whitelists
- ✅ **Safe Removal**: Remove operations check all locations
- ✅ **Input Validation**: All IPs validated before processing
- ✅ **Comment Sanitization**: Dangerous characters removed from comments

### Best Practices

1. **Always Whitelist Management IPs**
   ```bash
   # Add your office/home IPs first
   sudo nftban --add-ip 203.0.113.100
   sudo nftban --add-ip 203.0.113.101
   ```

2. **Use Comments on Bans**
   ```bash
   # Document why you banned
   sudo nftban --perm-ban 192.0.2.50 "Confirmed brute-force attacker - Ticket #12345"
   ```

3. **Regular Sync Checks**
   ```bash
   # Weekly validation
   sudo nftban --validate-sync
   ```

4. **Monitor Ban Lists**
   ```bash
   # Review bans monthly
   sudo nftban --view-banned
   ```

5. **Test Before Production**
   ```bash
   # Always test on non-production first
   sudo nftban --temp-ban TEST_IP
   sudo nftban --list-temp
   sudo nftban --remove-ban TEST_IP
   ```

---

## ⚙️ Technical Details

**Script Version:** 3.6.0  
**Shell:** Bash 4.0+  
**Dependencies:**
- nftables (required)
- fail2ban (optional but recommended)
- systemctl (required)
- grep, sed, awk (standard tools)

### Performance Characteristics

- **Command execution**: < 1 second (most commands)
- **Sync operation**: 2-10 seconds (depends on rule count)
- **Memory usage**: < 10 MB
- **CPU usage**: Minimal (< 1%)

### Exit Codes

```
0  - Success
1  - Generic failure (invalid input, failed checks)
2  - No change needed (e.g., IP already exists)
```

### Environment Variables

```bash
# Require fail2ban for config checks
export REQUIRE_F2B=true
nftban --check

# Disable file logging
export ENABLE_LOGGING=false
nftban --temp-ban 192.0.2.50
```

---

## 🔄 Integration with nftban Suite

### Complete nftban Workflow

```
1. System Preparation
   └─→ nftban_init.sh --github -y
        Creates directories, installs packages

2. Firewall Configuration
   └─→ nftban_init_nftables_conf.sh --install-final
        Creates nftables table and sets, applies rules

3. Intrusion Prevention
   └─→ nftban_init_fail2ban_conf.sh setup
        Configures fail2ban with nftables backend

4. Daily Management (THIS TOOL)
   └─→ nftban <command>
        Ban/unban IPs, manage lists, monitor status
```

### Shared Configuration

All tools share:
- Configuration files: `/etc/nftban/config/`
- Logs: `/var/log/nftban/`
- Global table: `inet nftban_global`

---

## 📜 License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025  
**Antonios Voulvoulis – ITCMS** (IT Consulting Managed Services)  
https://itcms.gr

### 📋 Summary

✅ **You CAN:**
- Use for personal or commercial projects
- Modify and customize
- Deploy on unlimited systems
- Charge for services using this software
- Include in managed service offerings

❌ **You CANNOT:**
- Sell the software itself
- Sublicense or resell
- Distribute as a paid product
- Remove copyright notices

See [LICENSE.md](./LICENSE.md) for complete legal text.

---

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create feature branch
3. Test thoroughly
4. Update documentation
5. Submit pull request

### Reporting Issues

Include:
- Operating system and version
- nftban version (`nftban version`)
- Command that failed
- Complete error message
- Output of `nftban status`

---

## 📚 Related Documentation

- [Main README](README.md) - Project overview
- [nftban_init.sh README](README_nftban_init.md) - System preparation
- [nftban_init_nftables_conf.sh README](README_nftban_init_nftables_conf.md) - Firewall setup
- [nftban_init_fail2ban_conf.sh README](README_nftban_fail2ban.md) - Fail2Ban integration
- [LICENSE](LICENSE.md) - Full license text

---

## 📞 Support

### Community Support

- **Issues**: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

### Professional Support

- **Author**: Antonios Voulvoulis (ITCMS Team)
- **Email**: support@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)

---

## 🎯 FAQ

### What's the difference between temp-ban and perm-ban?

**Temp Ban (`--temp-ban`)**:
- Adds IP to `temp_ban_v4/v6` set
- Automatically removed after timeout (default 1 hour)
- Takes effect immediately
- Good for transient attackers

**Permanent Ban (`--perm-ban`)**:
- Writes IP to blacklist file
- Stays until manually removed
- Requires `--sync` to load into permanent set
- Also adds temp ban for immediate effect
- Good for confirmed malicious IPs

### Can I ban an entire subnet?

Yes! Both IPv4 and IPv6 CIDR notation supported:

```bash
# Ban entire subnet
sudo nftban --temp-ban 192.0.2.0/24 "Entire subnet is malicious"
sudo nftban --perm-ban 2001:db8::/32 "Spam network"
```

### How do I unban an IP I banned by mistake?

```bash
# Remove from everywhere
sudo nftban --remove-ip 192.0.2.50

# If it was permanently banned, sync to apply
sudo nftban --sync

# Verify it's removed
sudo nftban --verify-ip 192.0.2.50
```

### What happens when I run --sync?

The `--sync` command:
1. Reads all configuration files
2. Rebuilds nftables sets from files
3. Applies the new rules
4. Essentially runs: `nftban_init_nftables_conf.sh --install-final`

### Do I need fail2ban for nftban to work?

No, but it's recommended:
- **Without fail2ban**: Manual ban/unban still works
- **With fail2ban**: Automatic banning of repeated offenders

### How can I see why an IP was banned?

```bash
# Check user blacklist (has comments)
grep 192.0.2.50 /etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local

# Example output:
# 192.0.2.50 # SSH brute-force attempt - Ticket #12345

# Or use comprehensive check
sudo nftban --verify-ip 192.0.2.50
```

### Can I ban my own IP?

No, the CLI specifically prevents this for safety. If you really need to:

1. Add IP to whitelist first
2. Login from different IP
3. Then ban if necessary

---

## 📖 Quick Reference Card

```bash
# WHITELIST MANAGEMENT
nftban --add-ip [IP]              # Add to whitelist
nftban --info                     # Show current IP status

# BANNING
nftban --temp-ban IP [COMMENT]    # Temporary (1 hour)
nftban --perm-ban IP [COMMENT]    # Permanent
nftban --list-temp                # List temp bans
nftban --view-banned              # View all bans

# UNBANNING
nftban --remove-ban IP            # Remove from temp sets
nftban --remove-ip IP             # Remove from everywhere

# VALIDATION & SYNC
nftban --verify-ip IP             # Where does IP exist?
nftban --validate-sync            # Check file vs set sync
nftban --show-sets                # Show all set contents
nftban --sync                     # Reload from files

# STATUS & INFO
nftban status                     # System status
nftban version                    # Version info
nftban --check                    # Config syntax check
nftban --list                     # List rules

# SERVICE MANAGEMENT
nftban --start                    # Start services
nftban --stop                     # Stop services
nftban --restart                  # Restart services
nftban --enable                   # Enable on boot
nftban --disable                  # Disable on boot

# FAIL2BAN
nftban --fail2ban-jails           # List jails
nftban --fail2ban-banned [JAIL]   # Show banned IPs
nftban --fail2ban-check           # Check config
```

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Command-line interface for nftban firewall management</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Bug</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>
