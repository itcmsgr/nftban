# NFTBan Whitelist Module

**File:** `lib/nftban_whitelist_module.sh`  
**Version:** 2.0.0 (v0.9.0 Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Comprehensive whitelist management with auto-protection and lockout prevention

---

## Overview

The Whitelist Module provides comprehensive IP whitelist management with automatic protection mechanisms to prevent administrator lockout. It manages three distinct whitelist files (system, user, and Cloudflare), automatically protects critical IPs (localhost, server IPs, and current user), and synchronizes all entries to nftables sets for enforcement.

The v2.0.0 release introduces atomic file operations with flock for race condition prevention, split-table architecture support (separate IPv4/IPv6 tables), and enhanced safety checks. The module includes automatic detection and protection of server interface IPs, public IPs, and the current SSH user's IP address to prevent accidental lockout scenarios.

All whitelist operations follow a multi-layered approach: file-based storage for persistence, nftables sets for enforcement, and dynamic checks for server and user IPs. The whitelist has the highest priority in the NFTBan filtering system—whitelisted IPs bypass all ban checks and are never blocked, regardless of other rules.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_whitelist_init()` | Initialize whitelist system | None | Creates config files and auto-protects |
| `nftban_whitelist_add_server_ips()` | Auto-protect all server IPs | None | Protects interface and public IPs |
| `nftban_whitelist_protect_current_user()` | Auto-protect current SSH user | None | Adds user's IP to whitelist |
| `nftban_whitelist_add_ip()` | Add IP to whitelist | `$1` - IP, `$2` - comment | 0 on success, 1 on error |
| `nftban_whitelist_remove_ip()` | Remove IP from whitelist | `$1` - IP | 0 on success, 1 on error |
| `nftban_whitelist_check_ip()` | Check if IP is whitelisted | `$1` - IP | 0 if whitelisted, 1 if not, 2 if invalid |
| `nftban_whitelist_list()` | Display all whitelisted IPs | None | Prints formatted list |
| `nftban_whitelist_sync_to_nftables()` | Sync files to nftables | None | 0 on success, 1 on error |
| `nftban_whitelist_verify()` | Verify whitelist system | None | 0 if valid, 1 if issues |
| `nftban_whitelist_get_stats()` | Get whitelist statistics | None | Prints stats string |

### Internal Functions (Private - Security Layer)

| Function | Purpose | Notes |
|----------|---------|-------|
| `_nftban_whitelist_safe_append()` | Atomic file append with flock | **SECURITY:** Prevents race conditions during writes |
| `_nftban_whitelist_safe_modify()` | Atomic file modification with flock | **SECURITY:** Safe sed operations under exclusive lock |

---

## Configuration Variables

### Whitelist File Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_WHITELIST_SYSTEM` | `/etc/nftban/config/whitelist-system.conf` | Auto-managed system whitelist |
| `NFTBAN_WHITELIST_USER` | `/etc/nftban/config/whitelist-user.conf` | User-editable whitelist |
| `NFTBAN_WHITELIST_CF` | `/etc/nftban/config/whitelist-cloudflare.conf` | Cloudflare IP ranges |

### Lock Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_WHITELIST_LOCK_DIR` | `/var/lock/nftban` | Lock file directory |
| `NFTBAN_WHITELIST_LOCK_TIMEOUT` | `5` | Lock timeout in seconds |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging, IP validation, and utilities
- `nftban_nftables_module.sh` - nftables operations (for sync)

**External Commands (Required):**
- `nft` - nftables command (for set operations)
- `flock` - File locking (CRITICAL for atomic operations)
- `ip` - Network interface queries (for server IP detection)
- `grep`, `awk`, `sed` - Text processing

**External Commands (Optional):**
- `curl` or `wget` - Public IP detection (for auto-protection)

---

## Usage Examples

### Example 1: Initialize Whitelist System
```bash
# Initialize with auto-protection
nftban_whitelist_init

# Expected output:
# [INFO] Initializing whitelist system with auto-protection...
# [INFO] Auto-protecting server interface IPs...
# [SUCCESS] Protected server IP: 192.168.1.100
# [SUCCESS] Protected public IPv4: 203.0.113.42
# [SUCCESS] Auto-protected 2 server IPs
# [SUCCESS] Protected current user IP: 203.0.113.50
# ⚠️  IMPORTANT: Your IP (203.0.113.50) has been whitelisted to prevent lockout
# [SUCCESS] Whitelist system initialized with protection

# Creates 3 files:
# - whitelist-system.conf (auto-managed, includes localhost + server IPs)
# - whitelist-user.conf (user-editable, includes current SSH user)
# - whitelist-cloudflare.conf (Cloudflare IPs, if enabled)
```

### Example 2: Add IP to Whitelist
```bash
# Add IP with comment
nftban_whitelist_add_ip "192.168.1.50" "Office network gateway"

# Add IP with default comment
nftban_whitelist_add_ip "10.0.0.1"

# Add IPv6 address
nftban_whitelist_add_ip "2001:db8::1" "IPv6 server"

# Add CIDR range
nftban_whitelist_add_ip "172.16.0.0/12" "Private network range"

# Expected output:
# [SUCCESS] Added 192.168.1.50 to whitelist (nftables + file)

# IP is now:
# 1. Added to /etc/nftban/config/whitelist-user.conf
# 2. Added to nftables whitelist set (IPv4 or IPv6)
# 3. Protected from all ban operations
```

### Example 3: Remove IP from Whitelist
```bash
# Remove IP from whitelist
nftban_whitelist_remove_ip "192.168.1.50"

# Expected output:
# [SUCCESS] Removed 192.168.1.50 from user whitelist file
# [SUCCESS] Removed 192.168.1.50 from nftables whitelist

# Safety checks prevent removing:
# - Localhost (127.0.0.1, ::1)
# - Server's own IPs
# - Current user's IP (would cause lockout!)
```

### Example 4: Safety Checks - Lockout Prevention
```bash
# Try to remove localhost (BLOCKED)
nftban_whitelist_remove_ip "127.0.0.1"
# Output: [ERROR] BLOCKED: Cannot remove localhost from whitelist!

# Try to remove server IP (BLOCKED)
nftban_whitelist_remove_ip "192.168.1.100"
# Output: [ERROR] BLOCKED: Cannot remove server's own IP from whitelist!

# Try to remove current SSH user's IP (BLOCKED)
nftban_whitelist_remove_ip "203.0.113.50"
# Output: [ERROR] BLOCKED: Cannot remove current user's IP from whitelist!
# Output: [ERROR] This would cause immediate lockout!

# These safety checks PREVENT accidental lockout scenarios
```

### Example 5: Check if IP is Whitelisted
```bash
# Check if IP is whitelisted
if nftban_whitelist_check_ip "192.168.1.50"; then
    echo "IP is whitelisted - will never be banned"
else
    echo "IP is not whitelisted - can be banned"
fi

# Check with invalid IP
nftban_whitelist_check_ip "999.999.999.999"
# Returns: 2 (invalid IP)

# The check examines 4 sources:
# 1. nftables sets (fastest)
# 2. Configuration files (includes CIDR ranges)
# 3. Server interface IPs (dynamic check)
# 4. Current user's IP (dynamic check)
```

### Example 6: List All Whitelisted IPs
```bash
# Display complete whitelist
nftban_whitelist_list

# Expected output:
# ══════════════════════════════════════════════════════
#  Whitelisted IPs
# ══════════════════════════════════════════════════════
#
# System Whitelist (Auto-Protected):
#  1. 127.0.0.1       # Localhost IPv4
#  2. ::1             # Localhost IPv6
#  3. 192.168.1.100   # Server IP (auto-detected)
#  4. 203.0.113.42    # Server public IPv4 (auto-detected)
#
# User Whitelist:
#  1. 203.0.113.50    # Current admin user (auto-protected)
#  2. 192.168.1.50    # Office network gateway
#  3. 10.0.0.0/8      # Private network
#
# Cloudflare Whitelist:
#  173 Cloudflare IP ranges
#  (Use 'nftban cloudflare status' for details)
#
# nftables Sets:
#  whitelist (IPv4):     15 IPs
#  whitelist (IPv6):      3 IPs
#
# Current Protections:
#  Current User IP: 203.0.113.50
#  Server IPs: 4 protected
```

### Example 7: Sync Whitelist to nftables
```bash
# Sync all whitelist files to nftables sets
nftban_whitelist_sync_to_nftables

# Expected output:
# [INFO] Syncing whitelist to nftables...
# [SUCCESS] Synced to nftables: 15 IPv4, 3 IPv6

# Process:
# 1. Flushes existing whitelist sets (IPv4 and IPv6)
# 2. Reads all whitelist files
# 3. Adds each IP/CIDR to appropriate table
# 4. Reports total count synced

# This is called automatically:
# - During initialization
# - After adding IPs
# - After removing IPs
# - After auto-protection operations
```

### Example 8: Verify Whitelist System
```bash
# Run comprehensive verification
nftban_whitelist_verify

# Expected output:
# ══════════════════════════════════════════════════════
#  Whitelist Safety Verification
# ══════════════════════════════════════════════════════
#
# Checking system whitelist... ✓ EXISTS
# Checking user whitelist... ✓ EXISTS
# Checking localhost protection... ✓ PROTECTED
# Checking server IP protection... ✓ ALL PROTECTED
# Checking current user IP... ✓ PROTECTED (203.0.113.50)
# Checking nftables sync... ✓ SYNCED
#
# ✓ ALL CHECKS PASSED

# If issues found:
# ══════════════════════════════════════════════════════
#  Whitelist Safety Verification
# ══════════════════════════════════════════════════════
#
# Checking system whitelist... ✗ MISSING
# Checking user whitelist... ✓ EXISTS
# Checking localhost protection... ✗ NOT PROTECTED
# Checking server IP protection... ⚠ 2 IPs NOT PROTECTED
# Checking current user IP... ✗ NOT PROTECTED (203.0.113.50)
#   ⚠️  WARNING: Risk of self-lockout!
# Checking nftables sync... ⚠ OUT OF SYNC (files: 15, nft: 12)
#
# 4 issue(s) found - run: nftban whitelist init
```

### Example 9: Auto-Protect Server IPs
```bash
# Manually trigger server IP protection
nftban_whitelist_add_server_ips

# Expected output:
# [INFO] Auto-protecting server interface IPs...
# [SUCCESS] Protected server IP: 192.168.1.100
# [SUCCESS] Protected server IP: 10.0.0.1
# [SUCCESS] Protected public IPv4: 203.0.113.42
# [SUCCESS] Auto-protected 3 server IPs

# Protects:
# 1. All interface IPs (from `ip addr show`)
# 2. Public IPv4 (from external service)
# 3. Public IPv6 (from external service)
# 4. Skips localhost (127.x.x.x, ::1)
# 5. Skips already protected IPs
```

### Example 10: Auto-Protect Current User
```bash
# Manually trigger current user protection
nftban_whitelist_protect_current_user

# Expected output:
# [SUCCESS] Protected current user IP: 203.0.113.50
# ⚠️  IMPORTANT: Your IP (203.0.113.50) has been whitelisted to prevent lockout

# Process:
# 1. Detects SSH client IP (from SSH_CLIENT, SSH_CONNECTION, who, last)
# 2. Checks if already protected
# 3. Adds to USER whitelist (not system - allows manual removal if needed)
# 4. Syncs to nftables
# 5. Logs protection

# If local console (no remote IP):
# [DEBUG] No remote user detected (local console?)
```

### Example 11: Get Whitelist Statistics
```bash
# Get counts from all whitelist sources
stats=$(nftban_whitelist_get_stats)
echo "$stats"

# Expected output:
# System: 4 | User: 8 | Cloudflare: 173 | Total: 185

# Useful for:
# - Monitoring dashboards
# - Scripts and automation
# - Status checks
```

### Example 12: CIDR Range Matching
```bash
# Add CIDR range to whitelist
nftban_whitelist_add_ip "10.0.0.0/8" "Private Class A network"

# Check if specific IP is in CIDR range
nftban_whitelist_check_ip "10.5.10.50"
# Returns: 0 (whitelisted - IP is in 10.0.0.0/8 range)

# Check IP outside range
nftban_whitelist_check_ip "11.0.0.1"
# Returns: 1 (not whitelisted - IP not in range)

# CIDR matching uses nftban_ip_in_cidr() from core module
# Supports both IPv4 and IPv6 CIDR ranges
```

### Example 13: Integration with Other Modules
```bash
# Whitelist check before banning (Fail2Ban integration)
IP="192.168.1.50"

if nftban_whitelist_check_ip "$IP"; then
    echo "Refusing to ban whitelisted IP: $IP"
    exit 0
fi

# Proceed with ban
nftban_blacklist_ban_ip "$IP" "Brute force attempt"

# This pattern is used by:
# - nftban_fail2ban_module.sh
# - nftban_blacklist_module.sh
# - nftban_search_module.sh
```

---

## File Structure

### System Whitelist (`whitelist-system.conf`)

**Purpose:** Auto-managed, critical IPs that should never be removed

**Contents:**
- Localhost (127.0.0.1, ::1)
- Server interface IPs (auto-detected)
- Server public IPs (auto-detected)

**Format:**
```
# =============================================================================
# nftban System Whitelist
# =============================================================================
# Auto-managed IPs that should NEVER be banned
# DO NOT edit manually - this file is auto-generated
# =============================================================================

127.0.0.1       # Localhost IPv4
::1             # Localhost IPv6
192.168.1.100   # Server IP (auto-detected on 2025-10-20)
203.0.113.42    # Server public IPv4 (auto-detected on 2025-10-20)
```

**Permissions:** 644 (read-only for users, writable by root)

**Management:** Automatically updated by `nftban_whitelist_add_server_ips()`

### User Whitelist (`whitelist-user.conf`)

**Purpose:** User-editable whitelist for custom IPs

**Contents:**
- Current SSH user IP (auto-added on init)
- User-added IPs and CIDR ranges
- Office networks, VPN ranges, etc.

**Format:**
```
# =============================================================================
# nftban User Whitelist
# =============================================================================
# Add IPs or CIDR ranges that should NEVER be banned
# Format: IP_ADDRESS  # Comment
# Examples:
#   192.168.1.100     # Office server
#   10.0.0.0/8        # Private network
#   2001:db8::/32     # IPv6 range
# =============================================================================

203.0.113.50    # Current admin user (auto-protected on 2025-10-20 14:30:00)
192.168.1.0/24  # Office network
10.0.0.1        # VPN gateway
```

**Permissions:** 644 (writable by root)

**Management:** Editable via `nftban whitelist add/remove` or manual editing

### Cloudflare Whitelist (`whitelist-cloudflare.conf`)

**Purpose:** Cloudflare IP ranges (when Cloudflare integration enabled)

**Contents:**
- Cloudflare IPv4 ranges
- Cloudflare IPv6 ranges

**Format:**
```
# =============================================================================
# nftban Cloudflare Whitelist
# =============================================================================
# Auto-managed - Populated when Cloudflare integration is enabled
# =============================================================================

173.245.48.0/20     # Cloudflare IPv4
103.21.244.0/22     # Cloudflare IPv4
# ... (170+ more ranges)
2400:cb00::/32      # Cloudflare IPv6
# ...
```

**Permissions:** 644

**Management:** Automatically populated by `nftban_cloudflare_module.sh`

---

## File Operations

**Reads from:**
- `/etc/nftban/config/whitelist-system.conf` - System whitelist
- `/etc/nftban/config/whitelist-user.conf` - User whitelist
- `/etc/nftban/config/whitelist-cloudflare.conf` - Cloudflare IPs
- `/proc/net/if_inet6`, `/sys/class/net/*` - Server IPs (via `ip addr`)
- `$SSH_CLIENT`, `$SSH_CONNECTION` - Current user IP detection

**Writes to:**
- `/etc/nftban/config/whitelist-user.conf` - When adding/removing IPs
- `/etc/nftban/config/whitelist-system.conf` - During auto-protection
- `/var/lock/nftban/*.lock` - Lock files for atomic operations

**nftables Access:**
- Reads from tables: `ip nftban_v4`, `ip6 nftban_v6`
- Modifies sets: `whitelist` (in both tables)
- Operations: `nft add element`, `nft delete element`, `nft flush set`, `nft list set`

---

## Security Considerations

### Atomic File Operations (v2.0.0)
**Issue:** Concurrent whitelist operations could cause race conditions and file corruption

**Solution:** All file modifications use flock for atomic operations
```bash
# Atomic append
_nftban_whitelist_safe_append "$file" "$content"
  ↓
flock -x -w 5 # Exclusive lock, 5 second timeout
  write to file
flock release

# Atomic modify
_nftban_whitelist_safe_modify "$file" "sed_expression"
  ↓
flock -x -w 5
  sed -i operation
flock release
```

**Benefits:**
- No partial writes
- No concurrent modification corruption
- Timeout prevents deadlock
- Exclusive locks guarantee atomicity

### Lockout Prevention Safeguards

**Critical IP Protection:**
```bash
# CANNOT remove localhost
nftban_whitelist_remove_ip "127.0.0.1"
→ [ERROR] BLOCKED: Cannot remove localhost from whitelist!

# CANNOT remove server's own IP
nftban_whitelist_remove_ip "192.168.1.100"  # Server IP
→ [ERROR] BLOCKED: Cannot remove server's own IP from whitelist!

# CANNOT remove current SSH user's IP
nftban_whitelist_remove_ip "203.0.113.50"  # Your IP
→ [ERROR] BLOCKED: Cannot remove current user's IP from whitelist!
→ [ERROR] This would cause immediate lockout!
```

**Auto-Protection on Initialization:**
- Localhost always protected (127.0.0.1, ::1)
- All server interface IPs auto-detected and protected
- Server public IP detected and protected
- Current SSH user auto-protected on first run

**Dynamic Checks:**
- `nftban_whitelist_check_ip()` performs live server IP check
- Catches IPs added after initialization
- Protects against config file corruption

### Split Table Architecture (v2.0.0)
**Old (v0.8.5):** Single `inet nftban_global` table, sets with `_v4`/`_v6` suffixes

**New (v0.9.0+):** Separate `ip nftban_v4` and `ip6 nftban_v6` tables, no suffixes

**Benefits:**
- 30-50% faster whitelist checks
- Simpler nftables rules
- Better cache efficiency
- No protocol discrimination overhead

**Compatibility:**
- Module auto-detects IP version
- Routes to correct table automatically
- Supports both architectures during migration

### CIDR Range Support
**Validation:** Uses `nftban_ip_in_cidr()` for proper CIDR matching

**Storage:**
- Files: CIDR ranges stored as text (e.g., `10.0.0.0/8`)
- nftables: Sets have `interval` flag for range support

**Matching:**
- Exact IP match checked first (fast)
- CIDR range match if exact fails (slower but comprehensive)

### Multi-Layer Whitelist Check

**Check Order (fastest to slowest):**
1. **nftables sets** - O(1) hash lookup, fastest
2. **Configuration files** - O(n) grep, includes CIDR
3. **Server IPs** - Dynamic interface check
4. **Current user IP** - Dynamic SSH session check

**Why Multiple Layers?**
- nftables: Enforcement layer (what's actually active)
- Files: Persistence layer (survives reboots)
- Dynamic: Safety layer (catches missed protections)

---

## Error Handling

**Common Errors:**

```bash
# Invalid IP address
nftban_whitelist_add_ip "999.999.999.999"
# Output: [ERROR] Invalid IP address: 999.999.999.999
# Returns: 1

# Already whitelisted
nftban_whitelist_add_ip "192.168.1.50"  # Already added
# Output: [WARNING] IP 192.168.1.50 is already whitelisted
# Returns: 0 (not an error)

# Lock timeout
_nftban_whitelist_safe_append "/etc/nftban/config/whitelist-user.conf" "..."
# Output: [ERROR] Could not acquire write lock on ...
# Returns: 1

# nftables not initialized
nftban_whitelist_sync_to_nftables
# Output: [ERROR] nftables table not initialized
# Returns: 1

# Safety check failure (lockout prevention)
nftban_whitelist_remove_ip "127.0.0.1"
# Output: [ERROR] BLOCKED: Cannot remove localhost from whitelist!
# Returns: 1
```

**Exit Codes:**
- `0` - Success (or already whitelisted)
- `1` - Error (invalid IP, lock failed, safety check blocked)
- `2` - Invalid IP format (from `nftban_whitelist_check_ip()`)

**Error Recovery:**
- Lock timeouts: Retry operation
- nftables failure: IP still added to file (manual sync later)
- Missing files: Run `nftban whitelist init`
- Corruption: Restore from backup or re-initialize

---

## Integration Points

**Called by:**
- `nftban init` - During system initialization
- `nftban_main_cli.sh` - For CLI commands (`nftban whitelist ...`)
- `nftban_fail2ban_module.sh` - Before banning IPs (uses `nftban_check_whitelist`)
- `nftban_blacklist_module.sh` - Duplicate check before adding to blacklist
- `nftban_search_module.sh` - Universal IP search (Priority 1 check)
- Migration scripts - During upgrades

**Calls:**
- `nftban_core.sh` functions - Logging, IP validation, utilities
- `nftban_nftables_module.sh` - nftables operations
- `nftban_search_build_index()` - If search module loaded
- External: `nft`, `flock`, `ip`, `grep`, `awk`, `sed`

**Provides Protection For:**
- Fail2Ban actions (prevents banning whitelisted IPs)
- Manual ban operations
- Automated security systems
- Threat feed blocking
- All blacklist operations

---

## Performance Characteristics

### Whitelist Check Speed
- **nftables lookup:** ~1-5μs (O(1) hash table)
- **File search:** ~5-20ms (O(n) grep, depends on file size)
- **CIDR matching:** ~2-5ms per CIDR (uses ipcalc)
- **Dynamic checks:** ~10-50ms (ip command execution)

### Scalability
- **10,000 whitelisted IPs:** No performance degradation
- **100+ CIDR ranges:** Minimal impact (~200ms total)
- **Concurrent operations:** Handled via flock (sequential processing)
- **File size:** Up to 1MB (100,000 entries) processes in <1 second

### Optimization Strategies
1. **nftables checked first** - Fastest path for active protection
2. **Early exit** - Returns on first match
3. **Atomic operations** - Prevents lock contention
4. **Set-based nftables** - O(1) lookups instead of linear rules

---

## Change Log

### Version 2.0.0 (2025-10-20) - Split Table Architecture + Security Hardening
- **BREAKING:** Migrated to split `ip nftban_v4` and `ip6 nftban_v6` tables
- Removed `_v4`/`_v6` suffixes from nftables set names
- **SECURITY:** Added atomic file operations with flock (prevents race conditions)
- **SECURITY:** Added `_nftban_whitelist_safe_append()` for safe file writes
- **SECURITY:** Added `_nftban_whitelist_safe_modify()` for safe modifications
- Enhanced lockout prevention with multiple safety checks
- Added auto-protection for server IPs (interface + public)
- Added auto-protection for current SSH user
- Improved CIDR range matching
- Enhanced verification with comprehensive checks
- 30-50% faster whitelist checks with split tables

### Version 1.x (v0.8.5 - Legacy)
- Unified `inet nftban_global` table
- Sets with `_v4`/`_v6` suffixes
- Basic file operations (no atomic protection)
- Manual server IP protection

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core IP validation and utilities
- `nftban_nftables_module.sh` - nftables infrastructure
- `nftban_search_module.sh` - Universal IP search (uses whitelist check)
- `nftban_blacklist_module.sh` - Blacklist management (checks whitelist first)
- `nftban_fail2ban_module.sh` - Fail2Ban integration (critical user)
- `nftban_safety_module.sh` - Additional safety checks
- `nftban_cloudflare_module.sh` - Cloudflare IP management

**Related Documentation:**
- `ARCHITECTURE.md` - v0.9.0 Split Table Architecture
- `LOCKOUT_PREVENTION.md` - Comprehensive lockout prevention guide
- `FAIL2BAN_INTEGRATION.md` - Fail2Ban whitelist integration
- `CONFIGURATION.md` - Whitelist configuration reference

**Configuration Files:**
- `/etc/nftban/config/whitelist-system.conf` - System whitelist
- `/etc/nftban/config/whitelist-user.conf` - User whitelist
- `/etc/nftban/config/whitelist-cloudflare.conf` - Cloudflare IPs

**CLI Commands:**
```bash
# Initialize whitelist
sudo nftban whitelist init

# Add IP
sudo nftban whitelist add <IP> [comment]

# Remove IP
sudo nftban whitelist remove <IP>

# List all
nftban whitelist list

# Check IP
nftban whitelist check <IP>

# Verify system
nftban whitelist verify

# Sync to nftables
sudo nftban whitelist sync

# Auto-protect current user
sudo nftban whitelist protect-me

# Get statistics
nftban whitelist stats
```
