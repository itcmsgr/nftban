# Health Diagnostics Guide

**System health checks and auto-fix capabilities**

NFTBan includes a comprehensive health diagnostic system that verifies your installation, detects issues, and can automatically fix many common problems.

---

## Table of Contents

- [Overview](#overview)
- [Running Health Checks](#running-health-checks)
- [Health Check Categories](#health-check-categories)
- [Understanding Results](#understanding-results)
- [Auto-Fix Capabilities](#auto-fix-capabilities)
- [Common Issues & Solutions](#common-issues--solutions)
- [Monitoring & Alerts](#monitoring--alerts)
- [Best Practices](#best-practices)

---

## Overview

### What is Health Diagnostics?

The health system performs comprehensive checks across 6 major categories:

1. **Binary Dependencies** - Required commands (nft, systemctl, etc.)
2. **FHS Path Structure** - Directory existence and permissions
3. **File Permissions** - Ownership and access rights
4. **Service Status** - nftables, Fail2Ban, systemd units
5. **Module Availability** - All 17 core modules present
6. **GeoIP Database** - MaxMind database status

### Why Use Health Checks?

✅ **Verify Installation** - Confirm everything installed correctly
✅ **Detect Issues Early** - Find problems before they cause failures
✅ **Auto-Fix** - Many issues can be fixed automatically
✅ **Troubleshooting** - Identify root causes quickly
✅ **Monitoring** - Run periodically to ensure system health

### Replaces Smoketest

In v0.9.x, NFTBan had a "smoketest" script. In v0.10.0, this is replaced by the comprehensive health diagnostic system with:
- More categories (6 vs 3)
- Auto-fix capabilities
- Detailed reporting
- JSON output support

---

## Running Health Checks

### Basic Health Check

Quick check of all categories:

```bash
sudo nftban health check
```

**Expected output (healthy system):**
```
NFTBan Health Check
═══════════════════

Running diagnostics...

✓ Binary Dependencies     PASS
✓ FHS Path Structure      PASS
✓ File Permissions        PASS
✓ Service Status          PASS
✓ Module Availability     PASS
✓ GeoIP Database          PASS

Overall Health: HEALTHY ✓

All checks passed!
```

### Health Check with Auto-Fix

Automatically fix detected issues:

```bash
sudo nftban health check --fix
```

**Output (with fixes applied):**
```
NFTBan Health Check (Auto-Fix Enabled)
══════════════════════════════════════

Running diagnostics...

✓ Binary Dependencies     PASS
⚠ FHS Path Structure      WARNING
  Issue: Missing directory /var/lib/nftban/feeds
  Fix: Creating directory... DONE ✓

✓ File Permissions        PASS
✓ Service Status          PASS
⚠ Module Availability     WARNING
  Issue: Missing module nftban_geoip_go.sh
  Fix: Module exists but not loaded, reloading... DONE ✓

✓ GeoIP Database          PASS

Overall Health: HEALTHY ✓ (2 issues auto-fixed)
```

### Verbose Output

See detailed information for each check:

```bash
sudo nftban health check --verbose
```

**Output:**
```
NFTBan Health Check (Verbose Mode)
═══════════════════════════════════

[1/6] Binary Dependencies
  ✓ nft                  /usr/sbin/nft
  ✓ systemctl            /usr/bin/systemctl
  ✓ journalctl           /usr/bin/journalctl
  ✓ awk                  /usr/bin/awk
  ✓ sed                  /usr/bin/sed
  ✓ grep                 /usr/bin/grep
  ✓ jq                   /usr/bin/jq
  ✓ curl                 /usr/bin/curl
  ✓ wget                 /usr/bin/wget
  ⚠ mail                 NOT FOUND (optional)
  ⚠ sendmail             NOT FOUND (optional)
  Status: PASS (2 optional binaries missing)

[2/6] FHS Path Structure
  ✓ /usr/lib/nftban              EXISTS (755)
  ✓ /usr/lib/nftban/core         EXISTS (755)
  ✓ /usr/lib/nftban/cli          EXISTS (755)
  ✓ /etc/nftban                  EXISTS (755)
  ✓ /etc/nftban/conf.d           EXISTS (755)
  ✓ /var/lib/nftban              EXISTS (755)
  ✓ /var/lib/nftban/feeds        EXISTS (755)
  ✓ /var/log/nftban              EXISTS (755)
  Status: PASS

[3/6] File Permissions
  ✓ User 'nftban' exists         UID: 995
  ✓ Group 'nftban' exists        GID: 993
  ✓ /usr/sbin/nftban             755 root:root
  ✓ /etc/nftban                  755 root:root
  ✓ /var/lib/nftban              755 nftban:nftban
  ✓ /var/log/nftban              755 nftban:nftban
  Status: PASS

[4/6] Service Status
  ✓ nftables                     ACTIVE (loaded)
  ✓ fail2ban                     ACTIVE (running)
  ✓ nftban-rollback.timer        INACTIVE (expected)
  Status: PASS

[5/6] Module Availability
  ✓ nftban_output.sh             17 KB
  ✓ nftban_cloudflare.sh         20 KB
  ✓ nftban_ddos.sh               38 KB
  ✓ nftban_fail2ban.sh           16 KB
  ✓ nftban_feeds.sh              13 KB
  ✓ nftban_file_ops.sh           4 KB
  ✓ nftban_geoip_go.sh           8 KB
  ✓ nftban_health.sh             21 KB
  ✓ nftban_login_alert.sh        15 KB
  ✓ nftban_mail.sh               20 KB
  ✓ nftban_nftables.sh           6 KB
  ✓ nftban_portscan.sh           22 KB
  ✓ nftban_report_fhs.sh         19 KB
  ✓ nftban_report_module.sh      15 KB
  ✓ nftban_report_port.sh        23 KB
  ✓ nftban_security.sh           3 KB
  ✓ nftban_system_ip.sh          15 KB
  Status: PASS (17/17 modules found)

[6/6] GeoIP Database
  ✓ nftban-geoip binary          /usr/share/nftban/go-binaries/nftban-geoip
  ✓ GeoLite2 database            /var/lib/nftban/geoip/GeoLite2-Country.mmdb
  ✓ Database age                 12 days (updated 2025-10-16)
  Status: PASS

Overall Health: HEALTHY ✓
```

### Specific Category Check

Check only one category:

```bash
# Check only binaries
sudo nftban health check --category binaries

# Check only services
sudo nftban health check --category services

# Check only modules
sudo nftban health check --category modules
```

### JSON Output

Get machine-readable output for monitoring:

```bash
sudo nftban health check --format json
```

**Output:**
```json
{
  "timestamp": "2025-10-28T14:30:15Z",
  "overall_status": "healthy",
  "checks": {
    "binaries": {
      "status": "pass",
      "required_missing": [],
      "optional_missing": ["mail", "sendmail"]
    },
    "paths": {
      "status": "pass",
      "missing": []
    },
    "permissions": {
      "status": "pass",
      "issues": []
    },
    "services": {
      "status": "pass",
      "nftables": "active",
      "fail2ban": "active"
    },
    "modules": {
      "status": "pass",
      "found": 17,
      "expected": 17,
      "missing": []
    },
    "geoip": {
      "status": "pass",
      "database_exists": true,
      "database_age_days": 12
    }
  },
  "warnings": 2,
  "errors": 0,
  "fixes_applied": 0
}
```

---

## Health Check Categories

### 1. Binary Dependencies

**What it checks:**
- Required command-line tools (nft, systemctl, awk, sed, grep, jq, curl, wget)
- Optional tools (go, git, mail, sendmail)

**Why it matters:**
- NFTBan requires certain binaries to function
- Missing binaries cause failures

**Common issues:**
- `jq` not installed (needed for JSON parsing)
- `nft` not found (nftables not installed)
- `mail`/`sendmail` missing (email alerts won't work)

**Auto-fix:** Cannot install binaries (requires manual package manager)

**Manual fix:**
```bash
# Rocky Linux / AlmaLinux / Fedora
sudo dnf install nftables jq curl wget mailx

# Ubuntu / Debian
sudo apt install nftables jq curl wget mailutils

# openSUSE
sudo zypper install nftables jq curl wget mailx
```

---

### 2. FHS Path Structure

**What it checks:**
- Critical directories exist:
  - `/usr/lib/nftban` (libraries)
  - `/usr/lib/nftban/core` (core modules)
  - `/usr/lib/nftban/cli` (CLI commands)
  - `/etc/nftban` (configuration)
  - `/etc/nftban/conf.d` (module configs)
  - `/var/lib/nftban` (state data)
  - `/var/lib/nftban/feeds` (feed cache)
  - `/var/log/nftban` (logs)

**Why it matters:**
- NFTBan follows FHS (Filesystem Hierarchy Standard)
- Missing directories cause module load failures

**Common issues:**
- `/var/lib/nftban/feeds` missing (first feed update fails)
- `/var/log/nftban` missing (logging fails)

**Auto-fix:** ✅ YES - Creates missing directories with correct permissions

**Example fix:**
```bash
sudo nftban health check --fix
# Creates /var/lib/nftban/feeds with 755 nftban:nftban
```

---

### 3. File Permissions

**What it checks:**
- `nftban` user exists (UID 995)
- `nftban` group exists (GID 993)
- Correct ownership on:
  - `/usr/sbin/nftban` (root:root, 755)
  - `/etc/nftban` (root:root, 755)
  - `/var/lib/nftban` (nftban:nftban, 755)
  - `/var/log/nftban` (nftban:nftban, 755)

**Why it matters:**
- Incorrect permissions cause access denied errors
- Security: sensitive files should not be world-writable

**Common issues:**
- `nftban` user doesn't exist (upgrade from old version)
- `/var/lib/nftban` owned by root (state files can't be written)

**Auto-fix:** ✅ YES - Creates user/group, fixes ownership

**Example fix:**
```bash
sudo nftban health check --fix
# Creates nftban user/group if missing
# Fixes ownership: chown -R nftban:nftban /var/lib/nftban
```

---

### 4. Service Status

**What it checks:**
- nftables service status (should be active/loaded)
- Fail2Ban service status (should be active/running)
- nftban-rollback.timer status (inactive is OK, active means pending rollback)

**Why it matters:**
- nftables must be active for firewall to work
- Fail2Ban must be running for automatic banning

**Common issues:**
- nftables service stopped (firewall not active!)
- Fail2Ban service dead (auto-banning broken)
- nftban-rollback.timer active (pending rollback, need to confirm!)

**Auto-fix:** ✅ YES (limited) - Restarts failed services

**Manual fix:**
```bash
# Restart nftables
sudo systemctl restart nftables

# Restart Fail2Ban
sudo systemctl restart fail2ban

# If rollback timer is active, confirm or rollback
sudo nftban-confirm  # or nftban-rollback
```

---

### 5. Module Availability

**What it checks:**
- All 17 core modules exist:
  1. nftban_output.sh
  2. nftban_cloudflare.sh
  3. nftban_ddos.sh
  4. nftban_fail2ban.sh
  5. nftban_feeds.sh
  6. nftban_file_ops.sh
  7. nftban_geoip_go.sh
  8. nftban_health.sh
  9. nftban_login_alert.sh
  10. nftban_mail.sh
  11. nftban_nftables.sh
  12. nftban_portscan.sh
  13. nftban_report_fhs.sh
  14. nftban_report_module.sh
  15. nftban_report_port.sh
  16. nftban_security.sh
  17. nftban_system_ip.sh

**Why it matters:**
- Missing modules cause command failures
- "Command not found" errors when using CLI

**Common issues:**
- Incomplete installation
- Corrupted files

**Auto-fix:** ❌ NO - Requires reinstallation

**Manual fix:**
```bash
# Reinstall NFTBan
sudo ./install.sh --reinstall
```

---

### 6. GeoIP Database

**What it checks:**
- `nftban-geoip` Go binary exists
- GeoLite2-Country.mmdb database exists
- Database age (warns if >30 days old)

**Why it matters:**
- GeoIP lookups fail without database
- Old database has inaccurate data

**Common issues:**
- Database not downloaded yet
- Database expired (>30 days)

**Auto-fix:** ✅ YES - Downloads database if missing

**Manual fix:**
```bash
# Download GeoLite2 database
sudo nftban geoip update
```

---

## Understanding Results

### Status Levels

```
✓ PASS      - Everything OK
⚠ WARNING   - Minor issue, system functional
✗ ERROR     - Significant issue, degraded functionality
❌ CRITICAL  - Severe issue, system non-functional
```

### Overall Health

**HEALTHY ✓** - All checks passed (warnings OK)
- All critical functionality working
- Minor issues may exist (optional features)

**DEGRADED ⚠** - Some warnings/errors
- Core functionality working
- Some features unavailable
- Action recommended

**UNHEALTHY ✗** - Multiple errors
- Significant functionality broken
- Immediate action required

**CRITICAL ❌** - Critical failures
- System non-functional
- Reinstallation may be needed

---

## Auto-Fix Capabilities

### What Can Be Fixed Automatically?

✅ **Can Auto-Fix:**
1. Missing directories (creates with correct permissions)
2. Incorrect ownership (chown to nftban:nftban)
3. Missing nftban user/group (creates)
4. Stopped services (restarts)
5. Missing GeoIP database (downloads)

❌ **Cannot Auto-Fix:**
1. Missing binaries (requires package manager)
2. Missing modules (requires reinstallation)
3. Disk space issues
4. Network connectivity issues
5. Corrupt configuration files

### How to Use Auto-Fix

**Basic auto-fix:**
```bash
sudo nftban health check --fix
```

**Verbose auto-fix (see what's being fixed):**
```bash
sudo nftban health check --fix --verbose
```

**Dry-run (see what would be fixed):**
```bash
sudo nftban health check --fix --dry-run
```

---

## Common Issues & Solutions

### Issue 1: "nftban: command not found"

**Symptom:**
```bash
$ nftban health check
bash: nftban: command not found
```

**Cause:** NFTBan not installed or not in PATH

**Solution:**
```bash
# Check if installed
ls -la /usr/sbin/nftban

# If exists, add to PATH
sudo ln -sf /usr/sbin/nftban /usr/local/bin/nftban

# If doesn't exist, install
sudo ./install.sh
```

---

### Issue 2: Missing Dependencies

**Symptom:**
```
✗ Binary Dependencies     ERROR
  Missing required: jq, curl
```

**Solution:**
```bash
# Rocky Linux / AlmaLinux / Fedora
sudo dnf install jq curl

# Ubuntu / Debian
sudo apt install jq curl

# Then re-check
sudo nftban health check
```

---

### Issue 3: Permission Denied

**Symptom:**
```
✗ File Permissions        ERROR
  /var/lib/nftban owned by root (should be nftban)
```

**Solution (auto-fix):**
```bash
sudo nftban health check --fix
```

**Solution (manual):**
```bash
sudo chown -R nftban:nftban /var/lib/nftban
sudo chown -R nftban:nftban /var/log/nftban
```

---

### Issue 4: Service Not Running

**Symptom:**
```
✗ Service Status          ERROR
  nftables: inactive (dead)
```

**Solution:**
```bash
# Check service status
sudo systemctl status nftables

# Start service
sudo systemctl start nftables

# Enable on boot
sudo systemctl enable nftables

# Verify
sudo nftban health check
```

---

### Issue 5: Missing Modules

**Symptom:**
```
✗ Module Availability     ERROR
  Missing: nftban_geoip_go.sh (1/17 modules)
```

**Solution:**
```bash
# Reinstall NFTBan
sudo ./install.sh --reinstall

# Verify
sudo nftban health check --category modules
```

---

### Issue 6: Old GeoIP Database

**Symptom:**
```
⚠ GeoIP Database          WARNING
  Database age: 45 days (recommended: <30 days)
```

**Solution (auto-fix):**
```bash
sudo nftban health check --fix
```

**Solution (manual):**
```bash
sudo nftban geoip update
```

---

## Monitoring & Alerts

### Scheduled Health Checks

Run health checks periodically via cron:

```bash
# Edit crontab
sudo crontab -e

# Add daily health check at 3am
0 3 * * * /usr/sbin/nftban health check --format json >> /var/log/nftban/health-daily.log 2>&1

# Add hourly quick check
0 * * * * /usr/sbin/nftban health check --quiet || echo "NFTBan health check FAILED!" | mail -s "NFTBan Alert" admin@example.com
```

### Monitoring Integration

**Prometheus/Grafana:**
```bash
# Export health metrics
sudo nftban health check --format json > /var/lib/node_exporter/textfile_collector/nftban_health.prom
```

**Nagios/Icinga:**
```bash
# Health check returns exit code:
# 0 = OK
# 1 = WARNING
# 2 = CRITICAL
sudo nftban health check --quiet
echo $?  # 0 = healthy
```

**Email Alerts:**
```bash
# Check and email if unhealthy
sudo nftban health check || \
  sudo nftban health check --verbose | \
  mail -s "NFTBan Health Alert: $(hostname)" admin@example.com
```

---

## Best Practices

### 1. Run After Installation

**Always verify installation:**
```bash
sudo nftban health check --verbose
```

### 2. Run After Updates

**After updating NFTBan:**
```bash
sudo nftban health check --fix
```

### 3. Run Before Major Changes

**Before applying new profile:**
```bash
# Check health first
sudo nftban health check

# Apply profile
sudo nftban profile set maximum

# Check again
sudo nftban health check
```

### 4. Include in Troubleshooting

**When something breaks:**
```bash
# Step 1: Health check
sudo nftban health check --verbose

# Step 2: Auto-fix
sudo nftban health check --fix

# Step 3: Check logs
sudo tail -100 /var/log/nftban/operations.log
```

### 5. Monitor Regularly

**Set up monitoring:**
```bash
# Daily health checks
0 3 * * * /usr/sbin/nftban health check --fix >> /var/log/nftban/health-daily.log 2>&1
```

### 6. Keep GeoIP Updated

**Monthly GeoIP updates:**
```bash
# First day of month at 2am
0 2 1 * * /usr/sbin/nftban geoip update >> /var/log/nftban/geoip-update.log 2>&1
```

---

## Summary

### Quick Reference

```bash
# Basic health check
sudo nftban health check

# With auto-fix
sudo nftban health check --fix

# Verbose output
sudo nftban health check --verbose

# Specific category
sudo nftban health check --category services

# JSON output (monitoring)
sudo nftban health check --format json

# Quiet mode (exit code only)
sudo nftban health check --quiet
```

### Health Check Categories

1. **✓ Binary Dependencies** - Required commands
2. **✓ FHS Path Structure** - Directory existence
3. **✓ File Permissions** - Ownership and access
4. **✓ Service Status** - nftables, Fail2Ban
5. **✓ Module Availability** - 17 core modules
6. **✓ GeoIP Database** - Country lookup data

### Auto-Fix Capabilities

- ✅ Missing directories
- ✅ Incorrect ownership
- ✅ Missing user/group
- ✅ Stopped services
- ✅ Missing GeoIP database
- ❌ Missing binaries (manual)
- ❌ Missing modules (reinstall needed)

---

**Next**: [Installation Guide →](install.md)

**See also**:
- [Quick Start](quickstart.md) - 5-minute setup
- [Troubleshooting](troubleshoot.md) - Common issues
- [Architecture](../concepts/architecture.md) - How NFTBan works
