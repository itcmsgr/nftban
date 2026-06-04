#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Whitelist Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="cmd_whitelist"
# meta:type="cli"
# meta:header="Whitelist IP management"
# meta:version="1.39.0"
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
# meta:updated_date="2026-02-23"


# =============================================================================
# CONFIGURATION
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# v1.19.27: Load validation library for defense-in-depth IP validation
# shellcheck source=/usr/lib/nftban/lib/validation.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/validation.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
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
            # v1.149.0: explicit whitelist tiers.
            #   (default)      runtime/live only — lost on rebuild/reload/restart
            #   --static       permanent — writes 99-manual.conf (no expiry) + applies live via sync
            #   --ttl <dur>    timed — delegates to `firewall whitelist-session` (00-session.conf)
            #   --session      timed with a default 1h TTL
            local _wl_static="false" _wl_ttl="" ip=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --static)  _wl_static="true"; shift ;;
                    --ttl)
                        _wl_ttl="${2:-}"
                        if [[ -z "$_wl_ttl" ]]; then
                            echo "ERROR: --ttl requires a duration (e.g. 30m, 1h, 1h30m)" >&2; return 1
                        fi
                        shift 2 ;;
                    --session) [[ -z "$_wl_ttl" ]] && _wl_ttl="1h"; shift ;;
                    -h|--help) nftban_whitelist_usage; return 0 ;;
                    --*)       echo "ERROR: Unknown flag for 'whitelist add': $1" >&2; return 1 ;;
                    *)         if [[ -z "$ip" ]]; then ip="$1"; shift; else echo "ERROR: Unexpected argument: $1" >&2; return 1; fi ;;
                esac
            done
            if [[ -z "$ip" ]]; then
                echo "Usage: nftban whitelist add [--static | --ttl <dur>] <IP>" >&2
                echo "Example: nftban whitelist add --static 192.168.1.100" >&2
                return 1
            fi
            if [[ "$_wl_static" == "true" && -n "$_wl_ttl" ]]; then
                echo "ERROR: --static and --ttl/--session are mutually exclusive (permanent vs timed)" >&2
                return 1
            fi
            if [[ -n "$_wl_ttl" ]]; then
                # Timed tier — reuse the existing session writer (00-session.conf).
                if command -v nftban >/dev/null 2>&1; then
                    nftban firewall whitelist-session add "$ip" --ttl "$_wl_ttl"
                else
                    echo "ERROR: timed whitelist requires the nftban CLI (firewall whitelist-session)" >&2
                    return 1
                fi
            elif [[ "$_wl_static" == "true" ]]; then
                nftban_whitelist_add_static_ip "$ip"
            else
                nftban_whitelist_add_ip "$ip" && \
                    echo "NOTE: $ip added to the RUNTIME whitelist only — it will NOT survive firewall rebuild/reload/restart. Use 'nftban whitelist add --static $ip' to persist." >&2
            fi
            ;;
        remove|rm|del|delete)
            # v1.149.0: --static also removes the durable 99-manual.conf entry so a
            # rebuild cannot resurrect it; default remove is live-set only (unchanged).
            local _wl_static="false" ip=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --static)  _wl_static="true"; shift ;;
                    -h|--help) nftban_whitelist_usage; return 0 ;;
                    --*)       echo "ERROR: Unknown flag for 'whitelist remove': $1" >&2; return 1 ;;
                    *)         if [[ -z "$ip" ]]; then ip="$1"; shift; else echo "ERROR: Unexpected argument: $1" >&2; return 1; fi ;;
                esac
            done
            if [[ -z "$ip" ]]; then
                echo "Usage: nftban whitelist remove [--static] <IP>" >&2
                echo "Example: nftban whitelist remove 192.168.1.100" >&2
                return 1
            fi
            if [[ "$_wl_static" == "true" ]]; then
                nftban_whitelist_remove_static_ip "$ip"
            else
                nftban_whitelist_remove_ip "$ip"
            fi
            ;;
        list|show)
            # Show whitelist (v1.59.0: added --json support)
            nftban_whitelist_list "$@"
            ;;
        sync|whitelistme)
            # Pass to whitelist-system for these commands
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh" ]]; then
                source "${NFTBAN_LIB_DIR}/cli/cmd_whitelist_system.sh" || return 1
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
# v1.18.7: Also removes from blacklist to prevent conflict
# v1.19.0: Enforced IPC-only path with daemon-running check (R20)
# v1.19.27: Added defense-in-depth IP validation
nftban_whitelist_add_ip() {
    local ip="$1"

    # v1.19.27 SECURITY: Validate IP/CIDR before any nft operations (defense-in-depth)
    if ! nftban_validate_ip "$ip" && ! nftban_validate_cidr "$ip"; then
        echo "ERROR: Invalid IP/CIDR format: $ip" >&2
        return 1
    fi

    # Validate IP format and determine family
    # v1.39.0: Check both blacklist_manual_* (hash) and blacklist_* (interval) sets
    local table set_name blacklist_set blacklist_manual_set family
    if [[ "$ip" =~ : ]]; then
        # IPv6
        table="ip6 nftban"
        set_name="whitelist_ipv6"
        blacklist_set="blacklist_ipv6"
        blacklist_manual_set="blacklist_manual_ipv6"
        family="IPv6"
    else
        # IPv4
        table="ip nftban"
        set_name="whitelist_ipv4"
        blacklist_set="blacklist_ipv4"
        blacklist_manual_set="blacklist_manual_ipv4"
        family="IPv4"
    fi

    # v1.19.0: Check daemon or emergency gate before any write operation
    local ipc_mode
    nftban_ipc_check_or_emergency
    ipc_mode=$?
    if [[ $ipc_mode -eq 2 ]]; then
        echo "ERROR: nftband daemon is not running. Start with: systemctl start nftband" >&2
        return 1
    fi

    # v1.18.7: First remove from blacklist if present (prevents whitelist/blacklist conflict)
    # v1.39.0: Check both blacklist_manual_* (hash) and blacklist_* (interval) sets
    # v1.39.0: Use nftban-core unban to remove from BOTH nft sets AND blacklist conf files
    #          (nft-only delete was insufficient — daemon reconciliation re-adds from conf)
    local _bl_set _is_banned=false
    for _bl_set in "$blacklist_manual_set" "$blacklist_set"; do
        if nft get element ${table} ${_bl_set} "{ $ip }" &>/dev/null; then
            _is_banned=true
            break
        fi
    done
    if [[ "$_is_banned" == "true" ]]; then
        local _core_bin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
        if [[ -x "$_core_bin" ]]; then
            "$_core_bin" unban "$ip" &>/dev/null || true
        else
            # Fallback: direct nft delete (won't remove from conf files)
            for _bl_set in "$blacklist_manual_set" "$blacklist_set"; do
                if nft get element ${table} ${_bl_set} "{ $ip }" &>/dev/null; then
                    if [[ $ipc_mode -eq 0 ]]; then
                        nft_ipc_delete_element "$table" "$_bl_set" "$ip" 2>/dev/null || true
                    else
                        nft delete element ${table} ${_bl_set} "{ $ip }" 2>/dev/null || true
                    fi
                fi
            done
        fi
        echo "Removed $ip from blacklist (was banned)"
    fi

    # Use IPC for add operation (or emergency direct access)
    if [[ $ipc_mode -eq 0 ]]; then
        if nft_ipc_add_element "$table" "$set_name" "$ip" 2>/dev/null; then
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
    else
        # Emergency direct nft access
        if nft add element ${table} ${set_name} "{ $ip }" 2>/dev/null; then
            echo "Added $ip to $family whitelist (emergency direct access)"
            return 0
        else
            echo "ERROR: Failed to add $ip to whitelist (emergency)" >&2
            return 1
        fi
    fi
}

# Remove IP from whitelist via IPC (v1.18.0: IPC-only writes)
# v1.19.0: Enforced IPC-only path with daemon-running check (R20)
# v1.19.27: Added defense-in-depth IP validation
# v1.39.0: Pre-check existence to prevent phantom success
nftban_whitelist_remove_ip() {
    local ip="$1"

    # v1.19.27 SECURITY: Validate IP/CIDR before any nft operations (defense-in-depth)
    if ! nftban_validate_ip "$ip" && ! nftban_validate_cidr "$ip"; then
        echo "ERROR: Invalid IP/CIDR format: $ip" >&2
        return 1
    fi

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

    # v1.39.0: Check if IP exists in whitelist before attempting removal
    if ! nft get element ${table} ${set_name} "{ $ip }" &>/dev/null; then
        echo "INFO: $ip is not in the $family whitelist (nothing to remove)"
        return 0
    fi

    # v1.19.0: Check daemon or emergency gate before any write operation
    local ipc_mode
    nftban_ipc_check_or_emergency
    ipc_mode=$?
    if [[ $ipc_mode -eq 2 ]]; then
        echo "ERROR: nftband daemon is not running. Start with: systemctl start nftband" >&2
        return 1
    fi

    # Use IPC for delete operation (or emergency direct access)
    if [[ $ipc_mode -eq 0 ]]; then
        if nft_ipc_delete_element "$table" "$set_name" "$ip" 2>/dev/null; then
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
    else
        # Emergency direct nft access
        if nft delete element ${table} ${set_name} "{ $ip }" 2>/dev/null; then
            echo "Removed $ip from $family whitelist (emergency direct access)"
            return 0
        else
            echo "ERROR: Failed to remove $ip from whitelist (emergency, may not exist)" >&2
            return 1
        fi
    fi
}

# =============================================================================
# v1.149.0 — PERMANENT (--static) whitelist tier (WL-STATIC)
# =============================================================================
# Durable operator entries live in whitelist.d/99-manual.conf with NO EXPIRES_AT.
# The whitelist loader already reads whitelist.d/*.conf on every rebuild and loads
# non-expiring entries permanently (internal/whitelist/loader.go) — so --static
# needs no daemon/loader/schema change, only a CLI writer for the durable file.
_NFTBAN_MANUAL_WHITELIST_PATH="/etc/nftban/whitelist.d/99-manual.conf"

# Ensure 99-manual.conf exists with a header on FIRST creation only. Never clobbers
# an existing file (shipped %config(noreplace); may carry hand-written operator entries).
_nftban_whitelist_manual_ensure_header() {
    [[ -f "$_NFTBAN_MANUAL_WHITELIST_PATH" ]] && return 0
    mkdir -p "$(dirname "$_NFTBAN_MANUAL_WHITELIST_PATH")"
    cat > "$_NFTBAN_MANUAL_WHITELIST_PATH" <<'MANUAL_HEADER_EOF'
# =============================================================================
# NFTBan Permanent Whitelist (99-manual.conf)
# =============================================================================
#
# Durable operator whitelist entries — NO expiry. Loaded on every firewall
# rebuild/reload/restart. Managed by `nftban whitelist add --static <ip>`, but
# safe to hand-edit (one IP or CIDR per line; '#' starts a comment).
#
#   nftban whitelist add --static <ip>      # persist here (survives rebuild)
#   nftban whitelist remove --static <ip>   # remove from here + live set
#   nftban whitelist add <ip>               # runtime-only (lost on rebuild)
#   nftban whitelist add --ttl 30m <ip>     # timed/session (00-session.conf)
#
# =============================================================================

MANUAL_HEADER_EOF
    chmod 0640 "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true
    chown root:nftban "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true
}

# Add a permanent (no-expiry) entry to 99-manual.conf + apply live. Idempotent
# (refresh: a prior line for the same IP is dropped before re-append).
nftban_whitelist_add_static_ip() {
    local ip="$1"

    if ! nftban_validate_ip "$ip" && ! nftban_validate_cidr "$ip"; then
        echo "ERROR: Invalid IP/CIDR format: $ip" >&2
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: writing $_NFTBAN_MANUAL_WHITELIST_PATH requires root (permanent whitelist)." >&2
        return 1
    fi

    _nftban_whitelist_manual_ensure_header

    local tmp
    tmp=$(mktemp "${_NFTBAN_MANUAL_WHITELIST_PATH}.XXXXXX") || { echo "ERROR: mktemp failed" >&2; return 1; }
    # Drop any prior line whose first token == ip (idempotent refresh).
    # shellcheck disable=SC2016
    awk -v ip="$ip" '
        { t=$0; gsub(/^[ \t]+/,"",t)
          if (t=="" || substr(t,1,1)=="#") { print; next }
          split(t,a,"#"); n=split(a[1],b,/[ \t]+/)
          if (n>=1 && b[1]==ip) next
          print }
    ' "$_NFTBAN_MANUAL_WHITELIST_PATH" > "$tmp"
    # Append the durable entry — NO EXPIRES_AT (permanent).
    printf '%s  # ADDED_BY=nftban-whitelist-static\n' "$ip" >> "$tmp"
    mv "$tmp" "$_NFTBAN_MANUAL_WHITELIST_PATH"
    chmod 0640 "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true
    chown root:nftban "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true

    echo "Added $ip to the PERMANENT whitelist ($_NFTBAN_MANUAL_WHITELIST_PATH) and applied it live. Durable: re-applied to the live set on every full sync (maintenance timer / daemon restart / reboot)."

    # Apply live immediately via a FULL sync. `nftban sync` runs the daemon
    # whitelist loader (LoadWhitelists → reconciles whitelist.d/*.conf, incl. this
    # file, into the live nft set). `firewall reload` alone does NOT apply it — its
    # whitelist step is system-IP auto-detection, not the whitelist.d loader
    # (lab-proven on v1.148.0). Fall back to reload if `sync` is unavailable.
    if command -v nftban >/dev/null 2>&1; then
        nftban sync >/dev/null 2>&1 || nftban firewall reload >/dev/null 2>&1 || true
    fi
    return 0
}

# Remove a permanent entry from 99-manual.conf AND the live set, so a rebuild
# cannot resurrect it.
nftban_whitelist_remove_static_ip() {
    local ip="$1"

    if ! nftban_validate_ip "$ip" && ! nftban_validate_cidr "$ip"; then
        echo "ERROR: Invalid IP/CIDR format: $ip" >&2
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: editing $_NFTBAN_MANUAL_WHITELIST_PATH requires root." >&2
        return 1
    fi

    local removed="false"
    if [[ -f "$_NFTBAN_MANUAL_WHITELIST_PATH" ]]; then
        local tmp
        tmp=$(mktemp "${_NFTBAN_MANUAL_WHITELIST_PATH}.XXXXXX") || { echo "ERROR: mktemp failed" >&2; return 1; }
        # shellcheck disable=SC2016
        if awk -v ip="$ip" '
            { t=$0; gsub(/^[ \t]+/,"",t)
              if (t=="" || substr(t,1,1)=="#") { print; next }
              split(t,a,"#"); n=split(a[1],b,/[ \t]+/)
              if (n>=1 && b[1]==ip) { dropped=1; next }
              print }
            END { exit (dropped?0:1) }
        ' "$_NFTBAN_MANUAL_WHITELIST_PATH" > "$tmp"; then
            mv "$tmp" "$_NFTBAN_MANUAL_WHITELIST_PATH"
            chmod 0640 "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true
            chown root:nftban "$_NFTBAN_MANUAL_WHITELIST_PATH" 2>/dev/null || true
            removed="true"
        else
            rm -f "$tmp"
        fi
    fi

    # Remove from the live set too (best-effort; may not be present).
    nftban_whitelist_remove_ip "$ip" >/dev/null 2>&1 || true
    # Reconcile the live set to the now-updated files via full sync, so the entry
    # is dropped even if it was applied into the CIDR-aware interval set by sync.
    if command -v nftban >/dev/null 2>&1; then
        nftban sync >/dev/null 2>&1 || true
    fi

    if [[ "$removed" == "true" ]]; then
        echo "Removed $ip from the PERMANENT whitelist ($_NFTBAN_MANUAL_WHITELIST_PATH) + live set; rebuild will not resurrect it."
    else
        echo "INFO: $ip not found in $_NFTBAN_MANUAL_WHITELIST_PATH (also removed from live set if present)."
    fi
    return 0
}

# List whitelisted IPs
nftban_whitelist_list() {
    # v1.59.0 UX-2: Added --json support for scripting/monitoring
    local _json_mode="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) _json_mode="true"; shift ;;
            *) shift ;;
        esac
    done

    # Collect implicit IPs
    local -a _implicit_ipv4=("127.0.0.1")
    local -a _implicit_ipv6=("::1")
    local _ip
    while IFS= read -r _ip; do
        [[ -z "$_ip" ]] && continue
        _implicit_ipv4+=("$_ip")
    done < <(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[^/]+' 2>/dev/null)
    while IFS= read -r _ip; do
        [[ -z "$_ip" ]] && continue
        _implicit_ipv6+=("$_ip")
    done < <(ip -6 addr show scope global 2>/dev/null | grep -oP 'inet6 \K[^/]+' 2>/dev/null)

    # Collect kernel whitelist entries
    local _wl_v4 _wl_v6
    # v1.59.1 BUG-9: Trim both leading AND trailing whitespace from nft output (was leaving trailing spaces in JSON)
    _wl_v4=$(timeout 10s nft list set ip nftban whitelist_ipv4 2>/dev/null | grep -E "elements.*=" | sed 's/.*= {//' | sed 's/}//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d') || true
    _wl_v6=$(timeout 10s nft list set ip6 nftban whitelist_ipv6 2>/dev/null | grep -E "elements.*=" | sed 's/.*= {//' | sed 's/}//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d') || true

    if [[ "$_json_mode" == "true" ]]; then
        # JSON output
        local _json='{"implicit":{"ipv4":['
        local _first=true
        for _ip in "${_implicit_ipv4[@]}"; do
            [[ "$_first" == "true" ]] && _first=false || _json+=","
            _json+="\"$_ip\""
        done
        _json+='],"ipv6":['
        _first=true
        for _ip in "${_implicit_ipv6[@]}"; do
            [[ "$_first" == "true" ]] && _first=false || _json+=","
            _json+="\"$_ip\""
        done
        _json+=']}'
        _json+=',"whitelist":{"ipv4":['
        _first=true
        while IFS= read -r _ip; do
            [[ -z "$_ip" ]] && continue
            [[ "$_first" == "true" ]] && _first=false || _json+=","
            _json+="\"$_ip\""
        done <<< "$_wl_v4"
        _json+='],"ipv6":['
        _first=true
        while IFS= read -r _ip; do
            [[ -z "$_ip" ]] && continue
            [[ "$_first" == "true" ]] && _first=false || _json+=","
            _json+="\"$_ip\""
        done <<< "$_wl_v6"
        _json+=']}}'
        echo "$_json"
        return 0
    fi

    # v1.38.0: Show implicit (always-protected) entries first
    echo "Implicit (always protected):"
    echo "────────────────────────────"
    echo "  127.0.0.1       IMPLICIT (loopback IPv4)"
    echo "  ::1             IMPLICIT (loopback IPv6)"
    for _ip in "${_implicit_ipv4[@]}"; do
        [[ "$_ip" == "127.0.0.1" ]] && continue
        echo "  ${_ip}  IMPLICIT (server IP)"
    done
    for _ip in "${_implicit_ipv6[@]}"; do
        [[ "$_ip" == "::1" ]] && continue
        echo "  ${_ip}  IMPLICIT (server IP)"
    done
    echo ""

    echo "IPv4 Whitelist:"
    echo "───────────────"
    if [[ -n "$_wl_v4" ]]; then
        while IFS= read -r _ip; do
            [[ -n "$_ip" ]] && echo "  $_ip"
        done <<< "$_wl_v4"
    else
        echo "  (empty or not available)"
    fi
    echo ""
    echo "IPv6 Whitelist:"
    echo "───────────────"
    if [[ -n "$_wl_v6" ]]; then
        while IFS= read -r _ip; do
            [[ -n "$_ip" ]] && echo "  $_ip"
        done <<< "$_wl_v6"
    else
        echo "  (empty or not available)"
    fi
}

# Show usage
nftban_whitelist_usage() {
    cat <<'EOF'
Usage: nftban whitelist <command> [options] [IP]

COMMANDS:
  add <IP>               Add IP to the RUNTIME whitelist only (lost on rebuild/reload/restart)
  add --static <IP>      Add IP to the PERMANENT whitelist (99-manual.conf; survives rebuild)
  add --ttl <dur> <IP>   Add IP to a TIMED session whitelist (00-session.conf; auto-expires)
  remove <IP>            Remove IP from the runtime whitelist (live set only)
  remove --static <IP>   Remove IP from the permanent whitelist (99-manual.conf) + live set
  list                   Show all whitelisted IPs
  sync                   Auto-detect and whitelist system IPs
  whitelistme            Whitelist your current IP (interactive)

WHITELIST TIERS:
  runtime   (default add)  live nft set only; DROPPED on the next firewall rebuild/reload/restart.
  timed     (--ttl <dur>)  written to 00-session.conf with an expiry; auto-pruned after the TTL.
  permanent (--static)     written to 99-manual.conf (no expiry); applied live + re-synced on every full sync.

EXAMPLES:
  nftban whitelist add 192.168.1.100              # runtime only (temporary)
  nftban whitelist add --static 192.168.1.100     # permanent (survives rebuild)
  nftban whitelist add --static 2001:db8::1        # IPv6 permanent
  nftban whitelist add --ttl 30m 192.168.1.100    # 30-minute session
  nftban whitelist remove --static 192.168.1.100  # remove permanent entry + live
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
