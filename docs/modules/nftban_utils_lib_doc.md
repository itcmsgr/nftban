# NFTBan Utilities Library

**File:** `lib/nftban_utils_lib.sh`
**Version:** 1.0.0
**Author:** ITCMS Team (Antonios Voulvoulis)
**Purpose:** Common utility functions for NFTBan modules

---

## Overview

The Utilities Library provides a comprehensive collection of reusable helper functions used throughout NFTBan. It serves as a foundational library offering common functionality including system checks, file operations, string/array manipulation, validation, user interaction, progress indicators, and network utilities.

This library follows Unix philosophy principles: small, focused functions that do one thing well. Functions are designed to be composable, with consistent return codes and error handling. The library automatically detects terminal capabilities (color support) and adapts output accordingly.

**Important Note:** Logging and configuration functions have been consolidated into `nftban_core.sh`. This library focuses on pure utility functions without dependencies on core NFTBan infrastructure.

---

## Key Functions

### System Checks

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `check_root()` | Verify running as root | None | Exits if not root |
| `command_exists()` | Check if command available | `$1` - command name | 0 if exists, 1 if not |
| `check_required_commands()` | Validate required commands | `$@` - command list | 0 if all exist, 1 if missing |
| `is_service_running()` | Check if service active | `$1` - service name | 0 if running, 1 if not |
| `is_service_enabled()` | Check if service enabled | `$1` - service name | 0 if enabled, 1 if not |

### File Operations

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `create_directory()` | Create directory with permissions | `$1` - path, `$2` - mode (default: 0755) | 0 on success, 1 on error |
| `backup_file()` | Backup file with timestamp | `$1` - file path, `$2` - backup dir (optional) | 0 on success, 1 on error |
| `safe_write_file()` | Atomic file write with backup | `$1` - file, `$2` - content, `$3` - backup (true/false) | 0 on success, 1 on error |

### String Utilities

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `trim()` | Remove leading/trailing whitespace | `$1` - string | Trimmed string |
| `to_upper()` | Convert to uppercase | `$1` - string | Uppercase string |
| `to_lower()` | Convert to lowercase | `$1` - string | Lowercase string |
| `string_contains()` | Check if string contains substring | `$1` - string, `$2` - substring | 0 if contains, 1 if not |

### Array Utilities

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `array_contains()` | Check if array contains element | `$1` - element, `$@` - array | 0 if contains, 1 if not |
| `array_join()` | Join array with delimiter | `$1` - delimiter, `$@` - array | Joined string |

### Validation Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `validate_yes_no()` | Validate yes/no input | `$1` - input | 0 for yes, 1 for no, 2 for invalid |
| `validate_port()` | Validate port number (1-65535) | `$1` - port | 0 if valid, 1 if invalid |
| `validate_email()` | Basic email validation | `$1` - email | 0 if valid, 1 if invalid |

### User Interaction

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `ask_yes_no()` | Ask yes/no question | `$1` - question, `$2` - default (optional) | 0 for yes, 1 for no |
| `confirm_action()` | Confirm dangerous action | `$1` - action, `$2` - warning (optional) | 0 if confirmed, 1 if cancelled |

### Progress Indicators

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `spinner()` | Show spinner while process runs | `$1` - process PID | None |
| `progress_bar()` | Display progress bar | `$1` - current, `$2` - total, `$3` - width (default: 50) | None |

### Time Utilities

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `seconds_to_human()` | Convert seconds to human format | `$1` - seconds | Human-readable string |
| `get_file_age()` | Get file age in seconds | `$1` - file path | Age in seconds, -1 if error |

### Network Utilities

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `is_port_open()` | Check if port accessible | `$1` - host (default: localhost), `$2` - port, `$3` - timeout (default: 2) | 0 if open, 1 if closed |
| `get_public_ip()` | Get public IP address | None | IP address string or "unknown" |

### Cleanup Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `register_cleanup()` | Register cleanup function | `$1` - cleanup function | None |
| `cleanup()` | Standard cleanup handler | None | None |

---

## Configuration Variables

### Color Codes (Auto-Detected)

| Variable | Value (TTY) | Value (Non-TTY) | Description |
|----------|-------------|-----------------|-------------|
| `COLOR_RESET` | `\033[0m` | `""` | Reset colors |
| `COLOR_RED` | `\033[0;31m` | `""` | Red text |
| `COLOR_GREEN` | `\033[0;32m` | `""` | Green text |
| `COLOR_YELLOW` | `\033[0;33m` | `""` | Yellow text |
| `COLOR_BLUE` | `\033[0;34m` | `""` | Blue text |
| `COLOR_MAGENTA` | `\033[0;35m` | `""` | Magenta text |
| `COLOR_CYAN` | `\033[0;36m` | `""` | Cyan text |
| `COLOR_WHITE` | `\033[0;37m` | `""` | White text |
| `COLOR_BOLD` | `\033[1m` | `""` | Bold text |
| `COLOR_DIM` | `\033[2m` | `""` | Dim text |

Colors automatically disabled when output is piped or redirected.

---

## Dependencies

**External Commands (Optional):**
- `systemctl` - Service status checks
- `curl` - Public IP detection
- `stat` - File modification time
- `timeout` - Port connectivity checks

**No NFTBan Dependencies:**
This library is standalone and does not depend on other NFTBan modules.

---

## Usage Examples

### Example 1: System Checks
```bash
# Check if running as root
check_root  # Exits with error if not root

# Check if command exists
if command_exists "nft"; then
    echo "nftables is installed"
fi

# Check multiple required commands
if check_required_commands nft systemctl curl; then
    echo "All required commands available"
else
    echo "Missing dependencies"
    exit 1
fi
```

### Example 2: Service Checks
```bash
# Check if service is running
if is_service_running "nftables"; then
    echo "nftables service is active"
else
    echo "nftables service is not running"
    systemctl start nftables
fi

# Check if service is enabled
if is_service_enabled "fail2ban"; then
    echo "Fail2Ban will start on boot"
else
    echo "Enabling Fail2Ban on boot"
    systemctl enable fail2ban
fi
```

### Example 3: File Operations
```bash
# Create directory with custom permissions
create_directory "/var/lib/nftban" "0700"

# Backup file before modification
backup_file "/etc/nftban/config/nftban.conf"
# Creates: /etc/nftban/config/backups/nftban.conf.20251020_143000.bak

# Safe atomic write with backup
safe_write_file "/etc/nftban/config/custom.conf" "key=value\nfoo=bar" true
```

### Example 4: String Manipulation
```bash
# Trim whitespace
input="  hello world  "
trimmed=$(trim "$input")
echo "$trimmed"  # Output: "hello world"

# Case conversion
upper=$(to_upper "nftban")
echo "$upper"  # Output: "NFTBAN"

lower=$(to_lower "SSHD")
echo "$lower"  # Output: "sshd"

# Check substring
if string_contains "nftban v0.9.0" "v0.9"; then
    echo "Version match"
fi
```

### Example 5: Array Operations
```bash
# Check if array contains element
allowed_commands=("start" "stop" "restart" "status")
if array_contains "start" "${allowed_commands[@]}"; then
    echo "Command is allowed"
fi

# Join array elements
paths=("/usr/bin" "/usr/local/bin" "/opt/bin")
path_string=$(array_join ":" "${paths[@]}")
echo "$path_string"  # Output: "/usr/bin:/usr/local/bin:/opt/bin"
```

### Example 6: Validation
```bash
# Validate yes/no input
read -p "Continue? " response
if validate_yes_no "$response"; then
    echo "User confirmed"
elif [ $? -eq 1 ]; then
    echo "User declined"
else
    echo "Invalid input"
fi

# Validate port
if validate_port "8080"; then
    echo "Valid port"
else
    echo "Invalid port"
fi

# Validate email
if validate_email "admin@example.com"; then
    echo "Valid email"
else
    echo "Invalid email"
fi
```

### Example 7: User Interaction
```bash
# Ask yes/no question with default
if ask_yes_no "Enable automatic updates?" "yes"; then
    enable_auto_updates
fi

# Confirm dangerous action
if confirm_action "delete all logs" "This will remove all historical data"; then
    rm -rf /var/log/nftban/*
    echo "Logs deleted"
else
    echo "Operation cancelled"
fi
```

### Example 8: Progress Indicators
```bash
# Show spinner for long operation
long_running_task &
pid=$!
spinner $pid
echo "Task completed"

# Progress bar
total=100
for ((i=1; i<=total; i++)); do
    progress_bar $i $total
    sleep 0.05
done
echo  # Newline after progress bar
```

### Example 9: Time Utilities
```bash
# Convert seconds to human format
uptime_seconds=3665
echo "Uptime: $(seconds_to_human $uptime_seconds)"
# Output: "Uptime: 1h 1m"

ban_time=86400
echo "Ban duration: $(seconds_to_human $ban_time)"
# Output: "Ban duration: 1d 0h"

# Get file age
age=$(get_file_age "/var/log/nftban/nftban.log")
echo "Log file is $(seconds_to_human $age) old"
```

### Example 10: Network Utilities
```bash
# Check if port is open
if is_port_open "localhost" "80"; then
    echo "Web server is running"
else
    echo "Web server not responding"
fi

# Check remote port with custom timeout
if is_port_open "example.com" "443" 5; then
    echo "HTTPS is accessible"
fi

# Get public IP
public_ip=$(get_public_ip)
echo "Your public IP: $public_ip"
```

### Example 11: Cleanup Handlers
```bash
#!/bin/bash

# Custom cleanup function
my_cleanup() {
    echo "Cleaning up temporary files..."
    rm -f /tmp/nftban_temp_*
    echo "Cleanup complete"
}

# Register cleanup
register_cleanup my_cleanup

# Script continues...
# Cleanup automatically called on EXIT, INT, or TERM
```

### Example 12: Combined Usage
```bash
#!/bin/bash
# Example: Safe configuration update

# Check prerequisites
check_root
check_required_commands nft systemctl

# Get user input
if ask_yes_no "Update firewall rules?" "no"; then
    # Backup existing config
    config_file="/etc/nftban/config/rules.conf"
    backup_file "$config_file"
    
    # Generate new content
    new_content="# Updated $(date)\nrule1=value1\nrule2=value2"
    
    # Safe write
    if safe_write_file "$config_file" "$new_content" true; then
        echo "Configuration updated successfully"
        
        # Reload service
        if is_service_running "nftables"; then
            systemctl reload nftables
        fi
    else
        echo "Failed to update configuration"
        exit 1
    fi
fi
```

---

## Function Details

### System Checks

#### `check_root()`
**Purpose:** Ensure script runs with root privileges

**Behavior:**
- Checks `$EUID` (effective user ID)
- Exits immediately if not 0 (root)
- Displays fatal error message

**Example:**
```bash
check_root  # Must be first line in scripts requiring root
```

#### `command_exists(command)`
**Purpose:** Test if command is available in PATH

**Return Codes:**
- `0` - Command exists
- `1` - Command not found

**Example:**
```bash
if command_exists "docker"; then
    docker --version
fi
```

#### `check_required_commands(cmd1 cmd2 ...)`
**Purpose:** Validate all required commands exist

**Behavior:**
- Tests each command
- Logs missing commands
- Suggests installation

**Return Codes:**
- `0` - All commands available
- `1` - One or more missing

**Example:**
```bash
check_required_commands git curl wget || exit 1
```

### File Operations

#### `create_directory(path, [mode])`
**Purpose:** Create directory with specific permissions

**Parameters:**
- `path` - Directory path to create
- `mode` - Permissions (default: 0755)

**Behavior:**
- Creates parent directories (`mkdir -p`)
- Sets specified permissions
- Idempotent (safe if exists)

**Example:**
```bash
create_directory "/var/lib/myapp" "0700"
```

#### `backup_file(file, [backup_dir])`
**Purpose:** Create timestamped backup

**Parameters:**
- `file` - File to backup
- `backup_dir` - Backup location (default: `./backups`)

**Behavior:**
- Preserves file attributes (`cp -a`)
- Adds timestamp: `filename.YYYYMMDD_HHMMSS.bak`
- Creates backup directory if needed

**Example:**
```bash
backup_file "/etc/myapp/config.ini" "/var/backups/myapp"
```

#### `safe_write_file(file, content, [backup])`
**Purpose:** Atomic file write with optional backup

**Parameters:**
- `file` - Target file path
- `content` - Content to write
- `backup` - Backup existing file (default: true)

**Behavior:**
1. Backups existing file (if enabled)
2. Writes to temporary file
3. Moves temp file to final location (atomic)
4. Cleans up on failure

**Atomicity:** Uses `mv` which is atomic on same filesystem

**Example:**
```bash
safe_write_file "/etc/hosts" "127.0.0.1 localhost" false
```

### String Utilities

#### `trim(string)`
**Purpose:** Remove whitespace from both ends

**Returns:** Trimmed string via stdout

**Example:**
```bash
clean=$(trim "  text  ")  # "text"
```

#### `to_upper(string)` / `to_lower(string)`
**Purpose:** Case conversion

**Returns:** Converted string via stdout

**Example:**
```bash
upper=$(to_upper "hello")  # "HELLO"
lower=$(to_lower "WORLD")  # "world"
```

#### `string_contains(string, substring)`
**Purpose:** Check if string contains substring

**Return Codes:**
- `0` - Contains substring
- `1` - Does not contain

**Example:**
```bash
if string_contains "$log_line" "ERROR"; then
    echo "Error found in log"
fi
```

### Validation Functions

#### `validate_yes_no(input)`
**Purpose:** Validate affirmative/negative input

**Accepts:**
- Yes: `yes`, `y`, `true`, `1` (case-insensitive)
- No: `no`, `n`, `false`, `0` (case-insensitive)

**Return Codes:**
- `0` - Yes
- `1` - No
- `2` - Invalid input

**Example:**
```bash
validate_yes_no "$user_input"
case $? in
    0) echo "Yes" ;;
    1) echo "No" ;;
    2) echo "Invalid" ;;
esac
```

#### `validate_port(port)`
**Purpose:** Validate TCP/UDP port number

**Valid Range:** 1-65535

**Return Codes:**
- `0` - Valid port
- `1` - Invalid port

**Example:**
```bash
if validate_port "$PORT"; then
    echo "Port $PORT is valid"
fi
```

#### `validate_email(email)`
**Purpose:** Basic email format validation

**Pattern:** `user@domain.tld`

**Note:** Basic regex, not RFC-compliant

**Example:**
```bash
if validate_email "admin@example.com"; then
    send_notification "$email"
fi
```

---

## Best Practices

### Error Handling

```bash
# Always check return codes
if ! create_directory "/var/lib/app"; then
    echo "Failed to create directory"
    exit 1
fi

# Use || for critical operations
check_required_commands nft systemctl || exit 1
```

### Safe File Operations

```bash
# Always backup before modification
backup_file "$config_file"

# Use atomic writes
safe_write_file "$config_file" "$new_content" true

# Never:
echo "$content" > "$important_file"  # Not atomic, no backup
```

### User Interaction

```bash
# Provide defaults for common choices
if ask_yes_no "Install recommended packages?" "yes"; then
    install_packages
fi

# Confirm dangerous operations
if confirm_action "delete database" "All data will be lost"; then
    drop_database
fi
```

### Color Usage

```bash
# Colors automatically adapt to terminal
echo -e "${COLOR_GREEN}Success${COLOR_RESET}"
echo -e "${COLOR_RED}Error${COLOR_RESET}"

# No special handling needed for pipes:
# script.sh | tee output.log  # Colors automatically disabled
```

---

## Performance

- **Lightweight:** All functions are pure bash
- **No External Dependencies:** Works without additional packages
- **Fast Execution:** Minimal overhead
- **Memory Efficient:** No persistent state

---

## Security Considerations

### Root Checks

- `check_root()` exits immediately if not root
- Prevents accidental non-privileged execution
- Use at script start for security-critical operations

### File Operations

- `safe_write_file()` is atomic within same filesystem
- Prevents partial writes visible to other processes
- Backups preserve permissions and ownership

### Input Validation

- Always validate user input before use
- Use validation functions for ports, emails, etc.
- Prevent injection attacks

---

## Limitations

### Email Validation

- Basic regex only
- Not RFC 5322 compliant
- For simple format checking only

### Port Checking

- `is_port_open()` requires `/dev/tcp`
- May not work in restricted environments
- Alternative: use `nc` or `telnet`

### Public IP Detection

- Requires internet connectivity
- Depends on external services
- May fail in air-gapped environments

---

## Integration Points

**Used by:**
- All NFTBan modules
- Installation scripts
- Maintenance scripts
- CLI commands

**Does not depend on:**
- nftban_core.sh (standalone library)
- Any other NFTBan modules

---

## Change Log

### Version 1.0.0 (2025-10-20)
- Initial release
- Extracted from monolithic utilities
- Removed logging functions (moved to nftban_core.sh)
- Removed config functions (moved to nftban_core.sh)
- Added comprehensive documentation
- Standardized function names
- Improved error handling

---

## See Also

**Related Modules:**
- `nftban_core.sh` - Core logging and configuration
- All other NFTBan modules use these utilities

**Documentation:**
- `BASH_BEST_PRACTICES.md` - Bash coding standards
- `CONTRIBUTING.md` - Development guidelines

**External Resources:**
- Bash Guide: https://mywiki.wooledge.org/BashGuide
- Advanced Bash Scripting: https://tldp.org/LDP/abs/html/
