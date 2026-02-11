#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Secure Mode Directive
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_secure_mode"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Secure-by-default environment with automatic file write validation and path security"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

set -Eeuo pipefail

# Module guard
[[ -n "${NFTBAN_SECURE_MODE_LOADED:-}" ]] && return 0
declare -g NFTBAN_SECURE_MODE_LOADED=1

# =============================================================================
# AUTO-LOAD DEPENDENCIES
# =============================================================================

# Load path security module if not already loaded
if ! declare -f nftban_path_validate_write >/dev/null 2>&1; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" || {
            echo "ERROR: Failed to load path security module" >&2
            return 1
        }
    else
        echo "ERROR: Path security module not found" >&2
        return 1
    fi
fi

# =============================================================================
# SECURE MODE CONFIGURATION
# =============================================================================

# Enable/disable secure mode (default: enabled)
: "${NFTBAN_SECURE_MODE_ENABLED:=1}"

# Allow unsafe operations with explicit flag (default: require flag)
: "${NFTBAN_SECURE_MODE_ALLOW_UNSAFE:=}"

# Audit all file operations (default: yes)
: "${NFTBAN_SECURE_MODE_AUDIT:=1}"

# Fail on security violations (default: yes, 0=warn only)
: "${NFTBAN_SECURE_MODE_STRICT:=1}"

# =============================================================================
# SAFE FILE WRITE WRAPPERS
# =============================================================================

# -----------------------------------------------------------------------------
# Safe file write wrapper
# Usage: nftban_secure_write "content" "/path/to/file"
# Returns: 0 if successful, 1 if blocked
# -----------------------------------------------------------------------------
nftban_secure_write() {
    local content="$1"
    local path="$2"
    local allow_unsafe="${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"

    # Validate path
    if ! nftban_path_validate_write "$path" "$allow_unsafe"; then
        [[ "$NFTBAN_SECURE_MODE_STRICT" == "1" ]] && return 1
        echo "WARNING: Proceeding with insecure write (strict mode disabled)" >&2
    fi

    # Create file safely (prevents symlink attacks)
    if ! nftban_path_create_file_safe "$path"; then
        echo "ERROR: Failed to create file safely: $path" >&2
        return 1
    fi

    # Write content
    echo "$content" > "$path"

    # Audit log
    [[ "$NFTBAN_SECURE_MODE_AUDIT" == "1" ]] && \
        nftban_path_audit_log "WRITE" "secure_write path=$path size=${#content}"

    return 0
}

# -----------------------------------------------------------------------------
# Safe file append wrapper
# Usage: nftban_secure_append "content" "/path/to/file"
# -----------------------------------------------------------------------------
nftban_secure_append() {
    local content="$1"
    local path="$2"
    local allow_unsafe="${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"

    # Validate path
    if ! nftban_path_validate_write "$path" "$allow_unsafe"; then
        [[ "$NFTBAN_SECURE_MODE_STRICT" == "1" ]] && return 1
    fi

    # Ensure file exists and is safe
    if [[ ! -e "$path" ]]; then
        nftban_path_create_file_safe "$path" || return 1
    elif [[ -L "$path" ]]; then
        echo "ERROR: Target is a symlink - refusing to append" >&2
        return 1
    fi

    # Append content
    echo "$content" >> "$path"

    # Audit log
    [[ "$NFTBAN_SECURE_MODE_AUDIT" == "1" ]] && \
        nftban_path_audit_log "APPEND" "secure_append path=$path size=${#content}"

    return 0
}

# -----------------------------------------------------------------------------
# Safe file copy with path validation
# Usage: nftban_secure_copy "/source/file" "/dest/file"
# -----------------------------------------------------------------------------
nftban_secure_copy() {
    local source="$1"
    local dest="$2"
    local allow_unsafe="${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"

    # Validate destination path
    if ! nftban_path_validate_write "$dest" "$allow_unsafe"; then
        [[ "$NFTBAN_SECURE_MODE_STRICT" == "1" ]] && return 1
    fi

    # Check source exists
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Source file not found: $source" >&2
        return 1
    fi

    # Ensure destination is safe
    if ! nftban_path_create_file_safe "$dest"; then
        return 1
    fi

    # Copy file
    cp -f "$source" "$dest" || {
        echo "ERROR: Copy failed: $source → $dest" >&2
        return 1
    }

    # Audit log
    [[ "$NFTBAN_SECURE_MODE_AUDIT" == "1" ]] && \
        nftban_path_audit_log "COPY" "secure_copy source=$source dest=$dest"

    return 0
}

# -----------------------------------------------------------------------------
# Safe output redirection helper
# Usage: command | nftban_secure_tee "/path/to/file"
# -----------------------------------------------------------------------------
nftban_secure_tee() {
    local path="$1"
    local allow_unsafe="${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"

    # Validate path
    if ! nftban_path_validate_write "$path" "$allow_unsafe"; then
        [[ "$NFTBAN_SECURE_MODE_STRICT" == "1" ]] && return 1
        echo "WARNING: Proceeding with insecure tee (strict mode disabled)" >&2
    fi

    # Ensure file is safe
    if ! nftban_path_create_file_safe "$path"; then
        return 1
    fi

    # Use tee
    tee "$path"

    # Audit log
    [[ "$NFTBAN_SECURE_MODE_AUDIT" == "1" ]] && \
        nftban_path_audit_log "TEE" "secure_tee path=$path"

    return 0
}

# =============================================================================
# HIGHER-LEVEL API (RECOMMENDED)
# =============================================================================

# -----------------------------------------------------------------------------
# Get safe output path (main API for user-provided paths)
# Usage: safe_path=$(nftban_get_output_path "$user_path" [default_dir])
# Examples:
#   safe_path=$(nftban_get_output_path "$user_input")
#   safe_path=$(nftban_get_output_path "$user_input" "/var/lib/nftban/reports")
#   safe_path=$(nftban_get_output_path "" "/var/lib/nftban/reports" ".html")
# -----------------------------------------------------------------------------
nftban_get_output_path() {
    local user_path="${1:-}"
    local default_dir="${2:-/var/lib/nftban/reports}"
    local allow_unsafe="${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"
    local default_ext="${3:-.html}"

    nftban_path_get_safe_output "$user_path" "$default_dir" "$allow_unsafe" "$default_ext"
}

# -----------------------------------------------------------------------------
# Write to safe file (combines path validation + write)
# Usage: nftban_write_safe "/path/to/file" "content"
# Or:    nftban_write_safe "$(nftban_get_output_path "$user_path")" "content"
# -----------------------------------------------------------------------------
nftban_write_safe() {
    local path="$1"
    local content="$2"

    # If path looks user-provided (no validation yet), validate it
    if [[ "$path" == *"/"* ]] && ! nftban_path_validate_write "$path" "${NFTBAN_SECURE_MODE_ALLOW_UNSAFE}"; then
        return 1
    fi

    nftban_secure_write "$content" "$path"
}

# -----------------------------------------------------------------------------
# Append to safe file
# Usage: nftban_append_safe "/path/to/file" "content"
# -----------------------------------------------------------------------------
nftban_append_safe() {
    local path="$1"
    local content="$2"

    nftban_secure_append "$content" "$path"
}

# =============================================================================
# SECURE MODE CONTROL
# =============================================================================

# -----------------------------------------------------------------------------
# Enable secure mode
# Usage: nftban_secure_mode_enable
# -----------------------------------------------------------------------------
nftban_secure_mode_enable() {
    export NFTBAN_SECURE_MODE_ENABLED=1
    export NFTBAN_SECURE_MODE_STRICT=1
    echo "[SECURE MODE] Enabled - all file writes validated" >&2
}

# -----------------------------------------------------------------------------
# Disable secure mode (not recommended)
# Usage: nftban_secure_mode_disable
# -----------------------------------------------------------------------------
nftban_secure_mode_disable() {
    export NFTBAN_SECURE_MODE_ENABLED=0
    export NFTBAN_SECURE_MODE_STRICT=0
    echo "[SECURE MODE] Disabled - WARNING: file writes NOT validated" >&2
}

# -----------------------------------------------------------------------------
# Allow unsafe operations (e.g., /tmp writes)
# Usage: nftban_secure_mode_allow_unsafe
# -----------------------------------------------------------------------------
nftban_secure_mode_allow_unsafe() {
    export NFTBAN_SECURE_MODE_ALLOW_UNSAFE="allow-unsafe"
    echo "[SECURE MODE] Unsafe operations allowed - use with caution" >&2
}

# -----------------------------------------------------------------------------
# Disallow unsafe operations (default, recommended)
# Usage: nftban_secure_mode_disallow_unsafe
# -----------------------------------------------------------------------------
nftban_secure_mode_disallow_unsafe() {
    export NFTBAN_SECURE_MODE_ALLOW_UNSAFE=""
    echo "[SECURE MODE] Unsafe operations blocked (recommended)" >&2
}

# =============================================================================
# DEVELOPER-FRIENDLY SHORTCUTS
# =============================================================================

# Shorter aliases for common operations
alias secure_write='nftban_secure_write'
alias secure_append='nftban_secure_append'
alias secure_copy='nftban_secure_copy'
alias secure_tee='nftban_secure_tee'
alias get_safe_path='nftban_get_output_path'

# =============================================================================
# USAGE EXAMPLES (COMMENTED)
# =============================================================================

: <<'USAGE_EXAMPLES'

# Example 1: Basic secure write
source /usr/lib/nftban/core/nftban_secure_mode.sh
nftban_secure_write "Hello World" "/var/lib/nftban/reports/test.txt"

# Example 2: User-provided path
user_path="/tmp/report.html"  # User input
safe_path=$(nftban_get_output_path "$user_path") || exit 1
nftban_secure_write "<html>..." "$safe_path"

# Example 3: Default path
safe_path=$(nftban_get_output_path "")  # Empty = use default
echo "Report" > "$safe_path"

# Example 4: Filename only
safe_path=$(nftban_get_output_path "myreport.html")
# → /var/lib/nftban/reports/myreport.html

# Example 5: Append to log
nftban_secure_append "Log entry" "/var/log/nftban/custom.log"

# Example 6: Copy with validation
nftban_secure_copy "/tmp/source.txt" "/var/lib/nftban/reports/dest.txt"

# Example 7: Pipe with tee
echo "Data" | nftban_secure_tee "/var/lib/nftban/reports/output.txt"

# Example 8: Allow unsafe (not recommended)
nftban_secure_mode_allow_unsafe
safe_path=$(nftban_get_output_path "/tmp/test.html")
nftban_secure_write "Content" "$safe_path"
nftban_secure_mode_disallow_unsafe

# Example 9: Disable strict mode (warnings only)
export NFTBAN_SECURE_MODE_STRICT=0
nftban_secure_write "Test" "/tmp/test.txt"  # Warns but proceeds

# Example 10: Integration in existing scripts
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

generate_report() {
    local output_path="$1"

    # Get safe path
    local safe_path
    safe_path=$(get_safe_path "$output_path") || return 1

    # Generate report
    local report="<html><body>Report</body></html>"

    # Write safely
    nftban_write_safe "$safe_path" "$report"

    echo "[SUCCESS] Report: $safe_path"
}

# Usage: generate_report "myreport.html"
# Or:    generate_report "/var/lib/nftban/reports/custom.html"
# Or:    generate_report ""  # Uses default

USAGE_EXAMPLES

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Auto-enable secure mode on load
if [[ "${NFTBAN_SECURE_MODE_ENABLED}" == "1" ]]; then
    echo "[SECURE MODE] Auto-enabled - file writes will be validated" >&2
fi

# Export all functions
declare -fx nftban_secure_write
declare -fx nftban_secure_append
declare -fx nftban_secure_copy
declare -fx nftban_secure_tee
declare -fx nftban_get_output_path
declare -fx nftban_write_safe
declare -fx nftban_append_safe
declare -fx nftban_secure_mode_enable
declare -fx nftban_secure_mode_disable
declare -fx nftban_secure_mode_allow_unsafe
declare -fx nftban_secure_mode_disallow_unsafe

return 0
