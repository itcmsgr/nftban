# NFTBan v0.30.0 - Comprehensive AI Agent Testing Guide
# Complete Test Plan for Lab Servers (lab through lab4)

**Date:** November 4, 2025
**Version:** v0.30.0
**Target Servers:** lab.mywebhost.gr, lab1.mywebhost.gr, lab2.mywebhost.gr, lab3.mywebhost.gr, lab4.mywebhost.gr
**Contact Email:** contact@itcms.gr
**Author:** Claude (Anthropic) + ChatGPT (OpenAI)

---

## Table of Contents

1. [Overview](#overview)
2. [Lab Server Inventory](#lab-server-inventory)
3. [Phase 1: FHS Structure Verification](#phase-1-fhs-structure-verification)
4. [Phase 2: Permissions Audit](#phase-2-permissions-audit)
5. [Phase 3: CLI Command Testing](#phase-3-cli-command-testing)
6. [Phase 4: Feature Configuration](#phase-4-feature-configuration)
7. [Phase 5: Integration Testing](#phase-5-integration-testing)
8. [Phase 6: Verification & Validation](#phase-6-verification--validation)
9. [Troubleshooting](#troubleshooting)

---

## Overview

This comprehensive guide provides **complete testing procedures** for AI agents to validate NFTBan v0.30.0 across all lab servers. The guide covers:

### Critical Test Requirements

- ✅ **FHS Structure** - Verify all directories follow Filesystem Hierarchy Standard
- ✅ **Permissions** - Validate all file/directory permissions are secure
- ✅ **CLI Commands** - Test all nftban commands work correctly
- ✅ **Threat Feeds** - Enable feeds with alerts to contact@itcms.gr
- ✅ **Login Monitoring** - Enable with ROOT LOGIN = 1 (alerts enabled)
- ✅ **Port Scan Detection** - Enable and configure alerting
- ✅ **SSH Jail** - Enable fail2ban integration with nftban
- ✅ **Daily Reports** - Configure automated reports to contact@itcms.gr

---

## Lab Server Inventory

| Server | Hostname | OS | Architecture | Package Type | Status |
|--------|----------|-----|--------------|--------------|--------|
| **lab** | lab.mywebhost.gr | CentOS Stream 9 | x86_64 | RPM | ✅ Active |
| **lab1** | lab1.mywebhost.gr | Ubuntu 24.04 | x86_64 | DEB | ✅ Active |
| **lab2** | lab2.mywebhost.gr | CentOS Stream 10 | x86_64 | RPM | ✅ Active |
| **lab3** | lab3.mywebhost.gr | AlmaLinux 10.0 | x86_64 | RPM | ✅ Active |
| **lab4** | lab4.mywebhost.gr | Rocky Linux 10 | x86_64 | RPM | ✅ Active |

---

## Phase 1: FHS Structure Verification

### Test 1.1: Verify Directory Structure Exists

Run this comprehensive check on each server:

```bash
#!/bin/bash
# NFTBan FHS Structure Verification Script

echo "==================================================================="
echo "NFTBan v0.30.0 - FHS Directory Structure Check"
echo "==================================================================="
echo ""

# Define expected directories with descriptions
declare -A DIRS=(
    # Configuration directories
    ["/etc/nftban"]="Main configuration directory"
    ["/etc/nftban/conf.d"]="Module configuration files"
    ["/etc/nftban/secrets.d"]="Secrets (API keys, tokens)"
    ["/etc/nftban/keys"]="GPG/SSH keys for secure operations"

    # State and data directories
    ["/var/lib/nftban"]="Persistent application data"
    ["/var/lib/nftban/state"]="Runtime state files"
    ["/var/lib/nftban/snapshots"]="nftables ruleset snapshots"
    ["/var/lib/nftban/feeds"]="Threat feed data"
    ["/var/lib/nftban/keyring"]="GPG keyring for feed verification"
    ["/var/lib/nftban/backup"]="Configuration backups"
    ["/var/lib/nftban/reports"]="Generated reports"
    ["/var/lib/nftban/reports/baseline"]="Baseline reports for comparison"
    ["/var/lib/nftban/metrics"]="Metrics and statistics"
    ["/var/lib/nftban/config"]="Generated config files (system.conf)"

    # Cache directories
    ["/var/cache/nftban"]="Temporary cache data"
    ["/var/cache/nftban/geoip"]="GeoIP database cache"
    ["/var/cache/nftban/tmp"]="Temporary working files"

    # Log directories
    ["/var/log/nftban"]="Application logs"

    # Application binaries
    ["/usr/lib/nftban"]="Application files"
    ["/usr/lib/nftban/bin"]="Binary executables"
    ["/usr/lib/nftban/modules"]="Bash modules"

    # Shared data
    ["/usr/share/nftban"]="Architecture-independent data"
    ["/usr/share/nftban/templates"]="Email/report templates"
    ["/usr/share/nftban/completions"]="Shell completion scripts"

    # Documentation
    ["/usr/share/doc/nftban"]="Documentation"
    ["/usr/share/licenses/nftban"]="License files"

    # Man pages
    ["/usr/share/man/man1"]="Man pages section 1"
    ["/usr/share/man/man5"]="Man pages section 5"
)

# Check each directory
PASSED=0
FAILED=0

for DIR in "${!DIRS[@]}"; do
    DESC="${DIRS[$DIR]}"
    if [ -d "$DIR" ]; then
        echo "✅ PASS: $DIR"
        echo "   → $DESC"
        ((PASSED++))
    else
        echo "❌ FAIL: $DIR - NOT FOUND"
        echo "   → Expected: $DESC"
        ((FAILED++))
    fi
done

echo ""
echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All FHS directories verified successfully!"
    exit 0
else
    echo "❌ Some directories are missing - package may not be installed correctly"
    exit 1
fi
```

**Save this script and run on each server:**

```bash
# On each lab server
curl -o /tmp/verify_fhs.sh https://raw.githubusercontent.com/itcmsgr/nftban/main/NFTBAN_AI_TESTING/helpers/verify_fhs.sh
chmod +x /tmp/verify_fhs.sh
sudo /tmp/verify_fhs.sh
```

### Test 1.2: Verify Systemd Units

```bash
#!/bin/bash
echo "==================================================================="
echo "NFTBan v0.30.0 - Systemd Units Check"
echo "==================================================================="

# Check for RPM (RHEL-based) vs DEB (Debian-based) to determine correct path
if [ -f /etc/redhat-release ]; then
    SYSTEMD_DIR="/usr/lib/systemd/system"
elif [ -f /etc/debian_version ]; then
    SYSTEMD_DIR="/lib/systemd/system"
else
    echo "❌ Unknown distribution"
    exit 1
fi

echo "Systemd units location: $SYSTEMD_DIR"
echo ""

# Expected units
UNITS=(
    "nftban.service"
    "nftban.timer"
    "nftban-health.timer"
    "nftban-health.service"
    "nftban-daily-report.timer"
    "nftban-daily-report.service"
    "nftban-permissions-audit.timer"
    "nftban-permissions-audit.service"
)

PASSED=0
FAILED=0

for UNIT in "${UNITS[@]}"; do
    if [ -f "$SYSTEMD_DIR/$UNIT" ]; then
        echo "✅ PASS: $UNIT"
        # Show if enabled/active
        STATUS=$(systemctl is-enabled "$UNIT" 2>/dev/null || echo "N/A")
        ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null || echo "inactive")
        echo "   → Enabled: $STATUS | Active: $ACTIVE"
        ((PASSED++))
    else
        echo "❌ FAIL: $UNIT - NOT FOUND"
        ((FAILED++))
    fi
done

echo ""
echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All systemd units verified successfully!"
    exit 0
else
    echo "❌ Some systemd units are missing"
    exit 1
fi
```

---

## Phase 2: Permissions Audit

### Test 2.1: Verify Directory Permissions

```bash
#!/bin/bash
echo "==================================================================="
echo "NFTBan v0.30.0 - Directory Permissions Audit"
echo "==================================================================="
echo ""

# Expected permissions (octal mode, owner, group)
declare -A EXPECTED_PERMS=(
    # Security-critical directories (restricted)
    ["/etc/nftban/secrets.d"]="700:root:root"
    ["/etc/nftban/keys"]="700:root:root"
    ["/var/log/nftban"]="750:root:nftban"

    # Standard directories (moderate)
    ["/etc/nftban"]="755:root:root"
    ["/etc/nftban/conf.d"]="755:root:root"
    ["/var/lib/nftban"]="755:root:nftban"
    ["/var/lib/nftban/state"]="750:root:nftban"
    ["/var/lib/nftban/feeds"]="750:root:nftban"
    ["/var/lib/nftban/reports"]="750:root:nftban"
    ["/var/cache/nftban"]="755:root:nftban"
)

PASSED=0
FAILED=0
WARNINGS=0

for DIR in "${!EXPECTED_PERMS[@]}"; do
    if [ ! -d "$DIR" ]; then
        echo "⚠️  SKIP: $DIR - Directory does not exist"
        ((WARNINGS++))
        continue
    fi

    # Parse expected values
    IFS=':' read -r EXP_MODE EXP_OWNER EXP_GROUP <<< "${EXPECTED_PERMS[$DIR]}"

    # Get actual values
    ACT_MODE=$(stat -c "%a" "$DIR" 2>/dev/null)
    ACT_OWNER=$(stat -c "%U" "$DIR" 2>/dev/null)
    ACT_GROUP=$(stat -c "%G" "$DIR" 2>/dev/null)

    # Compare
    if [ "$ACT_MODE" = "$EXP_MODE" ] && [ "$ACT_OWNER" = "$EXP_OWNER" ] && [ "$ACT_GROUP" = "$EXP_GROUP" ]; then
        echo "✅ PASS: $DIR"
        echo "   → Mode: $ACT_MODE | Owner: $ACT_OWNER | Group: $ACT_GROUP"
        ((PASSED++))
    else
        echo "❌ FAIL: $DIR"
        echo "   → Expected: $EXP_MODE $EXP_OWNER:$EXP_GROUP"
        echo "   → Actual:   $ACT_MODE $ACT_OWNER:$ACT_GROUP"
        ((FAILED++))
    fi
done

echo ""
echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed, $WARNINGS warnings"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All permissions verified successfully!"
    exit 0
else
    echo "❌ Some permission mismatches found"
    exit 1
fi
```

### Test 2.2: Verify System Groups and Users

```bash
#!/bin/bash
echo "==================================================================="
echo "NFTBan v0.30.0 - System Users and Groups Check"
echo "==================================================================="
echo ""

# Expected groups
EXPECTED_GROUPS=(
    "nftban"
    "nftban-cli"
    "nftban-auditors"
)

# Expected user
EXPECTED_USER="nftban"

PASSED=0
FAILED=0

# Check user
if id "$EXPECTED_USER" &>/dev/null; then
    USER_UID=$(id -u "$EXPECTED_USER")
    USER_GID=$(id -g "$EXPECTED_USER")
    USER_SHELL=$(getent passwd "$EXPECTED_USER" | cut -d: -f7)
    USER_HOME=$(getent passwd "$EXPECTED_USER" | cut -d: -f6)

    echo "✅ PASS: User '$EXPECTED_USER' exists"
    echo "   → UID: $USER_UID"
    echo "   → Primary GID: $USER_GID"
    echo "   → Shell: $USER_SHELL (should be /usr/sbin/nologin or /sbin/nologin)"
    echo "   → Home: $USER_HOME"
    ((PASSED++))
else
    echo "❌ FAIL: User '$EXPECTED_USER' does not exist"
    ((FAILED++))
fi

echo ""

# Check groups
for GROUP in "${EXPECTED_GROUPS[@]}"; do
    if getent group "$GROUP" &>/dev/null; then
        GROUP_GID=$(getent group "$GROUP" | cut -d: -f3)
        GROUP_MEMBERS=$(getent group "$GROUP" | cut -d: -f4)

        echo "✅ PASS: Group '$GROUP' exists"
        echo "   → GID: $GROUP_GID"
        echo "   → Members: ${GROUP_MEMBERS:-none}"
        ((PASSED++))
    else
        echo "❌ FAIL: Group '$GROUP' does not exist"
        ((FAILED++))
    fi
done

echo ""

# Check system.conf generation
SYSTEM_CONF="/var/lib/nftban/config/system.conf"
if [ -f "$SYSTEM_CONF" ]; then
    echo "✅ PASS: $SYSTEM_CONF exists"
    echo ""
    echo "   Contents:"
    cat "$SYSTEM_CONF" | sed 's/^/   /'
    ((PASSED++))
else
    echo "❌ FAIL: $SYSTEM_CONF not found (required for GUI tools)"
    ((FAILED++))
fi

echo ""
echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All users/groups verified successfully!"
    exit 0
else
    echo "❌ Some users/groups are missing"
    exit 1
fi
```

---

## Phase 3: CLI Command Testing

### Test 3.1: Basic CLI Commands

```bash
#!/bin/bash
echo "==================================================================="
echo "NFTBan v0.30.0 - CLI Command Testing"
echo "==================================================================="
echo ""

PASSED=0
FAILED=0

# Test 1: Version
echo "Test 1: nftban --version"
if OUTPUT=$(nftban --version 2>&1) && echo "$OUTPUT" | grep -q "0.30.0"; then
    echo "✅ PASS: Version command works"
    echo "   → $OUTPUT"
    ((PASSED++))
else
    echo "❌ FAIL: Version command failed or version mismatch"
    echo "   → $OUTPUT"
    ((FAILED++))
fi
echo ""

# Test 2: Help
echo "Test 2: nftban --help"
if OUTPUT=$(nftban --help 2>&1) && echo "$OUTPUT" | grep -q "Usage:"; then
    echo "✅ PASS: Help command works"
    ((PASSED++))
else
    echo "❌ FAIL: Help command failed"
    ((FAILED++))
fi
echo ""

# Test 3: Status
echo "Test 3: nftban status"
if OUTPUT=$(sudo nftban status 2>&1); then
    echo "✅ PASS: Status command works"
    echo "   Output (first 10 lines):"
    echo "$OUTPUT" | head -10 | sed 's/^/   /'
    ((PASSED++))
else
    echo "❌ FAIL: Status command failed"
    echo "   → $OUTPUT"
    ((FAILED++))
fi
echo ""

# Test 4: Config show
echo "Test 4: nftban config show"
if OUTPUT=$(sudo nftban config show 2>&1); then
    echo "✅ PASS: Config show command works"
    ((PASSED++))
else
    echo "❌ FAIL: Config show command failed"
    ((FAILED++))
fi
echo ""

# Test 5: Feeds list
echo "Test 5: nftban feeds list"
if OUTPUT=$(sudo nftban feeds list 2>&1); then
    echo "✅ PASS: Feeds list command works"
    echo "   Output (first 10 lines):"
    echo "$OUTPUT" | head -10 | sed 's/^/   /'
    ((PASSED++))
else
    echo "❌ FAIL: Feeds list command failed"
    ((FAILED++))
fi
echo ""

# Test 6: Stats show
echo "Test 6: nftban stats show"
if OUTPUT=$(sudo nftban stats show 2>&1); then
    echo "✅ PASS: Stats show command works"
    ((PASSED++))
else
    echo "❌ FAIL: Stats show command failed"
    ((FAILED++))
fi
echo ""

# Test 7: Health check
echo "Test 7: nftban health check"
if OUTPUT=$(sudo nftban health check 2>&1); then
    echo "✅ PASS: Health check command works"
    echo "   Output (first 10 lines):"
    echo "$OUTPUT" | head -10 | sed 's/^/   /'
    ((PASSED++))
else
    echo "❌ FAIL: Health check command failed"
    ((FAILED++))
fi
echo ""

echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All CLI commands work correctly!"
    exit 0
else
    echo "❌ Some CLI commands failed"
    exit 1
fi
```

### Test 3.2: Advanced CLI Commands

```bash
#!/bin/bash
echo "==================================================================="
echo "NFTBan v0.30.0 - Advanced CLI Command Testing"
echo "==================================================================="
echo ""

PASSED=0
FAILED=0

# Test 1: IP whitelist operations
echo "Test 1: IP whitelist operations"
if sudo nftban whitelist add 192.0.2.1 "Test IP" 2>&1 && \
   sudo nftban whitelist list 2>&1 | grep -q "192.0.2.1" && \
   sudo nftban whitelist remove 192.0.2.1 2>&1; then
    echo "✅ PASS: Whitelist add/list/remove works"
    ((PASSED++))
else
    echo "❌ FAIL: Whitelist operations failed"
    ((FAILED++))
fi
echo ""

# Test 2: Block operations
echo "Test 2: Block operations"
if sudo nftban block add 192.0.2.2 "Test block" 2>&1 && \
   sudo nftban block list 2>&1 | grep -q "192.0.2.2" && \
   sudo nftban block remove 192.0.2.2 2>&1; then
    echo "✅ PASS: Block add/list/remove works"
    ((PASSED++))
else
    echo "❌ FAIL: Block operations failed"
    ((FAILED++))
fi
echo ""

# Test 3: Snapshot operations
echo "Test 3: Snapshot operations"
if sudo nftban snapshot create "test-snapshot" 2>&1 && \
   sudo nftban snapshot list 2>&1 | grep -q "test-snapshot"; then
    echo "✅ PASS: Snapshot create/list works"
    ((PASSED++))
else
    echo "❌ FAIL: Snapshot operations failed"
    ((FAILED++))
fi
echo ""

# Test 4: Audit commands
echo "Test 4: Audit commands (as auditor)"
if sudo nftban audit permissions 2>&1 && \
   sudo nftban audit config 2>&1; then
    echo "✅ PASS: Audit commands work"
    ((PASSED++))
else
    echo "❌ FAIL: Audit commands failed"
    ((FAILED++))
fi
echo ""

# Test 5: Report generation
echo "Test 5: Report generation"
if sudo nftban report generate --format html 2>&1; then
    echo "✅ PASS: Report generation works"
    ((PASSED++))
else
    echo "❌ FAIL: Report generation failed"
    ((FAILED++))
fi
echo ""

echo "==================================================================="
echo "RESULTS: $PASSED passed, $FAILED failed"
echo "==================================================================="

if [ $FAILED -eq 0 ]; then
    echo "✅ All advanced CLI commands work correctly!"
    exit 0
else
    echo "❌ Some advanced CLI commands failed"
    exit 1
fi
```

---

## Phase 4: Feature Configuration

### Configuration 4.1: Enable Threat Feeds with Alerts

**File:** `/etc/nftban/conf.d/feeds.conf`

```bash
# Enable threat feeds
FEEDS_ENABLED="yes"

# Enable alerts
FEEDS_ALERT_ENABLED="yes"
FEEDS_ALERT_EMAIL="contact@itcms.gr"

# Enable specific feeds
FEEDS_FIREHOL_LEVEL1_ENABLED="yes"
FEEDS_SPAMHAUS_DROP_ENABLED="yes"
FEEDS_ABUSE_CH_ENABLED="yes"

# Update schedule
FEEDS_UPDATE_INTERVAL="3600"  # 1 hour
```

**Apply configuration:**

```bash
sudo nftban config reload
sudo nftban feeds update
sudo nftban feeds list
```

### Configuration 4.2: Enable Login Monitoring with ROOT LOGIN = 1

**File:** `/etc/nftban/conf.d/login.conf`

```bash
# Enable login monitoring
LOGIN_MONITORING_ENABLED="yes"

# CRITICAL: Enable root login alerts (must be "1")
LOGIN_ALERT_ROOT="1"
LOGIN_ALERT_ROOT_EMAIL="contact@itcms.gr"

# Alert on all logins
LOGIN_ALERT_ALL="yes"
LOGIN_ALERT_EMAIL="contact@itcms.gr"

# Monitor methods
LOGIN_MONITOR_SSH="yes"
LOGIN_MONITOR_CONSOLE="yes"
LOGIN_MONITOR_SU="yes"
LOGIN_MONITOR_SUDO="yes"
```

**Apply configuration:**

```bash
sudo nftban config reload
sudo systemctl restart nftban-login-monitor.service
```

### Configuration 4.3: Enable Port Scan Detection

**File:** `/etc/nftban/conf.d/portscan.conf`

```bash
# Enable port scan detection
PORTSCAN_ENABLED="yes"

# Detection thresholds
PORTSCAN_THRESHOLD_PORTS="10"    # 10+ ports in window = scan
PORTSCAN_THRESHOLD_TIME="60"     # Within 60 seconds

# Blocking
PORTSCAN_BLOCK_DURATION="3600"   # Block for 1 hour
PORTSCAN_AUTO_BLOCK="yes"

# Alerts
PORTSCAN_ALERT_ENABLED="yes"
PORTSCAN_ALERT_EMAIL="contact@itcms.gr"
```

**Apply configuration:**

```bash
sudo nftban config reload
```

### Configuration 4.4: Enable SSH Jail (fail2ban Integration)

**File:** `/etc/nftban/conf.d/fail2ban.conf`

```bash
# Enable fail2ban integration
FAIL2BAN_ENABLED="yes"

# SSH jail settings
FAIL2BAN_SSH_ENABLED="yes"
FAIL2BAN_SSH_MAXRETRY="3"
FAIL2BAN_SSH_FINDTIME="600"      # 10 minutes
FAIL2BAN_SSH_BANTIME="3600"      # 1 hour

# Alerts
FAIL2BAN_SSH_ALERT_ENABLED="yes"
FAIL2BAN_SSH_ALERT_EMAIL="contact@itcms.gr"
```

**Install fail2ban if not present:**

```bash
# RHEL-based
sudo dnf install -y fail2ban

# Debian-based
sudo apt-get install -y fail2ban
```

**Configure fail2ban to use nftban:**

```bash
sudo cat > /etc/fail2ban/jail.d/nftban-ssh.conf <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
banaction = nftban
EOF

sudo systemctl restart fail2ban
```

**Apply configuration:**

```bash
sudo nftban config reload
```

### Configuration 4.5: Enable Daily Reports

**File:** `/etc/nftban/conf.d/stats.conf`

```bash
# Enable statistics collection
STATS_ENABLED="yes"

# Daily reports
STATS_DAILY_REPORT="yes"
STATS_DAILY_REPORT_TIME="13:00"  # 1 PM daily
STATS_DAILY_REPORT_EMAIL="contact@itcms.gr"
STATS_DAILY_REPORT_FORMAT="html"

# Report sections
STATS_REPORT_INCLUDE_BLOCKS="yes"
STATS_REPORT_INCLUDE_FEEDS="yes"
STATS_REPORT_INCLUDE_LOGINS="yes"
STATS_REPORT_INCLUDE_SCANS="yes"
STATS_REPORT_INCLUDE_PERFORMANCE="yes"
```

**Apply configuration:**

```bash
sudo nftban config reload
sudo systemctl status nftban-daily-report.timer
```

### Configuration 4.6: Configure Email Settings

**File:** `/etc/nftban/nftban.conf`

```bash
# Email configuration
EMAIL_ENABLED="yes"
EMAIL_METHOD="smtp"              # or "sendmail"

# SMTP settings (if using smtp)
SMTP_HOST="mail.itcms.gr"
SMTP_PORT="587"
SMTP_TLS="yes"
SMTP_USERNAME="nftban@itcms.gr"
SMTP_PASSWORD_FILE="/etc/nftban/secrets.d/smtp_password"

# Email defaults
EMAIL_FROM="nftban@itcms.gr"
EMAIL_REPLY_TO="contact@itcms.gr"
EMAIL_SUBJECT_PREFIX="[NFTBan]"
```

**Set SMTP password:**

```bash
sudo mkdir -p /etc/nftban/secrets.d
sudo chmod 700 /etc/nftban/secrets.d
echo "your_smtp_password" | sudo tee /etc/nftban/secrets.d/smtp_password
sudo chmod 600 /etc/nftban/secrets.d/smtp_password
```

---

## Phase 5: Integration Testing

### Test 5.1: Threat Feed Integration Test

```bash
#!/bin/bash
echo "==================================================================="
echo "Test 5.1: Threat Feed Integration"
echo "==================================================================="

# Update feeds
echo "Updating threat feeds..."
sudo nftban feeds update

# Check feed status
echo ""
echo "Feed status:"
sudo nftban feeds list

# Verify feeds are loaded into nftables
echo ""
echo "Checking nftables sets:"
sudo nft list sets | grep -A 5 "nftban"

# Check for alert email
echo ""
echo "Check /var/log/nftban/feeds.log for any errors"
sudo tail -20 /var/log/nftban/feeds.log
```

### Test 5.2: Login Monitoring Test

```bash
#!/bin/bash
echo "==================================================================="
echo "Test 5.2: Login Monitoring"
echo "==================================================================="

# Create a test root login (SSH or console)
echo "Trigger a root login to test alerts..."
echo "Expected: Alert email should be sent to contact@itcms.gr"

# Check login logs
echo ""
echo "Recent login events:"
sudo nftban login history | tail -20

# Verify ROOT LOGIN setting
echo ""
echo "Checking ROOT LOGIN configuration:"
sudo grep "LOGIN_ALERT_ROOT" /etc/nftban/conf.d/login.conf
```

### Test 5.3: Port Scan Detection Test

```bash
#!/bin/bash
echo "==================================================================="
echo "Test 5.3: Port Scan Detection"
echo "==================================================================="

# Get server's external IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo "Simulating port scan from another server..."
echo "Run this from a different lab server:"
echo ""
echo "  nmap -sT -p 1-1000 $SERVER_IP"
echo ""
echo "Expected: Port scan should be detected and blocked"

# Check for detections
echo ""
echo "Checking for port scan detections:"
sudo nftban stats show | grep -i "port scan"

# Check blocked IPs
echo ""
echo "Currently blocked IPs:"
sudo nftban block list
```

### Test 5.4: SSH Jail Test

```bash
#!/bin/bash
echo "==================================================================="
echo "Test 5.4: SSH Jail (fail2ban)"
echo "==================================================================="

# Check fail2ban status
echo "fail2ban status:"
sudo fail2ban-client status sshd

# Simulate failed SSH attempts
echo ""
echo "To test: From another server, try to SSH with wrong password 3 times"
echo "Expected: IP should be banned by fail2ban + nftban"

# Check banned IPs
echo ""
echo "Currently banned IPs:"
sudo fail2ban-client status sshd

# Check nftban blocks
echo ""
echo "NFTBan blocked IPs:"
sudo nftban block list | grep -i "fail2ban"
```

### Test 5.5: Daily Report Test

```bash
#!/bin/bash
echo "==================================================================="
echo "Test 5.5: Daily Report"
echo "==================================================================="

# Check timer status
echo "Daily report timer status:"
sudo systemctl status nftban-daily-report.timer

# Manually trigger report generation
echo ""
echo "Generating test report..."
sudo nftban report generate --format html --output /tmp/nftban-report.html

# Check if report was created
if [ -f /tmp/nftban-report.html ]; then
    echo "✅ Report generated successfully!"
    echo "Report location: /tmp/nftban-report.html"
    echo "Report size: $(du -h /tmp/nftban-report.html | awk '{print $1}')"
else
    echo "❌ Report generation failed"
fi

# Check for email delivery
echo ""
echo "Check mail logs for report delivery:"
sudo grep "nftban.*report" /var/log/mail.log | tail -5
```

---

## Phase 6: Verification & Validation

### Complete System Verification Script

```bash
#!/bin/bash
# =============================================================================
# NFTBan v0.30.0 - Complete System Verification
# Run this on each lab server after all configuration
# =============================================================================

set -euo pipefail

echo "=========================================================================="
echo "NFTBan v0.30.0 - Complete System Verification"
echo "Server: $(hostname)"
echo "Date: $(date)"
echo "=========================================================================="
echo ""

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to run test
run_test() {
    local test_name="$1"
    local test_command="$2"

    ((TOTAL_TESTS++))
    echo -n "[$TOTAL_TESTS] $test_name ... "

    if eval "$test_command" &>/dev/null; then
        echo "✅ PASS"
        ((PASSED_TESTS++))
        return 0
    else
        echo "❌ FAIL"
        ((FAILED_TESTS++))
        return 1
    fi
}

echo "=== FHS Structure ==="
run_test "Config directory" "[ -d /etc/nftban ]"
run_test "State directory" "[ -d /var/lib/nftban/state ]"
run_test "Feeds directory" "[ -d /var/lib/nftban/feeds ]"
run_test "Reports directory" "[ -d /var/lib/nftban/reports ]"
run_test "Log directory" "[ -d /var/log/nftban ]"
run_test "Secrets directory" "[ -d /etc/nftban/secrets.d ]"
run_test "Keys directory" "[ -d /etc/nftban/keys ]"
echo ""

echo "=== System Users/Groups ==="
run_test "nftban user" "id nftban"
run_test "nftban group" "getent group nftban"
run_test "nftban-cli group" "getent group nftban-cli"
run_test "nftban-auditors group" "getent group nftban-auditors"
run_test "system.conf generated" "[ -f /var/lib/nftban/config/system.conf ]"
echo ""

echo "=== Systemd Units ==="
run_test "nftban.timer enabled" "systemctl is-enabled nftban.timer"
run_test "nftban-health.timer enabled" "systemctl is-enabled nftban-health.timer"
run_test "nftban-daily-report.timer enabled" "systemctl is-enabled nftban-daily-report.timer"
run_test "nftban.timer active" "systemctl is-active nftban.timer"
echo ""

echo "=== CLI Commands ==="
run_test "nftban version" "nftban --version | grep -q '0.30.0'"
run_test "nftban status" "sudo nftban status"
run_test "nftban config show" "sudo nftban config show"
run_test "nftban feeds list" "sudo nftban feeds list"
run_test "nftban stats show" "sudo nftban stats show"
run_test "nftban health check" "sudo nftban health check"
echo ""

echo "=== Feature Configuration ==="
run_test "Feeds enabled" "sudo grep -q 'FEEDS_ENABLED=\"yes\"' /etc/nftban/conf.d/feeds.conf"
run_test "Feeds alerts enabled" "sudo grep -q 'FEEDS_ALERT_EMAIL=\"contact@itcms.gr\"' /etc/nftban/conf.d/feeds.conf"
run_test "Login monitoring enabled" "sudo grep -q 'LOGIN_MONITORING_ENABLED=\"yes\"' /etc/nftban/conf.d/login.conf"
run_test "Root login alerts enabled" "sudo grep -q 'LOGIN_ALERT_ROOT=\"1\"' /etc/nftban/conf.d/login.conf"
run_test "Port scan detection enabled" "sudo grep -q 'PORTSCAN_ENABLED=\"yes\"' /etc/nftban/conf.d/portscan.conf"
run_test "Port scan alerts enabled" "sudo grep -q 'PORTSCAN_ALERT_EMAIL=\"contact@itcms.gr\"' /etc/nftban/conf.d/portscan.conf"
run_test "SSH jail enabled" "sudo grep -q 'FAIL2BAN_SSH_ENABLED=\"yes\"' /etc/nftban/conf.d/fail2ban.conf"
run_test "Daily reports enabled" "sudo grep -q 'STATS_DAILY_REPORT_EMAIL=\"contact@itcms.gr\"' /etc/nftban/conf.d/stats.conf"
echo ""

echo "=========================================================================="
echo "FINAL RESULTS"
echo "=========================================================================="
echo "Total Tests: $TOTAL_TESTS"
echo "Passed:      $PASSED_TESTS"
echo "Failed:      $FAILED_TESTS"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo "✅✅✅ ALL TESTS PASSED! ✅✅✅"
    echo ""
    echo "NFTBan v0.30.0 is fully configured and operational on $(hostname)"
    echo ""
    echo "Monitoring configuration:"
    echo "  • Threat feeds: ✅ Active with alerts to contact@itcms.gr"
    echo "  • Login monitoring: ✅ Active with ROOT LOGIN alerts enabled"
    echo "  • Port scan detection: ✅ Active with alerts to contact@itcms.gr"
    echo "  • SSH jail: ✅ Active with fail2ban integration"
    echo "  • Daily reports: ✅ Scheduled to contact@itcms.gr"
    exit 0
else
    echo "❌ SOME TESTS FAILED"
    echo ""
    echo "Please review the failed tests above and fix any issues."
    exit 1
fi
```

---

## Troubleshooting

### Issue 1: Feeds Not Updating

**Symptoms:**
- `nftban feeds update` fails
- No feed data in `/var/lib/nftban/feeds/`

**Solutions:**
```bash
# Check network connectivity
curl -I https://iplists.firehol.org/

# Check permissions
sudo ls -la /var/lib/nftban/feeds/

# Check logs
sudo journalctl -u nftban-feeds.service -n 50

# Manually update with verbose output
sudo nftban feeds update --verbose
```

### Issue 2: Email Alerts Not Sending

**Symptoms:**
- No alert emails received
- Configuration looks correct

**Solutions:**
```bash
# Test email configuration
sudo nftban test email contact@itcms.gr

# Check SMTP credentials
sudo cat /etc/nftban/secrets.d/smtp_password

# Check mail logs
sudo tail -100 /var/log/mail.log | grep nftban

# Test with sendmail directly
echo "Test" | mail -s "NFTBan Test" contact@itcms.gr
```

### Issue 3: Port Scan Detection Not Working

**Symptoms:**
- Port scans not detected
- No blocks triggered

**Solutions:**
```bash
# Verify portscan module is loaded
sudo nftban status | grep portscan

# Check detection thresholds
sudo grep PORTSCAN /etc/nftban/conf.d/portscan.conf

# Check kernel conntrack
sudo sysctl net.netfilter.nf_conntrack_max

# Test with controlled scan
sudo nmap -sT -p 1-100 localhost
```

### Issue 4: Permissions Errors

**Symptoms:**
- Permission denied errors in logs
- Commands fail as regular user

**Solutions:**
```bash
# Run permissions audit
sudo nftban audit permissions

# Fix common permission issues
sudo chmod 750 /var/log/nftban
sudo chown -R root:nftban /var/lib/nftban
sudo chmod 700 /etc/nftban/secrets.d

# Re-run postinstall script
sudo /usr/lib/nftban/helpers/nftban-postinstall.sh
```

---

## Test Execution Matrix

Use this matrix to track testing progress across all servers:

| Test Phase | lab | lab1 | lab2 | lab3 | lab4 | Notes |
|------------|-----|------|------|------|------|-------|
| **Phase 1: FHS Structure** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Directory structure | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Systemd units | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| **Phase 2: Permissions** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Directory permissions | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Users/groups | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| **Phase 3: CLI Commands** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Basic commands | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Advanced commands | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| **Phase 4: Configuration** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Threat feeds | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Login monitoring (ROOT=1) | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Port scan detection | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - SSH jail | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Daily reports | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Email configuration | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| **Phase 5: Integration** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Feeds integration | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Login monitoring | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Port scan detection | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - SSH jail | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Daily report | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| **Phase 6: Verification** | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |
| - Complete system check | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | |

**Legend:**
- ⬜ Not started
- 🔄 In progress
- ✅ Completed successfully
- ❌ Failed (see notes)

---

## Quick Start for AI Agents

To quickly test NFTBan v0.30.0 on any lab server:

```bash
# 1. Download and run complete verification
curl -o /tmp/verify_complete.sh \
  https://raw.githubusercontent.com/itcmsgr/nftban/main/NFTBAN_AI_TESTING/helpers/verify_complete.sh
chmod +x /tmp/verify_complete.sh
sudo /tmp/verify_complete.sh

# 2. If all tests pass, configure features
# Edit configuration files as shown in Phase 4

# 3. Reload and test
sudo nftban config reload
sudo nftban health check

# 4. Monitor for 24 hours
# Check logs: sudo journalctl -u nftban* -f
```

---

## Success Criteria

All lab servers MUST meet these criteria:

- ✅ All FHS directories exist with correct permissions
- ✅ All system users/groups created correctly
- ✅ All systemd timers active and scheduled
- ✅ All CLI commands work without errors
- ✅ Threat feeds updating and alerts working
- ✅ Login monitoring active with ROOT LOGIN = 1
- ✅ Port scan detection active with alerts
- ✅ SSH jail configured and working with fail2ban
- ✅ Daily reports scheduled to contact@itcms.gr
- ✅ Email delivery confirmed working

---

**END OF COMPREHENSIVE TEST GUIDE**

For questions or issues, contact: contact@itcms.gr
