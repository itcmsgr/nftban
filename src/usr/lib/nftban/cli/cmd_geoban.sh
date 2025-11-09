#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.25 - GeoBan CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for country-based IP blocking (wrapper for geoip)
#
# meta:name=cmd_geoban
# meta:type=cli
# meta:header=GeoBan CLI Handler
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-11-06
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_GEOBAN_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_GEOBAN_LOADED=1

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_geoban() {
    # Main GeoBan command handler - wraps geoip commands
    # Args: subcommand [options]
    #
    # This provides a user-friendly alias:
    #   nftban geoban ban CN    ->  nftban geoban ban CN
    #   nftban geoban whitelist US  ->  nftban geoban whitelist US

    local subcommand="${1:-help}"

    # Load geoip command handler
    if ! declare -f nftban_cmd_geoip >/dev/null 2>&1; then
        source /usr/lib/nftban/cli/cmd_geoip.sh || {
            echo "ERROR: Failed to load geoip command handler" >&2
            return 1
        }
    fi

    # Map geoban subcommands to geoip subcommands
    case "$subcommand" in
        ban|unban|whitelist|unwhitelist|list|update|status|config|refresh)
            # Pass directly to geoip handler
            nftban_cmd_geoip "$@"
            ;;
        help|--help|-h)
            nftban_geoban_help
            ;;
        *)
            echo "ERROR: Unknown geoban command: $subcommand" >&2
            nftban_geoban_help
            return 1
            ;;
    esac
}

# =============================================================================
# HELP
# =============================================================================

nftban_geoban_help() {
    cat <<'EOF'
🐧🛡️ NFTBan v0.32.25 - GeoBan Country Blocking
ban · unban · protect

Usage:
  nftban geoban ban <CC> [CC...]           # Ban country traffic
  nftban geoban unban <CC> [CC...]         # Remove country ban
  nftban geoban whitelist <CC> [CC...]     # Whitelist country (allow)
  nftban geoban unwhitelist <CC> [CC...]   # Remove country whitelist
  nftban geoban list                       # List active country blocks
  nftban geoban status                     # Show GeoBan status
  nftban geoban update                     # Update all active countries
  nftban geoban config                     # Show GeoBan configuration
  nftban geoban help                       # Show this help

Country Codes:
  Use ISO 3166-1 alpha-2 codes (2 letters, uppercase)
  Examples: CN (China), RU (Russia), US (United States), GB (United Kingdom)

Examples:
  nftban geoban ban CN RU              # Block China and Russia
  nftban geoban whitelist US GB        # Allow USA and UK
  nftban geoban list                   # Show active blocks
  nftban geoban unban CN               # Remove China block
  nftban geoban status                 # Check GeoBan status

Features:
  • Atomic Operations: Zero-downtime updates via netlink
  • RIR Data Sources: ARIN, RIPE, APNIC, LACNIC, AFRINIC
  • ETag Caching: Reduces bandwidth and API rate limits
  • CIDR Merging: Optimizes memory footprint
  • Safety Limits: CPU/RAM monitoring prevents system overload

Notes:
  • GeoBan uses the nftban-geoip Go binary for performance
  • Changes are applied atomically to running firewall
  • Country IP lists are cached in /var/cache/nftban/geoban/
  • Configuration files stored in /etc/nftban/geoban.d/

EOF
}

# Export the main function
export -f nftban_cmd_geoban
