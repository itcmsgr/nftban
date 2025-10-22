# NFTBan Fail2Ban Integration Module

**Module:** `nftban_fail2ban_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Fail2Ban Integration Module creates a seamless bridge between Fail2Ban's log monitoring and NFTBan's nftables-based ban system. It auto-generates Fail2Ban actions, jail configurations, and provides a monitoring panel for all Fail2Ban-protected services.

### Key Features

- **Auto-Configuration**: One-command setup creates all necessary Fail2Ban actions and jails
- **NFTBan Actions**: Custom Fail2Ban action that calls `nftban blacklist ban` instead of iptables
- **Pre-Built Jails**: SSH, SMTP, HTTP, IMAP/POP3 jail templates
- **Monitoring Panel**: Beautiful colored dashboard showing all protected services
- **Jail Management**: Enable/disable jails with built-in validation (BUG49 fix)
- **Zero Conflicts**: Works alongside existing Fail2Ban configurations

### Dependencies

- **Fail2Ban**: Must be installed (`fail2ban-client` command)
- **NFTBan Blacklist Module**: For ban/unban operations
- **systemd**: For service management

---

## API Reference

### Setup Functions

**`nftban_fail2ban_setup()`** - Auto-configure Fail2Ban integration
```bash
nftban fail2ban setup

# Creates:
# - /etc/fail2ban/action.d/nftban.conf (custom action)
# - /etc/fail2ban/jail.d/nftban-sshd.conf (example jail)

# Output:
# Fail2ban integration configured!
#
# Next steps:
#   1. Review jail: /etc/fail2ban/jail.d/nftban-sshd.conf
#   2. Reload fail2ban: systemctl reload fail2ban
#   3. Check status: fail2ban-client status sshd
#   4. Enable more jails: nftban fail2ban jail-enable <name>
```

**Created action file** (`/etc/fail2ban/action.d/nftban.conf`):
```ini
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/nftban blacklist ban <ip> 3600 "fail2ban-<name>" 2>&1 | logger -t nftban-fail2ban
actionunban = /usr/local/bin/nftban blacklist unban <ip> 2>&1 | logger -t nftban-fail2ban

[Init]
name = default
```

**Created jail file** (`/etc/fail2ban/jail.d/nftban-sshd.conf`):
```ini
[sshd]
enabled = true
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
action = nftban
ignoreip = 127.0.0.1/8 ::1
```

---

### Jail Management

**`nftban_fail2ban_enable_jail(jail_name)`** - Enable specific jail
```bash
nftban fail2ban jail-enable sshd
# Enabling jail: sshd
# Jail enabled (fail2ban reloaded)
```
- **BUG49 Fix**: Validates jail name (alphanumeric + `_-`, max 64 chars) to prevent path traversal
- **Actions**: Enables jail in config, reloads Fail2Ban service
- **Security**: Prevents `../../etc/passwd` style attacks

**`nftban_fail2ban_disable_jail(jail_name)`** - Disable specific jail
```bash
nftban fail2ban jail-disable apache-auth
# Disabling jail: apache-auth
# Jail disabled
```
- **Actions**: Sets `enabled = false` in config, reloads Fail2Ban
- **Preserves**: Jail configuration for future re-enabling

**`nftban_fail2ban_list_jails()`** - List all active jails with ban counts
```bash
nftban fail2ban list-jails

# ═══════════════════════════════════════════════════════════
#   Fail2ban Jails
# ═══════════════════════════════════════════════════════════
#
# Active Jails:
#   sshd                  12 banned
#   apache-auth           3 banned
#   postfix               0 banned
#   nginx-limit-req       5 banned
```

---

### Monitoring Functions

**`nftban_fail2ban_monitor_panel()`** - Beautiful monitoring dashboard
```bash
nftban fail2ban monitor

# +==============================================================================+
# |                      fail2ban SERVICE MONITORING PANEL                       |
# +==============================================================================+
#
# Server Information:
#   Hostname: server.example.com
#   OS:       Debian GNU/Linux 12 (bookworm)
#   Time:     2025-10-22 15:30:45
#
# fail2ban Status:
#   ● Active
#
# Service Monitoring:
#
#   ● SSH          CATCHING - 12 IPs banned
#     Jails: sshd
#   ● SMTP         Monitoring - No bans yet
#     Jails: postfix
#   ● HTTP         CATCHING - 8 IPs banned
#     Jails: nginx-limit-req, apache-auth
#     IMAP/POP3    Not monitored
#
# Summary:
#   Services Monitored: 3 / 4
#   Total Banned IPs:   20
#
# +------------------------------------------------------------------------------+
# Legend:
#   ● Monitoring  - Service jail enabled, no attacks detected
#   ● CATCHING    - Service jail enabled, actively blocking attacks
#      Not monitored - No jail configured for this service
# +------------------------------------------------------------------------------+
```
- **Services tracked**: SSH, SMTP, HTTP, IMAP/POP3
- **Color coding**: Green (monitoring), Red (catching attacks), Gray (not monitored)
- **Auto-detection**: Scans Fail2Ban for jails matching service patterns

**`nftban_fail2ban_show_status()`** - Detailed Fail2Ban status
```bash
nftban fail2ban status

# ═══════════════════════════════════════════════════════════
#   Fail2ban Status
# ═══════════════════════════════════════════════════════════
#
# Service:
#   ● ACTIVE
#   Boot: ENABLED
#
# Overview:
# Status
# |- Number of jail:      4
# `- Jail list:   sshd, apache-auth, postfix, nginx-limit-req
#
# Jail Details:
#
# Jail: sshd
#   Currently failed:     0
#   Total failed:         234
#   Currently banned:     12
#   Total banned:         45
#
# Jail: apache-auth
#   Currently failed:     2
#   Total failed:         89
#   Currently banned:     3
#   Total banned:         12
```

---

## Configuration

**NFTBan Action** (`/etc/fail2ban/action.d/nftban.conf`):
```ini
[Definition]
# Ban action: Call nftban with 1-hour ban (3600s)
actionban = /usr/local/bin/nftban blacklist ban <ip> 3600 "fail2ban-<name>" 2>&1 | logger -t nftban-fail2ban

# Unban action: Remove from blacklist
actionunban = /usr/local/bin/nftban blacklist unban <ip> 2>&1 | logger -t nftban-fail2ban

# No special start/stop/check actions needed
actionstart =
actionstop =
actioncheck =

[Init]
name = default
```

**Example Jails**:

**SSH Protection** (`/etc/fail2ban/jail.d/nftban-sshd.conf`):
```ini
[sshd]
enabled = true
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
action = nftban
ignoreip = 127.0.0.1/8 ::1
```

**Apache Authentication** (`/etc/fail2ban/jail.d/nftban-apache-auth.conf`):
```ini
[apache-auth]
enabled = true
backend = auto
port = http,https
filter = apache-auth
maxretry = 3
findtime = 10m
bantime = 24h
action = nftban
logpath = /var/log/apache2/*error.log
ignoreip = 127.0.0.1/8 ::1
```

**Nginx Rate Limiting** (`/etc/fail2ban/jail.d/nftban-nginx-limit.conf`):
```ini
[nginx-limit-req]
enabled = true
backend = auto
port = http,https
filter = nginx-limit-req
maxretry = 10
findtime = 1m
bantime = 2h
action = nftban
logpath = /var/log/nginx/*error.log
ignoreip = 127.0.0.1/8 ::1
```

---

## CLI Integration

```bash
# Initial setup
nftban fail2ban setup

# Jail management
nftban fail2ban jail-enable sshd
nftban fail2ban jail-disable apache-auth
nftban fail2ban list-jails

# Monitoring
nftban fail2ban monitor        # Beautiful dashboard
nftban fail2ban status          # Detailed status
```

---

## Integration Workflow

### 1. Fail2Ban Detects Attack
```
SSH login attempt from 203.0.113.50
Password incorrect (5 times in 10 minutes)
→ Fail2Ban jail "sshd" triggers
```

### 2. NFTBan Action Called
```bash
/usr/local/bin/nftban blacklist ban 203.0.113.50 3600 "fail2ban-sshd"
```

### 3. IP Banned in nftables
```nft
# Added to temp_ban set (split tables)
nft add element ip nftban_v4 temp_ban { 203.0.113.50 timeout 3600s comment "fail2ban-sshd" }
```

### 4. Logging
```bash
# Logged to both Fail2Ban and NFTBan logs
logger -t nftban-fail2ban "Banned 203.0.113.50 for 3600s (fail2ban-sshd)"
```

### 5. Auto-Unban (after 1 hour)
```bash
# nftables auto-expires (timeout 3600s)
# OR Fail2Ban calls unban action
/usr/local/bin/nftban blacklist unban 203.0.113.50
```

---

## Testing

### Test 1: Setup Verification

```bash
# Setup integration
nftban fail2ban setup

# Verify action file
cat /etc/fail2ban/action.d/nftban.conf

# Verify jail file
cat /etc/fail2ban/jail.d/nftban-sshd.conf

# Reload Fail2Ban
systemctl reload fail2ban

# Check jail loaded
fail2ban-client status sshd
```

### Test 2: Trigger SSH Ban (Controlled Test)

```bash
# From test machine, attempt SSH brute force
for i in {1..10}; do
    ssh invalid_user@target_server
done

# On target server, check Fail2Ban logs
tail -f /var/log/fail2ban.log | grep sshd

# Check NFTBan bans
nftban blacklist list | grep fail2ban-sshd

# Verify nftables set
nft list set ip nftban_v4 temp_ban
```

### Test 3: Manual Ban/Unban via Fail2Ban

```bash
# Manual ban
fail2ban-client set sshd banip 192.168.1.100

# Verify in NFTBan
nftban search 192.168.1.100
# Output: IP 192.168.1.100 found in: temp_ban (fail2ban-sshd)

# Manual unban
fail2ban-client set sshd unbanip 192.168.1.100

# Verify removed
nftban search 192.168.1.100
# Output: IP 192.168.1.100 not found
```

### Test 4: Monitoring Panel

```bash
# Start monitoring panel
watch -c -n 2 'nftban fail2ban monitor'

# From another terminal, trigger attacks
# Watch panel update in real-time
```

---

## Troubleshooting

### Issue 1: Fail2Ban Bans Not Appearing in NFTBan

**Symptoms**: Fail2Ban shows bans, but `nftban blacklist list` doesn't

**Causes**:
1. NFTBan action not configured
2. Action file has wrong path to nftban binary
3. Permission issues

**Solutions**:
```bash
# Re-run setup
nftban fail2ban setup

# Verify action file
cat /etc/fail2ban/action.d/nftban.conf | grep actionban

# Check nftban path
which nftban
# Should be: /usr/local/bin/nftban

# Test action manually
/usr/local/bin/nftban blacklist ban 192.0.2.1 3600 "test"

# Check syslog for errors
grep nftban-fail2ban /var/log/syslog
```

### Issue 2: "Invalid jail name" Error (BUG49)

**Symptoms**: `Invalid jail name: '../../etc/passwd'`

**Causes**: Attempting path traversal attack or special characters in jail name

**Solutions**:
```bash
# Valid jail names
nftban fail2ban jail-enable sshd           # ✓ Valid
nftban fail2ban jail-enable apache_auth    # ✓ Valid
nftban fail2ban jail-enable my-jail-123    # ✓ Valid

# Invalid jail names
nftban fail2ban jail-enable "../../passwd" # ✗ Invalid (path traversal)
nftban fail2ban jail-enable "jail;rm -rf"  # ✗ Invalid (special chars)
nftban fail2ban jail-enable "very_long_name_that_exceeds_64_characters_limit..." # ✗ Invalid (too long)

# Jail name requirements:
# - Alphanumeric characters only
# - Underscores (_) and hyphens (-) allowed
# - Maximum 64 characters
```

### Issue 3: Fail2Ban Not Starting

**Symptoms**: `fail2ban service is not running`

**Causes**:
1. Service not installed
2. Configuration errors
3. Service disabled

**Solutions**:
```bash
# Check if installed
which fail2ban-client

# Install if missing
apt-get install fail2ban   # Debian/Ubuntu
yum install fail2ban        # RHEL/CentOS

# Check configuration
fail2ban-client -t

# Start service
systemctl start fail2ban

# Enable on boot
systemctl enable fail2ban

# Check status
systemctl status fail2ban
```

### Issue 4: Duplicate Bans (iptables + nftables)

**Symptoms**: IPs banned in both iptables and nftables

**Causes**: Default Fail2Ban actions still using iptables

**Solutions**:
```bash
# Edit jail to use ONLY nftban action
# /etc/fail2ban/jail.d/nftban-sshd.conf
[sshd]
action = nftban  # NOT: action = %(action_mwl)s

# Disable default iptables actions
# Remove or comment out in /etc/fail2ban/jail.local:
# action = %(action_)s
# action = %(action_mw)s
# action = %(action_mwl)s

# Reload
systemctl reload fail2ban
```

---

## Security Considerations

### BUG49: Path Traversal Prevention

**Vulnerability**: Jail name validation (Fixed in v0.9.2)

**Attack**:
```bash
nftban_fail2ban_enable_jail "../../etc/shadow"
# Pre-BUG49: Could manipulate filesystem
# Post-BUG49: Rejected with error
```

**Fix**: `validate_jail_name()` function enforces:
- Alphanumeric characters + `_` + `-` only
- Maximum 64 characters
- No path separators (`/`, `\`, `.`)

### Integration Security

**Logging**: All Fail2Ban actions logged to syslog
```bash
# Monitor for suspicious activity
tail -f /var/log/syslog | grep nftban-fail2ban
```

**Whitelist Protection**: Fail2Ban `ignoreip` + NFTBan whitelist
```bash
# /etc/fail2ban/jail.d/nftban-sshd.conf
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8

# NFTBan whitelist
nftban whitelist add 203.0.113.50 "Admin IP"
```

---

## Best Practices

### Production Deployment

1. **Test in dry-run first**:
   ```bash
   # Edit /etc/fail2ban/jail.d/nftban-sshd.conf
   banaction = %(banaction)s  # Use default (iptables) first
   # Test for 1 week
   # Then switch to:
   action = nftban
   ```

2. **Monitor daily**:
   ```bash
   # Add to cron
   0 9 * * * nftban fail2ban status | mail -s "Fail2Ban Status" admin@example.com
   ```

3. **Coordinate ban times**:
   ```bash
   # Fail2Ban bantime should match NFTBan timeout
   [sshd]
   bantime = 1h              # Fail2Ban config
   # NFTBan action: 3600s    # Same duration
   ```

4. **Enable multiple jails**:
   ```bash
   nftban fail2ban setup
   # Enable jails for all services:
   # - SSH (sshd)
   # - Apache (apache-auth, apache-noscript, apache-overflows)
   # - Nginx (nginx-limit-req, nginx-http-auth)
   # - Postfix (postfix, postfix-sasl)
   ```

---

## Integration with Other Modules

### With Blacklist Module

Fail2Ban → NFTBan Blacklist → nftables `temp_ban` set

```bash
# Fail2Ban calls:
nftban blacklist ban <ip> 3600 "fail2ban-sshd"

# Which calls:
nftban_blacklist_ban_ip() → nftables set add
```

### With Stats Module

```bash
# Analyze Fail2Ban ban history
nftban stats history --source=fail2ban

# Top attacked services
nftban blacklist list | grep fail2ban | cut -d'-' -f2 | sort | uniq -c | sort -rn
```

### With GeoIP Module

```bash
# Lookup banned IPs by country
nftban blacklist list | grep fail2ban | awk '{print $1}' | while read ip; do
    echo "$ip: $(nftban_geoip_get_compact "$ip")"
done
```

---

## License

**NFTBAN Custom License v3.0**
SPDX-License-Identifier: NFTBAN-Custom-License

© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

---

**Made by ITCMS** | https://itcms.gr
Empowering system administrators with simple, powerful security tools.
