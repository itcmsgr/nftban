# NFTBan Search Module

**File:** `lib/nftban_search_module.sh`  
**Version:** 2.1.0 (Security Hardening for v0.9.0+)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Universal IP search system with TOCTOU protection and comprehensive security hardening

---

## Overview

The Search Module provides a unified, security-hardened interface for checking IP addresses across all NFTBan data sources. It searches configuration files, nftables sets, and threat feeds to determine if an IP is whitelisted, banned, or clean. This module is critical for the Fail2Ban integration and ensures that whitelisted IPs are never banned, even during high-load scenarios with concurrent operations.

The v2.1.0 release introduces comprehensive security hardening including TOCTOU (Time-Of-Check-Time-Of-Use) race condition protection via atomic flock operations, command injection prevention, regex injection protection, and IPv4-mapped IPv6 normalization. The module uses optimized O(1) nftables lookups and supports CIDR range matching for both file-based and nftables-based searches.

All search operations follow a strict priority system: whitelist (highest), temporary bans, permanent blacklist, and threat feeds (lowest). This ensures that whitelisted IPs are never affected by ban operations, providing a critical safety layer for the entire NFTBan system.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_check_whitelist()` | Fast atomic whitelist check | `$1` - IP address | 0 if whitelisted, 1 if not |
| `nftban_check_blacklist()` | Fast blacklist check | `$1` - IP address | 0 if blacklisted, 1 if not |
| `nftban_search_ip()` | Universal IP search (all sources) | `$1` - IP, `$2` - quiet mode (true/false) | Status code (10/20/30/40/0) |
| `nftban_get_ip_status()` | Get IP status as string | `$1` - IP address | String: WHITELISTED/TEMP_BANNED/PERM_BANNED/IN_FEEDS/CLEAN |
| `nftban_interactive_manage_ip()` | Interactive IP management | `$1` - IP address | Status code |

### Internal Functions (Private - Security Layer)

| Function | Purpose | Notes |
|----------|---------|-------|
| `_nftban_search_sanitize_input()` | Validate and sanitize input | **SECURITY:** Prevents command injection |
| `_nftban_search_normalize_ip()` | Normalize IPv4-mapped IPv6 | **SECURITY:** Converts ::ffff:x.x.x.x → x.x.x.x |
| `_nftban_search_validate_ip_strict()` | Strict IP validation | **SECURITY:** Uses ipcalc/sipcalc for validation |
| `_nftban_search_escape_regex()` | Escape regex metacharacters | **SECURITY:** Prevents regex injection |
| `_nftban_search_in_file()` | Search single file with flock | **SECURITY:** Atomic file read with shared lock |
| `_nftban_search_in_files()` | Search multiple files | Iterates with atomic locks |
| `_nftban_search_in_nftables_set()` | Search nftables set | **PERFORMANCE:** O(1) lookup with nft get element |
| `_nftban_search_is_ipv4()` | Check if IPv4 | Regex validation |
| `_nftban_search_is_ipv6()` | Check if IPv6 | Regex validation |
| `_nftban_search_is_cidr4()` | Check if IPv4 CIDR | Regex validation |
| `_nftban_search_is_cidr6()` | Check if IPv6 CIDR | Regex validation |
| `_nftban_search_get_ip_family()` | Detect IP family | Returns "v4", "v6", or "unknown" |
| `_nftban_search_ip_in_cidr()` | Check IP in CIDR range | Uses ipcalc for membership test |

---

## Configuration Variables

### Directory Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_SEARCH_CONFIG_DIR` | `/etc/nftban/config` | Configuration directory |
| `NFTBAN_SEARCH_FEEDS_DIR` | `/etc/nftban/config/feeds` | Threat feeds directory |
| `NFTBAN_LOCK_DIR` | `/var/lock/nftban` | Lock file directory |

### nftables Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_NFT_TABLE_V4` | `nftban_v4` | IPv4 table name |
| `NFTBAN_NFT_TABLE_V6` | `nftban_v6` | IPv6 table name |
| `NFTBAN_NFT_FAMILY_V4` | `ip` | IPv4 table family |
| `NFTBAN_NFT_FAMILY_V6` | `ip6` | IPv6 table family |

### Search Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_LOCK_TIMEOUT` | `5` | Lock timeout in seconds |
| `NFTBAN_SEARCH_STATUS_WHITELISTED` | `10` | Return code for whitelisted IP |
| `NFTBAN_SEARCH_STATUS_TEMP_BANNED` | `20` | Return code for temporary ban |
| `NFTBAN_SEARCH_STATUS_PERM_BANNED` | `30` | Return code for permanent ban |
| `NFTBAN_SEARCH_STATUS_IN_FEEDS` | `40` | Return code for threat feed match |
| `NFTBAN_SEARCH_STATUS_CLEAN` | `0` | Return code for clean IP |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and utilities

**External Commands (Required):**
- `nft` - nftables command (for set queries)
- `flock` - File locking (CRITICAL for TOCTOU protection)
- `grep` - Text pattern matching
- `awk` - Text processing
- `sed` - Text transformation
- `find` - File search (for feeds)

**External Commands (Recommended):**
- `ipcalc` or `sipcalc` - IP validation and CIDR calculations (highly recommended for production)

**External Commands (Optional):**
- Without ipcalc/sipcalc: Falls back to basic regex validation (not recommended for security-critical deployments)

---

## Usage Examples

### Example 1: Fast Whitelist Check (Fail2Ban Use)
```bash
# Called by Fail2Ban before banning
if nftban_check_whitelist "192.168.1.100"; then
    echo "IP is whitelisted - refusing to ban"
    exit 0
fi

# Expected: Returns 0 if whitelisted, 1 if not
# SECURITY: Uses atomic flock to prevent TOCTOU race conditions
```

### Example 2: Fast Blacklist Check
```bash
# Check if IP is permanently blacklisted
if nftban_check_blacklist "1.2.3.4"; then
    echo "IP is blacklisted"
    exit 1
fi

# Expected: Returns 0 if blacklisted, 1 if not
```

### Example 3: Full IP Search (Interactive)
```bash
# Complete search with formatted output
nftban_search_ip "192.168.1.100"

# Expected output:
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  IP Search Result: 192.168.1.100
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#
# Status: âœ… WHITELISTED (Protected - Cannot be banned)
#
# Found in:
#  â€¢ File: /etc/nftban/config/whitelist_ips.conf.local
#  â€¢ nftables: @whitelist (nftban_v4)
#
# IP Family: IPv4
```

### Example 4: Quiet Mode Search (Programmatic Use)
```bash
# Get just the status code without output
nftban_search_ip "1.2.3.4" true
status=$?

case $status in
    10) echo "Whitelisted" ;;
    20) echo "Temp banned" ;;
    30) echo "Perm banned" ;;
    40) echo "In threat feeds" ;;
    0)  echo "Clean" ;;
esac

# Or check specific status
if nftban_search_ip "1.2.3.4" true; [ $? -eq 10 ]; then
    echo "This IP is whitelisted"
fi
```

### Example 5: Get IP Status as String
```bash
# Get human-readable status
status=$(nftban_get_ip_status "8.8.8.8")
echo "IP status: $status"

# Expected output: CLEAN or WHITELISTED or TEMP_BANNED etc.

# Use in scripts
if [ "$(nftban_get_ip_status '192.168.1.1')" = "WHITELISTED" ]; then
    echo "Protected IP detected"
fi
```

### Example 6: IPv4-Mapped IPv6 Handling
```bash
# Search with IPv4-mapped IPv6 (automatically normalized)
nftban_search_ip "::ffff:192.168.1.100"

# Module automatically converts to: 192.168.1.100
# Searches both IPv4 and IPv6 sources
# Returns correct result based on normalized IP
```

### Example 7: CIDR Range Matching
```bash
# IP is in CIDR range in whitelist file
# File contains: 192.168.1.0/24

nftban_check_whitelist "192.168.1.50"
# Returns: 0 (whitelisted, because IP is in CIDR range)

nftban_search_ip "192.168.1.75"
# Shows: WHITELISTED (found in CIDR range)
```

### Example 8: Interactive IP Management
```bash
# Interactive management interface
nftban_interactive_manage_ip "1.2.3.4"

# Shows current status and available actions:
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Available Actions
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#
#  [1] Add to whitelist
#  [2] Add to permanent blacklist
#  [3] Ban temporarily (1 hour)
#  [q] Exit
#
# Select action: _
```

### Example 9: Error Handling and Validation
```bash
# Invalid IP address
nftban_search_ip "999.999.999.999"
# Output: Error: Invalid IP address format: 999.999.999.999
# Returns: 1

# Command injection attempt (blocked)
nftban_search_ip "192.168.1.1; rm -rf /"
# Output: ERROR: Dangerous characters detected in input
# Returns: 1

# Empty input
nftban_check_whitelist ""
# Returns: 1 (invalid)
```

### Example 10: Batch IP Checking
```bash
# Check multiple IPs
declare -a ips=("192.168.1.1" "10.0.0.1" "8.8.8.8")

for ip in "${ips[@]}"; do
    status=$(nftban_get_ip_status "$ip")
    echo "$ip: $status"
done

# Expected output:
# 192.168.1.1: WHITELISTED
# 10.0.0.1: CLEAN
# 8.8.8.8: CLEAN
```

### Example 11: Integration with Fail2Ban Action
```bash
#!/bin/bash
# Fail2Ban action script

IP="$1"

# CRITICAL: Check whitelist before banning
if nftban_check_whitelist "$IP"; then
    logger "Fail2Ban: Refusing to ban whitelisted IP: $IP"
    exit 0
fi

# Proceed with ban
nft add element ip nftban_v4 temp_ban { $IP timeout 1h }
logger "Fail2Ban: Banned IP: $IP"
```

---

## File Operations

**Reads from:**
- `/etc/nftban/config/whitelist_ips.conf` - System whitelist (read-only)
- `/etc/nftban/config/whitelist_ips.conf.local` - User whitelist
- `/etc/nftban/config/blacklist_ips.conf` - System blacklist
- `/etc/nftban/config/blacklist_ips.conf.local` - User blacklist
- `/etc/nftban/config/feeds/*-blacklist.conf` - Threat feed files

**Writes to:**
- `/var/lock/nftban/whitelist-check.lock` - Lock file for atomic operations (exclusive lock)

**nftables Access:**
- Reads from tables: `nftban_v4` (ip), `nftban_v6` (ip6)
- Queries sets: `@whitelist`, `@temp_ban`, `@perm_ban`, `@feeds`
- Uses `nft get element` for O(1) lookups
- Falls back to `nft list set` + grep for older nftables versions

---

## Security Considerations

### TOCTOU Protection (v2.1.0 - CRITICAL)
**Issue:** Time-Of-Check-Time-Of-Use race condition could allow whitelisted IPs to be banned during the window between check and ban operations.

**Example Scenario:**
```
Thread A: Check whitelist → IP not found
Thread B: Adds IP to whitelist
Thread A: Proceeds to ban → WHITELISTED IP BANNED (BUG!)
```

**Solution:** Exclusive flock on `whitelist-check.lock` during entire check operation
```bash
# Atomic operation - no modifications possible during check
flock -x -w 5 200
  check_whitelist_files()
  check_whitelist_nftables()
  return result
200> /var/lock/nftban/whitelist-check.lock
```

**Fail-Safe Behavior:** If lock cannot be acquired within timeout, REFUSE to ban (assume whitelisted). This ensures no false positives even under lock contention.

**Lock Types:**
- `nftban_check_whitelist()` - **Exclusive lock** (prevents any modifications)
- File reads - **Shared locks** (allows concurrent reads, blocks writes)

### Command Injection Prevention
**Issue:** IP parameters could contain shell metacharacters: `; | & $ \` () {} []`

**Solution:** `_nftban_search_sanitize_input()` rejects ANY dangerous characters
```bash
# Blocked inputs:
192.168.1.1; rm -rf /    # Semicolon
192.168.1.1 | cat        # Pipe
192.168.1.1 && ls        # Command chaining
192.168.1.1$(whoami)     # Command substitution
```

**Validation:** Only alphanumeric, dots, colons, slashes allowed (for IP/CIDR format only)

**Additional Protection:** Maximum input length (100 chars) prevents buffer overflow attacks

### Regex Injection Prevention
**Issue:** IP used in grep patterns could contain regex metacharacters: `. * [ ] $ ^ ( ) { } + ? |`

**Example Attack:**
```bash
# Malicious input: ".*" (matches everything)
grep ".*" whitelist.conf  # Returns all IPs as whitelisted!
```

**Solution:** `_nftban_search_escape_regex()` escapes all special characters
```bash
Input:  192.168.1.*
Escaped: 192\.168\.1\.\*
Result: Literal match only, not wildcard
```

### IPv4-Mapped IPv6 Bypass Prevention
**Issue:** `::ffff:192.168.1.1` not recognized as equivalent to `192.168.1.1`

**Attack Scenario:**
```
Whitelist: 192.168.1.1
Attacker uses: ::ffff:192.168.1.1
Old code: Not found in whitelist → BAN
New code: Normalized → Found → PROTECTED
```

**Solution:** `_nftban_search_normalize_ip()` converts before processing
```bash
::ffff:192.168.1.1  → 192.168.1.1
::192.168.1.1       → 192.168.1.1
```

**Impact:** Prevents whitelist bypass via IPv6 mapping

### File Race Conditions
**Issue:** Concurrent file reads/writes could cause data corruption or TOCTOU

**Solution:** Shared locks (flock -s) for reads, exclusive locks for writes
```bash
# Read operation (multiple readers allowed)
flock -s -w 5 200 < file.conf
  grep "..." file.conf
200< file.conf

# Write operation (exclusive access)
flock -x -w 5 200 > file.conf
  echo "..." >> file.conf
200> file.conf
```

**Timeout:** 5 seconds prevents deadlock scenarios

### Strict IP Validation
**Tools Used:**
1. **Primary:** `ipcalc` - Industry-standard IP calculator
2. **Fallback:** `sipcalc` - Alternative IP calculator
3. **Last Resort:** Regex validation (not recommended for production)

**Validation Flow:**
```bash
1. Sanitize input (reject dangerous chars)
2. Normalize (handle IPv4-mapped IPv6)
3. Validate with ipcalc/sipcalc
4. Return normalized, validated IP
```

**Why ipcalc/sipcalc?**
- Catches malformed IPs that pass regex: `192.168.256.1` (octet > 255)
- Validates CIDR prefixes: `/33` invalid for IPv4
- Handles edge cases: `0.0.0.0`, broadcast addresses, etc.

---

## Error Handling

**Common Errors:**

```bash
# Invalid IP format
ERROR: Invalid IP address format: 999.999.999.999

# Command injection attempt
ERROR: Dangerous characters detected in input: 192.168.1.1; rm -rf /

# Input too long (DoS prevention)
ERROR: Input too long (max 100 chars): 256

# IP validation failed
ERROR: IP validation failed (ipcalc): 192.168.256.1

# Lock timeout (fail-safe)
ERROR: Could not acquire whitelist lock (timeout)
# Behavior: Returns 0 (assumes whitelisted) - fail-safe

# File lock timeout (non-critical)
WARNING: Could not acquire read lock on /etc/nftban/config/whitelist_ips.conf
# Behavior: Continues with other sources

# Empty input
# Returns: 1 (invalid) without error message
```

**Exit Codes:**
- `0` (`NFTBAN_SEARCH_STATUS_CLEAN`) - IP not found in any list
- `10` (`NFTBAN_SEARCH_STATUS_WHITELISTED`) - IP is whitelisted
- `20` (`NFTBAN_SEARCH_STATUS_TEMP_BANNED`) - IP is temporarily banned
- `30` (`NFTBAN_SEARCH_STATUS_PERM_BANNED`) - IP is permanently banned
- `40` (`NFTBAN_SEARCH_STATUS_IN_FEEDS`) - IP found in threat feeds
- `1` - Error (invalid input, validation failed)

**Error Recovery:**
- Invalid IP → Returns 1, logs error
- Lock timeout → Fails safe (assumes whitelisted for critical operations)
- Missing file → Skips file, continues with other sources
- Missing nftables set → Skips set, continues with other sources

---

## Integration Points

**Called by:**
- `nftban_fail2ban_module.sh` - Before banning IPs via Fail2Ban
- `nftban_main_cli.sh` - For `nftban search <IP>` command
- `templates/fail2ban/action.d/nftban.conf` - Fail2Ban action script
- `nftban_whitelist_module.sh` - Duplicate detection during whitelist add
- `nftban_blacklist_module.sh` - Status checks before ban operations

**Calls:**
- `nftban_log_*` functions from `nftban_core.sh`
- External: `nft`, `flock`, `ipcalc`, `grep`, `awk`, `sed`, `find`
- Internal: All `_nftban_search_*` helper functions

**Exports to Environment:**
- `nftban_check_whitelist` - Available to Fail2Ban and other processes
- `nftban_check_blacklist` - Available to all processes
- `nftban_search_ip` - Available to CLI and scripts
- `nftban_get_ip_status` - Available to automation scripts
- `nftban_interactive_manage_ip` - Available to CLI

---

## Search Priority System

The module implements a strict priority hierarchy to ensure correct behavior:

### Priority 1: Whitelist (HIGHEST)
- **Files:** `whitelist_ips.conf`, `whitelist_ips.conf.local`
- **nftables:** `@whitelist` set
- **Status:** `WHITELISTED` (10)
- **Behavior:** NEVER ban, regardless of other findings
- **Protection:** Atomic check with exclusive lock

### Priority 2: Temporary Bans
- **nftables:** `@temp_ban` set (timeout-based)
- **Status:** `TEMP_BANNED` (20)
- **Behavior:** Currently banned, auto-expires
- **Note:** Only checked if not whitelisted

### Priority 3: Permanent Blacklist
- **Files:** `blacklist_ips.conf`, `blacklist_ips.conf.local`
- **nftables:** `@perm_ban` set
- **Status:** `PERM_BANNED` (30)
- **Behavior:** Permanently blocked
- **Note:** Only checked if not whitelisted/temp-banned

### Priority 4: Threat Feeds (LOWEST)
- **Files:** `/etc/nftban/config/feeds/*-blacklist.conf`
- **nftables:** `@feeds` set
- **Status:** `IN_FEEDS` (40)
- **Behavior:** Blocked by threat intelligence
- **Note:** Only checked if not in higher priority lists

### Priority 0: Clean (Default)
- **Status:** `CLEAN` (0)
- **Behavior:** Not found in any list
- **Result:** No action taken

---

## Performance Characteristics

### Whitelist Check (nftban_check_whitelist)
- **Speed:** ~2-5ms with lock overhead
- **Lock Type:** Exclusive (blocks all operations)
- **Optimization:** Early exit on first match

### Blacklist Check (nftban_check_blacklist)
- **Speed:** ~1-3ms (no lock required)
- **Lock Type:** Shared (allows concurrent reads)
- **Optimization:** Early exit on first match

### Full Search (nftban_search_ip)
- **Speed:** ~10-20ms (searches all sources)
- **Lock Type:** Shared for file reads
- **Optimization:** Priority-based early exit

### nftables Lookup
- **Method:** `nft get element` (O(1) hash lookup)
- **Speed:** <1ms per lookup
- **Fallback:** `nft list set` + grep (O(n), slower)

### File Search
- **Method:** `grep -qE` with escaped regex
- **Speed:** O(n) linear scan
- **Optimization:** Early exit on first match

### CIDR Matching
- **Method:** `ipcalc -c -n` for membership test
- **Speed:** ~2-5ms per CIDR check
- **Optimization:** Only checked for entries containing `/`

### Tested Performance
- **100,000 banned IPs:** No performance degradation
- **10 concurrent searches:** All complete successfully
- **Lock contention:** Minimal (<1% of operations timeout)
- **CIDR ranges:** Scales linearly with CIDR count

---

## Change Log

### Version 2.1.0 (2025-10-20) - Security Hardening
- **CRITICAL:** Added TOCTOU race condition protection with exclusive flock
- Added command injection prevention with strict input sanitization
- Added regex injection protection with escaped grep patterns
- Added IPv4-mapped IPv6 normalization (::ffff:x.x.x.x → x.x.x.x)
- Added CIDR range matching support for file-based searches
- Added strict IP validation with ipcalc/sipcalc
- Optimized nftables queries with O(1) `nft get element` lookups
- Added fail-safe behavior for lock timeouts
- Added maximum input length check (DoS prevention)
- Enhanced error messages with security context

### Version 2.0.0 (2025-10-17) - Complete Rewrite
- Unified search across all sources (files + nftables)
- Priority-based search logic (whitelist > temp > perm > feeds)
- Split-table architecture support (v4/v6 tables)
- Removed duplicate code paths
- Added quiet mode for programmatic use
- Added status code system (10/20/30/40/0)

### Version 1.x (Legacy)
- Basic search functionality
- No security hardening
- Legacy unified table architecture

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core logging and utilities
- `nftban_whitelist_module.sh` - Manages whitelist (calls search for duplicate detection)
- `nftban_blacklist_module.sh` - Manages blacklist (calls search for status checks)
- `nftban_feeds_module.sh` - Manages threat feeds (data source for search)
- `nftban_fail2ban_module.sh` - Fail2Ban integration (critical user of whitelist check)

**Related Documentation:**
- `SECURITY_FIXES_PHASE1_SEARCH_MODULE.md` - Detailed security fixes documentation
- `TESTING_PLAN_v0.9.0.md` - Test cases for search module
- `ARCHITECTURE.md` - v0.9.0 Split Table Architecture
- `FAIL2BAN_INTEGRATION.md` - Fail2Ban integration guide

**Configuration Files:**
- `/etc/nftban/config/whitelist_ips.conf` - System whitelist
- `/etc/nftban/config/whitelist_ips.conf.local` - User whitelist
- `/etc/nftban/config/blacklist_ips.conf` - System blacklist
- `/etc/nftban/config/blacklist_ips.conf.local` - User blacklist
- `/etc/nftban/config/feeds/*-blacklist.conf` - Threat feeds

**Fail2Ban Integration:**
- `/etc/fail2ban/action.d/nftban.conf` - Fail2Ban action script (uses nftban_check_whitelist)
