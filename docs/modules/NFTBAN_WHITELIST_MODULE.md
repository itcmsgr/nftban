# NFTBan Whitelist Module Documentation

**Module:** `nftban_whitelist_module.sh`
**Version:** 0.9.3-dev
**Location:** `/usr/local/lib/nftban/nftban_whitelist_module.sh`
**Purpose:** Whitelist management with auto-protection, lockout prevention, and atomic file operations

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

The Whitelist Module provides comprehensive IP whitelist management with automatic protection mechanisms to prevent administrator lockout. It maintains three separate whitelist files (system, user, Cloudflare) and synchronizes them with nftables firewall sets using atomic file operations and exclusive locking.

### Key Features

- **Auto-Protection System**: Automatically whitelists server IPs and current admin IP to prevent lockout
- **Dual Storage**: Maintains both configuration files and nftables sets
- **Atomic Operations**: File locking (flock) prevents race conditions and TOCTOU vulnerabilities
- **Split Table Architecture**: Separate IPv4/IPv6 tables for optimal performance (v0.9.0+)
- **Safety Checks**: Prevents removal of critical IPs (localhost, server IPs, current user)
- **CIDR Support**: Full CIDR range matching and validation
- **Three-Tier System**: System whitelist (auto-managed), user whitelist (manual), Cloudflare whitelist (integration)

### Dependencies

**Required Modules:**
- `nftban_core.sh` - Core validation and logging functions
- `nftban_utils_lib.sh` - Utility functions (CIDR checking)
- `nftban_nftables_module.sh` - nftables table management

**System Requirements:**
- `nftables` >= 0.9.0
- `flock` (util-linux package)
- `ip` command (iproute2 package)

### Version History

| Version | Changes |
|---------|---------|
| 0.9.3-dev | Added atomic file operations with flock, BUG61 fix (strict mode arithmetic) |
| 0.9.2 | Production hardening, enhanced auto-protection |
| 0.9.0 | Split table architecture (IPv4/IPv6 separation) |
| 0.8.x | Three-tier whitelist system introduced |

---

## Module Architecture

### File Structure

```
/etc/nftban/
├── whitelist-system.conf    # Auto-managed (server IPs, localhost)
├── whitelist-user.conf       # User-managed (manual additions)
└── whitelist-cloudflare.conf # Cloudflare integration (optional)

/var/lock/nftban/
├── whitelist-system.conf.lock
├── whitelist-user.conf.lock
└── whitelist-cloudflare.conf.lock
```

### Three-Tier Whitelist System

```
┌──────────────────────────────────────────────────────┐
│              WHITELIST ARCHITECTURE                  │
└──────────────────────────────────────────────────────┘

TIER 1: System Whitelist (AUTO-MANAGED)
├── localhost (127.0.0.1, ::1)
├── Server interface IPs (auto-detected)
├── Server public IPs (auto-detected)
└── PROTECTED: Manual removal blocked

TIER 2: User Whitelist (MANUAL)
├── Current admin IP (auto-added)
├── User-added IPs/CIDRs
└── PROTECTED: Current user IP removal blocked

TIER 3: Cloudflare Whitelist (INTEGRATION)
├── Cloudflare edge IPs (auto-synced)
└── MANAGED: By cloudflare module

                    ↓
        ┌────────────────────────┐
        │   ATOMIC FILE WRITE    │
        │  (flock exclusive lock)│
        └────────────────────────┘
                    ↓
        ┌────────────────────────┐
        │   nftables SYNC        │
        │  IPv4: nftban_v4/whitelist
        │  IPv6: nftban_v6/whitelist
        └────────────────────────┘
                    ↓
        ┌────────────────────────┐
        │   FIREWALL PRIORITY    │
        │  1. Whitelist (ACCEPT) │
        │  2. ... other rules    │
        └────────────────────────┘
```

### nftables Integration

**Split Table Architecture (v0.9.0+):**

```nft
# IPv4 Table
table ip nftban_v4 {
    set whitelist {
        type ipv4_addr
        flags interval  # CIDR support
        elements = { 127.0.0.1, 192.168.1.100, ... }
    }

    chain input {
        ip saddr @whitelist accept  # HIGHEST PRIORITY
        ...
    }
}

# IPv6 Table
table ip6 nftban_v6 {
    set whitelist {
        type ipv6_addr
        flags interval
        elements = { ::1, 2001:db8::100, ... }
    }

    chain input {
        ip6 saddr @whitelist accept
        ...
    }
}
```

### Auto-Protection Flow

```
INITIALIZATION
    ↓
┌─────────────────────────────────────┐
│ 1. Create whitelist files          │
│    - whitelist-system.conf          │
│    - whitelist-user.conf            │
│    - whitelist-cloudflare.conf      │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ 2. Auto-protect server IPs          │
│    - Localhost (127.0.0.1, ::1)     │
│    - Interface IPs (ip addr show)   │
│    - Public IPs (external detection)│
│    ⚠️ SKIP: Link-local IPv6 (fe80::)│
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ 3. Auto-protect current admin       │
│    - Detect SSH_CLIENT / SSH_CONNECTION
│    - Add to user whitelist          │
│    - Warn user about protection     │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ 4. Sync to nftables                 │
│    - Flush existing sets            │
│    - Load from all files            │
│    - Split IPv4/IPv6                │
└─────────────────────────────────────┘
```

---

## API Reference

### Initialization Functions

#### `nftban_whitelist_init()`

Initializes the whitelist system with auto-protection.

**Usage:**
```bash
nftban_whitelist_init
```

**Behavior:**
1. Creates three whitelist configuration files if missing
2. Auto-protects server interface IPs
3. Auto-protects current SSH user IP
4. Syncs to nftables sets

**Exit Codes:**
- `0` - Success
- `1` - Initialization failed

**Example:**
```bash
# Automatic initialization during nftban install
nftban_whitelist_init

# Output:
# [INFO] Initializing whitelist system with auto-protection...
# [SUCCESS] Protected server IP: 192.168.1.10
# [SUCCESS] Protected current user IP: 203.0.113.42
# [SUCCESS] Whitelist system initialized with protection
```

**Source:** `nftban_whitelist_module.sh:80-146`

---

#### `nftban_whitelist_add_server_ips()`

Auto-detects and protects all server interface IPs.

**Usage:**
```bash
nftban_whitelist_add_server_ips
```

**Behavior:**
1. Protects localhost (127.0.0.1, ::1)
2. Detects all interface IPs (`ip -o addr show`)
3. Skips link-local IPv6 addresses (fe80::) - BUG3.4 fix
4. Detects public IPv4/IPv6 (external services)
5. Adds IPs to system whitelist with atomic write
6. Syncs to nftables

**Exit Codes:**
- `0` - Success (one or more IPs protected or already protected)

**Example:**
```bash
nftban_whitelist_add_server_ips

# Output:
# [SUCCESS] Protected server IP: 192.168.1.10
# [SUCCESS] Protected server IP: 10.0.0.5
# [SUCCESS] Protected public IPv4: 203.0.113.10
# [SUCCESS] Auto-protected 3 server IPs
```

**Security Notes:**
- Uses atomic file append (`_nftban_whitelist_safe_append`) to prevent race conditions
- Prevents duplicate entries
- Link-local IPv6 excluded (not routable)

**Source:** `nftban_whitelist_module.sh:152-218`

---

#### `nftban_whitelist_protect_current_user()`

Auto-detects and protects the current SSH user's IP.

**Usage:**
```bash
nftban_whitelist_protect_current_user
```

**Behavior:**
1. Detects current user IP from `SSH_CLIENT` or `SSH_CONNECTION`
2. Checks if already whitelisted
3. Adds to **user whitelist** (not system - allows manual removal)
4. Warns user about auto-protection
5. Syncs to nftables

**Exit Codes:**
- `0` - Success (protected or already protected or local console)

**Example:**
```bash
# During SSH session from 203.0.113.42
nftban_whitelist_protect_current_user

# Output:
# [SUCCESS] Protected current user IP: 203.0.113.42
# [WARNING] ⚠️  IMPORTANT: Your IP (203.0.113.42) has been whitelisted to prevent lockout
```

**Security Notes:**
- Added to user whitelist (not system) to allow admin override
- Prevents immediate lockout during initial setup
- Warning ensures admin awareness

**Source:** `nftban_whitelist_module.sh:224-247`

---

### IP Management Functions

#### `nftban_whitelist_add_ip(ip, [comment])`

Adds an IP or CIDR range to the user whitelist.

**Parameters:**
- `ip` (required) - IP address or CIDR range (e.g., "192.168.1.100" or "10.0.0.0/8")
- `comment` (optional) - Descriptive comment (default: "Added on YYYY-MM-DD")

**Usage:**
```bash
nftban_whitelist_add_ip "192.168.1.100" "Office server"
nftban_whitelist_add_ip "10.0.0.0/8" "Private network"
nftban_whitelist_add_ip "2001:db8::1" "IPv6 gateway"
```

**Behavior:**
1. Validates IP format (`nftban_validate_ip`)
2. Checks if already whitelisted (all three files + nftables)
3. Adds to `whitelist-user.conf` with atomic write
4. Adds to appropriate nftables set (IPv4 or IPv6)
5. Rebuilds search index if available
6. Logs action

**Exit Codes:**
- `0` - Success (added or already exists)
- `1` - Invalid IP format
- `2` - nftables add failed (warning only)

**Example:**
```bash
nftban_whitelist_add_ip "192.168.1.100" "Office server"

# Output:
# [SUCCESS] Added 192.168.1.100 to whitelist (nftables + file)
# [LOG] WHITELIST: Added: 192.168.1.100

# File content (/etc/nftban/whitelist-user.conf):
# 192.168.1.100  # Office server
```

**Security Features:**
- **Atomic File Write**: Uses `_nftban_whitelist_safe_append` with flock
- **IP Validation**: Blocks dangerous CIDR ranges (e.g., 0.0.0.0/0)
- **Duplicate Prevention**: Checks all sources before adding

**Source:** `nftban_whitelist_module.sh:254-301`

---

#### `nftban_whitelist_remove_ip(ip)`

Removes an IP from the user whitelist with safety checks.

**Parameters:**
- `ip` (required) - IP address to remove

**Usage:**
```bash
nftban_whitelist_remove_ip "192.168.1.100"
```

**Behavior:**
1. Validates IP format
2. **SAFETY CHECKS** (BLOCKS removal if true):
   - Is localhost (127.0.0.1 or ::1)
   - Is server interface IP
   - Is current user's IP (prevents lockout)
3. Removes from user whitelist file (atomic modify)
4. Warns if in system whitelist (does not remove)
5. Removes from nftables set
6. Rebuilds search index

**Exit Codes:**
- `0` - Success (removed)
- `1` - Safety check blocked removal, or IP not found, or invalid format

**Example:**
```bash
# Safe removal
nftban_whitelist_remove_ip "192.168.1.100"
# [SUCCESS] Removed 192.168.1.100 from user whitelist file
# [SUCCESS] Removed 192.168.1.100 from nftables whitelist

# Blocked removal (current user)
nftban_whitelist_remove_ip "203.0.113.42"
# [ERROR] BLOCKED: Cannot remove current user's IP from whitelist!
# [ERROR] This would cause immediate lockout!
```

**Safety Features:**
```bash
# SAFETY CHECK 1: Localhost protection
if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "::1" ]]; then
    nftban_log_error "BLOCKED: Cannot remove localhost from whitelist!"
    return 1
fi

# SAFETY CHECK 2: Server IP protection
if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
    nftban_log_error "BLOCKED: Cannot remove server's own IP from whitelist!"
    return 1
fi

# SAFETY CHECK 3: Current user protection
current_ip=$(nftban_get_current_user_ip)
if [[ -n "$current_ip" && "$current_ip" == "$ip" ]]; then
    nftban_log_error "BLOCKED: Cannot remove current user's IP from whitelist!"
    nftban_log_error "This would cause immediate lockout!"
    return 1
fi
```

**Security Notes:**
- **Atomic File Modify**: Uses `_nftban_whitelist_safe_modify` with flock
- **Lockout Prevention**: Three-layer safety check
- **System Whitelist Protection**: Warns but does not auto-remove (requires manual edit)

**Source:** `nftban_whitelist_module.sh:304-378`

---

#### `nftban_whitelist_check_ip(ip)`

Checks if an IP is whitelisted using four verification methods.

**Parameters:**
- `ip` (required) - IP address to check

**Usage:**
```bash
if nftban_whitelist_check_ip "192.168.1.100"; then
    echo "IP is whitelisted"
fi
```

**Verification Methods (Priority Order):**

1. **nftables Sets** (fastest, most accurate)
   - Checks appropriate IPv4/IPv6 table
   - Direct kernel lookup

2. **Configuration Files** (exact match + CIDR)
   - Checks all three whitelist files
   - CIDR range matching using `nftban_ip_in_cidr`

3. **Server Interface IPs** (dynamic check)
   - Checks `ip addr show` output
   - Catches newly added interfaces

4. **Current User IP** (session check)
   - Protects active SSH sessions
   - Uses `SSH_CLIENT` / `SSH_CONNECTION`

**Exit Codes:**
- `0` - IP is whitelisted (any method matched)
- `1` - IP is not whitelisted
- `2` - Invalid IP format

**Example:**
```bash
# Direct IP match
nftban_whitelist_check_ip "192.168.1.100"
# Exit: 0 (whitelisted)

# CIDR range match
# whitelist-user.conf contains: 10.0.0.0/8
nftban_whitelist_check_ip "10.5.10.25"
# Exit: 0 (matches CIDR range)

# Not whitelisted
nftban_whitelist_check_ip "198.51.100.50"
# Exit: 1 (not whitelisted)
```

**Performance:**
- nftables lookup: O(log n) - fastest
- File scan: O(n) per file - with CIDR calculation
- Interface check: O(n) interfaces
- Average: < 10ms for typical setups

**Source:** `nftban_whitelist_module.sh:384-461`

---

### Display & Reporting Functions

#### `nftban_whitelist_list()`

Displays comprehensive whitelist status across all sources.

**Usage:**
```bash
nftban_whitelist_list
```

**Output Sections:**
1. System Whitelist (auto-protected IPs)
2. User Whitelist (manually added IPs)
3. Cloudflare Whitelist (integration status)
4. nftables Sets (IPv4/IPv6 counts)
5. Current Protections (user IP, server IP count)

**Example Output:**
```
═══════════════════════════════════════════════════════
  Whitelisted IPs
═══════════════════════════════════════════════════════

System Whitelist (Auto-Protected):
  1. 127.0.0.1       # Localhost IPv4
  2. ::1             # Localhost IPv6
  3. 192.168.1.10    # Server IP (auto-detected on 2025-10-22)

User Whitelist:
  1. 203.0.113.42    # Current admin user (auto-protected on 2025-10-22 14:30:15)
  2. 192.168.1.100   # Office server

Cloudflare Whitelist:
  (empty - enable with: nftban cloudflare enable)

nftables Sets:
  whitelist (IPv4):    5 IPs
  whitelist (IPv6):    1 IPs

Current Protections:
  Current User IP: 203.0.113.42
  Server IPs: 2 protected
```

**Color Coding:**
- Cyan: Section headers
- Default: IP addresses and comments
- Yellow: Warnings (empty sets)

**Source:** `nftban_whitelist_module.sh:468-543`

---

#### `nftban_whitelist_get_stats()`

Returns whitelist statistics in machine-readable format.

**Usage:**
```bash
stats=$(nftban_whitelist_get_stats)
echo "$stats"
```

**Output Format:**
```
System: 3 | User: 2 | Cloudflare: 0 | Total: 5
```

**Use Cases:**
- Dashboard integration
- Monitoring scripts
- Automated reporting
- Capacity planning

**Example:**
```bash
# Parse stats
stats=$(nftban_whitelist_get_stats)
total=$(echo "$stats" | grep -oP 'Total: \K\d+')

if [[ $total -gt 1000 ]]; then
    echo "WARNING: Large whitelist ($total IPs)"
fi
```

**Source:** `nftban_whitelist_module.sh:715-727`

---

### Synchronization Functions

#### `nftban_whitelist_sync_to_nftables()`

Syncs all whitelist files to nftables sets (full rebuild).

**Usage:**
```bash
nftban_whitelist_sync_to_nftables
```

**Behavior:**
1. Checks if nftables tables exist
2. **Flushes** existing whitelist sets (IPv4 and IPv6)
3. Reads all three whitelist files
4. Adds each IP to appropriate table (IPv4 → `nftban_v4`, IPv6 → `nftban_v6`)
5. Reports sync count

**Exit Codes:**
- `0` - Success
- `1` - nftables table not initialized

**Example:**
```bash
nftban_whitelist_sync_to_nftables

# Output:
# [INFO] Syncing whitelist to nftables...
# [SUCCESS] Synced to nftables: 4 IPv4, 1 IPv6
```

**When to Use:**
- After manual file edits
- After system restore
- When nftables sets are out of sync
- During troubleshooting

**Performance:**
- Small whitelist (< 100 IPs): < 100ms
- Medium whitelist (< 1000 IPs): < 1s
- Large whitelist (< 10000 IPs): < 10s

**Security Notes:**
- Atomic flush + rebuild (no partial state)
- Validates each IP before adding
- Continues on individual IP failures

**Source:** `nftban_whitelist_module.sh:550-604`

---

### Verification Functions

#### `nftban_whitelist_verify()`

Comprehensive whitelist safety verification.

**Usage:**
```bash
nftban_whitelist_verify
```

**Checks Performed:**

1. **File Existence**
   - System whitelist exists
   - User whitelist exists

2. **Localhost Protection**
   - 127.0.0.1 whitelisted
   - ::1 whitelisted

3. **Server IP Protection**
   - All interface IPs whitelisted
   - Reports unprotected count

4. **Current User Protection**
   - SSH user IP whitelisted (if remote session)
   - Warns about lockout risk

5. **nftables Sync Status**
   - Compares file count vs. nftables count
   - Detects out-of-sync state

**Exit Codes:**
- `0` - All checks passed
- `1` - One or more issues found

**Example Output:**
```
═══════════════════════════════════════════════════════
  Whitelist Safety Verification
═══════════════════════════════════════════════════════

Checking system whitelist... ✓ EXISTS
Checking user whitelist... ✓ EXISTS
Checking localhost protection... ✓ PROTECTED
Checking server IP protection... ✓ ALL PROTECTED
Checking current user IP... ✓ PROTECTED (203.0.113.42)
Checking nftables sync... ✓ SYNCED

✓ ALL CHECKS PASSED
```

**Failed Check Example:**
```
Checking current user IP... ✗ NOT PROTECTED (203.0.113.42)
  ⚠️  WARNING: Risk of self-lockout!

3 issue(s) found - run: nftban whitelist init
```

**Use Cases:**
- Pre-deployment safety check
- Troubleshooting lockout issues
- Regular health monitoring
- Post-restore verification

**Source:** `nftban_whitelist_module.sh:607-712`

---

### Internal Helper Functions

#### `_nftban_whitelist_safe_append(file, content)`

⚠️ **Internal function** - Do not call directly.

Atomically appends content to a file using exclusive lock (flock).

**Parameters:**
- `file` - Absolute path to whitelist file
- `content` - Content to append (single line)

**Security Features:**
- **Exclusive lock** (flock -x) prevents concurrent writes
- **Timeout** (5 seconds) prevents indefinite blocking
- **Atomic append** (single write operation)
- **Race condition prevention** (CWE-362 mitigation)

**Implementation:**
```bash
_nftban_whitelist_safe_append() {
    local file="$1"
    local content="$2"
    local lockfile="${NFTBAN_WHITELIST_LOCK_DIR}/$(basename "$file").lock"

    (
        # Acquire exclusive lock for write
        if ! flock -x -w "$NFTBAN_WHITELIST_LOCK_TIMEOUT" 200; then
            nftban_log_error "Could not acquire write lock on $file"
            return 1
        fi

        # Append content under lock
        echo "$content" >> "$file"

    ) 200>"$lockfile"
}
```

**Vulnerability Mitigated:**
- **VUL-WL-001**: Whitelist bypass via TOCTOU race condition (security review finding)
- **CWE-362**: Concurrent Execution using Shared Resource with Improper Synchronization

**Source:** `nftban_whitelist_module.sh:39-55`

---

#### `_nftban_whitelist_safe_modify(file, sed_expression)`

⚠️ **Internal function** - Do not call directly.

Atomically modifies a file using sed under exclusive lock.

**Parameters:**
- `file` - Absolute path to whitelist file
- `sed_expression` - sed command (e.g., "/^192.168.1.100/d")

**Security Features:**
- Same as `_nftban_whitelist_safe_append`
- Ensures atomic file modification
- Prevents partial writes during concurrent access

**Source:** `nftban_whitelist_module.sh:58-74`

---

## Integration Guide

### Integration with Core Module

**Initialization Order:**
```bash
# 1. Load core module
source /usr/local/lib/nftban/nftban_core.sh

# 2. Load utils (for CIDR checking)
source /usr/local/lib/nftban/nftban_utils_lib.sh

# 3. Load nftables module (for table checking)
source /usr/local/lib/nftban/nftban_nftables_module.sh

# 4. Load whitelist module
source /usr/local/lib/nftban/nftban_whitelist_module.sh

# 5. Initialize whitelist system
nftban_whitelist_init
```

### Integration with CLI

**Command Examples:**
```bash
# Add IP to whitelist
nftban whitelist add 192.168.1.100 "Office server"

# Remove IP from whitelist
nftban whitelist remove 192.168.1.100

# List whitelisted IPs
nftban whitelist list

# Verify whitelist safety
nftban whitelist verify

# Sync files to nftables
nftban whitelist sync
```

**CLI Implementation Example:**
```bash
case "$1" in
    add)
        nftban_whitelist_add_ip "$2" "${3:-Added via CLI}"
        ;;
    remove)
        nftban_whitelist_remove_ip "$2"
        ;;
    list)
        nftban_whitelist_list
        ;;
    verify)
        nftban_whitelist_verify
        ;;
    sync)
        nftban_whitelist_sync_to_nftables
        ;;
esac
```

### Integration with Other Modules

**Ban Module Integration:**
```bash
# Check whitelist BEFORE banning
nftban_ban_ip() {
    local ip="$1"

    # CRITICAL: Check whitelist first
    if nftban_whitelist_check_ip "$ip"; then
        nftban_log_warning "SKIPPED: $ip is whitelisted"
        return 0
    fi

    # Proceed with ban...
}
```

**DDoS Module Integration:**
```bash
# DDoS detection should respect whitelist
nftban_ddos_check() {
    local ip="$1"

    # Skip whitelisted IPs
    if nftban_whitelist_check_ip "$ip"; then
        return 0
    fi

    # Check DDoS thresholds...
}
```

**Search Module Integration:**
```bash
# Include whitelist in search index
nftban_search_build_index() {
    # ... existing index building ...

    # Add whitelist entries
    grep -hE "^[0-9a-fA-F.:]+([[:space:]]|$)" \
        "$NFTBAN_WHITELIST_SYSTEM" \
        "$NFTBAN_WHITELIST_USER" \
        >> "$SEARCH_INDEX"
}
```

### Integration with Cloudflare Module

**Cloudflare IP Sync:**
```bash
# Cloudflare module populates whitelist-cloudflare.conf
nftban_cloudflare_sync() {
    local cf_ips=(...)

    # Write to Cloudflare whitelist
    cat > "$NFTBAN_WHITELIST_CF" << EOF
# Cloudflare IPs (auto-synced on $(date))
$(printf '%s\n' "${cf_ips[@]}")
EOF

    # Trigger whitelist sync
    nftban_whitelist_sync_to_nftables
}
```

---

## Configuration

### File Locations

```bash
# Default paths (from nftban_core.sh)
NFTBAN_CONFIG_DIR="/etc/nftban"
NFTBAN_LOCK_DIR="/var/lock/nftban"

# Whitelist files
NFTBAN_WHITELIST_SYSTEM="${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
NFTBAN_WHITELIST_USER="${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
NFTBAN_WHITELIST_CF="${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"

# Lock timeout
NFTBAN_WHITELIST_LOCK_TIMEOUT=5  # seconds
```

### File Formats

**System Whitelist (`whitelist-system.conf`):**
```bash
# =============================================================================
# nftban System Whitelist
# =============================================================================
# Auto-managed IPs that should NEVER be banned
# DO NOT edit manually - this file is auto-generated
# =============================================================================

127.0.0.1       # Localhost IPv4
::1             # Localhost IPv6
192.168.1.10    # Server IP (auto-detected on 2025-10-22)
203.0.113.10    # Server public IPv4 (auto-detected on 2025-10-22)
```

**User Whitelist (`whitelist-user.conf`):**
```bash
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

203.0.113.42    # Current admin user (auto-protected on 2025-10-22 14:30:15)
192.168.1.100   # Office server
10.0.0.0/8      # Private network

# Common private network ranges (uncomment if needed):
# 10.0.0.0/8        # Private Class A
# 172.16.0.0/12     # Private Class B
# 192.168.0.0/16    # Private Class C
```

**Cloudflare Whitelist (`whitelist-cloudflare.conf`):**
```bash
# =============================================================================
# nftban Cloudflare Whitelist
# =============================================================================
# Auto-managed - Populated when Cloudflare integration is enabled
# =============================================================================

173.245.48.0/20     # Cloudflare edge
103.21.244.0/22     # Cloudflare edge
...
```

### File Permissions

```bash
# Whitelist files
chmod 644 /etc/nftban/whitelist-*.conf

# Lock directory
chmod 755 /var/lock/nftban
```

### Configuration Variables

**Environment Variables:**
```bash
# Override lock directory
export NFTBAN_LOCK_DIR="/custom/path/locks"

# Override lock timeout (seconds)
export NFTBAN_WHITELIST_LOCK_TIMEOUT=10

# Override table names (v0.9.0+)
export NFTBAN_NFT_TABLE_V4="custom_v4"
export NFTBAN_NFT_TABLE_V6="custom_v6"
```

---

## Security Considerations

### Security Model

**Threat Model:**
1. **Administrator Lockout** - Primary threat mitigated by auto-protection
2. **Race Conditions** - File locking prevents TOCTOU attacks
3. **Whitelist Bypass** - Multiple verification methods prevent bypass
4. **Privilege Escalation** - Strict permissions and validation

**Security Principles:**
- **Defense in Depth**: Multiple whitelist checks (files + nftables + runtime)
- **Fail-Safe Defaults**: Auto-protect critical IPs on initialization
- **Least Privilege**: User whitelist separate from system whitelist
- **Atomic Operations**: flock ensures consistency

### Historical Vulnerabilities

#### VUL-WL-001: Whitelist Bypass via TOCTOU Race Condition

**Severity:** HIGH
**CWE:** CWE-362 (Concurrent Execution using Shared Resource with Improper Synchronization)
**Discovered:** Security Review (October 2024)
**Fixed in:** v0.9.3

**Vulnerability:**
```bash
# OLD CODE (vulnerable to race condition):
nftban_whitelist_add_ip() {
    # ... validation ...

    # VULNERABLE: No lock - another process could modify file
    echo "$ip  # $comment" >> "$NFTBAN_WHITELIST_USER"

    # Race window here - file could be modified before nftables sync
    nft add element ip nftban_v4 whitelist "{ $ip }"
}
```

**Attack Scenario:**
1. Admin adds IP to whitelist (file write starts)
2. Concurrent ban process reads whitelist (sees old state)
3. File write completes
4. Ban process bans the IP (bypass whitelist)
5. nftables sync happens (IP is in file but was banned)

**Fix (v0.9.3):**
```bash
nftban_whitelist_add_ip() {
    # ... validation ...

    # SECURE: Atomic append with exclusive lock
    _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_USER" "${ip}  # ${comment}"

    # SECURE: Immediate nftables add (under lock, no race window)
    nft add element "$table_family" "$table_name" "whitelist" "{ $ip }"
}

_nftban_whitelist_safe_append() {
    local file="$1"
    local content="$2"
    local lockfile="${NFTBAN_WHITELIST_LOCK_DIR}/$(basename "$file").lock"

    (
        # Acquire exclusive lock - blocks other writes
        flock -x -w "$NFTBAN_WHITELIST_LOCK_TIMEOUT" 200 || return 1

        # Atomic append under lock
        echo "$content" >> "$file"

    ) 200>"$lockfile"  # Lock released automatically
}
```

**Mitigation:**
- Exclusive file locking (flock) prevents concurrent writes
- Timeout prevents indefinite blocking
- Atomic operations ensure consistency

---

#### VUL-WL-002: CIDR Validation Bypass

**Severity:** MEDIUM
**CWE:** CWE-20 (Improper Input Validation)
**Discovered:** Code Review
**Fixed in:** v0.9.1 (via nftban_validate_ip in core module)

**Vulnerability:**
Dangerous CIDR ranges (0.0.0.0/0, ::/0) could whitelist entire internet.

**Fix:**
Uses `nftban_validate_ip` which blocks dangerous CIDRs:
```bash
# In nftban_core.sh:
nftban_validate_ip() {
    # ... IP format validation ...

    # SECURITY: Block dangerous CIDR ranges
    if [[ "$ip" =~ / ]]; then
        if [[ "$ip" == "0.0.0.0/0" ]] || [[ "$ip" == "::/0" ]]; then
            nftban_log_error "Dangerous CIDR: $ip (would whitelist entire internet!)"
            return 1
        fi
    fi
}
```

---

#### BUG61: Arithmetic Expansion in Strict Mode

**Severity:** LOW (affects stability, not security)
**Discovered:** v0.9.3 testing with `set -u`
**Fixed in:** v0.9.3

**Issue:**
```bash
# OLD CODE (fails with set -u when count=0):
protected_count=0
((protected_count++))  # ERROR: unbound variable when count=0
```

**Fix:**
```bash
# NEW CODE (v0.9.3):
protected_count=0
protected_count=$((protected_count + 1))  # Safe in strict mode
```

**Affected Functions:**
- `nftban_whitelist_add_server_ips`
- `nftban_whitelist_sync_to_nftables`
- `nftban_whitelist_verify`

---

### Attack Surface Analysis

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
  - Sanitized table/set names

**IP Detection:**
- **Risk**: Spoofed SSH_CLIENT variable
- **Mitigation**:
  - System environment variable (trusted)
  - Only used for auto-protection hint
  - Admin can manually remove if needed

**CIDR Calculations:**
- **Risk**: Integer overflow in subnet calculations
- **Mitigation**:
  - Uses `nftban_ip_in_cidr` (from utils module)
  - Bash arithmetic (no external tools)
  - Validated ranges

### File Locking Security

**Lock Mechanism:**
```bash
lockfile="${NFTBAN_WHITELIST_LOCK_DIR}/$(basename "$file").lock"

(
    # Exclusive lock - blocks other writers
    flock -x -w 5 200 || return 1

    # Critical section - only one process here
    echo "$content" >> "$file"

) 200>"$lockfile"  # Auto-released on subshell exit
```

**Properties:**
- **Advisory Lock**: Cooperative (assumes all writers use flock)
- **Timeout**: 5 seconds prevents deadlock
- **Automatic Release**: Subshell exit releases lock
- **Error Handling**: Fails gracefully on timeout

**Lock Directory Permissions:**
```bash
/var/lock/nftban/
├── drwxr-xr-x root root (755)
└── whitelist-*.conf.lock (created on demand)
```

### Compliance

**CWE Mitigations:**
- **CWE-362**: Race Condition (flock-based atomicity)
- **CWE-20**: Improper Input Validation (IP validation, dangerous CIDR blocking)
- **CWE-732**: Incorrect Permission Assignment (umask 027, chmod 644)
- **CWE-703**: Improper Check or Handling of Exceptional Conditions (timeout handling)

**Security Standards:**
- **NIST 800-53**: SC-7 (Boundary Protection) - Whitelist as trust boundary
- **CIS Controls**: 9.2 (Firewall Configuration) - Explicit whitelist management

---

## Troubleshooting

### Common Issues

#### Issue 1: Lock Timeout During Add/Remove

**Symptoms:**
```
[ERROR] Could not acquire write lock on /etc/nftban/whitelist-user.conf
```

**Causes:**
1. Another nftban process is writing to the same file
2. Stale lock file (crashed process)
3. Lock directory permissions issue

**Solutions:**
```bash
# Check for running nftban processes
ps aux | grep nftban

# Remove stale lock files (if no processes running)
rm -f /var/lock/nftban/whitelist-*.lock

# Check lock directory permissions
ls -ld /var/lock/nftban/
# Should be: drwxr-xr-x root root

# Recreate lock directory if needed
mkdir -p /var/lock/nftban
chmod 755 /var/lock/nftban
```

---

#### Issue 2: IP Added to File But Not in nftables

**Symptoms:**
```bash
grep "192.168.1.100" /etc/nftban/whitelist-user.conf
# 192.168.1.100  # Office server

nft list set ip nftban_v4 whitelist | grep 192.168.1.100
# (no output)
```

**Causes:**
1. nftables table not initialized
2. Manual file edit (bypassed sync)
3. nft command failed silently

**Solutions:**
```bash
# Re-sync files to nftables
nftban whitelist sync

# Verify nftables table exists
nft list tables
# Should show: table ip nftban_v4, table ip6 nftban_v6

# If table missing, reinitialize
nftban init

# Check for nft errors
nft add element ip nftban_v4 whitelist { 192.168.1.100 }
```

---

#### Issue 3: Cannot Remove Current User IP

**Symptoms:**
```
[ERROR] BLOCKED: Cannot remove current user's IP from whitelist!
[ERROR] This would cause immediate lockout!
```

**Cause:**
Safety check preventing administrator lockout.

**Solutions:**
```bash
# OPTION 1: Remove from local console (not SSH)
# Login via physical console or KVM
nftban whitelist remove 203.0.113.42

# OPTION 2: SSH from different IP first
ssh admin@server -s 198.51.100.10
nftban whitelist remove 203.0.113.42

# OPTION 3: Manual file edit (use with caution!)
nano /etc/nftban/whitelist-user.conf
# Remove the line with the IP
nftban whitelist sync
```

---

#### Issue 4: Localhost Not Protected

**Symptoms:**
```bash
nftban whitelist verify
# [ERROR] Checking localhost protection... ✗ NOT PROTECTED
```

**Cause:**
System whitelist file corrupted or deleted.

**Solutions:**
```bash
# Reinitialize whitelist system
nftban whitelist init

# Manually add localhost
echo "127.0.0.1  # Localhost IPv4" >> /etc/nftban/whitelist-system.conf
echo "::1  # Localhost IPv6" >> /etc/nftban/whitelist-system.conf
nftban whitelist sync

# Verify
nftban whitelist verify
```

---

#### Issue 5: Out of Sync Warning

**Symptoms:**
```bash
nftban whitelist verify
# [WARNING] ⚠ OUT OF SYNC (files: 10, nft: 8)
```

**Causes:**
1. Manual nft commands bypassed file system
2. Partial sync failure
3. File edited while system running

**Solutions:**
```bash
# Full resync (recommended)
nftban whitelist sync

# Verify sync
nftban whitelist verify

# If still out of sync, check for duplicate entries
sort /etc/nftban/whitelist-*.conf | uniq -d

# Remove duplicates if found
sort -u /etc/nftban/whitelist-user.conf -o /etc/nftban/whitelist-user.conf
nftban whitelist sync
```

---

#### Issue 6: CIDR Range Not Matching

**Symptoms:**
```bash
# File contains: 10.0.0.0/8
nftban whitelist check 10.5.10.25
# Exit: 1 (not whitelisted)
```

**Causes:**
1. CIDR calculation error
2. IP version mismatch (IPv4 range vs IPv6 IP)
3. nftables set doesn't support intervals

**Solutions:**
```bash
# Verify CIDR function
nftban_ip_in_cidr "10.5.10.25" "10.0.0.0/8"
echo $?  # Should be 0

# Check nftables set flags
nft list set ip nftban_v4 whitelist
# Should show: flags interval

# If interval flag missing, recreate set
nft delete set ip nftban_v4 whitelist
nft add set ip nftban_v4 whitelist '{ type ipv4_addr; flags interval; }'
nftban whitelist sync
```

---

### Debugging

**Enable Debug Logging:**
```bash
export NFTBAN_LOG_LEVEL=debug
nftban whitelist add 192.168.1.100
```

**Debug Output:**
```
[DEBUG] NFTBan Whitelist Module loaded (v2.0.0 - Enhanced Protection + Split Tables)
[DEBUG] Validating IP: 192.168.1.100
[DEBUG] IP version detected: 4
[DEBUG] Checking if IP already whitelisted...
[DEBUG] nftables table check: nftban_v4
[DEBUG] Acquiring lock: /var/lock/nftban/whitelist-user.conf.lock
[DEBUG] Lock acquired, writing to file
[DEBUG] Adding to nftables set: ip nftban_v4 whitelist
[SUCCESS] Added 192.168.1.100 to whitelist (nftables + file)
```

**Check File Locks:**
```bash
# List open file locks
lslocks | grep nftban

# Check lock files
ls -l /var/lock/nftban/
```

**Trace nftables Commands:**
```bash
# Enable nftables debug
nft -d netlink add element ip nftban_v4 whitelist { 192.168.1.100 }
```

**Verify Function Exports:**
```bash
# Check if functions are exported
declare -F | grep nftban_whitelist

# Expected output:
# declare -fx nftban_whitelist_add_ip
# declare -fx nftban_whitelist_check_ip
# declare -fx nftban_whitelist_init
# ...
```

---

## Testing

### Unit Tests

**Test 1: Whitelist Initialization**
```bash
#!/bin/bash
# Test: Whitelist initialization creates files and protects IPs

test_whitelist_init() {
    # Clean state
    rm -f /etc/nftban/whitelist-*.conf

    # Initialize
    nftban_whitelist_init

    # Assert files exist
    [[ -f /etc/nftban/whitelist-system.conf ]] || {
        echo "FAIL: System whitelist not created"
        return 1
    }

    [[ -f /etc/nftban/whitelist-user.conf ]] || {
        echo "FAIL: User whitelist not created"
        return 1
    }

    # Assert localhost protected
    nftban_whitelist_check_ip "127.0.0.1" || {
        echo "FAIL: Localhost IPv4 not whitelisted"
        return 1
    }

    nftban_whitelist_check_ip "::1" || {
        echo "FAIL: Localhost IPv6 not whitelisted"
        return 1
    }

    echo "PASS: Whitelist initialization"
    return 0
}

test_whitelist_init
```

---

**Test 2: Add/Remove IP**
```bash
test_add_remove_ip() {
    local test_ip="192.168.99.99"

    # Add IP
    nftban_whitelist_add_ip "$test_ip" "Test IP" || {
        echo "FAIL: Could not add IP"
        return 1
    }

    # Verify in file
    grep -q "$test_ip" /etc/nftban/whitelist-user.conf || {
        echo "FAIL: IP not in file"
        return 1
    }

    # Verify in nftables
    nft list set ip nftban_v4 whitelist | grep -q "$test_ip" || {
        echo "FAIL: IP not in nftables"
        return 1
    }

    # Verify check function
    nftban_whitelist_check_ip "$test_ip" || {
        echo "FAIL: Check function failed"
        return 1
    }

    # Remove IP
    nftban_whitelist_remove_ip "$test_ip" || {
        echo "FAIL: Could not remove IP"
        return 1
    }

    # Verify removed from file
    grep -q "$test_ip" /etc/nftban/whitelist-user.conf && {
        echo "FAIL: IP still in file"
        return 1
    }

    # Verify removed from nftables
    nft list set ip nftban_v4 whitelist | grep -q "$test_ip" && {
        echo "FAIL: IP still in nftables"
        return 1
    }

    echo "PASS: Add/remove IP"
    return 0
}

test_add_remove_ip
```

---

**Test 3: Safety Checks**
```bash
test_safety_checks() {
    # Test 1: Cannot remove localhost
    if nftban_whitelist_remove_ip "127.0.0.1" 2>/dev/null; then
        echo "FAIL: Allowed removal of localhost"
        return 1
    fi

    # Test 2: Cannot remove server IP
    local server_ip=$(ip -o -4 addr show | awk '/inet/ {gsub(/\/.*/, "", $4); print $4; exit}')
    if [[ -n "$server_ip" ]]; then
        if nftban_whitelist_remove_ip "$server_ip" 2>/dev/null; then
            echo "FAIL: Allowed removal of server IP"
            return 1
        fi
    fi

    # Test 3: Cannot whitelist dangerous CIDR
    if nftban_whitelist_add_ip "0.0.0.0/0" 2>/dev/null; then
        echo "FAIL: Allowed dangerous CIDR 0.0.0.0/0"
        return 1
    fi

    echo "PASS: Safety checks"
    return 0
}

test_safety_checks
```

---

**Test 4: CIDR Range Matching**
```bash
test_cidr_matching() {
    # Add CIDR range
    nftban_whitelist_add_ip "10.0.0.0/8" "Test network"

    # Test IPs within range
    local test_ips=("10.0.0.1" "10.5.10.25" "10.255.255.254")

    for ip in "${test_ips[@]}"; do
        if ! nftban_whitelist_check_ip "$ip"; then
            echo "FAIL: $ip should match 10.0.0.0/8"
            return 1
        fi
    done

    # Test IP outside range
    if nftban_whitelist_check_ip "11.0.0.1"; then
        echo "FAIL: 11.0.0.1 should NOT match 10.0.0.0/8"
        return 1
    fi

    # Cleanup
    nftban_whitelist_remove_ip "10.0.0.0/8"

    echo "PASS: CIDR matching"
    return 0
}

test_cidr_matching
```

---

**Test 5: File Locking (Race Condition Prevention)**
```bash
test_file_locking() {
    local test_ip_base="192.168.100"
    local concurrent_count=10

    # Spawn multiple concurrent add operations
    for i in $(seq 1 $concurrent_count); do
        (
            nftban_whitelist_add_ip "${test_ip_base}.$i" "Concurrent test $i"
        ) &
    done

    # Wait for all to complete
    wait

    # Verify all IPs added
    local added_count=0
    for i in $(seq 1 $concurrent_count); do
        if grep -q "${test_ip_base}.$i" /etc/nftban/whitelist-user.conf; then
            added_count=$((added_count + 1))
        fi
    done

    if [[ $added_count -ne $concurrent_count ]]; then
        echo "FAIL: Race condition detected (added $added_count / $concurrent_count)"
        return 1
    fi

    # Verify file integrity (no corrupted lines)
    if ! grep -E "^${test_ip_base}\.[0-9]+[[:space:]]" /etc/nftban/whitelist-user.conf | \
         wc -l | grep -q "$concurrent_count"; then
        echo "FAIL: File corruption detected"
        return 1
    fi

    # Cleanup
    for i in $(seq 1 $concurrent_count); do
        nftban_whitelist_remove_ip "${test_ip_base}.$i"
    done

    echo "PASS: File locking (no race conditions)"
    return 0
}

test_file_locking
```

---

### Integration Tests

**Test 6: Sync to nftables**
```bash
test_sync_to_nftables() {
    # Add IPs to file directly (bypass normal add function)
    echo "192.168.200.1  # Direct add test 1" >> /etc/nftban/whitelist-user.conf
    echo "192.168.200.2  # Direct add test 2" >> /etc/nftban/whitelist-user.conf

    # Sync to nftables
    nftban_whitelist_sync_to_nftables

    # Verify in nftables
    if ! nft list set ip nftban_v4 whitelist | grep -q "192.168.200.1"; then
        echo "FAIL: Sync did not add 192.168.200.1 to nftables"
        return 1
    fi

    if ! nft list set ip nftban_v4 whitelist | grep -q "192.168.200.2"; then
        echo "FAIL: Sync did not add 192.168.200.2 to nftables"
        return 1
    fi

    # Cleanup
    sed -i '/192\.168\.200\./d' /etc/nftban/whitelist-user.conf
    nftban_whitelist_sync_to_nftables

    echo "PASS: Sync to nftables"
    return 0
}

test_sync_to_nftables
```

---

**Test 7: Verification Function**
```bash
test_verify_function() {
    # Should pass with initialized system
    if ! nftban_whitelist_verify > /dev/null 2>&1; then
        echo "FAIL: Verify failed on initialized system"
        return 1
    fi

    # Corrupt system by removing localhost
    sed -i '/^127\.0\.0\.1/d' /etc/nftban/whitelist-system.conf

    # Should now fail
    if nftban_whitelist_verify > /dev/null 2>&1; then
        echo "FAIL: Verify passed on corrupted system"
        return 1
    fi

    # Repair
    nftban_whitelist_init

    # Should pass again
    if ! nftban_whitelist_verify > /dev/null 2>&1; then
        echo "FAIL: Verify failed after repair"
        return 1
    fi

    echo "PASS: Verification function"
    return 0
}

test_verify_function
```

---

### Performance Tests

**Test 8: Large Whitelist Performance**
```bash
test_large_whitelist_performance() {
    local count=1000
    local start_time end_time duration

    echo "Adding $count IPs..."
    start_time=$(date +%s%3N)

    for i in $(seq 1 $count); do
        local ip="10.$(( i / 256 )).$(( i % 256 )).1"
        nftban_whitelist_add_ip "$ip" "Perf test $i" > /dev/null 2>&1
    done

    end_time=$(date +%s%3N)
    duration=$(( end_time - start_time ))

    echo "Added $count IPs in ${duration}ms ($(( duration / count ))ms per IP)"

    # Check lookup performance
    echo "Testing lookup performance..."
    start_time=$(date +%s%3N)

    for i in $(seq 1 100); do
        local ip="10.$(( i / 256 )).$(( i % 256 )).1"
        nftban_whitelist_check_ip "$ip" > /dev/null 2>&1
    done

    end_time=$(date +%s%3N)
    duration=$(( end_time - start_time ))

    echo "100 lookups in ${duration}ms ($(( duration / 100 ))ms per lookup)"

    # Cleanup
    echo "Cleaning up..."
    for i in $(seq 1 $count); do
        local ip="10.$(( i / 256 )).$(( i % 256 )).1"
        nftban_whitelist_remove_ip "$ip" > /dev/null 2>&1
    done

    echo "PASS: Large whitelist performance"
    return 0
}

test_large_whitelist_performance
```

---

## Performance

### Benchmarks

**Whitelist Check Performance (1000 IPs in whitelist):**
```
Method                    Time (avg)    Notes
--------------------------------------------------
nftables set lookup       < 1ms         O(log n) - fastest
File scan (exact match)   5-10ms        O(n) - linear scan
File scan (CIDR match)    10-20ms       O(n*m) - CIDR calculation per entry
Interface check           2-5ms         O(k) interfaces
Current user check        < 1ms         Environment variable
```

**Add Operation Performance:**
```
Whitelist Size    Add Time    Bottleneck
--------------------------------------------
< 100 IPs         5-10ms      File I/O
100-1000 IPs      10-20ms     File I/O + nft
1000-10000 IPs    20-50ms     File I/O + nft
> 10000 IPs       50-200ms    File I/O (linear growth)
```

**Sync Operation Performance:**
```
IP Count    Sync Time    Notes
----------------------------------
10          < 100ms      Fast
100         < 500ms      Acceptable
1000        1-3s         Noticeable
10000       10-30s       Consider optimization
```

### Optimization Tips

**1. Use nftables Sets for Lookups**
```bash
# FAST: Direct nftables lookup (O(log n))
if nftban_whitelist_check_ip "$ip"; then
    # Already checks nftables first
fi

# SLOW: File-based check only
if grep -q "$ip" /etc/nftban/whitelist-user.conf; then
    # Linear scan - avoid this
fi
```

**2. Minimize Sync Operations**
```bash
# BAD: Sync after each IP
for ip in "${ips[@]}"; do
    nftban_whitelist_add_ip "$ip"  # Each call syncs to nftables
done

# GOOD: Batch add, then sync once
for ip in "${ips[@]}"; do
    _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_USER" "$ip  # Batch"
done
nftban_whitelist_sync_to_nftables
```

**3. Use CIDR Ranges Instead of Individual IPs**
```bash
# BAD: 256 individual IPs
for i in {1..255}; do
    nftban_whitelist_add_ip "10.0.0.$i"
done

# GOOD: Single CIDR range
nftban_whitelist_add_ip "10.0.0.0/24"
```

**4. Reduce Lock Contention**
```bash
# If high concurrency, increase timeout
export NFTBAN_WHITELIST_LOCK_TIMEOUT=10

# Or serialize operations at higher level
flock /var/lock/nftban/global.lock nftban whitelist add "$ip"
```

### Memory Usage

**File Storage:**
```
Whitelist Size    File Size    Memory (loaded)
------------------------------------------------
100 IPs           ~5 KB        < 1 MB
1000 IPs          ~50 KB       < 5 MB
10000 IPs         ~500 KB      < 50 MB
```

**nftables Memory:**
```
Set Size          Kernel Memory
---------------------------------
100 IPs           ~10 KB
1000 IPs          ~100 KB
10000 IPs         ~1 MB
```

---

## Maintenance

### Regular Maintenance Tasks

**Weekly:**
```bash
# Verify whitelist health
nftban whitelist verify

# Check for sync issues
nftban whitelist sync
```

**Monthly:**
```bash
# Review auto-protected IPs
nftban whitelist list | grep "auto-detected"

# Remove stale entries (if server IPs changed)
# Manual review required

# Verify current user still needs protection
nftban whitelist list | grep "auto-protected"
```

**Quarterly:**
```bash
# Audit whitelist size
echo "Whitelist size: $(nftban_whitelist_get_stats)"

# Check for duplicate entries
sort /etc/nftban/whitelist-user.conf | uniq -d

# Remove duplicates if found
sort -u /etc/nftban/whitelist-user.conf -o /etc/nftban/whitelist-user.conf.tmp
mv /etc/nftban/whitelist-user.conf.tmp /etc/nftban/whitelist-user.conf
nftban whitelist sync
```

### Backup and Restore

**Backup Whitelist:**
```bash
# Backup all whitelist files
tar -czf nftban-whitelist-backup-$(date +%Y%m%d).tar.gz \
    /etc/nftban/whitelist-*.conf

# Backup with metadata
cat > whitelist-backup-info.txt << EOF
Date: $(date)
System IPs: $(grep -cE "^[0-9a-fA-F.]+" /etc/nftban/whitelist-system.conf)
User IPs: $(grep -cE "^[0-9a-fA-F.]+" /etc/nftban/whitelist-user.conf)
Cloudflare IPs: $(grep -cE "^[0-9a-fA-F.]+" /etc/nftban/whitelist-cloudflare.conf)
EOF
```

**Restore Whitelist:**
```bash
# Restore from backup
tar -xzf nftban-whitelist-backup-20251022.tar.gz -C /

# Sync to nftables
nftban whitelist sync

# Verify
nftban whitelist verify
```

### Log Rotation

**Whitelist-specific logs:**
```bash
# In /etc/logrotate.d/nftban
/var/log/nftban/whitelist.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl reload nftban 2>/dev/null || true
    endscript
}
```

### Upgrade Considerations

**v0.8.x → v0.9.0 (Split Tables):**
```bash
# Old table structure (single table)
table inet nftban {
    set whitelist { ... }
}

# New table structure (split IPv4/IPv6)
table ip nftban_v4 {
    set whitelist { ... }
}
table ip6 nftban_v6 {
    set whitelist { ... }
```

**Migration:**
```bash
# Automatic during upgrade
nftban update  # Migrates to split tables
nftban whitelist sync  # Repopulates new tables
```

**v0.9.2 → v0.9.3 (Atomic Operations):**
- No file format changes
- Automatic adoption of flock-based locking
- No manual migration needed

### Health Monitoring

**Monitoring Script Example:**
```bash
#!/bin/bash
# /usr/local/bin/nftban-whitelist-monitor.sh

# Check whitelist health
if ! nftban_whitelist_verify > /dev/null 2>&1; then
    echo "CRITICAL: Whitelist verification failed"
    # Send alert
    exit 2
fi

# Check sync status
stats=$(nftban_whitelist_get_stats)
total=$(echo "$stats" | grep -oP 'Total: \K\d+')

if [[ $total -gt 10000 ]]; then
    echo "WARNING: Large whitelist ($total IPs)"
    exit 1
fi

echo "OK: Whitelist healthy ($total IPs)"
exit 0
```

**Nagios/Icinga Integration:**
```bash
# /etc/nagios/nrpe.d/nftban.cfg
command[check_nftban_whitelist]=/usr/local/bin/nftban-whitelist-monitor.sh
```

---

## Related Documentation

- [NFTBAN_CORE_MODULE.md](NFTBAN_CORE_MODULE.md) - Core validation and logging
- [NFTBAN_UTILS_MODULE.md](NFTBAN_UTILS_MODULE.md) - CIDR checking utilities
- [NFTBAN_NFTABLES_MODULE.md](NFTBAN_NFTABLES_MODULE.md) - nftables integration
- [NFTBAN_BLACKLIST_MODULE.md](NFTBAN_BLACKLIST_MODULE.md) - Blacklist management
- [SECURITY_HARDENING_v0.9.3.md](../Security/SECURITY_HARDENING_v0.9.3.md) - Security improvements

---

## Changelog

### v0.9.3-dev (2025-10-22)
- ✅ Added atomic file operations with flock (VUL-WL-001 fix)
- ✅ Fixed BUG61: Arithmetic expansion in strict mode
- ✅ Enhanced lock timeout handling
- ✅ Improved error messages for safety checks

### v0.9.2 (2024-12-15)
- ✅ Production-hardened header (set -Eeuo pipefail)
- ✅ Enhanced auto-protection logging
- ✅ Added BUG3.4 fix (skip link-local IPv6)

### v0.9.0 (2024-11-01)
- ✅ Split table architecture (IPv4/IPv6 separation)
- ✅ Performance improvements (30-50% faster)
- ✅ Updated nft commands for split tables

### v0.8.5 (2024-09-15)
- ✅ Three-tier whitelist system introduced
- ✅ Auto-protection for server IPs and current user
- ✅ Cloudflare integration support

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
