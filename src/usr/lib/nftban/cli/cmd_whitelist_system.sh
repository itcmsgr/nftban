#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - System Whitelist CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System IP Whitelist Management
#
# meta:name=cmd_whitelist_system
# meta:type=cli
# meta:header=System Whitelist CLI Handler
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for system IP whitelist management and synchronization
# meta:input=Whitelist commands and IP addresses
# meta:output=Whitelist status and synchronization results
#
# **Inventory & Requirements**
# meta:depends=nftban_system_ip.sh,nftban_nftables.sh,nftban_file_ops.sh
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load system IP module
if [[ -f "/usr/lib/nftban/core/nftban_system_ip.sh" ]]; then
    source /usr/lib/nftban/core/nftban_system_ip.sh
else
    echo "ERROR: System IP module not found"
    exit 1
fi

# Load atomic reload if available
if [[ -f "/usr/lib/nftban/core/nftban_nftables.sh" ]]; then
    source /usr/lib/nftban/core/nftban_nftables.sh
fi

# Load atomic file ops if available
if [[ -f "/usr/lib/nftban/core/nftban_file_ops.sh" ]]; then
    source /usr/lib/nftban/core/nftban_file_ops.sh
fi

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    cat <<'EOF'
Usage: nftban whitelist-system <command>

COMMANDS:
  sync              Auto-detect and whitelist all system IPs
  show              Show current system whitelist
  whitelistme       Whitelist your current IP (interactive)

EXAMPLES:
  # Auto-detect and protect all system IPs
  sudo nftban whitelist-system sync

  # Show protected system IPs
  nftban whitelist-system show

  # Protect your current IP from being banned
  sudo nftban whitelist-system whitelistme

WHAT IS AUTO-DETECTED:
  • Localhost (127.0.0.1, ::1)
  • All server interface IPs (IPv4 + IPv6)
  • Server public IPv4
  • Server public IPv6

SAFE TO RUN:
  This command only ADDS IPs to whitelist, never removes them.
  It's safe to run multiple times (skips already whitelisted IPs).

EOF
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_whitelist_system() {
    # Main command handler for whitelist-system
    # Args: subcommand and options

    local subcommand="${1:-help}"
    shift || true

    case "$subcommand" in
        sync)
            # Auto-detect and whitelist all system IPs
            nftban_whitelist_system_sync
            ;;

        show)
            # Show current system whitelist
            nftban_show_system_whitelist
            ;;

        whitelistme)
            # Whitelist current user's IP
            nftban_whitelistme
            ;;

        help|--help|-h|"")
            show_usage
            return 0
            ;;

        *)
            echo "ERROR: Unknown command: $subcommand" >&2
            echo "" >&2
            show_usage
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_whitelist_system

# =============================================================================
# DIRECT EXECUTION SUPPORT (for backward compatibility)
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_whitelist_system "$@"
fi
