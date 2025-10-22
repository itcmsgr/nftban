# NFTBan Module: Core

**Version:** 0.9.3-dev
**Status:** Production
**Category:** Core
**Author:** ITCMS Team (Antonios Voulvoulis)
**Contact:** contact@itcms.gr
**Website:** https://itcms.gr
**Last Updated:** 2025-10-22

---

## Overview

**Purpose:** Provides foundational functionality for the entire NFTBan system including logging, configuration management, IP validation, file permissions, and utility functions.

**Key Features:**
- Unified logging contract with structured format
- Configuration management with dual-file support (.conf + .conf.local)
- Comprehensive IP validation (IPv4/IPv6) and CIDR calculations
- Secure file permissions enforcement (prevents privilege escalation)
- Email notification system for critical events
- Secure temp file management with automatic cleanup
- Hardened curl wrapper for safe external downloads
- Single-instance locking to prevent concurrent operations
- Input sanitization to prevent injection attacks
- Module auto-loader with enforced dependency order

**Dependencies:**
- `nft` (nftables) - for firewall table checks
- `bash` 4.0+ - for associative arrays and advanced features
- Optional: `mail` or `sendmail` - for email notifications
- Optional: `curl` or `wget` - for external API lookups
- Optional: `geoiplookup` - for GeoIP functionality

**When to Use:**
This module is automatically loaded by all other NFTBan modules. It provides the foundation that every other module depends on. Use it directly when you need logging, IP validation, configuration access, or any of the utility functions.

---

## Architecture

### Module Structure

**File:** `/etc/nftban/lib/nftban_core.sh`

**Public Functions (40+):**
- Logging: `nftban_log()`, `nftban_log_error()`, `nftban_log_success()`, `nftban_log_warning()`, `nftban_log_info()`, `nftban_log_debug()`, `nftban_log_ban()`, `nftban_log_whitelist_protection()`
- Configuration: `nftban_get_config()`, `nftban_set_config()`, `nftban_load_config()`
- IP Validation: `nftban_is_ipv4()`, `nftban_is_ipv6()`, `nftban_detect_ip_version()`, `nftban_validate_ip()`, `nftban_validate_cidr()`
- CIDR Operations: `nftban_ip_to_int()`, `nftban_cidr_size()`, `nftban_ip_in_cidr()`
- IP Lookup: `nftban_find_ip_locations()`, `nftban_geoip_lookup()`, `nftban_whois_lookup()`, `nftban_get_ip_info()`
- Utilities: `nftban_check_root()`, `nftban_check_nftables_table()`, `nftban_get_public_ip()`, `nftban_get_current_user_ip()`
- Security: `nftban_secure_permissions()`, `nftban_mktemp()`, `nftban_mktemp_dir()`, `nftban_secure_atomic_write()`, `nftban_secure_curl()`
- Locking: `nftban_with_lock()`, `nftban_is_locked()`, `nftban_get_lock_holder()`
- Sanitization: `nftban_sanitize_jail_name()`, `nftban_sanitize_identifier()`, `nftban_sanitize_path_component()`, `nftban_sanitize_port()`, `nftban_validate_email()`, `nftban_sanitize_shell_arg()`
- Email: `nftban_send_email()`, `nftban_send_ban_notification()`, `nftban_send_rate_limit_alert()`

**Internal Functions:**
- `_nftban_get_caller_module()` - Extracts calling module name from call stack
- `nftban_init_directories()` - Creates required directory structure
- `nftban_core_init()` - Module initialization
- `nftban_load_modules()` - Auto-loads all modules in dependency order

### Data Flow

```
Application/CLI
       ↓
[Core Initialization]
       ↓
[Load Config] → [Init Directories] → [Load Modules]
       ↓
[Provide Services]
  • Logging
  • Validation
  • Configuration
  • Utilities
       ↓
[All Other Modules]
```

### State Management

**Global Constants:**
- Path constants: `NFTBAN_BASE_DIR`, `NFTBAN_CONFIG_DIR`, `NFTBAN_LOG_DIR`, etc.
- nftables constants: `NFTBAN_NFT_TABLE_V4`, `NFTBAN_NFT_TABLE_V6`
- Color codes for terminal output
- Dangerous CIDR list for security validation

**State Files:**
- Configuration: `/etc/nftban/config/nftban.conf` (main), `/etc/nftban/config/nftban.conf.local` (overrides)
- Logs: `/var/log/nftban/nftban.log` (main), `/var/log/nftban/ban-history.log`, `/var/log/nftban/errors.log`
- Lock files: `/var/lock/nftban/*.lock` (single-instance enforcement)
- Temp files: Managed via `mktemp` with automatic cleanup

**Module Loading Guard:**
- `NFTBAN_CORE_LOADED` prevents double-loading

---

## API Reference

### Public Functions

#### nftban_log()

**Purpose:** Base logging function with unified format

**Syntax:**
```bash
nftban_log "LEVEL" "message"
```

**Parameters:**
- `LEVEL` (required): ERROR, WARNING, INFO, SUCCESS, DEBUG
- `message` (required): Log message

**Returns:**
- Echoes formatted log entry

**Example:**
```bash
nftban_log "INFO" "System initialized"
```

**Notes:**
- Unified format: `[YYYY-MM-DD HH:MM:SS] [PID] [MODULE] [LEVEL] message`
- Automatically detects calling module
- Atomic writes to prevent log corruption
- All convenience functions use this internally

---

#### nftban_log_error()

**Purpose:** Log error messages to stderr

**Syntax:**
```bash
nftban_log_error "message"
```

**Parameters:**
- `message` (required): Error message

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_error "Failed to load configuration"
```

**Notes:**
- Outputs to stderr in red color
- Writes to main log file
- Use for operational failures

---

#### nftban_log_success()

**Purpose:** Log success messages

**Syntax:**
```bash
nftban_log_success "message"
```

**Parameters:**
- `message` (required): Success message

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_success "IP 192.168.1.1 added to whitelist"
```

**Notes:**
- Green colored output
- Use to confirm successful operations

---

#### nftban_log_warning()

**Purpose:** Log warning messages

**Syntax:**
```bash
nftban_log_warning "message"
```

**Parameters:**
- `message` (required): Warning message

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_warning "Configuration file permissions insecure"
```

**Notes:**
- Yellow colored output
- Use for non-critical issues

---

#### nftban_log_info()

**Purpose:** Log informational messages

**Syntax:**
```bash
nftban_log_info "message"
```

**Parameters:**
- `message` (required): Info message

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_info "Starting nftables sync"
```

**Notes:**
- Blue colored output
- Use for status updates

---

#### nftban_log_debug()

**Purpose:** Log debug messages (only if DEBUG_ENABLED=true)

**Syntax:**
```bash
nftban_log_debug "message"
```

**Parameters:**
- `message` (required): Debug message

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_debug "Processing IP: 192.168.1.1"
```

**Notes:**
- Cyan colored output
- Only logs if `DEBUG_ENABLED=true` in configuration
- Use for detailed troubleshooting

---

#### nftban_log_ban()

**Purpose:** Log ban events with structured format

**Syntax:**
```bash
nftban_log_ban "ip" "jail" "action" "reason"
```

**Parameters:**
- `ip` (required): IP address being banned/unbanned
- `jail` (required): Fail2Ban jail name or source
- `action` (required): BAN, UNBAN, BLACKLIST, etc.
- `reason` (required): Reason for action

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_ban "203.0.113.45" "sshd" "BAN" "5 failed login attempts"
```

**Notes:**
- Writes to specialized ban log: `/var/log/nftban/ban-history.log`
- Pipe-delimited format for easy parsing: `timestamp|pid|module|ip|jail|action|reason`
- Also writes to main log with unified format
- Essential for audit trail

---

#### nftban_log_whitelist_protection()

**Purpose:** Log attempts to ban/blacklist whitelisted IPs

**Syntax:**
```bash
nftban_log_whitelist_protection "ip" "operation" "source" ["details"]
```

**Parameters:**
- `ip` (required): Protected IP address
- `operation` (required): BAN, BLACKLIST, REMOVE, etc.
- `source` (required): fail2ban jail name, CLI, module name
- `details` (optional): Additional context

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
nftban_log_whitelist_protection "192.168.1.1" "BAN" "sshd" "Blocked by whitelist protection"
```

**Notes:**
- Creates audit trail of protection events
- Logs to specialized file: `/var/log/nftban/whitelist-protection.log`
- Automatically calls `nftban_log_ban()` for consistency
- Critical for security compliance

---

#### nftban_get_config()

**Purpose:** Retrieve configuration value with fallback to default

**Syntax:**
```bash
value=$(nftban_get_config "KEY" "default")
```

**Parameters:**
- `KEY` (required): Configuration key name
- `default` (optional): Default value if key not found

**Returns:**
- Echoes configuration value or default

**Example:**
```bash
email_enabled=$(nftban_get_config "NFTBAN_EMAIL_ENABLED" "false")
if [[ "$email_enabled" == "true" ]]; then
    echo "Email notifications enabled"
fi
```

**Notes:**
- Checks `.local` file first (highest priority)
- Falls back to main config if not found
- Normalizes booleans: TRUE/True → true, FALSE/False → false
- Returns empty string if key not found and no default provided

---

#### nftban_set_config()

**Purpose:** Set configuration value in config file

**Syntax:**
```bash
nftban_set_config "KEY" "value" [file]
```

**Parameters:**
- `KEY` (required): Configuration key name
- `value` (required): Value to set
- `file` (optional): Target file (default: nftban.conf.local)

**Returns:**
- `0`: Success
- `1`: Failed to write

**Example:**
```bash
nftban_set_config "NFTBAN_EMAIL_ENABLED" "true"
nftban_set_config "CUSTOM_SETTING" "value" "$NFTBAN_MAIN_CONFIG"
```

**Notes:**
- Updates existing key or adds new one
- Creates file if doesn't exist
- Automatically redacts sensitive values in logs (passwords, tokens, keys)
- Uses double quotes around values

---

#### nftban_validate_ip()

**Purpose:** Validate IP address (IPv4 or IPv6)

**Syntax:**
```bash
if nftban_validate_ip "192.168.1.1"; then
    echo "Valid IP"
fi
```

**Parameters:**
- `ip` (required): IP address to validate

**Returns:**
- `0`: Valid IP
- `1`: Invalid IP

**Example:**
```bash
if nftban_validate_ip "$user_input"; then
    nftban_log_success "IP valid: $user_input"
else
    nftban_log_error "Invalid IP: $user_input"
    exit 1
fi
```

**Notes:**
- Detects IPv4 or IPv6 automatically
- Validates octet ranges for IPv4 (0-255)
- Validates IPv6 format
- Logs error if validation fails

---

#### nftban_validate_cidr()

**Purpose:** Validate CIDR notation with security checks

**Syntax:**
```bash
if nftban_validate_cidr "192.168.1.0/24" ["allow_dangerous"]; then
    echo "Valid CIDR"
fi
```

**Parameters:**
- `cidr` (required): CIDR notation (IP/prefix)
- `allow_dangerous` (optional): Set to "true" to allow dangerous CIDRs (default: false)

**Returns:**
- `0`: Valid CIDR
- `1`: Invalid CIDR or security check failed

**Example:**
```bash
# Standard validation (blocks dangerous ranges)
if nftban_validate_cidr "192.168.1.0/24"; then
    echo "Safe CIDR"
fi

# Allow dangerous CIDRs (use with caution)
if nftban_validate_cidr "0.0.0.0/0" "true"; then
    echo "Dangerous but allowed"
fi
```

**Notes:**
- **Security hardened** - blocks dangerous CIDRs by default:
  - `0.0.0.0/0`, `::/0` (entire internet)
  - `127.0.0.0/8` (loopback)
  - `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (private ranges)
- Validates prefix length (IPv4: 0-32, IPv6: 0-128)
- Blocks overly broad prefixes (IPv4 < /8, IPv6 < /32) unless `allow_dangerous=true`
- Warns if host address used instead of network address

---

#### nftban_ip_in_cidr()

**Purpose:** Check if IP is within CIDR range

**Syntax:**
```bash
if nftban_ip_in_cidr "192.168.1.50" "192.168.1.0/24"; then
    echo "IP is in range"
fi
```

**Parameters:**
- `ip` (required): IP address to check
- `cidr` (required): CIDR range

**Returns:**
- `0`: IP is in range
- `1`: IP not in range or invalid input

**Example:**
```bash
if nftban_ip_in_cidr "$user_ip" "10.0.0.0/8"; then
    nftban_log_info "IP is in private range"
fi
```

**Notes:**
- Currently supports IPv4 only
- Uses proper netmask calculation
- Validates CIDR before checking

---

#### nftban_find_ip_locations()

**Purpose:** Comprehensive search for IP across all NFTBan locations

**Syntax:**
```bash
locations=$(nftban_find_ip_locations "192.168.1.1")
```

**Parameters:**
- `ip` (required): IP address to find

**Returns:**
- `0`: IP found (outputs locations)
- `1`: IP not found

**Example:**
```bash
if locations=$(nftban_find_ip_locations "192.168.1.1"); then
    echo "IP found in:"
    echo "$locations"
else
    echo "IP not found anywhere"
fi
```

**Output Format:**
```
nftables:whitelist_v4
file:whitelist-system
server:interface
```

**Notes:**
- Searches: nftables sets, whitelist files, blacklist files, server interfaces, current user IP
- Checks both IPv4 and IPv6 tables (split table architecture)
- Returns all locations (one per line)
- Essential for debugging "where is this IP?" questions

---

#### nftban_secure_permissions()

**Purpose:** Enforce secure file permissions on NFTBan files

**Syntax:**
```bash
nftban_secure_permissions ["target"]
```

**Parameters:**
- `target` (optional): all, config, scripts, data, logs, bin (default: all)

**Returns:**
- `0`: Always succeeds

**Example:**
```bash
# Secure all files
nftban_secure_permissions

# Secure only config files
nftban_secure_permissions "config"
```

**Notes:**
- **Must run as root**
- Permission policy:
  - Config files: 640 (rw-r-----)
  - Config .local files: 600 (rw-------)
  - Scripts: 750 (rwxr-x---)
  - Data files: 600 (rw-------)
  - Log files: 640 (rw-r-----)
  - Executables: 755 (rwxr-xr-x)
- Prevents privilege escalation attacks
- Sets ownership to `root:root`
- Reports fixed/error counts

---

#### nftban_mktemp()

**Purpose:** Create secure temporary file with automatic cleanup

**Syntax:**
```bash
tmpfile=$(nftban_mktemp) || exit 1
trap 'rm -f "$tmpfile"' RETURN
```

**Parameters:**
- None

**Returns:**
- `0`: Success (outputs temp file path)
- `1`: Failed to create temp file

**Example:**
```bash
tmpfile=$(nftban_mktemp) || {
    nftban_log_error "Failed to create temp file"
    exit 1
}
trap 'rm -f "$tmpfile"' RETURN

echo "data" > "$tmpfile"
# Use tmpfile...
# Automatically cleaned up on function return
```

**Notes:**
- Uses `mktemp` for secure temp file creation
- Returns unpredictable filename
- **Always use with trap for cleanup**
- Prevents temp file attacks (CWE-377)

---

#### nftban_secure_atomic_write()

**Purpose:** Securely write file with atomic operation

**Syntax:**
```bash
nftban_secure_atomic_write "/path/to/file" "content"
```

**Parameters:**
- `target_file` (required): Destination file path
- `content` (required): Content to write

**Returns:**
- `0`: Success
- `1`: Failed to write

**Example:**
```bash
content="192.168.1.1 # Whitelisted server"
if nftban_secure_atomic_write "/etc/nftban/config/whitelist.conf" "$content"; then
    nftban_log_success "File written successfully"
fi
```

**Notes:**
- **Prevents TOCTOU attacks** (Time-Of-Check-Time-Of-Use)
- Uses `mktemp` + `flock` + atomic `mv`
- Creates parent directories if needed
- Syncs to disk before moving
- Race-condition safe

---

#### nftban_secure_curl()

**Purpose:** Hardened curl wrapper for safe external downloads

**Syntax:**
```bash
nftban_secure_curl "url" "output_file" [timeout]
```

**Parameters:**
- `url` (required): HTTPS URL to download
- `output_file` (required): Destination file path
- `timeout` (optional): Timeout in seconds (default: 30)

**Returns:**
- `0`: Success
- `1`: Failed (invalid URL, network error, etc.)

**Example:**
```bash
if nftban_secure_curl "https://example.com/feed.txt" "/tmp/feed.txt" 60; then
    nftban_log_success "Downloaded feed"
else
    nftban_log_error "Download failed"
fi
```

**Notes:**
- **HTTPS only** - rejects HTTP, file://, ftp://
- **Blocks private IPs** - prevents SSRF attacks
- Hardened flags:
  - `--proto =https` - HTTPS only
  - `--tlsv1.2` - Minimum TLS 1.2
  - `--max-redirs 3` - Limit redirect chains
  - `--retry 2` - Automatic retries
- Cleans up on failure
- User-Agent: `nftban/1.0 (security-tool)`

---

#### nftban_with_lock()

**Purpose:** Execute command with exclusive lock (prevents concurrent execution)

**Syntax:**
```bash
nftban_with_lock "lock_name" command args...
```

**Parameters:**
- `lock_name` (required): Lock identifier (alphanumeric only)
- `command` (required): Command to execute
- `args...` (optional): Command arguments

**Returns:**
- Command exit code, or `1` if lock acquisition fails

**Example:**
```bash
# Prevent concurrent sync operations
if nftban_with_lock "sync" nftban_sync_all; then
    nftban_log_success "Sync completed"
else
    nftban_log_error "Sync failed or already running"
fi
```

**Notes:**
- Lock files: `/var/lock/nftban/{lock_name}.lock`
- **Non-blocking** - fails immediately if lock held
- Writes PID to lock file
- Automatically released when command completes
- Essential for preventing race conditions

---

#### nftban_sanitize_jail_name()

**Purpose:** Sanitize jail name to prevent path traversal attacks

**Syntax:**
```bash
safe_name=$(nftban_sanitize_jail_name "jail-name")
```

**Parameters:**
- `jail_name` (required): Jail name to sanitize

**Returns:**
- `0`: Success (outputs sanitized name)
- `1`: Invalid jail name

**Example:**
```bash
user_input="../../../etc/passwd"
if safe_name=$(nftban_sanitize_jail_name "$user_input"); then
    echo "Safe: $safe_name"
else
    nftban_log_error "Invalid jail name"
fi
```

**Notes:**
- Allows only: alphanumeric, underscore, hyphen
- Prevents path traversal: `../`, `./`, etc.
- Warns if sanitization modified input
- Essential security function - always use for user input

---

#### nftban_sanitize_port()

**Purpose:** Validate and sanitize port number

**Syntax:**
```bash
safe_port=$(nftban_sanitize_port "8080")
```

**Parameters:**
- `port` (required): Port number to validate

**Returns:**
- `0`: Success (outputs validated port)
- `1`: Invalid port

**Example:**
```bash
if safe_port=$(nftban_sanitize_port "$user_input"); then
    echo "Valid port: $safe_port"
else
    nftban_log_error "Invalid port number"
fi
```

**Notes:**
- Validates range: 1-65535
- Removes non-digit characters
- Warns if sanitization changed input

---

#### nftban_check_root()

**Purpose:** Verify script is running as root

**Syntax:**
```bash
nftban_check_root || exit 1
```

**Parameters:**
- None

**Returns:**
- `0`: Running as root
- `1`: Not running as root

**Example:**
```bash
if ! nftban_check_root; then
    echo "This operation requires root privileges"
    exit 1
fi
```

**Notes:**
- Checks `$EUID -eq 0`
- Logs error if not root
- Use for operations requiring root privileges

---

#### nftban_check_nftables_table()

**Purpose:** Check if NFTBan nftables tables exist

**Syntax:**
```bash
if nftban_check_nftables_table; then
    echo "Tables exist"
fi
```

**Parameters:**
- None

**Returns:**
- `0`: At least one table exists (IPv4 or IPv6)
- `1`: No tables found

**Example:**
```bash
if ! nftban_check_nftables_table; then
    nftban_log_error "NFTBan tables not initialized"
    echo "Run: nftban init"
    exit 1
fi
```

**Notes:**
- Checks both `nftban_v4` and `nftban_v6` tables
- v0.9.0+ split table architecture
- Essential prerequisite check

---

## Integration

### CLI Commands

The core module doesn't expose direct CLI commands. It's automatically loaded and provides services to all other modules and CLI commands.

### Module Integration

**Loading the Module:**
```bash
source /etc/nftban/lib/nftban_core.sh
```

**Using in Scripts:**
```bash
#!/usr/bin/env bash

# Source core module
source /etc/nftban/lib/nftban_core.sh

# Use logging
nftban_log_info "Script started"

# Validate IP
if ! nftban_validate_ip "$1"; then
    nftban_log_error "Invalid IP address: $1"
    exit 1
fi

# Get configuration
debug_mode=$(nftban_get_config "DEBUG_ENABLED" "false")

# Secure operation with lock
nftban_with_lock "my_operation" my_function "$@"
```

### nftables Integration

The core module doesn't directly manipulate nftables, but provides:
- Table existence checks: `nftban_check_nftables_table()`
- Table name constants: `NFTBAN_NFT_TABLE_V4`, `NFTBAN_NFT_TABLE_V6`
- Family constants: `NFTBAN_NFT_FAMILY_V4` (ip), `NFTBAN_NFT_FAMILY_V6` (ip6)

---

## Configuration

### Configuration File

**Location:** `/etc/nftban/config/nftban.conf` (main), `/etc/nftban/config/nftban.conf.local` (overrides)

**Format:**
```bash
# Bash variable format
KEY="value"
```

**Available Settings:**

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `DEBUG_ENABLED` | boolean | `false` | Enable debug logging |
| `NFTBAN_EMAIL_ENABLED` | boolean | `false` | Enable email notifications |
| `NFTBAN_EMAIL_RECIPIENT` | string | - | Email recipient for alerts |
| `NFTBAN_EMAIL_SENDER` | string | `nftban@$(hostname)` | Email sender address |
| `NFTBAN_GEOIP_ENABLE` | boolean | `false` | Enable GeoIP lookups |
| `NFTBAN_WHOIS_ENABLE` | boolean | `false` | Enable WHOIS lookups |

**Example Configuration:**
```bash
# /etc/nftban/config/nftban.conf.local
DEBUG_ENABLED="false"
NFTBAN_EMAIL_ENABLED="true"
NFTBAN_EMAIL_RECIPIENT="admin@example.com"
NFTBAN_GEOIP_ENABLE="true"
```

---

## Security Considerations

### Security Rating

**Current (v0.9.2):** 6/10
**Target (v0.9.3):** 9/10
**Improvement:** +3 points

**Rating Breakdown:**
- **Input Validation:** 9/10 - Comprehensive validation and sanitization
- **Permission Security:** 8/10 - Enforced file permissions, some manual intervention needed
- **Attack Surface:** LOW - Core functions are internal, minimal external exposure
- **Known Vulnerabilities:** 0 HIGH, 0 MEDIUM

### Production-Hardened Security (v0.9.3+)

**This module implements v0.9.3 production-hardened patterns:**
- ✅ `set -euo pipefail` - Strict error handling
- ✅ Double-loading prevention (`NFTBAN_CORE_LOADED`)
- ✅ Atomic file operations (`nftban_secure_atomic_write`)
- ✅ Secure temp files (`mktemp` + cleanup traps)
- ✅ HTTPS-only downloads (`nftban_secure_curl`)
- ✅ Single-instance locks (`nftban_with_lock`)
- ✅ Input sanitization (comprehensive functions)
- ✅ Sensitive data redaction (passwords, tokens in logs)

### Vulnerabilities Addressed

**v0.9.3 Security Improvements:**
- **CWE-362:** Race Condition → MITIGATED (atomic operations, flock)
- **CWE-377:** Insecure Temp File → MITIGATED (mktemp + secure permissions)
- **CWE-426:** Untrusted Search Path → MITIGATED (absolute paths)
- **CWE-459:** Incomplete Cleanup → MITIGATED (trap handlers)
- **CWE-73:** External Control of File Name → MITIGATED (path sanitization)
- **CWE-918:** Server-Side Request Forgery → MITIGATED (HTTPS-only, private IP blocking)
- **CWE-89:** SQL Injection → N/A (no database)
- **CWE-78:** OS Command Injection → MITIGATED (input sanitization, proper quoting)

**Module-Specific Fixes:**
- **Whitelist bypass prevention:** Enhanced CIDR validation blocks dangerous ranges
- **Information disclosure:** Sensitive config values redacted in logs
- **Path traversal:** Jail name and path component sanitization

### Security Features

**Input Validation:**
- IP addresses: Regex + octet range validation (IPv4), format validation (IPv6)
- CIDR: Network/prefix validation + dangerous range blocking
- Ports: Numeric validation (1-65535)
- Jail names: Alphanumeric + underscore + hyphen only
- Identifiers: Lowercase alphanumeric + underscore, must start with letter
- Emails: RFC 5322 basic compliance check
- Shell arguments: Removes metacharacters (`;`, `|`, `&`, `$`, `` ` ``, etc.)

**Permission Checks:**
- Root required: File permission operations
- File permissions enforced:
  - Config: 640 (rw-r-----)
  - Config .local: 600 (rw-------)
  - Scripts: 750 (rwxr-x---)
  - Data: 600 (rw-------)
  - Logs: 640 (rw-r-----)
- All files owned by `root:root`

**Sanitization:**
- Command injection: All inputs validated before use
- Quote all expansions: `"${var}"` pattern throughout
- Arrays for commands: `cmd=(...) ; "${cmd[@]}"` pattern
- Path traversal: Blocked via sanitization functions

**Logging Security:**
- Sensitive data redaction: Passwords, tokens, keys never logged
- Structured format: Consistent, parseable
- Atomic writes: Prevents log corruption
- Separate error log: `/var/log/nftban/errors.log` with 600 permissions

### Attack Surface

**Input Sources:**
- CLI arguments (validated via sanitization functions)
- Configuration files (permission-checked, sourced safely)
- External data (HTTPS-only, private IP blocked)
- nftables output (parsed safely with proper quoting)

**Potential Risks:**
- **Risk 1:** Malicious configuration values
  - **Likelihood:** LOW (requires root access to modify configs)
  - **Impact:** HIGH (could alter system behavior)
  - **Mitigation:** Config files are 640, root-owned; sensitive values redacted in logs

- **Risk 2:** SSRF via external lookups (GeoIP, WHOIS, public IP)
  - **Likelihood:** LOW (HTTPS-only, private IPs blocked)
  - **Impact:** MEDIUM (information disclosure)
  - **Mitigation:** `nftban_secure_curl` blocks HTTP, local IPs; optional features disabled by default

- **Risk 3:** Log injection
  - **Likelihood:** LOW (structured format, no eval of log data)
  - **Impact:** LOW (log parsing confusion)
  - **Mitigation:** Structured logging format; atomic writes; no execution of log content

- **Risk 4:** Temp file race conditions
  - **Likelihood:** LOW (mktemp used, atomic operations)
  - **Impact:** MEDIUM (privilege escalation if exploited)
  - **Mitigation:** `mktemp` with unpredictable names; `flock` for atomic writes; trap handlers for cleanup

### File Security

**Configuration Files:**
- Location: `/etc/nftban/config/nftban.conf`, `/etc/nftban/config/nftban.conf.local`
- Permissions: `640` (main), `600` (.local)
- Owner: `root:root`

**Sensitive Files:**
- None in core module (config files may contain sensitive data)
- Permissions: `600` for `.local` files
- Never world-readable

**Log Files:**
- Location: `/var/log/nftban/nftban.log`, `/var/log/nftban/ban-history.log`, `/var/log/nftban/errors.log`
- Permissions: `640` (main logs), `600` (errors.log)
- Owner: `root:root`
- Sensitive data redacted before logging

**Lock Files:**
- Location: `/var/lock/nftban/*.lock`
- Permissions: Created by flock (system manages)
- Contains: PID of lock holder
- Automatically cleaned up on process exit

### Compliance

**Security Standards:**
- **CIS Benchmarks:** Aligned with Linux security best practices
- **OWASP:** Mitigates injection, SSRF, race conditions, insecure temp files
- **Production-grade:** ✅ Yes (v0.9.3+)

**Audit Trail:**
- All operations logged with timestamp, PID, module
- Ban events logged to dedicated file
- Whitelist protection events logged separately
- Structured format for easy parsing and analysis

---

## Troubleshooting

### Common Issues

#### Issue: "This operation must be run as root"

**Symptoms:**
- Error message when running NFTBan commands
- Operations fail with permission denied

**Cause:** Many NFTBan operations require root privileges (nftables manipulation, file permission changes)

**Solution:**
```bash
# Run with sudo
sudo nftban <command>

# Or switch to root
su -
nftban <command>
```

---

#### Issue: Debug logs not appearing

**Symptoms:**
- `nftban_log_debug()` calls produce no output
- Troubleshooting difficult

**Cause:** Debug logging disabled by default

**Solution:**
```bash
# Enable debug logging
nftban config set DEBUG_ENABLED true

# Or edit config directly
echo 'DEBUG_ENABLED="true"' >> /etc/nftban/config/nftban.conf.local

# Or set environment variable temporarily
export DEBUG_ENABLED=true
nftban <command>
```

---

#### Issue: "Failed to create secure temp file"

**Symptoms:**
- Operations fail with temp file error
- `/tmp` full or permissions issue

**Cause:** `/tmp` directory full, permission issues, or no mktemp command

**Solution:**
```bash
# Check /tmp space
df -h /tmp

# Clean /tmp if full
sudo rm -rf /tmp/tmp.*

# Check mktemp availability
which mktemp

# Check /tmp permissions (should be 1777)
ls -ld /tmp
# Fix if needed
sudo chmod 1777 /tmp
```

---

#### Issue: Email notifications not working

**Symptoms:**
- No email alerts received
- Ban notifications missing

**Cause:** Email not enabled, no mail command, or recipient not configured

**Solution:**
```bash
# Enable email notifications
nftban config set NFTBAN_EMAIL_ENABLED true
nftban config set NFTBAN_EMAIL_RECIPIENT admin@example.com

# Check mail command available
which mail sendmail

# Install mail if needed (Debian/Ubuntu)
sudo apt install mailutils

# Install mail if needed (RHEL/CentOS)
sudo dnf install mailx

# Test email manually
echo "Test" | mail -s "Test NFTBan" admin@example.com
```

---

#### Issue: "NFTBan tables not initialized"

**Symptoms:**
- `nftban_check_nftables_table()` returns false
- Commands fail with table not found

**Cause:** NFTBan nftables tables haven't been created

**Solution:**
```bash
# Initialize nftables tables
sudo nftban init

# Verify tables exist
sudo nft list tables

# Should see: ip nftban_v4, ip6 nftban_v6
```

---

#### Issue: Configuration changes not taking effect

**Symptoms:**
- Changed settings in config file don't work
- Old values still being used

**Cause:** .local file overrides main config, or config not reloaded

**Solution:**
```bash
# Check which file has the setting
grep "SETTING_NAME" /etc/nftban/config/nftban.conf
grep "SETTING_NAME" /etc/nftban/config/nftban.conf.local

# .local file takes precedence - edit it instead
sudo vi /etc/nftban/config/nftban.conf.local

# Or use nftban config command (writes to .local)
nftban config set SETTING_NAME value

# Restart services if needed
sudo systemctl restart nftban-sync.timer
```

---

#### Issue: "Lock held by another process"

**Symptoms:**
- Operations fail with "already running" error
- Commands can't acquire lock

**Cause:** Another NFTBan operation is running, or stale lock file

**Solution:**
```bash
# Check who holds the lock
lock_holder=$(nftban_get_lock_holder "operation_name")
echo "Lock held by PID: $lock_holder"

# Check if process still running
ps -p "$lock_holder"

# If process dead, remove stale lock
sudo rm -f /var/lock/nftban/operation_name.lock

# Try operation again
nftban <command>
```

---

### Logs

**Relevant Log Files:**
- `/var/log/nftban/nftban.log` - Main log (all modules, all levels)
- `/var/log/nftban/errors.log` - Error log (600 permissions, sensitive data)
- `/var/log/nftban/ban-history.log` - Ban/unban events (structured format)
- `/var/log/nftban/whitelist-protection.log` - Whitelist protection events

**Viewing Logs:**
```bash
# View main log
tail -f /var/log/nftban/nftban.log

# View only errors
grep "ERROR" /var/log/nftban/nftban.log

# View only core module logs
grep "\[core\]" /var/log/nftban/nftban.log

# View last 100 lines
tail -n 100 /var/log/nftban/nftban.log

# View ban history
cat /var/log/nftban/ban-history.log

# Parse ban history (pipe-delimited)
awk -F'|' '{print $1, $4, $6}' /var/log/nftban/ban-history.log
```

### Debugging

**Enable Debug Mode:**
```bash
# Temporary (environment variable)
export DEBUG_ENABLED=true
nftban <command>

# Permanent (configuration)
nftban config set DEBUG_ENABLED true
```

**Validation Commands:**
```bash
# Check if core module loaded
declare -F nftban_log >/dev/null && echo "Core loaded"

# Check nftables tables
nftban_check_nftables_table && echo "Tables OK"

# Test IP validation
nftban_validate_ip "192.168.1.1" && echo "Valid IP"

# Test CIDR validation
nftban_validate_cidr "192.168.1.0/24" && echo "Valid CIDR"

# Check lock status
nftban_is_locked "sync" && echo "Locked" || echo "Not locked"

# Find IP locations
nftban_find_ip_locations "192.168.1.1"
```

**Trace Function Calls:**
```bash
# Enable bash tracing
set -x
nftban <command>
set +x

# Or run with bash -x
bash -x /usr/local/bin/nftban <command>
```

---

## Testing

### Unit Testing

The core module doesn't have formal unit tests. Testing is done through:
- Integration testing with other modules
- Smoke tests via `nftban smoketest`
- Manual testing during development

### Integration Testing

Test the core module by using its functions in a script:

```bash
#!/usr/bin/env bash
source /etc/nftban/lib/nftban_core.sh

echo "Testing core module functions..."

# Test logging
nftban_log_info "Test info message"
nftban_log_success "Test success message"
nftban_log_warning "Test warning message"
nftban_log_error "Test error message"

# Test IP validation
test_ips=("192.168.1.1" "256.1.1.1" "2001:db8::1" "invalid")
for ip in "${test_ips[@]}"; do
    if nftban_validate_ip "$ip"; then
        echo "✓ Valid IP: $ip"
    else
        echo "✗ Invalid IP: $ip"
    fi
done

# Test CIDR validation
test_cidrs=("192.168.1.0/24" "10.0.0.0/8" "0.0.0.0/0" "invalid")
for cidr in "${test_cidrs[@]}"; do
    if nftban_validate_cidr "$cidr"; then
        echo "✓ Valid CIDR: $cidr"
    else
        echo "✗ Invalid CIDR: $cidr"
    fi
done

# Test sanitization
test_inputs=("valid_name" "../../../etc/passwd" "name;rm -rf" "port:8080")
for input in "${test_inputs[@]}"; do
    if safe=$(nftban_sanitize_jail_name "$input"); then
        echo "✓ Sanitized: $input → $safe"
    else
        echo "✗ Failed to sanitize: $input"
    fi
done

echo "Core module test complete"
```

### Test Cases

1. **Test Case 1: IP Validation**
   - Input: `192.168.1.1`, `256.1.1.1`, `2001:db8::1`, `invalid`
   - Expected: First and third valid, second and fourth invalid
   - Validation: `nftban_validate_ip` returns correct codes

2. **Test Case 2: CIDR Security Checks**
   - Input: `0.0.0.0/0`, `192.168.1.0/24`
   - Expected: First blocked (dangerous), second allowed
   - Validation: `nftban_validate_cidr` enforces security policy

3. **Test Case 3: Atomic File Write**
   - Input: Write to file concurrently from multiple processes
   - Expected: No corruption, last write wins
   - Validation: File content is valid, no partial writes

4. **Test Case 4: Lock Mechanism**
   - Input: Try to acquire same lock twice
   - Expected: Second attempt fails
   - Validation: `nftban_with_lock` returns error on second call

5. **Test Case 5: Sanitization**
   - Input: `../../../etc/passwd`
   - Expected: Sanitized to `etcpasswd`
   - Validation: `nftban_sanitize_jail_name` removes path characters

---

## Performance

### Resource Usage

- **Memory:** Minimal (~1-2 MB for loaded functions)
- **CPU:** Negligible (utility functions only)
- **Disk I/O:** Moderate (logging, config reads)
- **Network:** Optional (GeoIP, WHOIS, public IP lookups)

**Performance Characteristics:**
- Logging: O(1) - constant time, atomic append
- IP validation: O(1) - regex matching
- CIDR validation: O(1) - arithmetic operations
- IP in CIDR: O(1) - bitwise operations
- Find IP locations: O(n) - n = number of locations to check

### Optimization

**Tips for optimal performance:**

1. **Disable debug logging in production:**
   ```bash
   nftban config set DEBUG_ENABLED false
   ```

2. **Disable optional features if not needed:**
   ```bash
   nftban config set NFTBAN_GEOIP_ENABLE false
   nftban config set NFTBAN_WHOIS_ENABLE false
   ```

3. **Use locks judiciously:**
   - Only lock operations that truly need mutual exclusion
   - Keep locked sections as short as possible
   - Locks are non-blocking (fail fast)

4. **Batch log reads:**
   - Use `tail -n` instead of reading entire log files
   - Use `grep` to filter specific log levels or modules

5. **Cache configuration values:**
   ```bash
   # Instead of calling nftban_get_config repeatedly
   email_enabled=$(nftban_get_config "NFTBAN_EMAIL_ENABLED" "false")
   # Use cached value
   [[ "$email_enabled" == "true" ]] && send_email
   ```

---

## Maintenance

### Regular Tasks

- [ ] **Review logs** - Weekly (check for errors, warnings)
- [ ] **Rotate logs** - Automatically via logrotate (recommended)
- [ ] **Clean lock files** - Stale locks removed automatically, but check `/var/lock/nftban/` if issues
- [ ] **Audit configuration** - Monthly (verify settings match policy)
- [ ] **Update dangerous CIDR list** - As needed (if security policy changes)

### Backup Considerations

**Critical files to backup:**
- `/etc/nftban/config/nftban.conf` - Main configuration
- `/etc/nftban/config/nftban.conf.local` - Local overrides
- `/var/log/nftban/ban-history.log` - Audit trail (if required for compliance)

**Backup command:**
```bash
# Backup configuration
tar -czf nftban-config-$(date +%Y%m%d).tar.gz /etc/nftban/config/

# Backup logs (if needed for audit)
tar -czf nftban-logs-$(date +%Y%m%d).tar.gz /var/log/nftban/

# Restore configuration
tar -xzf nftban-config-20251022.tar.gz -C /
sudo nftban_secure_permissions config
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.9.3-dev | 2025-10-22 | Security maturity release: production-hardened header, secure temp files, HTTPS-only curl, enhanced sanitization |
| 0.9.2 | 2025-10-20 | Emergency fixes: validation system, enhanced CIDR validation |
| 0.9.1 | 2025-10-15 | Initial modular release: unified logging contract |
| 0.9.0 | 2025-10-10 | Split table architecture (v4/v6 separate) |

---

## References

### Related Documentation

- [NFTBAN_NFTABLES_MODULE.md](NFTBAN_NFTABLES_MODULE.md) - nftables integration
- [NFTBAN_WHITELIST_MODULE.md](NFTBAN_WHITELIST_MODULE.md) - Uses core validation
- [NFTBAN_BLACKLIST_MODULE.md](NFTBAN_BLACKLIST_MODULE.md) - Uses core validation
- [SECURITY_HARDENING_v0.9.3.md](../Security/SECURITY_HARDENING_v0.9.3.md) - Security improvements

### External Resources

- [nftables Wiki](https://wiki.nftables.org/) - nftables documentation
- [Bash Best Practices](https://mywiki.wooledge.org/BashGuide/Practices) - Bash coding standards
- [CWE Database](https://cwe.mitre.org/) - Common Weakness Enumeration
- [OWASP Top 10](https://owasp.org/www-project-top-ten/) - Security risks

---

## Footer

**Document Status:** Final
**Review Date:** 2026-01-22
**Maintainer:** ITCMS Team

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
---

*Generated: 2025-10-22 18:30:00 UTC*
*NFTBan Version: 0.9.3-dev*
