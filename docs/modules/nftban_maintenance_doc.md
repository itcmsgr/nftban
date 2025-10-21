# NFTBan Maintenance Module

**File:** `lib/nftban_maintenance_module.sh`  
**Version:** 2.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** System maintenance, cleanup, health checks, and comprehensive management panel

---

## Overview

The Maintenance Module provides comprehensive system maintenance, health monitoring, automated cleanup, and a visual management panel. It handles routine maintenance tasks like log rotation, database optimization, configuration validation, backup management, and automated cron scheduling.

Version 2.0.0 introduces a sophisticated maintenance panel UI that displays system health, version information, file integrity status, backup information, and current statistics in a unified dashboard.

Key features include interactive maintenance panel with real-time status, automated maintenance tasks via cron (runs every 6 hours), log rotation and cleanup (10MB threshold), database optimization and compaction, configuration validation and automatic repair, backup creation and management, comprehensive health checks with issue detection, and service management (nftables, fail2ban).

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_maintenance_show_panel()` | Display comprehensive management panel | None | Interactive display |
| `nftban_maintenance_run()` | Run all maintenance tasks | None | 0 on success |
| `nftban_maintenance_cleanup_logs()` | Clean and rotate old logs | `$1` - days to keep (default: 30) | 0 on success |
| `nftban_maintenance_health_check()` | Quick health check | None | Issue count |
| `nftban_maintenance_health_check_detailed()` | Comprehensive health check | None | Issue count |
| `nftban_maintenance_optimize_database()` | Optimize databases | None | 0 on success |
| `nftban_maintenance_install_cron()` | Install maintenance cron job | None | 0 on success |
| `nftban_maintenance_uninstall_cron()` | Remove maintenance cron job | None | 0 on success |
| `nftban_maintenance_cron_status()` | Show cron job status | None | Display status |
| `nftban_maintenance_create_backup()` | Create system backup | `$1` - backup name (optional) | Backup file path |
| `nftban_maintenance_list_backups()` | List available backups | None | Display list |
| `nftban_maintenance_validate_config()` | Validate configuration files | None | 0 if valid, 1 if errors |
| `nftban_maintenance_repair_config()` | Repair configuration issues | None | 0 on success |
| `nftban_maintenance_show_stats()` | Display system statistics | None | Display stats |
| `nftban_service_control()` | Control services | `$1` - action<br>`$2` - service | 0 on success |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_maintenance_clean_rate_limit()` | Clean rate limit tracker | Removes entries >1 hour old |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_MAINTENANCE_LOG` | `${NFTBAN_LOG_DIR}/maintenance.log` | Maintenance activity log |
| `NFTBAN_MAINTENANCE_SCRIPT` | `${NFTBAN_BASE_DIR}/scripts/nftban-maintenance-cron.sh` | Cron script path |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_nftables_module.sh` - nftables operations
- `nftban_whitelist_module.sh` - Whitelist validation
- `nftban_update_module.sh` - Version checking (optional)
- `nftban_search_module.sh` - Search index rebuild (optional)

**External Commands:**
- `systemctl` - Service management (required)
- `crontab` - Cron job management (required)
- `tar`, `gzip` - Backup creation (required)
- `nft` - nftables queries (required)
- `find` - File cleanup (required)

---

## Usage Examples

### Example 1: View Maintenance Panel
```bash
nftban maintenance panel

# Expected output:
# ╔════════════════════════════════════════════════════════════════════════╗
# ║                    NFTBan Maintenance Panel                            ║
# ╚════════════════════════════════════════════════════════════════════════╝
#
# ─── Version Information ───
#
#   Current Version:    0.9.0
#   Remote Version:     0.9.1
#   Status:             ⚠ UPDATE AVAILABLE
#
# ─── File Integrity Status ───
#
#   Total Files:        45
#   Core Modules:       8 / 8
#   Missing Files:      0 ✓
#   Full validation:    Run 'nftban validate status'
#
# ─── System Health ───
#
#   nftables:           ✓ Active
#   Fail2Ban:           ✓ Running
#   Disk Space:         ✓ OK
#   Log Directory Size: 23M
#
# ─── Backup Information ───
#
#   Total Backups:      5
#   Last Backup:        2025-10-20 10:30:15
#
# ─── Current Statistics ───
#
#   Temporary Bans:     23
#   Permanent Bans:     145
#   Whitelisted IPs:    67
#
# ─── Quick Actions ───
#
#   ⚠ Update available: 0.9.0 → 0.9.1
#     Run: sudo nftban update perform
#
#   Commands:
#     nftban update check         - Check for updates
#     nftban validate status      - Full integrity check
#     nftban maintenance health   - Detailed health check
#     nftban maintenance backup   - Create backup
#     nftban status               - System status
#
# ╚════════════════════════════════════════════════════════════════════════╝
```

### Example 2: Run Maintenance Tasks
```bash
nftban maintenance run

# Expected output:
# [INFO] Running maintenance tasks...
# [DEBUG] Cleaned rate limit tracker
# [INFO] Cleaning logs older than 30 days...
# [SUCCESS] Log cleanup completed: 2 files rotated
# [INFO] Running health check...
# [SUCCESS] Health check passed
# [INFO] Rebuilding search index...
# [SUCCESS] Search index rebuilt
# [SUCCESS] Maintenance completed in 5s
```

### Example 3: Comprehensive Health Check
```bash
nftban maintenance health

# Expected output:
# [INFO] Performing comprehensive health check...
#
# ═══════════════════════════════════════════════════════════════
#   NFTBan Comprehensive Health Check
# ═══════════════════════════════════════════════════════════════
#
# Services:
#   ✅ nftables: Active
#   ✅ fail2ban: Active
#
# NFTables:
#   ✅ Ruleset readable
#   ℹ️  IPv4 tables: 1
#   ℹ️  IPv6 tables: 1
#
# Fail2ban:
#   ℹ️  Total jails: 3
#   ℹ️  NFTBan jails: 2
#   ℹ️  Currently banned: 15 IPs
#
# Disk Space:
#   ✅ Usage: 45%
#   ℹ️  Available: 25G
#
# Log Files:
#   ℹ️  Total size: 23M
#   ✅ No large log files
#
# Critical Files:
#   ✅ nftban_core.sh
#   ✅ nftban_main_cli.sh
#   ✅ nftban
#   ✅ user-whitelist_ips.conf
#   ✅ user-blacklist_ips.conf
#
# Security Checks:
#   ✅ Localhost whitelisted (127.0.0.1)
#   ✅ Localhost whitelisted (::1)
#
# ═══════════════════════════════════════════════════════════════
#   ✅ Health check PASSED
# ═══════════════════════════════════════════════════════════════
```

### Example 4: Install Automated Maintenance
```bash
nftban maintenance cron-install

# Expected output:
# [INFO] Installing maintenance cron job...
# [SUCCESS] Cron job installed (runs every 6 hours)
#
# Maintenance cron job installed:
#   Script: /etc/nftban/scripts/nftban-maintenance-cron.sh
#   Schedule: Every 6 hours
#   View: crontab -l | grep nftban

# Verify installation
nftban maintenance cron-status

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Maintenance Cron Status
# ═══════════════════════════════════════════════════════════════
#
# ✓ Cron job installed
#
# Schedule:
#   0 */6 * * * /etc/nftban/scripts/nftban-maintenance-cron.sh >/dev/null 2>&1
#
# Script: /etc/nftban/scripts/nftban-maintenance-cron.sh
#
# Last run:
#   [2025-10-20 12:00:15] Maintenance completed (5s)
```

### Example 5: Create Backup
```bash
nftban maintenance backup

# Expected output:
# [INFO] Creating backup: nftban-backup-20251020-143215
# [SUCCESS] Backup created: /var/lib/nftban/backups/nftban-backup-20251020-143215.tar.gz
# /var/lib/nftban/backups/nftban-backup-20251020-143215.tar.gz

# List all backups
nftban maintenance list-backups

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Available Backups
# ═══════════════════════════════════════════════════════════════
#
#   1. nftban-backup-20251020-143215.tar.gz           2.3M  2025-10-20
#   2. nftban-backup-20251019-120000.tar.gz           2.1M  2025-10-19
#   3. pre_update_0.8.9_20251015_100530.tar.gz        2.0M  2025-10-15
#   4. nftban-backup-20251010-080000.tar.gz           1.9M  2025-10-10
#   5. nftban-backup-20251005-143000.tar.gz           1.8M  2025-10-05
```

### Example 6: Validate and Repair Configuration
```bash
# Validate configuration
nftban maintenance validate

# Expected output:
# [INFO] Validating NFTBan configuration...
# [SUCCESS] Configuration syntax valid
# [SUCCESS] NFTables configuration valid
# [SUCCESS] Fail2ban configuration valid
# [SUCCESS] Configuration validation passed

# If issues found, repair automatically
nftban maintenance repair

# Expected output:
# [INFO] Repairing NFTBan configuration...
# [SUCCESS] Recreated directory: /var/cache/nftban
# [SUCCESS] Recreated whitelist file
# [INFO] Fixing permissions...
# [SUCCESS] Configuration repair completed
```

### Example 7: Service Management
```bash
# Restart all services
nftban maintenance service restart all

# Control specific service
nftban maintenance service status nftables
nftban maintenance service reload fail2ban

# Enable services at boot
nftban maintenance service enable all
```

### Example 8: View Statistics
```bash
nftban maintenance stats

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   NFTBan System Statistics
# ═══════════════════════════════════════════════════════════════
#
# Configuration:
#   Enabled features: 8
#   Whitelisted IPs: 67
#   Blacklisted IPs: 145
#
# Ban Statistics:
#   Total bans recorded: 1,523
#   Bans today: 23
#
#   Top 5 banned IPs:
#     192.0.2.100: 45 times
#     198.51.100.50: 32 times
#     203.0.113.75: 28 times
#     45.67.89.10: 21 times
#     123.45.67.89: 18 times
#
# Service Status:
#   nftables: Active
#   fail2ban: Active
#
#   NFTBan tables (IPv4): 1
#   NFTBan tables (IPv6): 1
#
# ═══════════════════════════════════════════════════════════════
```

---

## Maintenance Panel Components

### 1. Version Information
- Current installed version
- Remote available version
- Update status (up-to-date, update available, local newer)
- Quick update command

### 2. File Integrity Status
- Total module files count
- Core modules validation (8 essential modules)
- Missing files detection
- Link to full validation

### 3. System Health
- nftables status (active/inactive)
- Fail2Ban status (running/not running)
- Disk space usage (with warning if >90%)
- Log directory size

### 4. Backup Information
- Total backups count
- Last backup timestamp
- Backup directory status

### 5. Current Statistics
- Temporary bans count (from both IPv4/IPv6 tables)
- Permanent bans count
- Whitelisted IPs count
- Real-time nftables queries

### 6. Quick Actions
- Update notification (if available)
- Commonly used commands
- Quick access links

---

## Automated Maintenance Tasks

### What Runs Automatically (Every 6 Hours)

1. **Rate Limit Cleanup**
   - Removes tracker entries older than 1 hour
   - Prevents tracker file growth

2. **Log Rotation**
   - Rotates logs larger than 10MB
   - Compresses rotated logs (.gz)
   - Deletes logs older than 30 days

3. **Health Check**
   - Verifies nftables table exists
   - Checks required directories
   - Validates localhost whitelist
   - Reports issues to log

4. **Search Index Rebuild**
   - Rebuilds if index is stale
   - Ensures fast IP lookups
   - Optional (if search module loaded)

### Maintenance Schedule

**Default Cron Entry:**
```bash
0 */6 * * * /etc/nftban/scripts/nftban-maintenance-cron.sh >/dev/null 2>&1
```

**Runs at:**
- 00:00 (midnight)
- 06:00 (6 AM)
- 12:00 (noon)
- 18:00 (6 PM)

**Customization:**
```bash
# Edit crontab directly
crontab -e

# Change schedule (example: every 12 hours)
0 */12 * * * /etc/nftban/scripts/nftban-maintenance-cron.sh >/dev/null 2>&1

# Change schedule (example: daily at 3 AM)
0 3 * * * /etc/nftban/scripts/nftban-maintenance-cron.sh >/dev/null 2>&1
```

---

## File Operations

### Reads from:
- `$NFTBAN_BASE_DIR/lib/*.sh` - Module files (integrity check)
- `$NFTBAN_CONFIG_DIR/nftban.conf.local` - Configuration validation
- `$NFTBAN_VERSION_FILE` - Version information
- `$NFTBAN_RATE_LIMIT_FILE` - Rate limit tracker (cleanup)
- `$NFTBAN_LOG_DIR/*.log` - Log files (rotation)
- `$NFTBAN_BAN_LOG` - Ban statistics
- `$NFTBAN_MAINTENANCE_LOG` - Maintenance history

### Writes to:
- `$NFTBAN_MAINTENANCE_LOG` - Maintenance activity log
- `$NFTBAN_MAINTENANCE_SCRIPT` - Auto-generated cron script
- `$NFTBAN_LOG_DIR/*.log.YYYYMMDD-HHMMSS.gz` - Rotated logs
- `${NFTBAN_DATA_DIR}/backups/*.tar.gz` - Backup archives
- `$NFTBAN_CONFIG_DIR/*.conf` - Configuration repair (if needed)

### Backup Contents:
```
nftban-backup-YYYYMMDD-HHMMSS.tar.gz
├── config/                    # All configuration files
│   ├── nftban.conf.local
│   ├── user-whitelist_ips.conf
│   ├── user-blacklist_ips.conf
│   └── ... (all config files)
├── geoip/                     # GeoIP data (if exists)
│   ├── cache/
│   └── sets/
├── nftables-backup-v4.nft     # IPv4 ruleset export
└── nftables-backup-v6.nft     # IPv6 ruleset export
```

---

## Health Check Categories

### Quick Health Check (`nftban_maintenance_health_check`)
**Checks:**
- nftables table exists
- Required directories present
- Localhost whitelisted

**Use Case:** Fast validation during maintenance runs

---

### Comprehensive Health Check (`nftban_maintenance_health_check_detailed`)
**Checks:**
- **Services:** nftables, fail2ban status
- **NFTables:** Ruleset readable, table counts
- **Fail2ban:** Jail counts, currently banned IPs
- **Disk Space:** Usage percentage, available space
- **Log Files:** Total size, large files (>100MB)
- **Critical Files:** Core modules presence
- **Security:** Localhost whitelist validation

**Use Case:** Detailed diagnostics, troubleshooting

---

## Configuration Validation

### What Gets Validated

1. **User Configuration File**
   - Exists (creates from default if missing)
   - Valid syntax (sources without errors)

2. **Essential Files**
   - `user-whitelist_ips.conf`
   - `user-blacklist_ips.conf`
   - `nftban` binary
   - Core modules (nftban_core.sh, nftban_main_cli.sh)

3. **nftables Configuration**
   - Syntax validation (`nft -c -f`)
   - Ruleset integrity

4. **Fail2ban Configuration**
   - Configuration test (`fail2ban-client --test`)
   - Jail syntax validation

---

## Configuration Repair

### What Gets Repaired

1. **Missing Directories**
   - Recreates all required directories
   - Sets correct permissions (755)

2. **Missing Configuration Files**
   - Recreates whitelist with localhost
   - Recreates blacklist (empty template)
   - Uses safe defaults

3. **Permission Fixes**
   - Directories: 755 (rwxr-xr-x)
   - Config files: 644 (rw-r--r--)
   - Library files: 644 (sourced, not executed)
   - Binary files: 755 (executed)
   - Script files: 755 (executed)
   - Log files: 644

4. **Localhost Whitelist**
   - Ensures 127.0.0.1 and ::1 are whitelisted
   - Critical safety measure

---

## Service Management

### Supported Services

1. **nftables / nft**
   - Firewall management
   - Controls: start, stop, restart, reload, enable, disable, status

2. **fail2ban / f2b**
   - Intrusion prevention
   - Controls: start, stop, restart, reload, enable, disable, status

3. **all**
   - Both services simultaneously

### Service Control Examples

```bash
# Start services
nftban_service_control start all

# Restart nftables
nftban_service_control restart nftables

# Check fail2ban status
nftban_service_control status fail2ban

# Enable at boot
nftban_service_control enable all

# Reload configuration
nftban_service_control reload all
```

---

## Performance Considerations

### Maintenance Run Time

**Typical Duration:** 3-10 seconds

**Breakdown:**
- Rate limit cleanup: <1s
- Log rotation: 1-5s (depends on log size)
- Health check: <1s
- Search index rebuild: 1-3s (if needed)

**Optimization:**
- Runs during off-peak hours (default: 00:00, 06:00, 12:00, 18:00)
- No performance impact on running system
- Background execution (cron redirects output)

### Resource Usage

**CPU:** <1% during maintenance
**Memory:** <50 MB
**Disk I/O:** Minimal (log rotation, backup creation)

---

## Troubleshooting

### Problem: Maintenance Cron Not Running

**Diagnostic:**
```bash
# Check cron job exists
crontab -l | grep nftban

# Check script exists and is executable
ls -l /etc/nftban/scripts/nftban-maintenance-cron.sh

# Check maintenance log
tail -50 /var/log/nftban/maintenance.log

# Check cron service
systemctl status cron  # Debian/Ubuntu
systemctl status crond # RHEL/CentOS
```

**Solution:**
```bash
# Reinstall cron job
nftban maintenance cron-uninstall
nftban maintenance cron-install

# Verify
nftban maintenance cron-status

# Test manual run
/etc/nftban/scripts/nftban-maintenance-cron.sh
```

---

### Problem: Health Check Fails

**Symptom:** `nftban maintenance health` reports issues

**Diagnostic:**
```bash
# Run detailed health check
nftban maintenance health

# Check specific issue
nft list tables  # nftables
systemctl status nftables fail2ban  # Services
df -h /etc/nftban  # Disk space
ls -l /etc/nftban/config/  # Config files
```

**Solution:**
```bash
# Automatic repair
nftban maintenance repair

# Manual fixes
# - nftables missing: nftban setup
# - Services inactive: nftban maintenance service start all
# - Disk full: nftban maintenance cleanup-logs 7
# - Config missing: nftban maintenance repair
```

---

### Problem: Backup Creation Fails

**Error:** "Permission denied" or "No space left"

**Diagnostic:**
```bash
# Check disk space
df -h /var/lib/nftban

# Check permissions
ls -ld /var/lib/nftban/backups

# Check existing backups
nftban maintenance list-backups
```

**Solution:**
```bash
# Create backup directory
mkdir -p /var/lib/nftban/backups
chmod 755 /var/lib/nftban/backups

# Clean old backups if space low
find /var/lib/nftban/backups -name "*.tar.gz" -mtime +30 -delete

# Retry backup
nftban maintenance backup
```

---

### Problem: Log Rotation Not Working

**Symptom:** Log files growing very large (>100MB)

**Diagnostic:**
```bash
# Check log sizes
ls -lh /var/log/nftban/

# Check rotation settings
grep "10485760" /etc/nftban/lib/nftban_maintenance_module.sh

# Check maintenance log
tail -20 /var/log/nftban/maintenance.log | grep "rotation"
```

**Solution:**
```bash
# Manual cleanup
nftban maintenance cleanup-logs 30

# Or force rotation
nftban maintenance run

# Verify
ls -lh /var/log/nftban/
```

---

## Best Practices

### ✅ DO:

1. **Install automated maintenance** immediately after setup
2. **Review maintenance panel** weekly
3. **Create backups** before major changes
4. **Run health checks** after configuration changes
5. **Monitor maintenance log** for issues
6. **Keep at least 3 backups** (use 30-day retention)
7. **Test backup restore** procedure periodically
8. **Enable services at boot** (nftables, fail2ban)
9. **Review statistics** monthly for trends
10. **Update promptly** when available

### ❌ DON'T:

1. **Don't skip automated maintenance** (critical for stability)
2. **Don't ignore health check warnings** (fix immediately)
3. **Don't delete backups manually** (use cleanup-logs)
4. **Don't modify cron script** (regenerate if needed)
5. **Don't disable services** without good reason
6. **Don't skip log rotation** (disk space issues)
7. **Don't ignore disk space warnings** (>90% is critical)
8. **Don't run maintenance manually** during peak hours
9. **Don't skip validation** after manual config edits
10. **Don't ignore localhost whitelist** (critical safety)

---

## Change Log

### Version 2.0.0 (2025-10-20) - Major Update
- Added comprehensive maintenance panel UI
- Added configuration validation and repair functions
- Added detailed health check with categorized issues
- Added service management functions
- Enhanced statistics display
- Split table support (v0.9.0 compatibility)
- Improved backup management
- Enhanced cron job management
- Better error handling and logging

### Version 1.0.0 - Initial Release
- Basic maintenance tasks
- Log rotation
- Health checks
- Cron job management
- Backup creation

---

## See Also

**Related Modules:**
- `nftban_update_module.sh` - Version checking and updates
- `nftban_stats_module.sh` - Statistics and reporting
- `nftban_search_module.sh` - Search index management
- `nftban_core.sh` - Core logging and utilities

**Related Documentation:**
- System Administration Guide
- Backup and Recovery Procedures
- Troubleshooting Guide

---

## Summary

The Maintenance Module provides complete system health management through automated maintenance, comprehensive health checks, configuration validation and repair, backup management, service control, and an interactive management panel. Essential for long-term system stability and operational excellence.