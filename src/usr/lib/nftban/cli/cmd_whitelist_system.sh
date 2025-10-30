#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - System Whitelist CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System IP Whitelist Management

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

case "${1:-}" in
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
        exit 0
        ;;

    *)
        echo "ERROR: Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
