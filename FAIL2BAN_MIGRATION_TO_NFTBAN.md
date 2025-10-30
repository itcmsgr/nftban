# Fail2ban Migration: f2b-table → NFTBan Integration
**Date:** 2025-10-30
**Priority:** HIGH - Unify ban management
**Status:** READY FOR DEPLOYMENT

═══════════════════════════════════════════════════════════════════

## 🎯 Goal

Migrate fail2ban from using separate `f2b-table` to NFTBan's unified `temp_ban_v4/v6` sets in `nftban_runtime` table.

**Benefits:**
- ✅ Single unified ban system (no redundancy)
- ✅ Consistent timeout handling across all bans
- ✅ Better integration with NFTBan statistics
- ✅ Cleaner nftables architecture
- ✅ Easier troubleshooting

---

## 📊 Current State

### Before Migration

```
┌─────────────────────────────────────┐
│ inet f2b-table (fail2ban)           │
│ ─────────────────────────────       │
│ • Created by nftables-multiport     │
│ • Separate table for each jail      │
│ • Uses reject/drop actions          │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ inet nftban_runtime (NFTBan)        │
│ ─────────────────────────────       │
│ • temp_ban_v4/v6 sets               │
│ • NOT used by fail2ban yet          │
│ • Ready but unused                  │
└─────────────────────────────────────┘
```

### After Migration

```
┌─────────────────────────────────────┐
│ inet nftban_runtime (UNIFIED)       │
│ ─────────────────────────────       │
│ • temp_ban_v4/v6 sets               │
│ • Used by fail2ban ✅               │
│ • All bans in one place             │
│ • Automatic timeout expiry          │
└─────────────────────────────────────┘

❌ f2b-table - REMOVED (no longer needed)
```

---

## 🔧 Migration Steps

### Step 1: Update Global fail2ban Configuration

**File:** `/etc/fail2ban/jail.local`

**Change:**
```ini
[DEFAULT]
# OLD: Uses separate f2b-table
#banaction = nftables-multiport

# NEW: Uses NFTBan unified banning
banaction = nftban

# Keep all other settings
bantime = 48h
findtime = 10m
maxretry = 5
```

### Step 2: Verify NFTBan Action Exists

**Check:**
```bash
ls -la /etc/fail2ban/action.d/nftban.conf
```

**Expected:** File exists with NFTBan ban action

**If missing, deploy from:**
```bash
cp /home/gituser/nftban-v0.10.0-dev/src/etc/fail2ban/action.d/nftban.conf \
   /etc/fail2ban/action.d/nftban.conf
```

### Step 3: Restart fail2ban

```bash
# Restart to apply new banaction
systemctl restart fail2ban

# Verify no errors
systemctl status fail2ban
```

### Step 4: Verify Migration

```bash
# 1. Check fail2ban is using nftban action
fail2ban-client get sshd actions
# Expected: Should show "nftban" not "nftables-multiport"

# 2. Check old f2b-table is gone or empty
nft list tables
# f2b-table should either be gone or have no active bans

# 3. Check temp_ban sets are being used
nft list set inet nftban_runtime temp_ban_v4
nft list set inet nftban_runtime temp_ban_v6
# Should show IPs if any bans are active

# 4. Test a ban
fail2ban-client set sshd banip 1.2.3.4
nft list set inet nftban_runtime temp_ban_v4 | grep 1.2.3.4
# Should see the IP in the set

# 5. Test unban (optional - timeout does it automatically)
fail2ban-client set sshd unbanip 1.2.3.4
```

### Step 5: Remove Old f2b-table (Optional)

**After confirming migration works:**

```bash
# Remove the old table entirely
nft delete table inet f2b-table

# This is safe - all bans are now in nftban_runtime
```

---

## 📁 DirectAdmin Jail Examples

Based on the production config from srv1.example.test, here are optimized jail configurations:

### Complete jail.local for DirectAdmin Servers

**File:** `/etc/fail2ban/jail.local`

```ini
# ═══════════════════════════════════════════════════════════════════
# NFTBan + Fail2ban Integration - DirectAdmin Server
# ═══════════════════════════════════════════════════════════════════

[DEFAULT]
# Ignore local and private networks
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

# Read additional ignore IPs from file
ignoreip.conf = /etc/fail2ban/ignoreip.conf

# CRITICAL: Use NFTBan unified banning (not nftables-multiport)
banaction = nftban

# Default ban settings
bantime = 48h          # 2 days default ban
findtime = 10m         # 10 minute window for counting retries
maxretry = 5           # 5 attempts before ban

# Email configuration
sender = Fail2Ban@%(hostname)s
destemail = support@rotame.com

# Combined action: ban + email notification
action_mwl = %(banaction)s[name=%(__name__)s, port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
             sendmail-whois[name=%(__name__)s, dest="%(destemail)s", sender="%(sender)s"]
             itcms-custom-log

# Default action for all jails
action = %(action_mwl)s

# ═══════════════════════════════════════════════════════════════════
# SSH Protection
# ═══════════════════════════════════════════════════════════════════

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure      # RHEL/CentOS
#logpath = /var/log/auth.log   # Debian/Ubuntu
bantime = 2d                    # 2 days for SSH attacks
maxretry = 5
findtime = 10m

# ═══════════════════════════════════════════════════════════════════
# DirectAdmin Control Panel Protection
# ═══════════════════════════════════════════════════════════════════

[directadmin]
enabled = true
port = 2222                     # DirectAdmin default port
filter = directadmin
logpath = /var/log/directadmin/login.log
bantime = 1h                    # 1 hour for DA login attempts
maxretry = 5
findtime = 10m

# ═══════════════════════════════════════════════════════════════════
# Mail Server Protection (Exim + Dovecot)
# ═══════════════════════════════════════════════════════════════════

[exim]
enabled = true
port = smtp,ssmtp,submission,smtps
filter = exim
logpath = /var/log/exim/mainlog
bantime = 1d
maxretry = 15
findtime = 10m

[exim-spam]
enabled = true
port = smtp,ssmtp,submission,smtps
filter = exim-spam
logpath = /var/log/exim/mainlog
bantime = 2d
maxretry = 15
findtime = 10m

[dovecot]
enabled = true
port = pop3,pop3s,imap,imaps
filter = dovecot
logpath = /var/log/maillog
bantime = 1h
maxretry = 9
findtime = 10m

# ═══════════════════════════════════════════════════════════════════
# FTP Protection (Pure-FTPd)
# ═══════════════════════════════════════════════════════════════════

[pure-ftpd]
enabled = true
port = ftp,ftp-data,ftps,ftps-data
filter = pure-ftpd
logpath = /var/log/messages
bantime = 2h
maxretry = 9
findtime = 20m

# ═══════════════════════════════════════════════════════════════════
# Web Application Protection
# ═══════════════════════════════════════════════════════════════════

[roundcube-auth]
enabled = true
port = http,https
filter = roundcube-auth
logpath = /var/www/html/roundcube/logs/errors.log
bantime = 1h
maxretry = 9
findtime = 10m

# ═══════════════════════════════════════════════════════════════════
# WordPress Protection
# ═══════════════════════════════════════════════════════════════════

[wp-login]
enabled = true
port = http,https
filter = apache-wp-login
logpath = /var/log/httpd/domains/*.log
bantime = 2h
maxretry = 10
findtime = 20m

[xmlrpc]
enabled = true
port = http,https
filter = apache-xmlrpc
logpath = /var/log/httpd/domains/*.log
bantime = 2h
maxretry = 9
findtime = 20m

# ═══════════════════════════════════════════════════════════════════
# Web Scanning / Reconnaissance Attacks
# ═══════════════════════════════════════════════════════════════════

[apache-scan]
enabled = true
port = http,https
filter = apache-scan
logpath = /var/log/httpd/domains/*.log
bantime = 1h
maxretry = 10
findtime = 1m                   # Very short window - rapid scanning

# ═══════════════════════════════════════════════════════════════════
# ModSecurity (Web Application Firewall)
# ═══════════════════════════════════════════════════════════════════

[modsecurity]
enabled = true
port = http,https
filter = modsecurity
logpath = /var/log/httpd/modsec_audit.log
bantime = 1h
maxretry = 9
findtime = 10m

# ═══════════════════════════════════════════════════════════════════
# Persistent Offenders (Repeat Ban Detection)
# ═══════════════════════════════════════════════════════════════════

[persistent-offenders]
enabled = true
filter = persistent-offenders
logpath = /var/log/itcms-fail2ban.log
bantime = 7d                    # 1 week for repeat offenders
maxretry = 3                    # 3 bans in 24h = permanent ban
findtime = 24h
```

---

## 📝 Custom Filters

### Filter Files to Deploy

All these filters should be placed in `/etc/fail2ban/filter.d/`:

#### 1. apache-wp-login.conf
```ini
[Definition]
# WordPress wp-login.php brute force detection
failregex = ^<HOST> -.*"POST //?wp-login\.php.*
ignoreregex =
```

#### 2. apache-xmlrpc.conf
```ini
[Definition]
# WordPress xmlrpc.php attack detection
failregex = ^<HOST> -.*"POST //?xmlrpc\.php.*
ignoreregex =
```

#### 3. apache-scan.conf
```ini
[Definition]
# Web reconnaissance and file enumeration attacks
# Matches multiple 403/404 responses

# Exclude legitimate automated tasks
ignoreregex = "POST /wp-cron\.php.*"

# Match 404/403 responses from GET/POST
failregex = ^<HOST> .*"(?:GET|POST).*".*"(?:404|403)".*
```

#### 4. modsecurity.conf
```ini
[Definition]
# ModSecurity v3 JSON logs - blocked requests
failregex = ^\s*\{\s*"transaction":\s*\{\s*"client_ip":"<HOST>",.*?"http_code":(?:403|406),.*
            ^.*"client_ip":"<HOST>",.*?"uri":"//xmlrpc\.php".*

# ModSecurity timestamp format
datepattern = %%a %%b  %%d %%H:%%M:%%S %%Y

ignoreregex =
```

#### 5. persistent-offenders.conf
```ini
[Definition]
# Detects IPs that have been banned multiple times
# Monitors fail2ban's own log for repeat offenders
failregex = Banned IP:\s+<HOST>
ignoreregex =
```

#### 6. dovecot-custom.conf
```ini
[Definition]
# Dovecot IMAP/POP3 authentication failures
failregex = ^.*dovecot\[\d+\]: (?:imap|pop3)-login: Login aborted: .*rip=<HOST>
ignoreregex =
journalmatch = _SYSTEMD_UNIT=dovecot.service
datepattern = {^LN-BEG}
```

---

## 🚀 Deployment Script

Create `/root/migrate_fail2ban_to_nftban.sh`:

```bash
#!/bin/bash
# Migrate fail2ban to NFTBan integration
set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Fail2ban → NFTBan Migration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Backup current config
echo "[1/6] Backing up current fail2ban config..."
cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup-$(date +%Y%m%d-%H%M%S)
echo "✓ Backup created"
echo ""

# 2. Check NFTBan action exists
echo "[2/6] Checking NFTBan action..."
if [[ ! -f /etc/fail2ban/action.d/nftban.conf ]]; then
    echo "❌ NFTBan action not found!"
    echo "Please deploy nftban.conf to /etc/fail2ban/action.d/"
    exit 1
fi
echo "✓ NFTBan action exists"
echo ""

# 3. Update jail.local to use nftban action
echo "[3/6] Updating jail.local..."
sed -i 's/^banaction = nftables-multiport/banaction = nftban/' /etc/fail2ban/jail.local
echo "✓ Updated banaction to nftban"
echo ""

# 4. Restart fail2ban
echo "[4/6] Restarting fail2ban..."
systemctl restart fail2ban
sleep 2
echo "✓ Fail2ban restarted"
echo ""

# 5. Verify migration
echo "[5/6] Verifying migration..."
ACTIONS=$(fail2ban-client get sshd actions)
if echo "$ACTIONS" | grep -q "nftban"; then
    echo "✓ SSH jail using nftban action"
else
    echo "⚠️  Warning: SSH jail not using nftban action"
    echo "   Current action: $ACTIONS"
fi
echo ""

# 6. Check temp_ban sets
echo "[6/6] Checking NFTBan temp_ban sets..."
if nft list set inet nftban_runtime temp_ban_v4 &>/dev/null; then
    echo "✓ temp_ban_v4 set exists"
else
    echo "⚠️  Warning: temp_ban_v4 set not found"
fi

if nft list set inet nftban_runtime temp_ban_v6 &>/dev/null; then
    echo "✓ temp_ban_v6 set exists"
else
    echo "⚠️  Warning: temp_ban_v6 set not found"
fi
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Migration Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Test a ban: fail2ban-client set sshd banip 1.2.3.4"
echo "  2. Verify: nft list set inet nftban_runtime temp_ban_v4"
echo "  3. Monitor: tail -f /var/log/fail2ban.log"
echo ""
echo "To remove old f2b-table:"
echo "  nft delete table inet f2b-table"
echo ""
```

Make it executable:
```bash
chmod +x /root/migrate_fail2ban_to_nftban.sh
```

---

## 🧪 Testing Procedure

### Test 1: Manual Ban Test

```bash
# Ban a test IP
fail2ban-client set sshd banip 1.2.3.4

# Check it's in NFTBan sets (not f2b-table)
nft list set inet nftban_runtime temp_ban_v4 | grep 1.2.3.4

# Check timeout is set
nft -a list set inet nftban_runtime temp_ban_v4

# Unban
fail2ban-client set sshd unbanip 1.2.3.4

# Verify removed
nft list set inet nftban_runtime temp_ban_v4 | grep 1.2.3.4 || echo "IP removed ✓"
```

### Test 2: Real Attack Simulation

```bash
# Try to trigger SSH jail
for i in {1..6}; do
    ssh invalid@localhost  # Will fail
done

# Check if banned
nft list set inet nftban_runtime temp_ban_v4

# Check fail2ban log
tail -20 /var/log/fail2ban.log
```

### Test 3: Verify All Jails

```bash
# List all enabled jails
fail2ban-client status

# Check each jail is using nftban action
for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr ',' ' '); do
    echo "=== $jail ==="
    fail2ban-client get $jail actions
done
```

---

## 📊 Monitoring

### Check Current Bans

```bash
# NFTBan way (unified)
nftban stats

# Or directly
nft list set inet nftban_runtime temp_ban_v4
nft list set inet nftban_runtime temp_ban_v6

# fail2ban way
fail2ban-client status sshd
```

### Check Ban Activity

```bash
# Real-time monitoring
tail -f /var/log/fail2ban.log

# NFTBan custom log
tail -f /var/log/itcms-fail2ban.log

# See who's getting banned
grep "Ban" /var/log/fail2ban.log | tail -20
```

---

## 🔍 Troubleshooting

### Problem: Jails Not Banning

**Check:**
```bash
# 1. Is fail2ban running?
systemctl status fail2ban

# 2. Are jails enabled?
fail2ban-client status

# 3. Check for errors
journalctl -u fail2ban -n 50

# 4. Test filter manually
fail2ban-regex /var/log/secure /etc/fail2ban/filter.d/sshd.conf
```

### Problem: Bans Not Showing in NFTBan

**Check:**
```bash
# 1. Verify banaction
grep "^banaction" /etc/fail2ban/jail.local

# 2. Should be: banaction = nftban
# If not, update and restart

# 3. Check nftban action is called
tail -f /var/log/fail2ban.log | grep nftban
```

### Problem: Old f2b-table Still Active

**Check:**
```bash
# List all tables
nft list tables

# If f2b-table exists, check if it has active bans
nft list table inet f2b-table

# If empty, safe to delete
nft delete table inet f2b-table
```

---

## ✅ Migration Checklist

- [ ] Backup current `/etc/fail2ban/jail.local`
- [ ] Verify `/etc/fail2ban/action.d/nftban.conf` exists
- [ ] Update `banaction = nftban` in jail.local
- [ ] Deploy custom filters to `/etc/fail2ban/filter.d/`
- [ ] Restart fail2ban: `systemctl restart fail2ban`
- [ ] Verify jails using nftban action
- [ ] Test manual ban/unban
- [ ] Monitor for 24 hours
- [ ] Remove old f2b-table if working
- [ ] Update documentation

---

## 📁 Files Summary

### To Deploy:

| File | Location | Purpose |
|------|----------|---------|
| `nftban.conf` | `/etc/fail2ban/action.d/` | NFTBan ban action |
| `jail.local` | `/etc/fail2ban/` | Main jail config |
| `*.conf` filters | `/etc/fail2ban/filter.d/` | Custom filters |
| `migrate_fail2ban_to_nftban.sh` | `/root/` | Migration script |

### To Backup:

- `/etc/fail2ban/jail.local` → `/etc/fail2ban/jail.local.backup-YYYYMMDD`
- `/etc/fail2ban/action.d/` → `/root/fail2ban-backup-YYYYMMDD/`

---

**Created:** 2025-10-30
**Status:** ✅ READY FOR DEPLOYMENT
**Tested:** Ready for lab testing

═══════════════════════════════════════════════════════════════════
