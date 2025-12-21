#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Version Management Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Single source of truth for all version numbers
#
# meta:name=version
# meta:type=library
# meta:header=Version Management
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Centralized version management for all NFTBan components
# meta:input=None (sourced by other scripts)
# meta:output=Version constants and functions
#
# **Inventory & Requirements**
# meta:depends=bash>=4.0
#
# **Usage**
# Source this file to get version information:
#   source "${NFTBAN_LIB_DIR}/lib/version.sh"
#   echo "$NFTBAN_VERSION"
#
# meta:created_date=2025-11-24
# =============================================================================

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

[[ -n "${NFTBAN_VERSION_LOADED:-}" ]] && return 0

# =============================================================================
# VERSION CONSTANTS
# =============================================================================

# Main NFTBan version
readonly NFTBAN_VERSION="1.0.0"
readonly NFTBAN_VERSION_MAJOR="1"
readonly NFTBAN_VERSION_MINOR="0"
readonly NFTBAN_VERSION_PATCH="0"

# Version details
readonly NFTBAN_VERSION_NAME="Unified Security Platform"
readonly NFTBAN_VERSION_DATE="2025-12-01"
NFTBAN_BUILD_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
readonly NFTBAN_BUILD_DATE

# Component versions (kept in sync with main version)
readonly NFTBAN_CLI_VERSION="$NFTBAN_VERSION"
readonly NFTBAN_CORE_VERSION="$NFTBAN_VERSION"
readonly NFTBAN_GUI_VERSION="$NFTBAN_VERSION"
readonly NFTBAN_API_VERSION="$NFTBAN_VERSION"

# Compatibility
readonly NFTBAN_MIN_BASH_VERSION="4.0"
readonly NFTBAN_MIN_NFT_VERSION="0.9.3"

# =============================================================================
# VERSION INFORMATION FUNCTIONS
# =============================================================================

nftban_version_full() {
    # Get full version string
    # Returns: "NFTBan v0.6.5 (Strict Mode) - 2025-11-24"
    echo "NFTBan v${NFTBAN_VERSION} (${NFTBAN_VERSION_NAME}) - ${NFTBAN_VERSION_DATE}"
}

nftban_version_short() {
    # Get short version string
    # Returns: "0.6.5"
    echo "$NFTBAN_VERSION"
}

nftban_version_numeric() {
    # Get numeric version for comparison
    # Returns: 605 (for 0.6.5)
    echo "$((NFTBAN_VERSION_MAJOR * 10000 + NFTBAN_VERSION_MINOR * 100 + NFTBAN_VERSION_PATCH))"
}

nftban_version_check() {
    # Check if a version requirement is met
    # Args: $1 = required version (e.g., "0.6.0")
    # Returns: 0 if current version >= required, 1 otherwise

    local required="$1"
    local required_major required_minor required_patch

    IFS='.' read -r required_major required_minor required_patch <<< "$required"

    local required_numeric=$((required_major * 10000 + required_minor * 100 + required_patch))
    local current_numeric
    current_numeric=$(nftban_version_numeric)

    [[ $current_numeric -ge $required_numeric ]]
}

nftban_version_info() {
    # Print detailed version information
    cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan Version Information
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Version:        ${NFTBAN_VERSION}
Name:           ${NFTBAN_VERSION_NAME}
Release Date:   ${NFTBAN_VERSION_DATE}
Build Date:     ${NFTBAN_BUILD_DATE}

Components:
  CLI:          ${NFTBAN_CLI_VERSION}
  Core:         ${NFTBAN_CORE_VERSION}
  GUI:          ${NFTBAN_GUI_VERSION}
  API:          ${NFTBAN_API_VERSION}

Requirements:
  Bash:         >= ${NFTBAN_MIN_BASH_VERSION}
  nftables:     >= ${NFTBAN_MIN_NFT_VERSION}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =============================================================================
# COMPATIBILITY CHECK
# =============================================================================

nftban_version_check_requirements() {
    # Check if system meets minimum requirements
    # Returns: 0 if all requirements met, 1 otherwise

    local status=0

    # Check bash version
    if [[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" < "$NFTBAN_MIN_BASH_VERSION" ]]; then
        echo "ERROR: Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} is too old. Need >= $NFTBAN_MIN_BASH_VERSION" >&2
        status=1
    fi

    # Check nftables version (if nft is available)
    if command -v nft &>/dev/null; then
        local nft_version
        nft_version=$(nft --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        if [[ -n "$nft_version" ]]; then
            # Simple version comparison (works for most cases)
            if [[ "$nft_version" < "$NFTBAN_MIN_NFT_VERSION" ]]; then
                echo "WARNING: nftables $nft_version may be too old. Recommend >= $NFTBAN_MIN_NFT_VERSION" >&2
            fi
        fi
    fi

    return $status
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_version_full
export -f nftban_version_short
export -f nftban_version_numeric
export -f nftban_version_check
export -f nftban_version_info
export -f nftban_version_check_requirements

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_VERSION_LOADED=1
export NFTBAN_VERSION_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
