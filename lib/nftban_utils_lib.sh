#!/usr/bin/env bash

# =============================================================================
# NFTBAN Utilities Library - Common Functions
# Version: 0.9.2
# Location: lib/nftban_utils_lib.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# =============================================================================

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_UTILS_LOADED:-}" ]] && return 0
readonly NFTBAN_UTILS_LOADED=1

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
# LOGGING FUNCTIONS - REMOVED
# =============================================================================
# NOTE: All logging functions have been consolidated into nftban_core.sh
# Use nftban_log_*() functions instead of log_*() functions
# This ensures consistent logging across all modules

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
# CONFIGURATION HELPERS - REMOVED
# =============================================================================
# NOTE: All configuration functions have been consolidated into nftban_core.sh
# Use nftban_get_config(), nftban_set_config(), nftban_load_config() instead
# This ensures consistent config management across all modules

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

# BUG49 FIX: Validate jail/template names to prevent path traversal
# Only allow alphanumeric, underscore, hyphen - no path separators
validate_safe_name() {
    local name="$1"
    local max_length="${2:-64}"

    # Empty check
    if [[ -z "$name" ]]; then
        return 1
    fi

    # Length check
    if [[ ${#name} -gt $max_length ]]; then
        return 1
    fi

    # Only allow: alphanumeric, underscore, hyphen
    # This prevents: ../ ./ / \ and other path traversal
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi

    # Prevent reserved names
    case "$name" in
        .|..|/*|*/*|*\\*|~/*|*..*)
            return 1
            ;;
    esac

    return 0
}

# Validate and sanitize jail name
validate_jail_name() {
    local name="$1"

    if ! validate_safe_name "$name" 64; then
        log_error "Invalid jail name: '$name' (must be alphanumeric with _ or -, max 64 chars)"
        return 1
    fi

    echo "$name"
    return 0
}

# Validate and sanitize template name
validate_template_name() {
    local name="$1"

    if ! validate_safe_name "$name" 64; then
        log_error "Invalid template name: '$name' (must be alphanumeric with _ or -, max 64 chars)"
        return 1
    fi

    echo "$name"
    return 0
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

# BUG53 FIX: Safe curl wrapper with security hardening
# Prevents common vulnerabilities in curl usage
safe_curl() {
    curl --fail-with-body \
         --proto '=https' \
         --tlsv1.2 \
         --retry 2 \
         --retry-delay 2 \
         --connect-timeout 10 \
         --max-time 30 \
         --silent \
         --show-error \
         "$@"
}

# Check if port is open
is_port_open() {
    local host="${1:-localhost}"
    local port="$2"
    local timeout="${3:-2}"

    timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null
}

# Get public IP
get_public_ip() {
    safe_curl https://api.ipify.org 2>/dev/null || \
    safe_curl https://ifconfig.me 2>/dev/null || \
    echo "unknown"
}

# =============================================================================
# MARK LIBRARY AS LOADED
# =============================================================================
log_debug "nftban_utils.sh library loaded"