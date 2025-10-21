# NFTBan Safety Module

**File:** `lib/nftban_safety_module.sh`  
**Version:** 2.0.0 (v0.9.0 Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Comprehensive safety verification and initialization safeguards with 18 risk checks

---

## Overview

The Safety Module provides comprehensive system verification, risk assessment, and initialization safeguards to prevent lockout scenarios and ensure NFTBan operates correctly. It implements 18 distinct safety checks covering everything from nftables service status to configuration file integrity, rule order verification, and lockout prevention.

The v2.0.0 release introduces split-table architecture support (separate IPv4/IPv6 tables), enhanced initialization safeguards that automatically protect critical IPs, and three levels of safety verification (quick, basic 8-check, comprehensive 18-check). The module serves as the quality assurance layer for the entire NFTBan system.

All safety checks are designed to be non-destructive—they identify issues and provide remediation guidance without making changes (except during initialization safeguards). The module integrates with initialization workflows to automatically protect localhost, server IPs, public IPs, and the current administrator's IP before the system becomes operational.

---

## Key Functions

### Public Functions (Exported) - Risk Detection

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_check_nftables_running()` | Verify nftables service operational | None | 0 if running, 1 if not |
| `nftban_check_nft_set_capacity()` | Check if set approaching capacity | `$1` - set name, `$2` - IP version | 0 if OK, 1 if near limit |
| `nftban_check_nft_duplicates()` | Check for duplicate IPs across sets | `$1` - IP version (4/6) | 0 if OK, 1 if duplicates found |
| `nftban_check_file_permissions()` | Verify file permissions correct | None | 0 if OK, count of issues |
| `nftban_check_disk_space()` | Check disk space on /etc and /var | None | 0 if OK, 1 if critical |
| `nftban_check_lock()` | Acquire process lock (race prevention) | None | 0 if acquired, 1 if conflict |
| `nftban_release_lock()` | Release process lock | None | Always succeeds |
| `nftban_check_config_integrity()` | Verify config files not corrupted | None | 0 if OK, count of issues |
| `nftban_check_nft_rules_order()` | Verify whitelist before ban rules | None | 0 if correct, 1 if wrong |
| `nftban_check_log_size()` | Check for oversized log files | None | Prints warnings |
| `nftban_check_private_ranges()` | Check if private IPs protected | None | Prints warnings |

### Public Functions (Exported) - Safeguards & Verification

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_init_safeguards()` | Apply initialization protections | None | 0 on success, 1 on failure |
| `nftban_check_safeguards()` | Basic 8-check verification | None | 0 if OK, 1 if issues |
| `nftban_check_all_risks()` | Comprehensive 18-check assessment | None | 0 if OK, 1 if critical issues |
| `nftban_quick_safety_check()` | Silent quick check (for cron) | None | Count of critical failures |
| `nftban_check_ip_location()` | Enhanced IP location report | `$1` - IP address | 0 on success |

---

## Configuration Variables

No module-specific configuration variables. Uses configuration from core and other modules.

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging, IP validation, utilities
- `nftban_nftables_module.sh` - nftables operations
- `nftban_whitelist_module.sh` - Whitelist checks and operations

**External Commands (Required):**
- `nft` - nftables command
- `systemctl` - Service management
- `stat` - File statistics
- `df` - Disk space
- `ip` - Network interface queries
- `grep`, `awk`, `sed` - Text processing
- `file` - File type detection
- `date` - Timestamp generation

**External Commands (Optional):**
- None

---

## Usage Examples

### Example 1: Basic Safety Check (8 Checks)
```bash
# Run basic safety verification
nftban_check_safeguards

# Expected output:
# ══════════════════════════════════════════════════════
#  NFTBAN SAFETY VERIFICATION
# ══════════════════════════════════════════════════════
#
# [1/8] Localhost Protection
#   Checking 127.0.0.1... ✓ PROTECTED
#   Checking ::1... ✓ PROTECTED
#
# [2/8] Server IP Protection
#   ✓ ALL 4 SERVER IPS PROTECTED
#
# [3/8] Current User IP Protection
#   Current IP: 203.0.113.50... ✓ PROTECTED
#
# [4/8] nftables Status
#   Checking table... ✓ TABLE EXISTS
#
# [5/8] Required nftables Sets
#   ✓ ALL 10 SETS EXIST
#
# [6/8] Whitelist Synchronization
#   ✓ SYNCED (files: 15, nft: 15)
#
# [7/8] Configuration Files
#   ✓ System Whitelist
#   ✓ User Whitelist
#   ✓ Persistent Blacklist
#   ✓ User Blacklist
#
# [8/8] Conflict Detection
#   ✓ NO CONFLICTS DETECTED
#
# ══════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════
#
# ✓ ALL CHECKS PASSED
#
# Your nftban installation is secure and properly configured.
```

### Example 2: Comprehensive Risk Assessment (18 Checks)
```bash
# Run full 18-check risk assessment
nftban_check_all_risks

# Expected output:
# ══════════════════════════════════════════════════════
#  COMPREHENSIVE RISK ASSESSMENT
# ══════════════════════════════════════════════════════
#
# [1/10] nftables Service Status
#   ✓ RUNNING
#
# [2/10] nftables Set Capacity
#   ✓ OK
#
# [3/10] Duplicate Detection
#   ✓ NO DUPLICATES
#
# [4/10] File Permissions
#   ✓ CORRECT
#
# [5/10] Disk Space
#   ✓ SUFFICIENT
#
# [6/10] Process Lock
#   ✓ NO CONFLICTS
#
# [7/10] Configuration Integrity
#   ✓ VALID
#
# [8/10] nftables Rule Order
#   ✓ CORRECT ORDER
#
# [9/10] Log File Size
#   ✓ CHECKED
#
# [10/10] Private IP Protection
#   ✓ CHECKED
#
# ══════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════
#
# ✓ ALL CHECKS PASSED
```

### Example 3: Initialization Safeguards
```bash
# Apply comprehensive initialization safeguards
nftban_init_safeguards

# Expected output:
# [INFO] Applying initialization safeguards...
#
# [INFO] Step 1/5: Protecting localhost...
# [SUCCESS] Protected localhost: 127.0.0.1
# [SUCCESS] Protected localhost: ::1
#
# [INFO] Step 2/5: Protecting server interface IPs...
# [SUCCESS] Protected server IP: 192.168.1.100
# [SUCCESS] Protected server IP: 10.0.0.1
#
# [INFO] Step 3/5: Detecting and protecting public IPs...
# [SUCCESS] Protected public IPv4: 203.0.113.42
# [SUCCESS] Protected public IPv6: 2001:db8::1
#
# [INFO] Step 4/5: Protecting current admin user IP...
# [SUCCESS] Protected current user IP: 203.0.113.50
# ⚠️  IMPORTANT: Your IP (203.0.113.50) has been whitelisted to prevent lockout
#
# [INFO] Step 5/5: Syncing protections to nftables...
# [SUCCESS] Synced to nftables: 15 IPv4, 3 IPv6
#
# [INFO] Verifying critical protections...
# [SUCCESS] All safeguards applied successfully (6 new protections)

# Process:
# 1. Protects localhost (127.0.0.1, ::1)
# 2. Detects and protects ALL server interface IPs
# 3. Detects and protects public IPv4/IPv6
# 4. Detects and protects current SSH user
# 5. Syncs all protections to nftables
# 6. Verifies critical protections worked
```

### Example 4: Quick Safety Check (Silent, for Cron)
```bash
# Quick silent check - only reports failures
nftban_quick_safety_check

# If all OK:
# (no output, exit code 0)

# If issues found:
# CRITICAL: Localhost not protected
# WARNING: Server IP not protected: 192.168.1.100
# CRITICAL: Current user IP not protected: 203.0.113.50
# CRITICAL: nftables table missing
# (exit code = count of critical failures)

# Use in cron:
# */15 * * * * /usr/local/bin/nftban quick-safety-check || \
#   mail -s "nftban Safety Alert" admin@example.com
```

### Example 5: Check Specific Risk - nftables Running
```bash
# Check if nftables service is operational
if nftban_check_nftables_running; then
    echo "nftables is running and functional"
else
    echo "nftables is NOT running or not functional"
    # Take corrective action
    systemctl start nftables
fi

# Checks:
# 1. nft command exists
# 2. nftables service active (optional warning)
# 3. nft list tables works
```

### Example 6: Check Specific Risk - Set Capacity
```bash
# Check if whitelist set approaching capacity limit
if nftban_check_nft_set_capacity "whitelist" "4"; then
    echo "Whitelist capacity OK"
else
    echo "Whitelist approaching capacity limit!"
    # Current count displayed in warning
fi

# Warns if set has >50,000 elements
# nftables default limit: ~65,535 elements per set
```

### Example 7: Check Specific Risk - Duplicate IPs
```bash
# Check for duplicate IPs across all sets (IPv4)
if nftban_check_nft_duplicates "4"; then
    echo "No duplicates found"
else
    echo "Duplicate IPs found across sets!"
fi

# Checks all sets:
# - whitelist
# - temp_ban
# - user_blacklist
# - system_blacklist
# - feeds
#
# Duplicates indicate:
# - Configuration error
# - Sync issues
# - Race conditions
```

### Example 8: Check Specific Risk - File Permissions
```bash
# Verify all config files have correct permissions
if nftban_check_file_permissions; then
    echo "All file permissions correct"
else
    echo "File permission issues found"
fi

# Checks:
# - Files are writable by root
# - Permissions are 644 or 600
# - Log directory is writable
#
# Critical files checked:
# - whitelist-system.conf
# - whitelist-user.conf
# - blacklist-persistent.conf
# - blacklist-user.conf
```

### Example 9: Check Specific Risk - Disk Space
```bash
# Check disk space on /etc and /var
if nftban_check_disk_space; then
    echo "Disk space sufficient"
else
    echo "Disk space critical!"
fi

# Thresholds:
# - >90% usage: CRITICAL (returns 1)
# - >80% usage: WARNING (returns 0 but logs warning)
# - <80% usage: OK (returns 0, no output)
```

### Example 10: Check Specific Risk - Process Lock
```bash
# Acquire process lock to prevent race conditions
if nftban_check_lock; then
    echo "Lock acquired - safe to proceed"
    
    # Do work here
    # ...
    
    # Always release lock when done
    nftban_release_lock
else
    echo "Another nftban process is running"
    exit 1
fi

# Lock behavior:
# - Waits up to 5 seconds for existing lock
# - Checks if lock process still alive (stale lock detection)
# - Creates lock with current PID
# - Prevents concurrent modifications
```

### Example 11: Check Specific Risk - Config Integrity
```bash
# Verify configuration files not corrupted
if nftban_check_config_integrity; then
    echo "All config files valid"
else
    echo "Config corruption detected!"
fi

# Checks:
# - Files are text (not binary/corrupted)
# - No invalid IP format entries
# - Syntax validation
#
# Reports:
# - Corrupted files
# - Count of invalid entries per file
```

### Example 12: Check Specific Risk - Rule Order
```bash
# Verify whitelist rules come BEFORE ban rules
if nftban_check_nft_rules_order; then
    echo "Rule order correct"
else
    echo "CRITICAL: Whitelist rules after ban rules!"
    echo "Whitelisted IPs can still be blocked!"
fi

# Critical check:
# - Whitelist rules MUST be before ban rules
# - Otherwise whitelisted IPs can be banned
# - This would break the entire whitelist system
```

### Example 13: Enhanced IP Location Check
```bash
# Check where an IP exists and its protection status
nftban_check_ip_location "192.168.1.100"

# Expected output:
# ══════════════════════════════════════════════════════
#  IP LOCATION CHECK: 192.168.1.100
# ══════════════════════════════════════════════════════
#
# Found in:
#   • nftables:whitelist_v4
#   • file:whitelist-system
#   • server:interface
#
# Protection Status:
#   Whitelisted: YES ✓
#   Can be banned: NO (whitelisted)
#
# Special Status:
#   • Server interface IP (auto-protected)
```

### Example 14: Detect Safety Issues
```bash
# Run basic check and capture issues
nftban_check_safeguards

# If issues found:
# ══════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════
#
# ✗ CRITICAL: 2 issue(s) found
# ⚠ 1 warning(s) found
#
# RECOMMENDED ACTIONS:
#   1. Run: nftban init --safeguards
#   2. Run: nftban whitelist sync
#   3. Re-run: nftban check-safety
```

---

## 18 Risk Checks Explained

### Risk 1: nftables Service Not Running
**Impact:** Complete system failure, no filtering  
**Check:** Service status, `nft` command functionality  
**Remediation:** `systemctl start nftables`

### Risk 2: nftables Set Full
**Impact:** Cannot add more IPs, bans fail  
**Check:** Element count vs capacity (warns at >50,000)  
**Remediation:** Clean old entries, increase limits

### Risk 3: Duplicate IPs Across Sets
**Impact:** Wasted memory, confusion, sync issues  
**Check:** Finds same IP in multiple sets  
**Remediation:** Remove duplicates, fix sync

### Risk 4: File Permissions Wrong
**Impact:** Cannot write configs, access denied  
**Check:** Writability, permission mode  
**Remediation:** `chmod 644`, `chown root:root`

### Risk 5: Disk Space Low
**Impact:** Cannot write logs/configs, system fails  
**Check:** Usage on /etc and /var partitions  
**Remediation:** Clean logs, expand partition

### Risk 6: Race Condition (Multiple Processes)
**Impact:** File corruption, duplicate operations  
**Check:** Process lock file existence  
**Remediation:** Wait for lock, kill stale processes

### Risk 7: Corrupted Configuration Files
**Impact:** Cannot parse configs, errors on load  
**Check:** Binary data, invalid IP formats  
**Remediation:** Restore from backup, re-initialize

### Risk 8: nftables Rule Order Wrong
**Impact:** Whitelisted IPs can be banned (CRITICAL)  
**Check:** Whitelist rules before ban rules  
**Remediation:** Re-apply rules in correct order

### Risk 9: Log Files Too Large
**Impact:** Slow operations, disk space issues  
**Check:** File size >100MB  
**Remediation:** Rotate logs, clean old entries

### Risk 10: Private IP Ranges Not Protected
**Impact:** Can ban internal network IPs  
**Check:** 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16  
**Remediation:** Whitelist private ranges

### Risks 11-18 (Integrated into Basic/Comprehensive Checks)
- Localhost not protected
- Server IPs not protected
- Current user IP not protected
- nftables table missing
- Required sets missing
- Whitelist out of sync
- Configuration files missing
- Conflicting entries (IP in both whitelist and blacklist)

---

## File Operations

**Reads from:**
- `/etc/nftban/config/whitelist-system.conf` - System whitelist
- `/etc/nftban/config/whitelist-user.conf` - User whitelist
- `/etc/nftban/config/blacklist-persistent.conf` - Persistent blacklist
- `/etc/nftban/config/blacklist-user.conf` - User blacklist
- `/var/lock/nftban.lock` - Process lock file
- `/var/log/nftban/*.log` - Log files (for size check)

**Writes to:**
- `/etc/nftban/config/whitelist-system.conf` - During initialization safeguards
- `/etc/nftban/config/whitelist-user.conf` - During initialization safeguards
- `/var/lock/nftban.lock` - Process lock creation

**nftables Access:**
- Reads from tables: `ip nftban_v4`, `ip6 nftban_v6`
- Queries all sets: `whitelist`, `temp_ban`, `user_blacklist`, `system_blacklist`, `feeds`
- Queries chains: `input`, `output`
- Operations: `nft list tables`, `nft list set`, `nft list chain`

**System Access:**
- `systemctl is-active nftables` - Service status
- `df /etc /var` - Disk space
- `stat` - File permissions and size
- `file` - File type detection
- `ip -o addr show` - Network interfaces

---

## Security Considerations

### Initialization Safeguards (5-Step Protection)

**Step 1: Localhost Protection**
- Always whitelists 127.0.0.1 and ::1
- Prevents accidental system breakage
- Critical for local services

**Step 2: Server IP Protection**
- Detects ALL network interfaces
- Protects each interface IP
- Prevents self-lockout via interface bans

**Step 3: Public IP Protection**
- Queries external services for public IPs
- Protects IPv4 and IPv6 public addresses
- Prevents lockout when behind NAT

**Step 4: Current User Protection**
- Detects SSH client IP
- Auto-whitelists administrator
- Prevents immediate lockout
- Shows prominent warning

**Step 5: Verification**
- Verifies all protections actually worked
- Tests whitelist checks for critical IPs
- Fails initialization if verification fails

### Non-Destructive Checks

**Philosophy:**
- Checks NEVER modify system (except `nftban_init_safeguards`)
- Only report issues with remediation guidance
- Safe to run repeatedly
- No side effects

### Process Locking

**Purpose:** Prevent race conditions during concurrent operations

**Implementation:**
```bash
# Lock file: /var/lock/nftban.lock
# Contains: PID of process holding lock
# Timeout: 5 seconds wait time
# Stale lock detection: Checks if PID still exists
```

**Benefits:**
- Prevents concurrent file modifications
- Prevents duplicate nftables operations
- Detects crashed processes (stale locks)
- Auto-recovers from stale locks

### Rule Order Verification (CRITICAL)

**Why Critical:**
```bash
# Wrong order (BAD):
1. Block temp_ban set
2. Block blacklist set
3. Accept whitelist set  ← Too late!

# Whitelisted IPs will be blocked by rules 1-2

# Correct order (GOOD):
1. Accept whitelist set  ← First!
2. Block feeds set
3. Block temp_ban set
4. Block blacklist sets
```

**Check:**
- Verifies whitelist rules come before any ban rules
- Fails check if order is wrong
- Provides clear error message
- Critical for whitelist functionality

---

## Error Handling

**Common Scenarios:**

```bash
# nftables not running
nftban_check_nftables_running
# Output: [ERROR] CRITICAL: nft command not found - nftables not installed!
# Returns: 1

# Set near capacity
nftban_check_nft_set_capacity "temp_ban" "4"
# Output: [WARNING] Set temp_ban has 52000 elements (approaching limit!)
# Returns: 1

# Duplicate IPs found
nftban_check_nft_duplicates "4"
# Output: [WARNING] Found 5 duplicate IPs across nftables sets (IPv4)
# Returns: 1

# File permission issue
nftban_check_file_permissions
# Output: [ERROR] File not writable: /etc/nftban/config/whitelist-user.conf
# Returns: count of issues

# Disk space critical
nftban_check_disk_space
# Output: [ERROR] CRITICAL: /var partition 95% full!
# Returns: 1

# Process lock conflict
nftban_check_lock
# Output: [ERROR] Another nftban process is running (PID: 12345)
# Returns: 1

# Config corruption
nftban_check_config_integrity
# Output: [ERROR] File appears corrupted: whitelist-user.conf
# Output: [WARNING] File has 3 invalid entries: blacklist-user.conf
# Returns: count of issues

# Wrong rule order (CRITICAL)
nftban_check_nft_rules_order
# Output: [ERROR] CRITICAL: Ban rules come before whitelist rules!
# Output: [ERROR] This means whitelisted IPs can still be blocked!
# Returns: 1
```

**Exit Codes:**
- `0` - All checks passed OR warnings only
- `1` - Critical issues found
- Count - Number of issues (for some functions)

**Error Recovery:**
- Most issues have clear remediation steps
- Automated fix available via `nftban init --safeguards`
- Backup/restore procedures documented
- Step-by-step guidance in output

---

## Integration Points

**Called by:**
- `nftban init` - During system initialization (runs safeguards)
- `nftban_main_cli.sh` - For CLI commands (`nftban check-safety`, `nftban verify`)
- Installation scripts - Post-installation verification
- Cron jobs - Periodic safety monitoring
- Automated monitoring systems - Health checks

**Calls:**
- `nftban_core.sh` functions - Logging, IP validation, utilities
- `nftban_whitelist_module.sh` - `nftban_whitelist_check_ip()`, `nftban_whitelist_sync_to_nftables()`
- `nftban_nftables_module.sh` - `nftban_check_nftables_table()`
- External: `nft`, `systemctl`, `stat`, `df`, `ip`, `file`

**Provides Services For:**
- System initialization - Safeguards
- Periodic monitoring - Quick checks
- Troubleshooting - Comprehensive assessment
- Audit compliance - Safety verification

---

## Performance Characteristics

### Check Speed
- **Quick check:** ~50-100ms (4 critical checks)
- **Basic check (8):** ~200-500ms (full verification)
- **Comprehensive (18):** ~1-3 seconds (thorough assessment)
- **Individual checks:** <50ms each

### Initialization Safeguards
- **Speed:** ~2-5 seconds
- **Depends on:** Network speed (public IP detection), number of interfaces
- **One-time:** Only runs during initialization

### Resource Usage
- **CPU:** Minimal (<1% during checks)
- **Memory:** <10MB
- **Disk I/O:** Reads only (no writes except safeguards)
- **Network:** Optional (public IP detection)

---

## Change Log

### Version 2.0.0 (2025-10-20) - Split Table Architecture
- **BREAKING:** Updated for split `ip nftban_v4` and `ip6 nftban_v6` tables
- Removed `_v4`/`_v6` suffixes from set names in checks
- Enhanced initialization safeguards with 5-step process
- Added verification step to initialization
- Improved error messages with clear remediation steps
- Added `nftban_check_ip_location()` for enhanced IP reports
- All 18 checks now support split-table architecture
- Enhanced duplicate detection across both tables

### Version 1.x (v0.8.5 - Legacy)
- Unified `inet nftban_global` table
- Basic safety checks
- Initialization safeguards

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core utilities
- `nftban_nftables_module.sh` - nftables infrastructure
- `nftban_whitelist_module.sh` - Whitelist operations (used by safeguards)
- `nftban_ipprotect_module.sh` - Additional IP protection

**Related Documentation:**
- `SAFETY_CHECKS.md` - Complete safety check reference
- `LOCKOUT_PREVENTION.md` - Lockout prevention guide
- `INITIALIZATION.md` - Initialization procedures
- `TROUBLESHOOTING.md` - Problem resolution guide

**CLI Commands:**
```bash
# Basic safety check (8 checks)
nftban check-safety
nftban verify

# Comprehensive assessment (18 checks)
nftban check-all-risks

# Quick check (silent, for cron)
nftban quick-safety-check

# Apply initialization safeguards
sudo nftban init --safeguards

# Enhanced IP location check
nftban check-ip <IP_ADDRESS>
```

**Cron Integration:**
```bash
# Add to crontab for periodic monitoring
# Check every 15 minutes
*/15 * * * * /usr/local/bin/nftban quick-safety-check || \
  mail -s "nftban Safety Alert on $(hostname)" admin@example.com

# Daily comprehensive check
0 2 * * * /usr/local/bin/nftban check-all-risks > \
  /var/log/nftban/daily-check-$(date +\%Y\%m\%d).log
```
