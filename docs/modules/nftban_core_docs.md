# NFTBan Core Module

**File:** `lib/nftban_core.sh`  
**Version:** 3.0.0 (v0.9.0 Split Table Architecture)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Foundation module providing logging, configuration, IP validation, and system initialization

---

## Overview

The Core Module serves as the foundation for the entire NFTBan system. It provides essential infrastructure including logging facilities, configuration management, IP address validation and manipulation, email notifications, and automatic module loading. This module must be loaded before any other NFTBan modules as it establishes the base environment and exports core functions used system-wide.

The v3.0.0 release introduces Split Table Architecture support (v0.9.0), separating IPv4 and IPv6 operations into distinct nftables tables (`nftban_v4` and `nftban_v6`) for improved performance and clarity. It maintains backward compatibility checks for legacy configurations.

All NFTBan modules depend on this core module for logging, IP validation, configuration access, and utility functions. The module automatically initializes directories, loads configurations, and imports all dependent modules in the correct dependency order.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_log()` | General logging with timestamp | `$1` - level, `$*` - message | Logs to file/stdout |
| `nftban_log_error()` | Error logging (red) | `$*` - message | Logs to stderr |
| `nftban_log_success()` | Success logging (green) | `$*` - message | Logs to stdout |
| `nftban_log_warning()` | Warning logging (yellow) | `$*` - message | Logs to stdout |
| `nftban_log_info()` | Info logging (blue) | `$*` - message | Logs to stdout |
| `nftban_log_debug()` | Debug logging (conditional) | `$*` - message | Only logs if DEBUG_ENABLED=true |
| `nftban_log_ban()` | Ban event logging | `$1` - IP, `$2` - jail, `$3` - action, `$4` - reason | Logs to ban-history.log |
| `nftban_get_config()` | Retrieve configuration value | `$1` - key, `$2` - default | Config value or default |
| `nftban_set_config()` | Set configuration value | `$1` - key, `$2` - value, `$3` - file (optional) | 0 on success |
| `nftban_load_config()` | Load all configuration files | None | Sources config files |
| `nftban_is_ipv4()` | Validate IPv4 address | `$1` - IP address | 0 if valid, 1 if invalid |
| `nftban_is_ipv6()` | Validate IPv6 address | `$1` - IP address | 0 if valid, 1 if invalid |
| `nftban_detect_ip_version()` | Detect IP version | `$1` - IP address | "4", "6", or "invalid" |
| `nftban_validate_ip()` | Comprehensive IP validation | `$1` - IP address | 0 if valid, 1 if invalid |
| `nftban_ip_to_int()` | Convert IPv4 to integer | `$1` - IPv4 address | Integer representation |
| `nftban_ip_in_cidr()` | Check if IP is in CIDR range | `$1` - IP, `$2` - CIDR | 0 if in range, 1 if not |
| `nftban_find_ip_locations()` | Find all locations of IP | `$1` - IP address | List of locations (stdout) |
| `nftban_geoip_lookup()` | GeoIP location lookup | `$1` - IP address | Country_City or status |
| `nftban_whois_lookup()` | WHOIS organization lookup | `$1` - IP address | Organization or status |
| `nftban_get_ip_info()` | Combined GeoIP + WHOIS | `$1` - IP address | Formatted info string |
| `nftban_send_email()` | Send email notification | `$1` - recipient, `$2` - subject, `$3` - body, `$4` - priority | 0 on success |
| `nftban_send_ban_notification()` | Send ban alert email | `$1` - IP, `$2` - jail, `$3` - action, `$4` - reason, `$5` - geoip, `$6` - whois | 0 on success |
| `nftban_send_rate_limit_alert()` | Send critical rate limit alert | `$1` - ban count, `$2` - time window, `$3` - rate limit | 0 on success |
| `nftban_check_root()` | Verify root privileges | None | 0 if root, 1 if not |
| `nftban_check_nftables_table()` | Check if nftables tables exist | None | 0 if exists, 1 if not |
| `nftban_atomic_write()` | Atomic file write operation | `$1` - target file, `$2` - content | Writes atomically |
| `nftban_backup_file()` | Create timestamped backup | `$1` - file path | Creates backup copy |
| `nftban_get_public_ip()` | Get server's public IP | `$1` - "ipv4" or "ipv6" | Public IP address |
| `nftban_get_current_user_ip()` | Get current SSH user's IP | None | User's IP address |
| `nftban_load_modules()` | Load all NFTBan modules | None | 0 always (logs failures) |

### Internal Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `nftban_init_directories()` | Create required directory structure | Creates /etc/nftban hierarchy |
| `nftban_core_init()` | Initialize core module | Auto-called on source |

---

## Configuration Variables

### Directory Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_BASE_DIR` | `/etc/nftban` | Base installation directory |
| `NFTBAN_LIB_DIR` | `/etc/nftban/lib` | Module library directory |
| `NFTBAN_CONFIG_DIR` | `/etc/nftban/config` | Configuration files directory |
| `NFTBAN_DATA_DIR` | `/etc/nftban/data` | Runtime data directory |
| `NFTBAN_CACHE_DIR` | `/etc/nftban/cache` | Cache directory |
| `NFTBAN_LOG_DIR` | `/var/log/nftban` | Log files directory |
| `NFTBAN_TEMPLATE_DIR` | `/etc/nftban/templates` | Template files directory |

### Configuration Files

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_MAIN_CONFIG` | `/etc/nftban/config/nftban.conf` | Main configuration file |
| `NFTBAN_LOCAL_CONFIG` | `/etc/nftban/config/nftban.conf.local` | Local overrides (priority) |

### Log Files

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_MAIN_LOG` | `/var/log/nftban/nftban.log` | Main system log |
| `NFTBAN_BAN_LOG` | `/var/log/nftban/ban-history.log` | Ban event history |
| `NFTBAN_SYNC_LOG` | `/var/log/nftban/sync.log` | Synchronization log |
| `NFTBAN_EMAIL_LOG` | `/var/log/nftban/email-notifications.log` | Email notification log |

### nftables Configuration (v0.9.0 Split Table Architecture)

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_NFT_TABLE_V4` | `nftban_v4` | IPv4 table name |
| `NFTBAN_NFT_TABLE_V6` | `nftban_v6` | IPv6 table name |
| `NFTBAN_NFT_FAMILY_V4` | `ip` | IPv4 table family |
| `NFTBAN_NFT_FAMILY_V6` | `ip6` | IPv6 table family |
| `NFTBAN_NFT_TABLE` | `nftban_global` | Legacy table (compatibility only) |
| `NFTBAN_NFT_FAMILY` | `inet` | Legacy family (compatibility only) |

### Color Constants

| Variable | Value | Description |
|----------|-------|-------------|
| `NFTBAN_RED` | `\033[0;31m` | Error messages |
| `NFTBAN_GREEN` | `\033[0;32m` | Success messages |
| `NFTBAN_YELLOW` | `\033[1;33m` | Warning messages |
| `NFTBAN_BLUE` | `\033[0;34m` | Info messages |
| `NFTBAN_MAGENTA` | `\033[0;35m` | Accent color |
| `NFTBAN_CYAN` | `\033[0;36m` | Accent color |
| `NFTBAN_NC` | `\033[0m` | No color (reset) |

---

## Dependencies

**Required Modules:**
- None (this is the foundation module)

**External Commands (Required):**
- `bash` (v4.0+) - Shell interpreter
- `nft` - nftables command (for table checks)
- `date` - Timestamp generation
- `mkdir`, `chmod` - Directory operations
- `grep`, `awk`, `sed`, `cut` - Text processing

**External Commands (Optional):**
- `mail` or `sendmail` - Email notifications
- `curl` or `wget` - Public IP detection, GeoIP lookups
- `geoiplookup` - GeoIP database queries
- `whois` - WHOIS lookups
- `python3` - JSON parsing for API responses
- `ip` - Network interface queries
- `who`, `last` - User session detection
- `ipcalc` or `sipcalc` - Advanced IP calculations

---

## Usage Examples

### Example 1: Basic Logging
```bash
# Source the core module
source /etc/nftban/lib/nftban_core.sh

# Log messages with different levels
nftban_log_info "System initialization started"
nftban_log_success "Configuration loaded successfully"
nftban_log_warning "Using default configuration"
nftban_log_error "Failed to connect to database"
nftban_log_debug "Debug info: variable=$value"

# Log a ban event
nftban_log_ban "192.168.1.100" "sshd" "BANNED" "Too many authentication failures"
```

### Example 2: Configuration Management
```bash
# Get configuration value with default
debug_mode=$(nftban_get_config "DEBUG_ENABLED" "false")
email=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "admin@example.com")

# Set configuration value
nftban_set_config "NFTBAN_EMAIL_ENABLED" "true"
nftban_set_config "CUSTOM_SETTING" "value" "/etc/nftban/config/custom.conf"

# Load all configurations
nftban_load_config
```

### Example 3: IP Validation and Detection
```bash
# Validate IP addresses
if nftban_validate_ip "192.168.1.1"; then
    echo "Valid IP"
fi

# Detect IP version
version=$(nftban_detect_ip_version "2001:db8::1")
echo "IP version: $version"  # Output: 6

# Check IPv4/IPv6 specifically
if nftban_is_ipv4 "10.0.0.1"; then
    echo "This is an IPv4 address"
fi

if nftban_is_ipv6 "fe80::1"; then
    echo "This is an IPv6 address"
fi
```

### Example 4: CIDR Range Checking
```bash
# Check if IP is within CIDR range
if nftban_ip_in_cidr "192.168.1.50" "192.168.1.0/24"; then
    echo "IP is in the subnet"
fi

# Check various CIDR ranges
nftban_ip_in_cidr "10.0.5.100" "10.0.0.0/16"   # Returns 0 (true)
nftban_ip_in_cidr "172.16.0.1" "192.168.0.0/16" # Returns 1 (false)
```

### Example 5: Finding IP Locations
```bash
# Find all locations where an IP exists
nftban_find_ip_locations "192.168.1.100"

# Expected output (if found):
# nftables:whitelist_v4
# file:whitelist-user
# server:interface

# Use in scripts
if nftban_find_ip_locations "$ip" | grep -q "whitelist"; then
    echo "IP is whitelisted"
fi
```

### Example 6: IP Information Lookup
```bash
# GeoIP lookup
geoip=$(nftban_geoip_lookup "8.8.8.8")
echo "Location: $geoip"  # Output: United_States_Mountain_View

# WHOIS lookup
whois=$(nftban_whois_lookup "8.8.8.8")
echo "Organization: $whois"  # Output: Google_LLC

# Combined lookup
info=$(nftban_get_ip_info "8.8.8.8")
echo "$info"  # Output: GeoIP: United_States | WHOIS: Google_LLC
```

### Example 7: Email Notifications
```bash
# Send basic email
nftban_send_email "admin@example.com" \
    "Test Subject" \
    "This is the email body" \
    "normal"

# Send ban notification
nftban_send_ban_notification \
    "192.168.1.100" \
    "sshd" \
    "BANNED" \
    "Failed password attempts" \
    "Russia_Moscow" \
    "HostingProvider_LLC"

# Send critical rate limit alert
nftban_send_rate_limit_alert 150 60 100
```

### Example 8: System Utilities
```bash
# Check if running as root
if ! nftban_check_root; then
    echo "Must run as root"
    exit 1
fi

# Check if nftables tables exist
if nftban_check_nftables_table; then
    echo "NFTBan tables are configured"
fi

# Get public IP
public_ipv4=$(nftban_get_public_ip "ipv4")
public_ipv6=$(nftban_get_public_ip "ipv6")

# Get current SSH user's IP
user_ip=$(nftban_get_current_user_ip)
echo "You are connecting from: $user_ip"

# Atomic file write (prevents corruption)
nftban_atomic_write "/etc/nftban/config/test.conf" "setting=value"

# Backup file with timestamp
nftban_backup_file "/etc/nftban/config/nftban.conf"
# Creates: /etc/nftban/data/backups/nftban.conf.20251020_143022
```

### Example 9: Module Loading
```bash
# Load all NFTBan modules in dependency order
nftban_load_modules

# Check if critical modules loaded
if [[ -z "${NFTBAN_NFTABLES_LOADED:-}" ]]; then
    echo "ERROR: nftables module failed to load"
    exit 1
fi
```

---

## File Operations

**Reads from:**
- `/etc/nftban/config/nftban.conf` - Main configuration file
- `/etc/nftban/config/nftban.conf.local` - Local configuration overrides (priority)
- `/etc/nftban/config/whitelist-*.conf` - Whitelist files (for IP location search)
- `/etc/nftban/config/blacklist-*.conf` - Blacklist files (for IP location search)
- `/etc/nftban/lib/*.sh` - Module files (for auto-loading)

**Writes to:**
- `/var/log/nftban/nftban.log` - Main system log
- `/var/log/nftban/ban-history.log` - Ban event history
- `/var/log/nftban/email-notifications.log` - Email notification log
- `/etc/nftban/config/nftban.conf.local` - Configuration updates
- `/etc/nftban/data/backups/*` - Timestamped backups
- `*.tmp.$$` - Temporary files for atomic writes

**nftables Access:**
- Reads from tables: `nftban_v4` (ip), `nftban_v6` (ip6)
- Queries sets: `whitelist`, `temp_ban`, `user_blacklist`, `system_blacklist`, `feeds`

---

## Security Considerations

### Privilege Requirements
- **Root Access Required:** Most operations require root privileges for nftables manipulation and system configuration
- **Validation:** `nftban_check_root()` enforces privilege requirements
- **File Permissions:** Creates directories with mode 755, ensuring system security

### Input Validation
- **IP Address Validation:** Comprehensive IPv4/IPv6 validation prevents injection attacks
- **Octet Range Checking:** IPv4 validation ensures octets are 0-255
- **CIDR Validation:** Prefix length validation prevents invalid CIDR ranges
- **Configuration Escaping:** Configuration values are properly quoted and escaped

### Atomic Operations
- **Atomic File Writes:** Uses temporary files + sync + mv for crash-safe writes
- **Prevents Corruption:** No partial writes even during crashes or SIGKILL
- **Timestamped Backups:** Original files preserved before modification

### Double-Load Prevention
- **Guard Variable:** `NFTBAN_CORE_LOADED` prevents duplicate sourcing
- **Idempotent:** Safe to source multiple times without side effects

### Email Security
- **Sender Validation:** Configurable sender address prevents spoofing
- **Priority Levels:** Critical alerts bypass normal email disable settings
- **Injection Prevention:** Email headers and body properly escaped

---

## Error Handling

**Common Errors:**
- `This operation must be run as root` - Non-root user attempted privileged operation
- `Module not found: [module]` - Module file missing during auto-load
- `Failed to load: [module]` - Module source failed (syntax error or dependency issue)
- `CRITICAL: [module] not loaded` - Essential module failed to load
- `Email recipient not configured` - Email notification attempted without recipient
- `No mail command available` - Email system not installed
- `Failed to send email` - Email delivery failed
- `Invalid IP address: [ip]` - IP validation failed

**Exit Codes:**
- Functions return `0` on success, `1` on failure
- Module loading always returns `0` (logs failures but doesn't exit)
- `nftban_check_root()` returns `1` if not root
- IP validation functions return `0` for valid, `1` for invalid
- `nftban_ip_in_cidr()` returns `0` if in range, `1` if not

**Logging Behavior:**
- All errors logged to both stderr and log file
- Debug messages only appear when `DEBUG_ENABLED=true`
- Ban events logged separately to `ban-history.log`
- Email notifications logged to `email-notifications.log`

---

## Integration Points

**Called by:**
- **All NFTBan modules** - Every module depends on core for logging and utilities
- `nftban` - Main CLI entry point
- `/etc/init.d/nftban` - System service init script
- Fail2Ban actions - Via action scripts in `/etc/fail2ban/action.d/nftban.conf`
- Cron jobs - Scheduled tasks source core for utilities

**Calls:**
- **External commands:** `nft`, `mail`, `sendmail`, `curl`, `wget`, `whois`, `geoiplookup`
- **System utilities:** `date`, `grep`, `awk`, `sed`, `ip`, `who`, `last`
- **All NFTBan modules:** Auto-loaded via `nftban_load_modules()`

**Exports to Environment:**
- All public functions listed above
- Available to child processes and sourced scripts
- Module guard variables prevent re-initialization

---

## Module Loading Order

The core module enforces strict dependency order when loading modules:

### Layer 1: Infrastructure (No Dependencies)
1. `nftban_nftables_module.sh` - nftables operations
2. `nftban_port_module.sh` - Port management
3. `nftban_template_module.sh` - Template processing

### Layer 2: Core Operations (Depend on Infrastructure)
4. `nftban_whitelist_module.sh` - Whitelist management
5. `nftban_blacklist_module.sh` - Blacklist management
6. `nftban_search_module.sh` - IP search operations
7. `nftban_safety_module.sh` - Safety checks
8. `nftban_ipprotect_module.sh` - IP protection
9. `nftban_fail2ban_module.sh` - Fail2Ban integration

### Layer 3: Advanced Features (Depend on Core Operations)
10. `nftban_cloudflare_module.sh` - Cloudflare integration
11. `nftban_geo_module.sh` - Geographic blocking
12. `nftban_geoip_module.sh` - GeoIP lookups
13. `nftban_stats_module.sh` - Statistics
14. `nftban_ratelimit_module.sh` - Rate limiting
15. `nftban_ddos_module.sh` - DDoS protection
16. `nftban_portscan_module.sh` - Port scan detection
17. `nftban_autorebuild_module.sh` - Auto-rebuild
18. `nftban_login_monitor_module.sh` - Login monitoring
19. `nftban_update_module.sh` - System updates
20. `nftban_maintenance_module.sh` - Maintenance tasks
21. `nftban_feeds_module.sh` - Threat feeds
22. `nftban_smoketest_module.sh` - Testing

---

## Performance Characteristics

- **Module Loading:** ~200-500ms for all modules on typical systems
- **IP Validation:** <1ms per IP address
- **CIDR Checking:** O(1) integer comparison after conversion
- **IP Location Search:** ~10-50ms (depends on number of sources)
- **GeoIP Lookup:** 100-1000ms (network API call)
- **WHOIS Lookup:** 500-2000ms (network query)
- **Atomic Write:** <10ms including sync
- **Configuration Read:** <5ms per value

**Optimization Notes:**
- Configuration values cached in memory after first read
- IP validation uses optimized regex patterns
- Module loading skips missing files without blocking
- GeoIP/WHOIS results should be cached by calling modules

---

## Change Log

### Version 3.0.0 (2025-10-20) - Split Table Architecture (v0.9.0)
- **BREAKING:** Split nftables architecture into separate IPv4/IPv6 tables
- Added constants: `NFTBAN_NFT_TABLE_V4`, `NFTBAN_NFT_TABLE_V6`
- Added family constants: `NFTBAN_NFT_FAMILY_V4`, `NFTBAN_NFT_FAMILY_V6`
- Updated `nftban_find_ip_locations()` for split table support
- Updated `nftban_check_nftables_table()` to check both tables
- Maintained backward compatibility checks for legacy configurations
- Enhanced module loading with dependency order enforcement
- Added critical module validation after loading

### Version 2.x (Previous Versions)
- Legacy unified table architecture (`nftban_global` inet table)
- Basic module loading without dependency enforcement

---

## See Also

**Related Modules:**
- `nftban_nftables_module.sh` - nftables operations (first loaded dependency)
- `nftban_search_module.sh` - Uses core IP validation extensively
- `nftban_whitelist_module.sh` - Uses core for IP protection
- `nftban_fail2ban_module.sh` - Uses core email and logging

**Related Documentation:**
- `README.md` - System overview and installation
- `ARCHITECTURE.md` - v0.9.0 Split Table Architecture details
- `CONFIGURATION.md` - Configuration file reference
- `API.md` - Function reference for module developers

**Configuration Files:**
- `/etc/nftban/config/nftban.conf` - Main configuration
- `/etc/nftban/config/nftban.conf.local` - Local overrides

**Log Files:**
- `/var/log/nftban/nftban.log` - Main system log
- `/var/log/nftban/ban-history.log` - Ban event history
