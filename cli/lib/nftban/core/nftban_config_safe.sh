#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Safe Configuration Loader
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_config_safe"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Secure configuration file parser that prevents arbitrary code execution"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CONFIG_SAFE_LOADED:-}" ]] && return 0
readonly NFTBAN_CONFIG_SAFE_LOADED=1

# =============================================================================
# ERROR HANDLING
# =============================================================================

__envsafe_err() {
    # Print error message to stderr
    # Args: error message
    printf "[CONFIG SECURITY] %s\n" "$*" >&2
}

__envsafe_warn() {
    # Print warning message to stderr
    # Args: warning message
    printf "[CONFIG WARNING] %s\n" "$*" >&2
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

__envsafe_validate_line() {
    # Validate a single config line for dangerous patterns
    # Args: line_number, line_content
    # Returns: 0 if safe, 1 if dangerous

    local line_num="$1"
    local line="$2"
    local file="${3:-unknown}"

    # Check for command substitution
    if [[ "$line" == *'$('* ]] || [[ "$line" == *'`'* ]]; then
        __envsafe_err "$file:$line_num: Command substitution detected: \$(…) or \`…\`"
        return 2
    fi

    # Check for shell operators (outside of quoted strings)
    # This is a simplified check - more sophisticated parsing would be needed for perfect detection
    if [[ "$line" == *';'* ]] || [[ "$line" == *'&&'* ]] || [[ "$line" == *'||'* ]]; then
        # Allow these inside double quotes (simplified - matches KEY="value;with;semicolons")
        if [[ ! "$line" =~ ^[A-Z0-9_]+=[\"\'][^\"\']*[\"\']$ ]]; then
            __envsafe_err "$file:$line_num: Shell operator detected outside quotes: ; && ||"
            return 2
        fi
    fi

    # Check for pipe operators
    if [[ "$line" == *'|'* ]] && [[ ! "$line" =~ ^[A-Z0-9_]+=\"[^\"]*\|[^\"]*\"$ ]]; then
        __envsafe_err "$file:$line_num: Pipe operator detected: |"
        return 2
    fi

    # Check for function definitions
    if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\(\) ]] || [[ "$line" == *'function '* ]]; then
        __envsafe_err "$file:$line_num: Function definition detected"
        return 2
    fi

    # Check for control structures
    if [[ "$line" =~ ^(if|for|while|case|select)[[:space:]] ]]; then
        __envsafe_err "$file:$line_num: Control structure detected: ${BASH_REMATCH[1]}"
        return 2
    fi

    return 0
}

__envsafe_parse_assignment() {
    # Parse and validate a KEY=VALUE assignment
    # Args: line
    # Sets: __ENVSAFE_KEY, __ENVSAFE_VALUE
    # Returns: 0 if valid, 1 if invalid

    local line="$1"

    # Match KEY=VALUE where KEY is [A-Z0-9_]+
    if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
        __ENVSAFE_KEY="${BASH_REMATCH[1]}"
        local raw="${BASH_REMATCH[2]}"

        # Strip optional quotes; allow simple escapes \" and \\ inside double quotes
        if [[ "$raw" =~ ^\"(([^\"]|\\\"|\\\\)*)\"$ ]]; then
            # Double-quoted value
            __ENVSAFE_VALUE="${BASH_REMATCH[1]}"
            # Unescape \" and \\
            __ENVSAFE_VALUE="${__ENVSAFE_VALUE//\\\"/\"}"
            __ENVSAFE_VALUE="${__ENVSAFE_VALUE//\\\\/\\}"
        elif [[ "$raw" =~ ^\'([^\']*)\'$ ]]; then
            # Single-quoted value (no escaping needed)
            __ENVSAFE_VALUE="${BASH_REMATCH[1]}"
        else
            # Unquoted value (strip trailing whitespace)
            __ENVSAFE_VALUE="${raw%%[[:space:]]*}"
        fi

        return 0
    else
        return 1
    fi
}

# =============================================================================
# MAIN LOADING FUNCTIONS
# =============================================================================

load_env_file() {
    # Load NAME=VALUE pairs from a file into current shell as globals
    # If PREFIX is provided, variables are exported as ${PREFIX}_NAME to avoid collisions
    #
    # Args:
    #   $1: file path (required)
    #   $2: prefix (optional, e.g., "NFTBAN")
    #
    # Returns:
    #   0: success
    #   1: file not readable
    #   2: syntax error or forbidden pattern detected
    #
    # Example:
    #   load_env_file "/etc/nftban/nftban.conf" "NFTBAN"
    #   # Sets: NFTBAN_VAR1=value1, NFTBAN_VAR2=value2, etc.

    local file="${1:?ERROR: load_env_file requires file path}"
    local prefix="${2:-}"

    # Check file exists and is readable
    if [[ ! -f "$file" ]]; then
        __envsafe_warn "File not found: $file"
        return 0  # Not an error - file might not exist yet
    fi

    if [[ ! -r "$file" ]]; then
        __envsafe_err "Cannot read file: $file (permission denied)"
        return 1
    fi

    # Validate file ownership (should be root:root or nftban:nftban)
    local file_owner
    file_owner="$(stat -c '%U' "$file" 2>/dev/null || stat -f '%Su' "$file" 2>/dev/null || echo "unknown")"
    if [[ "$file_owner" != "root" ]] && [[ "$file_owner" != "nftban" ]]; then
        __envsafe_err "File has dangerous ownership: $file (owner: $file_owner, expected: root or nftban)"
        return 2
    fi

    local line n=0 key val
    local __ENVSAFE_KEY __ENVSAFE_VALUE
    local errors=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # v1.19.20 FIX
        ((n++)) || true

        # Trim leading/trailing spaces
        line="${line##+([[:space:]])}"
        line="${line%%+([[:space:]])}"

        # Skip blank lines and comments
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        # Validate line for dangerous patterns
        if ! __envsafe_validate_line "$n" "$line" "$file"; then
            # v1.19.20 FIX
            ((errors++)) || true
            continue
        fi

        # Parse assignment
        if ! __envsafe_parse_assignment "$line"; then
            __envsafe_err "$file:$n: Invalid assignment syntax (expected: NAME=VALUE)"
            # v1.19.20 FIX
            ((errors++)) || true
            continue
        fi

        key="$__ENVSAFE_KEY"
        val="$__ENVSAFE_VALUE"

        # Export variable with optional prefix
        if [[ -n "$prefix" ]]; then
            # Namespaced variable: PREFIX_KEY
            export "${prefix}_${key}=${val}"
        else
            # Global variable: KEY
            export "${key}=${val}"
        fi

    done < "$file"

    # Return error if any dangerous patterns detected
    if ((errors > 0)); then
        __envsafe_err "Configuration file has $errors error(s): $file"
        __envsafe_err "REFUSING to load unsafe configuration!"
        return 2
    fi

    return 0
}

load_env_dir() {
    # Load all *.conf files from a directory
    # Files are loaded in alphabetical order
    #
    # Args:
    #   $1: directory path (required)
    #   $2: prefix (optional, e.g., "NFTBAN")
    #
    # Returns:
    #   0: success (or directory doesn't exist)
    #   1: error reading files
    #   2: syntax error in one or more files
    #
    # Example:
    #   load_env_dir "/etc/nftban/conf.d" "NFTBAN"

    local dir="${1:?ERROR: load_env_dir requires directory path}"
    local prefix="${2:-}"

    # Check directory exists
    if [[ ! -d "$dir" ]]; then
        return 0  # Not an error - directory might not exist yet
    fi

    local conf_file
    local errors=0
    local loaded=0

    # Load all *.conf files in alphabetical order
    for conf_file in "$dir"/*.conf; do
        # Skip if glob didn't match any files
        [[ -f "$conf_file" ]] || continue

        # Load file
        if load_env_file "$conf_file" "$prefix"; then
            # v1.19.20 FIX
            ((loaded++)) || true
        else
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    done

    if ((errors > 0)); then
        __envsafe_err "Failed to load $errors configuration file(s) from: $dir"
        return 2
    fi

    return 0
}

# =============================================================================
# MIGRATION HELPERS
# =============================================================================

migrate_from_source() {
    # Helper function to migrate from 'source' to 'load_env_file'
    # Prints migration instructions for a file
    #
    # Args:
    #   $1: file path
    #   $2: prefix (optional)
    #
    # Example:
    #   migrate_from_source "/etc/nftban/nftban.conf" "NFTBAN"

    local file="$1"
    local prefix="${2:-}"

    echo "=== Migration Instructions ==="
    echo ""
    echo "OLD (DANGEROUS):"
    echo "  source \"$file\""
    echo ""
    echo "NEW (SAFE):"
    if [[ -n "$prefix" ]]; then
        echo "  load_env_file \"$file\" \"$prefix\""
        echo ""
        echo "Access variables with prefix:"
        echo "  \${${prefix}_VARIABLE_NAME}"
    else
        echo "  load_env_file \"$file\""
        echo ""
        echo "Access variables normally:"
        echo "  \${VARIABLE_NAME}"
    fi
    echo ""
    echo "=== End Migration Instructions ==="
}

# =============================================================================
# TESTING & VALIDATION
# =============================================================================

test_config_safety() {
    # Test function to validate a config file without loading it
    # Args: file path
    # Returns: 0 if safe, non-zero if dangerous

    local file="${1:?ERROR: test_config_safety requires file path}"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file"
        return 1
    fi

    echo "Testing configuration file: $file"
    echo ""

    local line n=0
    local errors=0
    # shellcheck disable=SC2034  # Reserved for warning count
    local warnings=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # v1.19.20 FIX
        ((n++)) || true

        # Trim
        line="${line##+([[:space:]])}"
        line="${line%%+([[:space:]])}"

        # Skip blank/comments
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        # Validate
        if ! __envsafe_validate_line "$n" "$line" "$file"; then
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    done < "$file"

    echo ""
    if ((errors == 0)); then
        echo "✅ Configuration file is SAFE"
        return 0
    else
        echo "❌ Configuration file has $errors SECURITY ERROR(S)"
        echo "   REFUSING to load this file!"
        return 2
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main functions
export -f load_env_file
export -f load_env_dir
export -f test_config_safety
export -f migrate_from_source
