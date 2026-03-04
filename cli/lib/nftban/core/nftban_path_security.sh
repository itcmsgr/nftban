#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Path Validation & Write Security Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_path_security"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Secure path validation to prevent path traversal and unauthorized writes"
# meta:inventory.files=""
# meta:inventory.binaries="realpath"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

set -Eeuo pipefail

# Module guard
[[ -n "${NFTBAN_PATH_SECURITY_LOADED:-}" ]] && return 0
declare -g NFTBAN_PATH_SECURITY_LOADED=1

# =============================================================================
# SECURITY CONFIGURATION
# =============================================================================

# Allowed write directories (FHS compliant)
declare -ga NFTBAN_ALLOWED_WRITE_DIRS=(
    "${NFTBAN_DATA_DIR}/reports"      # Application state reports
    "${NFTBAN_DATA_DIR}/metrics"      # Statistics metrics database
    "${NFTBAN_DATA_DIR}/snapshots"    # Hourly stats snapshots
    "${NFTBAN_DATA_DIR}/exports"      # User exports
    "${NFTBAN_DATA_DIR}/geoip"        # GeoIP database
    "${NFTBAN_LOG_DIR}"                # Log files (daemon writes)
    "${NFTBAN_LOG_DIR}/reports"        # Report files in logs
    "${NFTBAN_CACHE_DIR}"              # Cache files
)

# Restricted directories (require --unsafe-allow-tmp flag + warning)
declare -ga NFTBAN_RESTRICTED_DIRS=(
    "/tmp"
    "/var/tmp"
)

# Forbidden directories (NEVER allow, even with --unsafe)
declare -ga NFTBAN_FORBIDDEN_DIRS=(
    "/etc"             # System configuration (except /etc/nftban handled separately)
    "/boot"            # Boot files
    "/root"            # Root home directory
    "/usr"             # System binaries and libraries
    "/bin"             # Essential binaries
    "/sbin"            # System binaries
    "/lib"             # Essential libraries
    "/lib64"           # Essential libraries (64-bit)
    "/sys"             # Kernel sysfs
    "/proc"            # Kernel procfs
    "/dev"             # Device files
)

# =============================================================================
# PATH VALIDATION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# Validate if path is safe for writing
# Arguments:
#   $1 - Path to validate
#   $2 - (optional) "allow-unsafe" to permit /tmp
# Returns:
#   0 if safe, 1 if unsafe
# Output:
#   Error message on stderr if unsafe
# Security:
#   - Blocks path traversal (..)
#   - Blocks null bytes
#   - Canonicalizes paths
#   - Checks against forbidden/allowed/restricted lists
# -----------------------------------------------------------------------------
nftban_path_validate_write() {
    local path="$1"
    local allow_unsafe="${2:-}"

    # Empty path
    if [[ -z "$path" ]]; then
        echo "ERROR: Empty path not allowed" >&2
        return 1
    fi

    # Convert to absolute path
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi

    # Resolve symlinks and canonicalize (prevent symlink attacks)
    if command -v realpath >/dev/null 2>&1; then
        path="$(realpath -m "$path" 2>/dev/null || echo "$path")"
    fi

    # Check for path traversal attempts (..)
    if [[ "$path" =~ \.\. ]]; then
        echo "ERROR: Path traversal detected (..) - FORBIDDEN" >&2
        echo "  Path: $path" >&2
        nftban_path_audit_log "DENIED" "path_traversal path=$path"
        return 1
    fi

    # Note: Null byte check removed - bash variables can't contain null bytes anyway
    # (they would be stripped during variable assignment)
    # Real protection is at kernel syscall level

    # Check FORBIDDEN directories (highest priority - never allow)
    local forbidden_dir
    for forbidden_dir in "${NFTBAN_FORBIDDEN_DIRS[@]}"; do
        if [[ "$path" == "$forbidden_dir" ]] || [[ "$path" == "$forbidden_dir"/* ]]; then
            echo "ERROR: Writing to $forbidden_dir is FORBIDDEN for security" >&2
            echo "  Attempted path: $path" >&2
            echo "  Reason: System directory - potential compromise" >&2
            nftban_path_audit_log "DENIED" "forbidden_dir path=$path forbidden=$forbidden_dir"
            return 1
        fi
    done

    # Check ALLOWED directories (safe, no warning)
    local allowed_dir
    for allowed_dir in "${NFTBAN_ALLOWED_WRITE_DIRS[@]}"; do
        if [[ "$path" == "$allowed_dir"/* ]] || [[ "$path" == "$allowed_dir" ]]; then
            nftban_path_audit_log "ALLOWED" "safe_path path=$path allowed_dir=$allowed_dir"
            return 0
        fi
    done

    # Check RESTRICTED directories (/tmp - requires --unsafe flag)
    local restricted_dir
    for restricted_dir in "${NFTBAN_RESTRICTED_DIRS[@]}"; do
        if [[ "$path" == "$restricted_dir"/* ]] || [[ "$path" == "$restricted_dir" ]]; then
            if [[ "$allow_unsafe" == "allow-unsafe" ]]; then
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "⚠️  SECURITY WARNING: Writing to $restricted_dir" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "  Path: $path" >&2
                echo "" >&2
                echo "  RISKS:" >&2
                echo "    • Symlink attacks (attacker creates symlink before you)" >&2
                echo "    • Race conditions (TOCTOU)" >&2
                echo "    • Information disclosure (world-readable by default)" >&2
                echo "    • Temporary files may be preserved across reboots" >&2
                echo "" >&2
                echo "  This operation proceeds because --unsafe-allow-tmp was used." >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                nftban_path_audit_log "WARNING" "unsafe_tmp_allowed path=$path"
                return 0
            else
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "❌ ERROR: Writing to $restricted_dir REQUIRES --unsafe-allow-tmp" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                echo "  Attempted path: $path" >&2
                echo "" >&2
                echo "  SECURITY RISKS:" >&2
                echo "    • Symlink attacks - attacker creates /tmp/report.html → /etc/passwd" >&2
                echo "    • Race conditions - file created between check and write" >&2
                echo "    • Information disclosure - other users can read files" >&2
                echo "    • Privilege escalation - if run as root with user-controlled paths" >&2
                echo "" >&2
                echo "  RECOMMENDED ALTERNATIVES (safer):" >&2
                echo "    1. Use default location (automatic):" >&2
                echo "       nftban report generate" >&2
                echo "       → /var/lib/nftban/reports/report-YYYYMMDD-HHMMSS.html" >&2
                echo "" >&2
                echo "    2. Use filename only (writes to safe directory):" >&2
                echo "       nftban report generate --output myreport.html" >&2
                echo "       → /var/lib/nftban/reports/myreport.html" >&2
                echo "" >&2
                echo "    3. Use --stdout and redirect (you control destination):" >&2
                echo "       nftban report generate --stdout > ~/report.html" >&2
                echo "" >&2
                echo "  UNSAFE OPTION (not recommended):" >&2
                echo "    nftban report generate --output /tmp/report.html --unsafe-allow-tmp" >&2
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
                nftban_path_audit_log "DENIED" "restricted_tmp path=$path missing_unsafe_flag=true"
                return 1
            fi
        fi
    done

    # Path not in any allowed/restricted/forbidden directory
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "❌ ERROR: Path not in allowed write directories" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "  Attempted path: $path" >&2
    echo "" >&2
    echo "  ALLOWED DIRECTORIES:" >&2
    for allowed_dir in "${NFTBAN_ALLOWED_WRITE_DIRS[@]}"; do
        echo "    ✓ $allowed_dir" >&2
    done
    echo "" >&2
    echo "  RECOMMENDED:" >&2
    echo "    • Use default: nftban report generate" >&2
    echo "    • Use filename only: --output report.html" >&2
    echo "    • Use redirect: --stdout > ~/report.html" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    nftban_path_audit_log "DENIED" "not_in_allowed_dirs path=$path"
    return 1
}

# -----------------------------------------------------------------------------
# Sanitize filename (remove dangerous characters)
# Arguments:
#   $1 - Filename to sanitize
# Output:
#   Sanitized filename
# Security:
#   - Removes path separators (/)
#   - Removes null bytes
#   - Removes newlines/control characters
#   - Removes leading dots (hidden files)
# -----------------------------------------------------------------------------
nftban_path_sanitize_filename() {
    local filename="$1"

    # Remove path components (keep only basename)
    filename="${filename##*/}"

    # Replace dangerous characters with underscore
    filename="${filename//[\\/\0\n\r\t]/_}"

    # Remove leading dots (prevent hidden files)
    filename="${filename#.}"

    # Remove multiple consecutive underscores
    filename="${filename//__/_}"

    # Ensure not empty
    if [[ -z "$filename" ]]; then
        filename="report-$(date +%s)"
    fi

    echo "$filename"
}

# -----------------------------------------------------------------------------
# Get safe output path (main function - handles all cases)
# Arguments:
#   $1 - User-provided path (can be empty, filename, or full path)
#   $2 - Default directory
#   $3 - (optional) "allow-unsafe" flag
# Output:
#   Safe validated path
# Returns:
#   0 if successful, 1 if validation failed
# Usage:
#   safe=$(nftban_path_get_safe_output "$user_input" "/var/lib/nftban/reports") || return 1
# -----------------------------------------------------------------------------
nftban_path_get_safe_output() {
    local user_path="$1"
    local default_dir="$2"
    local allow_unsafe="${3:-}"
    local default_ext="${4:-.html}"

    # Case 1: Empty path → use default
    if [[ -z "$user_path" ]]; then
        echo "${default_dir}/report-$(date +%Y%m%d-%H%M%S)${default_ext}"
        return 0
    fi

    # Case 2: Filename only (no path separators) → use default directory
    if [[ "$user_path" != */* ]]; then
        local sanitized
        sanitized=$(nftban_path_sanitize_filename "$user_path")
        local safe_path="${default_dir}/${sanitized}"
        echo "$safe_path"
        nftban_path_audit_log "ALLOWED" "filename_only input=$user_path output=$safe_path"
        return 0
    fi

    # Case 3: Full path → validate it
    if nftban_path_validate_write "$user_path" "$allow_unsafe"; then
        echo "$user_path"
        return 0
    else
        # Validation failed, error already printed
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Create file safely (prevents symlink attacks, TOCTOU)
# Arguments:
#   $1 - Path to create
# Returns:
#   0 if successful, 1 on failure
# Security:
#   - Checks for symlinks before writing
#   - Creates parent directories safely
#   - Uses set -C (noclobber) when creating new files
# -----------------------------------------------------------------------------
nftban_path_create_file_safe() {
    local path="$1"
    local dir
    dir="$(dirname "$path")"

    # Create directory if needed (atomic, avoids TOCTOU race)
    if ! mkdir -p "$dir" 2>/dev/null; then
        # Only fail if directory still doesn't exist (concurrent creation is OK)
        if [[ ! -d "$dir" ]]; then
            echo "ERROR: Cannot create directory: $dir" >&2
            nftban_path_audit_log "DENIED" "mkdir_failed path=$dir"
            return 1
        fi
    fi

    # Check if path exists and is a symlink (BEFORE writing)
    if [[ -L "$path" ]]; then
        echo "ERROR: Target is a symbolic link - REFUSING to write" >&2
        echo "  Path: $path" >&2
        echo "  Reason: Symlink attack prevention" >&2
        nftban_path_audit_log "DENIED" "symlink_attack_prevented path=$path"
        return 1
    fi

    # If file exists, check if it's a regular file
    if [[ -e "$path" ]]; then
        if [[ ! -f "$path" ]]; then
            echo "ERROR: Target exists and is not a regular file" >&2
            echo "  Path: $path" >&2
            nftban_path_audit_log "DENIED" "not_regular_file path=$path"
            return 1
        fi
        # Regular file exists - will be overwritten
        nftban_path_audit_log "ALLOWED" "overwrite_file path=$path"
        return 0
    fi

    # Create new file with noclobber (prevents race condition)
    set -C
    if ! { : > "$path"; } 2>/dev/null; then
        # Failed to create (race condition - file appeared)
        set +C
        echo "ERROR: Race condition detected - file appeared during creation" >&2
        echo "  Path: $path" >&2
        nftban_path_audit_log "DENIED" "race_condition path=$path"
        return 1
    fi
    set +C

    nftban_path_audit_log "ALLOWED" "create_file path=$path"
    return 0
}

# =============================================================================
# AUDIT LOGGING
# =============================================================================

# -----------------------------------------------------------------------------
# Log path security event to audit log
# Arguments:
#   $1 - Event type (ALLOWED, DENIED, WARNING)
#   $2 - Message
# Output:
#   Appends to /var/log/nftban/security-audit.log
# Security:
#   - Logs all path validation decisions
#   - Includes timestamp, user, PID, action
# -----------------------------------------------------------------------------
nftban_path_audit_log() {
    local event_type="$1"
    local message="$2"
    local audit_log="${NFTBAN_LOG_DIR}/security-audit.log"

    # Only log if parent directory exists
    if [[ -d "$(dirname "$audit_log")" ]]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local user="${SUDO_USER:-${USER:-unknown}}"
        local pid="$$"
        local ppid="${PPID:-0}"

        # Format: timestamp [TYPE] pid=PID ppid=PPID user=USER action message
        echo "${timestamp} [${event_type}] pid=${pid} ppid=${ppid} user=${user} ${message}" \
            >> "$audit_log" 2>/dev/null || true
    fi
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# Export functions for use by other modules
declare -fx nftban_path_validate_write
declare -fx nftban_path_sanitize_filename
declare -fx nftban_path_get_safe_output
declare -fx nftban_path_create_file_safe
declare -fx nftban_path_audit_log

return 0
