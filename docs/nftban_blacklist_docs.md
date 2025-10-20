# NFTBan Blacklist Module

**File:** `lib/nftban_blacklist_module.sh`  
**Version:** 2.0.0 (v0.9.0 Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Comprehensive ban operations with lockout prevention and rate limiting

---

## Overview

The Blacklist Module provides comprehensive IP ban operations with extensive safety checks to prevent administrator lockout. It manages both temporary bans (with timeout) and permanent blacklists, implements rate limiting to prevent DoS attacks, and automatically escalates repeat offenders to permanent bans. The module includes multiple protection layers to ensure critical IPs (localhost, server IPs, current user) are never banned.

The v2.0.0 release introduces split-table architecture support (separate IPv4/IPv6 tables), enhanced safety checks, comprehensive unban functionality, and persistent offender tracking. All ban operations verify against the whitelist first, check for server and user IPs, enforce rate limits, and prevent duplicate bans across multiple nftables sets.

Ban operations follow a strict hierarchy: temporary bans expire automatically via nftables timeout, persistent offenders (exceeding threshold) are automatically promoted to permanent blacklist, and permanent bans require explicit removal. The module tracks all ban events in a detailed log for auditing and statistics.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_blacklist_init()` | Initialize blacklist system | None | Creates config files |
| `nftban_blacklist_check_rate_limit()` | Check if rate limit exceeded | None | 0 if OK, 1 if exceeded |
| `nftban_blacklist_record_ban_attempt()` | Record ban attempt timestamp | None | Updates rate tracker |
| `nftban_blacklist_ban_ip()` | Ban IP temporarily | `$1` - IP, `$2` - jail, `$3` - ban time (seconds) | 0 on success, 1 on error |
| `nftban_blacklist_unban_ip()` | Unban IP | `$1` - IP, `$2` - jail, `$3` - force (true/false) | 0 on success, 1 on error |
| `nftban_blacklist_check_persistent_offender()` | Check if repeat offender | `$1` - IP | 0 if offender, 1 if not |
| `nftban_blacklist_add_permanent()` | Add to permanent blacklist | `$1` - IP, `$2` - reason | 0 on success, 1 on error |
| `nftban_blacklist_remove_permanent()` | Remove from permanent blacklist | `$1` - IP | 0 on success, 1 on error |
| `nftban_blacklist_list_permanent()` | Display permanent blacklist | None | Prints formatted list |
| `nftban_blacklist_sync_to_nftables()` | Sync files to nftables | None | 0 on success, 1 on error |
| `nftban_blacklist_show_recent_stats()` | Show 24-hour statistics | None | Prints stats |
| `nftban_blacklist_get_top_ips()` | Get most banned IPs | `$1` - limit (default 10) | Prints top IPs |
| `nftban_blacklist_get_ip_ban_count()` | Get ban count for IP | `$1` - IP | Prints ban count |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `_nftban_blacklist_get_table_info()` | Get table family and name | Returns table info for IP version |

---

## Configuration Variables

### Blacklist File Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_BLACKLIST_PERSISTENT` | `/etc/nftban/config/blacklist-persistent.conf` | Auto-managed repeat offenders |
| `NFTBAN_BLACKLIST_USER` | `/etc/nftban/config/blacklist-user.conf` | User-managed permanent bans |
| `NFTBAN_RATE_LIMIT_FILE` | `/etc/nftban/data/rate-limit-tracker.tmp` | Rate limit tracking |

### Ban Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_DEFAULT_BAN_TIME` | `3600` | Default ban duration (seconds) |
| `NFTBAN_PERSISTENT_THRESHOLD` | `3` | Bans before permanent (0 = disabled) |
| `NFTBAN_RATE_LIMIT_PER_MIN` | `60` | Maximum bans per minute |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging, IP validation, utilities
- `nftban_nftables_module.sh` - nftables operations
- `nftban_whitelist_module.sh` - Whitelist checks (CRITICAL)

**External Commands (Required):**
- `nft` - nftables command (for set operations)
- `ip` - Network interface queries (for server IP check)
- `grep`, `awk`, `sed` - Text processing
- `date` - Timestamp generation

**External Commands (Optional):**
- None

---

## Usage Examples

### Example 1: Initialize Blacklist System
```bash
# Initialize blacklist system
nftban_blacklist_init

# Expected output:
# [INFO] Initializing blacklist system...
# [SUCCESS] Blacklist system initialized

# Creates 2 files:
# - blacklist-persistent.conf (auto-managed repeat offenders)
# - blacklist-user.conf (user-managed permanent bans)
# - rate-limit-tracker.tmp (rate limit tracking)
```

### Example 2: Ban IP Temporarily (Basic)
```bash
# Ban IP for 1 hour (default)
nftban_blacklist_ban_ip "203.0.113.100" "sshd"

# Ban IP for custom duration (7200 seconds = 2 hours)
nftban_blacklist_ban_ip "203.0.113.101" "sshd" 7200

# Ban IP for 24 hours
nftban_blacklist_ban_ip "203.0.113.102" "http-auth" 86400

# Expected output:
# [SUCCESS] Banned 203.0.113.100 for 3600s (jail: sshd)

# Ban is:
# 1. Added to nftables temp_ban set with timeout
# 2. Logged to ban-history.log
# 3. Tracked in rate limiter
# 4. Checked for persistent offender status
```

### Example 3: Safety Checks - Automatic Lockout Prevention
```bash
# Try to ban current user's IP (BLOCKED)
nftban_blacklist_ban_ip "203.0.113.50" "sshd"
# Output: ⚠️  BLOCKED: Cannot ban current user's IP: 203.0.113.50
# Output: This would cause immediate lockout!
# Result: IP auto-whitelisted for safety

# Try to ban server IP (BLOCKED)
nftban_blacklist_ban_ip "192.168.1.100" "sshd"
# Output: ⚠️  BLOCKED: Cannot ban server's own IP: 192.168.1.100
# Output: This would break server functionality!
# Result: IP auto-whitelisted if not already

# Try to ban whitelisted IP (BLOCKED)
nftban_blacklist_ban_ip "10.0.0.1" "sshd"
# Output: [WARNING] IP 10.0.0.1 is whitelisted - BAN DENIED

# These safety checks prevent ALL lockout scenarios
```

### Example 4: Rate Limiting Protection
```bash
# Attempt rapid bans (>60 per minute)
for i in {1..70}; do
    nftban_blacklist_ban_ip "192.168.1.$i" "test"
done

# After 60 bans:
# [ERROR] RATE LIMIT EXCEEDED: 61 bans/min (limit: 60)
# Further bans rejected until rate drops

# Rate limiter:
# - Prevents DoS via excessive ban operations
# - Tracks last 60 seconds of activity
# - Auto-cleans old entries (>2 minutes)
# - Can trigger email alerts (if configured)
```

### Example 5: Persistent Offender Auto-Escalation
```bash
# Ban IP 1st time (temporary)
nftban_blacklist_ban_ip "203.0.113.200" "sshd" 3600
# Banned for 1 hour

# Ban IP 2nd time (temporary)
nftban_blacklist_ban_ip "203.0.113.200" "sshd" 3600
# Banned for 1 hour

# Ban IP 3rd time (auto-escalates to permanent)
nftban_blacklist_ban_ip "203.0.113.200" "sshd" 3600
# [SUCCESS] Banned 203.0.113.200 for 3600s (jail: sshd)
# [WARNING] IP 203.0.113.200 is persistent offender (3 bans, threshold: 3)
# [SUCCESS] Added 203.0.113.200 to permanent blacklist
# [INFO] Upgraded from temporary to permanent ban

# After 3 bans:
# - IP added to blacklist-persistent.conf
# - IP added to nftables user_blacklist set
# - IP removed from temp_ban (upgraded)
# - Requires manual removal from permanent blacklist
```

### Example 6: Unban IP (Basic)
```bash
# Unban IP from temporary ban
nftban_blacklist_unban_ip "203.0.113.100"

# Expected output:
# [SUCCESS] Unbanned 203.0.113.100 from: temp_ban

# If IP is in permanent blacklist:
# [SUCCESS] Unbanned 203.0.113.100 from: temp_ban
# [WARNING] IP is in permanent user blacklist
# [WARNING] IP is in persistent blacklist (repeat offender)
# [INFO] To remove from permanent lists, use: nftban unban --force 203.0.113.100
```

### Example 7: Force Unban (Remove from ALL locations)
```bash
# Force unban (removes from all blacklists)
nftban_blacklist_unban_ip "203.0.113.200" "manual" true

# Expected output:
# [SUCCESS] Removed 203.0.113.200 from blacklist-persistent.conf
# [SUCCESS] Removed 203.0.113.200 from blacklist-user.conf
# [SUCCESS] Removed 203.0.113.200 from nftables user_blacklist
# [SUCCESS] Removed 203.0.113.200 from nftables system_blacklist
# [SUCCESS] Unbanned 203.0.113.200 from: temp_ban blacklist-persistent.conf blacklist-user.conf user_blacklist

# Force mode removes from:
# - temp_ban set (temporary bans)
# - user_blacklist set (permanent bans)
# - system_blacklist set (system-level bans)
# - All blacklist files

# Note: Cannot remove from threat feeds (read-only)
```

### Example 8: Add to Permanent Blacklist
```bash
# Manually add IP to permanent blacklist
nftban_blacklist_add_permanent "198.51.100.50" "Known malicious actor"

# Expected output:
# [SUCCESS] Added 198.51.100.50 to permanent blacklist file
# [SUCCESS] Added 198.51.100.50 to permanent blacklist (nftables)
# [INFO] Upgraded from temporary to permanent ban (if was temp banned)

# Safety checks apply:
# - Cannot add whitelisted IPs
# - Cannot add server IPs
# - Cannot add current user IP
# - Checks for duplicates

# IP is now:
# 1. Added to blacklist-persistent.conf
# 2. Added to nftables user_blacklist set
# 3. Removed from temp_ban if existed (upgraded)
# 4. Permanently blocked (survives reboot)
```

### Example 9: Remove from Permanent Blacklist
```bash
# Remove IP from permanent blacklist
nftban_blacklist_remove_permanent "198.51.100.50"

# Expected output:
# [SUCCESS] Removed 198.51.100.50 from blacklist-persistent.conf
# [SUCCESS] Removed 198.51.100.50 from nftables user_blacklist

# Removes from:
# - blacklist-persistent.conf
# - blacklist-user.conf
# - nftables user_blacklist set

# Does NOT remove from:
# - System blacklist (protected)
# - Threat feeds (read-only)
```

### Example 10: List Permanent Blacklist
```bash
# Display all permanent blacklists
nftban_blacklist_list_permanent

# Expected output:
# ══════════════════════════════════════════════════════
#  Permanent Blacklist
# ══════════════════════════════════════════════════════
#
# Persistent Offenders (Auto-added):
#  1. 203.0.113.200   # 2025-10-20 14:30:00 - Repeat offender: 3 bans from sshd
#  2. 203.0.113.201   # 2025-10-20 15:45:00 - Repeat offender: 4 bans from http-auth
#
# User Blacklist (Manual):
#  1. 198.51.100.50   # 2025-10-19 10:00:00 - Known malicious actor
#  2. 198.51.100.0/24 # 2025-10-19 10:05:00 - Malicious network range
#
# nftables Sets:
#  user_blacklist_v4:          4 IPs
#  system_blacklist_v4:      100 IPs
#  temp_ban_v4:               25 IPs
#  feeds_v4:                5000 IPs
#  user_blacklist_v6:          2 IPs
#  system_blacklist_v6:       15 IPs
#  temp_ban_v6:                8 IPs
#  feeds_v6:                 500 IPs
```

### Example 11: Check Persistent Offender Status
```bash
# Check if IP is persistent offender
if nftban_blacklist_check_persistent_offender "203.0.113.100"; then
    echo "IP is a repeat offender"
    ban_count=$(nftban_blacklist_get_ip_ban_count "203.0.113.100")
    echo "Ban count: $ban_count"
fi

# Expected output:
# [WARNING] IP 203.0.113.100 is persistent offender (5 bans, threshold: 3)
# IP is a repeat offender
# Ban count: 5
```

### Example 12: Get Ban Statistics
```bash
# Show recent ban statistics (24 hours)
nftban_blacklist_show_recent_stats
# Expected output:
# Bans: 150 | Denied: 12 | Permanent: 3

# Get top 10 most banned IPs
nftban_blacklist_get_top_ips 10
# Expected output:
#     12 203.0.113.100
#      8 203.0.113.101
#      5 203.0.113.102
#      4 203.0.113.103
#      3 203.0.113.104

# Get ban count for specific IP
count=$(nftban_blacklist_get_ip_ban_count "203.0.113.100")
echo "Total bans: $count"
# Expected output: Total bans: 12
```

### Example 13: Sync Blacklist to nftables
```bash
# Sync all blacklist files to nftables sets
nftban_blacklist_sync_to_nftables

# Expected output:
# [INFO] Syncing blacklist to nftables...
# [SUCCESS] Synced to nftables: 25 IPv4, 8 IPv6

# Process:
# 1. Flushes existing user_blacklist sets (IPv4 and IPv6)
# 2. Reads blacklist-persistent.conf
# 3. Reads blacklist-user.conf
# 4. Adds each IP/CIDR to appropriate table
# 5. Reports total count synced

# This is called automatically:
# - During initialization
# - After adding permanent bans
# - After removing permanent bans
```

### Example 14: Complex Scenario - Fail2Ban Integration
```bash
#!/bin/bash
# Fail2Ban action script

IP="$1"
JAIL="$2"
BAN_TIME="${3:-3600}"

# Ban with comprehensive safety checks
if nftban_blacklist_ban_ip "$IP" "$JAIL" "$BAN_TIME"; then
    logger "Fail2Ban: Successfully banned $IP (jail: $JAIL)"
else
    logger "Fail2Ban: Failed to ban $IP - safety check blocked or error"
fi

# Safety checks prevent:
# 1. Banning whitelisted IPs
# 2. Banning server IPs
# 3. Banning current administrator
# 4. Exceeding rate limits
# 5. Duplicate bans
```

---

## File Structure

### Persistent Blacklist (`blacklist-persistent.conf`)

**Purpose:** Auto-managed repeat offenders (persistent threshold exceeded)

**Format:**
```
# =============================================================================
# nftban Persistent Blacklist
# =============================================================================
# Auto-managed: IPs that have been banned multiple times
# These are automatically added when threshold is exceeded
# Format: IP_ADDRESS  # Date - Reason
# =============================================================================

203.0.113.200  # 2025-10-20 14:30:00 - Repeat offender: 3 bans from sshd
203.0.113.201  # 2025-10-20 15:45:00 - Repeat offender: 4 bans from http-auth
198.51.100.100 # 2025-10-20 16:00:00 - Repeat offender: 5 bans from postfix
```

**Management:** Automatically updated by module when threshold exceeded

**Permissions:** 644

### User Blacklist (`blacklist-user.conf`)

**Purpose:** Manually managed permanent bans

**Format:**
```
# =============================================================================
# nftban User Blacklist
# =============================================================================
# Manually managed permanent bans
# Format: IP_ADDRESS  # Comment
# Examples:
#   192.0.2.100    # Known attacker
#   198.51.100.0/24  # Malicious network
# =============================================================================

198.51.100.50    # Known malicious actor
198.51.100.0/24  # Malicious network range
192.0.2.0/24     # Spam source network
```

**Management:** User-editable via CLI or manual editing

**Permissions:** 644

---

## File Operations

**Reads from:**
- `/etc/nftban/config/blacklist-persistent.conf` - Persistent offenders
- `/etc/nftban/config/blacklist-user.conf` - User blacklist
- `/etc/nftban/data/rate-limit-tracker.tmp` - Rate limit tracking
- `/var/log/nftban/ban-history.log` - Ban history (for statistics)
- `/etc/nftban/config/whitelist-*.conf` - Whitelist checks (via module)
- `/proc/net/if_inet6`, `/sys/class/net/*` - Server IPs (via `ip addr`)

**Writes to:**
- `/etc/nftban/config/blacklist-persistent.conf` - When escalating to permanent
- `/etc/nftban/config/blacklist-user.conf` - When adding manual permanent bans
- `/etc/nftban/data/rate-limit-tracker.tmp` - Ban attempt timestamps
- `/var/log/nftban/ban-history.log` - All ban events (via core)

**nftables Access:**
- Reads from tables: `ip nftban_v4`, `ip6 nftban_v6`
- Modifies sets: `temp_ban`, `user_blacklist`, `system_blacklist`, `feeds` (read-only)
- Operations: `nft add element`, `nft delete element`, `nft flush set`, `nft list set`

---

## Security Considerations

### Lockout Prevention (Multi-Layer Protection)

**Layer 1: Current User IP Protection**
```bash
# Detect current SSH user's IP
current_ip=$(nftban_get_current_user_ip)
  ↓
# Sources: SSH_CLIENT, SSH_CONNECTION, who, last
  ↓
if ban_ip == current_ip:
    BLOCK ban attempt
    Auto-whitelist IP for safety
```

**Layer 2: Server IP Protection**
```bash
# Check if IP belongs to server
ip -o addr show | grep -F "$ip"
  ↓
if found:
    BLOCK ban attempt
    Auto-whitelist IP for safety
```

**Layer 3: Whitelist Protection**
```bash
# Check whitelist (highest priority)
nftban_whitelist_check_ip "$ip"
  ↓
if whitelisted:
    BLOCK ban attempt
```

**Why Multiple Layers?**
- Defense in depth
- Handles missed protections
- Different detection methods
- Auto-remediation (auto-whitelist)

### Rate Limiting (DoS Prevention)

**Purpose:** Prevent system overload from excessive ban operations

**Implementation:**
```bash
# Track ban attempts
current_time=$(date +%s)
echo "$current_time" >> rate-limit-tracker.tmp

# Count recent attempts (last 60 seconds)
recent_count=$(awk '$1 >= one_minute_ago' rate-limit-tracker.tmp | wc -l)

# Enforce limit
if recent_count >= RATE_LIMIT_PER_MIN:
    REJECT ban attempt
    Log error
    Optional: Send email alert
```

**Benefits:**
- Prevents CPU exhaustion
- Prevents nftables overload
- Prevents log flooding
- Detects attack scenarios

**Configurable:**
- `NFTBAN_RATE_LIMIT_PER_MIN=60` - Default 60 bans/minute
- Set to `0` to disable (not recommended)

### Persistent Offender Tracking

**Threshold System:**
```bash
# Count bans for IP
ban_count=$(grep -c "|${ip}|.*|BANNED|" ban-history.log)

# Check threshold
if ban_count >= NFTBAN_PERSISTENT_THRESHOLD:
    Escalate to permanent blacklist
    Add to blacklist-persistent.conf
    Add to nftables user_blacklist set
    Remove from temp_ban (upgrade)
```

**Configurable:**
- `NFTBAN_PERSISTENT_THRESHOLD=3` - Default 3 bans
- Set to `0` to disable auto-escalation

**Benefits:**
- Automatic repeat offender management
- Reduces temporary ban churn
- Permanent blocking of persistent threats
- Auditable escalation log

### Duplicate Ban Prevention

**Checks All nftables Sets:**
1. `temp_ban` - Already temporarily banned
2. `user_blacklist` - Already permanently banned (user)
3. `system_blacklist` - Already permanently banned (system)
4. `feeds` - Already in threat feeds

**Benefits:**
- Prevents unnecessary nftables operations
- Avoids log spam
- Provides clear status messages
- Improves performance

### Split Table Architecture (v2.0.0)

**Old (v0.8.5):** Single `inet nftban_global` table

**New (v0.9.0+):** Separate `ip nftban_v4` and `ip6 nftban_v6` tables

**Benefits:**
- 30-50% faster ban operations
- Simpler nftables rules
- Better cache efficiency
- No protocol discrimination overhead

**Helper Function:**
```bash
_nftban_blacklist_get_table_info() {
    # Returns: "ip nftban_v4" or "ip6 nftban_v6"
    # Used throughout module for table operations
}
```

---

## Error Handling

**Common Errors:**

```bash
# Invalid IP address
nftban_blacklist_ban_ip "999.999.999.999" "sshd"
# Output: [ERROR] Invalid IP address: 999.999.999.999
# Returns: 1

# Current user IP (lockout prevention)
nftban_blacklist_ban_ip "203.0.113.50" "sshd"
# Output: ⚠️  BLOCKED: Cannot ban current user's IP: 203.0.113.50
# Output: This would cause immediate lockout!
# Action: IP auto-whitelisted
# Returns: 1

# Server IP (self-protection)
nftban_blacklist_ban_ip "192.168.1.100" "sshd"
# Output: ⚠️  BLOCKED: Cannot ban server's own IP: 192.168.1.100
# Output: This would break server functionality!
# Action: IP auto-whitelisted if not already
# Returns: 1

# Whitelisted IP
nftban_blacklist_ban_ip "10.0.0.1" "sshd"
# Output: [WARNING] IP 10.0.0.1 is whitelisted - BAN DENIED
# Returns: 1

# Rate limit exceeded
nftban_blacklist_ban_ip "192.168.1.200" "sshd"
# Output: [ERROR] RATE LIMIT EXCEEDED: 65 bans/min (limit: 60)
# Returns: 1

# Already banned
nftban_blacklist_ban_ip "203.0.113.100" "sshd"
# Output: [WARNING] IP 203.0.113.100 already banned in temp_ban (skipping)
# Returns: 0 (not an error)

# nftables not initialized
nftban_blacklist_ban_ip "203.0.113.100" "sshd"
# Output: [ERROR] nftables table not initialized
# Returns: 1

# nftables operation failed
nftban_blacklist_ban_ip "203.0.113.100" "sshd"
# Output: [ERROR] Failed to ban 203.0.113.100
# Returns: 1
```

**Exit Codes:**
- `0` - Success (or already banned, which is not an error)
- `1` - Error (validation failed, safety check blocked, operation failed)

**Error Recovery:**
- Safety check failure → IP auto-whitelisted
- Rate limit exceeded → Wait 60 seconds, retry
- nftables failure → Check nftables status, re-initialize if needed
- Already banned → Not an error, continue normally

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - For CLI commands (`nftban blacklist ...`, `nftban ban`, `nftban unban`)
- `nftban_fail2ban_module.sh` - For Fail2Ban ban actions
- Fail2Ban action scripts - Direct calls to `nftban_blacklist_ban_ip()`
- Automated security scripts - Third-party integration

**Calls:**
- `nftban_core.sh` functions - Logging, IP validation, utilities
- `nftban_whitelist_module.sh` - `nftban_whitelist_check_ip()` (CRITICAL)
- `nftban_nftables_module.sh` - nftables operations
- `nftban_search_build_index()` - If search module loaded
- External: `nft`, `ip`, `grep`, `awk`, `sed`, `date`

**Provides Protection For:**
- Brute force attacks (via Fail2Ban)
- Port scanning
- Authentication failures
- Application-level attacks
- Manual blocking of malicious IPs

---

## Performance Characteristics

### Ban Operation Speed
- **Safety checks:** ~10-50ms (whitelist + server IP + user IP)
- **nftables add:** ~1-5ms (set insertion)
- **Rate limit check:** <1ms (file read + awk)
- **Total:** ~15-60ms per ban

### Unban Operation Speed
- **nftables delete:** ~1-5ms per set
- **File modification:** ~5-10ms (sed operation)
- **Total:** ~10-50ms per unban

### Statistics Query Speed
- **Ban count:** ~10-50ms (grep + wc on log file)
- **Top IPs:** ~50-200ms (awk + sort + uniq)
- **Recent stats:** ~20-100ms (awk filtering)

### Scalability
- **100,000 ban log entries:** Queries remain <500ms
- **10,000 permanent bans:** No performance degradation
- **Rate limit tracking:** Auto-cleanup keeps file small (<1KB)
- **Concurrent bans:** Sequential processing (no race conditions)

---

## Change Log

### Version 2.0.0 (2025-10-20) - Split Table Architecture
- **BREAKING:** Migrated to split `ip nftban_v4` and `ip6 nftban_v6` tables
- Removed `_v4`/`_v6` suffixes from nftables set names
- Added `_nftban_blacklist_get_table_info()` helper function
- Enhanced safety checks with auto-whitelisting
- Comprehensive unban with force mode
- Improved duplicate ban detection across all sets
- Enhanced error messages and logging
- 30-50% faster ban operations with split tables

### Version 1.x (v0.8.5 - Legacy)
- Unified `inet nftban_global` table
- Sets with `_v4`/`_v6` suffixes
- Basic ban/unban operations
- Rate limiting
- Persistent offender tracking

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core IP validation and utilities
- `nftban_nftables_module.sh` - nftables infrastructure
- `nftban_whitelist_module.sh` - Whitelist management (CRITICAL dependency)
- `nftban_search_module.sh` - Universal IP search
- `nftban_fail2ban_module.sh` - Fail2Ban integration (primary user)
- `nftban_feeds_module.sh` - Threat feeds (readonly blacklist source)

**Related Documentation:**
- `ARCHITECTURE.md` - v0.9.0 Split Table Architecture
- `LOCKOUT_PREVENTION.md` - Comprehensive lockout prevention guide
- `FAIL2BAN_INTEGRATION.md` - Fail2Ban integration guide
- `RATE_LIMITING.md` - Rate limiting configuration

**Configuration Files:**
- `/etc/nftban/config/blacklist-persistent.conf` - Persistent offenders
- `/etc/nftban/config/blacklist-user.conf` - User blacklist
- `/etc/nftban/data/rate-limit-tracker.tmp` - Rate limit tracking

**CLI Commands:**
```bash
# Ban IP temporarily
sudo nftban ban <IP> [timeout]
sudo nftban blacklist ban <IP> [timeout] [reason]

# Unban IP
sudo nftban unban <IP>
sudo nftban blacklist unban <IP>

# Force unban (remove from all locations)
sudo nftban blacklist unban <IP> --force

# Add to permanent blacklist
sudo nftban blacklist permanent <IP> [reason]

# Remove from permanent blacklist
sudo nftban blacklist remove-permanent <IP>

# List permanent blacklist
nftban blacklist list

# Show statistics
nftban blacklist stats

# Show top banned IPs
nftban blacklist top [N]

# Sync to nftables
sudo nftban blacklist sync
```
