#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="strict" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Provides consistent strict mode configuration for all bash scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CLI_ERROR_LOG,NFTBAN_ENABLE_ERROR_LOGGING"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

set -Eeuo pipefail

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

# If already loaded, just return
[[ -n "${NFTBAN_STRICT_MODE_LOADED:-}" ]] && return 0

# =============================================================================
# STRICT MODE SETTINGS (already set at top: set -Eeuo pipefail)
# =============================================================================
# -E: ERR traps are inherited by functions, subshells, etc.
# -e: Exit on error (any command returning non-zero causes script exit)
# -u: Exit on undefined variable
# -o pipefail: If any command in pipeline fails, the whole pipeline fails

# =============================================================================
# SAFE INTERNAL FIELD SEPARATOR
# =============================================================================

# Set IFS to only newline and tab
# This prevents word splitting on spaces, which is often a security issue
# Preserves spaces in filenames and variables
IFS=$'\n\t'

# =============================================================================
# SECURE FILE CREATION
# =============================================================================

# Set umask for secure file creation
# 027 = owner: rwx (7), group: r-x (5), other: none (0)
# Created files: rw-r----- (640)
# Created directories: rwxr-x--- (750)
umask 027

# =============================================================================
# ERROR HANDLING
# =============================================================================

# Error handler function
# Called when any command fails (via ERR trap)
nftban_error_handler() {
    local exit_code=$?
    # shellcheck disable=SC2034  # Used in ERR trap context
    local line_no=$1
    local bash_lineno=${BASH_LINENO[0]}
    local function_name="${FUNCNAME[1]:-main}"
    local script_name="${BASH_SOURCE[1]:-${0}}"

    # Don't print error if we're in an if/while/test context
    # (these are expected to fail sometimes)
    if [[ "${BASH_COMMAND}" =~ ^(test|\[|\[\[) ]]; then
        return 0
    fi

    # Don't print error for ANY return statement
    # return 0 = success, return 1 = normal failure/not found, return 2-3 = warnings
    # These are all intentional exit codes, not errors worth logging
    if [[ "${BASH_COMMAND}" =~ ^return ]]; then
        return 0
    fi

    # Don't print error for explicit exit statements
    # exit 1 after showing usage/help is intentional, not an error
    if [[ "${BASH_COMMAND}" =~ ^exit ]]; then
        return 0
    fi

    # Print error message to stderr
    cat >&2 <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ERROR: Script failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Script:   ${script_name}
Function: ${function_name}
Line:     ${bash_lineno}
Command:  ${BASH_COMMAND}
Exit:     ${exit_code}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

    # Log error to file (if logging enabled and writable)
    local cli_error_log="${NFTBAN_CLI_ERROR_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/cli-errors.log}"
    if [[ "${NFTBAN_ENABLE_ERROR_LOGGING:-1}" == "1" ]]; then
        local log_dir
        log_dir=$(dirname "${cli_error_log}")
        # Only log if directory exists and is writable
        if [[ -d "${log_dir}" && -w "${log_dir}" ]]; then
            {
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "ERROR: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "Script:   ${script_name}"
                echo "Function: ${function_name}"
                echo "Line:     ${bash_lineno}"
                echo "Command:  ${BASH_COMMAND}"
                echo "Exit:     ${exit_code}"
                echo "User:     ${USER:-unknown}"
                echo "PWD:      ${PWD:-unknown}"
                echo ""
            } >> "${cli_error_log}" 2>/dev/null || true
        fi
    fi

    # Exit with the original error code
    exit "${exit_code}"
}

# Set up error trap
# This trap will call nftban_error_handler whenever a command fails
trap 'nftban_error_handler ${LINENO}' ERR

# =============================================================================
# EXIT HANDLER (CLEANUP)
# =============================================================================

# Cleanup handler function
# Called when script exits (normally or via error)
nftban_exit_handler() {
    local exit_code=$?

    # Clean up temp files if they exist
    # Scripts can add files to this array for automatic cleanup
    if [[ -n "${NFTBAN_TEMP_FILES:-}" ]]; then
        for temp_file in "${NFTBAN_TEMP_FILES[@]:-}"; do
            [[ -f "${temp_file}" ]] && rm -f "${temp_file}" 2>/dev/null || true
        done
    fi

    # Clean up temp directories if they exist
    if [[ -n "${NFTBAN_TEMP_DIRS:-}" ]]; then
        for temp_dir in "${NFTBAN_TEMP_DIRS[@]:-}"; do
            [[ -d "${temp_dir}" ]] && rm -rf "${temp_dir}" 2>/dev/null || true
        done
    fi

    return "${exit_code}"
}

# Set up exit trap
trap 'nftban_exit_handler' EXIT

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Disable strict mode temporarily
# Usage: nftban_strict_off
nftban_strict_off() {
    set +e
    set +u
    set +o pipefail
}

# Re-enable strict mode
# Usage: nftban_strict_on
nftban_strict_on() {
    set -e
    set -u
    set -o pipefail
}

# Run a command without strict mode
# Usage: nftban_try <command>
# Returns: exit code of command (doesn't exit script on failure)
nftban_try() {
    set +e
    "$@"
    local exit_code=$?
    set -e
    return "${exit_code}"
}

# Check if running as root
# Usage: nftban_require_root
# Exits: 1 if not root
nftban_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root" >&2
        echo "Try: sudo $0 $*" >&2
        exit 1
    fi
}

# Check if a command exists
# Usage: nftban_require_command <command> [package]
# Exits: 1 if command not found
nftban_require_command() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: Required command '${cmd}' not found" >&2
        echo "Install: dnf install ${pkg}" >&2
        exit 1
    fi
}

# Validate required environment variable
# Usage: nftban_require_var <var_name>
# Exits: 1 if variable not set or empty
nftban_require_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"

    if [[ -z "${var_value}" ]]; then
        echo "ERROR: Required environment variable '${var_name}' is not set" >&2
        exit 1
    fi
}

# =============================================================================
# TEMP FILE MANAGEMENT
# =============================================================================

# Create a temporary file and register it for cleanup
# Usage: temp_file=$(nftban_mktemp)
nftban_mktemp() {
    local temp_file
    temp_file=$(mktemp "${TMPDIR:-/tmp}/nftban.XXXXXXXXXX")

    # Add to cleanup array
    NFTBAN_TEMP_FILES+=("${temp_file}")

    echo "${temp_file}"
}

# Create a temporary directory and register it for cleanup
# Usage: temp_dir=$(nftban_mktemp_dir)
nftban_mktemp_dir() {
    local temp_dir
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nftban.XXXXXXXXXX")

    # Add to cleanup array
    NFTBAN_TEMP_DIRS+=("${temp_dir}")

    echo "${temp_dir}"
}

# Initialize temp file/dir arrays
declare -a NFTBAN_TEMP_FILES=()
declare -a NFTBAN_TEMP_DIRS=()

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_error_handler
export -f nftban_exit_handler
export -f nftban_strict_off
export -f nftban_strict_on
export -f nftban_try
export -f nftban_require_root
export -f nftban_require_command
export -f nftban_require_var
export -f nftban_mktemp
export -f nftban_mktemp_dir

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_STRICT_MODE_LOADED=1
export NFTBAN_STRICT_MODE_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
