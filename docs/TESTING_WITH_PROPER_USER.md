# NFTBan Testing with Proper User Account

**Version:** 1.0.0
**Purpose:** Secure Testing Protocol
**Author:** Antonios Voulvoulis <contact@nftban.com>
**Website:** https://nftban.com
**Status:** ✅ Recommended Practice

---

## Table of Contents

1. [Why Not Test as Root](#why-not-test-as-root)
2. [Proper Test User Setup](#proper-test-user-setup)
3. [Group Permissions](#group-permissions)
4. [Testing CLI Commands](#testing-cli-commands)
5. [Testing GeoIP](#testing-geoip)
6. [Testing Health Checks](#testing-health-checks)
7. [Testing Login Alerts](#testing-login-alerts)
8. [Testing Reports](#testing-reports)
9. [Testing Bash Completion](#testing-bash-completion)
10. [Troubleshooting Test User Issues](#troubleshooting-test-user-issues)
11. [Automated Testing](#automated-testing)
12. [Cleanup](#cleanup)

---

## Why Not Test as Root

### Security Risks

❌ **Never test as root for these reasons:**

1. **Accidental Damage** - Root can delete/modify critical system files
2. **Permission Masking** - Root bypasses permission checks, hiding bugs
3. **Service Conflicts** - Root testing might interfere with production
4. **Security Habit** - Encourages bad security practices
5. **Production Simulation** - Real users won't have root access

### What Can Go Wrong

```bash
# Example: Testing as root might work but fail for regular users

# As root (WRONG):
root$ nftban geoip lookup 8.8.8.8
✅ Works (but misleading!)

# As regular user (FAILS):
user$ nftban geoip lookup 8.8.8.8
❌ Permission denied: /var/lib/nftban/geoip/GeoLite2-City.mmdb

# The database file needs group read permissions!
```

✅ **The Right Way:** Test as a dedicated user with appropriate group membership.

---

## Proper Test User Setup

### Step 1: Create Test User

```bash
# Create user
sudo useradd -m -s /bin/bash nftban-test

# Set a password (optional, for SSH testing)
sudo passwd nftban-test

# Verify user created
id nftban-test

# Output:
uid=1001(nftban-test) gid=1001(nftban-test) groups=1001(nftban-test)
```

### Step 2: Create NFTBan CLI Group

```bash
# Create group for CLI access
sudo groupadd nftban-cli

# Verify group created
getent group nftban-cli

# Output:
nftban-cli:x:2001:
```

### Step 3: Add User to Group

```bash
# Add test user to nftban-cli group
sudo usermod -aG nftban-cli nftban-test

# Verify group membership
id nftban-test

# Output:
uid=1001(nftban-test) gid=1001(nftban-test) groups=1001(nftban-test),2001(nftban-cli)

# Or check groups directly
groups nftban-test

# Output:
nftban-test : nftban-test nftban-cli
```

### Step 4: Set Home Directory

```bash
# Ensure home directory exists with correct permissions
sudo mkdir -p /home/nftban-test
sudo chown nftban-test:nftban-test /home/nftban-test
sudo chmod 750 /home/nftban-test

# Verify
ls -ld /home/nftban-test

# Output:
drwxr-x--- 2 nftban-test nftban-test 4096 Oct 27 14:30 /home/nftban-test
```

---

## Group Permissions

### What Needs Group Access

The `nftban-cli` group needs read access to:

1. **GeoIP Database** - `/var/lib/nftban/geoip/GeoLite2-City.mmdb`
2. **Configuration Files** - `/etc/nftban/` (read-only)
3. **Report Output** - `/var/log/nftban/reports/` (if generating reports)
4. **Log Files** - `/var/log/nftban/` (read-only for viewing)

### Set Correct Permissions

```bash
# GeoIP database
sudo chown root:nftban-cli /var/lib/nftban/geoip/GeoLite2-City.mmdb
sudo chmod 640 /var/lib/nftban/geoip/GeoLite2-City.mmdb

# GeoIP directory
sudo chown root:nftban-cli /var/lib/nftban/geoip
sudo chmod 750 /var/lib/nftban/geoip

# Configuration directory (read-only)
sudo chown -R root:nftban-cli /etc/nftban
sudo chmod 750 /etc/nftban
sudo chmod 640 /etc/nftban/*.conf
sudo chmod 750 /etc/nftban/conf.d
sudo chmod 640 /etc/nftban/conf.d/*.conf

# Reports directory (read/write for reports)
sudo chown root:nftban-cli /var/log/nftban/reports
sudo chmod 770 /var/log/nftban/reports

# Verify permissions
sudo ls -la /var/lib/nftban/geoip/

# Output:
drwxr-x--- 2 root nftban-cli 4096 Oct 27 14:00 .
-rw-r----- 1 root nftban-cli 61M  Oct 27 14:00 GeoLite2-City.mmdb
```

### Permission Script

Create `/usr/lib/nftban/scripts/set-test-permissions.sh`:

```bash
#!/bin/bash
# Set permissions for nftban-cli group testing

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root" >&2
    exit 1
fi

echo "Setting NFTBan CLI group permissions..."

# Create group if needed
if ! getent group nftban-cli >/dev/null; then
    groupadd nftban-cli
    echo "✅ Created group: nftban-cli"
fi

# GeoIP
chown -R root:nftban-cli /var/lib/nftban/geoip
chmod 750 /var/lib/nftban/geoip
chmod 640 /var/lib/nftban/geoip/*.mmdb
echo "✅ GeoIP permissions set"

# Configuration
chown -R root:nftban-cli /etc/nftban
find /etc/nftban -type d -exec chmod 750 {} \;
find /etc/nftban -type f -exec chmod 640 {} \;
echo "✅ Configuration permissions set"

# Reports
chown root:nftban-cli /var/log/nftban/reports
chmod 770 /var/log/nftban/reports
echo "✅ Report permissions set"

# Logs (read-only)
chown -R root:nftban-cli /var/log/nftban
chmod 750 /var/log/nftban
find /var/log/nftban -type f -exec chmod 640 {} \;
echo "✅ Log permissions set"

echo ""
echo "✅ All permissions configured for nftban-cli group"
```

Run it:
```bash
sudo chmod +x /usr/lib/nftban/scripts/set-test-permissions.sh
sudo /usr/lib/nftban/scripts/set-test-permissions.sh
```

---

## Testing CLI Commands

### Switch to Test User

```bash
# Method 1: su (from root or another user)
sudo su - nftban-test

# Method 2: sudo (with user shell)
sudo -u nftban-test -i

# Method 3: SSH (if password set)
ssh nftban-test@localhost

# Verify you're the test user
whoami
# Output: nftban-test

id
# Output: uid=1001(nftban-test) gid=1001(nftban-test) groups=1001(nftban-test),2001(nftban-cli)
```

### Test Basic Commands

```bash
# As nftban-test user

# Test version
nftban version
# Expected: NFTBan v0.10.0

# Test hello
nftban hello
# Expected: Banner and status

# Test help
nftban help
# Expected: Command list

# Test check
nftban check
# Expected: Environment check
```

---

## Testing GeoIP

### Test GeoIP Lookups

```bash
# As nftban-test user

# Single lookup
nftban geoip lookup 8.8.8.8

# Expected output:
{
  "ip": "8.8.8.8",
  "country": "United States",
  "country_code": "US",
  "city": "Mountain View",
  "region": "California",
  "latitude": 37.386,
  "longitude": -122.0838
}

# Compact format
nftban geoip lookup 8.8.8.8 compact

# Expected: US, California, Mountain View

# Country only
nftban geoip lookup 8.8.8.8 country

# Expected: United States (US)
```

### Test Bulk Lookups

```bash
# Create test file
cat > /tmp/test-ips.txt <<EOF
8.8.8.8
1.1.1.1
208.67.222.222
EOF

# Bulk lookup
nftban geoip bulk /tmp/test-ips.txt

# Expected:
8.8.8.8       | United States | California   | Mountain View
1.1.1.1       | Australia     | Queensland   | Brisbane
208.67.222.222| United States | California   | San Francisco

# Clean up
rm /tmp/test-ips.txt
```

### Test GeoIP Status

```bash
nftban geoip status

# Expected:
GeoIP System Status
===================

Binary: /usr/lib/nftban/bin/nftban-geoip
  ✅ Exists
  ✅ Executable
  ✅ Version: 1.0.0

Database: /var/lib/nftban/geoip/GeoLite2-City.mmdb
  ✅ Exists
  ✅ Readable
  ✅ Size: 61 MB
  ✅ Last updated: 2025-10-20

Test Lookup:
  ✅ 8.8.8.8 → United States, California, Mountain View
```

### Run GeoIP Tests

```bash
nftban geoip test

# Expected:
NFTBan GeoIP Test Suite
=======================

Test 1: Binary exists... ✅ PASS
Test 2: Binary is executable... ✅ PASS
Test 3: Database exists... ✅ PASS
Test 4: Test lookup (8.8.8.8)... ✅ PASS
Test 5: Invalid IP handling... ✅ PASS
Test 6: Performance test... ✅ PASS (45 μs)

Results: 6/6 tests passed
```

---

## Testing Health Checks

### Basic Health Check

```bash
# As nftban-test user
nftban health check

# Expected output:
NFTBan Health Check
===================

Binaries:
  ✅ /usr/sbin/nft
  ✅ /usr/sbin/nftban
  ✅ /usr/lib/nftban/bin/nftban-geoip

Paths:
  ✅ /etc/nftban
  ✅ /usr/lib/nftban
  ✅ /var/log/nftban

GeoIP:
  ✅ Binary working
  ✅ Database accessible
  ✅ Test lookup successful

Overall Status: ✅ HEALTHY
```

### Component Checks

```bash
# Check only GeoIP
nftban health geoip

# Check only binaries
nftban health binaries

# Check only modules
nftban health modules

# Check only services (may show warnings without root)
nftban health services
```

### Health Reports

```bash
# Terminal report
nftban health report terminal

# HTML report (requires write access to /var/log/nftban/reports)
nftban health report html

# Expected:
HTML report generated: /var/log/nftban/reports/health-20251027-143022.html

# JSON report
nftban health report json > /tmp/health-report.json
```

---

## Testing Login Alerts

### Test Login Alert

```bash
# As nftban-test user

# Send test alert
nftban login test

# Expected:
Testing NFTBan Login Alert System
==================================

Configuration:
  Enabled: true
  Email: admin@example.com
  Format: html
  GeoIP: true

Testing GeoIP:
  8.8.8.8 → United States, California, Mountain View

Sending test alert...
✓ Test alert sent to admin@example.com
```

**Note:** Check email inbox for test alert.

### Check Login Status

```bash
nftban login status

# Expected:
NFTBan Login Alert Status
=========================

✅ Configuration: /etc/nftban/conf.d/login_alert.conf
✅ Core Module: Installed
⚠️  Service: Not running (requires root to start)

Configuration:
  Enabled: true
  Email: admin@example.com
  Format: html
  GeoIP: true

Monitoring:
  SSH: true
  ...
```

**Note:** Service management requires root privileges.

---

## Testing Reports

### Port Reports

```bash
# As nftban-test user

# List open ports
nftban port list

# Port summary
nftban port summary

# HTML report (if permissions allow)
nftban port html-report

# Expected:
HTML report generated: /var/log/nftban/reports/port-20251027-143022.html
```

### Module Reports

```bash
# List modules
nftban module list

# Module summary
nftban module summary

# HTML report
nftban module html-report
```

### FHS Reports

```bash
# Check FHS structure
nftban fhs check

# List all paths
nftban fhs list

# HTML report
nftban fhs html-report
```

---

## Testing Bash Completion

### Test TAB Completion

```bash
# As nftban-test user

# Ensure completion is loaded
source /etc/bash_completion.d/nftban

# Test main commands
nftban <TAB><TAB>

# Expected:
check    fhs      geoip    health   hello    login    mail     module   port     version  help

# Test subcommands
nftban geoip <TAB><TAB>

# Expected:
bulk     help     lookup   status   test     update

# Test further levels
nftban geoip lookup <TAB><TAB>

# Expected:
compact  country  json

# Test health subcommands
nftban health <TAB><TAB>

# Expected:
binaries  check  fix  geoip  help  modules  permissions  report  services
```

### Completion Functionality Test

```bash
# Partial completion
nftban geo<TAB>
# Should complete to: nftban geoip

nftban health ch<TAB>
# Should complete to: nftban health check

nftban geoip lo<TAB>
# Should complete to: nftban geoip lookup
```

---

## Troubleshooting Test User Issues

### Issue 1: Permission Denied on GeoIP

**Error:**
```
nftban geoip lookup 8.8.8.8
Error: cannot read database file
```

**Solution:**
```bash
# As root, fix permissions
sudo chown root:nftban-cli /var/lib/nftban/geoip/GeoLite2-City.mmdb
sudo chmod 640 /var/lib/nftban/geoip/GeoLite2-City.mmdb

# Verify
ls -l /var/lib/nftban/geoip/GeoLite2-City.mmdb
# Expected: -rw-r----- 1 root nftban-cli ...
```

### Issue 2: User Not in Group

**Error:**
```
id
# Shows: groups=1001(nftban-test)
# Missing: nftban-cli group
```

**Solution:**
```bash
# As root, add user to group
sudo usermod -aG nftban-cli nftban-test

# User must logout and login again for group to take effect
exit  # Logout
sudo su - nftban-test  # Login again

# Verify
id
# Should show: groups=1001(nftban-test),2001(nftban-cli)
```

### Issue 3: Cannot Write Reports

**Error:**
```
nftban health report html
Error: Permission denied: /var/log/nftban/reports/
```

**Solution:**
```bash
# As root, fix report directory permissions
sudo chown root:nftban-cli /var/log/nftban/reports
sudo chmod 770 /var/log/nftban/reports

# Verify
ls -ld /var/log/nftban/reports
# Expected: drwxrwx--- 2 root nftban-cli ...
```

### Issue 4: Service Commands Fail

**Error:**
```
nftban health services
Error: Failed to check service status
```

**Explanation:**
Regular users cannot check systemd service status without additional permissions.

**Solution:**
This is expected behavior. Service management requires root privileges. Use sudo:
```bash
sudo nftban health services
```

### Issue 5: Completion Not Working

**Error:**
```
nftban <TAB><TAB>
# Shows file list instead of commands
```

**Solution:**
```bash
# Ensure completion is installed
ls -l /etc/bash_completion.d/nftban

# Load it manually
source /etc/bash_completion.d/nftban

# Or reload bash
exec bash

# Try again
nftban <TAB><TAB>
```

---

## Automated Testing

### Create Test Script

`/usr/lib/nftban/scripts/test-as-user.sh`:

```bash
#!/bin/bash
# Automated testing as nftban-test user

set -Eeuo pipefail

USER="nftban-test"
LOGFILE="/tmp/nftban-test-results-$(date +%Y%m%d-%H%M%S).log"

echo "NFTBan Test Suite - Running as $USER" | tee "$LOGFILE"
echo "=====================================" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# Test function
run_test() {
    local test_name="$1"
    local command="$2"

    echo -n "Testing: $test_name... " | tee -a "$LOGFILE"

    if sudo -u "$USER" bash -c "$command" >> "$LOGFILE" 2>&1; then
        echo "✅ PASS" | tee -a "$LOGFILE"
        return 0
    else
        echo "❌ FAIL" | tee -a "$LOGFILE"
        return 1
    fi
}

# Run tests
passed=0
failed=0

run_test "nftban version" "nftban version" && ((passed++)) || ((failed++))
run_test "nftban check" "nftban check" && ((passed++)) || ((failed++))
run_test "nftban geoip lookup" "nftban geoip lookup 8.8.8.8" && ((passed++)) || ((failed++))
run_test "nftban geoip status" "nftban geoip status" && ((passed++)) || ((failed++))
run_test "nftban geoip test" "nftban geoip test" && ((passed++)) || ((failed++))
run_test "nftban health check" "nftban health check" && ((passed++)) || ((failed++))
run_test "nftban health geoip" "nftban health geoip" && ((passed++)) || ((failed++))
run_test "nftban health binaries" "nftban health binaries" && ((passed++)) || ((failed++))
run_test "nftban port list" "nftban port list" && ((passed++)) || ((failed++))
run_test "nftban module list" "nftban module list" && ((passed++)) || ((failed++))
run_test "nftban fhs check" "nftban fhs check" && ((passed++)) || ((failed++))

echo "" | tee -a "$LOGFILE"
echo "Results: $passed passed, $failed failed" | tee -a "$LOGFILE"
echo "Log saved to: $LOGFILE"

exit $failed
```

### Run Automated Tests

```bash
# Make executable
sudo chmod +x /usr/lib/nftban/scripts/test-as-user.sh

# Run tests
sudo /usr/lib/nftban/scripts/test-as-user.sh

# View results
cat /tmp/nftban-test-results-*.log
```

---

## Cleanup

### Remove Test User

```bash
# Remove user and home directory
sudo userdel -r nftban-test

# Verify removed
id nftban-test
# Expected: id: 'nftban-test': no such user
```

### Keep Group

```bash
# Keep nftban-cli group for other users
# Do NOT delete it if other users need it

# Only delete if no longer needed
sudo groupdel nftban-cli
```

### Clean Test Files

```bash
# Remove test logs
sudo rm -f /tmp/nftban-test-*.log

# Remove test reports (if any)
sudo rm -f /var/log/nftban/reports/test-*.html
```

---

## Best Practices Summary

✅ **DO:**
1. Create dedicated test user (`nftban-test`)
2. Use `nftban-cli` group for permissions
3. Set correct file/directory permissions (640/750/770)
4. Test as the test user, not root
5. Use `sudo` only when root is actually required
6. Verify group membership with `id` command
7. Logout/login after adding user to group
8. Document any permission issues found

❌ **DON'T:**
1. Test as root (hides permission bugs)
2. Give 777 permissions (security risk)
3. Add test user to sudo group (unnecessary)
4. Skip group membership verification
5. Test with cached credentials
6. Forget to logout after group changes
7. Leave test files in production directories

---

## Quick Reference

```bash
# Setup (as root)
sudo useradd -m -s /bin/bash nftban-test
sudo groupadd nftban-cli
sudo usermod -aG nftban-cli nftban-test
sudo /usr/lib/nftban/scripts/set-test-permissions.sh

# Switch to test user
sudo su - nftban-test

# Verify
id
# Should show: groups=...,nftban-cli

# Test
nftban version
nftban geoip lookup 8.8.8.8
nftban health check

# Cleanup
exit  # Exit test user
sudo userdel -r nftban-test
```

---

**nftban — Simplifying Linux Firewall Management**

https://nftban.com
