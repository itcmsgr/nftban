#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Setup Utilities Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Common utility functions for setup scripts
# Location: /usr/lib/nftban/lib/setup_utils.sh
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:name=setup_utils
# meta:type=lib
# meta:header=Setup Utilities Library
# meta:version=1.0.0
#
# **Description & Purpose**
# meta:description=Common utility functions shared across all setup scripts
# meta:input=None
# meta:output=Utility functions for printing, distro detection, root checks
#
# **Functions Provided**
# - print_status(): Print success message with green checkmark
# - print_error(): Print error message with red X to stderr
# - print_info(): Print info message with yellow indicator
# - check_root(): Verify script is running as root
# - detect_distro(): Detect Linux distribution ID
# - detect_pkg_manager(): Detect package manager for distro
#
# meta:created_date=2025-12-02
# =============================================================================

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

# Print informational message with yellow indicator
# Usage: print_info "Info message"
print_info() {
    echo -e "${SETUP_YELLOW}[i]${SETUP_NC} $1" >&2
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
# Copyright © 2024-2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
# =============================================================================
