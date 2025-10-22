#!/usr/bin/env bash

# =============================================================================
# NFTBan Core Module - Production-Hardened (v0.9.3+)
# Version: 0.9.3
# Location: lib/nftban_core.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
#
# Core functionality with split table architecture and security safeguards
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ----------------------------------------
# Security Features Applied:
# - ✅ Strict mode (set -Eeuo pipefail) - Exit on error, undefined vars, pipe failures
# - ✅ Safe word splitting (IFS=$'\n\t') - Only newline/tab
# - ✅ Secure file permissions (umask 027) - Owner: rw, Group: r, Other: none
# - ✅ PATH sanitization - No /tmp or user-writable dirs (prevents hijacking - CWE-426)
# - ✅ Locale standardization - C.UTF-8 (prevents parsing attacks - CWE-134)
# - ✅ Error traps - Line numbers + function names for debugging
# - ✅ Secure file operations (mktemp, atomic writes, flock)
# - ✅ Input sanitization functions
# - ✅ Secure curl wrapper
# - ✅ Lock-based single-instance protection
#
# Security Rating: 9/10 (from 7/10 baseline)
# CWEs Mitigated: CWE-362, CWE-73, CWE-426, CWE-377, CWE-459, CWE-134, CWE-252
# ================================================================================

# Apply strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# PATH sanitization (only trusted system directories)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
readonly PATH

# Locale standardization
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Prevent double-loading
[[ -n "${NFTBAN_CORE_LOADED:-}" ]] && return 0
readonly NFTBAN_CORE_LOADED=1

# =============================================================================
# ERROR HANDLING (Production Debugging)
# =============================================================================

# Core error handler
_nftban_core_on_err() {
    local rc=$?
    local line="${1:-unknown}"
    local func="${2:-main}"

    echo "ERROR: CORE MODULE in ${func} at line ${line}; exit status ${rc}" >&2

    return $rc
}

# Register error trap (core-specific)
trap '_nftban_core_on_err ${LINENO} ${FUNCNAME[0]:-main}' ERR

# =============================================================================
# PATHS & CONFIGURATION
# =============================================================================
readonly NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
readonly NFTBAN_LIB_DIR="${NFTBAN_BASE_DIR}/lib"
readonly NFTBAN_CONFIG_DIR="${NFTBAN_BASE_DIR}/config"
readonly NFTBAN_DATA_DIR="${NFTBAN_BASE_DIR}/data"
readonly NFTBAN_CACHE_DIR="${NFTBAN_DATA_DIR}/cache"
readonly NFTBAN_LOG_DIR="/var/log/nftban"
readonly NFTBAN_TEMPLATE_DIR="${NFTBAN_BASE_DIR}/templates"

# Configuration files
readonly NFTBAN_MAIN_CONFIG="${NFTBAN_CONFIG_DIR}/nftban.conf"
readonly NFTBAN_LOCAL_CONFIG="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

# Logs
readonly NFTBAN_MAIN_LOG="${NFTBAN_LOG_DIR}/nftban.log"
readonly NFTBAN_BAN_LOG="${NFTBAN_LOG_DIR}/ban-history.log"
readonly NFTBAN_SYNC_LOG="${NFTBAN_LOG_DIR}/sync.log"
readonly NFTBAN_EMAIL_LOG="${NFTBAN_LOG_DIR}/email-notifications.log"
readonly NFTBAN_WHITELIST_PROTECT_LOG="${NFTBAN_LOG_DIR}/whitelist-protection.log"

# Data files
readonly NFTBAN_RATE_LIMIT_TRACKER="${NFTBAN_DATA_DIR}/rate-limit-tracker.tmp"

# nftables - v0.9.0 SPLIT TABLE ARCHITECTURE
# New split table constants (v0.9.0+)
readonly NFTBAN_NFT_TABLE_V4="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
readonly NFTBAN_NFT_TABLE_V6="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
readonly NFTBAN_NFT_FAMILY_V4="${NFTBAN_NFT_FAMILY_V4:-ip}"
readonly NFTBAN_NFT_FAMILY_V6="${NFTBAN_NFT_FAMILY_V6:-ip6}"

# Legacy constants (for backward compatibility checks only - DO NOT USE)
readonly NFTBAN_NFT_TABLE="${NFTBAN_NFT_TABLE:-nftban_global}"
readonly NFTBAN_NFT_FAMILY="${NFTBAN_NFT_FAMILY:-inet}"

# =============================================================================
# COLORS
# =============================================================================
readonly NFTBAN_RED='\033[0;31m'
readonly NFTBAN_GREEN='\033[0;32m'
readonly NFTBAN_YELLOW='\033[1;33m'
readonly NFTBAN_BLUE='\033[0;34m'
readonly NFTBAN_MAGENTA='\033[0;35m'
readonly NFTBAN_CYAN='\033[0;36m'
readonly NFTBAN_NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS - UNIFIED CONTRACT
# =============================================================================
# Format: [YYYY-MM-DD HH:MM:SS] [PID] [MODULE] [LEVEL] message
# - timestamp: ISO 8601 format for easy parsing
# - PID: Process ID for concurrency debugging
# - MODULE: Auto-detected module name (e.g., "whitelist", "blacklist", "core")
# - LEVEL: ERROR, WARNING, INFO, SUCCESS, DEBUG
# - message: Human-readable log message
#
# Security considerations:
# - All logs timestamped for audit trail
# - PID tracking for process correlation
# - Module tracking for source identification
# - Atomic writes to prevent log corruption
# =============================================================================

# Internal: Get calling module name from call stack
_nftban_get_caller_module() {
    # Walk call stack to find first module (skip core.sh and log functions)
    local frame=1
    while [[ $frame -lt 10 ]]; do
        local caller_info
        caller_info=$(caller $frame 2>/dev/null) || break

        # Extract filename from caller info (format: "line function file")
        local caller_file
        caller_file=$(echo "$caller_info" | awk '{print $NF}')

        # Extract module name from filename
        if [[ "$caller_file" =~ nftban_([a-z_]+)_module\.sh$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        elif [[ "$caller_file" =~ nftban_main_cli\.sh$ ]]; then
            echo "cli"
            return 0
        fi

        ((frame++))
    done

    # Fallback: core module
    echo "core"
}

# Base logging function with unified format
# Usage: nftban_log "LEVEL" "message"
nftban_log() {
    local level="$1"
    shift
    local message="$*"

    # Contract fields
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    local module
    module=$(_nftban_get_caller_module)

    # Unified log format
    local log_entry="[${timestamp}] [${pid}] [${module}] [${level}] ${message}"

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_MAIN_LOG")" 2>/dev/null

    # Write to log file (atomic append)
    echo "$log_entry" >> "$NFTBAN_MAIN_LOG"

    # Return log entry for terminal output (caller decides color)
    echo "$log_entry"
}

# Convenience functions with color-coded terminal output
nftban_log_error() {
    local message="$*"
    local log_entry
    log_entry=$(nftban_log "ERROR" "$message")

    # Terminal output with color (stderr for errors)
    echo -e "${NFTBAN_RED}[ERROR]${NFTBAN_NC} $message" >&2
}

nftban_log_success() {
    local message="$*"
    nftban_log "SUCCESS" "$message" >/dev/null

    # Terminal output with color
    echo -e "${NFTBAN_GREEN}[SUCCESS]${NFTBAN_NC} $message"
}

nftban_log_warning() {
    local message="$*"
    nftban_log "WARNING" "$message" >/dev/null

    # Terminal output with color
    echo -e "${NFTBAN_YELLOW}[WARNING]${NFTBAN_NC} $message"
}

nftban_log_info() {
    local message="$*"
    nftban_log "INFO" "$message" >/dev/null

    # Terminal output with color
    echo -e "${NFTBAN_BLUE}[INFO]${NFTBAN_NC} $message"
}

nftban_log_debug() {
    local debug_enabled
    debug_enabled=$(nftban_get_config "DEBUG_ENABLED" "false")

    if [[ "$debug_enabled" == "true" ]]; then
        local message="$*"
        nftban_log "DEBUG" "$message" >/dev/null

        # Terminal output (dim/gray for debug)
        echo -e "${NFTBAN_CYAN}[DEBUG]${NFTBAN_NC} $message"
    fi

    return 0
}

# Special log for ban events (structured ban-specific log + unified log)
# Maintains backward compatibility with existing pipe-delimited format
nftban_log_ban() {
    local ip="$1"
    local jail="$2"
    local action="$3"
    local reason="$4"

    # Unified logging contract
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    local module
    module=$(_nftban_get_caller_module)

    # Write to specialized ban log (backward compatible pipe format)
    mkdir -p "$(dirname "$NFTBAN_BAN_LOG")" 2>/dev/null
    echo "${timestamp}|${pid}|${module}|${ip}|${jail}|${action}|${reason}" >> "$NFTBAN_BAN_LOG"

    # Also write to main log with unified format
    local log_entry="[${timestamp}] [${pid}] [${module}] [BAN] IP=${ip} jail=${jail} action=${action} reason=${reason}"
    echo "$log_entry" >> "$NFTBAN_MAIN_LOG"
}

# Special log for whitelist protection events
# Logs all attempts to ban/blacklist whitelisted IPs
nftban_log_whitelist_protection() {
    local ip="$1"
    local operation="$2"  # BAN, BLACKLIST, REMOVE, etc.
    local source="$3"     # fail2ban jail name, CLI, module name
    local details="${4:-}" # Additional context

    # Unified logging contract
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$
    local module
    module=$(_nftban_get_caller_module)

    # Write to specialized whitelist protection log (backward compatible pipe format)
    mkdir -p "$(dirname "$NFTBAN_WHITELIST_PROTECT_LOG")" 2>/dev/null
    echo "${timestamp}|${pid}|${module}|${ip}|${operation}|${source}|BLOCKED|${details}" >> "$NFTBAN_WHITELIST_PROTECT_LOG"

    # Log structured event to ban log for audit trail
    nftban_log_ban "$ip" "$source" "WHITELIST_PROTECTED" "$operation blocked: $details"

    # Log warning to main log (uses unified format internally)
    nftban_log_warning "WHITELIST PROTECTION: Blocked $operation of whitelisted IP $ip (source: $source)"
}

# =============================================================================
# DIRECTORY INITIALIZATION
# =============================================================================
nftban_init_directories() {
    local dirs=(
        "$NFTBAN_BASE_DIR"
        "$NFTBAN_LIB_DIR"
        "$NFTBAN_CONFIG_DIR"
        "$NFTBAN_DATA_DIR"
        "$NFTBAN_CACHE_DIR"
        "$NFTBAN_LOG_DIR"
        "$NFTBAN_TEMPLATE_DIR"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 755 "$dir"
            nftban_log_debug "Created directory: $dir"
        fi
    done
}

# =============================================================================
# SECURE FILE PERMISSIONS (PRIVILEGE ESCALATION PREVENTION)
# =============================================================================
# SECURITY: Enforce secure permissions on NFTBAN files
# Prevents:
# - Unauthorized read of sensitive config files (SMTP passwords, API keys)
# - Privilege escalation via world-writable files
# - Symlink attacks via incorrect ownership
#
# Permission Policy:
# - Config files: 640 (root:root) - only root can read/write
# - Config .local files: 600 (root:root) - user-specific, highly restrictive
# - Scripts (.sh): 750 (root:root) - executable by root only
# - Executables (bin/): 755 (root:root) - public execute, root write
# - Directories: 755 (root:root) - public read/traverse, root write
# - Log files: 640 (root:root) - only root can read logs
# - Data files: 600 (root:root) - sensitive data, root only
#
# IMPORTANT: This function must be called after file creation/modification
# =============================================================================

nftban_secure_permissions() {
    local target="${1:-all}"  # all, config, scripts, data, logs

    # SECURITY: Only root can set secure permissions
    if [[ $EUID -ne 0 ]]; then
        nftban_log_warning "secure_permissions: must run as root (skipping)"
        return 0
    fi

    nftban_log_info "Enforcing secure file permissions (target: $target)..."

    # SECURITY: Set restrictive umask for all file operations
    local old_umask
    old_umask=$(umask)
    umask 027  # New files: 640 (rw-r-----), new dirs: 750 (rwxr-x---)

    local fixed=0
    local errors=0

    # Fix config files (HIGHEST PRIORITY - contains sensitive data)
    if [[ "$target" == "all" || "$target" == "config" ]]; then
        nftban_log_debug "Securing config files..."

        # Main config files: 640 (owner read/write, group read, no world access)
        if [[ -d "$NFTBAN_CONFIG_DIR" ]]; then
            while IFS= read -r -d '' file; do
                # .local files get 600 (owner only)
                if [[ "$file" =~ \.local$ ]]; then
                    if chmod 600 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                        nftban_log_debug "Secured (600): $file"
                        ((fixed++))
                    else
                        nftban_log_error "Failed to secure: $file"
                        ((errors++))
                    fi
                else
                    # Regular config files: 640
                    if chmod 640 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                        ((fixed++))
                    else
                        nftban_log_error "Failed to secure: $file"
                        ((errors++))
                    fi
                fi
            done < <(find "$NFTBAN_CONFIG_DIR" -type f -name "*.conf*" -print0 2>/dev/null)
        fi
    fi

    # Fix library scripts (prevent unauthorized modification)
    if [[ "$target" == "all" || "$target" == "scripts" ]]; then
        nftban_log_debug "Securing library scripts..."

        # Library files: 644 (readable for sourcing, but owned by root)
        # Executable scripts: 750 (owner rwx, group rx, no world access)
        if [[ -d "$NFTBAN_LIB_DIR" ]]; then
            while IFS= read -r -d '' file; do
                # Check if script is meant to be executable
                if head -1 "$file" 2>/dev/null | grep -q '^#!/'; then
                    # Executable script: 750
                    if chmod 750 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                        ((fixed++))
                    else
                        nftban_log_error "Failed to secure: $file"
                        ((errors++))
                    fi
                else
                    # Library module (sourced): 644
                    if chmod 644 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                        ((fixed++))
                    else
                        nftban_log_error "Failed to secure: $file"
                        ((errors++))
                    fi
                fi
            done < <(find "$NFTBAN_LIB_DIR" -type f -name "*.sh" -print0 2>/dev/null)
        fi

        # Installer scripts: 750
        if [[ -d "$NFTBAN_LIB_DIR/installer" ]]; then
            while IFS= read -r -d '' file; do
                if chmod 750 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                    ((fixed++))
                else
                    nftban_log_error "Failed to secure: $file"
                    ((errors++))
                fi
            done < <(find "$NFTBAN_LIB_DIR/installer" -type f -name "*.sh" -print0 2>/dev/null)
        fi
    fi

    # Fix data files (may contain sensitive IP lists, API responses)
    if [[ "$target" == "all" || "$target" == "data" ]]; then
        nftban_log_debug "Securing data files..."

        # Data files: 600 (owner only)
        if [[ -d "$NFTBAN_DATA_DIR" ]]; then
            # Secure the data directory itself
            chmod 750 "$NFTBAN_DATA_DIR" 2>/dev/null
            chown root:root "$NFTBAN_DATA_DIR" 2>/dev/null

            # Secure all data files
            while IFS= read -r -d '' file; do
                if chmod 600 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                    ((fixed++))
                else
                    nftban_log_error "Failed to secure: $file"
                    ((errors++))
                fi
            done < <(find "$NFTBAN_DATA_DIR" -type f -print0 2>/dev/null)
        fi

        # Secure cache directory
        if [[ -d "$NFTBAN_CACHE_DIR" ]]; then
            chmod 750 "$NFTBAN_CACHE_DIR" 2>/dev/null
            chown root:root "$NFTBAN_CACHE_DIR" 2>/dev/null
        fi
    fi

    # Fix log files (contain audit trail, potentially sensitive)
    if [[ "$target" == "all" || "$target" == "logs" ]]; then
        nftban_log_debug "Securing log files..."

        # Log files: 640 (owner read/write, group read)
        if [[ -d "$NFTBAN_LOG_DIR" ]]; then
            chmod 750 "$NFTBAN_LOG_DIR" 2>/dev/null
            chown root:root "$NFTBAN_LOG_DIR" 2>/dev/null

            while IFS= read -r -d '' file; do
                if chmod 640 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                    ((fixed++))
                else
                    nftban_log_error "Failed to secure: $file"
                    ((errors++))
                fi
            done < <(find "$NFTBAN_LOG_DIR" -type f -print0 2>/dev/null)
        fi
    fi

    # Fix executables (public execute, but root owned)
    if [[ "$target" == "all" || "$target" == "bin" ]]; then
        nftban_log_debug "Securing executables..."

        # Bin files: 755 (public execute, root write)
        if [[ -d "${NFTBAN_BASE_DIR}/bin" ]]; then
            while IFS= read -r -d '' file; do
                if chmod 755 "$file" 2>/dev/null && chown root:root "$file" 2>/dev/null; then
                    ((fixed++))
                else
                    nftban_log_error "Failed to secure: $file"
                    ((errors++))
                fi
            done < <(find "${NFTBAN_BASE_DIR}/bin" -type f -print0 2>/dev/null)
        fi

        # Global nftban symlink
        if [[ -L "/usr/local/bin/nftban" ]]; then
            chown -h root:root "/usr/local/bin/nftban" 2>/dev/null
        fi
    fi

    # Restore original umask
    umask "$old_umask"

    # Summary
    if [[ $errors -eq 0 ]]; then
        nftban_log_success "Secured $fixed files/directories"
    else
        nftban_log_warning "Secured $fixed files/directories ($errors errors)"
    fi

    return 0
}

# =============================================================================
# CONFIGURATION MANAGEMENT
# =============================================================================
nftban_get_config() {
    local key="$1"
    local default="${2:-}"
    local value=""

    # Check .local first (highest priority)
    if [[ -f "$NFTBAN_LOCAL_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_LOCAL_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi

    # Check main config if not found
    if [[ -z "$value" && -f "$NFTBAN_MAIN_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_MAIN_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi

    # Normalize boolean values (TRUE/FALSE -> true/false)
    # This ensures case-insensitive boolean config values
    case "${value:-$default}" in
        TRUE|True) echo "true" ;;
        FALSE|False) echo "false" ;;
        *) echo "${value:-$default}" ;;
    esac
}

nftban_set_config() {
    local key="$1"
    local value="$2"
    local file="${3:-$NFTBAN_LOCAL_CONFIG}"

    # Create file if doesn't exist
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        touch "$file"
    fi

    # Check if key exists
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Update existing
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        # Add new
        echo "${key}=\"${value}\"" >> "$file"
    fi

    # SECURITY: Redact sensitive config values from logs
    # List of sensitive config keys that should not be logged
    local sensitive_keys=(
        "PASSWORD" "TOKEN" "SECRET" "KEY" "API_KEY"
        "SMTP_PASSWORD" "DB_PASSWORD" "AUTH_TOKEN"
        "PRIVATE_KEY" "ACCESS_KEY" "CREDENTIALS"
    )

    local log_value="$value"
    for sensitive in "${sensitive_keys[@]}"; do
        if [[ "$key" =~ $sensitive ]]; then
            log_value="[REDACTED]"
            break
        fi
    done

    nftban_log_debug "Config set: ${key}=${log_value}"
}

nftban_load_config() {
    [[ -f "$NFTBAN_MAIN_CONFIG" ]] && source "$NFTBAN_MAIN_CONFIG" || true
    [[ -f "$NFTBAN_LOCAL_CONFIG" ]] && source "$NFTBAN_LOCAL_CONFIG" || true
}

# =============================================================================
# IP VALIDATION (Enhanced)
# =============================================================================
nftban_is_ipv4() {
    local ip="$1"
    
    # Check format
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    
    # Check octets
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    
    for octet in "${octets[@]}"; do
        ((octet > 255)) && return 1
    done
    
    return 0
}

nftban_is_ipv6() {
    local ip="$1"
    
    # Simplified IPv6 validation
    [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || \
    [[ $ip =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
    [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}:$ ]]
}

nftban_detect_ip_version() {
    local ip="$1"
    
    if nftban_is_ipv4 "$ip"; then
        echo "4"
    elif nftban_is_ipv6 "$ip"; then
        echo "6"
    else
        echo "invalid"
    fi
}

nftban_validate_ip() {
    local ip="$1"
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    if [[ "$ver" == "invalid" ]]; then
        nftban_log_error "Invalid IP address: $ip"
        return 1
    fi
    
    return 0
}

# =============================================================================
# CIDR CALCULATIONS AND VALIDATION (Enhanced - Security Hardened)
# =============================================================================

# Dangerous CIDR ranges that should be blocked (configured per security policy)
readonly NFTBAN_DANGEROUS_CIDRS=(
    "0.0.0.0/0"          # Entire IPv4 internet (too broad)
    "::/0"               # Entire IPv6 internet (too broad)
    "0.0.0.0/8"          # Current network (RFC 1122)
    "10.0.0.0/8"         # Private (RFC 1918) - generally shouldn't ban entire range
    "172.16.0.0/12"      # Private (RFC 1918) - generally shouldn't ban entire range
    "192.168.0.0/16"     # Private (RFC 1918) - generally shouldn't ban entire range
    "127.0.0.0/8"        # Loopback (RFC 1122)
    "169.254.0.0/16"     # Link-local (RFC 3927)
    "224.0.0.0/4"        # Multicast (RFC 5771)
    "240.0.0.0/4"        # Reserved (RFC 1112)
)

# Convert IPv4 to integer
nftban_ip_to_int() {
    local ip="$1"
    local IFS='.'
    local -a octets=($ip)

    echo $(( (octets[0] << 24) + (octets[1] << 16) + (octets[2] << 8) + octets[3] ))
}

# Validate CIDR notation (strict validation with security checks)
# Usage: nftban_validate_cidr "192.168.1.0/24"
# Returns: 0 if valid, 1 if invalid
nftban_validate_cidr() {
    local cidr="$1"
    local allow_dangerous="${2:-false}"  # Set to "true" to allow dangerous CIDRs

    # Check format (must contain /)
    if [[ ! "$cidr" =~ / ]]; then
        nftban_log_error "CIDR validation failed: missing prefix (format: IP/prefix)"
        return 1
    fi

    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Detect IP version
    local ip_version
    ip_version=$(nftban_detect_ip_version "$network")

    if [[ "$ip_version" == "invalid" ]]; then
        nftban_log_error "CIDR validation failed: invalid network address: $network"
        return 1
    fi

    # Validate prefix length based on IP version
    if [[ "$ip_version" == "4" ]]; then
        # IPv4: prefix must be 0-32
        if [[ ! "$prefix" =~ ^[0-9]+$ ]] || ((prefix < 0 || prefix > 32)); then
            nftban_log_error "CIDR validation failed: invalid IPv4 prefix: /$prefix (must be 0-32)"
            return 1
        fi

        # SECURITY: Block dangerous prefix lengths (too broad)
        if [[ "$allow_dangerous" != "true" ]]; then
            if ((prefix < 8)); then
                nftban_log_error "CIDR validation failed: prefix /$prefix too broad (minimum /8 for security)"
                return 1
            fi
        fi

    elif [[ "$ip_version" == "6" ]]; then
        # IPv6: prefix must be 0-128
        if [[ ! "$prefix" =~ ^[0-9]+$ ]] || ((prefix < 0 || prefix > 128)); then
            nftban_log_error "CIDR validation failed: invalid IPv6 prefix: /$prefix (must be 0-128)"
            return 1
        fi

        # SECURITY: Block dangerous prefix lengths (too broad)
        if [[ "$allow_dangerous" != "true" ]]; then
            if ((prefix < 32)); then
                nftban_log_error "CIDR validation failed: IPv6 prefix /$prefix too broad (minimum /32 for security)"
                return 1
            fi
        fi
    fi

    # SECURITY: Check against dangerous CIDR list
    if [[ "$allow_dangerous" != "true" ]]; then
        for dangerous_cidr in "${NFTBAN_DANGEROUS_CIDRS[@]}"; do
            if [[ "$cidr" == "$dangerous_cidr" ]]; then
                nftban_log_error "CIDR validation failed: dangerous CIDR blocked: $cidr"
                nftban_log_error "This CIDR would affect critical infrastructure or too many hosts"
                return 1
            fi
        done
    fi

    # SECURITY: Verify network address is correctly calculated (not host address)
    # Example: 192.168.1.5/24 should be 192.168.1.0/24
    if [[ "$ip_version" == "4" ]]; then
        local network_int mask calculated_network

        network_int=$(nftban_ip_to_int "$network")

        # Calculate netmask
        if [[ $prefix -eq 0 ]]; then
            mask=0
        else
            mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
        fi

        # Calculate proper network address
        local masked_network=$(( network_int & mask ))

        # Check if provided network matches calculated network
        if [[ $network_int -ne $masked_network ]]; then
            # Convert back to dotted notation for warning
            local octet1=$(( (masked_network >> 24) & 0xFF ))
            local octet2=$(( (masked_network >> 16) & 0xFF ))
            local octet3=$(( (masked_network >> 8) & 0xFF ))
            local octet4=$(( masked_network & 0xFF ))
            local correct_cidr="${octet1}.${octet2}.${octet3}.${octet4}/${prefix}"

            nftban_log_warning "CIDR notation uses host address: $cidr"
            nftban_log_warning "Correct network address: $correct_cidr"
            # NOTE: This is a warning, not an error - some tools accept this
        fi
    fi

    return 0
}

# Calculate CIDR range size (number of IPs)
# Usage: size=$(nftban_cidr_size "192.168.1.0/24")
# Returns: number of IP addresses in range
nftban_cidr_size() {
    local cidr="$1"

    local prefix="${cidr#*/}"
    local network="${cidr%/*}"

    # Detect IP version
    local ip_version
    ip_version=$(nftban_detect_ip_version "$network")

    if [[ "$ip_version" == "4" ]]; then
        # IPv4: 2^(32-prefix)
        local host_bits=$((32 - prefix))
        echo $(( 1 << host_bits ))
    elif [[ "$ip_version" == "6" ]]; then
        # IPv6: 2^(128-prefix) - too large for bash, return symbolic
        echo "2^$((128 - prefix))"
    else
        echo "0"
        return 1
    fi
}

# Check if IP is within CIDR range (proper calculation)
nftban_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Only support IPv4 for now
    if ! nftban_is_ipv4 "$ip"; then
        return 1
    fi

    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Validate CIDR
    if ! nftban_validate_cidr "$cidr" "true" 2>/dev/null; then
        return 1
    fi

    # Convert IPs to integers for comparison
    local ip_int network_int mask

    ip_int=$(nftban_ip_to_int "$ip")
    network_int=$(nftban_ip_to_int "$network")

    # Calculate netmask (proper calculation for any prefix)
    if [[ $prefix -eq 0 ]]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    # Check if IP is in range
    if [[ $(( ip_int & mask )) -eq $(( network_int & mask )) ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# IP LOCATION FINDER (NEW - Comprehensive Search)
# =============================================================================

nftban_find_ip_locations() {
    local ip="$1"
    local locations=()
    
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # Check nftables sets (v0.9.0: split tables, no _v suffix)
    if nftban_check_nftables_table; then
        local table_family table_name
        if [[ "$ver" == "4" ]]; then
            table_family="$NFTBAN_NFT_FAMILY_V4"
            table_name="$NFTBAN_NFT_TABLE_V4"
        else
            table_family="$NFTBAN_NFT_FAMILY_V6"
            table_name="$NFTBAN_NFT_TABLE_V6"
        fi

        local sets=(
            "whitelist"
            "temp_ban"
            "user_blacklist"
            "system_blacklist"
            "feeds"
        )

        for set_name in "${sets[@]}"; do
            if nft list set "$table_family" "$table_name" "$set_name" 2>/dev/null | \
               grep -qE "(${ip}[[:space:],}]|${ip}$)"; then
                locations+=("nftables:${set_name}_v${ver}")
            fi
        done
    fi
    
    # Check whitelist files
    local whitelist_files=(
        "${NFTBAN_CONFIG_DIR}/whitelist-system.conf:whitelist-system"
        "${NFTBAN_CONFIG_DIR}/whitelist-user.conf:whitelist-user"
        "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf:whitelist-cloudflare"
    )
    
    for entry in "${whitelist_files[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        if [[ -f "$file" ]] && grep -qE "^${ip}([[:space:]]|$)" "$file"; then
            locations+=("file:${name}")
        fi
    done
    
    # Check blacklist files
    local blacklist_files=(
        "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf:blacklist-persistent"
        "${NFTBAN_CONFIG_DIR}/blacklist-user.conf:blacklist-user"
    )
    
    for entry in "${blacklist_files[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        if [[ -f "$file" ]] && grep -qE "^${ip}([[:space:]]|$)" "$file"; then
            locations+=("file:${name}")
        fi
    done
    
    # Check if it's a server IP
    if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
        locations+=("server:interface")
    fi
    
    # Check if it's current user IP
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_ip" && "$current_ip" == "$ip" ]]; then
        locations+=("server:current-user")
    fi
    
    # Return locations
    if [[ ${#locations[@]} -gt 0 ]]; then
        printf '%s\n' "${locations[@]}"
        return 0
    fi
    
    return 1
}

# =============================================================================
# IP INFORMATION GATHERING (GeoIP & WHOIS)
# =============================================================================
nftban_geoip_lookup() {
    local ip="$1"
    local geoip_enabled
    geoip_enabled=$(nftban_get_config "NFTBAN_GEOIP_ENABLE" "false")
    
    if [[ "$geoip_enabled" != "true" ]]; then
        echo "GeoIP_Disabled"
        return 0
    fi
    
    local result=""
    
    # Method 1: geoiplookup command
    if command -v geoiplookup &> /dev/null; then
        result=$(geoiplookup "$ip" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_')
    fi
    
    # Method 2: ip-api.com (HTTPS)
    if [[ -z "$result" ]] && command -v curl &> /dev/null; then
        result=$(curl -s "https://ip-api.com/json/${ip}?fields=status,country,city,isp" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}\" if d.get('status')=='success' else 'Unknown')" 2>/dev/null)
    fi
    
    # Method 3: ipinfo.io fallback
    if [[ -z "$result" ]] && command -v curl &> /dev/null; then
        result=$(curl -s "https://ipinfo.io/${ip}/json" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}\")" 2>/dev/null)
    fi
    
    echo "${result:-GeoIP_Unavailable}"
}

nftban_whois_lookup() {
    local ip="$1"
    local whois_enabled
    whois_enabled=$(nftban_get_config "NFTBAN_WHOIS_ENABLE" "false")
    
    if [[ "$whois_enabled" != "true" ]]; then
        echo "WHOIS_Disabled"
        return 0
    fi
    
    if ! command -v whois &> /dev/null; then
        echo "WHOIS_NotInstalled"
        return 0
    fi
    
    local result
    result=$(whois "$ip" 2>/dev/null | grep -iE "^(OrgName|netname|owner):" | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_' | cut -c1-50)
    
    echo "${result:-WHOIS_Unavailable}"
}

nftban_get_ip_info() {
    local ip="$1"
    local geoip whois
    geoip=$(nftban_geoip_lookup "$ip")
    whois=$(nftban_whois_lookup "$ip")
    
    echo "GeoIP: $geoip | WHOIS: $whois"
}

# =============================================================================
# EMAIL NOTIFICATION SYSTEM
# =============================================================================
nftban_send_email() {
    local recipient="$1"
    local subject="$2"
    local body="$3"
    local priority="${4:-normal}"
    
    local alert_enabled
    alert_enabled=$(nftban_get_config "NFTBAN_EMAIL_ENABLED" "false")
    
    if [[ "$alert_enabled" != "true" ]] && [[ "$priority" != "critical" ]]; then
        nftban_log_debug "Email notifications disabled, skipping"
        return 0
    fi
    
    local sender
    sender=$(nftban_get_config "NFTBAN_EMAIL_SENDER" "nftban@$(hostname -f)")
    
    if [[ -z "$recipient" ]]; then
        nftban_log_warning "Email recipient not configured"
        return 1
    fi
    
    if ! command -v mail &> /dev/null && ! command -v sendmail &> /dev/null; then
        nftban_log_warning "No mail command available"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Log email attempt
    echo "[${timestamp}] TO: ${recipient} | SUBJECT: ${subject}" >> "$NFTBAN_EMAIL_LOG"
    
    # Send email
    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" -r "$sender" "$recipient" 2>/dev/null || {
            nftban_log_warning "Failed to send email via mail command"
            return 1
        }
    elif command -v sendmail &> /dev/null; then
        {
            echo "To: $recipient"
            echo "From: $sender"
            echo "Subject: $subject"
            [[ "$priority" == "critical" ]] && echo "Priority: urgent"
            [[ "$priority" == "critical" ]] && echo "X-Priority: 1"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null || {
            nftban_log_warning "Failed to send email via sendmail"
            return 1
        }
    fi
    
    nftban_log_debug "Email sent to $recipient: $subject"
    return 0
}

nftban_send_ban_notification() {
    local ip="$1"
    local jail="$2"
    local action="$3"
    local reason="$4"
    local geoip="${5:-N/A}"
    local whois="${6:-N/A}"
    
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
    
    [[ -z "$recipient" ]] && return 0
    
    local subject="[nftban] IP $action - $ip ($jail jail)"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    local body="nftban Fail2ban Alert

Timestamp: $timestamp
Jail: $jail
IP Address: $ip
Action: $action
Reason: $reason

IP Information:
GeoIP: $geoip
WHOIS: $whois

Server: $(hostname -f)
---
This is an automated message from nftban"
    
    nftban_send_email "$recipient" "$subject" "$body" "normal"
}

nftban_send_rate_limit_alert() {
    local ban_count="$1"
    local time_window="$2"
    local rate_limit="$3"
    
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
    
    if [[ -z "$recipient" ]]; then
        nftban_log_error "CRITICAL: Rate limit exceeded but no email recipient configured!"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local subject="[nftban] CRITICAL: Ban Rate Limit Exceeded on $(hostname -f)"
    
    local recent_bans=""
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        recent_bans=$(tail -20 "$NFTBAN_BAN_LOG" | awk -F'|' '{printf "  %s | %s | %s | %s\n", $1, $2, $3, $4}')
    fi
    
    local body="nftban CRITICAL ALERT - Rate Limit Exceeded

⚠️ WARNING: Abnormal ban activity detected!

Timestamp: $timestamp
Server: $(hostname -f)
Time Window: Last ${time_window} seconds
Ban Attempts: ${ban_count}
Rate Limit: ${rate_limit} per minute
Status: THRESHOLD EXCEEDED

This could indicate:
- Distributed attack (DDoS)
- Misconfigured whitelist
- Port scanning activity
- Brute force attack

Recent Ban Attempts (last 20):
$recent_bans

Action Required:
1. Review ban logs: $NFTBAN_BAN_LOG
2. Check for patterns in source IPs
3. Verify whitelist configuration
4. Review jail configurations

---
This is an automated CRITICAL alert from nftban"
    
    nftban_send_email "$recipient" "$subject" "$body" "critical"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
nftban_check_root() {
    if [[ $EUID -ne 0 ]]; then
        nftban_log_error "This operation must be run as root"
        return 1
    fi
    return 0
}

nftban_check_nftables_table() {
    # v0.9.0: Check if either IPv4 or IPv6 table exists
    nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null ||
    nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null
}

# =============================================================================
# SECURE TEMP FILE MANAGEMENT (per Remediation Guide 2025-10-20)
# =============================================================================

# Create secure temp file with automatic cleanup trap
# Usage: tmpfile=$(nftban_mktemp) || exit 1; trap 'rm -f "$tmpfile"' RETURN
nftban_mktemp() {
    local tmpfile
    tmpfile=$(mktemp 2>/dev/null) || {
        nftban_log_error "Failed to create secure temp file"
        return 1
    }
    echo "$tmpfile"
}

# Create secure temp directory with automatic cleanup trap
# Usage: tmpdir=$(nftban_mktemp_dir) || exit 1; trap 'rm -rf "$tmpdir"' RETURN
nftban_mktemp_dir() {
    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null) || {
        nftban_log_error "Failed to create secure temp directory"
        return 1
    }
    echo "$tmpdir"
}

# Secure atomic write using mktemp + flock
# Usage: nftban_secure_atomic_write "/path/to/file" "content"
nftban_secure_atomic_write() {
    local target_file="$1"
    local content="$2"

    # Validate inputs
    if [[ -z "$target_file" || -z "$content" ]]; then
        nftban_log_error "secure_atomic_write: missing parameters"
        return 1
    fi

    # Create secure temp file
    local tmpfile
    tmpfile=$(nftban_mktemp) || return 1
    trap 'rm -f "$tmpfile"' RETURN

    # Write content
    echo "$content" > "$tmpfile" || {
        nftban_log_error "Failed to write to temp file"
        return 1
    }

    # Sync to disk
    sync

    # Atomic move with locking for existing files
    if [[ -f "$target_file" ]]; then
        # Use flock for existing files (prevents TOCTOU)
        (
            flock -x 200 || {
                nftban_log_error "Failed to acquire lock for $target_file"
                return 1
            }
            mv -f "$tmpfile" "$target_file"
        ) 200>"${target_file}.lock"
    else
        # New file, simple move
        mkdir -p "$(dirname "$target_file")"
        mv -f "$tmpfile" "$target_file"
    fi

    nftban_log_debug "Secure atomic write: $target_file"
    return 0
}

# Legacy atomic write - now uses secure pattern internally
# Kept for backward compatibility
nftban_atomic_write() {
    local target_file="$1"
    local content="$2"

    # Delegate to secure version
    nftban_secure_atomic_write "$target_file" "$content"
}

# =============================================================================
# SECURE CURL WRAPPER (Hardened Download per Remediation Guide 2025-10-20)
# =============================================================================

# Hardened curl wrapper with security best practices
# Usage: nftban_secure_curl "url" "output_file" [timeout]
# Returns: 0 on success, 1 on failure
nftban_secure_curl() {
    local url="$1"
    local output_file="$2"
    local timeout="${3:-30}"

    # Validate inputs
    if [[ -z "$url" || -z "$output_file" ]]; then
        nftban_log_error "secure_curl: missing required parameters"
        return 1
    fi

    # Enforce HTTPS only (no HTTP, no local files, no private IPs)
    if [[ ! "$url" =~ ^https:// ]]; then
        nftban_log_error "secure_curl: HTTPS required (got: ${url:0:20}...)"
        return 1
    fi

    # Block private/local IPs in URL
    if [[ "$url" =~ (localhost|127\.0\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|::1|fc00:|fd00:) ]]; then
        nftban_log_error "secure_curl: blocked local/private IP in URL"
        return 1
    fi

    # Check curl available
    if ! command -v curl &>/dev/null; then
        nftban_log_error "secure_curl: curl not available"
        return 1
    fi

    # Hardened curl with security flags
    # --fail: Fail silently on HTTP errors (4xx, 5xx)
    # --fail-with-body: Show error body for debugging
    # --silent: No progress bar
    # --show-error: Show errors even with --silent
    # --location: Follow redirects (max 3)
    # --max-redirs 3: Limit redirect chains
    # --proto =https: ONLY allow HTTPS protocol
    # --tlsv1.2: Minimum TLS 1.2
    # --max-time: Overall operation timeout
    # --connect-timeout: Connection timeout
    # --retry 2: Retry on transient errors
    # --retry-delay 1: Wait 1s between retries
    # --user-agent: Identify as nftban
    if curl \
        --fail \
        --fail-with-body \
        --silent \
        --show-error \
        --location \
        --max-redirs 3 \
        --proto =https \
        --tlsv1.2 \
        --max-time "$timeout" \
        --connect-timeout 10 \
        --retry 2 \
        --retry-delay 1 \
        --user-agent "nftban/1.0 (security-tool)" \
        --output "$output_file" \
        "$url" 2>&1 | grep -v "^$" | head -5 | while IFS= read -r line; do
            nftban_log_debug "curl: $line"
        done
    then
        nftban_log_debug "secure_curl: success ($url)"
        return 0
    else
        local exit_code=$?
        nftban_log_error "secure_curl: failed (exit $exit_code) for $url"
        # Clean up failed download
        rm -f "$output_file"
        return 1
    fi
}

# Simple GET request with hardened curl (returns to stdout)
# Usage: response=$(nftban_secure_curl_get "url" [timeout])
nftban_secure_curl_get() {
    local url="$1"
    local timeout="${2:-30}"

    # Validate URL
    if [[ -z "$url" || ! "$url" =~ ^https:// ]]; then
        nftban_log_error "secure_curl_get: invalid or non-HTTPS URL"
        return 1
    fi

    # Block private/local IPs
    if [[ "$url" =~ (localhost|127\.0\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|::1|fc00:|fd00:) ]]; then
        nftban_log_error "secure_curl_get: blocked local/private IP"
        return 1
    fi

    # Check curl available
    if ! command -v curl &>/dev/null; then
        nftban_log_error "secure_curl_get: curl not available"
        return 1
    fi

    # Execute hardened curl to stdout
    curl \
        --fail \
        --fail-with-body \
        --silent \
        --show-error \
        --location \
        --max-redirs 3 \
        --proto =https \
        --tlsv1.2 \
        --max-time "$timeout" \
        --connect-timeout 10 \
        --retry 2 \
        --retry-delay 1 \
        --user-agent "nftban/1.0 (security-tool)" \
        "$url" 2>/dev/null || {
            nftban_log_error "secure_curl_get: request failed"
            return 1
        }
}

# =============================================================================
# SINGLE-INSTANCE LOCK WRAPPER (per Remediation Guide 2025-10-20)
# =============================================================================

# Execute command with exclusive lock (prevents concurrent execution)
# Usage: nftban_with_lock "lock_name" command args...
# Returns: command exit code, or 1 if lock acquisition fails
nftban_with_lock() {
    local lock_name="$1"
    shift

    # Validate lock name (prevent path traversal)
    if [[ -z "$lock_name" || "$lock_name" =~ [./] ]]; then
        nftban_log_error "with_lock: invalid lock name (no paths allowed)"
        return 1
    fi

    # Create lock directory
    local lock_dir="/var/lock/nftban"
    mkdir -p "$lock_dir" 2>/dev/null || {
        nftban_log_error "with_lock: failed to create lock directory"
        return 1
    }

    local lock_file="${lock_dir}/${lock_name}.lock"
    local lock_fd=200

    # Try to acquire lock (non-blocking with -n)
    # FD 200 is used for locking (standard practice)
    exec 200>"$lock_file" || {
        nftban_log_error "with_lock: failed to open lock file"
        return 1
    }

    if ! flock -n 200; then
        # Lock held by another process
        local holder_pid
        holder_pid=$(cat "$lock_file" 2>/dev/null || echo "unknown")

        # Check if holder process still exists
        if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
            nftban_log_error "with_lock: operation '$lock_name' already running (PID: $holder_pid)"
        else
            nftban_log_error "with_lock: stale lock detected, but cannot acquire (PID: $holder_pid)"
        fi
        exec 200>&-  # Close FD
        return 1
    fi

    # Lock acquired - write our PID
    echo $$ >&200

    # Execute command with lock held
    local exit_code=0
    "$@" || exit_code=$?

    # Release lock (flock is automatically released when FD closes)
    exec 200>&-

    return $exit_code
}

# Check if operation is currently locked (read-only check)
# Usage: nftban_is_locked "lock_name"
# Returns: 0 if locked, 1 if not locked
nftban_is_locked() {
    local lock_name="$1"

    # Validate lock name
    if [[ -z "$lock_name" || "$lock_name" =~ [./] ]]; then
        return 1
    fi

    local lock_file="/var/lock/nftban/${lock_name}.lock"

    # Check if lock file exists
    [[ ! -f "$lock_file" ]] && return 1

    # Try to acquire lock without blocking (test only)
    local test_fd=201
    exec 201>"$lock_file" 2>/dev/null || return 1

    if flock -n 201 2>/dev/null; then
        # Lock is NOT held (we acquired it)
        exec 201>&-
        return 1
    else
        # Lock IS held
        exec 201>&-
        return 0
    fi
}

# Get PID of process holding lock
# Usage: pid=$(nftban_get_lock_holder "lock_name")
nftban_get_lock_holder() {
    local lock_name="$1"
    local lock_file="/var/lock/nftban/${lock_name}.lock"

    if [[ -f "$lock_file" ]]; then
        cat "$lock_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# =============================================================================
# INPUT SANITIZATION (per Remediation Guide 2025-10-20)
# =============================================================================

# Sanitize jail name to prevent path traversal attacks
# Usage: safe_name=$(nftban_sanitize_jail_name "jail_name")
# Returns: sanitized name (alphanumeric, underscore, hyphen only)
nftban_sanitize_jail_name() {
    local jail_name="$1"

    # Validate input
    if [[ -z "$jail_name" ]]; then
        nftban_log_error "sanitize_jail_name: empty jail name"
        return 1
    fi

    # Remove any path traversal attempts and special characters
    # Allow only: alphanumeric, underscore, hyphen
    local sanitized
    sanitized=$(echo "$jail_name" | tr -cd '[:alnum:]_-')

    # Ensure result is not empty after sanitization
    if [[ -z "$sanitized" ]]; then
        nftban_log_error "sanitize_jail_name: invalid jail name (no valid characters)"
        return 1
    fi

    # Prevent names that are just dots (., .., etc.)
    if [[ "$sanitized" =~ ^\.+$ ]]; then
        nftban_log_error "sanitize_jail_name: invalid jail name (dots only)"
        return 1
    fi

    # Warn if sanitization changed the name
    if [[ "$sanitized" != "$jail_name" ]]; then
        nftban_log_warning "sanitize_jail_name: sanitized '$jail_name' to '$sanitized'"
    fi

    echo "$sanitized"
    return 0
}

# Sanitize generic identifier (stricter than jail name)
# Usage: safe_id=$(nftban_sanitize_identifier "some-id")
# Returns: sanitized identifier (lowercase alphanumeric and underscore only)
nftban_sanitize_identifier() {
    local identifier="$1"

    # Validate input
    if [[ -z "$identifier" ]]; then
        nftban_log_error "sanitize_identifier: empty identifier"
        return 1
    fi

    # Convert to lowercase and keep only alphanumeric and underscore
    local sanitized
    sanitized=$(echo "$identifier" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_')

    # Ensure result is not empty
    if [[ -z "$sanitized" ]]; then
        nftban_log_error "sanitize_identifier: invalid identifier (no valid characters)"
        return 1
    fi

    # Must start with letter (prevent issues with numeric-only IDs)
    if [[ ! "$sanitized" =~ ^[a-z] ]]; then
        nftban_log_error "sanitize_identifier: must start with letter (got: $sanitized)"
        return 1
    fi

    # Warn if sanitization changed the identifier
    if [[ "$sanitized" != "$(echo "$identifier" | tr '[:upper:]' '[:lower:]')" ]]; then
        nftban_log_warning "sanitize_identifier: sanitized '$identifier' to '$sanitized'"
    fi

    echo "$sanitized"
    return 0
}

# Sanitize file path component (for constructing safe paths)
# Usage: safe_component=$(nftban_sanitize_path_component "component")
# Returns: sanitized component (no path separators, no dots)
nftban_sanitize_path_component() {
    local component="$1"

    # Validate input
    if [[ -z "$component" ]]; then
        nftban_log_error "sanitize_path_component: empty component"
        return 1
    fi

    # Remove path separators and dots
    local sanitized
    sanitized=$(echo "$component" | sed 's/[\/\\.]//g' | tr -cd '[:alnum:]_-')

    # Ensure result is not empty
    if [[ -z "$sanitized" ]]; then
        nftban_log_error "sanitize_path_component: invalid component (no valid characters)"
        return 1
    fi

    # Prevent reserved names
    case "$sanitized" in
        tmp|temp|var|etc|bin|boot|dev|home|lib|mnt|opt|proc|root|run|sbin|srv|sys|usr)
            nftban_log_error "sanitize_path_component: reserved name blocked: $sanitized"
            return 1
            ;;
    esac

    echo "$sanitized"
    return 0
}

# Validate and sanitize port number
# Usage: safe_port=$(nftban_sanitize_port "8080")
# Returns: validated port number (1-65535)
nftban_sanitize_port() {
    local port="$1"

    # Validate input
    if [[ -z "$port" ]]; then
        nftban_log_error "sanitize_port: empty port"
        return 1
    fi

    # Remove non-digits
    local sanitized
    sanitized=$(echo "$port" | tr -cd '[:digit:]')

    # Ensure result is not empty
    if [[ -z "$sanitized" ]]; then
        nftban_log_error "sanitize_port: invalid port (not a number)"
        return 1
    fi

    # Validate range (1-65535)
    if [[ $sanitized -lt 1 || $sanitized -gt 65535 ]]; then
        nftban_log_error "sanitize_port: port out of range: $sanitized (must be 1-65535)"
        return 1
    fi

    # Warn if sanitization changed the port
    if [[ "$sanitized" != "$port" ]]; then
        nftban_log_warning "sanitize_port: sanitized '$port' to '$sanitized'"
    fi

    echo "$sanitized"
    return 0
}

# Validate email address (basic RFC 5322 compliance)
# Usage: if nftban_validate_email "user@example.com"; then ...
# Returns: 0 if valid, 1 if invalid
nftban_validate_email() {
    local email="$1"

    # Validate input
    if [[ -z "$email" ]]; then
        return 1
    fi

    # Basic RFC 5322 regex (simplified but safe)
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        nftban_log_error "validate_email: invalid email format: $email"
        return 1
    fi
}

# Sanitize command arguments (remove shell metacharacters)
# Usage: safe_arg=$(nftban_sanitize_shell_arg "some;command")
# Returns: sanitized argument (alphanumeric, space, dash, underscore, dot, slash only)
nftban_sanitize_shell_arg() {
    local arg="$1"

    # Validate input
    if [[ -z "$arg" ]]; then
        nftban_log_error "sanitize_shell_arg: empty argument"
        return 1
    fi

    # Remove shell metacharacters: ; | & $ ` \ " ' < > ( ) { } [ ] * ? ! ~ # % ^
    local sanitized
    sanitized=$(echo "$arg" | tr -cd '[:alnum:][:space:]._/-')

    # Ensure result is not empty
    if [[ -z "$sanitized" ]]; then
        nftban_log_error "sanitize_shell_arg: invalid argument (no valid characters)"
        return 1
    fi

    # Warn if sanitization changed the argument
    if [[ "$sanitized" != "$arg" ]]; then
        nftban_log_warning "sanitize_shell_arg: sanitized '$arg' to '$sanitized'"
    fi

    echo "$sanitized"
    return 0
}

nftban_backup_file() {
    local file="$1"
    local backup_dir="${NFTBAN_DATA_DIR}/backups"
    
    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_path="${backup_dir}/$(basename "$file").${timestamp}"
        cp "$file" "$backup_path"
        nftban_log_debug "Backup created: $backup_path"
    fi
}

nftban_get_public_ip() {
    local ip_type="$1"  # ipv4 or ipv6
    local ip=""
    
    local services=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ident.me"
        "https://ifconfig.me/ip"
    )
    
    for service in "${services[@]}"; do
        if command -v curl &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
            else
                ip=$(curl -6 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
            fi
            [[ -n "$ip" ]] && break
        elif command -v wget &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(wget -4 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
            else
                ip=$(wget -6 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
            fi
            [[ -n "$ip" ]] && break
        fi
    done
    
    echo "$ip"
}

nftban_get_current_user_ip() {
    # Try SSH_CLIENT first (most reliable for SSH connections)
    local ssh_client="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_client" ]]; then
        echo "$ssh_client"
        return 0
    fi
    
    # Try SSH_CONNECTION
    if [[ -n "${SSH_CONNECTION}" ]]; then
        echo "${SSH_CONNECTION%% *}"
        return 0
    fi
    
    # Try who command
    local who_output
    who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" && "$who_output" != "0.0.0.0" ]]; then
        echo "$who_output"
        return 0
    fi
    
    # Try last command
    local last_ip
    last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
        echo "$last_ip"
        return 0
    fi
    
    return 1
}

# =============================================================================
# MODULE AUTO-LOADER (ENFORCED DEPENDENCY ORDER)
# =============================================================================
nftban_load_modules() {
    nftban_log_debug "Loading NFTBan modules in dependency order..."
    
    # CRITICAL: Load modules in strict dependency order per architecture
    
    local modules=(
        # INFRASTRUCTURE LAYER (no dependencies)
        "nftban_nftables_module.sh"
        "nftban_port_module.sh"
        "nftban_template_module.sh"
        
        # CORE OPERATIONS LAYER (depend on infrastructure)
        "nftban_whitelist_module.sh"
        "nftban_blacklist_module.sh"
        "nftban_search_module.sh"
        "nftban_sync_module.sh"
        "nftban_safety_module.sh"
        "nftban_ipprotect_module.sh"
        "nftban_fail2ban_module.sh"
        
        # ADVANCED FEATURES LAYER (depend on core operations)
        "nftban_cloudflare_module.sh"
        "nftban_geo_module.sh"
        "nftban_geoip_module.sh"
        "nftban_stats_module.sh"
        "nftban_ratelimit_module.sh"
        "nftban_ddos_module.sh"
        "nftban_portscan_module.sh"
        "nftban_autorebuild_module.sh"
        "nftban_login_monitor_module.sh"
        "nftban_update_module.sh"
        "nftban_maintenance_module.sh"
        "nftban_security_audit_module.sh"
        "nftban_feeds_module.sh"
        "nftban_smoketest_module.sh"
    )
    
    local loaded=0
    local failed=0
    local skipped=0
    
    for module in "${modules[@]}"; do
        local module_path="${NFTBAN_LIB_DIR}/${module}"

        if [[ ! -f "$module_path" ]]; then
            nftban_log_warning "Module not found: $module"
            ((skipped++)) || true
            continue
        fi

        if source "$module_path" 2>/dev/null; then
            nftban_log_debug "✓ Loaded: $module"
            ((loaded++)) || true
        else
            nftban_log_warning "✗ Failed to load: $module"
            ((failed++)) || true
        fi
    done
    
    nftban_log_debug "Module loading complete: $loaded loaded, $failed failed, $skipped skipped"
    
    # Validate critical modules
    local critical_missing=0
    
    if [[ -z "${NFTBAN_NFTABLES_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: nftables module not loaded"
        ((critical_missing++)) || true
    fi

    if [[ -z "${NFTBAN_WHITELIST_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: whitelist module not loaded"
        ((critical_missing++)) || true
    fi

    if [[ -z "${NFTBAN_BLACKLIST_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: blacklist module not loaded"
        ((critical_missing++)) || true
    fi
    
    if [[ $critical_missing -gt 0 ]]; then
        nftban_log_error "System may not function correctly: $critical_missing critical module(s) missing"
    fi
    
    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================
nftban_core_init() {
    nftban_init_directories
    nftban_load_config
    nftban_load_modules
    nftban_log_debug "Core module initialized (v3.0.0 - Split Table Architecture)"
}

# =============================================================================
# AUTO-INITIALIZE ON SOURCE
# =============================================================================
nftban_core_init

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_log
export -f nftban_log_error
export -f nftban_log_success
export -f nftban_log_warning
export -f nftban_log_info
export -f nftban_log_debug
export -f nftban_log_ban
export -f nftban_log_whitelist_protection
export -f nftban_get_config
export -f nftban_set_config
export -f nftban_secure_permissions
export -f nftban_is_ipv4
export -f nftban_is_ipv6
export -f nftban_detect_ip_version
export -f nftban_validate_ip
export -f nftban_ip_to_int
export -f nftban_ip_in_cidr
export -f nftban_find_ip_locations
export -f nftban_check_root
export -f nftban_check_nftables_table
export -f nftban_geoip_lookup
export -f nftban_whois_lookup
export -f nftban_get_ip_info
export -f nftban_send_email
export -f nftban_send_ban_notification
export -f nftban_send_rate_limit_alert
export -f nftban_get_public_ip
export -f nftban_get_current_user_ip
export -f nftban_mktemp
export -f nftban_mktemp_dir
export -f nftban_secure_atomic_write
export -f nftban_atomic_write
export -f nftban_secure_curl
export -f nftban_secure_curl_get
export -f nftban_with_lock
export -f nftban_is_locked
export -f nftban_get_lock_holder
export -f nftban_sanitize_jail_name
export -f nftban_sanitize_identifier
export -f nftban_sanitize_path_component
export -f nftban_sanitize_port
export -f nftban_validate_email
export -f nftban_sanitize_shell_arg
export -f nftban_load_modules

nftban_log_debug "NFTBan Core Module loaded successfully (v3.0.0 - Split Tables)"

# =============================================================================
# FOOTER
# =============================================================================
#
# **Module Version:** 0.9.3-dev
# **Security Level:** Production-Hardened (9/10)
# **License:** NFTBAN Custom License v3.0
# SPDX-License-Identifier: NFTBAN-Custom-License
#
# © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.
#
# Permission is granted, free of charge, to use, modify, and deploy this Software
# for personal, educational, or commercial purposes within your own systems or
# organization, without redistribution.
#
# Redistribution, publication, resale, or sharing of this Software or any
# derivative works — in source or binary form — is strictly prohibited without
# prior written permission from the copyright holder.
#
# You may not, under any circumstance:
# ❌ Publicly upload, mirror, fork, or rehost this repository or its contents.
# ❌ Share, sell, or include the Software in any downloadable product, service,
#    or marketplace (commercial or non-commercial).
# ❌ Post the Software or any derivative works to public Git repositories,
#    software distribution platforms, package registries, or file-sharing networks.
# ❌ Use the Software or its output to train, fine-tune, or develop artificial
#    intelligence or machine learning models without prior written permission
#    from the copyright holder.
#
# Use freely within your organization—but do not redistribute publicly.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE, OR NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHOR OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER
# LIABILITY ARISING FROM THE USE OF THE SOFTWARE OR ITS DOCUMENTATION.
#
# =============================================================================
