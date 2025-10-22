# NFTBan Blacklist Module Documentation

**Module:** `nftban_blacklist_module.sh`
**Version:** 0.9.3-dev
**Location:** `/usr/local/lib/nftban/nftban_blacklist_module.sh`
**Purpose:** Ban operations with comprehensive safety checks, persistent offender management, and rate limiting

---

## Table of Contents

1. [Overview](#overview)
2. [Module Architecture](#module-architecture)
3. [API Reference](#api-reference)
4. [Integration Guide](#integration-guide)
5. [Configuration](#configuration)
6. [Security Considerations](#security-considerations)
7. [Troubleshooting](#troubleshooting)
8. [Testing](#testing)
9. [Performance](#performance)
10. [Maintenance](#maintenance)

---

## Overview

### Purpose

The Blacklist Module provides comprehensive IP banning functionality with multi-layered safety checks to prevent administrator lockout, server self-blocking, and whitelist bypass. It manages temporary bans (with timeout), persistent offender tracking, permanent blacklists, and rate limiting to prevent abuse.

### Key Features

- **Multi-Layer Safety Checks**: Prevents banning current user, server IPs, and whitelisted IPs
- **Temporary Bans**: Timeout-based bans with automatic expiration (nftables native timeout)
- **Persistent Offender Detection**: Auto-promotes repeat offenders to permanent blacklist
- **Permanent Blacklist**: Two-tier system (user manual, system auto-generated)
- **Rate Limiting**: Prevents ban flooding (default: 60 bans/minute)
- **Comprehensive Unban**: Removes from all locations (temp_ban, user_blacklist, system_blacklist)
- **Split Table Architecture**: Separate IPv4/IPv6 tables (v0.9.0+)
- **Atomic File Operations**: flock-based locking prevents race conditions

### Dependencies

**Required Modules:**
- `nftban_core.sh` - Core validation and logging functions
- `nftban_nftables_module.sh` - nftables table management
- `nftban_whitelist_module.sh` - Whitelist checking (safety)

**System Requirements:**
- `nftables` >= 0.9.0 (with timeout support)
- `flock` (util-linux package)
- `ip` command (iproute2 package)

### Version History

| Version | Changes |
|---------|---------|
| 0.9.3-dev | Added atomic file operations, enhanced safety checks |
| 0.9.2 | Production hardening, BUG61 fix (arithmetic in strict mode) |
| 0.9.0 | Split table architecture (IPv4/IPv6 separation) |
| 0.8.x | Persistent offender system introduced |

---

## Module Architecture

### File Structure

```
/etc/nftban/
├── blacklist-persistent.conf  # Auto-managed (repeat offenders)
├── blacklist-user.conf         # User-managed (manual permanent bans)
└── whitelist-*.conf            # Referenced for safety checks

/var/nftban/
└── rate-limit-tracker.tmp      # Temporary (ban rate tracking)

/var/lock/nftban/
├── blacklist-persistent.conf.lock
├── blacklist-user.conf.lock
└── rate-limit-tracker.tmp.lock

/var/log/nftban/
└── ban.log                     # Ban event log
```

### Ban Flow Architecture

```
┌──────────────────────────────────────────────────────┐
│              BAN REQUEST (IP, jail, time)            │
└──────────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│         SAFETY CHECKS (7 layers)                     │
├──────────────────────────────────────────────────────┤
│ 1. IP Validation (format, dangerous CIDRs)          │
│ 2. Rate Limit Check (prevent ban flooding)          │
│ 3. Current User IP Check (prevent lockout)          │
│ 4. Server IP Check (prevent self-blocking)          │
│ 5. Whitelist Check (highest priority)               │
│ 6. Duplicate Check (temp_ban, blacklists, feeds)    │
│ 7. nftables Table Check (table must exist)          │
└──────────────────────────────────────────────────────┘
                    ↓
        ┌───────────┴───────────┐
        │    ALL CHECKS PASS    │
        └───────────┬───────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│         ADD TO nftables temp_ban SET                 │
│  nft add element [table] temp_ban                    │
│      { IP timeout 3600s comment "jail" }             │
└──────────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│         LOG BAN EVENT                                │
│  /var/log/nftban/ban.log                             │
│  TIMESTAMP|IP|JAIL|STATUS|REASON                     │
└──────────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│         PERSISTENT OFFENDER CHECK                    │
│  If ban_count >= threshold (default: 3):            │
│    - Add to blacklist-persistent.conf               │
│    - Move to user_blacklist set (permanent)         │
│    - Remove from temp_ban (upgrade to permanent)    │
└──────────────────────────────────────────────────────┘
```

### nftables Ban Priority

```
INPUT CHAIN EVALUATION ORDER:

1. WHITELIST (accept)           ← Highest priority
   ↓
2. Established/Related (accept)
   ↓
3. ICMP (accept)
   ↓
4. SSH Safety Rule (accept)
   ↓
5. Dynamic Ports (accept)
   ↓
6. temp_ban (drop)              ← Temporary bans (with timeout)
   ↓
7. user_blacklist (drop)        ← Permanent bans (persistent offenders + manual)
   ↓
8. system_blacklist (drop)      ← System-managed (reserved)
   ↓
9. feeds (drop)                 ← Threat intelligence feeds
   ↓
10. Default Policy
```

**Key Property**: Whitelist always overrides any ban list.

### Two-Tier Blacklist System

```
┌─────────────────────────────────────────────────────┐
│         PERSISTENT BLACKLIST (Auto-Managed)         │
├─────────────────────────────────────────────────────┤
│ File: /etc/nftban/blacklist-persistent.conf        │
│ Set:  user_blacklist (nftables)                    │
│                                                     │
│ Trigger: IP banned >= threshold times (default: 3) │
│ Action:  Auto-promoted from temp_ban                │
│ Removal: Manual only (nftban blacklist remove IP)  │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│         USER BLACKLIST (Manual)                     │
├─────────────────────────────────────────────────────┤
│ File: /etc/nftban/blacklist-user.conf              │
│ Set:  user_blacklist (nftables)                    │
│                                                     │
│ Trigger: Manual addition (nftban blacklist add IP) │
│ Action:  Immediate permanent ban                    │
│ Removal: Manual only (nftban blacklist remove IP)  │
└─────────────────────────────────────────────────────┘

Both files sync to the SAME nftables set: user_blacklist
```

### Rate Limiting Mechanism

```
/var/nftban/rate-limit-tracker.tmp format:
─────────────────────────────────────
1729600000
1729600001
1729600002
...

Each line: Unix timestamp of ban attempt

Check: Count lines with timestamp >= (now - 60 seconds)
Limit: Default 60 bans/minute
Action: Deny ban if limit exceeded
Cleanup: Remove timestamps older than 2 minutes
```

---

## API Reference

### Initialization Functions

#### `nftban_blacklist_init()`

Initializes the blacklist system.

**Usage:**
```bash
nftban_blacklist_init
```

**Behavior:**
1. Creates `/etc/nftban/blacklist-persistent.conf` (if missing)
2. Creates `/etc/nftban/blacklist-user.conf` (if missing)
3. Creates `/var/nftban/rate-limit-tracker.tmp` (if missing)

**Exit Codes:**
- `0` - Success

**Example:**
```bash
nftban_blacklist_init

# Output:
# [INFO] Initializing blacklist system...
# [DEBUG] Created persistent blacklist
# [DEBUG] Created user blacklist
# [SUCCESS] Blacklist system initialized
```

**Source:** `nftban_blacklist_module.sh:99-142`

---

### Ban Operations

#### `nftban_blacklist_ban_ip(ip, [jail], [ban_time])`

Bans an IP temporarily with comprehensive safety checks.

**Parameters:**
- `ip` (required) - IP address to ban
- `jail` (optional) - Source/reason for ban (default: "manual")
- `ban_time` (optional) - Ban duration in seconds (default: 3600)

**Usage:**
```bash
nftban_blacklist_ban_ip "192.0.2.100" "ssh" 3600
nftban_blacklist_ban_ip "198.51.100.50" "http-bruteforce" 7200
nftban_blacklist_ban_ip "203.0.113.10"  # Uses defaults (manual, 3600s)
```

**Safety Checks (7 layers):**

1. **IP Validation**
   - Format validation
   - Dangerous CIDR blocking (0.0.0.0/0, ::/0)

2. **Rate Limit Check**
   - Checks if ban rate exceeds limit (default: 60/min)
   - Prevents ban flooding attacks

3. **Current User IP Check** (CRITICAL)
   - Detects if banning SSH user's IP
   - **BLOCKS ban and auto-whitelists** the user IP
   - Prevents immediate administrator lockout

4. **Server IP Check** (CRITICAL)
   - Detects if IP belongs to server interface
   - **BLOCKS ban and auto-whitelists** server IP
   - Prevents server self-blocking

5. **Whitelist Check** (CRITICAL)
   - Checks all whitelist sources
   - **BLOCKS ban if whitelisted** (highest priority)
   - Logs whitelist protection event

6. **Duplicate Check**
   - Checks temp_ban set (skip if already there)
   - Checks user_blacklist (permanent)
   - Checks system_blacklist (permanent)
   - Checks feeds (threat intel)

7. **nftables Table Check**
   - Ensures table is initialized

**Ban Execution (if all checks pass):**
```bash
# IPv4
nft add element ip nftban_v4 temp_ban { 192.0.2.100 timeout 3600s comment "ssh" }

# IPv6
nft add element ip6 nftban_v6 temp_ban { 2001:db8::1 timeout 3600s comment "ssh" }
```

**Persistent Offender Detection:**
After successful ban, checks if IP has been banned >= threshold times (default: 3):
- If yes: Auto-promotes to permanent blacklist
- Removes from temp_ban
- Adds to blacklist-persistent.conf and user_blacklist set

**Exit Codes:**
- `0` - Success (banned or already banned)
- `1` - Failed (safety check blocked, rate limit, or nftables error)

**Example Output:**
```bash
# Successful ban
nftban_blacklist_ban_ip "192.0.2.100" "ssh"
# [SUCCESS] Banned 192.0.2.100 for 3600s (jail: ssh)
# [LOG] 2025-10-22 15:30:00|192.0.2.100|ssh|BANNED|Timeout: 3600s

# Current user IP (blocked)
nftban_blacklist_ban_ip "203.0.113.42" "test"
# [ERROR] ⚠️  BLOCKED: Cannot ban current user's IP: 203.0.113.42
# [ERROR] This would cause immediate lockout!
# [WARNING] Auto-whitelisting current user IP for safety...
# [LOG] 2025-10-22 15:30:00|203.0.113.42|test|DENIED|Current user IP - lockout prevention

# Whitelisted IP (blocked)
nftban_blacklist_ban_ip "192.168.1.100" "test"
# [WARNING] WHITELIST PROTECTION: 192.168.1.100
# [WARNING] Action: BAN | Source: test | Reason: Attempted temp ban blocked by whitelist
```

**Source:** `nftban_blacklist_module.sh:185-318`

---

#### `nftban_blacklist_unban_ip(ip, [jail], [force])`

Removes IP from temporary bans and optionally from permanent blacklists.

**Parameters:**
- `ip` (required) - IP address to unban
- `jail` (optional) - Source identifier (default: "manual")
- `force` (optional) - If "true", removes from permanent blacklists too (default: "false")

**Usage:**
```bash
# Normal unban (temp_ban only)
nftban_blacklist_unban_ip "192.0.2.100"

# Force unban (includes permanent blacklists)
nftban_blacklist_unban_ip "192.0.2.100" "manual" "true"
```

**Behavior:**

**Normal Mode (force=false):**
1. Removes from `temp_ban` set
2. **Warns** if in permanent blacklists (does not remove)
3. **Warns** if in threat feeds (read-only, cannot remove)
4. Provides instructions for removal

**Force Mode (force=true):**
1. Removes from `temp_ban` set
2. Removes from `user_blacklist` set
3. Removes from `system_blacklist` set
4. Removes from `blacklist-persistent.conf` file
5. Removes from `blacklist-user.conf` file
6. **Cannot remove** from `feeds` (read-only)

**Exit Codes:**
- `0` - Success (removed from one or more locations)
- `1` - Failed (IP not found in any temporary ban list, or removal error)

**Example Output:**
```bash
# Normal unban (temp_ban only)
nftban_blacklist_unban_ip "192.0.2.100"
# [SUCCESS] Unbanned 192.0.2.100 from: temp_ban

# Normal unban (with warnings)
nftban_blacklist_unban_ip "192.0.2.50"
# [SUCCESS] Unbanned 192.0.2.50 from: temp_ban
# [WARNING] IP is in permanent user blacklist
# [WARNING] IP is in persistent blacklist (repeat offender)
# [INFO] To remove from permanent lists, use: nftban unban --force 192.0.2.50

# Force unban
nftban_blacklist_unban_ip "192.0.2.50" "manual" "true"
# [SUCCESS] Unbanned 192.0.2.50 from: temp_ban user_blacklist blacklist-persistent.conf

# IP in threat feeds (cannot fully unban)
nftban_blacklist_unban_ip "198.51.100.10" "manual" "true"
# [SUCCESS] Unbanned 198.51.100.10 from: temp_ban
# [WARNING] IP is in threat intelligence feeds (read-only)
# [INFO] To allow despite feeds, add to whitelist: nftban whitelist add 198.51.100.10
```

**Source:** `nftban_blacklist_module.sh:324-462`

---

### Permanent Blacklist Operations

#### `nftban_blacklist_add_permanent(ip, [reason])`

Adds IP to permanent blacklist with comprehensive safety checks.

**Parameters:**
- `ip` (required) - IP address to blacklist permanently
- `reason` (optional) - Description (default: "Manual permanent ban")

**Usage:**
```bash
nftban_blacklist_add_permanent "192.0.2.100" "Known attacker"
nftban_blacklist_add_permanent "198.51.100.0/24" "Malicious network"
```

**Safety Checks:**

1. **Whitelist Check** (CRITICAL)
   - **BLOCKS** if IP is whitelisted
   - Requires whitelist removal first

2. **Server IP Check** (CRITICAL)
   - **BLOCKS** if IP is server interface IP

3. **Current User IP Check** (CRITICAL)
   - **BLOCKS** if IP is current user's IP
   - Prevents lockout

4. **Duplicate Check**
   - Checks existing locations
   - Skips if already in permanent blacklist

**Behavior:**
1. Adds to `/etc/nftban/blacklist-persistent.conf` (atomic write with flock)
2. Adds to `user_blacklist` nftables set
3. Removes from `temp_ban` if exists (upgrade to permanent)
4. Logs permanent ban event
5. Rebuilds search index

**Exit Codes:**
- `0` - Success (added or already exists)
- `1` - Failed (safety check blocked or error)

**Example Output:**
```bash
# Successful permanent ban
nftban_blacklist_add_permanent "192.0.2.100" "Known attacker"
# [SUCCESS] Added 192.0.2.100 to permanent blacklist file
# [SUCCESS] Added 192.0.2.100 to permanent blacklist (nftables)
# [INFO] Upgraded from temporary to permanent ban
# [LOG] 2025-10-22 15:30:00|192.0.2.100|PERSISTENT|PERMANENT|Known attacker

# Whitelisted IP (blocked)
nftban_blacklist_add_permanent "192.168.1.100" "Test"
# [WARNING] WHITELIST PROTECTION: 192.168.1.100
# [WARNING] Action: BLACKLIST | Source: PERMANENT | Reason: Attempted permanent blacklist blocked by whitelist
# [ERROR] Remove from whitelist first if you really want to ban this IP

# Current user IP (blocked)
nftban_blacklist_add_permanent "203.0.113.42" "Test"
# [ERROR] ⚠️  BLOCKED: Cannot blacklist current user's IP: 203.0.113.42
# [ERROR] This would cause immediate lockout!

# Already in permanent blacklist
nftban_blacklist_add_permanent "192.0.2.50" "Repeat"
# [INFO] IP 192.0.2.50 already exists in:
# [INFO]   - user_blacklist (nftables)
# [INFO]   - blacklist-persistent.conf (file)
# [INFO] IP already in permanent blacklist, skipping
```

**Source:** `nftban_blacklist_module.sh:488-590`

---

#### `nftban_blacklist_remove_permanent(ip)`

Removes IP from permanent blacklist (files and nftables).

**Parameters:**
- `ip` (required) - IP address to remove

**Usage:**
```bash
nftban_blacklist_remove_permanent "192.0.2.100"
```

**Behavior:**
1. Removes from `blacklist-persistent.conf`
2. Removes from `blacklist-user.conf`
3. Removes from `user_blacklist` nftables set
4. Logs unblacklist event
5. Rebuilds search index

**Exit Codes:**
- `0` - Success (removed from one or more locations)
- `1` - Failed (IP not found)

**Example:**
```bash
nftban_blacklist_remove_permanent "192.0.2.100"

# Output:
# [SUCCESS] Removed 192.0.2.100 from blacklist-persistent.conf
# [SUCCESS] Removed 192.0.2.100 from nftables user_blacklist
# [LOG] 2025-10-22 15:30:00|192.0.2.100|MANUAL|UNBLACKLISTED|Removed from permanent blacklist
```

**Source:** `nftban_blacklist_module.sh:593-634`

---

### Persistent Offender Management

#### `nftban_blacklist_check_persistent_offender(ip)`

Checks if IP qualifies as persistent offender (repeat bans >= threshold).

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
if nftban_blacklist_check_persistent_offender "192.0.2.100"; then
    echo "Persistent offender detected"
fi
```

**Behavior:**
1. Reads ban log (`/var/log/nftban/ban.log`)
2. Counts "BANNED" events for the IP
3. Compares to threshold (default: 3)
4. Returns 0 if >= threshold, 1 otherwise

**Exit Codes:**
- `0` - IP is persistent offender (ban_count >= threshold)
- `1` - IP is not persistent offender (or threshold disabled)

**Example:**
```bash
# Check IP with 5 bans (threshold = 3)
nftban_blacklist_check_persistent_offender "192.0.2.100"
# [WARNING] IP 192.0.2.100 is persistent offender (5 bans, threshold: 3)
# Exit: 0

# Check IP with 2 bans (threshold = 3)
nftban_blacklist_check_persistent_offender "192.0.2.50"
# Exit: 1 (no warning)
```

**Configuration:**
```bash
# Disable persistent offender tracking
export NFTBAN_PERSISTENT_THRESHOLD=0

# Set custom threshold (5 bans)
export NFTBAN_PERSISTENT_THRESHOLD=5
```

**Source:** `nftban_blacklist_module.sh:469-485`

---

### Rate Limiting Functions

#### `nftban_blacklist_check_rate_limit()`

Checks if current ban rate exceeds limit.

**Usage:**
```bash
if ! nftban_blacklist_check_rate_limit; then
    echo "Rate limit exceeded, ban denied"
fi
```

**Behavior:**
1. Reads `/var/nftban/rate-limit-tracker.tmp`
2. Counts timestamps from last 60 seconds
3. Compares to limit (default: 60 bans/minute)
4. Returns 0 if within limit, 1 if exceeded

**Exit Codes:**
- `0` - Within rate limit
- `1` - Rate limit exceeded

**Example:**
```bash
# Within limit
nftban_blacklist_check_rate_limit
# Exit: 0

# Limit exceeded
nftban_blacklist_check_rate_limit
# [ERROR] RATE LIMIT EXCEEDED: 65 bans/min (limit: 60)
# Exit: 1
```

**Configuration:**
```bash
# Set custom rate limit (100 bans/minute)
export NFTBAN_RATE_LIMIT_PER_MIN=100

# Disable rate limiting
export NFTBAN_RATE_LIMIT_PER_MIN=999999
```

**Source:** `nftban_blacklist_module.sh:148-162`

---

#### `nftban_blacklist_record_ban_attempt()`

Records a ban attempt for rate limiting (internal use).

**Usage:**
```bash
nftban_blacklist_record_ban_attempt
```

**Behavior:**
1. Gets current Unix timestamp
2. Appends to `/var/nftban/rate-limit-tracker.tmp` (atomic with flock)
3. Cleans up old entries (> 2 minutes old)

**Exit Codes:**
- `0` - Success
- `1` - Failed (lock timeout)

**Source:** `nftban_blacklist_module.sh:164-178`

---

### Display & Statistics Functions

#### `nftban_blacklist_list_permanent()`

Displays comprehensive permanent blacklist status.

**Usage:**
```bash
nftban_blacklist_list_permanent
```

**Output Sections:**
1. Persistent Offenders (auto-added repeat offenders)
2. User Blacklist (manual permanent bans)
3. nftables Sets (user_blacklist, system_blacklist, temp_ban, feeds counts)

**Example Output:**
```
═══════════════════════════════════════════════════════
  Permanent Blacklist
═══════════════════════════════════════════════════════

Persistent Offenders (Auto-added):
  1. 192.0.2.100  # 2025-10-22 15:00:00 - Repeat offender: 5 bans from ssh
  2. 192.0.2.101  # 2025-10-22 16:00:00 - Repeat offender: 4 bans from http

User Blacklist (Manual):
  1. 198.51.100.0/24  # Known malicious network
  2. 203.0.113.50     # Manual ban - attacker

nftables Sets:
  user_blacklist_v4:        4 IPs
  user_blacklist_v6:        0 IPs
  system_blacklist_v4:      0 IPs
  system_blacklist_v6:      0 IPs
  temp_ban_v4:              12 IPs
  temp_ban_v6:              2 IPs
  feeds_v4:                 1523 IPs
  feeds_v6:                 45 IPs
```

**Source:** `nftban_blacklist_module.sh:641-680`

---

#### `nftban_blacklist_show_recent_stats()`

Shows ban statistics from last 24 hours.

**Usage:**
```bash
nftban_blacklist_show_recent_stats
```

**Output:**
```
Bans: 45 | Denied: 3 | Permanent: 2
```

**Example:**
```bash
echo "Last 24 hours:"
nftban_blacklist_show_recent_stats

# Output:
# Last 24 hours:
# Bans: 45 | Denied: 3 | Permanent: 2
```

**Source:** `nftban_blacklist_module.sh:745-763`

---

#### `nftban_blacklist_get_top_ips([limit])`

Returns top banned IPs sorted by ban count.

**Parameters:**
- `limit` (optional) - Number of IPs to return (default: 10)

**Usage:**
```bash
nftban_blacklist_get_top_ips 5
```

**Output Format:**
```
5 192.0.2.100
3 192.0.2.101
2 198.51.100.50
1 203.0.113.10
1 203.0.113.11
```

**Example:**
```bash
echo "Top 5 banned IPs:"
nftban_blacklist_get_top_ips 5

# Output:
# Top 5 banned IPs:
#       5 192.0.2.100
#       3 192.0.2.101
#       2 198.51.100.50
#       1 203.0.113.10
#       1 203.0.113.11
```

**Source:** `nftban_blacklist_module.sh:766-775`

---

#### `nftban_blacklist_get_ip_ban_count(ip)`

Returns total ban count for a specific IP.

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
count=$(nftban_blacklist_get_ip_ban_count "192.0.2.100")
echo "Ban count: $count"
```

**Example:**
```bash
count=$(nftban_blacklist_get_ip_ban_count "192.0.2.100")
echo "192.0.2.100 has been banned $count times"

# Output:
# 192.0.2.100 has been banned 5 times
```

**Source:** `nftban_blacklist_module.sh:778-787`

---

### Synchronization Functions

#### `nftban_blacklist_sync_to_nftables()`

Syncs blacklist files to nftables user_blacklist set.

**Usage:**
```bash
nftban_blacklist_sync_to_nftables
```

**Behavior:**
1. Flushes `user_blacklist` sets (IPv4 and IPv6)
2. Reads `blacklist-persistent.conf` and `blacklist-user.conf`
3. Adds each IP to appropriate nftables set
4. Reports sync count

**Exit Codes:**
- `0` - Success
- `1` - nftables table not initialized

**Example:**
```bash
nftban_blacklist_sync_to_nftables

# Output:
# [INFO] Syncing blacklist to nftables...
# [SUCCESS] Synced to nftables: 4 IPv4, 0 IPv6
```

**When to Use:**
- After manual file edits
- After system restore
- During troubleshooting
- After bulk unban operations

**Source:** `nftban_blacklist_module.sh:687-738`

---

### Internal Helper Functions

#### `_nftban_blacklist_get_table_info(version)`

⚠️ **Internal function** - Do not call directly.

Returns table family and name for IP version (split table helper).

**Parameters:**
- `version` - IP version ("4" or "6")

**Output:**
```bash
# For IPv4:
ip nftban_v4

# For IPv6:
ip6 nftban_v6
```

**Source:** `nftban_blacklist_module.sh:86-93`

---

#### `_nftban_blacklist_safe_append(file, content)`

⚠️ **Internal function** - Do not call directly.

Atomically appends content to a file using exclusive lock.

**Security Features:**
- Exclusive lock (flock -x) prevents concurrent writes
- Timeout (5 seconds) prevents indefinite blocking
- Atomic append (single write operation)

**Source:** `nftban_blacklist_module.sh:44-60`

---

#### `_nftban_blacklist_safe_modify(file, sed_expression)`

⚠️ **Internal function** - Do not call directly.

Atomically modifies a file using sed under exclusive lock.

**Source:** `nftban_blacklist_module.sh:63-79`

---

## Integration Guide

### Integration with Core Module

**Initialization Order:**
```bash
# 1. Load core module
source /usr/local/lib/nftban/nftban_core.sh

# 2. Load whitelist (for safety checks)
source /usr/local/lib/nftban/nftban_whitelist_module.sh

# 3. Load nftables module
source /usr/local/lib/nftban/nftban_nftables_module.sh

# 4. Load blacklist module
source /usr/local/lib/nftban/nftban_blacklist_module.sh

# 5. Initialize blacklist system
nftban_blacklist_init
```

### Integration with CLI

**Command Examples:**
```bash
# Ban IP
nftban ban 192.0.2.100 --jail ssh --time 3600

# Unban IP
nftban unban 192.0.2.100

# Force unban (including permanent)
nftban unban --force 192.0.2.100

# Permanent ban
nftban blacklist add 192.0.2.100 "Known attacker"

# Remove from permanent blacklist
nftban blacklist remove 192.0.2.100

# List permanent blacklist
nftban blacklist list

# Show statistics
nftban stats
```

**CLI Implementation Example:**
```bash
case "$1" in
    ban)
        nftban_blacklist_ban_ip "$2" "${3:-manual}" "${4:-$NFTBAN_DEFAULT_BAN_TIME}"
        ;;
    unban)
        if [[ "$2" == "--force" ]]; then
            nftban_blacklist_unban_ip "$3" "manual" "true"
        else
            nftban_blacklist_unban_ip "$2" "manual" "false"
        fi
        ;;
    blacklist)
        case "$2" in
            add)
                nftban_blacklist_add_permanent "$3" "${4:-Manual permanent ban}"
                ;;
            remove)
                nftban_blacklist_remove_permanent "$3"
                ;;
            list)
                nftban_blacklist_list_permanent
                ;;
        esac
        ;;
esac
```

### Integration with Fail2Ban

**Fail2Ban Action Script (`/etc/fail2ban/action.d/nftban.conf`):**
```bash
[Definition]
actionstart =
actionstop =
actioncheck =

actionban = /usr/local/bin/nftban ban <ip> --jail <name> --time <bantime>

actionunban = /usr/local/bin/nftban unban <ip>
```

**Example Jail (`/etc/fail2ban/jail.d/sshd.local`):**
```ini
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 3600
action = nftban
```

### Integration with Login Monitor

**Login Monitor Integration:**
```bash
# In nftban_login_monitor_module.sh

nftban_login_monitor_check_failed_login() {
    local ip="$1"
    local attempts="$2"
    local threshold="$NFTBAN_LOGIN_THRESHOLD"

    if [[ $attempts -ge $threshold ]]; then
        nftban_log_warning "Failed login threshold exceeded: $ip ($attempts attempts)"

        # Ban IP using blacklist module
        nftban_blacklist_ban_ip "$ip" "login-monitor" "$NFTBAN_LOGIN_BAN_TIME"
    fi
}
```

### Integration with DDoS Module

**DDoS Detection Integration:**
```bash
# In nftban_ddos_module.sh

nftban_ddos_handle_attack() {
    local ip="$1"
    local rate="$2"

    nftban_log_error "DDoS attack detected from $ip (rate: $rate pps)"

    # Ban IP with extended timeout
    nftban_blacklist_ban_ip "$ip" "ddos" 86400  # 24 hours
}
```

### Integration with Port Scan Detection

**Port Scan Handler:**
```bash
# In nftban_portscan_module.sh

nftban_portscan_handle_scanner() {
    local ip="$1"
    local ports_scanned="$2"

    nftban_log_warning "Port scan detected from $ip ($ports_scanned ports)"

    # Ban for 12 hours
    nftban_blacklist_ban_ip "$ip" "portscan" 43200
}
```

---

## Configuration

### File Locations

```bash
# Default paths (from nftban_core.sh)
NFTBAN_CONFIG_DIR="/etc/nftban"
NFTBAN_DATA_DIR="/var/nftban"
NFTBAN_LOCK_DIR="/var/lock/nftban"

# Blacklist files
NFTBAN_BLACKLIST_PERSISTENT="${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
NFTBAN_BLACKLIST_USER="${NFTBAN_CONFIG_DIR}/blacklist-user.conf"

# Rate limit tracker
NFTBAN_RATE_LIMIT_FILE="${NFTBAN_DATA_DIR}/rate-limit-tracker.tmp"

# Lock timeout
NFTBAN_BLACKLIST_LOCK_TIMEOUT=5  # seconds
```

### Configuration Variables

**Environment Variables (can override in `/etc/nftban/nftban.conf.local`):**

```bash
# Default ban time (seconds)
NFTBAN_DEFAULT_BAN_TIME=3600  # 1 hour

# Persistent offender threshold (number of bans)
NFTBAN_PERSISTENT_THRESHOLD=3  # Auto-promote after 3 bans

# Rate limit (bans per minute)
NFTBAN_RATE_LIMIT_PER_MIN=60

# Disable persistent offender tracking
NFTBAN_PERSISTENT_THRESHOLD=0

# Disable rate limiting
NFTBAN_RATE_LIMIT_PER_MIN=999999
```

### File Formats

**Persistent Blacklist (`blacklist-persistent.conf`):**
```bash
# =============================================================================
# nftban Persistent Blacklist
# =============================================================================
# Auto-managed: IPs that have been banned multiple times
# =============================================================================

192.0.2.100  # 2025-10-22 15:00:00 - Repeat offender: 5 bans from ssh
192.0.2.101  # 2025-10-22 16:00:00 - Repeat offender: 4 bans from http
198.51.100.50  # 2025-10-22 17:00:00 - Repeat offender: 3 bans from fail2ban
```

**User Blacklist (`blacklist-user.conf`):**
```bash
# =============================================================================
# nftban User Blacklist
# =============================================================================
# Manually managed permanent bans
# =============================================================================

198.51.100.0/24  # Known malicious network
203.0.113.50     # Manual ban - attacker
2001:db8:bad::/48  # IPv6 malicious range
```

**Rate Limit Tracker (`rate-limit-tracker.tmp`):**
```
1729600000
1729600001
1729600015
1729600032
```

### File Permissions

```bash
# Blacklist files
chmod 644 /etc/nftban/blacklist-*.conf

# Rate limit tracker
chmod 600 /var/nftban/rate-limit-tracker.tmp

# Lock directory
chmod 755 /var/lock/nftban
```

---

## Security Considerations

### Security Model

**Threat Model:**
1. **Administrator Lockout** - Primary threat mitigated by safety checks
2. **Server Self-Blocking** - Prevented by server IP detection
3. **Whitelist Bypass** - Prevented by mandatory whitelist check
4. **Ban Flooding** - Mitigated by rate limiting
5. **Race Conditions** - Prevented by flock-based atomic operations

**Security Principles:**
- **Defense in Depth**: 7-layer safety check system
- **Fail-Safe Defaults**: Auto-whitelist on lockout risk
- **Least Privilege**: Separate persistent vs. user blacklists
- **Atomic Operations**: flock ensures consistency

### Safety Check Priority

```
BAN REQUEST
    ↓
[1] IP Validation (format, dangerous CIDRs)
    ↓
[2] Rate Limit (prevent flooding)
    ↓
[3] Current User IP (CRITICAL - prevent lockout)
    ↓  BLOCKED → Auto-whitelist user IP
    ↓
[4] Server IP (CRITICAL - prevent self-block)
    ↓  BLOCKED → Auto-whitelist server IP
    ↓
[5] Whitelist Check (CRITICAL - highest priority)
    ↓  BLOCKED → Log whitelist protection event
    ↓
[6] Duplicate Check (temp_ban, blacklists, feeds)
    ↓  EXISTS → Skip (already banned)
    ↓
[7] nftables Table Check (must exist)
    ↓  MISSING → Error
    ↓
✅ ALL CHECKS PASSED → Execute Ban
```

### Historical Vulnerabilities

#### BUG61: Arithmetic Expansion in Strict Mode

**Severity:** LOW (affects stability, not security)
**Discovered:** v0.9.3 testing with `set -u`
**Fixed in:** v0.9.3

**Issue:**
```bash
# OLD CODE (fails with set -u):
synced_v4=0
((synced_v4++))  # ERROR when synced_v4=0 in strict mode
```

**Fix:**
```bash
# NEW CODE (v0.9.3):
synced_v4=0
synced_v4=$((synced_v4 + 1))  # Safe in strict mode
```

**Affected Functions:**
- `nftban_blacklist_sync_to_nftables`

---

### Attack Surface Analysis

**Ban Operation Security:**
- **Risk**: Malicious user bans legitimate IPs
- **Mitigation**:
  - Whitelist protection (cannot ban whitelisted IPs)
  - Current user IP protection (cannot ban self)
  - Server IP protection (cannot ban server)
  - Logging (all ban attempts logged)

**Rate Limiting Security:**
- **Risk**: Ban flooding attack (exhaust rate limit)
- **Mitigation**:
  - Rate limit file (atomic write with flock)
  - Automatic cleanup (old entries removed)
  - Limit: 60 bans/minute (configurable)

**File System Operations:**
- **Risk**: Unauthorized file modification
- **Mitigation**:
  - File permissions (644) - root write only
  - flock prevents race conditions
  - Strict umask (027)

**nftables Integration:**
- **Risk**: Privilege escalation via nft command
- **Mitigation**:
  - Requires root/CAP_NET_ADMIN
  - Input validation before nft calls
  - Sanitized IP addresses

### Lockout Prevention Mechanisms

**1. Current User IP Detection:**
```bash
current_user_ip=$(nftban_get_current_user_ip)
# Sources: SSH_CLIENT, SSH_CONNECTION environment variables

if [[ -n "$current_user_ip" && "$current_user_ip" == "$ip" ]]; then
    # BLOCK ban
    # AUTO-WHITELIST user IP
    nftban_log_error "⚠️  BLOCKED: Cannot ban current user's IP: $ip"

    # Add to whitelist for permanent protection
    _nftban_blacklist_safe_append "${NFTBAN_CONFIG_DIR}/whitelist-user.conf" \
        "${ip}  # Current user (auto-protected on $(date))"

    nftban_whitelist_sync_to_nftables
    return 1
fi
```

**2. Server IP Detection:**
```bash
if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
    # BLOCK ban
    # AUTO-WHITELIST server IP
    nftban_log_error "⚠️  BLOCKED: Cannot ban server's own IP: $ip"

    _nftban_blacklist_safe_append "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" \
        "${ip}  # Server IP (auto-protected on $(date))"

    nftban_whitelist_sync_to_nftables
    return 1
fi
```

**3. Whitelist Priority:**
```bash
# Whitelist ALWAYS checked before ban
if nftban_whitelist_check_ip "$ip"; then
    # BLOCK ban
    # LOG whitelist protection event
    nftban_log_whitelist_protection "$ip" "BAN" "$jail" "Attempted ban blocked"
    return 1
fi
```

### Compliance

**CWE Mitigations:**
- **CWE-362**: Race Condition (flock-based atomicity)
- **CWE-400**: Uncontrolled Resource Consumption (rate limiting)
- **CWE-732**: Incorrect Permission Assignment (umask 027, chmod 644)
- **CWE-703**: Improper Check or Handling of Exceptional Conditions (7-layer safety)

**Security Standards:**
- **NIST 800-53**: AC-7 (Unsuccessful Logon Attempts), SC-5 (Denial of Service Protection)
- **CIS Controls**: 6.2 (Activate Audit Logging), 8.3 (Enable Operating System Anti-Exploitation Features)

---

## Troubleshooting

### Common Issues

#### Issue 1: Ban Denied - Current User IP

**Symptoms:**
```
[ERROR] ⚠️  BLOCKED: Cannot ban current user's IP: 203.0.113.42
[ERROR] This would cause immediate lockout!
```

**Cause:**
Attempting to ban the IP you're connecting from.

**Solutions:**
```bash
# OPTION 1: Connect from different IP first
ssh admin@server -s 198.51.100.10
nftban ban 203.0.113.42

# OPTION 2: Add IP to whitelist first (makes ban impossible)
nftban whitelist add 203.0.113.42

# OPTION 3: Use local console (not SSH)
# Physical access or KVM
nftban ban 203.0.113.42

# OPTION 4: Temporarily disable safety check (DANGEROUS)
# Edit source code: Comment out current user check (NOT RECOMMENDED)
```

---

#### Issue 2: Rate Limit Exceeded

**Symptoms:**
```
[ERROR] RATE LIMIT EXCEEDED: 65 bans/min (limit: 60)
```

**Causes:**
1. Automated ban script running too fast
2. Multiple concurrent ban sources
3. Ban flooding attack

**Solutions:**
```bash
# Check rate limit tracker
wc -l /var/nftban/rate-limit-tracker.tmp

# Increase rate limit temporarily
export NFTBAN_RATE_LIMIT_PER_MIN=100
nftban ban ...

# Disable rate limiting
export NFTBAN_RATE_LIMIT_PER_MIN=999999

# Clear rate limit tracker
> /var/nftban/rate-limit-tracker.tmp

# Add delay in scripts
for ip in "${ips[@]}"; do
    nftban ban "$ip"
    sleep 0.1  # 10 bans/second = 600/minute (exceeds limit)
done

# Better: Batch processing
for ip in "${ips[@]}"; do
    echo "$ip" >> /tmp/batch-ban.txt
done
nftban import /tmp/batch-ban.txt
```

---

#### Issue 3: IP Not Banned (Whitelisted)

**Symptoms:**
```
[WARNING] WHITELIST PROTECTION: 192.168.1.100
```

**Cause:**
IP is in whitelist (blocks all bans).

**Solutions:**
```bash
# Check whitelist status
nftban whitelist list | grep 192.168.1.100

# Remove from whitelist first
nftban whitelist remove 192.168.1.100

# Then ban
nftban ban 192.168.1.100

# OR: Force ban by editing whitelist file directly (NOT RECOMMENDED)
sudo nano /etc/nftban/whitelist-user.conf
# Remove the line with the IP
nftban whitelist sync
nftban ban 192.168.1.100
```

---

#### Issue 4: Cannot Unban (In Permanent Blacklist)

**Symptoms:**
```bash
nftban unban 192.0.2.100
# [SUCCESS] Unbanned 192.0.2.100 from: temp_ban
# [WARNING] IP is in permanent user blacklist
# [INFO] To remove from permanent lists, use: nftban unban --force
```

**Cause:**
IP is in permanent blacklist (persistent offender or manual).

**Solutions:**
```bash
# Check permanent blacklist
nftban blacklist list | grep 192.0.2.100

# Force unban (removes from ALL locations)
nftban unban --force 192.0.2.100

# OR: Remove from permanent blacklist specifically
nftban blacklist remove 192.0.2.100
```

---

#### Issue 5: Persistent Offender Auto-Ban

**Symptoms:**
```
[WARNING] IP 192.0.2.100 is persistent offender (5 bans, threshold: 3)
[INFO] Upgraded from temporary to permanent ban
```

**Cause:**
IP has been banned >= threshold times (default: 3).

**Solutions:**
```bash
# Disable persistent offender tracking
export NFTBAN_PERSISTENT_THRESHOLD=0

# Increase threshold
export NFTBAN_PERSISTENT_THRESHOLD=10

# Remove from persistent blacklist
nftban blacklist remove 192.0.2.100

# Check ban count for IP
nftban_blacklist_get_ip_ban_count "192.0.2.100"
```

---

#### Issue 6: Lock Timeout During Ban

**Symptoms:**
```
[ERROR] Could not acquire write lock on /etc/nftban/blacklist-persistent.conf
```

**Causes:**
1. Another nftban process is writing
2. Stale lock file (crashed process)

**Solutions:**
```bash
# Check for running nftban processes
ps aux | grep nftban

# Remove stale lock files (if no processes running)
rm -f /var/lock/nftban/blacklist-*.lock

# Increase lock timeout
export NFTBAN_BLACKLIST_LOCK_TIMEOUT=10
nftban ban ...

# Check lock directory permissions
ls -ld /var/lock/nftban/
# Should be: drwxr-xr-x root root
```

---

### Debugging

**Enable Debug Logging:**
```bash
export NFTBAN_LOG_LEVEL=debug
nftban ban 192.0.2.100
```

**Debug Output:**
```
[DEBUG] NFTBan Blacklist Module loaded (v2.0.0 - Split Tables)
[DEBUG] Validating IP: 192.0.2.100
[DEBUG] IP version detected: 4
[DEBUG] Checking rate limit...
[DEBUG] Recent bans: 15 (limit: 60)
[DEBUG] Rate limit OK
[DEBUG] Recording ban attempt
[DEBUG] Checking current user IP...
[DEBUG] Current user IP: 203.0.113.42 (different from 192.0.2.100)
[DEBUG] Checking server IPs...
[DEBUG] Server IPs: 10.0.0.5, 192.168.1.10
[DEBUG] Not a server IP
[DEBUG] Checking whitelist...
[DEBUG] Not whitelisted
[DEBUG] Checking for duplicates...
[DEBUG] Not in temp_ban
[DEBUG] Not in user_blacklist
[DEBUG] Adding to nftables: ip nftban_v4 temp_ban { 192.0.2.100 timeout 3600s comment "manual" }
[SUCCESS] Banned 192.0.2.100 for 3600s (jail: manual)
```

**Check nftables Sets:**
```bash
# List temp_ban set
nft list set ip nftban_v4 temp_ban

# List user_blacklist set
nft list set ip nftban_v4 user_blacklist

# Check if specific IP is in set
nft list set ip nftban_v4 temp_ban | grep 192.0.2.100
```

**Check Ban Log:**
```bash
# View recent bans
tail -n 50 /var/log/nftban/ban.log

# Filter by IP
grep "192.0.2.100" /var/log/nftban/ban.log

# Filter by status
grep "|BANNED|" /var/log/nftban/ban.log
grep "|DENIED|" /var/log/nftban/ban.log

# Count bans per IP
awk -F'|' '{print $2}' /var/log/nftban/ban.log | sort | uniq -c | sort -rn
```

**Verify Function Exports:**
```bash
declare -F | grep nftban_blacklist

# Expected output:
# declare -fx nftban_blacklist_ban_ip
# declare -fx nftban_blacklist_unban_ip
# declare -fx nftban_blacklist_add_permanent
# ...
```

---

## Testing

### Unit Tests

**Test 1: Basic Ban Operation**
```bash
#!/bin/bash
# Test: Ban IP successfully

test_ban_ip() {
    local test_ip="192.0.99.99"

    # Ban IP
    nftban_blacklist_ban_ip "$test_ip" "test" 60 || {
        echo "FAIL: Could not ban IP"
        return 1
    }

    # Verify in nftables
    if ! nft list set ip nftban_v4 temp_ban | grep -q "$test_ip"; then
        echo "FAIL: IP not in nftables temp_ban set"
        return 1
    }

    # Verify in ban log
    if ! grep -q "|${test_ip}|test|BANNED|" "$NFTBAN_BAN_LOG"; then
        echo "FAIL: Ban not logged"
        return 1
    }

    # Wait for timeout
    sleep 61

    # Verify auto-expiration
    if nft list set ip nftban_v4 temp_ban | grep -q "$test_ip"; then
        echo "FAIL: IP still in set after timeout"
        return 1
    fi

    echo "PASS: Ban operation"
    return 0
}

test_ban_ip
```

---

**Test 2: Safety Checks**
```bash
test_safety_checks() {
    # Test 1: Cannot ban current user IP
    local current_ip=$(nftban_get_current_user_ip)

    if [[ -n "$current_ip" ]]; then
        if nftban_blacklist_ban_ip "$current_ip" "test" 2>/dev/null; then
            echo "FAIL: Allowed ban of current user IP"
            return 1
        fi

        # Verify auto-whitelist
        if ! nftban_whitelist_check_ip "$current_ip"; then
            echo "FAIL: Current user IP not auto-whitelisted"
            return 1
        fi
    fi

    # Test 2: Cannot ban server IP
    local server_ip=$(ip -o -4 addr show | awk '/inet/ {gsub(/\/.*/, "", $4); print $4; exit}')

    if [[ -n "$server_ip" && "$server_ip" != "127.0.0.1" ]]; then
        if nftban_blacklist_ban_ip "$server_ip" "test" 2>/dev/null; then
            echo "FAIL: Allowed ban of server IP"
            return 1
        fi
    fi

    # Test 3: Cannot ban whitelisted IP
    nftban_whitelist_add_ip "192.0.98.98" "Test whitelist"

    if nftban_blacklist_ban_ip "192.0.98.98" "test" 2>/dev/null; then
        echo "FAIL: Allowed ban of whitelisted IP"
        return 1
    fi

    nftban_whitelist_remove_ip "192.0.98.98"

    echo "PASS: Safety checks"
    return 0
}

test_safety_checks
```

---

**Test 3: Persistent Offender Detection**
```bash
test_persistent_offender() {
    local test_ip="192.0.97.97"
    local threshold=3

    export NFTBAN_PERSISTENT_THRESHOLD=$threshold

    # Ban IP multiple times (with unban between)
    for i in $(seq 1 $threshold); do
        nftban_blacklist_ban_ip "$test_ip" "test-$i" 5 || {
            echo "FAIL: Ban $i failed"
            return 1
        }

        # Wait for timeout
        sleep 6

        # Verify expired
        if nft list set ip nftban_v4 temp_ban | grep -q "$test_ip"; then
            echo "FAIL: Ban $i did not expire"
            return 1
        fi
    done

    # Next ban should trigger persistent offender
    nftban_blacklist_ban_ip "$test_ip" "test-final" 60

    # Verify in permanent blacklist
    if ! grep -q "$test_ip" "$NFTBAN_BLACKLIST_PERSISTENT"; then
        echo "FAIL: Not added to persistent blacklist"
        return 1
    fi

    if ! nft list set ip nftban_v4 user_blacklist | grep -q "$test_ip"; then
        echo "FAIL: Not in user_blacklist set"
        return 1
    }

    # Verify NOT in temp_ban (upgraded to permanent)
    if nft list set ip nftban_v4 temp_ban | grep -q "$test_ip"; then
        echo "FAIL: Still in temp_ban (should be upgraded)"
        return 1
    fi

    # Cleanup
    nftban_blacklist_remove_permanent "$test_ip"

    echo "PASS: Persistent offender detection"
    return 0
}

test_persistent_offender
```

---

**Test 4: Rate Limiting**
```bash
test_rate_limiting() {
    local limit=60
    export NFTBAN_RATE_LIMIT_PER_MIN=$limit

    # Clear rate limit tracker
    > "$NFTBAN_RATE_LIMIT_FILE"

    # Ban many IPs rapidly
    local ban_count=0
    for i in $(seq 1 70); do
        local ip="192.0.96.$((i % 256))"

        if nftban_blacklist_ban_ip "$ip" "rate-test" 60 2>/dev/null; then
            ban_count=$((ban_count + 1))
        else
            # Should fail after limit reached
            break
        fi
    done

    if [[ $ban_count -gt $limit ]]; then
        echo "FAIL: Rate limit not enforced ($ban_count > $limit)"
        return 1
    fi

    if [[ $ban_count -lt $limit ]]; then
        echo "FAIL: Rate limit too restrictive ($ban_count < $limit)"
        return 1
    fi

    echo "PASS: Rate limiting ($ban_count bans allowed)"
    return 0
}

test_rate_limiting
```

---

**Test 5: Comprehensive Unban**
```bash
test_comprehensive_unban() {
    local test_ip="192.0.95.95"

    # Add to multiple locations
    nftban_blacklist_ban_ip "$test_ip" "test" 3600
    nftban_blacklist_add_permanent "$test_ip" "Test permanent"

    # Verify in both temp_ban and user_blacklist
    nft list set ip nftban_v4 temp_ban | grep -q "$test_ip" || {
        echo "FAIL: Not in temp_ban"
        return 1
    }

    nft list set ip nftban_v4 user_blacklist | grep -q "$test_ip" || {
        echo "FAIL: Not in user_blacklist"
        return 1
    }

    # Normal unban (temp_ban only)
    nftban_blacklist_unban_ip "$test_ip" "test" "false"

    # Verify temp_ban removed
    if nft list set ip nftban_v4 temp_ban | grep -q "$test_ip"; then
        echo "FAIL: Still in temp_ban after unban"
        return 1
    fi

    # Verify user_blacklist still present
    if ! nft list set ip nftban_v4 user_blacklist | grep -q "$test_ip"; then
        echo "FAIL: user_blacklist removed (should remain)"
        return 1
    fi

    # Force unban (all locations)
    nftban_blacklist_unban_ip "$test_ip" "test" "true"

    # Verify user_blacklist removed
    if nft list set ip nftban_v4 user_blacklist | grep -q "$test_ip"; then
        echo "FAIL: Still in user_blacklist after force unban"
        return 1
    fi

    # Verify file removed
    if grep -q "$test_ip" "$NFTBAN_BLACKLIST_PERSISTENT"; then
        echo "FAIL: Still in persistent blacklist file"
        return 1
    fi

    echo "PASS: Comprehensive unban"
    return 0
}

test_comprehensive_unban
```

---

### Integration Tests

**Test 6: Ban Log Integrity**
```bash
test_ban_log_integrity() {
    local test_ip="192.0.94.94"

    # Clear log
    > "$NFTBAN_BAN_LOG"

    # Perform various operations
    nftban_blacklist_ban_ip "$test_ip" "test1" 60
    nftban_blacklist_unban_ip "$test_ip"
    nftban_blacklist_ban_ip "$test_ip" "test2" 60
    nftban_blacklist_add_permanent "$test_ip" "Test"
    nftban_blacklist_remove_permanent "$test_ip"

    # Verify log entries
    local entries=$(grep -c "$test_ip" "$NFTBAN_BAN_LOG")

    if [[ $entries -ne 5 ]]; then
        echo "FAIL: Expected 5 log entries, got $entries"
        cat "$NFTBAN_BAN_LOG"
        return 1
    fi

    # Verify log format
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\|.*\|.*\|.*\|.* ]]; then
            echo "FAIL: Invalid log format: $line"
            return 1
        fi
    done < <(grep "$test_ip" "$NFTBAN_BAN_LOG")

    echo "PASS: Ban log integrity"
    return 0
}

test_ban_log_integrity
```

---

## Performance

### Benchmarks

**Ban Operation Performance:**
```
Operation                           Time (avg)    Notes
------------------------------------------------------------
Ban IP (no checks fail)             10-20ms       IP validation + nft add
Ban IP (whitelist check fails)      < 5ms         Early exit (fast)
Ban IP (rate limit fails)           < 1ms         File read only
Unban IP (temp_ban only)            5-10ms        nft delete
Unban IP (force, all locations)     20-50ms       Multiple nft + file ops
Add permanent blacklist             15-30ms       File write + nft add
Persistent offender check           5-15ms        Log file grep
```

**Rate Limit Check Performance:**
```
Tracker Size       Check Time    Notes
-----------------------------------------
< 100 entries      < 1ms         awk filter
100-1000 entries   1-5ms         Linear scan
> 1000 entries     5-20ms        Consider cleanup
```

**Sync Operation Performance:**
```
Blacklist Size     Sync Time    Notes
-----------------------------------------
< 100 IPs          < 100ms      Fast
100-1000 IPs       100-500ms    Acceptable
1000-10000 IPs     500ms-5s     Noticeable
> 10000 IPs        5-30s        Consider optimization
```

### Optimization Tips

**1. Batch Ban Operations**
```bash
# BAD: Individual bans (slow)
for ip in "${ips[@]}"; do
    nftban ban "$ip"  # 10-20ms each
done

# GOOD: Batch import
cat > /tmp/batch-ban.txt << EOF
${ips[@]}
EOF
nftban import /tmp/batch-ban.txt --timeout 3600
```

**2. Increase Rate Limit for Bulk Operations**
```bash
# Temporarily increase limit
export NFTBAN_RATE_LIMIT_PER_MIN=1000

# Perform bulk bans
for ip in "${ips[@]}"; do
    nftban ban "$ip"
done

# Reset to default
export NFTBAN_RATE_LIMIT_PER_MIN=60
```

**3. Disable Persistent Offender Tracking (Bulk Imports)**
```bash
# Disable for performance
export NFTBAN_PERSISTENT_THRESHOLD=0

# Import large list
nftban import large-ban-list.txt

# Re-enable
export NFTBAN_PERSISTENT_THRESHOLD=3
```

**4. Use Direct nftables for Read Operations**
```bash
# SLOW: Function call overhead
if nftban_blacklist_check_ip "$ip"; then ...

# FAST: Direct nftables query
if nft list set ip nftban_v4 temp_ban | grep -q "$ip"; then ...
```

### Memory Usage

**File Storage:**
```
File Type              Size (1000 IPs)    Memory (loaded)
-----------------------------------------------------------
blacklist-persistent   ~50 KB             < 5 MB
blacklist-user         ~50 KB             < 5 MB
rate-limit-tracker     ~10 KB (60 sec)    < 1 MB
ban.log                ~200 KB/day        N/A (stream)
```

**nftables Memory:**
```
Set Size          Kernel Memory    Performance Impact
------------------------------------------------------
temp_ban (100)    ~10 KB           Negligible
temp_ban (1000)   ~100 KB          Negligible
temp_ban (10000)  ~1 MB            Low
user_blacklist    Same as above    Same as above
```

---

## Maintenance

### Regular Maintenance Tasks

**Daily:**
```bash
# Check ban statistics
nftban stats

# Review recent bans
tail -n 100 /var/log/nftban/ban.log

# Check for lockout risks
nftban whitelist verify
```

**Weekly:**
```bash
# Review persistent offenders
nftban blacklist list

# Check rate limit tracker size
wc -l /var/nftban/rate-limit-tracker.tmp

# Verify nftables sync
nftban blacklist sync
```

**Monthly:**
```bash
# Audit permanent blacklist
grep -E "^[0-9]" /etc/nftban/blacklist-persistent.conf | wc -l

# Review top banned IPs
nftban_blacklist_get_top_ips 20

# Clean up old ban log entries (keep last 30 days)
find /var/log/nftban/ -name "ban.log.*" -mtime +30 -delete
```

### Backup and Restore

**Backup Blacklist:**
```bash
# Backup all blacklist data
tar -czf nftban-blacklist-backup-$(date +%Y%m%d).tar.gz \
    /etc/nftban/blacklist-*.conf \
    /var/log/nftban/ban.log

# Backup with metadata
cat > blacklist-backup-info.txt << EOF
Date: $(date)
Persistent: $(grep -cE "^[0-9]" /etc/nftban/blacklist-persistent.conf)
User: $(grep -cE "^[0-9]" /etc/nftban/blacklist-user.conf)
Ban Log Size: $(wc -l < /var/log/nftban/ban.log) lines
EOF
```

**Restore Blacklist:**
```bash
# Restore from backup
tar -xzf nftban-blacklist-backup-20251022.tar.gz -C /

# Sync to nftables
nftban blacklist sync
```

### Log Rotation

**Logrotate Configuration (`/etc/logrotate.d/nftban`):**
```
/var/log/nftban/ban.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload nftban 2>/dev/null || true
    endscript
}
```

### Cleanup Tasks

**Clean Rate Limit Tracker:**
```bash
# Manual cleanup (removes all entries)
> /var/nftban/rate-limit-tracker.tmp

# Automatic cleanup (happens during ban attempt recording)
# Keeps only last 2 minutes of data
```

**Clean Expired Bans:**
```bash
# nftables handles this automatically with timeouts
# No manual cleanup needed for temp_ban set

# Verify cleanup
nft list set ip nftban_v4 temp_ban
# Should only show active bans (not expired)
```

---

## Related Documentation

- [NFTBAN_CORE_MODULE.md](NFTBAN_CORE_MODULE.md) - Core validation and logging
- [NFTBAN_WHITELIST_MODULE.md](NFTBAN_WHITELIST_MODULE.md) - Whitelist management
- [NFTBAN_NFTABLES_MODULE.md](NFTBAN_NFTABLES_MODULE.md) - nftables integration
- [NFTBAN_FEEDS_MODULE.md](NFTBAN_FEEDS_MODULE.md) - Threat intelligence feeds
- [SECURITY_HARDENING_v0.9.3.md](../Security/SECURITY_HARDENING_v0.9.3.md) - Security improvements

---

## Changelog

### v0.9.3-dev (2025-10-22)
- ✅ Added atomic file operations with flock
- ✅ Enhanced safety checks (7-layer system)
- ✅ Fixed BUG61: Arithmetic expansion in strict mode
- ✅ Improved lockout prevention (auto-whitelist)

### v0.9.2 (2024-12-15)
- ✅ Production-hardened header (set -Eeuo pipefail)
- ✅ Enhanced logging for safety events
- ✅ Added whitelist protection logging

### v0.9.0 (2024-11-01)
- ✅ Split table architecture (IPv4/IPv6 separation)
- ✅ Updated nft commands for split tables
- ✅ Performance improvements (30-50% faster)

### v0.8.5 (2024-09-15)
- ✅ Persistent offender system introduced
- ✅ Rate limiting added
- ✅ Comprehensive unban function

---

## License

**NFTBAN Custom License v3.0**
SPDX-License-Identifier: NFTBAN-Custom-License

© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

---

**Made by ITCMS** | https://itcms.gr
Empowering system administrators with simple, powerful security tools.
