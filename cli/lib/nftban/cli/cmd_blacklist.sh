#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.23.0 - Blacklist Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_blacklist"
# meta:type="cli"
# meta:header="Blacklist IP management"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Add, remove, list, and flush blacklisted (banned) IPs"
# meta:inventory.files=""
# meta:inventory.binaries="nft,nftban-core"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="blacklist.d/*.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-03-18"
# meta:updated_date="2026-03-18"

# =============================================================================
# CONFIGURATION
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Table/set names from central config
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_BLACKLIST_DIR:=${NFTBAN_CONFIG_DIR}/blacklist.d}"

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_blacklist() {
    local subcommand="${1:-help}"
    shift 2>/dev/null || true

    case "$subcommand" in
        add|ban)
            # Delegate to nftban ban (the canonical blacklist-add mechanism)
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_ban.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/cli/cmd_ban.sh" || return 1
                nftban_cmd_ban "$@"
            else
                echo "ERROR: cmd_ban.sh not found" >&2
                return 1
            fi
            ;;
        remove|rm|del|delete|unban)
            # Delegate to nftban unban (the canonical blacklist-remove mechanism)
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_unban.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/cli/cmd_unban.sh" || return 1
                nftban_cmd_unban "$@"
            else
                echo "ERROR: cmd_unban.sh not found" >&2
                return 1
            fi
            ;;
        list|show)
            nftban_blacklist_list "$@"
            ;;
        files|config)
            nftban_blacklist_files
            ;;
        count)
            nftban_blacklist_count "$@"
            ;;
        flush)
            # Delegate to nftban flush blacklist
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_flush.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/cli/cmd_flush.sh" || return 1
                nftban_cmd_flush "blacklist" "$@"
            else
                echo "ERROR: cmd_flush.sh not found" >&2
                return 1
            fi
            ;;
        reconcile)
            # Trigger manual reconciliation via daemon IPC (v1.35.0)
            echo "Triggering blacklist reconciliation..."
            local ipc_helper="${NFTBAN_LIB_DIR}/helpers/ipc_client.sh"
            if [[ -f "$ipc_helper" ]]; then
                # shellcheck source=/dev/null
                source "$ipc_helper" || return 1
                local result
                result=$(nftban_ipc_send '{"method":"reconcile"}' 2>&1)
                if echo "$result" | grep -q '"success":true'; then
                    echo "Reconciliation completed successfully"
                    echo "$result" | grep -o '"data":"[^"]*"' | sed 's/"data":"//;s/"//'
                else
                    echo "ERROR: Reconciliation failed" >&2
                    echo "$result" >&2
                    return 1
                fi
            else
                echo "ERROR: IPC client not found. Is nftband running?" >&2
                return 1
            fi
            ;;
        help|--help|-h|"")
            nftban_blacklist_usage
            ;;
        *)
            echo "ERROR: Unknown blacklist command: $subcommand" >&2
            nftban_blacklist_usage
            return 1
            ;;
    esac
}

# =============================================================================
# LIST - Show blacklisted IPs from nftables sets
# =============================================================================

nftban_blacklist_list() {
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" == "true" ]]; then
        # Delegate to nftban list banned --json
        if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_list.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/cli/cmd_list.sh" || return 1
            nftban_cmd_list banned --json
        fi
        return $?
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Blacklist - Banned IPs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # IPv4 blacklist from nftables
    echo "IPv4 Blacklist (nftables):"
    echo "──────────────────────────"
    # shellcheck disable=SC2086
    local ipv4_output
    ipv4_output=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null) || true
    if [[ -n "$ipv4_output" ]]; then
        local ipv4_elements
        ipv4_elements=$(echo "$ipv4_output" | tr '\n' ' ' | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*/  /' | grep -v '^[[:space:]]*$' || true)
        if [[ -n "$ipv4_elements" ]]; then
            echo "$ipv4_elements"
        else
            echo "  (empty)"
        fi
    else
        echo "  (not available)"
    fi

    echo ""

    # IPv6 blacklist from nftables
    echo "IPv6 Blacklist (nftables):"
    echo "──────────────────────────"
    # shellcheck disable=SC2086
    local ipv6_output
    ipv6_output=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null) || true
    if [[ -n "$ipv6_output" ]]; then
        local ipv6_elements
        ipv6_elements=$(echo "$ipv6_output" | tr '\n' ' ' | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | tr ',' '\n' | sed 's/^[[:space:]]*/  /' | grep -v '^[[:space:]]*$' || true)
        if [[ -n "$ipv6_elements" ]]; then
            echo "$ipv6_elements"
        else
            echo "  (empty)"
        fi
    else
        echo "  (not available)"
    fi

    echo ""

    # Count from config files
    local config_count=0
    if [[ -d "$NFTBAN_BLACKLIST_DIR" ]]; then
        config_count=$(grep -vhE '^\s*(#|$)' "${NFTBAN_BLACKLIST_DIR}"/*.conf 2>/dev/null | grep -cE '.' || true)
    fi
    echo "Config files: ${config_count} persistent entries in ${NFTBAN_BLACKLIST_DIR}/"
    echo ""
    echo "Use 'nftban blacklist files' to see config file details."
}

# =============================================================================
# FILES - Show blacklist config file contents
# =============================================================================

nftban_blacklist_files() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Blacklist Config Files"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Directory: ${NFTBAN_BLACKLIST_DIR}/"
    echo ""

    if [[ ! -d "$NFTBAN_BLACKLIST_DIR" ]]; then
        echo "  (directory not found)"
        return 0
    fi

    local found=false
    local total_ips=0

    for conf_file in "${NFTBAN_BLACKLIST_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        found=true
        local basename
        basename=$(basename "$conf_file")
        local count
        count=$(grep -cvE '^\s*(#|$)' "$conf_file" 2>/dev/null || echo "0")
        total_ips=$((total_ips + count))

        echo "──────────────────────────────────────────────────────────────"
        printf "  %-40s %d IPs\n" "$basename" "$count"
        echo "──────────────────────────────────────────────────────────────"

        # Show IPs (first 20, with truncation notice)
        local ips
        ips=$(grep -vE '^\s*(#|$)' "$conf_file" 2>/dev/null | head -20 || true)
        if [[ -n "$ips" ]]; then
            echo "$ips" | sed 's/^/    /'
            local actual_count
            actual_count=$(grep -cvE '^\s*(#|$)' "$conf_file" 2>/dev/null || echo "0")
            if [[ "$actual_count" -gt 20 ]]; then
                echo "    ... and $((actual_count - 20)) more"
            fi
        else
            echo "    (empty)"
        fi
        echo ""
    done

    if [[ "$found" == "false" ]]; then
        echo "  (no config files found)"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Total: ${total_ips} persistent blacklist entries"
    fi
}

# =============================================================================
# COUNT - Quick IP count
# =============================================================================

nftban_blacklist_count() {
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    # Count from nftables sets
    # v1.24.0: Capture output first, then count — prevents pipefail empty variable crash
    # shellcheck disable=SC2086
    local nft_ipv4_count=0 nft_ipv6_count=0
    local ipv4_raw=""
    ipv4_raw=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null) || ipv4_raw=""
    if [[ -n "$ipv4_raw" ]]; then
        nft_ipv4_count=$(echo "$ipv4_raw" | tr '\n' ' ' | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | tr ',' '\n' | grep -cE '[0-9a-fA-F]') || nft_ipv4_count=0
    fi

    # shellcheck disable=SC2086
    local ipv6_raw=""
    ipv6_raw=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null) || ipv6_raw=""
    if [[ -n "$ipv6_raw" ]]; then
        nft_ipv6_count=$(echo "$ipv6_raw" | tr '\n' ' ' | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' | tr ',' '\n' | grep -cE '[0-9a-fA-F]') || nft_ipv6_count=0
    fi

    # Ensure counts are valid integers (defense-in-depth)
    [[ -z "$nft_ipv4_count" || ! "$nft_ipv4_count" =~ ^[0-9]+$ ]] && nft_ipv4_count=0
    [[ -z "$nft_ipv6_count" || ! "$nft_ipv6_count" =~ ^[0-9]+$ ]] && nft_ipv6_count=0
    local nft_total=$(( ${nft_ipv4_count:-0} + ${nft_ipv6_count:-0} ))

    # Count from config files
    local config_count=0
    if [[ -d "$NFTBAN_BLACKLIST_DIR" ]]; then
        config_count=$(grep -vhE '^\s*(#|$)' "${NFTBAN_BLACKLIST_DIR}"/*.conf 2>/dev/null | grep -cE '.' || true)
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat <<EOF
{"success":true,"nftables":{"ipv4":${nft_ipv4_count},"ipv6":${nft_ipv6_count},"total":${nft_total}},"config":{"total":${config_count}}}
EOF
    else
        echo "Blacklist count:"
        echo "  nftables: ${nft_total} (IPv4: ${nft_ipv4_count}, IPv6: ${nft_ipv6_count})"
        echo "  config:   ${config_count} persistent entries"
    fi
}

# =============================================================================
# USAGE
# =============================================================================

nftban_blacklist_usage() {
    cat <<'EOF'
Usage: nftban blacklist <command> [options]

COMMANDS:
  add <IP> [opts]     Ban IP (alias for 'nftban ban')
                      Options: --reason "TEXT" --timeout SECS --source SRC
  remove <IP>         Unban IP (alias for 'nftban unban')
  list [--json]       Show all blacklisted IPs from nftables
  files               Show persistent blacklist config files
  count [--json]      Quick count of blacklisted IPs
  flush [--yes]       Flush all blacklist sets (alias for 'nftban flush blacklist')
  reconcile           Trigger manual reconciliation (verify kernel matches daemon state)

ALIASES:
  add, ban            → nftban ban <IP>
  remove, unban, del  → nftban unban <IP>
  list, show          → list from nftables sets
  flush               → nftban flush blacklist

EXAMPLES:
  nftban blacklist list                          List all banned IPs
  nftban blacklist add 192.168.1.100             Ban IP permanently
  nftban blacklist add 10.0.0.1 --timeout 3600   Ban IP for 1 hour
  nftban blacklist remove 192.168.1.100          Unban IP
  nftban blacklist files                         Show config files
  nftban blacklist count --json                  Get count as JSON
  nftban blacklist flush --yes                   Flush all bans

CONFIG FILES:
  /etc/nftban/blacklist.d/99-manual.conf           Manual bans
  /etc/nftban/blacklist.d/30-persistent-offenders.conf  Auto-escalated
  /etc/nftban/blacklist.d/login-auto.conf          SSH brute-force
  /etc/nftban/blacklist.d/portscan-auto.conf       Port scan bans
  /etc/nftban/blacklist.d/ddos-auto.conf           DDoS bans

SEE ALSO:
  nftban ban <IP>           Direct ban command
  nftban unban <IP>         Direct unban command
  nftban list banned        List banned IPs (alternative)
  nftban search <IP>        Check if IP is banned
  nftban flush blacklist    Emergency flush

EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "blacklist"

export -f nftban_cmd_blacklist

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_blacklist "$@"
fi
