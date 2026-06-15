#!/usr/bin/env bash
# =============================================================================
# NFTBan - Ban Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Ban IP addresses using nftban-core
#
# meta:name="cmd_ban"
# meta:type="cli"
# meta:header="Ban Command"
# meta:version="1.44.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Ban IP addresses permanently using nftban-core"
# meta:input="IP address, optional reason"
# meta:output="Ban confirmation or error message"
# meta:depends="bash,nftban-core"
# meta:created_date="2025-11-24"
# meta:updated_date="2026-02-07"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================
set -Eeuo pipefail

# Prevent double-loading
[[ -n "${CMD_BAN_LOADED:-}" ]] && return 0

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_require_binary, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Load timestamp utilities (nftban_timestamp_unix, nftban_timestamp, etc.)
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# Initialize CLI environment (loads config, sets paths, enables strict mode)
cmd_init

readonly CMD_BAN_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_ban() {
    # Ban an IP address using nftban-core
    # Usage: nftban ban <ip> [--reason "REASON"] [--timeout SECONDS] [--source SOURCE] [--json]
    #        nftban ban --file <path> [--reason "REASON"] [--timeout SECONDS] [--source SOURCE]

    local ip=""
    local reason=""
    local timeout=""
    local ban_source=""
    local ban_file=""
    local compact_mode="false"
    local dry_run="false"
    local auto_confirm="false"
    local async_mode="false"
    local wait_mode="false"
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_ban_usage; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                shift
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            --timeout)
                # v1.141 PR-A (BUG-A7/A8): reject non-positive-integer timeouts at
                # parse time, before any IPC to nftban-core / blacklist.d write /
                # nft mutation. Prior to v1.141, "abc" / "-5" / "0" / "" / "1.5"
                # silently propagated to nftban-core which then defaulted to
                # permanent ban — operator surprise reproduced live in the
                # cruel-judge review on monitor.mywebhost.gr.
                if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
                    echo "ERROR: --timeout requires a positive integer (seconds); got: '${2:-(missing)}'" >&2
                    echo "Hint:  nftban ban <ip> --timeout 3600" >&2
                    echo "       (use no --timeout for permanent ban)" >&2
                    return 1
                fi
                timeout="$2"
                shift 2
                ;;
            --source)
                ban_source="$2"
                shift 2
                ;;
            --compact|-q)
                # v1.39.0 P3-34: Compact output (3 lines: action, result, total)
                compact_mode="true"
                shift
                ;;
            --dry-run)
                # v1.43.0 P3-21: Show what would happen without executing
                dry_run="true"
                shift
                ;;
            --yes|-y)
                # v1.43.0 P3-24: Skip confirmation prompt
                auto_confirm="true"
                shift
                ;;
            --async)
                # v1.43.0 P3-18: Return immediately, don't wait for IPC response
                async_mode="true"
                shift
                ;;
            --wait)
                # v1.43.0 P3-18: Wait for nftables sync confirmation
                wait_mode="true"
                shift
                ;;
            --file|--file=*)
                # v1.39.0 P3-22: Bulk ban from file
                if [[ "$1" == --file=* ]]; then
                    ban_file="${1#--file=}"
                    shift
                else
                    ban_file="$2"
                    shift 2
                fi
                ;;
            -*)
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_ban_usage
                return 1
                ;;
            *)
                if [[ -z "$ip" ]]; then
                    ip="$1"
                    shift
                else
                    cmd_error "Multiple IP addresses not supported. Use --file for bulk bans." "$json_mode"
                    return 1
                fi
                ;;
        esac
    done

    # v1.39.0 P3-22: Bulk ban from file
    if [[ -n "$ban_file" ]]; then
        _nftban_cmd_ban_from_file "$ban_file" "$reason" "$timeout" "$ban_source" "$json_mode"
        return $?
    fi

    # Validate required arguments
    cmd_require_arg "$ip" "IP address" "$json_mode" nftban_cmd_ban_usage || return 1
    cmd_validate_ip "$ip" "$json_mode" nftban_cmd_ban_usage || return 1

    # V127 UX-2 item 1.7 (V129 PR-C D7 corrected): well-known public infrastructure
    # IP guard. Banning addresses like 8.8.8.8 / 1.1.1.1 / 9.9.9.9 / 208.67.222.222
    # produces no security benefit on a typical host and disrupts legitimate name
    # resolution for the operator's users. Refuse unless --yes (auto_confirm) is set
    # explicitly. V129 PR-C D7 fix: the guard now fires for BOTH live AND --dry-run
    # paths. A dry-run preview showing "would ban 8.8.8.8" misleads operators into
    # thinking the subsequent live command will succeed; instead dry-run must
    # reflect what the guard would actually do (refuse). --yes still overrides for
    # both live and dry-run paths.
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_well_known.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_well_known.sh" 2>/dev/null || true
        if declare -f nftban_is_well_known_infra_ip >/dev/null 2>&1; then
            local _wk_descr
            if _wk_descr=$(nftban_is_well_known_infra_ip "$ip"); then
                if [[ "$auto_confirm" != "true" ]]; then
                    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                        json_output "false" '{}' "Refused: ${ip} is well-known public infrastructure (${_wk_descr}). Re-run with --yes to override."
                    else
                        nftban_well_known_warn_block "$ip" stderr
                    fi
                    return 1
                fi
                # Explicit override path: log the override + proceed.
                # Both dry-run and live fall through after this block when --yes is set.
                if [[ "$json_mode" != "true" ]]; then
                    echo "[!] Well-known infrastructure override accepted: ${ip} (${_wk_descr})" >&2
                    echo "    Proceeding under explicit --yes confirmation." >&2
                fi
            fi
        fi
    fi

    # v1.18.8: Check if IP is whitelisted - warn user before banning
    local whitelist_set
    if [[ "$ip" =~ : ]]; then
        whitelist_set="ip6 nftban whitelist_ipv6"
    else
        whitelist_set="ip nftban whitelist_ipv4"
    fi

    # Check whitelist conflict
    if nft get element ${whitelist_set} "{ $ip }" &>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            json_output "false" '{}' "Cannot ban whitelisted IP: $ip. Remove from whitelist first with: nftban whitelist remove $ip"
            return 1
        else
            echo "WARNING: IP $ip is currently whitelisted!" >&2
            echo "To ban this IP, first remove it from the whitelist:" >&2
            echo "  nftban whitelist remove $ip" >&2
            echo "Then retry the ban command." >&2
            return 1
        fi
    fi

    # v1.43.0 P3-21: Dry-run mode — show what would happen without executing
    if [[ "$dry_run" == "true" ]]; then
        local ban_type="permanent"
        [[ -n "$timeout" ]] && ban_type="temporary (${timeout}s)"
        local family="ip"
        [[ "$ip" =~ : ]] && family="ip6"

        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
            local data
            data=$(jq -n \
                --arg ip "$ip" \
                --arg family "$family" \
                --arg ban_type "$ban_type" \
                --arg reason "${reason:-manual}" \
                --arg timeout "${timeout:-permanent}" \
                --arg source "${ban_source:-manual}" \
                '{dry_run: true, ip: $ip, family: $family, ban_type: $ban_type, reason: $reason, timeout: $timeout, source: $source}')
            json_output "true" "$data"
        else
            echo "[DRY-RUN] Would ban IP: $ip"
            echo "  Family:   $family"
            echo "  Type:     $ban_type"
            echo "  Reason:   ${reason:-(none)}"
            echo "  Source:   ${ban_source:-manual}"
            echo "  Blacklist: ${NFTBAN_CONFIG_DIR}/blacklist.d/99-manual.conf"
            echo "  nft set:  $family nftban banned_${family}v4"
            [[ "$family" == "ip6" ]] && echo "  nft set:  ip6 nftban banned_ipv6" || true
        fi
        return 0
    fi

    # v1.43.0 P3-24: Confirmation prompt for permanent bans
    # v1.44.0 BUG-009: Add 10s timeout to prevent infinite hang in scripts
    if [[ -z "$timeout" && "$auto_confirm" != "true" && "$json_mode" != "true" ]]; then
        if [[ -t 0 ]]; then
            echo "WARNING: This will permanently ban $ip (no timeout set)."
            printf "Continue? [y/N] "
            local reply
            if ! read -r -t 10 reply; then
                echo ""
                echo "Aborted (no response within 10s)."
                return 1
            fi
            case "$reply" in
                [yY]|[yY][eE][sS]) ;;
                *)
                    echo "Aborted."
                    return 1
                    ;;
            esac
        fi
    fi

    # Check if nftban-core exists (required for ban command)
    local NFTBAN_CORE
    NFTBAN_CORE=$(cmd_get_core_binary)
    cmd_require_binary "$NFTBAN_CORE" "nftban-core" "$json_mode" || return 1

    # Build command arguments
    local cmd_args=("$ip")
    [[ -n "$reason" ]] && cmd_args+=(--reason "$reason")
    [[ -n "$timeout" ]] && cmd_args+=(--timeout "$timeout")
    [[ -n "$ban_source" ]] && cmd_args+=(--source "$ban_source")
    [[ "$async_mode" == "true" ]] && cmd_args+=(--async)
    [[ "$wait_mode" == "true" ]] && cmd_args+=(--wait)

    # Call nftban-core ban (Go binary handles logging to bans.log)
    local output exit_code
    output=$("$NFTBAN_CORE" ban "${cmd_args[@]}" 2>&1)
    exit_code=$?

    # v1.24.0: Ensure blacklist.d/99-manual.conf has correct ownership after write
    if [[ $exit_code -eq 0 ]]; then
        local blacklist_file="${NFTBAN_CONFIG_DIR}/blacklist.d/99-manual.conf"
        # v1.61.1 TOCTOU fix: single ownership+mode set without double check
        chown root:nftban "$blacklist_file" 2>/dev/null && chmod 640 "$blacklist_file" 2>/dev/null || true
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ $exit_code -eq 0 ]]; then
            local data
            if command -v jq &>/dev/null; then
                data=$(jq -n \
                    --arg ip "$ip" \
                    --arg reason "$reason" \
                    --arg timeout "$timeout" \
                    --arg ban_source "$ban_source" \
                    '{ip: $ip, reason: $reason, timeout: (if $timeout == "" then null else ($timeout | tonumber) end), source: (if $ban_source == "" then "manual" else $ban_source end)}')
            else
                local timeout_val="null"
                [[ -n "$timeout" ]] && timeout_val="$timeout"
                local source_val="manual"
                [[ -n "$ban_source" ]] && source_val="$ban_source"
                data="{\"ip\":\"$ip\",\"reason\":\"$reason\",\"timeout\":$timeout_val,\"source\":\"$source_val\"}"
            fi
            json_output "true" "$data"
        else
            json_output "false" '{}' "Failed to ban IP: $output"
        fi
    elif [[ "$compact_mode" == "true" ]]; then
        # v1.39.0 P3-34: Show only essential lines
        if [[ $exit_code -eq 0 ]]; then
            echo "$output" | grep -E "^✅ IP|^The IP|^Entry saved|PERSISTENT OFFENDER|already banned" || echo "Banned: $ip"
        else
            echo "$output" | grep -E "^Error|^failed|whitelisted|invalid" || echo "Failed: $ip"
        fi
    else
        echo "$output"
    fi

    return $exit_code
}

# =============================================================================
# BULK BAN FROM FILE (v1.39.0 P3-22)
# =============================================================================

_nftban_cmd_ban_from_file() {
    local file="$1" reason="$2" timeout="$3" ban_source="$4" json_mode="$5"

    if [[ ! -f "$file" ]]; then
        cmd_error "File not found: $file" "$json_mode"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        cmd_error "Cannot read file: $file" "$json_mode"
        return 1
    fi

    local NFTBAN_CORE
    NFTBAN_CORE=$(cmd_get_core_binary)
    cmd_require_binary "$NFTBAN_CORE" "nftban-core" "$json_mode" || return 1

    local total=0 success=0 skipped=0 failed=0
    local line_ip

    while IFS= read -r line_ip || [[ -n "$line_ip" ]]; do
        # Skip empty lines and comments
        line_ip="${line_ip%%#*}"
        line_ip="${line_ip// /}"
        [[ -z "$line_ip" ]] && continue

        total=$((total + 1))

        # Build command arguments
        local cmd_args=("$line_ip")
        [[ -n "$reason" ]] && cmd_args+=(--reason "$reason")
        [[ -n "$timeout" ]] && cmd_args+=(--timeout "$timeout")
        [[ -n "$ban_source" ]] && cmd_args+=(--source "$ban_source")

        local output
        if output=$("$NFTBAN_CORE" ban "${cmd_args[@]}" 2>&1); then
            success=$((success + 1))
        else
            if [[ "$output" == *"whitelisted"* ]] || [[ "$output" == *"already"* ]]; then
                skipped=$((skipped + 1))
            else
                failed=$((failed + 1))
                echo "FAIL: $line_ip — $output" >&2
            fi
        fi
    done < "$file"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        data="{\"total\":$total,\"success\":$success,\"skipped\":$skipped,\"failed\":$failed}"
        if [[ $failed -eq 0 ]]; then
            json_output "true" "$data"
        else
            json_output "false" "$data" "$failed IPs failed to ban"
        fi
    else
        echo "Bulk ban complete: $success banned, $skipped skipped, $failed failed (of $total)"
    fi

    [[ $failed -eq 0 ]]
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_ban_usage() {
    cat <<EOF
Usage: nftban ban <ip> [OPTIONS]
       nftban ban --file <path> [OPTIONS]

Ban an IP address or bulk ban from a file.

Arguments:
  <ip>                  IP address to ban (IPv4 or IPv6)

Options:
  --file <path>         Ban all IPs from a file (one per line, # comments ok)
  --reason "TEXT"       Ban reason (optional, stored as comment)
  --timeout SECONDS     Temporary ban duration (omit for permanent)
  --source SOURCE       Ban source (e.g., login, portscan, ddos, manual)
  --compact, -q         Compact output (essential info only)
  --dry-run             Show what would happen without executing
  --yes, -y             Skip confirmation prompt for permanent bans
  --async               Return immediately after sending the ban request
                        to the daemon; do NOT wait for kernel-set
                        confirmation. Use for high-throughput bulk imports
                        where caller does not need post-sync verification.
  --wait                Explicitly wait for nftables kernel-set sync
                        confirmation before returning. This is the
                        DEFAULT — flag is accepted for clarity in scripts
                        that want to be explicit.
  --help, -h            Show this help message

Examples:
  nftban ban 192.168.1.100
  nftban ban 192.168.1.100 --reason "Brute force attack"
  nftban ban 192.168.1.100 --timeout 3600 --reason "SSH brute-force"
  nftban ban --file /tmp/bad-ips.txt --reason "Bulk import" --source manual
  nftban ban 2001:db8::1

Notes:
  - Whitelisted IPs cannot be banned
  - Without --timeout, ban is permanent until manually removed
  - With --timeout, ban auto-expires after specified seconds
  - IP is added to ${NFTBAN_CONFIG_DIR}/blacklist.d/99-manual.conf
  - Default behavior writes to the blacklist file and waits for the
    kernel set to confirm sync before returning. --async skips the
    confirmation wait; the daemon still completes the sync, but the
    CLI returns before it is observable via 'nft list set ...'.
  - File format: one IP per line, # for comments, blank lines ignored

Exit Codes:
  0   Ban applied (or queued via --async)
  1   General error (invalid IP, IPC failure, write failure)
  2   IP is whitelisted; ban refused
  3   File path missing or unreadable (with --file)

See also:
  nftban unban <ip>     Remove IP ban
  nftban search <ip>    Check IP status
  nftban list           List all banned IPs

EOF
}

# Export function
export -f nftban_cmd_ban
export -f nftban_cmd_ban_usage
