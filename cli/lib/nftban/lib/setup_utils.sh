#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="setup_utils" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Common utility functions shared across all setup scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Guard against multiple sourcing
[[ -n "${_NFTBAN_SETUP_UTILS_LOADED:-}" ]] && return 0
readonly _NFTBAN_SETUP_UTILS_LOADED=1

# =============================================================================
# COLORS
# =============================================================================

# Only set colors if not already defined (allow overrides)
readonly SETUP_RED="${RED:-\033[0;31m}"
readonly SETUP_GREEN="${GREEN:-\033[0;32m}"
readonly SETUP_YELLOW="${YELLOW:-\033[1;33m}"
readonly SETUP_NC="${NC:-\033[0m}"

# =============================================================================
# PRINT FUNCTIONS
# =============================================================================

# Print success message with green checkmark
# Usage: print_status "Message"
print_status() {
    echo -e "${SETUP_GREEN}[✓]${SETUP_NC} $1" >&2
}

# Print error message with red X to stderr
# Usage: print_error "Error message"
print_error() {
    echo -e "${SETUP_RED}[✗]${SETUP_NC} $1" >&2
}

# Print warning message with yellow indicator
# Usage: print_warn "Warning message"
print_warn() {
    echo -e "${SETUP_YELLOW}[!]${SETUP_NC} $1" >&2
}

# Print informational message with blue indicator
# Usage: print_info "Info message"
print_info() {
    local SETUP_BLUE="${BLUE:-\033[0;34m}"
    echo -e "${SETUP_BLUE}[i]${SETUP_NC} $1" >&2
}

# =============================================================================
# SYSTEM DETECTION FUNCTIONS
# =============================================================================

# Check if script is running as root
# Usage: check_root || exit 1
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        return 1
    fi
    return 0
}

# Detect Linux distribution ID
# Usage: distro=$(detect_distro)
# Returns: Distribution ID (e.g., "fedora", "ubuntu", "rocky", "debian")
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # Source to get ID variable
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Detect package manager for a given distribution
# Usage: pkg_mgr=$(detect_pkg_manager "$distro")
# Returns: "dnf", "apt", or "unknown"
detect_pkg_manager() {
    local distro="${1:-$(detect_distro)}"

    case "$distro" in
        centos|rhel|fedora|rocky|alma*)
            echo "dnf"
            ;;
        debian|ubuntu)
            echo "apt"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f print_status
export -f print_error
export -f print_info
export -f check_root
export -f detect_distro
export -f detect_pkg_manager

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
# =============================================================================
