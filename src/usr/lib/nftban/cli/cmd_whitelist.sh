#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.6 - Whitelist Command Alias
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Friendly alias for whitelist-system command
#
# meta:name=cmd_whitelist
# meta:type=cli
# meta:header=NFTBan Whitelist Alias
# meta:version=0.32.6
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=User-friendly alias for whitelist-system (shorter command name)
# meta:input=Subcommands and options (sync, show, whitelistme, help)
# meta:output=Passes through to whitelist-system command
#
# **Inventory & Requirements**
# meta:depends=bash,cmd_whitelist_system.sh
#
# meta:created_date=2025-11-05

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_whitelist() {
    # Alias wrapper for whitelist-system
    # Args: subcommand and options (passed through)

    # Load whitelist-system module
    if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh"

        # Pass through to whitelist-system handler
        nftban_cmd_whitelist_system "$@"
    else
        echo "ERROR: Whitelist system module not found" >&2
        echo "Expected: ${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh" >&2
        return 1
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_whitelist

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_whitelist "$@"
fi
