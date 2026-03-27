#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Path Validator Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="path_validator"
# meta:type="core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Cross-platform command path detection and validation for critical system utilities"
# meta:inventory.files=""
# meta:inventory.binaries="which"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PATH DETECTION AND VALIDATION
# ═══════════════════════════════════════════════════════════════════════════

# Global variables to store detected paths
declare -g NFT_PATH=""
declare -g SYSTEMCTL_PATH=""

# Search paths in order of priority
readonly SEARCH_PATHS=(
    "/usr/local/sbin"
    "/usr/local/bin"
    "/usr/sbin"
    "/usr/bin"
    "/sbin"
    "/bin"
)

##
# Detect command path by searching common locations
# Usage: detect_command_path "command_name"
# Returns: Full path to command, or empty string if not found
##
detect_command_path() {
    local cmd_name="$1"

    # Try 'command -v' first (respects PATH)
    if command -v "$cmd_name" &>/dev/null; then
        command -v "$cmd_name"
        return 0
    fi

    # Try 'which' as fallback
    if command -v which &>/dev/null; then
        local which_result
        which_result=$(which "$cmd_name" 2>/dev/null || true)
        if [[ -n "$which_result" ]] && [[ -x "$which_result" ]]; then
            echo "$which_result"
            return 0
        fi
    fi

    # Manual search through common paths
    for search_path in "${SEARCH_PATHS[@]}"; do
        local full_path="$search_path/$cmd_name"
        if [[ -x "$full_path" ]]; then
            echo "$full_path"
            return 0
        fi
    done

    # Not found
    return 1
}

##
# Validate and cache nft command path
# Sets: NFT_PATH global variable
# Returns: 0 if found, 1 if not found
##
validate_nft_path() {
    NFT_PATH=$(detect_command_path "nft" || echo "")

    if [[ -z "$NFT_PATH" ]]; then
        return 1
    fi

    # Verify it's executable and works
    if ! "$NFT_PATH" --version &>/dev/null; then
        NFT_PATH=""
        return 1
    fi

    return 0
}

##
# Validate and cache systemctl command path
# Sets: SYSTEMCTL_PATH global variable
# Returns: 0 if found, 1 if not found
##
validate_systemctl_path() {
    SYSTEMCTL_PATH=$(detect_command_path "systemctl" || echo "")

    if [[ -z "$SYSTEMCTL_PATH" ]]; then
        return 1
    fi

    # Verify it's executable
    if [[ ! -x "$SYSTEMCTL_PATH" ]]; then
        SYSTEMCTL_PATH=""
        return 1
    fi

    return 0
}

##
# Validate all critical paths
# Returns: 0 if all required commands found, 1 if any missing
##
validate_all_paths() {
    local missing_critical=0
    # shellcheck disable=SC2034  # Reserved for optional validation
    local missing_optional=0

    # Required: nft
    if ! validate_nft_path; then
        echo "✗ CRITICAL: nft command not found" >&2
        echo "  Install with: dnf install nftables (RHEL) or apt install nftables (Debian/Ubuntu)" >&2
        missing_critical=$((missing_critical + 1))
    fi

    # Required: systemctl
    if ! validate_systemctl_path; then
        echo "✗ CRITICAL: systemctl command not found" >&2
        echo "  systemd is required for NFTBan v1.0.0" >&2
        missing_critical=$((missing_critical + 1))
    fi

    if [[ $missing_critical -gt 0 ]]; then
        return 1
    fi

    return 0
}

##
# Print detected paths (for debugging)
##
print_detected_paths() {
    echo "═══════════════════════════════════════════════════════════"
    echo "Detected Command Paths:"
    echo "═══════════════════════════════════════════════════════════"

    if [[ -n "$NFT_PATH" ]]; then
        echo "✓ nft: $NFT_PATH"
        "$NFT_PATH" --version 2>&1 | head -1 | sed 's/^/  /'
    else
        echo "✗ nft: NOT FOUND"
    fi

    if [[ -n "$SYSTEMCTL_PATH" ]]; then
        echo "✓ systemctl: $SYSTEMCTL_PATH"
        "$SYSTEMCTL_PATH" --version 2>&1 | head -1 | sed 's/^/  /'
    else
        echo "✗ systemctl: NOT FOUND"
    fi

    echo "═══════════════════════════════════════════════════════════"
}

##
# Export paths to environment (for use in other scripts)
##
export_paths_to_env() {
    export NFTBAN_NFT_PATH="$NFT_PATH"
    export NFTBAN_SYSTEMCTL_PATH="$SYSTEMCTL_PATH"
}

##
# Write detected paths to config file for persistence
# Usage: save_paths_to_config "/etc/nftban/nftban.conf"
##
save_paths_to_config() {
    local config_file="${1:-/etc/nftban/nftban.conf}"

    if [[ ! -w "$config_file" ]]; then
        echo "ERROR: Cannot write to $config_file" >&2
        return 1
    fi

    # Remove old path entries if they exist
    sed -i '/^NFTBAN_NFT_PATH=/d' "$config_file" 2>/dev/null || true
    sed -i '/^NFTBAN_SYSTEMCTL_PATH=/d' "$config_file" 2>/dev/null || true

    # Append new paths
    {
        echo ""
        echo "# Auto-detected command paths (updated: $(date '+%Y-%m-%d %H:%M:%S'))"
        echo "NFTBAN_NFT_PATH=\"$NFT_PATH\""
        echo "NFTBAN_SYSTEMCTL_PATH=\"$SYSTEMCTL_PATH\""
    } >> "$config_file"

    echo "✓ Paths saved to $config_file"
    return 0
}

##
# Load paths from config file
# Usage: load_paths_from_config "/etc/nftban/nftban.conf"
##
load_paths_from_config() {
    local config_file="${1:-/etc/nftban/nftban.conf}"

    if [[ ! -r "$config_file" ]]; then
        return 1
    fi

    # Source the config file to load variables
    # config path determined at runtime from validation args
    # shellcheck disable=SC1090
    source "$config_file" 2>/dev/null || return 1

    # Set global variables from config
    NFT_PATH="${NFTBAN_NFT_PATH:-}"
    SYSTEMCTL_PATH="${NFTBAN_SYSTEMCTL_PATH:-}"

    # Verify paths still exist and are executable
    if [[ -n "$NFT_PATH" ]] && [[ ! -x "$NFT_PATH" ]]; then
        NFT_PATH=""
    fi

    if [[ -n "$SYSTEMCTL_PATH" ]] && [[ ! -x "$SYSTEMCTL_PATH" ]]; then
        SYSTEMCTL_PATH=""
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════

# If sourced, try to load paths from config first, then validate if needed
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script is being sourced
    if load_paths_from_config "/etc/nftban/nftban.conf"; then
        # Paths loaded from config, verify they're still valid
        if [[ -z "$NFT_PATH" ]] || [[ ! -x "$NFT_PATH" ]]; then
            validate_all_paths &>/dev/null || true
        fi
    else
        # No config or paths invalid, detect fresh
        validate_all_paths &>/dev/null || true
    fi

    # Export to environment for other scripts
    export_paths_to_env
fi

# If executed directly, run validation and show results
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "NFTBan Path Validator v1.0.0"
    echo ""

    if validate_all_paths; then
        print_detected_paths
        echo ""
        echo "✅ All required commands found!"
        exit 0
    else
        print_detected_paths
        echo ""
        echo "❌ Some required commands are missing!"
        echo "Please install missing packages and try again."
        exit 1
    fi
fi
