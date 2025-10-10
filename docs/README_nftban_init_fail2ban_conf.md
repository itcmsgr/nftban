# nftban_init_fail2ban_conf.sh

**Comprehensive Fail2Ban automation with nftables backend and advanced login monitoring**

[![Version](https://img.shields.io/badge/version-3.6-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A sophisticated automation tool that configures Fail2Ban with nftables backend, featuring enhanced security monitoring, intelligent mail alerts, login tracking, and comprehensive ban management.

---

## 🎯 What's New in v3.6

### 🔐 Enhanced Security Features

- **Rate Limiting**: Built-in protection against ban storms (max 10 bans/minute)
- **Input Validation**: Strict IP address and configuration validation
- **Path Sanitization**: Prevents path traversal attacks
- **Configuration Syntax Checking**: Validates before applying changes

### 📧 Improved Email System

- **Multi-MTA Support**: Automatic detection of Postfix, Exim, MSMTP
- **Enhanced Testing**: Comprehensive mail system diagnostics
- **Timeout Protection**: Prevents hanging on mail operations
- **Detailed Logging**: Debug mode for troubleshooting mail issues

### 📊 Advanced Monitoring

- **Login Monitor**: Real-time SSH/sudo/root login tracking
- **Periodic Scanning**: Timer-based digest reports
- **Ban Statistics**: Comprehensive reporting and analysis
- **System Status Dashboard**: Visual health monitoring

### 🛡️ Better Management

- **Dry-Run Mode**: Preview changes without applying
- **Backup Rotation**: Automatic cleanup of old backups (30 days retention)
- **Configuration Comparison**: Visual diff between base and local configs
- **Self-Test Suite**: Comprehensive system validation

---

## 🚀 What This Script Does

### Core Functionality

✅ **Fail2Ban Configuration**
- Configures nftables backend (not iptables)
- Creates jail configurations for multiple services
- Manages whitelist/blacklist files
- Integrates with global nftables sets

✅ **Email Alert System**
- Auto-detects sendmail-compatible MTAs
- Creates custom mail actions
- Tests mail delivery with detailed diagnostics
- Sends ban/unban notifications

✅ **Login Monitoring**
- **Live Service**: Real-time journald log monitoring
- **Periodic Timer**: Scheduled digest reports
- Tracks failed logins, successful logins, sudo usage, root access
- Configurable alerts and thresholds

✅ **Ban Management**
- Direct nftables integration for bans/unbans
- IP validation (IPv4 and IPv6)
- Whitelist protection
- Ban rate limiting
- Detailed ban logging

✅ **Configuration Management**
- Base configuration (auto-managed)
- User configuration (`.conf.local` - preserved)
- Template system for jails
- Configuration validation and comparison
- Automatic backup and rotation

---

## 📋 Prerequisites

Before running this script, you must have:

1. ✅ **nftban_init.sh** - System preparation completed
2. ✅ **nftban_init_nftables_conf.sh** - NFTables configured and running
3. ✅ **Root access** - Must run as root/sudo
4. ✅ **Fail2Ban installed** - Should be installed by nftban_init.sh
5. ✅ **NFTables table** - `inet nftban_global` table must exist

### Verify Prerequisites

```bash
# Check if nftables table exists
sudo nft list table inet nftban_global

# Check if fail2ban is installed
fail2ban-client --version

# Check if fail2ban is running
systemctl status fail2ban
```

---

## 🎯 Complete Workflow Guide

### Step 1: System Preparation (First Time)

```bash
# Run nftban_init.sh (only needed once)
sudo ./nftban_init.sh --github -y
```

### Step 2: Configure NFTables (Required)

```bash
# Configure and activate firewall
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Step 3: Configure Fail2Ban (This Script)

```bash
# Initial setup
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

# Test mail system
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Check status
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh status
```

### Step 4: Enable Login Monitoring (Optional)

```bash
# Install login monitor components
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor install

# Enable live monitoring (real-time)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable service

# Or enable periodic scanning (digest mode)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable timer

# Or enable both (hybrid mode)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable hybrid
```

### Step 5: Restart Fail2Ban

```bash
# Apply all changes
sudo systemctl restart fail2ban

# Verify jails are active
sudo fail2ban-client status
```

---

## 🎛️ Command Reference

### Configuration Commands

```bash
# Initial setup (creates base config + empty .conf.local)
sudo nftban_init_fail2ban_conf.sh setup

# Compare base vs local configuration
sudo nftban_init_fail2ban_conf.sh diff-config

# Validate configuration syntax and values
sudo nftban_init_fail2ban_conf.sh validate-config

# Generate configuration documentation
sudo nftban_init_fail2ban_conf.sh gen-docs
```

### Status & Monitoring

```bash
# Show comprehensive system status
sudo nftban_init_fail2ban_conf.sh status

# Show ban statistics and top offenders
sudo nftban_init_fail2ban_conf.sh stats

# Run comprehensive self-test
sudo nftban_init_fail2ban_conf.sh self-test
```

### Email System

```bash
# Check mail system configuration
sudo nftban_init_fail2ban_conf.sh check-mail

# Send test email
sudo nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Regenerate mail action file
sudo nftban_init_fail2ban_conf.sh generate-mail-action
```

### Backup & Restore

```bash
# Backup current configuration
sudo nftban_init_fail2ban_conf.sh backup-config

# List available backups
sudo nftban_init_fail2ban_conf.sh list-backups

# Restore from backup
sudo nftban_init_fail2ban_conf.sh restore-config /path/to/backup.tar.gz
```

### Login Monitor Management

```bash
# Install login monitor
sudo nftban_init_fail2ban_conf.sh login-monitor install

# Enable live service (real-time monitoring)
sudo nftban_init_fail2ban_conf.sh login-monitor enable service

# Enable timer (periodic digest)
sudo nftban_init_fail2ban_conf.sh login-monitor enable timer

# Enable both (hybrid mode)
sudo nftban_init_fail2ban_conf.sh login-monitor enable hybrid

# Check status
sudo nftban_init_fail2ban_conf.sh login-monitor status

# Disable login monitor
sudo nftban_init_fail2ban_conf.sh login-monitor disable all

# Completely remove
sudo nftban_init_fail2ban_conf.sh login-monitor uninstall
```

### Manual Ban/Unban Operations

```bash
# Initialize NFT for a jail (rarely needed manually)
sudo nftban_init_fail2ban_conf.sh nft-init ssh

# Ban an IP (with optional timeout)
sudo nftban_init_fail2ban_conf.sh ban ssh 192.168.1.100
sudo nftban_init_fail2ban_conf.sh ban ssh 192.168.1.100 3600
sudo nftban_init_fail2ban_conf.sh ban ssh 192.168.1.100 1h

# Unban an IP
sudo nftban_init_fail2ban_conf.sh unban 192.168.1.100
```

### Testing & Dry-Run

```bash
# Dry-run mode (preview changes)
sudo nftban_init_fail2ban_conf.sh --dry-run setup

# Run self-test suite
sudo nftban_init_fail2ban_conf.sh self-test
```

---

## 📁 Configuration Files

### File Structure

```
/etc/nftban/config/
├── nftban.conf                              # Base config (auto-managed)
├── nftban.conf.local                        # User config (your settings)
├── nftban-configuration-user-whitelist_ips.conf.local
├── nftban-configuration-user-blacklist_ips.conf.local
├── nftban-fail2ban-ip-whitelist.conf.local  # Fail2Ban whitelist
└── nftban-configuration-system_whitelist_ips.conf.local

/etc/nftban/templates/fail2ban/
├── jail.d/           # Jail templates
├── filter.d/         # Filter templates
└── action.d/         # Action templates

/etc/fail2ban/
├── jail.d/
│   ├── 00-nftban.conf                       # Global defaults
│   └── NFTBAN_F2B_*_JAIL.conf              # Individual jails
├── filter.d/
│   └── NFTBAN_F2B_*.conf                    # Filter definitions
└── action.d/
    ├── nftban-global.conf                   # NFT ban action
    └── NFTBAN_F2B_SENDMAIL.conf            # Mail action
```

### Configuration Hierarchy

```
System Configuration (Auto-Managed)          User Configuration (Preserved)
┌─────────────────────────────────┐         ┌──────────────────────────────┐
│ nftban.conf                     │    +    │ nftban.conf.local            │
│ - Created by 'setup'            │         │ - Your customizations        │
│ - Updated on version changes    │         │ - Never overwritten          │
│ - Reference/defaults            │         │ - Overrides base settings    │
└─────────────────────────────────┘         └──────────────────────────────┘
                                    ↓
                          Merged Configuration
                        (loaded by the script)
```

---

## ⚙️ Configuration Options

### Email Settings

```bash
# Edit /etc/nftban/config/nftban.conf.local

NFTBAN_F2B_RECIPIENT="admin@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ALERT_ENABLED="true"
```

### Default Jail Settings

```bash
NFTBAN_F2B_DEF_BAN_TIME="3600"        # 1 hour
NFTBAN_F2B_DEF_FIND_TIME="600"        # 10 minutes
NFTBAN_F2B_DEF_MAX_RETRY="5"          # 5 attempts
NFTBAN_F2B_BACKEND="systemd"          # systemd or polling
```

### Enhanced Security

```bash
NFTBAN_F2B_AGGRESSIVE_MODE="false"    # Auto-ban on threshold
NFTBAN_F2B_GEOIP_ENABLE="true"        # GeoIP lookups
NFTBAN_F2B_WHOIS_ENABLE="true"        # WHOIS lookups
```

### Login Monitoring

```bash
NFTBAN_F2B_LOGIN_MONITOR="true"
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_SSH_LOGIN_ALERT="false"
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"
```

### Individual Jail Configuration

```bash
# SSH Jail
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_SSH_BAN_TIME="1800"        # 30 minutes
NFTBAN_F2B_SSH_MAX_RETRY="3"
NFTBAN_F2B_SSH_FIND_TIME="600"        # 10 minutes

# WordPress Jail
NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_WORDPRESS_BAN_TIME="7200"  # 2 hours
NFTBAN_F2B_WORDPRESS_MAX_RETRY="3"
NFTBAN_F2B_WORDPRESS_FIND_TIME="600"

# XML-RPC Jail (WordPress API)
NFTBAN_F2B_XMLRPC_JAIL="true"
NFTBAN_F2B_XMLRPC_BAN_TIME="10800"    # 3 hours
NFTBAN_F2B_XMLRPC_MAX_RETRY="2"
NFTBAN_F2B_XMLRPC_FIND_TIME="300"     # 5 minutes

# DirectAdmin Jail
NFTBAN_F2B_DIRECTADMIN_JAIL="true"
NFTBAN_F2B_DIRECTADMIN_BAN_TIME="14400" # 4 hours
NFTBAN_F2B_DIRECTADMIN_MAX_RETRY="3"
NFTBAN_F2B_DIRECTADMIN_FIND_TIME="600"

# Other available jails:
# APACHE, NGINX, POSTFIX (set to "true" to enable)
```

---

## 💡 Usage Examples

### Example 1: Basic Setup

```bash
# First time setup
sudo nftban_init_fail2ban_conf.sh setup

# Edit configuration
sudo nano /etc/nftban/config/nftban.conf.local

# Change email recipient
NFTBAN_F2B_RECIPIENT="security@example.com"

# Enable SSH jail
NFTBAN_F2B_SSH_JAIL="true"

# Apply changes
sudo systemctl restart fail2ban

# Verify
sudo fail2ban-client status
```

### Example 2: Testing Email Alerts

```bash
# Check mail system
sudo nftban_init_fail2ban_conf.sh check-mail

# Output shows:
# ✅ Sendmail-compatible MTA found: /usr/sbin/sendmail
# ✅ Binary is executable
#    MTA: Postfix detected

# Send test email
sudo nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Check mail logs
sudo tail -f /var/log/mail.log
```

### Example 3: Enable Login Monitoring

```bash
# Install components
sudo nftban_init_fail2ban_conf.sh login-monitor install

# Configure alerts
sudo nano /etc/nftban/config/nftban.conf.local
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="3"

# Enable real-time monitoring
sudo nftban_init_fail2ban_conf.sh login-monitor enable service

# Check status
sudo systemctl status nftban_lfd.service

# View logs
sudo journalctl -u nftban_lfd.service -f
```

### Example 4: Managing Whitelists

```bash
# Add trusted IPs to whitelist
cat >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local <<EOF
# Office IPs
203.0.113.10
203.0.113.11

# VPN Server
198.51.100.5
EOF

# Rebuild Fail2Ban whitelist
sudo nftban_init_fail2ban_conf.sh setup

# Restart Fail2Ban
sudo systemctl restart fail2ban
```

### Example 5: Manual Ban Operations

```bash
# Ban an IP for 1 hour
sudo nftban_init_fail2ban_conf.sh ban ssh 192.168.1.100 3600

# Ban an IP permanently (until manual unban)
sudo nftban_init_fail2ban_conf.sh ban ssh 192.168.1.100

# Check if IP is banned
sudo nft list set inet nftban_global temp_ban_v4 | grep 192.168.1.100

# Unban an IP
sudo nftban_init_fail2ban_conf.sh unban 192.168.1.100

# View ban log
sudo tail -f /var/log/nftban/nftban-bans.log
```

### Example 6: Configuration Validation

```bash
# Compare base vs local config
sudo nftban_init_fail2ban_conf.sh diff-config

# Output shows:
# === Config Comparison ===
# Base:  /etc/nftban/config/nftban.conf
# Local: /etc/nftban/config/nftban.conf.local
# 
# DIFFERENT values (override ok):
#   - NFTBAN_F2B_RECIPIENT
#       BASE='admin@yourdomain.com'
#       USER='security@mycompany.com'

# Validate configuration
sudo nftban_init_fail2ban_conf.sh validate-config

# If errors found, fix them
sudo nano /etc/nftban/config/nftban.conf.local
```

### Example 7: Viewing Statistics

```bash
# Show comprehensive status
sudo nftban_init_fail2ban_conf.sh status

# Show ban statistics
sudo nftban_init_fail2ban_conf.sh stats

# Output shows:
# === Ban Statistics ===
# Top 10 Banned IPs:
#    15  192.168.1.100
#    12  203.0.113.50
#     8  198.51.100.25
# 
# Bans by Jail:
#    20  ssh
#    10  wordpress
#     5  directadmin
```

### Example 8: Backup and Restore

```bash
# Create backup before major changes
sudo nftban_init_fail2ban_conf.sh backup-config
# Output: /etc/nftban/backups/nftban-config-20250110-143022.tar.gz

# List available backups
sudo nftban_init_fail2ban_conf.sh list-backups

# Restore from backup if needed
sudo nftban_init_fail2ban_conf.sh restore-config \
  /etc/nftban/backups/nftban-config-20250110-143022.tar.gz

# Restart Fail2Ban to apply restored config
sudo systemctl restart fail2ban
```

### Example 9: Dry-Run Mode

```bash
# Preview changes without applying
sudo nftban_init_fail2ban_conf.sh --dry-run setup

# Output shows:
# [DRY-RUN] Would execute: install -m 0644 -o root -g root ...
# [DRY-RUN] Would execute: systemctl restart fail2ban
# [DRY-RUN] Would execute: nft add element ...
```

---

## 🔍 Login Monitoring Modes

### Mode 1: Live Service (Real-Time)

**Best for:** Production servers requiring immediate alerts

```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable service
```

**Features:**
- ✅ Real-time log monitoring via journald
- ✅ Immediate email alerts on events
- ✅ Failed login threshold tracking
- ✅ Root/sudo access alerts
- ✅ Optional auto-ban on aggressive mode

**Logs:**
- Service: `/var/log/nftban/login-monitor.log`
- Debug: `/var/log/nftban/login-monitor-debug.log`

**Status:**
```bash
sudo systemctl status nftban_lfd.service
sudo journalctl -u nftban_lfd.service -f
```

### Mode 2: Periodic Timer (Digest)

**Best for:** Servers with high login activity, digest reporting

```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable timer
```

**Features:**
- ✅ Runs every 10 minutes (configurable)
- ✅ Digest email reports
- ✅ Lower resource usage
- ✅ Historical analysis
- ✅ Persistent state tracking

**Configuration:**
```bash
# Edit timer interval
sudo nano /etc/nftban/config/nftban.conf.local
NFTBAN_F2B_LOGIN_TIMER_INTERVAL="10m"  # 10 minutes
```

**Logs:**
- Service: `/var/log/nftban/login-monitor.log`
- State: `/var/lib/nftban/login-monitor/state.json`

**Status:**
```bash
sudo systemctl status nftban-login-scan.timer
sudo systemctl list-timers | grep nftban
```

### Mode 3: Hybrid (Both)

**Best for:** Critical servers requiring both real-time and digest reports

```bash
sudo nftban_init_fail2ban_conf.sh login-monitor enable hybrid
```

**Features:**
- ✅ All real-time alerts
- ✅ Plus periodic digest reports
- ✅ Comprehensive coverage
- ✅ Historical + immediate

---

## 🛡️ Supported Jails

### Pre-configured Jails

| Jail | Default | Ban Time | Max Retry | Description |
|------|---------|----------|-----------|-------------|
| **SSH** | ✅ Enabled | 30 min | 3 | SSH brute-force protection |
| **Apache** | ❌ Disabled | 1 hour | 5 | Apache authentication failures |
| **Nginx** | ❌ Disabled | 1 hour | 5 | Nginx authentication failures |
| **Postfix** | ❌ Disabled | 1 hour | 5 | Email server protection |
| **WordPress** | ✅ Enabled | 2 hours | 3 | WordPress login attacks |
| **XML-RPC** | ✅ Enabled | 3 hours | 2 | WordPress XML-RPC abuse |
| **DirectAdmin** | ✅ Enabled | 4 hours | 3 | DirectAdmin panel protection |

### Enabling Additional Jails

```bash
# Edit configuration
sudo nano /etc/nftban/config/nftban.conf.local

# Enable Apache jail
NFTBAN_F2B_APACHE_JAIL="true"
NFTBAN_F2B_APACHE_BAN_TIME="3600"
NFTBAN_F2B_APACHE_MAX_RETRY="5"

# Enable Nginx jail
NFTBAN_F2B_NGINX_JAIL="true"
NFTBAN_F2B_NGINX_BAN_TIME="3600"
NFTBAN_F2B_NGINX_MAX_RETRY="5"

# Apply changes
sudo nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban

# Verify
sudo fail2ban-client status
```

### Creating Custom Jails

To add a custom jail, you need to create three files:

1. **Jail Configuration** (`/etc/nftban/templates/fail2ban/jail.d/NFTBAN_F2B_CUSTOM_JAIL.conf`)
2. **Filter** (`/etc/nftban/templates/fail2ban/filter.d/NFTBAN_F2B_CUSTOM_JAIL.conf`)
3. **Action** (optional, uses default nftban-global)

See the existing templates for examples.

---

## 🛠️ Troubleshooting

### Common Issues

#### Fail2Ban Not Starting

```bash
# Check Fail2Ban status
sudo systemctl status fail2ban

# Check logs
sudo journalctl -u fail2ban -n 50

# Test configuration
sudo fail2ban-client -t

# Common causes:
# 1. Syntax error in jail configs
sudo fail2ban-client -d | grep -i error

# 2. Missing nftables table
sudo nft list table inet nftban_global

# 3. Permission issues
ls -la /etc/fail2ban/jail.d/
```

#### Email Alerts Not Working

```bash
# Run mail system check
sudo nftban_init_fail2ban_conf.sh check-mail

# If no MTA found, install one:
# Debian/Ubuntu
sudo apt-get install postfix

# RHEL/CentOS/Rocky
sudo dnf install postfix

# Start mail service
sudo systemctl start postfix
sudo systemctl enable postfix

# Test mail
sudo nftban_init_fail2ban_conf.sh test-mail admin@example.com

# Check mail logs
sudo tail -f /var/log/mail.log
sudo tail -f /var/log/maillog
```

#### Login Monitor Not Working

```bash
# Check service status
sudo systemctl status nftban_lfd.service

# Check logs
sudo journalctl -u nftban_lfd.service -n 50

# Common issues:

# 1. Python not found
which python3

# 2. Journalctl not available
which journalctl

# 3. Configuration errors
sudo nano /etc/nftban/config/nftban.conf.local

# 4. Permission issues
ls -la /usr/local/sbin/nftban-login-monitor
ls -la /var/log/nftban/

# Reinstall if needed
sudo nftban_init_fail2ban_conf.sh login-monitor uninstall
sudo nftban_init_fail2ban_conf.sh login-monitor install
sudo nftban_init_fail2ban_conf.sh login-monitor enable service
```

#### Bans Not Applied

```bash
# Check nftables
sudo nft list table inet nftban_global

# Check sets
sudo nft list set inet nftban_global temp_ban_v4
sudo nft list set inet nftban_global temp_ban_v6

# Manual test ban
sudo nftban_init_fail2ban_conf.sh ban ssh 192.0.2.1 300

# Check if ban was added
sudo nft list set inet nftban_global temp_ban_v4 | grep 192.0.2.1

# Check Fail2Ban action
sudo fail2ban-client get ssh actions

# Check ban log
sudo tail -f /var/log/nftban/nftban-bans.log
```

#### IP in Whitelist Still Getting Banned

```bash
# Check whitelist files
cat /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
cat /etc/nftban/config/nftban-fail2ban-ip-whitelist.conf.local

# Rebuild whitelist
sudo nftban_init_fail2ban_conf.sh setup

# Check Fail2Ban ignoreip
sudo fail2ban-client get ssh ignoreip

# Restart Fail2Ban
sudo systemctl restart fail2ban
```

#### Configuration Changes Not Applied

```bash
# After editing .conf.local, always run:
sudo nftban_init_fail2ban_conf.sh setup

# Restart Fail2Ban
sudo systemctl restart fail2ban

# Verify changes
sudo nftban_init_fail2ban_conf.sh validate-config
sudo nftban_init_fail2ban_conf.sh diff-config
```

### Debug Mode

```bash
# Enable debug logging
sudo nano /etc/nftban/config/nftban.conf.local
NFTBAN_F2B_DEBUG="true"

# Check debug logs
sudo tail -f /var/log/nftban/nftban-setup.log
sudo tail -f /var/log/nftban/login-monitor-debug.log

# Run self-test
sudo nftban_init_fail2ban_conf.sh self-test
```

### Getting Help

If issues persist:

1. **Run self-test:**
   ```bash
   sudo nftban_init_fail2ban_conf.sh self-test
   ```

2. **Collect logs:**
   ```bash
   sudo tar -czf nftban-debug.tar.gz /var/log/nftban/
   ```

3. **Report issue with:**
   - Operating system and version
   - Script version
   - Self-test output
   - Relevant log files
   - Configuration (sanitize sensitive data)

---

## 📊 Monitoring & Status

### System Status Dashboard

```bash
sudo nftban_init_fail2ban_conf.sh status
```

**Output includes:**
- ✅ Configuration status (valid/invalid)
- ✅ Enabled jails
- ✅ Service status (Fail2Ban, login monitors)
- ✅ NFTables status
- ✅ Active ban counts (IPv4/IPv6)
- ✅ Recent bans (last 5)
- ✅ Disk usage
- ✅ Last setup time

### Ban Statistics

```bash
sudo nftban_init_fail2ban_conf.sh stats
```

**Provides:**
- Top 10 most banned IPs
- Bans by jail
- Ban timeline (last 7 days)
- Historical trends

### Self-Test

```bash
sudo nftban_init_fail2ban_conf.sh self-test
```

**Checks:**
- ✅ Root privileges
- ✅ Required commands (nft, fail2ban-client, systemctl)
- ✅ Directory permissions
- ✅ Configuration syntax
- ✅ NFTables setup
- ✅ Mail system

---

## 🔐 Security Considerations

### Built-in Protection

- ✅ **Rate Limiting**: Max 10 bans per minute prevents DOS
- ✅ **Input Validation**: All IPs validated before banning
- ✅ **Whitelist Protection**: Whitelisted IPs cannot be banned
- ✅ **Path Sanitization**: Prevents directory traversal
- ✅ **Syntax Validation**: Configs validated before loading
- ✅ **Timeout Protection**: Mail operations timeout after 10s

### Best Practices

1. **Whitelist Critical IPs**
   ```bash
   # Add your management IPs
   echo "YOUR_IP" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
   ```

2. **Use Strong Ban Times**
   ```bash
   # Increase ban time for critical services
   NFTBAN_F2B_SSH_BAN_TIME="7200"  # 2 hours
   ```

3. **Enable Login Monitoring**
   ```bash
   # Get alerts on suspicious activity
   NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
   NFTBAN_F2B_SUDO_ALERT="true"
   ```

4. **Regular Backups**
   ```bash
   # Backup before major changes
   sudo nftban_init_fail2ban_conf.sh backup-config
   ```

5. **Review Statistics**
   ```bash
   # Weekly review of ban patterns
   sudo nftban_init_fail2ban_conf.sh stats
   ```

---

## ⚙️ Technical Details

**Script Version:** 3.6  
**Shell:** Bash 4.0+  
**Dependencies:**
- nftables (firewall)
- fail2ban (IPS)
- Python 3.x (for login monitor)
- sendmail-compatible MTA (for email alerts)
- journald (for login monitor)

### Performance Characteristics

- **Setup time**: 10-30 seconds
- **Memory usage**: < 50 MB (including login monitor)
- **CPU usage**: Minimal (< 1% most of the time)
- **Disk usage**: ~10 MB (logs rotate automatically)

### File Locations

```
/etc/nftban/config/                   # Configuration files
/etc/nftban/templates/fail2ban/       # Jail templates
/etc/nftban/backups/                  # Backups (30 day retention)
/var/log/nftban/                      # Logs
/var/lib/nftban/login-monitor/        # Login monitor state
/usr/local/sbin/nftban-login-monitor  # Live monitor script
/usr/local/sbin/nftban-login-scan     # Periodic scanner script
/etc/systemd/system/nftban_lfd.service       # Live monitor service
/etc/systemd/system/nftban-login-scan.timer  # Periodic timer
```

### Logging

All operations are logged to:
- **Setup log**: `/var/log/nftban/nftban-setup.log`
- **Ban log**: `/var/log/nftban/nftban-bans.log`
- **Login monitor**: `/var/log/nftban/login-monitor.log`
- **Debug log**: `/var/log/nftban/login-monitor-debug.log`

---

## 🔄 Integration with nftban

### Complete nftban Stack

```
┌────────────────────────────────────────────┐
│ nftban_init.sh                             │
│ • System preparation                       │
│ • Package installation                     │
│ • Directory structure                      │
└────────────────┬───────────────────────────┘
                 ↓
┌────────────────────────────────────────────┐
│ nftban_init_nftables_conf.sh               │
│ • NFTables configuration                   │
│ • Firewall rules                           │
│ • Port management                          │
└────────────────┬───────────────────────────┘
                 ↓
┌────────────────────────────────────────────┐
│ nftban_init_fail2ban_conf.sh (THIS)        │
│ • Fail2Ban setup                           │
│ • Jail configuration                       │
│ • Login monitoring                         │
│ • Ban management                           │
└────────────────┬───────────────────────────┘
                 ↓
┌────────────────────────────────────────────┐
│ nftban CLI                                 │
│ • User-friendly commands                   │
│ • Status monitoring                        │
│ • Manual operations                        │
└────────────────────────────────────────────┘
```

### How They Work Together

1. **nftban_init.sh** prepares the system
2. **nftban_init_nftables_conf.sh** creates firewall rules
3. **nftban_init_fail2ban_conf.sh** (this script) adds intrusion prevention
4. **nftban CLI** provides user interface

All scripts share:
- Configuration files in `/etc/nftban/config/`
- Logs in `/var/log/nftban/`
- Backups in `/etc/nftban/backups/`

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

### 🤔 Still Unclear?

**Allowed:**
- $500 setup fee for Fail2Ban configuration using nftban
- $100/month managed security service including nftban
- Consulting services using nftban

**NOT Allowed:**
- Selling "nftban Premium Edition" for $299
- Charging $50 to download the software
- Reselling in a software bundle

See [LICENSE.md](./LICENSE.md) for complete legal text.

### Need Permission to Resell?

📧 Email: contact@itcms.gr  
🌐 Web: https://itcms.gr

---

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create feature branch
3. Test thoroughly (multiple distributions)
4. Update documentation
5. Submit pull request

### Reporting Issues

Include:
- Operating system and version
- Script version
- Self-test output
- Relevant logs
- Steps to reproduce

---

## 📚 Related Documentation

- [Main README](README.md) - Project overview
- [nftban_init.sh README](README_nftban_init.md) - System preparation
- [nftban_init_nftables_conf.sh README](README_nftban_init_nftables_conf.md) - Firewall setup
- [nftban CLI README](README_nftban_cli.md) - Command-line interface
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

### Does this replace my firewall?

No. This works **with** your nftables firewall (configured by nftban_init_nftables_conf.sh) to add intrusion prevention.

### Will legitimate users be blocked?

No, if configured properly. Add your management IPs to the whitelist.

### How do I disable email alerts?

```bash
sudo nano /etc/nftban/config/nftban.conf.local
NFTBAN_F2B_ALERT_ENABLED="false"
```

### Can I use this without a control panel?

Yes. All features work on any Linux server.

### How do I unban myself if locked out?

From another IP or console access:
```bash
sudo nftban_init_fail2ban_conf.sh unban YOUR_IP
```

### What happens if I run setup multiple times?

It's safe. Your `.conf.local` files are preserved, and backups are created.

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Advanced Fail2Ban automation with nftables backend</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Bug</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>
