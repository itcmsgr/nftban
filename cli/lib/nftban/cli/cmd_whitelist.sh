#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Whitelist Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_whitelist"
# meta:type="cli"
# meta:header="Whitelist IP management"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Add, remove, and list whitelisted IPs"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-11"


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

# v1.18.0: Load IPC library for daemon communication
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# =============================================================================

# COMMAND HANDLER
# =============================================================================


nftban_cmd_whitelist() {
    # Whitelist management - add/remove IPs or pass to whitelist-system
    # Args: subcommand and options

    local subcommand="${1:-help}"
    shift 2>/dev/null || true

    case "$subcommand" in
        add)
            # Add IP to whitelist
            local ip="${1:-}"
            if [[ -z "$ip" || "$ip" == "--help" || "$ip" == "-h" ]]; then
                echo "Usage: nftban whitelist add <IP>" >&2
                echo "Example: nftban whitelist add 192.168.1.100" >&2
                return 0
            fi
            nftban_whitelist_add_ip "$ip"
            ;;
        remove|rm|del|delete)
            # Remove IP from whitelist
            local ip="${1:-}"
            if [[ -z "$ip" || "$ip" == "--help" || "$ip" == "-h" ]]; then
                echo "Usage: nftban whitelist remove <IP>" >&2
                echo "Example: nftban whitelist remove 192.168.1.100" >&2
                return 0
            fi
            nftban_whitelist_remove_ip "$ip"
            ;;
        list|show)
            # Show whitelist
            nftban_whitelist_list
            ;;
        sync|whitelistme)
            # Pass to whitelist-system for these commands
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh" ]]; then
                source "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh"
                nftban_cmd_whitelist_system "$subcommand" "$@"
            else
                echo "ERROR: Whitelist system module not found" >&2
                return 1
            fi
            ;;
        help|--help|-h|"")
            nftban_whitelist_usage
            ;;
        *)
            echo "ERROR: Unknown whitelist command: $subcommand" >&2
            nftban_whitelist_usage
            return 1
            ;;
    esac
}

# Add IP to whitelist via IPC (v1.18.0: IPC-only writes)
nftban_whitelist_add_ip() {
    local ip="$1"

    # Validate IP format and determine family
    local table set_name family
    if [[ "$ip" =~ : ]]; then
        # IPv6
        table="ip6 nftban"
        set_name="whitelist_ipv6"
        family="IPv6"
    else
        # IPv4
        table="ip nftban"
        set_name="whitelist_ipv4"
        family="IPv4"
    fi

    # Use IPC for add operation
    if declare -f nft_ipc_add_element &>/dev/null && nft_ipc_add_element "$table" "$set_name" "$ip" 2>/dev/null; then
        # Verify addition (read-only check)
        if nft get element ${table} ${set_name} "{ $ip }" &>/dev/null; then
            echo "Added $ip to $family whitelist"
            return 0
        else
            echo "Added $ip to $family whitelist (IPC success, verification pending)"
            return 0
        fi
    else
        echo "ERROR: Failed to add $ip to whitelist via IPC" >&2
        return 1
    fi
}

# Remove IP from whitelist via IPC (v1.18.0: IPC-only writes)
nftban_whitelist_remove_ip() {
    local ip="$1"

    # Validate IP format and determine family
    local table set_name family
    if [[ "$ip" =~ : ]]; then
        # IPv6
        table="ip6 nftban"
        set_name="whitelist_ipv6"
        family="IPv6"
    else
        # IPv4
        table="ip nftban"
        set_name="whitelist_ipv4"
        family="IPv4"
    fi

    # Use IPC for delete operation
    if declare -f nft_ipc_delete_element &>/dev/null && nft_ipc_delete_element "$table" "$set_name" "$ip" 2>/dev/null; then
        # Verify removal (read-only check)
        if ! nft get element ${table} ${set_name} "{ $ip }" &>/dev/null; then
            echo "Removed $ip from $family whitelist"
            return 0
        else
            echo "Removed $ip from $family whitelist (IPC success, verification pending)"
            return 0
        fi
    else
        echo "ERROR: Failed to remove $ip from whitelist via IPC (may not exist)" >&2
        return 1
    fi
}

# List whitelisted IPs
nftban_whitelist_list() {
    echo "IPv4 Whitelist:"
    echo "───────────────"
    timeout 10s nft list set ip nftban whitelist_ipv4 2>/dev/null | grep -E "elements.*=" | sed 's/.*= {//' | sed 's/}//' | tr ',' '\n' | sed 's/^[[:space:]]*/  /' || echo "  (empty or not available)"
    echo ""
    echo "IPv6 Whitelist:"
    echo "───────────────"
    timeout 10s nft list set ip6 nftban whitelist_ipv6 2>/dev/null | grep -E "elements.*=" | sed 's/.*= {//' | sed 's/}//' | tr ',' '\n' | sed 's/^[[:space:]]*/  /' || echo "  (empty or not available)"
}

# Show usage
nftban_whitelist_usage() {
    cat <<'EOF'
Usage: nftban whitelist <command> [IP]

COMMANDS:
  add <IP>          Add IP to whitelist (permanent protection from banning)
  remove <IP>       Remove IP from whitelist
  list              Show all whitelisted IPs
  sync              Auto-detect and whitelist system IPs
  whitelistme       Whitelist your current IP (interactive)

EXAMPLES:
  nftban whitelist add 192.168.1.100
  nftban whitelist add 2001:db8::1
  nftban whitelist remove 192.168.1.100
  nftban whitelist list
  nftban whitelist sync

EOF
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
