# NFTBan Health Check System

**Version:** 1.0.0
**Module:** `nftban_health.sh` + `cmd_health.sh`
**Author:** Antonios Voulvoulis <contact@nftban.com>
**Website:** https://nftban.com
**Status:** ✅ Production Ready

---

## Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
4. [CLI Usage](#cli-usage)
5. [Health Checks](#health-checks)
6. [Auto-Fix Capabilities](#auto-fix-capabilities)
7. [Integration Examples](#integration-examples)
8. [Status Codes](#status-codes)
9. [Configuration](#configuration)
10. [Troubleshooting](#troubleshooting)

---

## Overview

The NFTBan Health Check System provides comprehensive verification and diagnostics for the entire NFTBan installation. It checks binaries, paths, permissions, services, modules, GeoIP functionality, databases, and configuration files.

### Key Benefits

- **Comprehensive Verification** - Checks all critical NFTBan components
- **Auto-Fix Capabilities** - Can automatically repair common issues
- **Clear Status Reporting** - Visual indicators (✅ ⚠️ ❌) for quick assessment
- **Multiple Output Formats** - Terminal, HTML, and JSON reports
- **Component-Specific Checks** - Can check individual subsystems
- **Root Privilege Detection** - Warns when elevated privileges needed

---

## Features

### What Gets Checked

1. **Binaries** - Core executables (nft, nftables, nftban, nftban-geoip)
2. **Paths** - All FHS directories (/etc, /usr, /var paths)
3. **Permissions** - File and directory permissions
4. **Services** - Systemd services (nftables, nftban-daemon)
5. **Modules** - Bash modules and CLI commands
6. **GeoIP** - GO binary and MaxMind database
7. **Databases** - SQLite databases and schemas
8. **Configuration** - Config files and syntax validation

### Auto-Fix Capabilities

- Create missing directories
- Fix incorrect permissions (755 for executables, 644 for configs)
- Restart failed services
- Download missing GeoIP database
- Reset database schemas

---

## Architecture

### Core Module: `nftban_health.sh`

Location: `/usr/lib/nftban/core/nftban_health.sh`

**21 Exported Functions:**

```bash
# Initialization
nftban_health_init()

# Main checks
nftban_health_check_all()
nftban_health_check_binaries()
nftban_health_check_paths()
nftban_health_check_permissions()
nftban_health_check_services()
nftban_health_check_modules()
nftban_health_check_geoip()
nftban_health_check_databases()
nftban_health_check_config()

# Auto-fix functions
nftban_health_fix_all()
nftban_health_fix_permissions()
nftban_health_fix_directories()
nftban_health_fix_services()

# Reporting
nftban_health_report()
nftban_health_report_html()
nftban_health_report_json()

# Component checks
nftban_health_check_binary()
nftban_health_check_path()
nftban_health_check_file_permission()
nftban_health_check_service()
nftban_health_check_module()
```

### CLI Handler: `cmd_health.sh`

Location: `/usr/lib/nftban/cli/cmd_health.sh`

**8 CLI Commands:**

```bash
nftban health check         # Comprehensive health check
nftban health report        # Generate reports (terminal/html/json)
nftban health fix           # Auto-fix issues
nftban health services      # Check only services
nftban health modules       # Check only modules
nftban health binaries      # Check only binaries
nftban health permissions   # Check only permissions
nftban health geoip         # Check only GeoIP system
nftban health help          # Show help
```

---

## CLI Usage

### Basic Health Check

```bash
# Run comprehensive check
nftban health check

# Output:
NFTBan Health Check
===================

Binaries:
  ✅ /usr/sbin/nft
  ✅ /usr/sbin/nftables
  ✅ /usr/sbin/nftban
  ✅ /usr/lib/nftban/bin/nftban-geoip

Paths:
  ✅ /etc/nftban
  ✅ /usr/lib/nftban
  ✅ /var/log/nftban
  ... (all FHS paths)

Permissions:
  ✅ /usr/sbin/nftban (755)
  ✅ /etc/nftban/nftban.conf (644)
  ... (all critical files)

Services:
  ✅ nftables.service (active)
  ⚠️  nftban-daemon.service (inactive)

Modules:
  ✅ nftban_output.sh
  ✅ nftban_geoip_go.sh
  ✅ nftban_health.sh
  ... (all modules)

GeoIP:
  ✅ GO binary: /usr/lib/nftban/bin/nftban-geoip
  ✅ Database: /var/lib/nftban/geoip/GeoLite2-City.mmdb (61 MB)
  ✅ Lookups: Working (test: 8.8.8.8 → US)

Overall Status: ✅ HEALTHY (2 warnings)
```

### Generate Reports

```bash
# Terminal report
nftban health report terminal

# HTML report (saved to file)
nftban health report html

# Output:
HTML report generated: /var/log/nftban/reports/health-20251027-143022.html

# JSON report (for automation)
nftban health report json
```

### Auto-Heal Mode (NEW in v0.10.0)

```bash
# Run health check with automatic fixing
sudo nftban health check --auto-heal

# Output:
Running NFTBan system health check...
Auto-heal: ENABLED

... (health checks run) ...

═══════════════════════════════════════════════════════════
  Auto-Heal Activated
═══════════════════════════════════════════════════════════

→ Fixing directories...
  ✓ Created /var/lib/nftban/exports (750 nftban:nftban)

→ Fixing permissions...
  ✓ Fixed /etc/nftban → 750 root:nftban

→ Fixing system config...
  ✓ Updated /var/lib/nftban/config/system.conf

→ Fixing services...
  ✓ All services already running

✅ Auto-heal complete (3 fixes applied)

→ Re-checking system health...

... (verification checks run) ...

Overall Status: ✅ OK
```

**Requirements:**
- Must run as root (requires chown/chmod privileges)
- Logs all fixes to `/var/lib/nftban/permissions_audit.log`
- Re-checks system after fixes to verify success
- Use `--quiet` flag for cron/timer usage

**Quiet Mode for Automation:**
```bash
# Minimal output - only shows summary if issues found
sudo nftban health check --auto-heal --quiet
```

### Manual Fix (Traditional Approach)

```bash
# Fix all issues (requires root)
sudo nftban health fix all

# Output:
NFTBan Health Fix
=================

Fixing directories...
  ✅ Created: /var/log/nftban/reports
  ✅ Created: /var/lib/nftban/geoip

Fixing permissions...
  ✅ Fixed: /usr/sbin/nftban (now 755)
  ✅ Fixed: /etc/nftban/nftban.conf (now 644)

Fixing services...
  ✅ Started: nftban-daemon.service

Summary: Fixed 5 issues

# Fix specific component
sudo nftban health fix permissions
sudo nftban health fix directories
sudo nftban health fix services
```

### Component-Specific Checks

```bash
# Check only services
nftban health services

# Output:
Services Health Check
=====================
  ✅ nftables.service (active)
  ⚠️  nftban-daemon.service (inactive)

# Check only GeoIP
nftban health geoip

# Output:
GeoIP Health Check
==================
  ✅ Binary: /usr/lib/nftban/bin/nftban-geoip
  ✅ Version: 1.0.0
  ✅ Database: GeoLite2-City.mmdb (61 MB)
  ✅ Test lookup: 8.8.8.8 → United States, California, Mountain View
  ✅ Performance: 45 μs per lookup

# Check only modules
nftban health modules

# Check only binaries
nftban health binaries

# Check only permissions
nftban health permissions
```

---

## Health Checks

### 1. Binary Checks

Verifies that all required executables exist and are executable:

```bash
Binaries Checked:
- /usr/sbin/nft               # NFTables binary
- /usr/sbin/nftables          # NFTables service wrapper
- /usr/sbin/nftban            # Main CLI
- /usr/lib/nftban/bin/nftban-geoip  # GO GeoIP binary
```

**Detection Logic:**
- Checks file existence with `-f`
- Checks executable permission with `-x`
- Reports status: ✅ (exists), ❌ (missing)

### 2. Path Checks

Verifies all FHS directories exist:

```bash
Paths Checked:
Configuration:
- /etc/nftban
- /etc/nftban/conf.d
- /etc/nftban/rules.d
- /etc/nftban/zones.d

Libraries:
- /usr/lib/nftban
- /usr/lib/nftban/core
- /usr/lib/nftban/cli
- /usr/lib/nftban/modules
- /usr/lib/nftban/bin

Data:
- /usr/share/nftban
- /usr/share/nftban/templates
- /var/lib/nftban
- /var/lib/nftban/db
- /var/lib/nftban/geoip

Logs & Reports:
- /var/log/nftban
- /var/log/nftban/reports
- /var/log/nftban/daemon

Runtime:
- /run/nftban
```

**Auto-Fix:** Can create missing directories with correct permissions.

### 3. Permission Checks

Verifies file and directory permissions:

```bash
Expected Permissions:

Executables (755):
- /usr/sbin/nftban
- /usr/lib/nftban/bin/nftban-geoip
- All .sh files in /usr/lib/nftban/

Config Files (644):
- /etc/nftban/nftban.conf
- /etc/nftban/conf.d/*.conf

Directories (755):
- All directories under /usr/lib/nftban
- All directories under /etc/nftban

Secure Directories (750):
- /var/lib/nftban
- /var/log/nftban
```

**Auto-Fix:** Can correct wrong permissions automatically.

### 4. Service Checks

Verifies systemd services:

```bash
Services Checked:
- nftables.service        # Core NFTables
- nftban-daemon.service   # NFTBan daemon
- nftban-login-monitor.service  # Login alerts
```

**Detection Logic:**
- `systemctl is-active` - Check if running
- `systemctl is-enabled` - Check if enabled
- Reports: ✅ (active), ⚠️ (inactive/disabled), ❌ (not found)

**Auto-Fix:** Can start and enable services.

### 5. Module Checks

Verifies all Bash modules load correctly:

```bash
Core Modules:
- nftban_output.sh
- nftban_geoip_go.sh
- nftban_health.sh
- nftban_login_alert.sh
- ... (all core modules)

CLI Modules:
- cmd_port.sh
- cmd_module.sh
- cmd_fhs.sh
- cmd_geoip.sh
- cmd_health.sh
- cmd_login.sh
- cmd_mail.sh
```

**Detection Logic:**
- Attempts to source each module
- Checks for syntax errors with `bash -n`
- Verifies exported functions exist

### 6. GeoIP Checks

Comprehensive GeoIP system verification:

```bash
Checks:
1. Binary exists and is executable
2. Binary version matches expected
3. Database file exists
4. Database is not corrupted
5. Test lookup works
6. Performance is acceptable
```

**Test Command:**
```bash
/usr/lib/nftban/bin/nftban-geoip lookup 8.8.8.8
```

**Expected Output:**
```json
{
  "ip": "8.8.8.8",
  "country": "United States",
  "country_code": "US",
  "city": "Mountain View",
  "region": "California",
  "latitude": 37.386,
  "longitude": -122.0838
}
```

### 7. Database Checks

Verifies SQLite databases:

```bash
Databases Checked:
- /var/lib/nftban/db/nftban.db
- /var/lib/nftban/db/bans.db
- /var/lib/nftban/db/logs.db
```

**Checks:**
- File exists
- Valid SQLite3 format
- Not corrupted (integrity check)
- Schema is correct

### 8. Configuration Checks

Validates configuration files:

```bash
Config Files:
- /etc/nftban/nftban.conf
- /etc/nftban/conf.d/*.conf
```

**Checks:**
- File exists and readable
- Valid bash syntax
- Required variables are set
- No dangerous settings (e.g., DEBUG=true in production)

---

## Auto-Fix Capabilities

### What Can Be Fixed Automatically

1. **Missing Directories** - Creates with correct permissions
2. **Wrong Permissions** - Corrects to standard (755/644/750)
3. **Stopped Services** - Starts and enables them
4. **Missing GeoIP Database** - Downloads from MaxMind
5. **Corrupted Databases** - Resets schema (with backup)

### What CANNOT Be Fixed Automatically

- Missing binaries (requires installation)
- Module syntax errors (requires code fix)
- Configuration errors (requires manual review)
- Network connectivity issues

### Safety Features

- **Root Privilege Check** - Refuses to run fixes without sudo
- **Dry Run Mode** - Shows what would be fixed without making changes
- **Backup Creation** - Backs up files before modifying
- **Rollback Capability** - Can undo fixes if something goes wrong

---

## Integration Examples

### Bash Scripts

```bash
#!/bin/bash

# Source health module
source /usr/lib/nftban/core/nftban_health.sh

# Initialize
nftban_health_init

# Check GeoIP
if nftban_health_check_geoip; then
    echo "GeoIP is healthy"
else
    echo "GeoIP has issues"
    nftban_health_fix_geoip
fi

# Check all and get status
nftban_health_check_all
status=$?

if [ $status -eq 0 ]; then
    echo "All systems healthy"
elif [ $status -eq 1 ]; then
    echo "Some warnings detected"
else
    echo "Critical errors found"
    nftban_health_fix_all
fi
```

### Systemd Timer for Automated Auto-Heal

**NEW in v0.10.0:** Daily health check with auto-heal

```bash
# Timer configuration: nftban-health.timer
# Runs daily at 03:00 AM with auto-heal enabled

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true

# Enable the timer
sudo systemctl enable --now nftban-health.timer

# Check next run time
systemctl list-timers nftban-health.timer

# View logs from last run
journalctl -u nftban-health.service -n 50

# Manually trigger auto-heal
sudo systemctl start nftban-health.service
```

**What the timer does:**
- Runs `nftban health check --auto-heal --quiet` daily
- Automatically fixes permissions, directories, services, config
- Logs all fixes to audit trail
- Runs as root (required for chown/chmod)
- Minimal output (quiet mode)

### Systemd Service Integration

```bash
# In nftban-daemon.service
[Service]
ExecStartPre=/usr/sbin/nftban health check
ExecStart=/usr/lib/nftban/daemon/nftban-daemon
ExecStop=/usr/sbin/nftban health check
```

### Cron Job for Regular Checks

```bash
# /etc/cron.daily/nftban-health

#!/bin/bash
# Daily health check with auto-fix

LOG_FILE="/var/log/nftban/health-daily.log"

echo "=== NFTBan Daily Health Check ===" >> "$LOG_FILE"
date >> "$LOG_FILE"

# Run check
/usr/sbin/nftban health check >> "$LOG_FILE" 2>&1

# Auto-fix if issues found
if [ $? -ne 0 ]; then
    echo "Issues detected, attempting auto-fix..." >> "$LOG_FILE"
    /usr/sbin/nftban health fix all >> "$LOG_FILE" 2>&1
fi

# Generate HTML report
/usr/sbin/nftban health report html >> "$LOG_FILE" 2>&1

echo "" >> "$LOG_FILE"
```

### Ansible Playbook Integration

```yaml
---
- name: Verify NFTBan Health
  hosts: firewalls
  tasks:
    - name: Run health check
      command: /usr/sbin/nftban health check
      register: health_check
      failed_when: health_check.rc > 1

    - name: Auto-fix issues
      command: /usr/sbin/nftban health fix all
      when: health_check.rc != 0

    - name: Generate report
      command: /usr/sbin/nftban health report json
      register: health_report

    - name: Save report
      copy:
        content: "{{ health_report.stdout }}"
        dest: "/tmp/nftban-health-{{ inventory_hostname }}.json"
      delegate_to: localhost
```

---

## Status Codes

### Return Codes

```bash
0  - All checks passed (✅ HEALTHY)
1  - Some warnings (⚠️ WARNING)
2  - Critical errors (❌ CRITICAL)
```

### Visual Indicators

```
✅  - Component is healthy
⚠️   - Component has warnings
❌  - Component has errors
```

### Health States

| State | Code | Symbol | Meaning |
|-------|------|--------|---------|
| `HEALTH_OK` | 0 | ✅ | Everything working perfectly |
| `HEALTH_WARNING` | 1 | ⚠️ | Non-critical issues detected |
| `HEALTH_ERROR` | 2 | ❌ | Critical problems found |

---

## Configuration

### Environment Variables

```bash
# Override default paths
export NFTBAN_LIB_DIR="/opt/nftban/lib"
export NFTBAN_CONFIG_DIR="/opt/nftban/etc"
export NFTBAN_VAR_DIR="/opt/nftban/var"

# Health check behavior
export NFTBAN_HEALTH_AUTO_FIX="false"    # Disable auto-fix
export NFTBAN_HEALTH_VERBOSE="true"      # Verbose output
export NFTBAN_HEALTH_JSON="true"         # JSON output only
```

### Configuration File

Location: `/etc/nftban/conf.d/health.conf` (optional)

```bash
# Health check configuration
NFTBAN_HEALTH_AUTO_FIX="false"
NFTBAN_HEALTH_CHECK_INTERVAL="3600"      # Seconds
NFTBAN_HEALTH_REPORT_DIR="/var/log/nftban/reports"
NFTBAN_HEALTH_ALERT_EMAIL="admin@example.com"
NFTBAN_HEALTH_ALERT_ON_ERROR="true"
```

---

## Troubleshooting

### Common Issues

#### 1. "Permission denied" errors

**Problem:** Health check reports permission issues

**Solution:**
```bash
# Run fix with root privileges
sudo nftban health fix permissions

# Or manually fix
sudo chmod 755 /usr/sbin/nftban
sudo chmod 644 /etc/nftban/nftban.conf
```

#### 2. GeoIP not working

**Problem:** GeoIP checks fail

**Diagnosis:**
```bash
# Check binary
ls -la /usr/lib/nftban/bin/nftban-geoip
file /usr/lib/nftban/bin/nftban-geoip

# Check database
ls -lh /var/lib/nftban/geoip/GeoLite2-City.mmdb

# Test manually
/usr/lib/nftban/bin/nftban-geoip lookup 8.8.8.8
```

**Solution:**
```bash
# Auto-fix
sudo nftban health fix geoip

# Or manual
nftban geoip update
```

#### 3. Services not running

**Problem:** Systemd services are inactive

**Solution:**
```bash
# Auto-fix
sudo nftban health fix services

# Or manual
sudo systemctl start nftban-daemon
sudo systemctl enable nftban-daemon
```

#### 4. Module loading errors

**Problem:** Bash modules fail to load

**Diagnosis:**
```bash
# Check syntax
bash -n /usr/lib/nftban/core/nftban_health.sh

# Try loading manually
source /usr/lib/nftban/core/nftban_health.sh
```

**Solution:** Fix syntax errors in the problematic module.

#### 5. False positives

**Problem:** Health check reports issues that don't exist

**Investigation:**
```bash
# Run with verbose output
NFTBAN_HEALTH_VERBOSE=true nftban health check

# Check individual components
nftban health binaries
nftban health paths
nftban health geoip
```

### Debug Mode

```bash
# Enable debug output
export NFTBAN_DEBUG=1
nftban health check

# Check logs
tail -f /var/log/nftban/health.log
journalctl -u nftban-health -f
```

---

## Performance

### Typical Check Times

```
Full health check:     200-500 ms
Binary checks:         10-20 ms
Path checks:           20-30 ms
Permission checks:     30-50 ms
Service checks:        50-100 ms
Module checks:         20-40 ms
GeoIP checks:          10-20 ms
Database checks:       30-50 ms
Config checks:         10-20 ms
```

### Optimization Tips

1. **Skip unnecessary checks** - Use component-specific commands
2. **Run checks in parallel** - Use background jobs for independent checks
3. **Cache results** - Store check results for reuse
4. **Adjust frequency** - Don't check too often

---

## Best Practices

1. **Run Regular Checks** - Daily cron job recommended
2. **Auto-Fix with Caution** - Review what will be fixed first
3. **Monitor Logs** - Check `/var/log/nftban/health.log`
4. **Generate Reports** - HTML reports for management
5. **Alert on Errors** - Send email on critical issues
6. **Pre-Deployment Checks** - Always check before deploying
7. **Post-Deployment Verification** - Verify after updates
8. **Document Custom Paths** - If using non-standard locations

---

## Related Documentation

- [GO_GEOIP_MODULE.md](GO_GEOIP_MODULE.md) - GeoIP system details
- [LOGIN_ALERT_SYSTEM.md](LOGIN_ALERT_SYSTEM.md) - Login monitoring
- [BASH_COMPLETION.md](BASH_COMPLETION.md) - TAB completion
- [FHS_STRUCTURE.md](FHS_STRUCTURE.md) - Directory layout

---

**nftban — Simplifying Linux Firewall Management**

https://nftban.com
