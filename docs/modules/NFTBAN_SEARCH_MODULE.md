# NFTBan Search Module Documentation

**Module:** `nftban_search_module.sh`
**Version:** 0.9.3-dev (v2.1.0 Security Hardened)
**Location:** `/usr/local/lib/nftban/nftban_search_module.sh`
**Purpose:** Universal IP search with TOCTOU protection, command injection prevention, and comprehensive security hardening

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

The Search Module provides universal IP search capabilities across all NFTBan data sources (whitelists, blacklists, temp bans, threat feeds, nftables sets) with production-grade security hardening including TOCTOU race condition protection, command injection prevention, regex injection prevention, and IPv4-mapped IPv6 normalization.

### Key Features

- **Universal Search**: Single function searches all lists and nftables sets
- **TOCTOU Protection**: Atomic whitelist checks with flock prevent race conditions
- **Command Injection Prevention**: Strict input sanitization blocks shell metacharacters
- **Regex Injection Prevention**: Automatic escaping of grep patterns
- **IPv4-Mapped IPv6 Normalization**: Converts `::ffff:192.168.1.1` → `192.168.1.1`
- **CIDR Range Matching**: File-based CIDR membership checking with ipcalc
- **Priority-Based Search**: Whitelist → Temp Ban → Perm Blacklist → Feeds
- **O(1) nftables Lookup**: Uses `nft get element` instead of list + grep
- **Atomic File Operations**: flock-based shared locks prevent file races
- **Fail2Ban Integration**: Critical `nftban_check_whitelist()` for Fail2Ban

### Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging functions

**System Requirements:**
- `nftables` >= 0.9.0
- `flock` (util-linux package)
- `ipcalc` or `sipcalc` (recommended for strict IP validation)
- `grep` with `-E` support

**Optional:**
- `ipcalc` - Strict IP validation and CIDR membership (strongly recommended)
- `sipcalc` - Alternative to ipcalc

### Version History

| Version | Changes |
|---------|---------|
| v2.1.0 (0.9.3-dev) | TOCTOU protection, command injection prevention, IPv4-mapped IPv6 normalization |
| v2.0.0 (0.9.2) | Clean NEW logic, split table support, BUG51 fix (strict mode) |
| v1.x (0.8.x) | Initial search implementation |

---

## Module Architecture

### Search Priority System

```
IP SEARCH REQUEST
    ↓
┌────────────────────────────────────────┐
│  PRIORITY 1: WHITELIST (Highest)      │
│  • Files: whitelist_ips.conf          │
│  • nftables: @whitelist               │
│  • Status: WHITELISTED (cannot ban)   │
└────────────────────────────────────────┘
    ↓ (if not found)
┌────────────────────────────────────────┐
│  PRIORITY 2: TEMPORARY BANS            │
│  • nftables: @temp_ban (timeouts)     │
│  • Status: TEMP_BANNED                │
└────────────────────────────────────────┘
    ↓ (if not found)
┌────────────────────────────────────────┐
│  PRIORITY 3: PERMANENT BLACKLIST       │
│  • Files: blacklist_ips.conf          │
│  • nftables: @perm_ban                │
│  • Status: PERM_BANNED                │
└────────────────────────────────────────┘
    ↓ (if not found)
┌────────────────────────────────────────┐
│  PRIORITY 4: THREAT FEEDS              │
│  • Files: feeds/*-blacklist.conf      │
│  • nftables: @feeds                   │
│  • Status: IN_FEEDS                   │
└────────────────────────────────────────┘
    ↓ (if not found)
┌────────────────────────────────────────┐
│  PRIORITY 5: CLEAN                     │
│  • Status: CLEAN (not in any list)    │
└────────────────────────────────────────┘
```

### Security Hardening Layers

```
┌──────────────────────────────────────────────────────┐
│           INPUT VALIDATION & SANITIZATION            │
├──────────────────────────────────────────────────────┤
│ 1. Input Sanitization                                │
│    • Block shell metacharacters: $ ` ; | & < > etc   │
│    • Max length check (100 chars - DoS prevention)   │
│                                                       │
│ 2. IPv4-Mapped IPv6 Normalization                    │
│    • ::ffff:192.168.1.1 → 192.168.1.1                │
│    • ::192.168.1.1 → 192.168.1.1                     │
│                                                       │
│ 3. Strict IP Validation (ipcalc)                     │
│    • Format validation                                │
│    • Prevents malformed IPs                           │
│    • CIDR range validation                            │
└──────────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│              FILE OPERATION SECURITY                 │
├──────────────────────────────────────────────────────┤
│ 1. Atomic Read Locks (flock -s)                      │
│    • Shared locks allow concurrent reads             │
│    • Prevents TOCTOU race conditions                 │
│    • Timeout protection (5 seconds)                  │
│                                                       │
│ 2. Regex Injection Prevention                        │
│    • Automatic escaping: . [ ] * ^ $ ( ) etc         │
│    • Safe grep patterns                               │
│                                                       │
│ 3. CIDR Range Matching                               │
│    • Uses ipcalc for membership check                │
│    • Safe network calculations                        │
└──────────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────────┐
│            NFTABLES OPERATION SECURITY               │
├──────────────────────────────────────────────────────┤
│ 1. O(1) Direct Lookup (nft get element)             │
│    • Avoids grep injection                            │
│    • Faster performance                               │
│    • Safer operation                                  │
│                                                       │
│ 2. Fallback: Escaped Grep                            │
│    • For older nftables versions                     │
│    • Automatic regex escaping                         │
└──────────────────────────────────────────────────────┘
```

### TOCTOU Protection (Critical for Fail2Ban)

```
TOCTOU (Time-Of-Check-Time-Of-Use) Race Condition:

WITHOUT PROTECTION (Vulnerable):
─────────────────────────────────────────
Thread 1 (Fail2Ban):                Thread 2 (Admin):
  1. Check whitelist (IP not found)
                                      2. Add IP to whitelist
  3. Ban IP (WRONG!)
  ↓
  Result: Whitelisted IP gets banned!

WITH FLOCK PROTECTION (Secure):
─────────────────────────────────────────
Thread 1 (Fail2Ban):                Thread 2 (Admin):
  1. Acquire exclusive lock
  2. Check whitelist (IP not found)
                                      (BLOCKED - waiting for lock)
  3. Release lock
                                      4. Acquire exclusive lock
                                      5. Add IP to whitelist
                                      6. Release lock
  ↓
  Result: Safe operation, no race!

Implementation (nftban_check_whitelist):

(
    flock -x -w 5 200 || return 0  # FAIL-SAFE: Can't lock? Assume whitelisted

    # Check files under lock
    if grep -q "$ip" whitelist_ips.conf; then
        return 0  # Whitelisted
    fi

    # Check nftables under lock
    if nft get element ... whitelist { $ip }; then
        return 0  # Whitelisted
    fi

    return 1  # Not whitelisted
) 200>"/var/lock/nftban/whitelist-check.lock"
```

---

## API Reference

### Core Search Functions

#### `nftban_search_ip(ip, [quiet])`

Universal IP search across all NFTBan data sources with formatted output.

**Parameters:**
- `ip` (required) - IP address or CIDR to search
- `quiet` (optional) - Set to "true" for non-interactive mode (default: "false")

**Usage:**
```bash
# Interactive mode (formatted output)
nftban_search_ip "192.168.1.100"

# Quiet mode (status code only)
nftban_search_ip "192.168.1.100" true
status=$?
```

**Search Locations (Priority Order):**

1. **Whitelist** (files + nftables)
   - `/etc/nftban/config/whitelist_ips.conf`
   - `/etc/nftban/config/whitelist_ips.conf.local`
   - nftables: `@whitelist` set

2. **Temporary Bans** (nftables only)
   - nftables: `@temp_ban` set

3. **Permanent Blacklist** (files + nftables)
   - `/etc/nftban/config/blacklist_ips.conf`
   - `/etc/nftban/config/blacklist_ips.conf.local`
   - nftables: `@perm_ban` set

4. **Threat Feeds** (files + nftables)
   - `/etc/nftban/config/feeds/*-blacklist.conf`
   - nftables: `@feeds` set

**Exit Codes (Status Codes):**
- `10` - WHITELISTED (highest priority, cannot be banned)
- `20` - TEMP_BANNED (temporary ban active)
- `30` - PERM_BANNED (permanent blacklist)
- `40` - IN_FEEDS (threat intelligence feeds)
- `0` - CLEAN (not found in any list)

**Example Output (Interactive Mode):**
```bash
nftban_search_ip "192.168.1.100"

# Output:
═══════════════════════════════════════════════════════════════
  IP Search Result: 192.168.1.100
═══════════════════════════════════════════════════════════════

Status: ✅ WHITELISTED (Protected - Cannot be banned)

Found in:
  • File: /etc/nftban/config/whitelist_ips.conf
  • nftables: @whitelist (nftban_v4/nftban_v6)

IP Family: IPv4

# Exit code: 10
```

**Example Output (Different Statuses):**
```bash
# Temporary Ban
Status: ⏰ TEMPORARILY BANNED

Found in:
  • nftables: @temp_ban (nftban_v4/nftban_v6)

# Permanent Blacklist
Status: 🚫 PERMANENTLY BLACKLISTED

Found in:
  • File: /etc/nftban/config/blacklist_ips.conf
  • nftables: @perm_ban (nftban_v4/nftban_v6)

# Threat Feeds
Status: 📡 IN THREAT FEEDS

Found in:
  • Feed: spamhaus
  • Feed: blocklist-de
  • nftables: @feeds (nftban_v4/nftban_v6)

# Clean
Status: ✓ CLEAN (Not found in any list)

This IP is not whitelisted, banned, or blacklisted.
```

**Quiet Mode Usage:**
```bash
# Check status programmatically
if nftban_search_ip "192.168.1.100" true; then
    status=$?
    case $status in
        10) echo "Whitelisted" ;;
        20) echo "Temp banned" ;;
        30) echo "Perm banned" ;;
        40) echo "In feeds" ;;
        0) echo "Clean" ;;
    esac
fi
```

**Security Features:**
- **Input Sanitization**: Blocks shell metacharacters
- **IPv4-Mapped IPv6 Normalization**: Automatic conversion
- **Strict IP Validation**: ipcalc validation (if available)
- **Regex Injection Prevention**: Automatic escaping
- **CIDR Range Matching**: File-based CIDR membership
- **O(1) nftables Lookup**: Uses `nft get element`

**Source:** `nftban_search_module.sh:397-593`

---

#### `nftban_get_ip_status(ip)`

Returns simple status string for IP (quiet mode wrapper).

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
status=$(nftban_get_ip_status "192.168.1.100")
echo "$status"
```

**Output:**
```
WHITELISTED
TEMP_BANNED
PERM_BANNED
IN_FEEDS
CLEAN
UNKNOWN
```

**Example:**
```bash
status=$(nftban_get_ip_status "192.168.1.100")

case "$status" in
    WHITELISTED)
        echo "IP is protected - cannot ban"
        ;;
    TEMP_BANNED)
        echo "IP is temporarily banned"
        ;;
    PERM_BANNED)
        echo "IP is permanently blacklisted"
        ;;
    IN_FEEDS)
        echo "IP is in threat feeds"
        ;;
    CLEAN)
        echo "IP is clean"
        ;;
esac
```

**Source:** `nftban_search_module.sh:601-617`

---

### Whitelist/Blacklist Check Functions

#### `nftban_check_whitelist(ip)`

**CRITICAL**: Atomic whitelist check with TOCTOU protection for Fail2Ban integration.

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
if nftban_check_whitelist "192.168.1.100"; then
    echo "IP is whitelisted - do not ban"
else
    echo "IP not whitelisted - safe to ban"
fi
```

**Security Features:**

1. **TOCTOU Protection** (Race Condition Prevention)
   - Exclusive lock (flock -x) prevents concurrent modifications
   - Atomic check-and-use operation
   - Timeout protection (5 seconds)

2. **Fail-Safe Behavior**
   - If lock cannot be acquired: **ASSUMES WHITELISTED** (prevents accidental bans)
   - Better to skip a ban than ban a whitelisted IP

3. **Input Validation**
   - Sanitization (blocks shell metacharacters)
   - IPv4-mapped IPv6 normalization
   - Strict IP validation with ipcalc

**Implementation:**
```bash
nftban_check_whitelist() {
    local ip="$1"

    # Validate IP
    local validated_ip=$(_nftban_search_validate_ip_strict "$ip")

    local lockfile="/var/lock/nftban/whitelist-check.lock"

    (
        # CRITICAL: Exclusive lock prevents TOCTOU
        flock -x -w 5 200 || return 0  # FAIL-SAFE

        # Check files
        if grep -q "$ip" whitelist_ips.conf; then
            return 0
        fi

        # Check nftables
        if nft get element ... whitelist { $ip }; then
            return 0
        fi

        return 1
    ) 200>"$lockfile"
}
```

**Exit Codes:**
- `0` - IP is whitelisted (or lock failed - fail-safe)
- `1` - IP is not whitelisted

**Why This Matters (Fail2Ban Integration):**
```bash
# In Fail2Ban action script:
if ! nftban_check_whitelist "$IP"; then
    nftban ban "$IP"  # Safe - IP not whitelisted
else
    # BLOCKED - IP is whitelisted, skip ban
fi
```

**Without TOCTOU Protection (Vulnerable):**
```
Time  | Fail2Ban Thread              | Admin Thread
─────────────────────────────────────────────────────────
T1    | Check whitelist (not found)  |
T2    |                              | Add IP to whitelist
T3    | Ban IP (WRONG!)              |
```

**With TOCTOU Protection (Secure):**
```
Time  | Fail2Ban Thread              | Admin Thread
─────────────────────────────────────────────────────────
T1    | Acquire lock                 |
T2    | Check whitelist (not found)  | (BLOCKED - waiting)
T3    | Release lock                 |
T4    |                              | Acquire lock
T5    |                              | Add IP to whitelist
T6    |                              | Release lock
```

**Source:** `nftban_search_module.sh:309-357`

---

#### `nftban_check_blacklist(ip)`

Fast blacklist check (permanent blacklist only, no temp bans).

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
if nftban_check_blacklist "192.168.1.100"; then
    echo "IP is permanently blacklisted"
fi
```

**Checks:**
- `/etc/nftban/config/blacklist_ips.conf`
- `/etc/nftban/config/blacklist_ips.conf.local`
- nftables: `@perm_ban` set

**Exit Codes:**
- `0` - IP is in permanent blacklist
- `1` - IP is not in permanent blacklist

**Note:** Does NOT check temp_ban or feeds. Use `nftban_search_ip()` for comprehensive search.

**Source:** `nftban_search_module.sh:365-389`

---

### Interactive Functions

#### `nftban_interactive_manage_ip(ip)`

Interactive IP management with context-aware actions.

**Parameters:**
- `ip` (required) - IP address to manage

**Usage:**
```bash
nftban_interactive_manage_ip "192.168.1.100"
```

**Behavior:**
1. Runs full IP search (`nftban_search_ip`)
2. Displays current status
3. Shows context-aware action menu
4. Prompts for user choice

**Example Output:**
```
═══════════════════════════════════════════════════════════════
  IP Search Result: 192.168.1.100
═══════════════════════════════════════════════════════════════

Status: ✅ WHITELISTED (Protected - Cannot be banned)

Found in:
  • File: /etc/nftban/config/whitelist_ips.conf

IP Family: IPv4

═══════════════════════════════════════════════════════════════
  Available Actions
═══════════════════════════════════════════════════════════════

  [1] Remove from whitelist
  [2] Add to permanent blacklist (removes from whitelist)
  [q] Exit

Select action: _
```

**Context-Aware Actions:**

**WHITELISTED:**
- [1] Remove from whitelist
- [2] Add to permanent blacklist (removes from whitelist)
- [q] Exit

**TEMP_BANNED:**
- [1] Remove temporary ban (unban now)
- [2] Convert to permanent blacklist
- [3] Add to whitelist (also unbans)
- [q] Exit

**PERM_BANNED:**
- [1] Remove from permanent blacklist
- [2] Add to whitelist (also removes from blacklist)
- [q] Exit

**IN_FEEDS:**
- [1] Add to whitelist (excludes from feeds)
- [2] Add to permanent blacklist
- [3] Ban temporarily (1 hour)
- [q] Exit

**CLEAN:**
- [1] Add to whitelist
- [2] Add to permanent blacklist
- [3] Ban temporarily (1 hour)
- [q] Exit

**Note:** Action execution requires integration with whitelist/blacklist modules (currently displays placeholder).

**Source:** `nftban_search_module.sh:625-695`

---

#### `nftban_search_ip_everywhere(ip)`

User-friendly wrapper for IP search (simple alias).

**Parameters:**
- `ip` (required) - IP address to search

**Usage:**
```bash
nftban_search_ip_everywhere "192.168.1.100"
```

**Behavior:**
Simply calls `nftban_search_ip()` with user-friendly error messages.

**Example:**
```bash
# Missing IP
nftban_search_ip_everywhere

# Output:
ERROR: No IP address provided

Usage: nftban search ip <IP_ADDRESS>

Examples:
  nftban search ip 192.168.1.100
  nftban search ip 103.21.244.0
  nftban search ip 2001:db8::1
```

**Source:** `nftban_search_module.sh:704-723`

---

### Internal Security Functions

#### `_nftban_search_sanitize_input(input)`

⚠️ **Internal function** - Do not call directly.

Strict input sanitization to prevent command injection.

**Security Checks:**
1. **Shell Metacharacter Detection**
   - Blocks: `$ \` ; | & < > ( ) { } [ ] \ ' "`
   - Allows: digits, dots, colons, slashes (IP/CIDR only)

2. **DoS Prevention**
   - Max length: 100 characters
   - Prevents resource exhaustion

**Example:**
```bash
# Valid inputs
_nftban_search_sanitize_input "192.168.1.100"  # OK
_nftban_search_sanitize_input "2001:db8::1"    # OK
_nftban_search_sanitize_input "10.0.0.0/8"     # OK

# Blocked inputs
_nftban_search_sanitize_input "192.168.1.100; rm -rf /"  # ERROR: Dangerous characters
_nftban_search_sanitize_input "192.168.1.\$(whoami)"     # ERROR: Dangerous characters
_nftban_search_sanitize_input "192.168.1.100|nc"         # ERROR: Dangerous characters
```

**Source:** `nftban_search_module.sh:63-81`

---

#### `_nftban_search_normalize_ip(ip)`

⚠️ **Internal function** - Do not call directly.

Normalizes IPv4-mapped IPv6 addresses to IPv4.

**Conversions:**
```bash
::ffff:192.168.1.1  →  192.168.1.1
::192.168.1.1       →  192.168.1.1
2001:db8::1         →  2001:db8::1 (no change)
192.168.1.1         →  192.168.1.1 (no change)
```

**Why This Matters:**
- Some systems represent IPv4 as IPv4-mapped IPv6
- Ensures consistent lookups across both representations
- Prevents whitelist/blacklist bypass

**Source:** `nftban_search_module.sh:85-97`

---

#### `_nftban_search_validate_ip_strict(ip)`

⚠️ **Internal function** - Do not call directly.

Strict IP validation with ipcalc (3-stage validation).

**Validation Stages:**

1. **Sanitization**
   - Block shell metacharacters
   - Max length check

2. **Normalization**
   - IPv4-mapped IPv6 conversion

3. **Validation**
   - ipcalc (preferred) - most accurate
   - sipcalc (fallback) - alternative
   - Regex (last resort) - basic only

**Output:**
Returns normalized IP on success, error on failure.

**Example:**
```bash
# Valid IPs
validated=$(_nftban_search_validate_ip_strict "192.168.1.100")
# Output: 192.168.1.100

validated=$(_nftban_search_validate_ip_strict "::ffff:192.168.1.1")
# Output: 192.168.1.1 (normalized!)

# Invalid IPs
validated=$(_nftban_search_validate_ip_strict "999.999.999.999")
# ERROR: IP validation failed (ipcalc): 999.999.999.999
```

**Source:** `nftban_search_module.sh:120-152`

---

#### `_nftban_search_escape_regex(input)`

⚠️ **Internal function** - Do not call directly.

Escapes regex metacharacters to prevent regex injection.

**Escaped Characters:**
```
. [ ] * ^ $ ( ) { } + ? | \
```

**Example:**
```bash
# Without escaping (VULNERABLE):
grep "192.168.1.100" file  # Matches: 192X168X1X100 (. matches any char)

# With escaping (SAFE):
escaped=$(_nftban_search_escape_regex "192.168.1.100")
# Output: 192\.168\.1\.100
grep "$escaped" file  # Matches: 192.168.1.100 only
```

**Security Impact:**
```bash
# Regex injection attack (WITHOUT escaping):
ip=".*"  # Attacker input
grep "$ip" whitelist  # Matches EVERYTHING!

# With escaping (SAFE):
escaped=$(_nftban_search_escape_regex ".*")
# Output: \.\*
grep "$escaped" whitelist  # Matches literal ".*" only
```

**Source:** `nftban_search_module.sh:193-197`

---

#### `_nftban_search_in_file(ip, file)`

⚠️ **Internal function** - Do not call directly.

Search file with flock (prevent race conditions) and escaped regex.

**Security Features:**
- **Shared Lock** (flock -s): Allows concurrent reads, blocks concurrent writes
- **Regex Escaping**: Prevents regex injection
- **CIDR Matching**: File-based CIDR membership with ipcalc

**Implementation:**
```bash
_nftban_search_in_file() {
    local ip="$1"
    local file="$2"

    local escaped_ip=$(_nftban_search_escape_regex "$ip")

    (
        flock -s -w 5 200 || return 1

        # Exact IP match
        if grep -qE "^[[:space:]]*${escaped_ip}([[:space:]]|#|$)" "$file"; then
            return 0
        fi

        # CIDR range match
        while IFS= read -r line; do
            local entry=$(echo "$line" | awk '{print $1}')
            if [[ "$entry" =~ / ]]; then
                if _nftban_search_ip_in_cidr "$ip" "$entry"; then
                    return 0
                fi
            fi
        done < "$file"

        return 1
    ) 200<"$file"
}
```

**Source:** `nftban_search_module.sh:200-243`

---

#### `_nftban_search_in_nftables_set(ip, set_name, family)`

⚠️ **Internal function** - Do not call directly.

Search nftables set using O(1) direct lookup.

**Parameters:**
- `ip` - IP address
- `set_name` - Set name (whitelist, temp_ban, perm_ban, feeds)
- `family` - IP family ("v4" or "v6")

**Method:**
1. **Primary**: `nft get element` (O(1) direct lookup)
2. **Fallback**: `nft list set | grep` (for older nftables)

**Example:**
```bash
# O(1) direct lookup (preferred)
nft get element ip nftban_v4 whitelist { 192.168.1.100 }
# Exit: 0 (found) or 1 (not found)

# Fallback: list + grep (older nftables)
nft list set ip nftban_v4 whitelist | grep -E "192\.168\.1\.100"
```

**Performance:**
- Direct lookup: O(1) - constant time
- List + grep: O(n) - linear scan

**Source:** `nftban_search_module.sh:271-300`

---

## Integration Guide

### Integration with Fail2Ban

**Critical Whitelist Check in Fail2Ban Action:**

`/etc/fail2ban/action.d/nftban.conf`:
```bash
[Definition]
actionstart =
actionstop =
actioncheck =

# CRITICAL: Check whitelist BEFORE banning
actionban = if ! nftban_check_whitelist <ip>; then \
                /usr/local/bin/nftban ban <ip> --jail <name>; \
            fi

actionunban = /usr/local/bin/nftban unban <ip>
```

**Why This Integration is Critical:**
- Prevents banning whitelisted IPs (admin, monitoring systems, etc.)
- TOCTOU protection ensures atomic check
- Fail-safe behavior (can't lock? assume whitelisted)

**Example Jail (`/etc/fail2ban/jail.d/sshd.local`):**
```ini
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
action = nftban
```

---

### Integration with CLI

**Command Examples:**
```bash
# Search IP
nftban search ip 192.168.1.100

# Get IP status
nftban status 192.168.1.100

# Interactive management
nftban manage 192.168.1.100
```

**CLI Implementation:**
```bash
case "$1" in
    search)
        case "$2" in
            ip)
                nftban_search_ip "$3"
                ;;
        esac
        ;;

    status)
        status=$(nftban_get_ip_status "$2")
        echo "Status: $status"
        ;;

    manage)
        nftban_interactive_manage_ip "$2"
        ;;
esac
```

---

### Integration with Other Modules

**Blacklist Module Integration:**
```bash
# Before banning, check whitelist
nftban_blacklist_ban_ip() {
    local ip="$1"

    # CRITICAL: Use search module's atomic whitelist check
    if nftban_check_whitelist "$ip"; then
        nftban_log_error "Cannot ban whitelisted IP: $ip"
        return 1
    fi

    # Proceed with ban...
}
```

**Monitoring Dashboard Integration:**
```bash
# Get IP status for dashboard
get_ip_status_for_dashboard() {
    local ip="$1"

    # Quiet mode returns status code
    nftban_search_ip "$ip" true
    local status=$?

    case $status in
        10) echo "whitelisted" ;;
        20) echo "temp_banned" ;;
        30) echo "perm_banned" ;;
        40) echo "in_feeds" ;;
        0) echo "clean" ;;
    esac
}
```

**Automated Threat Response:**
```bash
# Check IP against threat feeds
check_threat_feeds() {
    local ip="$1"

    nftban_search_ip "$ip" true
    local status=$?

    if [[ $status -eq 40 ]]; then
        # IP is in threat feeds
        nftban_blacklist_add_permanent "$ip" "Threat intelligence match"
    fi
}
```

---

## Configuration

### File Locations

```bash
# Configuration directory
NFTBAN_SEARCH_CONFIG_DIR="/etc/nftban/config"

# Feeds directory
NFTBAN_SEARCH_FEEDS_DIR="/etc/nftban/config/feeds"

# Lock directory
NFTBAN_LOCK_DIR="/var/lock/nftban"

# Lock timeout
NFTBAN_LOCK_TIMEOUT=5  # seconds
```

### Status Codes

```bash
# Search result status codes
NFTBAN_SEARCH_STATUS_WHITELISTED=10  # Highest priority
NFTBAN_SEARCH_STATUS_TEMP_BANNED=20
NFTBAN_SEARCH_STATUS_PERM_BANNED=30
NFTBAN_SEARCH_STATUS_IN_FEEDS=40
NFTBAN_SEARCH_STATUS_CLEAN=0        # Not found
```

### nftables Tables

```bash
# IPv4 table
NFTBAN_NFT_TABLE_V4="nftban_v4"
NFTBAN_NFT_FAMILY_V4="ip"

# IPv6 table
NFTBAN_NFT_TABLE_V6="nftban_v6"
NFTBAN_NFT_FAMILY_V6="ip6"
```

### File Formats

**Whitelist File (`whitelist_ips.conf`):**
```bash
# NFTBan Whitelist
192.168.1.100  # Office server
10.0.0.0/8     # Private network
2001:db8::1    # IPv6 gateway
```

**Blacklist File (`blacklist_ips.conf`):**
```bash
# NFTBan Permanent Blacklist
192.0.2.100     # Known attacker
198.51.100.0/24 # Malicious network
```

**Feed File (`feeds/spamhaus-blacklist.conf`):**
```bash
# Spamhaus DROP List
192.0.2.0/24
198.51.100.0/24
...
```

---

## Security Considerations

### Security Model

**Threat Model:**
1. **Command Injection** - Attacker provides malicious IP like `192.168.1.1; rm -rf /`
2. **Regex Injection** - Attacker provides regex like `.*` to match everything
3. **TOCTOU Race Condition** - Concurrent whitelist check and modification
4. **IPv4-Mapped IPv6 Bypass** - Using `::ffff:192.168.1.1` to bypass checks
5. **DoS via Long Input** - Providing extremely long IP strings

**Security Principles:**
- **Defense in Depth**: Multiple validation layers (sanitize → normalize → validate)
- **Fail-Safe Defaults**: Lock timeout? Assume whitelisted (safer)
- **Least Privilege**: Read-only shared locks for searches
- **Atomic Operations**: flock ensures consistency

### Vulnerability Mitigations

#### Command Injection Prevention

**Attack:**
```bash
# Malicious IP input
ip='192.168.1.1; rm -rf /'

# Without sanitization (VULNERABLE):
grep "$ip" whitelist  # Executes: rm -rf /
```

**Mitigation:**
```bash
_nftban_search_sanitize_input() {
    local input="$1"

    # Block dangerous characters
    if [[ "$input" =~ [\$\`\;\|\&\<\>\(\)\{\}\\\'\"] ]]; then
        echo "ERROR: Dangerous characters detected" >&2
        return 1
    fi

    return 0
}

# Usage:
_nftban_search_sanitize_input "$ip" || return 1
```

---

#### Regex Injection Prevention

**Attack:**
```bash
# Malicious IP (regex wildcard)
ip='.*'

# Without escaping (VULNERABLE):
grep "$ip" whitelist  # Matches EVERYTHING!
```

**Mitigation:**
```bash
_nftban_search_escape_regex() {
    local input="$1"
    # Escape: . [ ] * ^ $ ( ) { } + ? | \
    printf '%s\n' "$input" | sed 's/[][.*^$()+?{|\\]/\\&/g'
}

# Usage:
escaped=$(_nftban_search_escape_regex "$ip")
grep "$escaped" whitelist  # Matches literal ".*" only
```

---

#### TOCTOU Race Condition Prevention

**Attack:**
```
Thread 1 (Fail2Ban):          Thread 2 (Admin):
  Check whitelist (not found)
                                Add IP to whitelist
  Ban IP (WRONG!)
```

**Mitigation:**
```bash
nftban_check_whitelist() {
    local lockfile="/var/lock/nftban/whitelist-check.lock"

    (
        # CRITICAL: Exclusive lock
        flock -x -w 5 200 || return 0  # FAIL-SAFE

        # Atomic check under lock
        if grep -q "$ip" whitelist; then
            return 0
        fi

        return 1
    ) 200>"$lockfile"
}
```

---

#### IPv4-Mapped IPv6 Bypass Prevention

**Attack:**
```bash
# Whitelist contains: 192.168.1.100
# Attacker uses: ::ffff:192.168.1.100

# Without normalization (VULNERABLE):
grep "::ffff:192.168.1.100" whitelist  # Not found! (bypass)
```

**Mitigation:**
```bash
_nftban_search_normalize_ip() {
    local ip="$1"

    # Convert ::ffff:x.x.x.x → x.x.x.x
    if [[ "$ip" =~ ^::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$ip"
    fi
}

# Usage:
ip=$(_nftban_search_normalize_ip "$ip")
# Now: ::ffff:192.168.1.100 → 192.168.1.100 (matches whitelist!)
```

---

### Attack Surface Analysis

**File System Operations:**
- **Risk**: Concurrent file modifications during search
- **Mitigation**: Shared locks (flock -s) allow concurrent reads, block writes

**nftables Operations:**
- **Risk**: Grep injection in nftables output
- **Mitigation**: Use `nft get element` (O(1), injection-proof)

**Input Validation:**
- **Risk**: Malformed IPs crash validation
- **Mitigation**: ipcalc validation (strict), fallback to regex

**Lock Timeout:**
- **Risk**: Deadlock if lock held indefinitely
- **Mitigation**: 5-second timeout with fail-safe (assume whitelisted)

### Compliance

**CWE Mitigations:**
- **CWE-78**: OS Command Injection (input sanitization)
- **CWE-94**: Improper Control of Generation of Code (regex escaping)
- **CWE-362**: Concurrent Execution using Shared Resource (flock)
- **CWE-400**: Uncontrolled Resource Consumption (max length check)

**Security Standards:**
- **OWASP A03:2021**: Injection (command + regex injection prevention)
- **NIST 800-53**: SI-10 (Information Input Validation)

---

## Troubleshooting

### Common Issues

#### Issue 1: Lock Timeout During Whitelist Check

**Symptoms:**
```
ERROR: Could not acquire whitelist lock (timeout)
```

**Causes:**
1. Another process holding lock for > 5 seconds
2. Stale lock file (crashed process)

**Behavior:**
- **Fail-safe**: Assumes IP is whitelisted (safer than banning)

**Solutions:**
```bash
# Check for stale locks
ls -l /var/lock/nftban/whitelist-check.lock

# Remove stale lock (if no processes running)
rm -f /var/lock/nftban/whitelist-check.lock

# Increase timeout (if needed)
# Edit nftban_search_module.sh:
readonly NFTBAN_LOCK_TIMEOUT=10
```

---

#### Issue 2: ipcalc Not Found

**Symptoms:**
```
ERROR: IP validation failed (regex): 192.168.1.300
```

**Cause:**
ipcalc not installed, fallback regex allows invalid IP.

**Solutions:**
```bash
# Install ipcalc (recommended)
# Debian/Ubuntu:
apt-get install ipcalc

# RHEL/CentOS:
yum install ipcalc

# Alternative: sipcalc
apt-get install sipcalc

# Verify
ipcalc -c 192.168.1.100
echo $?  # Should be 0
```

---

#### Issue 3: IPv4-Mapped IPv6 Not Normalized

**Symptoms:**
```bash
# Whitelist has: 192.168.1.100
nftban_search_ip "::ffff:192.168.1.100"
# Status: CLEAN (should be WHITELISTED)
```

**Cause:**
Normalization not working (regex issue).

**Solutions:**
```bash
# Test normalization
_nftban_search_normalize_ip "::ffff:192.168.1.100"
# Should output: 192.168.1.100

# If not working, check bash version
bash --version  # Need 4.0+

# Manual workaround: Add both forms to whitelist
echo "192.168.1.100  # IPv4" >> whitelist_ips.conf
echo "::ffff:192.168.1.100  # IPv4-mapped IPv6" >> whitelist_ips.conf
```

---

#### Issue 4: CIDR Range Not Matching

**Symptoms:**
```bash
# File has: 10.0.0.0/8
nftban_search_ip "10.5.10.25"
# Status: CLEAN (should match CIDR)
```

**Causes:**
1. ipcalc not installed
2. CIDR membership check failing

**Solutions:**
```bash
# Test CIDR membership
_nftban_search_ip_in_cidr "10.5.10.25" "10.0.0.0/8"
echo $?  # Should be 0

# Install ipcalc
apt-get install ipcalc

# Test again
ipcalc -c "10.5.10.25" -n "10.0.0.0/8"
echo $?  # Should be 0
```

---

### Debugging

**Enable Debug Logging:**
```bash
export NFTBAN_LOG_LEVEL=debug
nftban_search_ip "192.168.1.100"
```

**Manual Validation Tests:**
```bash
# Test sanitization
_nftban_search_sanitize_input "192.168.1.100"
echo $?  # Should be 0

_nftban_search_sanitize_input "192.168.1.1; rm -rf /"
echo $?  # Should be 1

# Test normalization
_nftban_search_normalize_ip "::ffff:192.168.1.1"
# Output: 192.168.1.1

# Test validation
_nftban_search_validate_ip_strict "192.168.1.100"
# Output: 192.168.1.100

_nftban_search_validate_ip_strict "999.999.999.999"
# ERROR: IP validation failed
```

**Check File Locks:**
```bash
# List active locks
lslocks | grep nftban

# Check lock files
ls -l /var/lock/nftban/
```

**Test nftables Lookup:**
```bash
# Direct lookup (O(1))
nft get element ip nftban_v4 whitelist { 192.168.1.100 }
echo $?

# List set
nft list set ip nftban_v4 whitelist
```

---

## Testing

### Unit Tests

**Test 1: Input Sanitization**
```bash
test_input_sanitization() {
    # Valid inputs
    _nftban_search_sanitize_input "192.168.1.100" || {
        echo "FAIL: Valid IPv4 rejected"
        return 1
    }

    _nftban_search_sanitize_input "2001:db8::1" || {
        echo "FAIL: Valid IPv6 rejected"
        return 1
    }

    # Dangerous inputs
    if _nftban_search_sanitize_input "192.168.1.1; rm -rf /"; then
        echo "FAIL: Command injection not blocked"
        return 1
    fi

    if _nftban_search_sanitize_input "192.168.1.\$(whoami)"; then
        echo "FAIL: Command substitution not blocked"
        return 1
    fi

    echo "PASS: Input sanitization"
    return 0
}

test_input_sanitization
```

---

**Test 2: IPv4-Mapped IPv6 Normalization**
```bash
test_ipv4_mapped_normalization() {
    local result

    # Test ::ffff:x.x.x.x
    result=$(_nftban_search_normalize_ip "::ffff:192.168.1.1")
    if [[ "$result" != "192.168.1.1" ]]; then
        echo "FAIL: ::ffff: normalization failed (got: $result)"
        return 1
    fi

    # Test ::x.x.x.x
    result=$(_nftban_search_normalize_ip "::192.168.1.1")
    if [[ "$result" != "192.168.1.1" ]]; then
        echo "FAIL: :: normalization failed (got: $result)"
        return 1
    fi

    # Test regular IPv4 (no change)
    result=$(_nftban_search_normalize_ip "192.168.1.1")
    if [[ "$result" != "192.168.1.1" ]]; then
        echo "FAIL: IPv4 normalization changed (got: $result)"
        return 1
    fi

    # Test regular IPv6 (no change)
    result=$(_nftban_search_normalize_ip "2001:db8::1")
    if [[ "$result" != "2001:db8::1" ]]; then
        echo "FAIL: IPv6 normalization changed (got: $result)"
        return 1
    fi

    echo "PASS: IPv4-mapped IPv6 normalization"
    return 0
}

test_ipv4_mapped_normalization
```

---

**Test 3: Whitelist Check (TOCTOU Protection)**
```bash
test_whitelist_check_toctou() {
    local test_ip="192.168.99.99"

    # Add to whitelist
    echo "$test_ip  # Test" >> /etc/nftban/config/whitelist_ips.conf

    # Test atomic check
    if ! nftban_check_whitelist "$test_ip"; then
        echo "FAIL: Whitelisted IP not detected"
        return 1
    fi

    # Test concurrent access (spawn multiple checks)
    local failures=0
    for i in {1..10}; do
        (
            if ! nftban_check_whitelist "$test_ip"; then
                exit 1
            fi
        ) &
    done

    wait

    if [[ $failures -gt 0 ]]; then
        echo "FAIL: Concurrent whitelist checks failed"
        return 1
    fi

    # Cleanup
    sed -i "/$test_ip/d" /etc/nftban/config/whitelist_ips.conf

    echo "PASS: Whitelist check with TOCTOU protection"
    return 0
}

test_whitelist_check_toctou
```

---

**Test 4: Universal Search**
```bash
test_universal_search() {
    local test_ip="192.168.98.98"

    # Test CLEAN status
    nftban_search_ip "$test_ip" true
    local status=$?

    if [[ $status -ne 0 ]]; then
        echo "FAIL: Clean IP not detected (status=$status)"
        return 1
    fi

    # Add to whitelist
    echo "$test_ip  # Test" >> /etc/nftban/config/whitelist_ips.conf

    # Test WHITELISTED status
    nftban_search_ip "$test_ip" true
    status=$?

    if [[ $status -ne 10 ]]; then
        echo "FAIL: Whitelisted IP not detected (status=$status, expected 10)"
        return 1
    fi

    # Cleanup
    sed -i "/$test_ip/d" /etc/nftban/config/whitelist_ips.conf

    echo "PASS: Universal search"
    return 0
}

test_universal_search
```

---

## Performance

### Benchmarks

**Search Performance:**
```
Operation                        Time (avg)    Method
--------------------------------------------------------------
nftables lookup (get element)   < 1ms         O(1) direct lookup
nftables lookup (list + grep)   5-10ms        O(n) linear scan
File search (exact match)        2-5ms         flock + grep
File search (CIDR match)         10-20ms       flock + ipcalc loop
Full universal search            15-30ms       All sources combined
```

**TOCTOU-Protected Whitelist Check:**
```
Whitelist Size    Check Time    Notes
------------------------------------------
< 100 IPs         < 5ms         Fast
100-1000 IPs      5-15ms        Acceptable
1000-10000 IPs    15-50ms       Consider optimization
```

### Optimization Tips

**1. Use nft get element (Not list + grep)**
```bash
# FAST: O(1) direct lookup
nft get element ip nftban_v4 whitelist { 192.168.1.100 }

# SLOW: O(n) linear scan
nft list set ip nftban_v4 whitelist | grep 192.168.1.100
```

**2. Use Quiet Mode for Scripts**
```bash
# Interactive mode (formatted output - slower)
nftban_search_ip "192.168.1.100"

# Quiet mode (status code only - faster)
nftban_search_ip "192.168.1.100" true
```

**3. Cache Results for Repeated Lookups**
```bash
# Cache last search result
export NFTBAN_LAST_SEARCH_IP="192.168.1.100"
export NFTBAN_LAST_SEARCH_STATUS="10"

# Check cache first
if [[ "$ip" == "$NFTBAN_LAST_SEARCH_IP" ]]; then
    return "$NFTBAN_LAST_SEARCH_STATUS"
fi
```

---

## Maintenance

### Regular Maintenance

**Daily:**
```bash
# Check lock directory
ls -l /var/lock/nftban/

# Remove stale locks (if no processes)
find /var/lock/nftban/ -name "*.lock" -mtime +1 -delete
```

**Weekly:**
```bash
# Verify ipcalc availability
which ipcalc || apt-get install ipcalc

# Test search function
nftban_search_ip "127.0.0.1"
```

---

## Related Documentation

- [NFTBAN_WHITELIST_MODULE.md](NFTBAN_WHITELIST_MODULE.md) - Whitelist management
- [NFTBAN_BLACKLIST_MODULE.md](NFTBAN_BLACKLIST_MODULE.md) - Blacklist management
- [NFTBAN_FEEDS_MODULE.md](NFTBAN_FEEDS_MODULE.md) - Threat intelligence feeds
- [SECURITY_HARDENING_v0.9.3.md](../Security/SECURITY_HARDENING_v0.9.3.md) - Security improvements

---

## Changelog

### v2.1.0 (0.9.3-dev) - 2025-10-22
- ✅ Added TOCTOU protection with flock (CWE-362)
- ✅ Added command injection prevention (CWE-78)
- ✅ Added regex injection prevention (CWE-94)
- ✅ Added IPv4-mapped IPv6 normalization
- ✅ Added strict IP validation with ipcalc
- ✅ Added DoS prevention (max length check)

### v2.0.0 (0.9.2) - 2024-12-15
- ✅ Clean NEW logic implementation
- ✅ Split table architecture support
- ✅ BUG51 fix: Production-grade strict mode

### v1.x (0.8.x) - 2024-09-15
- ✅ Initial search implementation
- ✅ Basic file and nftables search

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
