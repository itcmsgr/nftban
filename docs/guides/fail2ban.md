# Fail2Ban Integration

**Automatic intrusion prevention with NFTBan v0.10.0**

NFTBan v0.10.0 integrates seamlessly with Fail2Ban to provide automatic banning of attackers. This guide explains how the integration works, how to configure it, and how to manage jails.

---

## Table of Contents

- [What is Fail2Ban?](#what-is-failban)
- [How NFTBan Integration Works](#how-nftban-integration-works)
- [Quick Setup](#quick-setup)
- [Managing Jails](#managing-jails)
- [Common Jails](#common-jails)
- [Advanced Configuration](#advanced-configuration)
- [Monitoring & Troubleshooting](#monitoring--troubleshooting)
- [Best Practices](#best-practices)

---

## What is Fail2Ban?

**Fail2Ban** is an intrusion prevention framework that monitors log files and automatically bans IP addresses showing malicious behavior (too many failed login attempts, exploit scanning, etc.).

### How Fail2Ban Works

```
┌──────────────┐
│  Log Files   │ (SSH, Nginx, Postfix, etc.)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Fail2Ban    │ Monitors logs for attack patterns
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  NFTBan CLI  │ Receives ban command
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   nftables   │ Blocks traffic at kernel level
└──────────────┘
```

### Why Use Fail2Ban with NFTBan?

**Automatic Protection**:
- Detects and blocks SSH brute force attacks
- Prevents web exploitation attempts
- Stops mail server abuse
- Protects against service-specific attacks

**Intelligent Banning**:
- Pattern-based detection (not signature-based)
- Configurable thresholds
- Automatic expiry (no manual unbanning)
- Works with any service that logs

**NFTBan Advantages**:
- **Native nftables timeout**: Bans expire automatically via kernel
- **No unban action needed**: nftables handles expiry
- **Runtime table**: Bans survive firewall reloads
- **Dynamic jail discovery**: No hardcoded jail lists
- **OS-aware recommendations**: Suggests jails based on installed services

---

## How NFTBan Integration Works

### Traditional Fail2Ban Action

**Problem with traditional actions**:
```bash
# Ban action
actionban = iptables -I INPUT -s <ip> -j DROP

# Unban action (Fail2Ban must remember and call this)
actionunban = iptables -D INPUT -s <ip> -j DROP
```

**Issues**:
- Fail2Ban must track all bans in memory
- Requires explicit unban action
- Firewall reload removes bans
- No central ban management

### NFTBan Action (Better!)

**NFTBan's solution**:
```bash
# Ban action (with automatic timeout)
actionban = /usr/sbin/nftban ban <ip> --temp --timeout <bantime> --source fail2ban --jail <name>

# NO actionunban needed! nftables timeout handles it automatically
```

**Advantages**:
- ✅ **Automatic expiry**: nftables kernel timer handles timeout
- ✅ **Survives reloads**: Runtime table persists through firewall reloads
- ✅ **Central management**: All bans visible via `nftban list banned`
- ✅ **Metadata tracking**: Knows which jail banned which IP
- ✅ **No memory overhead**: Fail2Ban doesn't track bans

### How Bans Work

When Fail2Ban detects an attack:

1. **Fail2Ban calls NFTBan action**:
   ```bash
   /usr/sbin/nftban ban 192.0.2.100 --temp --timeout 3600 --source fail2ban --jail sshd
   ```

2. **NFTBan adds to runtime table**:
   ```nft
   nft add element inet nftban_runtime temp_ban_v4 { 192.0.2.100 timeout 3600s }
   ```

3. **Kernel blocks traffic**:
   - All packets from 192.0.2.100 are dropped
   - Lookup time: <1 microsecond
   - No performance impact

4. **Automatic expiry** (after 3600 seconds):
   - nftables kernel timer removes IP automatically
   - No unban action needed
   - No Fail2Ban involvement

### Runtime Table Persistence

**The `nftban_runtime` table** (see [Ban System Guide](ban-system.md)):
- Priority -310 (highest)
- Survives `nft flush ruleset`
- Survives firewall reloads
- Bans persist until timeout expires

---

## Quick Setup

### Step 1: Check Fail2Ban Status

```bash
# Check if Fail2Ban is installed and running
sudo nftban fail2ban status
```

**Expected output**:
```
════════════════════════════════════════════════════════════
  Fail2ban Status: RUNNING ✓
════════════════════════════════════════════════════════════

Version: 1.0.2
Active Jails: 3
  - sshd (3 banned IPs)
  - nginx-limit-req (1 banned IP)
  - postfix (0 banned IPs)

Total Banned IPs: 4
Log File: /var/log/nftban/fail2ban.log
```

### Step 2: Install Fail2Ban Action

Create NFTBan action file:

```bash
sudo nftban fail2ban install-action
```

**What this does**:
- Creates `/etc/fail2ban/action.d/nftban.conf`
- Configures Fail2Ban to call NFTBan CLI on ban events
- No restart needed (action is loaded on demand)

**Verify**:
```bash
ls -la /etc/fail2ban/action.d/nftban.conf
```

### Step 3: Enable NFTBan Action for Jails

Edit Fail2Ban jail configuration:

```bash
sudo nano /etc/fail2ban/jail.local
```

**Add NFTBan action to jails**:
```ini
[DEFAULT]
# Use NFTBan as the ban action
banaction = nftban
banaction_allports = nftban

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 5
bantime = 3600
findtime = 600

[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 1800
```

**Restart Fail2Ban**:
```bash
sudo systemctl restart fail2ban
```

### Step 4: Verify Integration

```bash
# Check jail status
sudo nftban fail2ban jails

# View banned IPs
sudo nftban fail2ban banned

# Check nftables temp_ban set
sudo nft list set inet nftban_runtime temp_ban_v4
```

---

## Managing Jails

### List All Jails

**Show currently enabled jails**:
```bash
sudo nftban fail2ban jails
```

**Output**:
```
NFTBan Fail2Ban Integration v0.10.0
═══════════════════════════════════

Currently Enabled Jails: 3

┌─────────────────┬────────┬──────────┬───────────────────┐
│ Jail            │ Status │ Banned   │ Failed            │
├─────────────────┼────────┼──────────┼───────────────────┤
│ sshd            │ ACTIVE │ 3 IPs    │ 127 failures      │
│ nginx-limit-req │ ACTIVE │ 1 IP     │ 45 failures       │
│ postfix         │ ACTIVE │ 0 IPs    │ 12 failures       │
└─────────────────┴────────┴──────────┴───────────────────┘

Total Banned IPs: 4
```

**Show available jails** (not yet enabled):
```bash
sudo nftban fail2ban available
```

**Output**:
```
Available Jails (not yet enabled):
══════════════════════════════════

SSH:
  - sshd-aggressive     (ban after 3 failures)
  - sshd-ddos           (SSH connection floods)

Web:
  - nginx-http-auth     (Basic auth failures)
  - nginx-botsearch     (Bad bot/scanner detection)
  - apache-auth         (Apache authentication)
  - apache-badbots      (Apache bot blocking)
  - apache-noscript     (Script injection attempts)

Mail:
  - postfix-sasl        (SMTP auth failures)
  - dovecot             (IMAP/POP3 auth failures)
  - postfix-rbl         (RBL hits)

FTP:
  - proftpd             (FTP brute force)
  - vsftpd              (vsFTPd protection)

Other:
  - recidive            (Ban repeat offenders longer)
  - mysqld-auth         (MySQL auth failures)

Use 'nftban fail2ban enable <jail>' to enable a jail.
```

### Get Recommendations

NFTBan detects installed services and recommends appropriate jails:

```bash
sudo nftban fail2ban recommended
```

**Output**:
```
Recommended Jails for Your System
══════════════════════════════════

Detected OS: Rocky Linux 9.3
Installed Services: SSH, Nginx, Postfix, Dovecot

HIGHLY RECOMMENDED:
  ✓ sshd              - SSH brute force protection (ESSENTIAL)
  ✓ nginx-limit-req   - Nginx rate limiting (DETECTED: Nginx)
  ✓ postfix           - Mail server protection (DETECTED: Postfix)
  ✓ dovecot           - IMAP/POP3 protection (DETECTED: Dovecot)

RECOMMENDED:
  • recidive          - Ban repeat offenders (30 days)
  • nginx-botsearch   - Bad bot/scanner blocking

OPTIONAL:
  • apache-auth       - If using Apache authentication
  • postfix-rbl       - If using RBL checks

Enable all highly recommended jails:
  sudo nftban fail2ban enable sshd nginx-limit-req postfix dovecot
```

### Enable/Disable Jails

**Enable a jail**:
```bash
sudo nftban fail2ban enable sshd
```

**Enable multiple jails**:
```bash
sudo nftban fail2ban enable sshd nginx-limit-req postfix
```

**Disable a jail**:
```bash
sudo nftban fail2ban disable sshd
```

**Restart a jail** (reload configuration):
```bash
sudo nftban fail2ban reload sshd
```

### Check Specific Jail

**Detailed jail status**:
```bash
sudo nftban fail2ban jail sshd
```

**Output**:
```
Jail: sshd
═══════════

Status: ACTIVE
Filter: sshd
Logpath:
  - /var/log/secure
  - /var/log/auth.log

Configuration:
  Max Retry: 5 failures
  Find Time: 10 minutes
  Ban Time: 1 hour

Current Statistics:
  Total Failed: 127
  Total Banned: 3
  Currently Banned: 3

Banned IPs:
  192.0.2.45    (banned 15 minutes ago, expires in 45 minutes)
  198.51.100.89 (banned 3 minutes ago, expires in 57 minutes)
  203.0.113.12  (banned 52 minutes ago, expires in 8 minutes)

Actions:
  - nftban (NFTBan CLI integration)
```

### Manual Ban/Unban

**Ban an IP manually** in a specific jail:
```bash
sudo nftban fail2ban ban sshd 192.0.2.100
```

**Unban an IP**:
```bash
sudo nftban fail2ban unban sshd 192.0.2.100
```

**Unban from all jails**:
```bash
sudo nftban unban 192.0.2.100
```

---

## Common Jails

### SSH Protection

**sshd** (Essential for all servers):
```ini
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 5        # Ban after 5 failed attempts
bantime = 3600      # Ban for 1 hour
findtime = 600      # 5 failures in 10 minutes
```

**sshd-aggressive** (Stricter, for high-security):
```ini
[sshd-aggressive]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3        # Ban after 3 failures
bantime = 86400     # Ban for 24 hours
findtime = 300      # 3 failures in 5 minutes
```

### Web Server Protection

**nginx-limit-req** (Rate limiting):
```ini
[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 1800      # Ban for 30 minutes
findtime = 60       # 10 failures in 1 minute
```

**nginx-botsearch** (Bad bots/scanners):
```ini
[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 7200      # Ban for 2 hours
findtime = 300
```

**nginx-http-auth** (Basic authentication):
```ini
[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600
findtime = 300
```

### Mail Server Protection

**postfix** (SMTP attacks):
```ini
[postfix]
enabled = true
port = smtp,submission,smtps
logpath = /var/log/mail.log
maxretry = 5
bantime = 3600
findtime = 600
```

**dovecot** (IMAP/POP3):
```ini
[dovecot]
enabled = true
port = imap,imaps,pop3,pop3s
logpath = /var/log/mail.log
maxretry = 5
bantime = 3600
findtime = 600
```

### Advanced Jails

**recidive** (Ban repeat offenders):
```ini
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 2592000   # Ban for 30 days!
findtime = 86400    # Repeat within 24 hours
maxretry = 3        # Banned 3 times = permanent ban
```

**Explanation**: Monitors Fail2Ban's own log. If an IP gets banned by ANY jail 3 times within 24 hours, ban it for 30 days.

---

## Advanced Configuration

### Whitelist IPs

Prevent Fail2Ban from banning trusted IPs:

**Method 1: NFTBan whitelist** (Recommended):
```bash
# Whitelist in NFTBan (highest priority, cannot be banned)
sudo nftban whitelist add 203.0.113.100
sudo nftban whitelist add 198.51.100.0/24
```

**Method 2: Fail2Ban ignoreip**:
```bash
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 203.0.113.100 198.51.100.0/24
```

**Cloudflare Integration**:

If using Cloudflare, whitelist Cloudflare IPs to avoid blocking legitimate traffic:

```bash
sudo nftban fail2ban cloudflare
```

This automatically whitelists all Cloudflare IP ranges.

### Custom Ban Times

**By jail**:
```ini
[sshd]
bantime = 3600      # 1 hour

[nginx-limit-req]
bantime = 1800      # 30 minutes

[postfix]
bantime = 86400     # 24 hours
```

**Progressive ban times**:
```ini
[sshd]
# First ban: 10 minutes
# Second ban: 1 hour
# Third+ ban: 24 hours
bantime.increment = true
bantime.factor = 6
bantime.maxtime = 86400
```

### Custom Find Times

**Find time** = Window to count failures:

```ini
[sshd]
findtime = 600      # 5 failures in 10 minutes

[nginx-botsearch]
findtime = 60       # 5 failures in 1 minute (faster response)

[recidive]
findtime = 86400    # 3 repeat bans in 24 hours
```

### Email Notifications

Get notified when IPs are banned:

```bash
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
destemail = admin@example.com
sendername = Fail2Ban@myserver
mta = sendmail

action = %(action_mwl)s
# action_mwl = mail with log

[sshd]
enabled = true
action = %(action_mwl)s
```

### Integration with NFTBan Reporting

NFTBan can include Fail2Ban statistics in reports:

```bash
# Generate report with Fail2Ban stats
sudo nftban report generate --include fail2ban

# Email report
sudo nftban report email admin@example.com
```

---

## Monitoring & Troubleshooting

### View Banned IPs

**All jails**:
```bash
sudo nftban fail2ban banned
```

**Output**:
```
Banned IPs Across All Jails
════════════════════════════

sshd:
  192.0.2.45    (15m ago, expires in 45m)
  198.51.100.89 (3m ago, expires in 57m)
  203.0.113.12  (52m ago, expires in 8m)

nginx-limit-req:
  192.0.2.200   (5m ago, expires in 25m)

Total Banned: 4 IPs
```

**Specific jail**:
```bash
sudo nftban fail2ban banned sshd
```

**View in nftables**:
```bash
sudo nft list set inet nftban_runtime temp_ban_v4
```

### Check Fail2Ban Logs

**NFTBan Fail2Ban log**:
```bash
tail -f /var/log/nftban/fail2ban.log
```

**Fail2Ban main log**:
```bash
tail -f /var/log/fail2ban.log
```

**Filter for bans only**:
```bash
grep "Ban" /var/log/fail2ban.log
```

### Test Jail Detection

Trigger a ban to test (from another machine):

```bash
# SSH test (5 failed attempts)
for i in {1..6}; do
    ssh testuser@your-server
done

# Check if banned
sudo nftban fail2ban jail sshd
```

### Common Issues

#### Issue: Fail2Ban not banning

**Check 1: Jail is enabled**:
```bash
sudo nftban fail2ban jails
```

**Check 2: Log file exists and is readable**:
```bash
sudo tail /var/log/secure  # Rocky/AlmaLinux
sudo tail /var/log/auth.log  # Ubuntu/Debian
```

**Check 3: Pattern matches**:
```bash
sudo fail2ban-regex /var/log/secure /etc/fail2ban/filter.d/sshd.conf
```

#### Issue: NFTBan action not working

**Check 1: Action file exists**:
```bash
ls -la /etc/fail2ban/action.d/nftban.conf
```

**Check 2: Jail uses nftban action**:
```bash
sudo fail2ban-client get sshd actions
# Should show: nftban
```

**Check 3: NFTBan CLI works**:
```bash
sudo nftban ban 192.0.2.1 --temp --timeout 60
sudo nftban list banned
sudo nftban unban 192.0.2.1
```

#### Issue: Bans not expiring

**This is handled by nftables, not Fail2Ban!**

Check nftables timeout:
```bash
sudo nft -a list set inet nftban_runtime temp_ban_v4
```

Should show: `timeout 3600s` for each IP.

If missing, reinstall NFTBan or check runtime table.

#### Issue: Legitimate IPs getting banned

**Whitelist the IP**:
```bash
sudo nftban whitelist add 203.0.113.100
```

**Or increase maxretry**:
```bash
sudo nano /etc/fail2ban/jail.local
```

```ini
[sshd]
maxretry = 10  # More lenient
```

**Or increase findtime**:
```ini
[sshd]
findtime = 1800  # 30 minutes window instead of 10
```

---

## Best Practices

### Start Conservative

**Begin with essential jails**:
```bash
sudo nftban fail2ban enable sshd
```

**Monitor for 24-48 hours**:
```bash
tail -f /var/log/nftban/fail2ban.log
```

**Expand gradually**:
```bash
sudo nftban fail2ban enable nginx-limit-req postfix
```

### Whitelist First

**Before enabling strict jails, whitelist**:
```bash
# Your office IP
sudo nftban whitelist add 203.0.113.100

# Your home network
sudo nftban whitelist add 198.51.100.0/24

# Monitoring services
sudo nftban whitelist add monitoring.example.com
```

### Use Recommended Jails

```bash
# Let NFTBan suggest based on your system
sudo nftban fail2ban recommended

# Enable all recommended
sudo nftban fail2ban enable sshd nginx-limit-req postfix dovecot
```

### Configure Progressive Bans

**Escalate ban times for repeat offenders**:
```ini
[sshd]
bantime.increment = true
bantime.factor = 6
bantime.maxtime = 2592000  # 30 days max

# First ban: 1 hour
# Second ban: 6 hours
# Third ban: 36 hours
# Fourth+ ban: 30 days
```

### Enable recidive Jail

**Ban persistent attackers**:
```bash
sudo nftban fail2ban enable recidive
```

This jail monitors Fail2Ban's log and bans IPs that get banned repeatedly across different jails.

### Regular Monitoring

**Daily check**:
```bash
sudo nftban fail2ban status
```

**Weekly report**:
```bash
sudo nftban report generate --include fail2ban --email admin@example.com
```

### Test Before Production

**Test jails on development/staging**:
```bash
# Set short ban times for testing
[sshd]
bantime = 60  # 1 minute for testing
```

**Trigger test bans**:
```bash
# From another machine
for i in {1..6}; do ssh wronguser@test-server; done
```

**Verify**:
```bash
sudo nftban fail2ban jail sshd
```

---

## Dynamic Jail Discovery

NFTBan v0.10.0 uses **dynamic jail discovery** - no hardcoded jail lists!

### How It Works

**Traditional approach** (hardcoded):
```bash
# BAD: Hardcoded array
JAILS=("sshd" "nginx" "postfix")
```

**NFTBan approach** (dynamic):
```bash
# GOOD: Discover from filesystem
nftban_fail2ban_discover_available_jails() {
    # Scans /etc/fail2ban/jail.d/*.conf
    # Scans /etc/fail2ban/filter.d/*.conf
    # Returns all available jails
}
```

### Benefits

**Automatic detection**:
- Discovers jails when you install new filters
- No code updates needed
- Supports custom jails automatically

**OS-aware**:
- Detects installed services
- Recommends appropriate jails
- Adapts to your environment

**Example**:
```bash
# Install new Fail2Ban filter
sudo apt install fail2ban-filters-extra

# NFTBan automatically sees new jails
sudo nftban fail2ban available
# Shows newly installed jails!
```

---

## Summary

NFTBan's Fail2Ban integration provides:

- **Automatic banning**: Detects and blocks attackers
- **nftables timeout**: Automatic expiry, no unban action
- **Runtime persistence**: Survives firewall reloads
- **Dynamic discovery**: No hardcoded jail lists
- **OS-aware recommendations**: Suggests jails for your services
- **Central management**: All bans visible via NFTBan CLI

**Key commands**:
```bash
# Status
sudo nftban fail2ban status

# List jails
sudo nftban fail2ban jails

# Enable jail
sudo nftban fail2ban enable sshd

# View banned IPs
sudo nftban fail2ban banned

# Check specific jail
sudo nftban fail2ban jail sshd
```

**Configuration**:
- Action: `/etc/fail2ban/action.d/nftban.conf`
- Jails: `/etc/fail2ban/jail.local`
- NFTBan config: `/etc/nftban/conf.d/fail2ban.conf`
- Logs: `/var/log/nftban/fail2ban.log` and `/var/log/fail2ban.log`

---

## Next Steps

- **[Ban System Guide](ban-system.md)** - Manual banning and whitelist
- **[Threat Feeds](feeds.md)** - Proactive IP blocking
- **[Security Profiles](security-profiles.md)** - Choose security level
- **[Troubleshooting](troubleshoot.md)** - Common issues

---

**Questions?** See the [full documentation](../index.md) or [troubleshooting section](#monitoring--troubleshooting).
