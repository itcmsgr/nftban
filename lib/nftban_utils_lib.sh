#!/bin/bash
# =============================================================================
# NFTBAN Utilities Library - Common Functions
# =============================================================================

# Mark this library as loaded
NFTBAN_UTILS_LOADED="true"

# =============================================================================
# COLOR CODES
# =============================================================================
if [[ -t 1 ]]; then
    # Terminal supports colors
    COLOR_RESET="\033[0m"
    COLOR_RED="\033[0;31m"
    COLOR_GREEN="\033[0;32m"
    COLOR_YELLOW="\033[0;33m"
    COLOR_BLUE="\033[0;34m"
    COLOR_MAGENTA="\033[0;35m"
    COLOR_CYAN="\033[0;36m"
    COLOR_WHITE="\033[0;37m"
    COLOR_BOLD="\033[1m"
    COLOR_DIM="\033[2m"
else
    # No color support
    COLOR_RESET=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
    COLOR_WHITE=""
    COLOR_BOLD=""
    COLOR_DIM=""
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Get timestamp
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Log to file
log_to_file() {
    local level="$1"
    local message="$2"
    local log_file="${NFTBAN_LOG_FILE:-/var/log/nftban/nftban.log}"
    
    # Create log directory if it doesn't exist
    local log_dir=$(dirname "$log_file")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null
    fi
    
    # Write to log file
    if [[ -w "$log_dir" ]]; then
        echo "[$(get_timestamp)] [$level] $message" >> "$log_file"
    fi
}

# Log debug message
log_debug() {
    local message="$1"
    
    # Only show debug if debug mode enabled
    if [[ "${NFTBAN_DEBUG_MODE}" == "true" ]] || [[ "${NFTBAN_LOG_LEVEL}" == "DEBUG" ]]; then
        echo -e "${COLOR_DIM}[DEBUG]${COLOR_RESET} $message" >&2
        log_to_file "DEBUG" "$message"
    fi
}

# Log info message
log_info() {
    local message="$1"
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $message"
    log_to_file "INFO" "$message"
}

# Log success message
log_success() {
    local message="$1"
    echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $message"
    log_to_file "SUCCESS" "$message"
}

# Log warning message
log_warning() {
    local message="$1"
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $message" >&2
    log_to_file "WARNING" "$message"
}

# Log error message
log_error() {
    local message="$1"
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $message" >&2
    log_to_file "ERROR" "$message"
}

# Log fatal error and exit
log_fatal() {
    local message="$1"
    local exit_code="${2:-1}"
    echo -e "${COLOR_RED}${COLOR_BOLD}[FATAL]${COLOR_RESET} $message" >&2
    log_to_file "FATAL" "$message"
    exit "$exit_code"
}

# =============================================================================
# SYSTEM CHECKS
# =============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root (use sudo)"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check required commands
check_required_commands() {
    local missing=()
    
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Please install missing packages and try again"
        return 1
    fi
    
    return 0
}

# Check if service is running
is_service_running() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

# Check if service is enabled
is_service_enabled() {
    local service="$1"
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

# =============================================================================
# FILE OPERATIONS
# =============================================================================

# Create directory with proper permissions
create_directory() {
    local dir="$1"
    local mode="${2:-0755}"
    
    if [[ -d "$dir" ]]; then
        log_debug "Directory already exists: $dir"
        return 0
    fi
    
    if mkdir -p "$dir" 2>/dev/null; then
        chmod "$mode" "$dir"
        log_success "Created directory: $dir"
        return 0
    else
        log_error "Failed to create directory: $dir"
        return 1
    fi
}

# Backup file
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")/backups}"
    
    if [[ ! -f "$file" ]]; then
        log_debug "File does not exist, no backup needed: $file"
        return 0
    fi
    
    create_directory "$backup_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename=$(basename "$file")
    local backup_file="${backup_dir}/${filename}.${timestamp}.bak"
    
    if cp -a "$file" "$backup_file" 2>/dev/null; then
        log_success "Backed up: $file -> $backup_file"
        return 0
    else
        log_error "Failed to backup: $file"
        return 1
    fi
}

# Safe file write (atomic write with backup)
safe_write_file() {
    local file="$1"
    local content="$2"
    local backup="${3:-true}"
    
    # Backup existing file
    if [[ "$backup" == "true" && -f "$file" ]]; then
        backup_file "$file"
    fi
    
    # Write to temp file first
    local temp_file="${file}.tmp.$$"
    
    if echo "$content" > "$temp_file" 2>/dev/null; then
        # Move to final location (atomic operation)
        if mv "$temp_file" "$file" 2>/dev/null; then
            log_debug "Successfully wrote file: $file"
            return 0
        else
            log_error "Failed to move temp file to: $file"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to write temp file: $temp_file"
        return 1
    fi
}

# =============================================================================
# CONFIGURATION HELPERS
# =============================================================================

# Load configuration files with override support
load_config_with_override() {
    local base_config="$1"
    local local_config="$2"
    
    # Source base config
    if [[ -f "$base_config" ]]; then
        source "$base_config"
        log_debug "Loaded base config: $base_config"
    else
        log_warning "Base config not found: $base_config"
        return 1
    fi
    
    # Source local override if exists
    if [[ -f "$local_config" ]]; then
        source "$local_config"
        log_debug "Loaded local config: $local_config"
    else
        log_debug "No local config found: $local_config"
    fi
    
    return 0
}

# Get config value with default
get_config_value() {
    local var_name="$1"
    local default_value="$2"
    
    local value="${!var_name}"
    
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

# Set config value in local config
set_config_value() {
    local var_name="$1"
    local value="$2"
    local config_file="$3"
    
    if [[ ! -f "$config_file" ]]; then
        touch "$config_file"
    fi
    
    # Check if variable exists
    if grep -q "^${var_name}=" "$config_file" 2>/dev/null; then
        # Update existing
        sed -i "s|^${var_name}=.*|${var_name}=\"${value}\"|" "$config_file"
    else
        # Add new
        echo "${var_name}=\"${value}\"" >> "$config_file"
    fi
    
    log_success "Updated config: ${var_name}=${value}"
}

# =============================================================================
# STRING UTILITIES
# =============================================================================

# Trim whitespace
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Convert to uppercase
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Convert to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Check if string contains substring
string_contains() {
    local string="$1"
    local substring="$2"
    [[ "$string" == *"$substring"* ]]
}

# =============================================================================
# ARRAY UTILITIES
# =============================================================================

# Check if array contains element
array_contains() {
    local element="$1"
    shift
    local array=("$@")
    
    for item in "${array[@]}"; do
        if [[ "$item" == "$element" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Join array elements with delimiter
array_join() {
    local delimiter="$1"
    shift
    local array=("$@")
    
    local result=""
    local first=true
    
    for item in "${array[@]}"; do
        if [[ "$first" == true ]]; then
            result="$item"
            first=false
        else
            result="${result}${delimiter}${item}"
        fi
    done
    
    echo "$result"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate yes/no input
validate_yes_no() {
    local input="$1"
    input=$(to_lower "$input")
    
    if [[ "$input" == "yes" || "$input" == "y" || "$input" == "true" || "$input" == "1" ]]; then
        return 0
    elif [[ "$input" == "no" || "$input" == "n" || "$input" == "false" || "$input" == "0" ]]; then
        return 1
    else
        return 2
    fi
}

# Validate port number
validate_port() {
    local port="$1"
    
    if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
        return 0
    else
        return 1
    fi
}

# Validate email address (basic)
validate_email() {
    local email="$1"
    
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# USER INTERACTION
# =============================================================================

# Ask yes/no question
ask_yes_no() {
    local question="$1"
    local default="${2:-}"
    
    local prompt="$question"
    if [[ "$default" == "yes" ]]; then
        prompt="$prompt [Y/n]: "
    elif [[ "$default" == "no" ]]; then
        prompt="$prompt [y/N]: "
    else
        prompt="$prompt [y/n]: "
    fi
    
    while true; do
        read -p "$prompt" response
        
        # Use default if empty
        if [[ -z "$response" && -n "$default" ]]; then
            response="$default"
        fi
        
        if validate_yes_no "$response"; then
            return 0
        elif validate_yes_no "$response"; then
            return 1
        else
            echo "Please answer yes or no."
        fi
    done
}

# Confirm action
confirm_action() {
    local action="$1"
    local warning="${2:-This action cannot be undone.}"
    
    echo
    log_warning "$warning"
    echo
    
    if ask_yes_no "Are you sure you want to $action?" "no"; then
        return 0
    else
        log_info "Action cancelled."
        return 1
    fi
}

# =============================================================================
# PROGRESS INDICATORS
# =============================================================================

# Simple spinner
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Show progress bar
progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\rProgress: ["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%%" "$percentage"
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

# Register cleanup function
register_cleanup() {
    trap "$1" EXIT INT TERM
}

# Standard cleanup
cleanup() {
    log_debug "Running cleanup..."
    # Add cleanup tasks here
}

# =============================================================================
# TIME UTILITIES
# =============================================================================

# Convert seconds to human readable format
seconds_to_human() {
    local seconds="$1"
    
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    elif [[ $seconds -lt 86400 ]]; then
        echo "$((seconds / 3600))h $(((seconds % 3600) / 60))m"
    else
        echo "$((seconds / 86400))d $(((seconds % 86400) / 3600))h"
    fi
}

# Get file age in seconds
get_file_age() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo "-1"
        return 1
    fi
    
    local now=$(date +%s)
    local mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
    echo $((now - mtime))
}

# =============================================================================
# NETWORK UTILITIES
# =============================================================================

# Check if port is open
is_port_open() {
    local host="${1:-localhost}"
    local port="$2"
    local timeout="${3:-2}"
    
    timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null
}

# Get public IP
get_public_ip() {
    curl -s https://api.ipify.org 2>/dev/null || \
    curl -s https://ifconfig.me 2>/dev/null || \
    echo "unknown"
}

# =============================================================================
# MARK LIBRARY AS LOADED
# =============================================================================
log_debug "nftban_utils.sh library loaded"