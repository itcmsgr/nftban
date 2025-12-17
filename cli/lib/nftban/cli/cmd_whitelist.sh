#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Whitelist Command Alias
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Friendly alias for whitelist-system command
#
# meta:name=cmd_whitelist
# meta:type=cli
# meta:header=NFTBan Whitelist Alias
# meta:version=1.0.0
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
# meta:updated_date=2025-11-24


# =============================================================================
# CONFIGURATION
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi

# =============================================================================

# COMMAND HANDLER
# =============================================================================


nftban_cmd_whitelist() {
    # Alias wrapper for whitelist-system
    # Args: subcommand and options (passed through)
    # Banner is shown by whitelist-system module

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


# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "whitelist"

export -f nftban_cmd_whitelist

# =============================================================================

# DIRECT EXECUTION SUPPORT
# =============================================================================


# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_whitelist "$@"
fi
