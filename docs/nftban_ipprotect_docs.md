# NFTBan IP Protection Module

**File:** `lib/nftban_ipprotect_module.sh`  
**Version:** 1.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Automatic protection of server IPs, public IPs, and current user sessions

---

## Overview

The IP Protection Module provides automatic detection and protection of critical IP addresses to prevent lockout scenarios. It continuously monitors and protects server interface IPs, public IPs (IPv4/IPv6), and active SSH session IPs, ensuring administrators and the server itself can never be accidentally banned.

The module implements a comprehensive IP detection system using multiple methods (ip command, hostname, ifconfig, who, last, ss/netstat) with automatic fallbacks. It maintains three distinct protection files: auto-whitelist (automatically managed), protected-ips reference (tracking log), and system-whitelist_ips.conf (comprehensive system IP list).

All protection operations are logged to a dedicated ip-protection.log file for audit purposes. The module integrates with the ban workflow to automatically deny any attempt to ban protected IPs, with critical alert notifications sent to administrators when protection triggers.

---

## Key Functions

### Public Functions (Exported) - IP Detection

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_ipprotect_get_local_ips()` | Get all local server IPs | None | Prints IPs (one per line) |
| `nftban_ipprotect_get_public_ipv4()` | Get server's public IPv4 | None | Prints IPv4 address |
| `nftban_ipprotect_get_public_ipv6()` | Get server's public IPv6 | None | Prints IPv6 address |
| `nftban_ipprotect_get_all_server_ips()` | Get all server IPs (local + public) | None | Prints all IPs |
| `nftban_ipprotect_get_current_user_ip()` | Get current SSH user's IP | None | Prints user's IP |
| `nftban_ipprotect_get_all_ssh_ips()` | Get all active SSH session IPs | None | Prints all SSH IPs |

### Public Functions (Exported) - Protection Management

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_ipprotect_init()` | Initialize protection system | None | 0 on success |
| `nftban_ipprotect_add()` | Add IP to auto-protection | `$1` - IP, `$2` - source label | 0 on success |
| `nftban_ipprotect_update()` | Update all auto-protections | None | 0 on success |
| `nftban_ipprotect_force()` | Force protect specific IP | `$1` - IP, `$2` - reason | 0 on success |
| `nftban_ipprotect_is_protected()` | Check if IP is protected | `$1` - IP | 0 if protected, 1 if not |
| `nftban_ipprotect_list()` | List all protected IPs | None | Prints formatted table |
| `nftban_ipprotect_summary()` | Show protection summary | None | Prints comprehensive status |
| `nftban_ipprotect_setup()` | Run initial setup | None | 0 on success |
| `nftban_ipprotect_check_before_ban()` | Check IP before banning | `$1` - IP | 0 if can ban, 1 if protected |
| `nftban_ipprotect_cleanup_stale()` | Remove stale SSH protections | None | 0 on success |
| `nftban_ipprotect_write_system_whitelist()` | Write system IPs to file | None | 0 on success |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_ipprotect_log()` | Log protection events | Logs to ip-protection.log |

---

## Configuration Variables

### File Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_IPPROTECT_LOG` | `/var/log/nftban/ip-protection.log` | Protection event log |
| `NFTBAN_PROTECTED_IPS_FILE` | `/etc/nftban/config/protected-ips.conf` | Protection reference/tracking |
| `NFTBAN_AUTO_WHITELIST_FILE` | `/etc/nftban/config/whitelist-auto.conf` | Auto-managed whitelist |
| `NFTBAN_SYSTEM_WHITELIST_FILE` | `/etc/nftban/config/system-whitelist_ips.conf` | System IP comprehensive list |

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `NFTBAN_AUTO_PROTECT_IPS` | `true` | Enable automatic IP protection |
| `NFTBAN_PROTECT_ALL_SSH_SESSIONS` | `true` | Protect all SSH sessions (not just current) |

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging, IP validation, public IP detection
- `nftban_whitelist_module.sh` - Whitelist operations (for adding protected IPs)

**External Commands (Required):**
- `ip` - Network interface queries (primary method)
- `date` - Timestamp generation
- `grep`, `awk`, `sed` - Text processing

**External Commands (Optional, Fallback Methods):**
- `hostname` - Alternative IP detection
- `ifconfig` - Legacy IP detection
- `who` - SSH session detection
- `last` - Login history
- `ss` or `netstat` - Active connection detection

---

## Usage Examples

### Example 1: Initialize IP Protection
```bash
# Initialize protection system
nftban_ipprotect_init

# Expected output:
# [INFO] Initializing IP protection system...
# [SUCCESS] Created auto-whitelist file
# [SUCCESS] Created system-whitelist_ips.conf
# [SUCCESS] IP protection system initialized

# Creates 3 files:
# - whitelist-auto.conf (auto-managed protections)
# - protected-ips.conf (tracking log)
# - system-whitelist_ips.conf (comprehensive system IP list)
```

### Example 2: Get Local Server IPs
```bash
# Detect all local interface IPs
nftban_ipprotect_get_local_ips

# Expected output:
# 192.168.1.100
# 10.0.0.1
# 172.16.0.5
# 2001:db8::1
# fd00::1

# Detection methods (in order):
# 1. ip -4/-6 addr show (primary, most reliable)
# 2. hostname -I (fallback for IPv4)
# 3. ifconfig (legacy fallback)
#
# Excludes:
# - Loopback (127.x.x.x, ::1)
# - Link-local IPv6 (fe80::)
```

### Example 3: Get Public IPs
```bash
# Get public IPv4
public_v4=$(nftban_ipprotect_get_public_ipv4)
echo "Public IPv4: $public_v4"
# Output: Public IPv4: 203.0.113.42

# Get public IPv6
public_v6=$(nftban_ipprotect_get_public_ipv6)
echo "Public IPv6: $public_v6"
# Output: Public IPv6: 2001:db8::1

# Get all server IPs (local + public)
nftban_ipprotect_get_all_server_ips

# Expected output:
# 10.0.0.1
# 172.16.0.5
# 192.168.1.100
# 203.0.113.42          # Public IPv4
# 2001:db8::1           # Public IPv6
# fd00::1
```

### Example 4: Get Current User and SSH Session IPs
```bash
# Get current SSH user's IP
current_ip=$(nftban_ipprotect_get_current_user_ip)
echo "Current user: $current_ip"
# Output: Current user: 203.0.113.50

# Get ALL active SSH session IPs
nftban_ipprotect_get_all_ssh_ips

# Expected output:
# 203.0.113.50  # Current user
# 203.0.113.51  # Another admin
# 198.51.100.10 # Third admin

# Detection methods:
# 1. SSH_CLIENT environment variable
# 2. who command output
# 3. last command (still logged in)
# 4. ss/netstat (established SSH connections on port 22)
```

### Example 5: Update Auto-Protections
```bash
# Update all auto-protections
nftban_ipprotect_update

# Expected output:
# [INFO] Updating auto-protected IPs...
# [INFO]   Detecting server local IPs...
# [SUCCESS] Auto-protected IP: 192.168.1.100 (SERVER_LOCAL)
# [SUCCESS] Auto-protected IP: 10.0.0.1 (SERVER_LOCAL)
# [INFO]   Detecting server public IPs...
# [SUCCESS] Auto-protected IP: 203.0.113.42 (SERVER_PUBLIC_IPV4)
# [INFO]   Detecting current user IP...
# [SUCCESS] Auto-protected IP: 203.0.113.50 (CURRENT_USER)
# [INFO]   Detecting all SSH session IPs...
# [SUCCESS] Auto-protected IP: 203.0.113.51 (SSH_SESSION)
# [SUCCESS] Auto-protection updated: 7 IPs protected
# [SUCCESS] System whitelist updated: 4 local IPs

# Process:
# 1. Protects localhost (127.0.0.1, ::1)
# 2. Detects and protects all local interface IPs
# 3. Detects and protects public IPv4/IPv6
# 4. Protects current SSH user
# 5. Protects all active SSH sessions (if enabled)
# 6. Writes to whitelist-auto.conf
# 7. Logs to protected-ips.conf
# 8. Adds to whitelist module
# 9. Writes comprehensive list to system-whitelist_ips.conf
```

### Example 6: Force Protect Specific IP
```bash
# Manually protect an IP
nftban_ipprotect_force "198.51.100.100" "VPN gateway"

# Expected output:
# [SUCCESS] Auto-protected IP: 198.51.100.100 (MANUAL: VPN gateway)

# IP is now:
# 1. Added to whitelist-auto.conf
# 2. Logged to protected-ips.conf
# 3. Added to whitelist module
# 4. Protected from banning

# Use cases:
# - VPN gateways
# - Load balancer IPs
# - Monitoring system IPs
# - Partner network IPs
```

### Example 7: Check if IP is Protected
```bash
# Check protection status
if nftban_ipprotect_is_protected "192.168.1.100"; then
    echo "IP is protected - cannot be banned"
else
    echo "IP is not protected - can be banned"
fi

# Check before banning (integrated into ban workflow)
if nftban_ipprotect_check_before_ban "192.168.1.100"; then
    echo "Safe to ban"
    nftban_blacklist_ban_ip "192.168.1.100" "sshd"
else
    echo "Cannot ban - IP is protected"
fi

# If protection triggers:
# [ERROR] CRITICAL: Cannot ban auto-protected IP: 192.168.1.100
# [ERROR] This IP is protected (server IP or active SSH session)
# Email alert sent to administrator
```

### Example 8: List Protected IPs
```bash
# List all protected IPs in table format
nftban_ipprotect_list

# Expected output:
# =======================================================
#  Auto-Protected IPs
# =======================================================
#
# Current Protection Status:
#
# No. IP Address                               Source               Protected At
# -------------------------------------------------------
# 1   127.0.0.1                                LOCALHOST_IPV4       2025-10-20 14:30:00
# 2   ::1                                      LOCALHOST_IPV6       2025-10-20 14:30:00
# 3   192.168.1.100                            SERVER_LOCAL         2025-10-20 14:30:00
# 4   10.0.0.1                                 SERVER_LOCAL         2025-10-20 14:30:00
# 5   203.0.113.42                             SERVER_PUBLIC_IPV4   2025-10-20 14:30:00
# 6   2001:db8::1                              SERVER_PUBLIC_IPV6   2025-10-20 14:30:00
# 7   203.0.113.50                             CURRENT_USER         2025-10-20 14:30:05
# 8   203.0.113.51                             SSH_SESSION          2025-10-20 14:30:05
# 9   198.51.100.100                           MANUAL: VPN gateway  2025-10-20 14:35:00
#
# Total protected: 9 IPs
#
# =======================================================
```

### Example 9: Show Protection Summary
```bash
# Show comprehensive protection status
nftban_ipprotect_summary

# Expected output:
# =======================================================
#  IP Protection Summary
# =======================================================
#
# Auto-Protection: true
# Protect All SSH: true
#
# Protected IPs by Source:
#   LOCALHOST_IPV4                   1 IPs
#   LOCALHOST_IPV6                   1 IPs
#   SERVER_LOCAL                     2 IPs
#   SERVER_PUBLIC_IPV4               1 IPs
#   SERVER_PUBLIC_IPV6               1 IPs
#   CURRENT_USER                     1 IPs
#   SSH_SESSION                      2 IPs
#   MANUAL: VPN gateway              1 IPs
#
# Current Server IPs:
#   Local IPs:
#     192.168.1.100
#     10.0.0.1
#
#   Public IPv4: 203.0.113.42
#   Public IPv6: 2001:db8::1
#
# Current SSH Sessions:
#   Active sessions: 3
#     203.0.113.50
#     203.0.113.51
#     198.51.100.10
#
# =======================================================
```

### Example 10: Run Initial Setup
```bash
# Complete setup process
nftban_ipprotect_setup

# Expected output:
# [INFO] Running IP protection setup...
# [INFO] Initializing IP protection system...
# [SUCCESS] IP protection system initialized
# [INFO] Updating auto-protected IPs...
# [SUCCESS] Auto-protection updated: 7 IPs protected
# [SUCCESS] IP protection setup complete
#
# IP Protection Configuration:
#   Auto-protect: ENABLED
#   Protect SSH sessions: ENABLED
#
# Protected IPs:
# [... full list display ...]
#
# To update protection:
#   nftban ipprotect update
#
# To disable auto-protection:
#   nftban config set NFTBAN_AUTO_PROTECT_IPS false
```

### Example 11: Clean Up Stale SSH Protections
```bash
# Remove protections for disconnected SSH sessions
nftban_ipprotect_cleanup_stale

# Expected output:
# [INFO] Cleaning up stale SSH session protections...
# [DEBUG] Removing stale SSH protection: 203.0.113.51
# [DEBUG] Removing stale SSH protection: 198.51.100.10
# [SUCCESS] Removed 2 stale SSH session protections

# Process:
# 1. Gets currently active SSH sessions
# 2. Compares with protected SSH_SESSION IPs
# 3. Removes protections for disconnected sessions
# 4. Keeps all other protection types (SERVER_LOCAL, etc.)

# Run periodically via cron:
# 0 * * * * /usr/local/bin/nftban ipprotect cleanup-stale
```

### Example 12: Write System Whitelist File
```bash
# Generate comprehensive system-whitelist_ips.conf
nftban_ipprotect_write_system_whitelist

# Expected output:
# [INFO] Writing system IPs to system-whitelist_ips.conf...
# [SUCCESS] System whitelist updated: 4 local IPs

# Creates file with:
# - Complete header with description
# - Loopback addresses (127.0.0.1, ::1)
# - All local interface IPs with timestamps
# - Public IPv4/IPv6 with timestamps
# - Summary footer with statistics

# File format:
# =============================================================================
# NFTBan Template File: system-whitelist_ips.conf
# =============================================================================
# [Header documentation]
#
# 127.0.0.1  # IPv4 Loopback
# ::1        # IPv6 Loopback
#
# =============================================================================
# System Local IPs (Auto-detected)
# =============================================================================
# 192.168.1.100  # Local interface - detected at 2025-10-20 14:30:00
# 10.0.0.1       # Local interface - detected at 2025-10-20 14:30:00
#
# =============================================================================
# System Public IPs (Auto-detected)
# =============================================================================
# 203.0.113.42   # Public IPv4 - detected at 2025-10-20 14:30:00
# 2001:db8::1    # Public IPv6 - detected at 2025-10-20 14:30:00
#
# =============================================================================
# Last updated: 2025-10-20 14:30:00
# Total system IPs protected: 4 local IPs
# Public IPv4: 203.0.113.42
# Public IPv6: 2001:db8::1
# =============================================================================
```

### Example 13: Integration with Ban Workflow
```bash
#!/bin/bash
# Custom ban script with protection check

IP="$1"

# ALWAYS check protection before banning
if ! nftban_ipprotect_check_before_ban "$IP"; then
    logger "Ban denied: $IP is protected"
    exit 1
fi

# Safe to ban
nftban_blacklist_ban_ip "$IP" "custom-script"

# This integration prevents:
# - Banning server IPs (self-lockout)
# - Banning current administrator (lockout)
# - Banning active SSH sessions (admin lockout)
# - Banning manually protected IPs
```

### Example 14: Configuration Management
```bash
# Enable auto-protection (default)
nftban_set_config "NFTBAN_AUTO_PROTECT_IPS" "true"

# Disable auto-protection (not recommended)
nftban_set_config "NFTBAN_AUTO_PROTECT_IPS" "false"

# Enable protection of all SSH sessions (default)
nftban_set_config "NFTBAN_PROTECT_ALL_SSH_SESSIONS" "true"

# Only protect current user (not all SSH sessions)
nftban_set_config "NFTBAN_PROTECT_ALL_SSH_SESSIONS" "false"

# After changing config, update protections
nftban_ipprotect_update
```

---

## File Structure

### Auto-Whitelist (`whitelist-auto.conf`)

**Purpose:** Automatically managed whitelist

**Content:**
```
# =============================================================================
# nftban Auto-Whitelist (Auto-Protected IPs)
# =============================================================================
# This file is automatically managed by the IP protection system
# IPs are automatically added to protect:
#   - Server's local IPs
#   - Server's public IP
#   - Current SSH session IPs
#   - Active user login IPs
# =============================================================================
# DO NOT EDIT MANUALLY - Use: nftban ipprotect update
# =============================================================================

127.0.0.1  # LOCALHOST_IPV4 - 2025-10-20 14:30:00
::1  # LOCALHOST_IPV6 - 2025-10-20 14:30:00
192.168.1.100  # SERVER_LOCAL - 2025-10-20 14:30:00
203.0.113.42  # SERVER_PUBLIC_IPV4 - 2025-10-20 14:30:00
203.0.113.50  # CURRENT_USER - 2025-10-20 14:30:05
```

**Management:** Automatically updated by `nftban_ipprotect_update()`

### Protected IPs Reference (`protected-ips.conf`)

**Purpose:** Tracking log with source information

**Format:** `IP|SOURCE|TIMESTAMP`

**Content:**
```
# =============================================================================
# nftban Protected IPs Reference
# =============================================================================
# This file tracks all auto-protected IPs with their source
# Format: IP_ADDRESS | SOURCE | TIMESTAMP
# =============================================================================

127.0.0.1|LOCALHOST_IPV4|2025-10-20 14:30:00
::1|LOCALHOST_IPV6|2025-10-20 14:30:00
192.168.1.100|SERVER_LOCAL|2025-10-20 14:30:00
203.0.113.42|SERVER_PUBLIC_IPV4|2025-10-20 14:30:00
203.0.113.50|CURRENT_USER|2025-10-20 14:30:05
203.0.113.51|SSH_SESSION|2025-10-20 14:30:05
198.51.100.100|MANUAL: VPN gateway|2025-10-20 14:35:00
```

**Usage:** Provides audit trail and enables source-based analysis

### System Whitelist (`system-whitelist_ips.conf`)

**Purpose:** Comprehensive system IP list with full documentation

**Features:**
- Complete template header with usage instructions
- Loopback addresses always included
- All local interface IPs with detection timestamps
- Public IPv4/IPv6 with detection timestamps
- Summary footer with statistics

**Auto-Generated:** Created/updated by `nftban_ipprotect_write_system_whitelist()`

**Integration:** Used by nftables configuration as trusted IP source

---

## File Operations

**Reads from:**
- `/proc/net/if_inet6` - IPv6 interfaces (via `ip` command)
- `/sys/class/net/*` - Network interfaces
- `/var/run/utmp` - Currently logged in users (via `who`)
- `/var/log/wtmp` - Login history (via `last`)
- `/proc/net/tcp`, `/proc/net/tcp6` - TCP connections (via `ss`/`netstat`)

**Writes to:**
- `/etc/nftban/config/whitelist-auto.conf` - Auto-whitelist
- `/etc/nftban/config/protected-ips.conf` - Protection tracking
- `/etc/nftban/config/system-whitelist_ips.conf` - Comprehensive system IP list
- `/var/log/nftban/ip-protection.log` - Protection event log

**Calls:**
- `nftban_whitelist_add_ip()` - Adds protected IPs to whitelist module
- `nftban_get_public_ip()` - Detects public IPs
- `nftban_get_current_user_ip()` - Detects current SSH user
- `nftban_send_email()` - Sends critical alerts

---

## Security Considerations

### Multi-Method IP Detection (Reliability)

**Why Multiple Methods?**
- Different systems have different tools
- Fallback ensures detection always works
- Cross-validation prevents missing IPs

**Detection Hierarchy:**
1. **ip command** (primary) - Most reliable, modern standard
2. **hostname -I** (fallback) - Simple, works on most systems
3. **ifconfig** (legacy) - Old systems compatibility
4. **who/last** (SSH) - Session detection
5. **ss/netstat** (connections) - Active SSH verification

### Ban Prevention Integration

**Critical Check:**
```bash
# Every ban operation checks protection first
nftban_ipprotect_check_before_ban "$IP"
  ↓
if protected:
    - Log error message
    - Log to ip-protection.log
    - Send CRITICAL email alert
    - Return error (prevent ban)
```

**Alert System:**
- Email sent on protection trigger
- Subject: "CRITICAL: Attempt to ban protected IP"
- Details: IP, protection reason, timestamp, server
- Priority: critical (bypasses email disable)

### Automatic Re-Protection

**Scenarios:**
- New network interface added → Auto-detected on next update
- Public IP changes → Auto-detected on next update
- New SSH session → Auto-protected immediately
- Server reboot → Protection restored on service start

**Update Triggers:**
- `nftban ipprotect update` - Manual
- `nftban init` - Initialization
- Periodic cron job - Automated
- Network change detection - Event-driven (if implemented)

### Stale Protection Cleanup

**Problem:** Disconnected SSH sessions remain protected forever

**Solution:** `nftban_ipprotect_cleanup_stale()`
- Checks current active SSH sessions
- Compares with protected SSH_SESSION IPs
- Removes protections for disconnected sessions
- Preserves all other protection types

**Recommended Schedule:**
```bash
# Hourly cleanup via cron
0 * * * * /usr/local/bin/nftban ipprotect cleanup-stale
```

### IPv6 Handling

**Full IPv6 Support:**
- Detects IPv6 interfaces
- Excludes link-local (fe80::)
- Excludes loopback (::1)
- Detects public IPv6
- Protects IPv6 SSH sessions

**Link-Local Exclusion:**
- fe80:: addresses are auto-configuration only
- Not routable, not protection-worthy
- Explicitly filtered out

---

## Error Handling

**Common Scenarios:**

```bash
# No IP detection tools available
nftban_ipprotect_get_local_ips
# Tries: ip → hostname → ifconfig
# If all fail: Returns empty (logs warning)

# Cannot detect public IP
nftban_ipprotect_get_public_ipv4
# Tries multiple external services
# If all fail: Returns empty (not critical)

# Invalid IP provided
nftban_ipprotect_force "999.999.999.999" "test"
# Output: [ERROR] Invalid IP address
# Returns: 1

# Protection files don't exist
nftban_ipprotect_list
# Output: No protected IPs found
# Suggestion: Run nftban ipprotect init

# Ban attempt on protected IP
nftban_ipprotect_check_before_ban "192.168.1.100"
# Output: [ERROR] CRITICAL: Cannot ban auto-protected IP
# Email alert sent
# Returns: 1 (ban prevented)
```

**Exit Codes:**
- `0` - Success
- `1` - Error (invalid IP, protection triggered, operation failed)

---

## Integration Points

**Called by:**
- `nftban init` - During system initialization
- `nftban_main_cli.sh` - For CLI commands (`nftban ipprotect ...`)
- `nftban_blacklist_module.sh` - Before banning IPs (protection check)
- Cron jobs - Periodic updates and cleanup
- Network change scripts - Event-driven protection

**Calls:**
- `nftban_core.sh` functions - Logging, IP validation, public IP detection
- `nftban_whitelist_module.sh` - `nftban_whitelist_add_ip()`
- `nftban_search_build_index()` - If search module loaded
- External: `ip`, `hostname`, `ifconfig`, `who`, `last`, `ss`, `netstat`

**Provides Services For:**
- Lockout prevention
- Server IP protection
- SSH session protection
- Manual IP protection
- Audit logging

---

## Performance Characteristics

### IP Detection Speed
- **Local IPs (ip command):** ~10-50ms
- **Local IPs (fallback methods):** ~50-200ms
- **Public IP detection:** ~500-2000ms (network query)
- **SSH session detection:** ~50-100ms
- **Total update time:** ~1-3 seconds

### Update Frequency
- **Manual:** On-demand via `nftban ipprotect update`
- **Automatic:** During `nftban init`
- **Periodic (recommended):** Every 15-60 minutes via cron
- **Event-driven:** Network changes (if monitoring configured)

### Resource Usage
- **CPU:** Minimal (<1% during update)
- **Memory:** <5MB
- **Disk I/O:** Minimal (small config files)
- **Network:** Optional (public IP detection)

---

## Change Log

### Version 1.0.0 (2025-10-20) - Initial Release
- Multi-method IP detection (ip, hostname, ifconfig)
- Automatic protection of server IPs (local + public)
- SSH session protection (current + all active)
- Manual IP protection (`force` function)
- Protection tracking and logging
- Ban prevention integration
- Stale protection cleanup
- Comprehensive system-whitelist_ips.conf generation
- Email alerts on protection triggers
- Full IPv6 support

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core utilities, public IP detection
- `nftban_whitelist_module.sh` - Whitelist operations (used for protection)
- `nftban_blacklist_module.sh` - Ban operations (protection check integration)
- `nftban_safety_module.sh` - Safety verification and safeguards

**Related Documentation:**
- `LOCKOUT_PREVENTION.md` - Comprehensive lockout prevention guide
- `IP_PROTECTION.md` - IP protection strategies
- `SSH_HARDENING.md` - SSH security best practices

**CLI Commands:**
```bash
# Initialize protection
sudo nftban ipprotect init

# Update all protections
sudo nftban ipprotect update

# Force protect IP
sudo nftban ipprotect force <IP> [reason]

# List protected IPs
nftban ipprotect list

# Show summary
nftban ipprotect summary

# Run initial setup
sudo nftban ipprotect setup

# Clean up stale SSH protections
sudo nftban ipprotect cleanup-stale
```

**Cron Integration:**
```bash
# Update protections every 30 minutes
*/30 * * * * /usr/local/bin/nftban ipprotect update

# Clean up stale SSH protections hourly
0 * * * * /usr/local/bin/nftban ipprotect cleanup-stale
```
