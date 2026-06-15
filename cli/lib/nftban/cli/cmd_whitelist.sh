#!/usr/bin/env bash
# =============================================================================
# NFTBan - Whitelist Command
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
        verify)
            # v1.163.0 (SEC-WL-VERIFY): READ-ONLY anomaly report comparing the
            # live kernel whitelist sets against the durable whitelist.d baseline.
            nftban_whitelist_verify "$@"
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

    echo "Added $ip to the PERMANENT whitelist ($_NFTBAN_MANUAL_WHITELIST_PATH) and applied it live — durable: survives firewall reload, daemon restart, and reboot."

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
# v1.169 (CLI-BUG-3): format one kernel whitelist set element for display,
# labeling timed (session / `--ttl`, carries an nft `timeout`) vs durable
# entries. Since v1.168 a timed element renders as
# "1.2.3.4 timeout 30m expires 29m55s"; without this the list printed that raw
# text appended to the IP, unlabeled. Input = one element line from
# `nft list set` (timed or a bare "1.2.3.4"). Output = "  <ip>   <LABEL>".
# Pure/string-only — no nft calls, no writes (unit-testable).
nftban_whitelist_fmt_element() {
    local _el="$1" _bare _rem
    _bare="${_el%% *}"
    if [[ "$_el" == *" timeout "* ]]; then
        if [[ "$_el" == *" expires "* ]]; then
            _rem="${_el##* expires }"; _rem="${_rem%% *}"
            printf '  %-18s TIMED (expires in %s)\n' "$_bare" "$_rem"
        else
            printf '  %-18s TIMED\n' "$_bare"
        fi
    else
        printf '  %-18s DURABLE\n' "$_bare"
    fi
}

# nftban_whitelist_bare_ip — first whitespace-delimited field of an element line
# (strips any `timeout …`/`expires …` suffix). Keeps --json values valid IPs.
nftban_whitelist_bare_ip() {
    local _el="$1"
    printf '%s' "${_el%% *}"
}

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
            _json+="\"$(nftban_whitelist_bare_ip "$_ip")\""
        done <<< "$_wl_v4"
        _json+='],"ipv6":['
        _first=true
        while IFS= read -r _ip; do
            [[ -z "$_ip" ]] && continue
            [[ "$_first" == "true" ]] && _first=false || _json+=","
            _json+="\"$(nftban_whitelist_bare_ip "$_ip")\""
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
            [[ -n "$_ip" ]] && nftban_whitelist_fmt_element "$_ip"
        done <<< "$_wl_v4"
    else
        echo "  (empty or not available)"
    fi
    echo ""
    echo "IPv6 Whitelist:"
    echo "───────────────"
    if [[ -n "$_wl_v6" ]]; then
        while IFS= read -r _ip; do
            [[ -n "$_ip" ]] && nftban_whitelist_fmt_element "$_ip"
        done <<< "$_wl_v6"
    else
        echo "  (empty or not available)"
    fi
}

# =============================================================================
# v1.163.0 — `nftban whitelist verify` (SEC-WL-VERIFY)
# =============================================================================
# READ-ONLY anomaly report. Compares the live kernel whitelist sets
# (@whitelist_ipv4 in `ip nftban`, @whitelist_ipv6 in `ip6 nftban`) against the
# DURABLE whitelist.d baseline (entries with NO EXPIRES_AT — the 99-manual.conf
# class loaded permanently on every rebuild by internal/whitelist/loader.go).
#
# Anomaly classes (both set rc=1):
#   IN-KERNEL-NOT-IN-BASELINE  — a kernel entry that is neither a durable baseline
#                                entry nor a current (unexpired) session entry.
#                                This is the security-relevant case (possible
#                                out-of-band injection into the live set).
#   IN-BASELINE-NOT-IN-KERNEL  — a durable baseline entry not applied to the
#                                kernel (drift / not-applied).
#
# Session/TTL entries (whitelist.d/*.conf lines WITH an EXPIRES_AT that has not
# yet passed, e.g. 00-session.conf) are INFORMATIONAL only — a legitimate live
# admin session in the kernel must NOT be flagged as injected. Expired session
# entries are NOT treated as baseline (the loader would not keep them), so a
# kernel entry matching only an expired session line is still an anomaly.
#
# Strictly read-only: the only nft invocation is `nft list set` (read). No add,
# no delete, no sync. Remediation is a hint; there is no --fix.

# Directory holding the durable + session whitelist config files.
_NFTBAN_WHITELIST_CONF_DIR="/etc/nftban/whitelist.d"

# Normalize a single nft `elements` token to a bare IP/CIDR key for comparison.
# Drops any trailing nft annotation (e.g. ` comment "..."` / ` timeout ...`) and
# surrounding whitespace, leaving "1.2.3.4" or "1.2.3.0/24". Lowercased so IPv6
# hex compares stably against config lines.
_nftban_wl_norm_key() {
    local tok="$1"
    tok="${tok%%comment*}"   # strip ` comment "..."`
    tok="${tok%%timeout*}"   # strip ` timeout ...`
    tok="${tok%%expires*}"   # strip ` expires ...`
    # trim surrounding whitespace
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    printf '%s' "${tok,,}"
}

# Read one kernel whitelist set, one normalized key per line (read-only).
# $1 = family table words ("ip nftban" | "ip6 nftban"), $2 = set name.
# Returns rc 0 on a readable set (even if empty), rc 1 if the set is unreadable
# (nft absent, daemon down, or no table) so the caller can report gracefully.
_nftban_wl_read_kernel_set() {
    local table="$1" set_name="$2" raw tok
    # shellcheck disable=SC2086
    raw=$(timeout 10s nft list set ${table} ${set_name} 2>/dev/null) || return 1
    # Empty/absent elements block is a valid (empty) set, not an error.
    [[ "$raw" == *"elements"* ]] || return 0
    printf '%s\n' "$raw" \
        | tr '\n' ' ' \
        | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' \
        | tr ',' '\n' \
        | while IFS= read -r tok || [[ -n "$tok" ]]; do
            [[ -z "${tok//[[:space:]]/}" ]] && continue
            local k; k="$(_nftban_wl_norm_key "$tok")"
            [[ -n "$k" ]] && printf '%s\n' "$k"
          done
    return 0
}

# Read durable baseline keys (whitelist.d/*.conf entries with NO EXPIRES_AT).
# $1 = "4" or "6" to filter by family (IPv6 keys contain ':').
_nftban_wl_read_baseline() {
    local fam="$1" f line before_hash ip
    [[ -d "$_NFTBAN_WHITELIST_CONF_DIR" ]] || return 0
    for f in "$_NFTBAN_WHITELIST_CONF_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue
            [[ "${trimmed:0:1}" == "#" ]] && continue
            # Durable baseline = NO EXPIRES_AT marker (session/TTL entries excluded).
            [[ "$line" == *EXPIRES_AT=* ]] && continue
            before_hash="${line%%#*}"
            # shellcheck disable=SC2086
            ip=$(printf '%s' $before_hash | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            if [[ "$fam" == "6" && "$ip" == *:* ]]; then
                printf '%s\n' "${ip,,}"
            elif [[ "$fam" == "4" && "$ip" != *:* ]]; then
                printf '%s\n' "${ip,,}"
            fi
        done < "$f"
    done
}

# Read CURRENT (unexpired) session keys (whitelist.d/*.conf entries WITH an
# EXPIRES_AT still in the future). $1 = "4"/"6". Used to classify kernel entries
# as legitimate live sessions rather than injections. Unparseable/expired lines
# are skipped (NOT counted as session), so they fall through to anomaly checks.
_nftban_wl_read_sessions() {
    local fam="$1" f line before_hash ip expires_at expires_unix now_unix
    now_unix=$(date -u +%s 2>/dev/null) || now_unix=0
    [[ -d "$_NFTBAN_WHITELIST_CONF_DIR" ]] || return 0
    for f in "$_NFTBAN_WHITELIST_CONF_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue
            [[ "${trimmed:0:1}" == "#" ]] && continue
            [[ "$line" == *EXPIRES_AT=* ]] || continue
            expires_at=$(printf '%s' "$line" | grep -oE 'EXPIRES_AT=[^ ]+' | head -1 | cut -d= -f2)
            [[ -z "$expires_at" ]] && continue
            expires_unix=$(date -u -d "$expires_at" +%s 2>/dev/null) || continue
            [[ "$expires_unix" -le "$now_unix" ]] && continue   # expired => not a current session
            before_hash="${line%%#*}"
            # shellcheck disable=SC2086
            ip=$(printf '%s' $before_hash | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            if [[ "$fam" == "6" && "$ip" == *:* ]]; then
                printf '%s\n' "${ip,,}"
            elif [[ "$fam" == "4" && "$ip" != *:* ]]; then
                printf '%s\n' "${ip,,}"
            fi
        done < "$f"
    done
}

# Verify one family. Echoes report lines; returns the anomaly count for the
# family via the named-by-convention globals below (bash can't return ints >255
# cleanly, and we want a precise count). Sets _NFTBAN_WL_VERIFY_ANOM.
# $1 = family label (IPv4/IPv6), $2 = "4"/"6", $3 = table words, $4 = set name.
_nftban_wl_verify_family() {
    local label="$1" fam="$2" table="$3" set_name="$4"
    local -a kernel=() baseline=() sessions=()
    local k

    if ! _nftban_wl_read_kernel_set "$table" "$set_name" >/dev/null 2>&1; then
        # Distinguish "unreadable" from "empty": re-run and capture rc.
        :
    fi
    local kraw krc=0
    kraw="$(_nftban_wl_read_kernel_set "$table" "$set_name")" || krc=$?
    if [[ $krc -ne 0 ]]; then
        echo "  $label: kernel set ${set_name} is UNREADABLE (nft missing, daemon down, or table absent) — cannot verify."
        _NFTBAN_WL_VERIFY_UNREADABLE=$(( ${_NFTBAN_WL_VERIFY_UNREADABLE:-0} + 1 ))
        return 0
    fi
    while IFS= read -r k; do [[ -n "$k" ]] && kernel+=("$k"); done <<< "$kraw"
    while IFS= read -r k; do [[ -n "$k" ]] && baseline+=("$k"); done < <(_nftban_wl_read_baseline "$fam")
    while IFS= read -r k; do [[ -n "$k" ]] && sessions+=("$k"); done < <(_nftban_wl_read_sessions "$fam")

    local anom=0 b kk found

    echo "  ${label} (set ${set_name}):"

    # IN-KERNEL-NOT-IN-BASELINE: kernel keys absent from durable baseline.
    for kk in "${kernel[@]}"; do
        found=false
        for b in "${baseline[@]}"; do [[ "$kk" == "$b" ]] && { found=true; break; }; done
        if [[ "$found" == "true" ]]; then continue; fi
        # Not baseline — is it a current session? (informational, not anomaly)
        local is_session=false
        for b in "${sessions[@]}"; do [[ "$kk" == "$b" ]] && { is_session=true; break; }; done
        if [[ "$is_session" == "true" ]]; then
            echo "    [info]    $kk — active session whitelist (unexpired 00-session.conf); not an anomaly"
        else
            echo "    [ANOMALY] $kk — IN-KERNEL-NOT-IN-BASELINE (present in live set, not in durable whitelist.d; possible injection)"
            anom=$(( anom + 1 ))
        fi
    done

    # IN-BASELINE-NOT-IN-KERNEL: durable baseline keys missing from the kernel.
    for b in "${baseline[@]}"; do
        found=false
        for kk in "${kernel[@]}"; do [[ "$b" == "$kk" ]] && { found=true; break; }; done
        if [[ "$found" == "false" ]]; then
            echo "    [ANOMALY] $b — IN-BASELINE-NOT-IN-KERNEL (durable whitelist.d entry not applied to live set; drift)"
            anom=$(( anom + 1 ))
        fi
    done

    [[ "$anom" -eq 0 ]] && echo "    OK — kernel matches durable baseline (sessions informational)."

    _NFTBAN_WL_VERIFY_ANOM=$(( ${_NFTBAN_WL_VERIFY_ANOM:-0} + anom ))
    return 0
}

# Public entry point: `nftban whitelist verify`. rc=0 clean, rc=1 anomalies.
nftban_whitelist_verify() {
    # No write flags accepted — this surface is read-only by contract.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) nftban_whitelist_usage; return 0 ;;
            --fix)     echo "ERROR: 'whitelist verify' is read-only; there is no --fix. Use 'nftban sync' to reapply durable entries." >&2; return 2 ;;
            --*)       echo "ERROR: Unknown flag for 'whitelist verify': $1" >&2; return 2 ;;
            *)         echo "ERROR: Unexpected argument: $1" >&2; return 2 ;;
        esac
    done

    if ! command -v nft >/dev/null 2>&1; then
        echo "ERROR: nft (nftables) not found — cannot read the live whitelist sets." >&2
        return 2
    fi

    _NFTBAN_WL_VERIFY_ANOM=0
    _NFTBAN_WL_VERIFY_UNREADABLE=0

    echo "Whitelist verify (read-only) — live kernel sets vs durable whitelist.d baseline"
    echo "──────────────────────────────────────────────────────────────────────────────"
    _nftban_wl_verify_family "IPv4" "4" "ip nftban"  "whitelist_ipv4"
    _nftban_wl_verify_family "IPv6" "6" "ip6 nftban" "whitelist_ipv6"
    echo ""

    if [[ "${_NFTBAN_WL_VERIFY_UNREADABLE:-0}" -gt 0 && "${_NFTBAN_WL_VERIFY_ANOM:-0}" -eq 0 ]]; then
        echo "Result: could not read one or more kernel whitelist sets — verification incomplete."
        echo "Hint: ensure the nftband daemon is running (systemctl status nftband) and re-run."
        return 2
    fi

    if [[ "${_NFTBAN_WL_VERIFY_ANOM:-0}" -gt 0 ]]; then
        echo "Result: ${_NFTBAN_WL_VERIFY_ANOM} anomaly(ies) found."
        echo "Hint:"
        echo "  • IN-BASELINE-NOT-IN-KERNEL (drift) → reapply durable entries: nftban sync"
        echo "  • IN-KERNEL-NOT-IN-BASELINE (possible injection) → review the source of the live entry;"
        echo "    it is not in whitelist.d and not a current session. Persist it with"
        echo "    'nftban whitelist add --static <IP>' or remove it if unexpected."
        return 1
    fi

    echo "Result: OK — no anomalies. Live whitelist matches the durable baseline."
    return 0
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
  verify                 Read-only: compare live kernel sets vs durable whitelist.d baseline (reports anomalies)
  sync                   Auto-detect and whitelist system IPs
  whitelistme            Whitelist your current IP (interactive)

WHITELIST TIERS:
  runtime   (default add)  live nft set only; DROPPED on the next firewall rebuild/reload/restart.
  timed     (--ttl <dur>)  written to 00-session.conf with an expiry; auto-pruned after the TTL.
  permanent (--static)     written to 99-manual.conf (no expiry); applied live; survives firewall reload/restart/reboot.

EXAMPLES:
  nftban whitelist add 192.168.1.100              # runtime only (temporary)
  nftban whitelist add --static 192.168.1.100     # permanent (survives rebuild)
  nftban whitelist add --static 2001:db8::1        # IPv6 permanent
  nftban whitelist add --ttl 30m 192.168.1.100    # 30-minute session
  nftban whitelist remove --static 192.168.1.100  # remove permanent entry + live
  nftban whitelist list
  nftban whitelist verify                          # read-only anomaly check (live set vs baseline)
  nftban whitelist sync

EOF
}

# =============================================================================

# EXPORTS
# =============================================================================


# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "whitelist"

export -f nftban_cmd_whitelist
export -f nftban_whitelist_verify 2>/dev/null || true

# =============================================================================

# DIRECT EXECUTION SUPPORT
# =============================================================================


# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_whitelist "$@"
fi
