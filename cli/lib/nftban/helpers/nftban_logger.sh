#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_logger"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Centralized logging to files and stdout for all modules"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail


# =============================================================================
# MODULE GUARD
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_LOGGER_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGGER_LOADED=1

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# =============================================================================
# LOG LEVELS
# =============================================================================

# Log level constants for external use
# shellcheck disable=SC2034
readonly LOG_LEVEL_DEBUG=0
# shellcheck disable=SC2034
readonly LOG_LEVEL_INFO=1
# shellcheck disable=SC2034
readonly LOG_LEVEL_WARN=2
# shellcheck disable=SC2034
readonly LOG_LEVEL_ERROR=3
# shellcheck disable=SC2034
readonly LOG_LEVEL_SUCCESS=4

# =============================================================================
# CONFIGURATION
# =============================================================================

# Main log file
: "${NFTBAN_LOG_FILE:=${NFTBAN_LOG_DIR}/nftban.log}"

# Current log level (default: INFO)
: "${NFTBAN_LOG_LEVEL:=$LOG_LEVEL_INFO}"

# Enable/disable stdout logging
: "${NFTBAN_LOG_STDOUT:=true}"

# Enable/disable file logging
: "${NFTBAN_LOG_FILE_ENABLED:=true}"

# Log format: timestamp, simple
: "${NFTBAN_LOG_FORMAT:=timestamp}"

# =============================================================================
# CORE LOGGING FUNCTION
# =============================================================================

# Main logging function
# Usage: nftban_log <level> <module> <message...>
nftban_log() {
    local level="$1"
    local module="${2:-nftban}"
    shift 2
    local message="$*"

    # Skip if message is empty
    [[ -z "$message" ]] && return 0

    # Strip ANSI escape codes before writing to log file
    message=$(printf '%s' "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')

    # Build timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Build log line based on format
    local log_line
    case "${NFTBAN_LOG_FORMAT}" in
        timestamp)
            log_line="[$timestamp] [$level] [$module] $message"
            ;;
        simple)
            log_line="[$level] [$module] $message"
            ;;
        *)
            log_line="[$timestamp] [$level] [$module] $message"
            ;;
    esac

    # Write to file (with error handling)
    if [[ "${NFTBAN_LOG_FILE_ENABLED}" == "true" ]]; then
        local log_dir
        log_dir="$(dirname "$NFTBAN_LOG_FILE")"

        if [[ -w "$log_dir" ]] || [[ -w "$NFTBAN_LOG_FILE" ]]; then
            echo "$log_line" >> "$NFTBAN_LOG_FILE" 2>/dev/null || true
        fi
    fi

    # Write to stdout (if enabled)
    if [[ "${NFTBAN_LOG_STDOUT}" == "true" ]] && [[ "${NFTBAN_SILENT:-false}" != "true" ]]; then
        echo "[$level] $message"
    fi
}

# =============================================================================
# CONVENIENCE FUNCTIONS
# =============================================================================

# Log DEBUG message
nftban_log_debug() {
    local module="${NFTBAN_MODULE_NAME:-nftban}"
    nftban_log "DEBUG" "$module" "$@"
}

# Log INFO message
nftban_log_info() {
    local module="${NFTBAN_MODULE_NAME:-nftban}"
    nftban_log "INFO" "$module" "$@"
}

# Log WARN message
nftban_log_warn() {
    local module="${NFTBAN_MODULE_NAME:-nftban}"
    nftban_log "WARN" "$module" "$@"
}

# Log ERROR message
nftban_log_error() {
    local module="${NFTBAN_MODULE_NAME:-nftban}"
    nftban_log "ERROR" "$module" "$@"
}

# Log SUCCESS message
nftban_log_success() {
    local module="${NFTBAN_MODULE_NAME:-nftban}"
    nftban_log "SUCCESS" "$module" "$@"
}

# =============================================================================
# MODULE-SPECIFIC LOGGING
# =============================================================================

# Log to module-specific file
# Usage: nftban_log_to_module_file <log_file> <level> <message...>
nftban_log_to_module_file() {
    local module_log="$1"
    local level="$2"
    shift 2
    local message="$*"

    # Skip if message is empty
    [[ -z "$message" ]] && return 0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Strip ANSI escape codes before writing to log file
    message=$(printf '%s' "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')

    local log_line="[$timestamp] [$level] $message"

    # Check if log directory is writable
    local log_dir
    log_dir="$(dirname "$module_log")"

    if [[ -w "$log_dir" ]] || [[ -w "$module_log" ]]; then
        echo "$log_line" >> "$module_log" 2>/dev/null || true
    fi
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Initialize logging for a module
# Usage: nftban_logger_init <module_name> [log_file]
nftban_logger_init() {
    local module_name="$1"
    local module_log="${2:-/var/log/nftban/${module_name}.log}"

    # Set module name for convenience functions
    export NFTBAN_MODULE_NAME="$module_name"
    export NFTBAN_MODULE_LOG_FILE="$module_log"

    # Ensure log directory exists
    local log_dir
    log_dir="$(dirname "$module_log")"

    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi

    # Create log file if it doesn't exist
    if [[ ! -f "$module_log" ]]; then
        touch "$module_log" 2>/dev/null || true
        chmod 640 "$module_log" 2>/dev/null || true
    fi

    # Log initialization
    nftban_log_info "Logger initialized for module: $module_name"
    nftban_log_to_module_file "$module_log" "INFO" "Module logger initialized"
}

# Write to both main log and module log
# Usage: nftban_log_dual <level> <message...>
nftban_log_dual() {
    local level="$1"
    shift
    local message="$*"

    # Log to main log
    nftban_log "$level" "${NFTBAN_MODULE_NAME:-nftban}" "$message"

    # Log to module log (if defined)
    if [[ -n "${NFTBAN_MODULE_LOG_FILE:-}" ]]; then
        nftban_log_to_module_file "$NFTBAN_MODULE_LOG_FILE" "$level" "$message"
    fi
}

# =============================================================================
# LOG ROTATION HELPER
# =============================================================================

# Check if log file needs rotation (based on size)
# Usage: nftban_log_check_rotation <log_file> <max_size_mb>
nftban_log_check_rotation() {
    local log_file="$1"
    local max_size_mb="${2:-10}"  # Default 10MB

    [[ ! -f "$log_file" ]] && return 0

    local size_bytes
    size_bytes=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
    local size_mb=$((size_bytes / 1024 / 1024))

    if ((size_mb >= max_size_mb)); then
        # Rotate log
        local backup="${log_file}.1"
        [[ -f "$backup" ]] && rm -f "$backup"
        mv "$log_file" "$backup"
        touch "$log_file"
        chmod 640 "$log_file" 2>/dev/null || true

        nftban_log_info "Rotated log file: $log_file (was ${size_mb}MB)"
    fi
}

# =============================================================================
# COMPATIBILITY ALIASES (for nftban_logging.sh migration)
# =============================================================================
# These aliases provide backward compatibility for scripts that used the
# old log_info, log_warn, log_error, log_debug, log_success functions
# from nftban_logging.sh. New code should use nftban_log_* functions.

log_info() {
    nftban_log_info "$@"
}

log_warn() {
    nftban_log_warn "$@"
}

log_error() {
    nftban_log_error "$@"
}

log_debug() {
    nftban_log_debug "$@"
}

log_success() {
    nftban_log_success "$@"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

# Export logging functions for use by other scripts
export -f nftban_log
export -f nftban_log_debug
export -f nftban_log_info
export -f nftban_log_warn
export -f nftban_log_error
export -f nftban_log_success
export -f nftban_log_to_module_file
export -f nftban_log_dual
export -f nftban_logger_init
export -f nftban_log_check_rotation

# Export compatibility aliases
export -f log_info
export -f log_warn
export -f log_error
export -f log_debug
export -f log_success

# =============================================================================
# MODULE LOADED
# =============================================================================

# Silent mode - don't log this during module load
if [[ "${NFTBAN_SILENT:-false}" != "true" ]] && [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_log_debug "Logger module loaded"
fi
