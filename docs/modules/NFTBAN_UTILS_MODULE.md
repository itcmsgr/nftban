# NFTBan Module: Utilities Library

**Version:** 0.9.3-dev
**Status:** Production
**Category:** Core
**Author:** ITCMS Team (Antonios Voulvoulis)
**Contact:** contact@itcms.gr
**Website:** https://itcms.gr
**Last Updated:** 2025-10-22

**SPDX-License-Identifier:** LicenseRef-ITCMS-ProtectiveFreeUse-2.0

---

## Overview

**Purpose:** Provides common utility functions used across all NFTBan modules including system checks, file operations, string/array manipulation, validation, user interaction, and mail service detection.

**Key Features:**
- System and service checks (root detection, command availability)
- Safe file operations with atomic writes and automatic backups
- String and array manipulation utilities
- Input validation and sanitization (ports, emails, names)
- User interaction (prompts, confirmations, progress indicators)
- Network utilities with security-hardened curl
- Comprehensive mail service detection and conflict resolution
- Path traversal prevention (BUG49 fix)

**Dependencies:**
- `nftban_core.sh` (for logging functions)
- Standard Linux utilities: `mkdir`, `cp`, `mv`, `stat`, `curl`
- Optional: `mail`, `mailx`, `sendmail` (for email notifications)
- systemctl (for service management)

**When to Use:**
- Any module needing common utility functions
- File operations requiring atomic writes or backups
- Input validation and sanitization
- User prompts and confirmations
- Mail service configuration and status checks
- Network operations requiring secure curl

---

## Architecture

### Module Structure

**File:** `/etc/nftban/lib/nftban_utils_lib.sh`

**Exports:**
- System checks: `check_root()`, `command_exists()`, `check_required_commands()`
- Service checks: `is_service_running()`, `is_service_enabled()`
- File operations: `create_directory()`, `backup_file()`, `safe_write_file()`
- String utilities: `trim()`, `to_upper()`, `to_lower()`, `string_contains()`
- Array utilities: `array_contains()`, `array_join()`
- Validation: `validate_yes_no()`, `validate_port()`, `validate_email()`, `validate_safe_name()`, `validate_jail_name()`, `validate_template_name()`
- User interaction: `ask_yes_no()`, `confirm_action()`
- Progress indicators: `spinner()`, `progress_bar()`
- Cleanup: `register_cleanup()`, `cleanup()`
- Time utilities: `seconds_to_human()`, `get_file_age()`
- Network: `safe_curl()`, `is_port_open()`, `get_public_ip()`
- Mail services: `detect_mail_command()`, `detect_mta_service()`, `get_mail_installation_recommendation()`, `show_mail_service_panel()`, `check_mail_service()`

**Internal Functions:**
- All functions are public (no underscore prefix) as this is a utility library

### Data Flow

```
[Module Import] → [Function Call] → [Validation/Processing] → [Return Result]
                                         ↓
                             [Log to Core Module] (if needed)
```

This is a stateless utility library - no persistent state is maintained. Each function operates independently.

### State Management

**No persistent state** - This is a pure utility library. Functions are stateless and side-effect free (except for file operations which modify filesystem state).

**Color codes:** Determined at load time based on terminal capabilities (stored in readonly variables).

**Double-loading prevention:** Uses `NFTBAN_UTILS_LOADED` guard variable.

---

## API Reference

### System Checks

#### check_root()

**Purpose:** Verify the script is running as root

**Syntax:**
```bash
check_root
```

**Parameters:** None

**Returns:**
- Exits script with fatal error if not root (does not return)

**Example:**
```bash
#!/usr/bin/env bash
source /etc/nftban/lib/nftban_core.sh
source /etc/nftban/lib/nftban_utils_lib.sh

check_root  # Will exit if not root
echo "Running as root, continuing..."
```

**Notes:**
- Uses `$EUID` to check effective user ID
- Calls `log_fatal()` from core module if not root
- Should be called early in scripts requiring root privileges

---

#### command_exists()

**Purpose:** Check if a command is available in PATH

**Syntax:**
```bash
command_exists <command>
```

**Parameters:**
- `command` (required): Command name to check

**Returns:**
- `0`: Command exists
- `1`: Command not found

**Example:**
```bash
if command_exists "nft"; then
    echo "nftables is installed"
else
    echo "nftables is NOT installed"
fi
```

**Notes:**
- Uses `command -v` for POSIX compliance
- Redirects all output to `/dev/null`
- Fast check suitable for use in loops

---

#### check_required_commands()

**Purpose:** Verify multiple required commands are available

**Syntax:**
```bash
check_required_commands <command1> [command2] [...]
```

**Parameters:**
- `command1..N` (required): One or more command names

**Returns:**
- `0`: All commands found
- `1`: One or more commands missing

**Example:**
```bash
if ! check_required_commands nft iptables curl jq; then
    exit 1
fi
echo "All required commands are available"
```

**Notes:**
- Logs all missing commands at once
- Provides user-friendly error message
- Returns after logging (doesn't exit)

---

#### is_service_running()

**Purpose:** Check if a systemd service is active

**Syntax:**
```bash
is_service_running <service>
```

**Parameters:**
- `service` (required): Systemd service name

**Returns:**
- `0`: Service is active
- `1`: Service is inactive or doesn't exist

**Example:**
```bash
if is_service_running "postfix"; then
    echo "Postfix is running"
else
    echo "Postfix is not running"
fi
```

**Notes:**
- Uses `systemctl is-active --quiet`
- Silent operation (no output)
- Returns immediately

---

#### is_service_enabled()

**Purpose:** Check if a systemd service is enabled at boot

**Syntax:**
```bash
is_service_enabled <service>
```

**Parameters:**
- `service` (required): Systemd service name

**Returns:**
- `0`: Service is enabled
- `1`: Service is disabled or doesn't exist

**Example:**
```bash
if is_service_enabled "nftables"; then
    echo "nftables will start on boot"
fi
```

---

### File Operations

#### create_directory()

**Purpose:** Create directory with specified permissions

**Syntax:**
```bash
create_directory <path> [mode]
```

**Parameters:**
- `path` (required): Directory path to create
- `mode` (optional): Permission mode (default: 0755)

**Returns:**
- `0`: Directory created or already exists
- `1`: Failed to create directory

**Example:**
```bash
# Create with default permissions (755)
create_directory "/etc/nftban/backups"

# Create with restrictive permissions (700)
create_directory "/etc/nftban/secrets" "0700"
```

**Notes:**
- Uses `mkdir -p` for recursive creation
- Logs success/failure using core logging
- Skips if directory already exists (idempotent)

---

#### backup_file()

**Purpose:** Create timestamped backup of file

**Syntax:**
```bash
backup_file <file> [backup_dir]
```

**Parameters:**
- `file` (required): File path to backup
- `backup_dir` (optional): Backup destination (default: `dirname(file)/backups`)

**Returns:**
- `0`: Backup created successfully or file doesn't exist
- `1`: Backup failed

**Example:**
```bash
# Backup to default location
backup_file "/etc/nftban/config/nftban.conf"
# Creates: /etc/nftban/config/backups/nftban.conf.20251022_143052.bak

# Backup to custom location
backup_file "/etc/nftban/config/nftban.conf" "/var/backups/nftban"
```

**Notes:**
- Uses `cp -a` to preserve permissions and timestamps
- Timestamp format: `YYYYMMDD_HHMMSS`
- Logs success with full backup path
- Returns success if source file doesn't exist (no-op)

---

#### safe_write_file()

**Purpose:** Atomic file write with optional backup (v0.9.3 security feature)

**Syntax:**
```bash
safe_write_file <file> <content> [backup]
```

**Parameters:**
- `file` (required): Destination file path
- `content` (required): Content to write
- `backup` (optional): "true" (default) or "false"

**Returns:**
- `0`: File written successfully
- `1`: Write failed

**Example:**
```bash
# Write with automatic backup
safe_write_file "/etc/nftban/config/whitelist.conf" "192.168.1.0/24"

# Write without backup
safe_write_file "/tmp/test.txt" "temporary data" "false"
```

**Notes:**
- **Atomic operation:** Writes to temp file, then moves (prevents corruption)
- **Secure temp file:** Uses `$$` (PID) in temp filename
- **Automatic backup:** Calls `backup_file()` first if enabled
- Mitigates **CWE-362** (Race Condition) via atomic move
- Cleans up temp file on failure

**Security:**
- Temp file: `${file}.tmp.$$` (unique per process)
- Move operation is atomic on same filesystem
- Backup created before write (can rollback)

---

### String Utilities

#### trim()

**Purpose:** Remove leading and trailing whitespace

**Syntax:**
```bash
trim <string>
```

**Parameters:**
- `string` (required): String to trim

**Returns:**
- Trimmed string (stdout)

**Example:**
```bash
cleaned=$(trim "  hello world  ")
echo "[$cleaned]"  # Output: [hello world]
```

---

#### to_upper()

**Purpose:** Convert string to uppercase

**Syntax:**
```bash
to_upper <string>
```

**Example:**
```bash
upper=$(to_upper "hello")
echo "$upper"  # Output: HELLO
```

---

#### to_lower()

**Purpose:** Convert string to lowercase

**Syntax:**
```bash
to_lower <string>
```

**Example:**
```bash
lower=$(to_lower "HELLO")
echo "$lower"  # Output: hello
```

---

#### string_contains()

**Purpose:** Check if string contains substring

**Syntax:**
```bash
string_contains <string> <substring>
```

**Returns:**
- `0`: Substring found
- `1`: Substring not found

**Example:**
```bash
if string_contains "hello world" "world"; then
    echo "Found!"
fi
```

---

### Array Utilities

#### array_contains()

**Purpose:** Check if array contains element

**Syntax:**
```bash
array_contains <element> <array_element1> [array_element2] [...]
```

**Parameters:**
- `element` (required): Element to search for
- `array_elements` (required): Array elements

**Returns:**
- `0`: Element found
- `1`: Element not found

**Example:**
```bash
allowed_actions=("ban" "unban" "list" "search")
if array_contains "ban" "${allowed_actions[@]}"; then
    echo "Action is allowed"
fi
```

**Notes:**
- Performs exact string matching
- Safe with spaces in elements

---

#### array_join()

**Purpose:** Join array elements with delimiter

**Syntax:**
```bash
array_join <delimiter> <element1> [element2] [...]
```

**Parameters:**
- `delimiter` (required): Separator string
- `elements` (required): Array elements to join

**Returns:**
- Joined string (stdout)

**Example:**
```bash
ips=("192.168.1.1" "192.168.1.2" "192.168.1.3")
csv=$(array_join ", " "${ips[@]}")
echo "$csv"  # Output: 192.168.1.1, 192.168.1.2, 192.168.1.3
```

---

### Validation Functions

#### validate_port()

**Purpose:** Validate TCP/UDP port number

**Syntax:**
```bash
validate_port <port>
```

**Parameters:**
- `port` (required): Port number to validate

**Returns:**
- `0`: Valid port (1-65535)
- `1`: Invalid port

**Example:**
```bash
if validate_port "8080"; then
    echo "Valid port"
else
    echo "Invalid port"
fi

# Test cases:
validate_port "80"     # Returns 0 (valid)
validate_port "65535"  # Returns 0 (valid)
validate_port "0"      # Returns 1 (invalid)
validate_port "99999"  # Returns 1 (invalid)
validate_port "abc"    # Returns 1 (invalid)
```

**Notes:**
- Checks numeric format with regex `^[0-9]+$`
- Validates range 1-65535
- Used by port management modules

---

#### validate_email()

**Purpose:** Basic email address validation

**Syntax:**
```bash
validate_email <email>
```

**Parameters:**
- `email` (required): Email address to validate

**Returns:**
- `0`: Valid email format
- `1`: Invalid email format

**Example:**
```bash
if validate_email "admin@example.com"; then
    echo "Valid email"
fi

# Test cases:
validate_email "user@domain.com"     # Returns 0
validate_email "user.name@sub.domain.com"  # Returns 0
validate_email "invalid@"            # Returns 1
validate_email "@example.com"        # Returns 1
validate_email "no-at-sign.com"      # Returns 1
```

**Notes:**
- Basic regex validation (not RFC 5322 compliant)
- Checks format: `username@domain.tld`
- Does NOT verify deliverability

---

#### validate_safe_name()

**Purpose:** Validate names to prevent path traversal (BUG49 fix)

**Syntax:**
```bash
validate_safe_name <name> [max_length]
```

**Parameters:**
- `name` (required): Name to validate
- `max_length` (optional): Maximum length (default: 64)

**Returns:**
- `0`: Safe name
- `1`: Unsafe name (path traversal attempt or invalid chars)

**Example:**
```bash
# Valid names
validate_safe_name "my-jail"       # Returns 0
validate_safe_name "jail_name_123" # Returns 0

# Invalid names (security issues)
validate_safe_name "../etc/passwd" # Returns 1 (path traversal)
validate_safe_name "jail/name"     # Returns 1 (slash not allowed)
validate_safe_name "jail name"     # Returns 1 (space not allowed)
validate_safe_name "jail.conf"     # Returns 1 (dot in middle not allowed)
```

**Notes:**
- **Security:** Prevents **CWE-73** (External Control of File Name/Path)
- **Allowed characters:** `A-Za-z0-9_-` (alphanumeric, underscore, hyphen)
- **Blocked patterns:** `./`, `../`, `~`, `\`, any path separators
- Used by `validate_jail_name()` and `validate_template_name()`
- This is a **critical security function** added in v0.9.2 (BUG49 fix)

**Security Context:**
```bash
# Without this validation, an attacker could:
jail_name="../../../etc/shadow"
jail_file="/etc/nftban/jails/${jail_name}.conf"
# Would write to: /etc/shadow (CRITICAL vulnerability!)

# With validation:
if ! validate_safe_name "$jail_name"; then
    # Blocked! Returns 1
fi
```

---

#### validate_jail_name()

**Purpose:** Validate and sanitize Fail2Ban jail name

**Syntax:**
```bash
jail_name=$(validate_jail_name <name>)
```

**Parameters:**
- `name` (required): Jail name to validate

**Returns:**
- `0`: Valid jail name (prints sanitized name to stdout)
- `1`: Invalid jail name (logs error)

**Example:**
```bash
# Valid usage
if jail_name=$(validate_jail_name "sshd"); then
    echo "Using jail: $jail_name"
else
    echo "Invalid jail name"
    exit 1
fi
```

**Notes:**
- Wraps `validate_safe_name()` with jail-specific error messages
- Maximum length: 64 characters
- Logs errors via core logging

---

#### validate_template_name()

**Purpose:** Validate and sanitize template name

**Syntax:**
```bash
template=$(validate_template_name <name>)
```

**Parameters:**
- `name` (required): Template name to validate

**Returns:**
- `0`: Valid template name (prints sanitized name to stdout)
- `1`: Invalid template name (logs error)

**Example:**
```bash
if template=$(validate_template_name "default-ban"); then
    template_file="/etc/nftban/templates/${template}.conf"
fi
```

**Notes:**
- Wraps `validate_safe_name()` with template-specific error messages
- Prevents loading arbitrary files via template injection

---

### User Interaction

#### ask_yes_no()

**Purpose:** Prompt user for yes/no answer

**Syntax:**
```bash
ask_yes_no <question> [default]
```

**Parameters:**
- `question` (required): Question to ask
- `default` (optional): "yes" or "no"

**Returns:**
- `0`: User answered yes
- `1`: User answered no

**Example:**
```bash
if ask_yes_no "Do you want to continue?" "yes"; then
    echo "Continuing..."
else
    echo "Cancelled"
    exit 0
fi
```

**Notes:**
- Shows `[Y/n]` if default is "yes"
- Shows `[y/N]` if default is "no"
- Shows `[y/n]` if no default
- Accepts: y, yes, n, no (case-insensitive)
- Loops until valid answer

---

#### confirm_action()

**Purpose:** Ask for confirmation before destructive action

**Syntax:**
```bash
confirm_action <action> [warning]
```

**Parameters:**
- `action` (required): Action description
- `warning` (optional): Custom warning (default: "This action cannot be undone.")

**Returns:**
- `0`: User confirmed
- `1`: User cancelled

**Example:**
```bash
if confirm_action "delete all banned IPs" "All bans will be removed!"; then
    nftban blacklist clear
else
    echo "Operation cancelled"
fi
```

**Notes:**
- Shows warning message before prompt
- Default answer is "no" (safer)
- Logs cancellation message

---

### Progress Indicators

#### spinner()

**Purpose:** Show spinning animation while process runs

**Syntax:**
```bash
spinner <pid>
```

**Parameters:**
- `pid` (required): Process ID to monitor

**Example:**
```bash
long_running_process &
pid=$!
spinner $pid
wait $pid
```

**Notes:**
- Shows rotating characters: `|`, `/`, `-`, `\`
- Updates every 0.1 seconds
- Clears when process exits

---

#### progress_bar()

**Purpose:** Show progress bar

**Syntax:**
```bash
progress_bar <current> <total> [width]
```

**Parameters:**
- `current` (required): Current progress value
- `total` (required): Total value
- `width` (optional): Bar width in characters (default: 50)

**Example:**
```bash
total=100
for i in {1..100}; do
    progress_bar $i $total
    sleep 0.05
done
echo ""
```

**Notes:**
- Shows: `Progress: [==========          ] 50%`
- Updates in-place with `\r`
- Call with newline after completion

---

### Time Utilities

#### seconds_to_human()

**Purpose:** Convert seconds to human-readable format

**Syntax:**
```bash
seconds_to_human <seconds>
```

**Parameters:**
- `seconds` (required): Number of seconds

**Returns:**
- Human-readable time string (stdout)

**Example:**
```bash
echo $(seconds_to_human 3661)  # Output: 1h 1m
echo $(seconds_to_human 90)    # Output: 1m 30s
echo $(seconds_to_human 45)    # Output: 45s
echo $(seconds_to_human 90000) # Output: 1d 1h
```

---

#### get_file_age()

**Purpose:** Get file age in seconds

**Syntax:**
```bash
get_file_age <file>
```

**Parameters:**
- `file` (required): File path

**Returns:**
- Age in seconds (stdout), or `-1` if file doesn't exist
- Exit code: `0` if success, `1` if file not found

**Example:**
```bash
age=$(get_file_age "/etc/nftban/config/nftban.conf")
if [[ $age -gt 86400 ]]; then
    echo "Config is over 24 hours old"
fi
```

**Notes:**
- Uses `stat` command (Linux and BSD compatible)
- Calculates: current_time - file_modification_time

---

### Network Utilities

#### safe_curl()

**Purpose:** Security-hardened curl wrapper (BUG53 fix)

**Syntax:**
```bash
safe_curl [curl_options] <url>
```

**Parameters:**
- `curl_options` (optional): Additional curl flags
- `url` (required): URL to fetch

**Returns:**
- `0`: Success (prints response to stdout)
- Non-zero: Failure

**Example:**
```bash
# Simple fetch
if safe_curl "https://api.github.com/repos/user/repo" > /tmp/repo.json; then
    echo "Downloaded successfully"
fi

# With additional options
safe_curl -o /tmp/file.txt "https://example.com/data.txt"
```

**Notes:**
- **Security hardening (v0.9.3):**
  - **HTTPS-only:** `--proto '=https'` (blocks HTTP, prevents downgrade)
  - **TLS 1.2+:** `--tlsv1.2` (blocks old TLS versions)
  - **Fail on error:** `--fail-with-body` (returns error codes)
  - **Timeouts:** Connection (10s), total (30s) (prevents hangs)
  - **Retries:** 2 attempts with 2s delay (handles transient failures)
  - **Silent/show-error:** Quiet output except on errors

**Security:**
- Prevents **CWE-918** (SSRF) via HTTPS-only enforcement
- Prevents downgrade attacks via `--proto` flag
- Prevents hanging connections via timeouts
- Should be used for ALL external HTTP requests

---

#### is_port_open()

**Purpose:** Check if TCP port is open

**Syntax:**
```bash
is_port_open [host] <port> [timeout]
```

**Parameters:**
- `host` (optional): Host to check (default: localhost)
- `port` (required): Port number
- `timeout` (optional): Timeout in seconds (default: 2)

**Returns:**
- `0`: Port is open
- `1`: Port is closed or timeout

**Example:**
```bash
if is_port_open "localhost" 22; then
    echo "SSH is running"
fi

if is_port_open "192.168.1.1" 443 5; then
    echo "HTTPS is accessible"
fi
```

**Notes:**
- Uses bash's `/dev/tcp/` feature
- Fast check without external tools
- Silent operation

---

#### get_public_ip()

**Purpose:** Get server's public IP address

**Syntax:**
```bash
get_public_ip
```

**Returns:**
- Public IP address (stdout), or "unknown" if failed

**Example:**
```bash
public_ip=$(get_public_ip)
echo "Server public IP: $public_ip"
```

**Notes:**
- Tries multiple services: ipify.org, ifconfig.me
- Uses `safe_curl()` for security
- Returns "unknown" on failure (doesn't fail script)

---

### Mail Service Detection

#### detect_mail_command()

**Purpose:** Find available mail command

**Syntax:**
```bash
mail_cmd=$(detect_mail_command)
```

**Returns:**
- Command name ("mail", "mailx", or "sendmail"), or empty string if none found

**Example:**
```bash
mail_cmd=$(detect_mail_command)
if [[ -n "$mail_cmd" ]]; then
    echo "Found mail command: $mail_cmd"
else
    echo "No mail command found"
fi
```

**Notes:**
- Checks in order: `mail`, `mailx`, `sendmail`
- Returns first available command
- Does NOT check if command actually works

---

#### detect_mta_service()

**Purpose:** Detect installed Mail Transfer Agents and their status

**Syntax:**
```bash
mta_info=$(detect_mta_service)
```

**Returns:**
- Comma-separated list: `"postfix:active,dovecot:inactive"` or empty string

**Example:**
```bash
mta_info=$(detect_mta_service)
echo "Detected MTAs: $mta_info"

# Parse results
IFS=',' read -ra mta_list <<< "$mta_info"
for mta_entry in "${mta_list[@]}"; do
    mta_name="${mta_entry%:*}"
    mta_status="${mta_entry#*:}"
    echo "$mta_name is $mta_status"
done
```

**Detected Services:**
- **Postfix** (SMTP MTA)
- **Exim** / **Exim4** (SMTP MTA)
- **Sendmail** (SMTP MTA)
- **Dovecot** (IMAP/POP3 server)

**Notes:**
- Uses `systemctl list-units` to detect services
- Checks active status with `systemctl is-active`
- Returns both active and inactive services
- BUG59 FIX: Uses manual string splitting to avoid IFS issues

---

#### check_mail_service()

**Purpose:** Quick check if mail is properly configured

**Syntax:**
```bash
check_mail_service
```

**Returns:**
- `0`: Mail is fully configured (1 MTA active + mail command)
- `1`: Mail is NOT configured (missing command or no active MTA)
- `2`: Conflict detected (multiple MTAs active)

**Example:**
```bash
case $(check_mail_service; echo $?) in
    0)
        echo "Mail service is ready"
        ;;
    1)
        echo "Mail service is not configured"
        show_mail_service_panel  # Show recommendations
        ;;
    2)
        echo "Multiple MTAs detected - conflict!"
        show_mail_service_panel  # Show conflict warning
        ;;
esac
```

**Notes:**
- Silent check (no output)
- Fast return (suitable for startup checks)
- Only counts SMTP services for conflict detection (Dovecot is excluded)

---

#### show_mail_service_panel()

**Purpose:** Show comprehensive mail service status with recommendations

**Syntax:**
```bash
show_mail_service_panel
```

**Parameters:** None

**Returns:** None (displays output)

**Example:**
```bash
# In installer or status command
show_mail_service_panel
```

**Output:**
```
═══════════════════════════════════════════════════════
  Mail Service Status
═══════════════════════════════════════════════════════

Mail Command:
  ✓ Found: mail
    Path: /usr/bin/mail

Mail Services:
  Service: postfix (SMTP)
  Status: ● ACTIVE

  Service: dovecot (IMAP/POP3)
  Status: ● ACTIVE

Email Functionality:
  ✓ READY - Email notifications can be sent

═══════════════════════════════════════════════════════
```

**Features:**
- **Colorized output** (green for OK, red for errors, yellow for warnings)
- **Conflict detection:** Warns if multiple SMTP servers are active
- **Service status:** Shows active/inactive for each service
- **Recommendations:** Provides OS-specific installation commands if needed
- **Action items:** Shows exact commands to fix issues

**Notes:**
- Comprehensive diagnostic tool
- Use in installers and `nftban status` commands
- Shows different recommendations for RHEL/Debian/Arch

---

#### get_mail_installation_recommendation()

**Purpose:** Get OS-specific mail installation commands

**Syntax:**
```bash
get_mail_installation_recommendation
```

**Returns:**
- Multi-line recommendations (stdout)

**Example:**
```bash
echo "Mail service not configured. Here's how to install it:"
get_mail_installation_recommendation
```

**Supported OS:**
- **RHEL/CentOS Stream:** Uses `dnf`
- **Debian/Ubuntu:** Uses `apt`
- **Arch Linux:** Uses `pacman`
- **Other:** Generic recommendations

---

## Integration

### CLI Commands

This module is not directly invoked via CLI. It's a library loaded by other modules.

### Module Integration

**Loading the Module:**
```bash
source "${NFTBAN_LIB_DIR}/nftban_utils_lib.sh"
```

**Using in Scripts:**
```bash
#!/usr/bin/env bash
source /etc/nftban/lib/nftban_core.sh
source /etc/nftban/lib/nftban_utils_lib.sh

# System check
check_root
check_required_commands nft iptables

# File operations
backup_file "/etc/nftban/config/nftban.conf"
safe_write_file "/etc/nftban/config/whitelist.conf" "192.168.1.0/24"

# Validation
if ! validate_port "$port"; then
    nftban_log_error "Invalid port: $port"
    exit 1
fi

# User interaction
if confirm_action "clear all bans"; then
    nftban blacklist clear
fi

# Mail check
if ! check_mail_service; then
    nftban_log_warning "Mail service not configured"
    show_mail_service_panel
fi
```

### nftables Integration

This module does not interact with nftables directly.

---

## Configuration

This module does not use configuration files. All behavior is controlled by function parameters.

---

## Security Considerations

### Security Rating

**Current (v0.9.3):** 9/10
**Previous (v0.9.2):** 7/10
**Improvement:** +2 points

**Rating Breakdown:**
- **Input Validation:** 10/10 - Path traversal prevention (BUG49)
- **File Operations:** 9/10 - Atomic writes, secure temp files
- **Network Security:** 9/10 - HTTPS-only, timeouts (BUG53)
- **Attack Surface:** LOW - Pure utility library, no external inputs

### Production-Hardened Security (v0.9.3+)

**This module uses the v0.9.3 production-hardened header with:**
- ✅ Strict error handling (`set -Eeuo pipefail`)
- ✅ IFS protection (`IFS=$'\n\t'`)
- ✅ Secure umask (027 - group-readable, not world-readable)
- ✅ Double-loading prevention (guard variable)

### Historical Vulnerabilities

#### VUL-UTILS-001: Path Traversal via Jail/Template Names (HIGH)

**Status:** FIXED in v0.9.2 (BUG49)
**CWE:** CWE-73 (External Control of File Name or Path)

**Issue:** Jail and template names were not validated, allowing path traversal attacks.

**Attack Scenario:**
```bash
# Attacker provides malicious jail name
jail_name="../../../etc/shadow"
jail_file="/etc/nftban/jails/${jail_name}.conf"

# Without validation, this would write to:
/etc/shadow  # CRITICAL - Password file overwrite!
```

**Mitigation (v0.9.2+):**
```bash
# Added validate_safe_name() function
validate_safe_name() {
    # Only allow: A-Za-z0-9_-
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi

    # Block path separators
    case "$name" in
        .|..|/*|*/*|*\\*|~/*|*..*) return 1 ;;
    esac

    return 0
}
```

**Reference:** External security review, Path Traversal Prevention

---

#### VUL-UTILS-002: Unsafe curl Usage (MEDIUM)

**Status:** FIXED in v0.9.3 (BUG53)
**CWE:** CWE-918 (Server-Side Request Forgery)

**Issue:** curl was used without security hardening, allowing:
- HTTP downgrade attacks
- SSRF via redirects to `file://` or `localhost`
- Hanging connections without timeouts

**Attack Scenario:**
```bash
# Attacker-controlled URL
feed_url="http://attacker.com/malicious"  # HTTP (not HTTPS)

# Old code:
curl -s "$feed_url" > /etc/nftban/feeds/data.txt
# Vulnerable to: HTTP downgrade, MITM, SSRF
```

**Mitigation (v0.9.3+):**
```bash
safe_curl() {
    curl --fail-with-body \
         --proto '=https' \       # HTTPS only
         --tlsv1.2 \              # TLS 1.2+
         --retry 2 \
         --connect-timeout 10 \   # Prevent hangs
         --max-time 30 \
         "$@"
}
```

**Reference:** External security review, Network Security Hardening

---

#### VUL-UTILS-003: Race Condition in safe_write_file (LOW)

**Status:** MITIGATED in v0.9.2
**CWE:** CWE-362 (Race Condition)

**Issue:** Predictable temp file name could allow symlink attack:
```bash
# Old code:
temp_file="${file}.tmp"
echo "$content" > "$temp_file"  # Attacker creates symlink first
mv "$temp_file" "$file"
```

**Mitigation (v0.9.2+):**
```bash
# Use PID in temp filename
temp_file="${file}.tmp.$$"
# Each process has unique temp file
```

**Additional Protection (v0.9.3):**
- Use `nftban_mktemp()` from core module for truly random temp files
- Set umask 027 at module load (temp files not world-readable)

---

### Security Features

**Input Validation:**
- ✅ Port numbers: Range validation (1-65535)
- ✅ Email addresses: Basic format validation
- ✅ Safe names: Path traversal prevention (alphanumeric + `_-` only)
- ✅ Jail/template names: Wrapper functions with logging

**File Operations:**
- ✅ Atomic writes: Write to temp, then move (prevents corruption)
- ✅ Automatic backups: Timestamped backups before overwrites
- ✅ Permission control: Configurable directory permissions
- ✅ Secure temp files: PID-based or random names

**Network Security:**
- ✅ HTTPS-only enforcement (prevents downgrade)
- ✅ TLS 1.2+ requirement (blocks weak crypto)
- ✅ Connection timeouts (prevents hangs)
- ✅ Retry logic (handles transient failures)

**Command Injection Prevention:**
- ✅ No user input passed to shell commands
- ✅ All function parameters validated
- ✅ Safe use of `command -v` for existence checks

### CWE Mitigations

**v0.9.3 addresses:**
- **CWE-73:** External Control of File Name/Path → MITIGATED (`validate_safe_name()`)
- **CWE-362:** Race Condition → MITIGATED (atomic file writes with PID)
- **CWE-918:** Server-Side Request Forgery → MITIGATED (`safe_curl()` with `--proto '=https'`)

**Additional CWEs:**
- **CWE-78:** Command Injection → NOT APPLICABLE (no user input in commands)
- **CWE-79:** Cross-Site Scripting → NOT APPLICABLE (no web interface)
- **CWE-20:** Improper Input Validation → MITIGATED (comprehensive validation functions)

### Attack Surface

**Risk 1: Path Traversal via Jail/Template Names**
- **Likelihood:** LOW (requires admin privileges to call functions)
- **Impact:** CRITICAL (arbitrary file write)
- **Mitigation:** `validate_safe_name()` blocks all path separators and special chars
- **Status:** MITIGATED (v0.9.2+)

**Risk 2: SSRF via safe_curl() Misconfiguration**
- **Likelihood:** LOW (function enforces HTTPS-only)
- **Impact:** MEDIUM (could access internal services if HTTPS redirect allowed)
- **Mitigation:** `--proto '=https'` blocks all non-HTTPS protocols (including `file://`, `ftp://`)
- **Status:** MITIGATED (v0.9.3+)

**Risk 3: Race Condition in File Operations**
- **Likelihood:** LOW (requires precise timing + multiple processes)
- **Impact:** MEDIUM (file corruption or data loss)
- **Mitigation:** Atomic writes with unique temp files (PID-based)
- **Status:** MITIGATED (v0.9.2+)

**Risk 4: MTA Conflict Detection Bypass**
- **Likelihood:** MEDIUM (user could manually edit systemctl units)
- **Impact:** LOW (mail delivery failures, not a security issue)
- **Mitigation:** Comprehensive detection of all major MTAs, visual warnings
- **Status:** OPERATIONAL (informational only)

### File Security

**Configuration Files:**
- Location: N/A (this module doesn't use config files)

**Log Files:**
- Location: Uses core module logging (`/var/log/nftban/nftban.log`)
- Permissions: Inherited from core module (640)

**Temporary Files:**
- Location: `/tmp/` or `$TMPDIR` (caller-dependent)
- Permissions: Respects umask 027 (group-readable, not world-readable)
- Cleanup: Caller responsible (or use `nftban_mktemp()` from core for automatic cleanup)

### Compliance

**Security Standards:**
- **CIS Benchmarks:** Aligned with file permission recommendations (restrictive umask)
- **OWASP:** Input validation (path traversal), secure communication (HTTPS-only)
- **Production-grade:** ✅ Yes (v0.9.3+)

**Audit Trail:**
- All security-relevant operations logged via core module
- File operations logged with full paths
- Validation failures logged with reason

---

## Troubleshooting

### Common Issues

#### Issue: "This script must be run as root" error

**Symptoms:**
- Script exits immediately with fatal error
- Happens on script start

**Cause:** Script requires root privileges but was run as regular user

**Solution:**
```bash
# Run with sudo
sudo nftban [command]

# Or switch to root
su -
nftban [command]
```

---

#### Issue: "Missing required commands" error

**Symptoms:**
- Script exits with list of missing commands
- Functions fail with "command not found"

**Cause:** Required system commands not installed

**Solution:**
```bash
# Example: nft is missing
sudo apt install nftables  # Debian/Ubuntu
sudo dnf install nftables  # RHEL/CentOS

# Example: curl is missing
sudo apt install curl      # Debian/Ubuntu
sudo dnf install curl      # RHEL/CentOS
```

---

#### Issue: safe_write_file() fails silently

**Symptoms:**
- File is not written
- No error message visible
- Returns non-zero exit code

**Cause:** Permission denied or disk full

**Solution:**
```bash
# Check permissions
ls -la $(dirname "/etc/nftban/config/file.conf")

# Check disk space
df -h /etc

# Check for read-only filesystem
mount | grep /etc
```

---

#### Issue: Mail service shows "CONFLICT" warning

**Symptoms:**
- Multiple SMTP services running
- `show_mail_service_panel()` shows red warning
- Mail delivery is unreliable

**Cause:** Multiple MTAs (Postfix, Exim, Sendmail) active simultaneously

**Solution:**
```bash
# Identify active MTAs
systemctl status postfix
systemctl status exim
systemctl status sendmail

# Keep only ONE SMTP service (example: keep Postfix)
sudo systemctl stop exim
sudo systemctl disable exim

# Verify only one is running
show_mail_service_panel
```

**Note:** Dovecot (IMAP/POP3) can run alongside any SMTP server - this is NOT a conflict.

---

#### Issue: validate_safe_name() rejects valid name

**Symptoms:**
- Function returns 1 for seemingly valid name
- Error: "must be alphanumeric with _ or -"

**Cause:** Name contains disallowed characters

**Solution:**
```bash
# ALLOWED:
validate_safe_name "my-jail"      # ✓ OK
validate_safe_name "jail_name"    # ✓ OK
validate_safe_name "jail123"      # ✓ OK

# NOT ALLOWED:
validate_safe_name "my.jail"      # ✗ Dot not allowed
validate_safe_name "jail name"    # ✗ Space not allowed
validate_safe_name "jail/name"    # ✗ Slash not allowed (path traversal)
validate_safe_name "../jail"      # ✗ Path traversal attempt

# Use only: A-Z a-z 0-9 _ -
```

---

#### Issue: get_public_ip() returns "unknown"

**Symptoms:**
- Function returns "unknown" instead of IP address

**Cause:** Network error or external services down

**Solution:**
```bash
# Test connectivity manually
curl -v https://api.ipify.org
curl -v https://ifconfig.me

# Check if safe_curl() is working
safe_curl https://api.ipify.org

# Verify internet connectivity
ping -c 3 8.8.8.8

# Check if firewall is blocking outbound HTTPS
sudo nft list ruleset | grep -i output
```

---

### Logs

**Relevant Log Files:**
- `/var/log/nftban/nftban.log` - All utility function operations (via core logging)
- `/var/log/nftban/errors.log` - Error-level messages

**Viewing Logs:**
```bash
# View recent utility operations
tail -f /var/log/nftban/nftban.log | grep "utils"

# Search for validation errors
grep "Invalid.*name" /var/log/nftban/nftban.log

# View file operations
grep -E "Created directory|Backed up|Successfully wrote" /var/log/nftban/nftban.log
```

---

### Debugging

**Enable Debug Mode:**
```bash
export NFTBAN_DEBUG=1
source /etc/nftban/lib/nftban_utils_lib.sh

# Now all operations will log debug messages
```

**Manual Testing:**
```bash
# Test validation functions
source /etc/nftban/lib/nftban_utils_lib.sh

validate_port "8080" && echo "Valid" || echo "Invalid"
validate_email "admin@example.com" && echo "Valid" || echo "Invalid"
validate_safe_name "my-jail" && echo "Valid" || echo "Invalid"

# Test file operations
backup_file "/etc/hosts"
safe_write_file "/tmp/test.txt" "Hello World"

# Test mail detection
detect_mail_command
detect_mta_service
show_mail_service_panel
```

**Verification Commands:**
```bash
# Verify module is loaded
declare -f check_root

# Verify functions exist
command -v validate_safe_name
command -v safe_curl
command -v show_mail_service_panel

# Check color codes
echo -e "${COLOR_GREEN}Green${COLOR_RESET}"
echo -e "${COLOR_RED}Red${COLOR_RESET}"
```

---

## Testing

### Unit Testing

**Manual tests for key functions:**

```bash
#!/usr/bin/env bash
source /etc/nftban/lib/nftban_core.sh
source /etc/nftban/lib/nftban_utils_lib.sh

echo "Testing validation functions..."

# Test validate_port
test_port() {
    local port=$1
    local expected=$2

    if validate_port "$port"; then
        result="VALID"
    else
        result="INVALID"
    fi

    if [[ "$result" == "$expected" ]]; then
        echo "✓ validate_port($port) = $result"
    else
        echo "✗ validate_port($port) = $result (expected $expected)"
    fi
}

test_port "80" "VALID"
test_port "65535" "VALID"
test_port "0" "INVALID"
test_port "99999" "INVALID"
test_port "abc" "INVALID"

# Test validate_safe_name (BUG49 regression test)
test_safe_name() {
    local name=$1
    local expected=$2

    if validate_safe_name "$name"; then
        result="VALID"
    else
        result="INVALID"
    fi

    if [[ "$result" == "$expected" ]]; then
        echo "✓ validate_safe_name($name) = $result"
    else
        echo "✗ validate_safe_name($name) = $result (expected $expected)"
    fi
}

test_safe_name "my-jail" "VALID"
test_safe_name "jail_123" "VALID"
test_safe_name "../etc/passwd" "INVALID"  # Path traversal
test_safe_name "jail/name" "INVALID"      # Slash
test_safe_name "jail name" "INVALID"      # Space

echo ""
echo "Testing file operations..."

# Test atomic write
test_file="/tmp/nftban-test-$$"
if safe_write_file "$test_file" "test content" "false"; then
    if [[ $(cat "$test_file") == "test content" ]]; then
        echo "✓ safe_write_file() works"
    else
        echo "✗ safe_write_file() - content mismatch"
    fi
    rm -f "$test_file"
else
    echo "✗ safe_write_file() failed"
fi

echo ""
echo "Testing mail detection..."
mail_cmd=$(detect_mail_command)
echo "Mail command: ${mail_cmd:-NOT FOUND}"

mta_info=$(detect_mta_service)
echo "MTAs detected: ${mta_info:-NONE}"

check_mail_service
case $? in
    0) echo "Mail status: READY" ;;
    1) echo "Mail status: NOT CONFIGURED" ;;
    2) echo "Mail status: CONFLICT" ;;
esac
```

---

### Integration Testing

**Test in real module:**

```bash
#!/usr/bin/env bash
# Test script: test_utils_integration.sh

source /etc/nftban/lib/nftban_core.sh
source /etc/nftban/lib/nftban_utils_lib.sh

echo "Integration Test: Utils Module"
echo ""

# Test 1: Root check (will fail if not root)
echo "Test 1: Root check"
if [[ $EUID -eq 0 ]]; then
    check_root
    echo "✓ Passed root check"
else
    echo "⚠ Skipping (not root)"
fi

# Test 2: Command checks
echo ""
echo "Test 2: Required commands"
if check_required_commands nft iptables curl; then
    echo "✓ All required commands present"
else
    echo "✗ Some commands missing"
fi

# Test 3: File operations with backup
echo ""
echo "Test 3: File operations"
test_file="/tmp/nftban-integration-test.conf"
echo "Original content" > "$test_file"

if backup_file "$test_file" "/tmp/nftban-backup"; then
    echo "✓ Backup created"
else
    echo "✗ Backup failed"
fi

if safe_write_file "$test_file" "Modified content"; then
    echo "✓ File updated atomically"
else
    echo "✗ File update failed"
fi

# Cleanup
rm -f "$test_file"
rm -rf "/tmp/nftban-backup"

# Test 4: Mail service check
echo ""
echo "Test 4: Mail service detection"
show_mail_service_panel

echo ""
echo "Integration test complete"
```

---

### Test Cases

**Test Case 1: Path Traversal Prevention (Security)**
- **Input:** `validate_safe_name "../../../etc/shadow"`
- **Expected:** Returns 1 (invalid)
- **Validation:** No error logged, function blocks silently

**Test Case 2: Atomic File Write (Race Condition)**
- **Input:** `safe_write_file "/etc/nftban/test.conf" "data"`
- **Expected:** File written atomically, backup created
- **Validation:**
  - Temp file uses unique name (`test.conf.tmp.$$`)
  - Original file backed up before overwrite
  - Move is atomic (no partial writes)

**Test Case 3: HTTPS-Only Enforcement (SSRF Prevention)**
- **Input:** `safe_curl "http://example.com"`
- **Expected:** Fails (HTTP not allowed)
- **Validation:** curl returns error, does not fetch

**Test Case 4: Mail Conflict Detection**
- **Input:** Postfix and Exim both active
- **Expected:** `check_mail_service` returns 2
- **Validation:** `show_mail_service_panel` displays red conflict warning

**Test Case 5: Service Detection**
- **Input:** `is_service_running "postfix"`
- **Expected:** Returns 0 if active, 1 if inactive
- **Validation:** Matches `systemctl is-active postfix`

---

## Performance

### Resource Usage

- **Memory:** ~5KB (color variables + function definitions)
- **CPU:** Negligible (no background processes)
- **Disk I/O:** Minimal (only during file operations)
- **Network:** Only when `safe_curl()` or `get_public_ip()` called

### Optimization

**Best Practices:**

1. **Validation caching:** If validating same value multiple times, cache result:
```bash
# Instead of:
for i in {1..100}; do
    validate_port "$port" && process_port "$port"
done

# Do this:
if validate_port "$port"; then
    for i in {1..100}; do
        process_port "$port"
    done
fi
```

2. **Command existence:** Cache `command_exists` results:
```bash
# At script start
if command_exists "mail"; then
    HAS_MAIL=true
else
    HAS_MAIL=false
fi

# Later, use cached result
if [[ "$HAS_MAIL" == true ]]; then
    echo "test" | mail -s "subject" user@example.com
fi
```

3. **Mail detection:** Use `check_mail_service()` instead of `show_mail_service_panel()` for fast checks.

4. **File age checks:** Don't call `get_file_age()` repeatedly for same file:
```bash
# Cache age at start
file_age=$(get_file_age "/etc/nftban/config/nftban.conf")
if [[ $file_age -gt 86400 ]]; then
    echo "Config is old"
fi
```

---

## Maintenance

### Regular Tasks

- [ ] **Review validation rules** - Monthly
  - Ensure `validate_safe_name()` blocks all known path traversal patterns
  - Update regex patterns if new attack vectors discovered

- [ ] **Test mail detection** - After OS upgrades
  - Verify `detect_mta_service()` recognizes all MTAs on new OS versions
  - Test `show_mail_service_panel()` output

- [ ] **Update safe_curl() security** - Quarterly
  - Review curl security advisories
  - Update minimum TLS version if needed
  - Add new security flags as available

- [ ] **Backup testing** - Monthly
  - Verify `backup_file()` creates valid backups
  - Test restore from backup

### Backup Considerations

**This module doesn't store data** - no backup needed.

**Backups created BY this module:**
- Location: `${dir}/backups/` or custom path
- Format: `${filename}.YYYYMMDD_HHMMSS.bak`
- Retention: Not managed (caller responsible for cleanup)

**Recommendation:** Create cleanup script for old backups:
```bash
# Clean backups older than 30 days
find /etc/nftban/config/backups -name "*.bak" -mtime +30 -delete
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.9.3-dev | 2025-10-22 | Security maturity release: Enhanced safe_curl() (BUG53), atomic file writes |
| 0.9.2 | 2025-10-20 | Path traversal prevention (BUG49), strict mode (BUG51), MTA conflict detection (BUG58/59) |
| 0.9.1 | 2025-10-15 | Initial modular release with mail service detection |

---

## References

### Related Documentation

- [NFTBAN_CORE_MODULE.md](NFTBAN_CORE_MODULE.md) - Core functions and logging
- [SECURITY_HARDENING_v0.9.3.md](../Security/SECURITY_HARDENING_v0.9.3.md) - Security improvements
- [VULNERABILITY_TRACKING.md](../Security/VULNERABILITY_TRACKING.md) - Known vulnerabilities and fixes

### External Resources

- [CWE-73: External Control of File Name or Path](https://cwe.mitre.org/data/definitions/73.html)
- [CWE-362: Concurrent Execution using Shared Resource with Improper Synchronization](https://cwe.mitre.org/data/definitions/362.html)
- [CWE-918: Server-Side Request Forgery (SSRF)](https://cwe.mitre.org/data/definitions/918.html)
- [Bash Path Traversal Prevention](https://owasp.org/www-community/attacks/Path_Traversal)
- [curl Security Best Practices](https://curl.se/docs/security.html)

---

## Footer

**Document Status:** Final
**Review Date:** 2025-11-22
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

*Generated: 2025-10-22 00:00:00 UTC*
*NFTBan Version: 0.9.3-dev*
