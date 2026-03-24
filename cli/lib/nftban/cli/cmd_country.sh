#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.4 - Country Command (Alias for GeoBan)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI alias for country-based IP blocking (delegates to geoban)
#
# meta:name="cmd_country"
# meta:type="cli"
# meta:header="Country Command (GeoBan Alias)"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI alias for country-based IP blocking - delegates to geoban"
# meta:input="Command line arguments (same as geoban)"
# meta:output="GeoBan management output"
# meta:depends="bash,cmd_geoban.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Guard against multiple sourcing
[[ -n "${CMD_COUNTRY_LOADED:-}" ]] && return 0
readonly CMD_COUNTRY_LOADED=1

# Determine library directory
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Source the geoban handler
GEOBAN_HANDLER="${NFTBAN_LIB_DIR}/cli/cmd_geoban.sh"
if [[ -f "$GEOBAN_HANDLER" ]]; then
    # shellcheck source=/dev/null
    source "$GEOBAN_HANDLER" || return 1
else
    echo "ERROR: GeoBan handler not found: $GEOBAN_HANDLER" >&2
    return 1
fi

# =============================================================================
# COMMAND HANDLER
# =============================================================================

cmd_country_help() {
    echo "Usage: nftban country [options]"
    echo ""
    echo "Alias for 'nftban geoban' - country-based IP blocking"
    echo ""
    echo "Options passed to geoban subcommand."
    echo "Run 'nftban geoban --help' for details."
}

nftban_cmd_country() {
    # Country command - alias for geoban
    # Delegates all arguments to nftban_cmd_geoban
    case "${1:-}" in
        -h|--help|help) cmd_country_help; return 0 ;;
    esac
    nftban_cmd_geoban "$@"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_country

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_country "$@"
fi
