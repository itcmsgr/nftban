#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Search Command
# Version: 1.0.0
# Location: lib/cli/cmd_search.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_search_module.sh
# Description: IP search across all lists and logs
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# SEARCH COMMAND HANDLER
# =============================================================================

cmd_search() {
    local search_type="${1:-}"
    shift || true

    if [[ "$search_type" == "ip" ]]; then
        [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban search ip <IP_ADDRESS>"; exit 1; }
        nftban_search_ip_everywhere "$1"
    else
        nftban_log_error "Usage: nftban search ip <IP_ADDRESS>"
        echo ""
        echo "Examples:"
        echo "  nftban search ip 192.168.1.100"
        echo "  nftban search ip 2001:db8::1"
        exit 1
    fi
}

# Export function
export -f cmd_search
