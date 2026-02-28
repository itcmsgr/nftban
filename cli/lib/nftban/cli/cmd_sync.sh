#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Sync CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI command for atomic firewall reload
#
# meta:name="cmd_sync"
# meta:type="cli"
# meta:header="Sync CLI Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI command for atomic firewall reload"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-18"
# =============================================================================

# Strict mode

# Load required modules
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

if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_sync.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_sync.sh"
else
    echo "ERROR: Sync module not found: ${NFTBAN_LIB_DIR}/core/nftban_sync.sh" >&2
    exit 1
fi

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

cmd_sync_help() {
    echo "Usage: nftban sync [subcommand]"
    echo ""
    echo "Subcommands:"
    echo "  full      Full atomic sync (default)"
    echo "  validate  Validate only"
    echo "  status    Show sync status"
    echo "  --dry-run Dry run mode"
    echo "  help      Show full help"
}

nftban_cmd_sync() {
    # Main sync command handler
    # Routes subcommands to appropriate functions

    local subcommand="${1:-}"

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        ""|full)
            # Full sync (default)
            shift || true
            nftban_sync_full "$@"
            ;;

        validate)
            # Validate only
            nftban_sync_validate
            ;;

        status)
            # Show status
            nftban_sync_status
            ;;

        help|--help|-h)
            # Show help
            nftban_sync_help
            ;;

        --dry-run)
            # Dry run mode
            nftban_sync_full --dry-run
            ;;

        --quick|-q|quick)
            # BUG-LOW-001 FIX: Quick sync for postinst (skip feeds/geoban)
            # Use for fast restarts when feeds/geoban don't need reloading
            nftban_sync_full --quick
            ;;

        *)
            nftban_output "error" "Unknown sync subcommand: $subcommand"
            nftban_output "info" "Run 'nftban sync help' for usage"
            return 1
            ;;
    esac
}

# Export main function
export -f nftban_cmd_sync
