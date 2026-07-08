#!/usr/bin/env bash
# =============================================================================
# NFTBan - Flush CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Emergency flush/reset commands for nftables sets
#
# shellcheck disable=SC2086
# NOTE: SC2086 disabled because NFTBAN_TABLE_IPV4/IPV6 variables contain
# space-separated values like "ip nftban" that MUST be word-split when
# passed to nft commands (e.g., nft list set $NFTBAN_TABLE_IPV4 blacklist_ipv4
# expands to: nft list set ip nftban blacklist_ipv4). This is intentional.
#
# meta:name="cmd_flush"
# meta:type="cli"
# meta:header="Flush CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for flush/reset commands"
# meta:input="Command line arguments (blacklist, whitelist, feeds, geoban, all)"
# meta:output="Flush operation results"
# meta:depends="bash,nft_ipc.sh"
#
# meta:inventory.files="nft_ipc.sh,cmd_common.sh"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-04"
# meta:updated_date="2026-02-23"
# =============================================================================

set -Eeuo pipefail

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_is_json_mode, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Initialize CLI environment (loads config, sets paths, enables strict mode)
cmd_init

# Load IPC library for nftables operations
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Table/set names from central config
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"

# File locations
: "${NFTBAN_FEEDS_DIR:=/var/lib/nftban/feeds}"
: "${NFTBAN_GEOBAN_DIR:=/etc/nftban/geoban.d}"
: "${NFTBAN_WHITELIST_DIR:=/etc/nftban/whitelist.d}"
: "${NFTBAN_BLACKLIST_DIR:=/etc/nftban/blacklist.d}"

# System whitelist file (anti-lockout)
: "${NFTBAN_SYSTEM_WHITELIST:=/etc/nftban/whitelist.d/00-system-ip.conf}"

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_flush_help() {
    # V127 UX-6 D-1: banner suppressed in help dispatch (the no-args dashboard
    # banner is rendered separately). nftban_output.sh is no longer sourced
    # here because nftban_banner is the only symbol it provided to this path.

    cat <<'HELP'

USAGE:
    nftban flush <target> [options]

TARGETS:
    blacklist [SCOPE]   Flush blacklist bans. SCOPE: all (default; feed+GeoBan AND
                        manual+botscan) | feeds (blacklist_ipv4/ipv6) | manual
                        (blacklist_manual_ipv4/ipv6). Whitelist preserved.
    whitelist           Flush whitelist sets (system whitelist auto-restored)
    feeds               Flush only feed-sourced IPs from blacklist
    geoban              Flush only geoban-sourced IPs from blacklist
    ddos                Flush DDoS blocked set
    all                 EMERGENCY: Flush everything (system whitelist restored)

OPTIONS:
    --yes               Skip confirmation prompt
    --dry-run           Show what would be flushed without executing

EXAMPLES:
    nftban flush blacklist              # Flush all blacklist IPs (with prompt)
    nftban flush feeds --yes            # Flush feed IPs without prompt
    nftban flush all --dry-run          # Show what SOS mode would flush
    nftban flush geoban                 # Flush only geoban country IPs

SOURCE DISCRIMINATION:
    This command can selectively flush IPs by source because:

    - Feeds:  Stored in /var/lib/nftban/feeds/*.list
    - GeoBan: Stored in /etc/nftban/geoban.d/50-ban-*.conf
    - Manual: Stored in /etc/nftban/blacklist.d/*.conf
    - Temp:   DDoS/Portscan have nftables timeout (auto-expire)

    Flush reads the source files and deletes ONLY those IPs.

SAFETY:
    - System whitelist is ALWAYS preserved (anti-lockout mechanism)
    - Even "flush all" immediately restores system whitelist
    - Current SSH connection IP is protected

WARNING:
    Flushing blacklist removes protection! Use only for:
    - Emergency recovery (broken config)
    - Debugging firewall issues
    - Starting fresh after misconfiguration

CTRL+C / INTERRUPTION:
    Do NOT interrupt this command with Ctrl+C once flush has started.
    nftables set mutations are not transactional from the CLI's perspective;
    an interrupted flush can leave the kernel set partially emptied while
    the source files still claim those IPs are banned. Recovery requires
    'nftban firewall reload' to re-sync from config.

REQUIRES:
    Elevated privileges for mutating subcommands:
      all flush targets (blacklist, whitelist, feeds, geoban, ddos, all).

    Users in the nftban group may be authorized through PolicyKit/polkit
    rules for supported NFTBan operations.

    Read-only modes do not require elevated privileges:
      --dry-run.

EXIT CODES:
    0   Flush completed (or dry-run completed)
    1   General error (IPC failure, nft command failure)
    2   Unsupported target / invalid argument

HELP
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Count IPs in a set
_count_set_elements() {
    local table="$1"
    local set="$2"

    # V131 PR-A.2: removed a stray `grep -c "elements = {" || true` line here.
    # It echoed a first-pass count that the "More accurate count" below
    # immediately supersedes — emitting TWO numeric lines, so the caller's
    # `$(_count_set_elements ...)` captured a multiline value (the same
    # 0\n0-into-arithmetic bug class). The accurate count is the sole answer.
    local count
    count=$(timeout 10s nft list set $table "$set" 2>/dev/null | grep -oP '(?<=elements = \{ ).*(?= \})' | tr ',' '\n' | wc -l)
    if [[ $count -gt 0 ]]; then echo "$count"; else echo "0"; fi
}

# Count IPs in files
_count_file_ips() {
    local dir="$1"
    local pattern="$2"
    local count=0

    for file in "$dir"/$pattern; do
        [[ -f "$file" ]] || continue
        # Count non-comment, non-empty lines
        # V131 PR-A.2: hoist the grep -c out of the arithmetic. Inline
        # `$((count + $(grep -c ... || echo 0)))` would feed "0\n0" straight
        # into arithmetic on no-match (grep -c prints "0" + exits 1, then
        # `|| echo 0` appends a second 0) — a hard syntax-error crash. Capture
        # first with `|| true` + numeric fallback, then add.
        local _fc
        _fc=$(grep -cE '^[0-9a-fA-F]' "$file" 2>/dev/null || true)
        count=$((count + ${_fc:-0}))
    done

    echo "$count"
}

# Restore system whitelist after flush
_restore_system_whitelist() {
    local dry_run="${1:-false}"

    echo "Restoring system whitelist (anti-lockout)..."

    # Collect IPv4 and IPv6 IPs
    local ips_v4=""
    local ips_v6=""
    local count_v4=0
    local count_v6=0

    # Read from system whitelist file
    if [[ -f "$NFTBAN_SYSTEM_WHITELIST" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^#.* ]] && continue

            if [[ "$line" =~ : ]]; then
                [[ -n "$ips_v6" ]] && ips_v6+=","
                ips_v6+="$line"
                # v1.19.20 FIX
                ((count_v6++)) || true
            else
                [[ -n "$ips_v4" ]] && ips_v4+=","
                ips_v4+="$line"
                # v1.19.20 FIX
                ((count_v4++)) || true
            fi
        done < "$NFTBAN_SYSTEM_WHITELIST"
    fi

    # Also add current SSH source IP (anti-lockout)
    local ssh_ip="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_ip" ]] && [[ ! "$ips_v4" =~ $ssh_ip ]]; then
        [[ -n "$ips_v4" ]] && ips_v4+=","
        ips_v4+="$ssh_ip"
        # v1.19.20 FIX
        ((count_v4++)) || true
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "  [DRY-RUN] Would restore IPv4: $ips_v4"
        echo "  [DRY-RUN] Would restore IPv6: $ips_v6"
        return 0
    fi

    # Add IPv4 system IPs back via IPC (v1.18.0: IPC-only writes)
    if [[ -n "$ips_v4" ]]; then
        if declare -f nft_ipc_add_element &>/dev/null; then
            # H25 fix: IPs are comma-separated, split on comma for iteration
            local IFS_OLD="$IFS"
            IFS=','
            for ip in $ips_v4; do
                IFS="$IFS_OLD"
                ip="${ip// /}"  # trim whitespace
                [[ -z "$ip" ]] && continue
                nft_ipc_add_element "$NFTBAN_TABLE_IPV4" "whitelist_ipv4" "$ip" 2>/dev/null || true
            done
            IFS="$IFS_OLD"
        else
            # Fallback for emergency - direct nft (should rarely be used)
            # v1.19.27 SECURITY: Validate IPs contain only safe characters
            if [[ "$ips_v4" =~ ^[0-9.,/[:space:]]+$ ]]; then
                nft add element "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 "{ $ips_v4 }" 2>/dev/null || true
            fi
        fi
        echo "  Restored $count_v4 IPv4 system IPs"
    fi

    # Add IPv6 system IPs back via IPC (v1.18.0: IPC-only writes)
    if [[ -n "$ips_v6" ]]; then
        if declare -f nft_ipc_add_element &>/dev/null; then
            # H25 fix: IPs are comma-separated, split on comma for iteration
            local IFS_OLD="$IFS"
            IFS=','
            for ip in $ips_v6; do
                IFS="$IFS_OLD"
                ip="${ip// /}"  # trim whitespace
                [[ -z "$ip" ]] && continue
                nft_ipc_add_element "$NFTBAN_TABLE_IPV6" "whitelist_ipv6" "$ip" 2>/dev/null || true
            done
            IFS="$IFS_OLD"
        else
            # Fallback for emergency - direct nft (should rarely be used)
            # v1.19.27 SECURITY: Validate IPs contain only safe characters
            if [[ "$ips_v6" =~ ^[0-9a-fA-F:,/[:space:]]+$ ]]; then
                nft add element "${NFTBAN_TABLE_IPV6}" whitelist_ipv6 "{ $ips_v6 }" 2>/dev/null || true
            fi
        fi
        echo "  Restored $count_v6 IPv6 system IPs"
    fi
}

# Prompt user for confirmation
_confirm_flush() {
    local target="$1"
    local count_v4="$2"
    local count_v6="$3"
    local skip_confirm="${4:-false}"

    if [[ "$skip_confirm" == "true" ]]; then
        return 0
    fi

    echo ""
    echo "This will remove:"
    echo "  - $count_v4 IPv4 addresses from $target"
    echo "  - $count_v6 IPv6 addresses from $target"
    echo ""
    read -r -p "Proceed? [y/N] " response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            echo "Aborted."
            return 1
            ;;
    esac
}

# =============================================================================
# v1.19.0: IPC/EMERGENCY GATE HELPER (R20)
# =============================================================================

# Check daemon or emergency gate before flush operations
# Sets _FLUSH_IPC_MODE: 0=IPC, 1=emergency direct, 2=error
_flush_check_daemon() {
    nftban_ipc_check_or_emergency
    _FLUSH_IPC_MODE=$?
    if [[ $_FLUSH_IPC_MODE -eq 2 ]]; then
        echo "ERROR: nftband daemon is not running. Start with: systemctl start nftband" >&2
        return 1
    fi
    return 0
}

# v1.19.0: Flush a set through IPC or emergency direct access
# Usage: _flush_set_via_ipc <table> <set_name>
_flush_set_via_ipc() {
    local table="$1"
    local set_name="$2"

    if [[ ${_FLUSH_IPC_MODE:-2} -eq 0 ]]; then
        nft_ipc_flush_set "$table" "$set_name" 2>/dev/null
    else
        # Emergency direct nft access
        nft flush set $table "$set_name" 2>/dev/null
    fi
}

# v1.19.0: Apply ruleset file through IPC or emergency direct access
# Usage: _apply_file_via_ipc <file_path>
_apply_file_via_ipc() {
    local file_path="$1"

    if [[ ${_FLUSH_IPC_MODE:-2} -eq 0 ]]; then
        nft_ipc_apply_ruleset "$file_path" 2>/dev/null
    else
        # Emergency direct nft access
        nft -f "$file_path" 2>/dev/null
    fi
}

# =============================================================================
# FLUSH IMPLEMENTATIONS
# =============================================================================

# Flush entire blacklist sets
# Count kernel elements in one set (grep 'N elements' header, fallback to comma-split).
_flush_setcount() {
    local table="$1" set="$2" c
    c=$(timeout 10s nft list set "$table" "$set" 2>/dev/null | grep -oP '\d+(?= elements)' | head -1 || echo "")
    if [[ -z "$c" ]]; then
        c=$(timeout 10s nft list set "$table" "$set" 2>/dev/null | tr ',' '\n' | grep -cE '^[[:space:]]*[0-9a-fA-F]' || true)
    fi
    echo "${c:-0}"
}

# v1.218.10 BLACKLIST_FLUSH_TRUTH: bare `flush blacklist` clears ALL 4 real blacklist
# sets, not just the feed interval sets. Scope ∈ {all(default),feeds,manual}.
#   feeds  = blacklist_ipv4/ipv6      (feed + GeoBan interval CIDRs — shared set)
#   manual = blacklist_manual_ipv4/ipv6 (admin + botscan + portscan/login/ddos-escalated)
#   all    = both (what "blacklist flush" means to an operator)
# No new sets. Whitelist/port-allow sets untouched. Kernel-only (blacklist.d re-adds on reconcile).
_flush_blacklist() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"
    local scope="${3:-all}"
    [[ -z "$scope" ]] && scope="all"
    case "$scope" in
        feeds|manual|all) ;;
        *) echo "Unknown blacklist flush scope: '$scope' (valid: feeds | manual | all)"; return 2 ;;
    esac

    # Count all four real blacklist sets by authority.
    local fc4 fc6 mc4 mc6
    fc4=$(_flush_setcount "$NFTBAN_TABLE_IPV4" blacklist_ipv4)
    fc6=$(_flush_setcount "$NFTBAN_TABLE_IPV6" blacklist_ipv6)
    mc4=$(_flush_setcount "$NFTBAN_TABLE_IPV4" blacklist_manual_ipv4)
    mc6=$(_flush_setcount "$NFTBAN_TABLE_IPV6" blacklist_manual_ipv6)
    local feed_total=$((fc4 + fc6)) manual_total=$((mc4 + mc6))
    local grand=$((feed_total + manual_total)) removed=0

    echo "Flush target: blacklist (scope: $scope)"
    echo ""
    echo "Current blacklist (kernel sets):"
    echo "  Feed + GeoBan     IPv4: $fc4   IPv6: $fc6   (blacklist_ipv4/ipv6 — interval CIDRs)"
    echo "  Manual + BotScan  IPv4: $mc4   IPv6: $mc6   (blacklist_manual_ipv4/ipv6 — incl. portscan/login/ddos-escalated)"
    echo "  Total kernel:     $grand"
    echo ""

    # Sets to flush for this scope (existing sets only — no new sets created).
    local -a sets=()
    case "$scope" in
        feeds)  sets=("$NFTBAN_TABLE_IPV4|blacklist_ipv4" "$NFTBAN_TABLE_IPV6|blacklist_ipv6"); removed=$feed_total ;;
        manual) sets=("$NFTBAN_TABLE_IPV4|blacklist_manual_ipv4" "$NFTBAN_TABLE_IPV6|blacklist_manual_ipv6"); removed=$manual_total ;;
        all)    sets=("$NFTBAN_TABLE_IPV4|blacklist_ipv4" "$NFTBAN_TABLE_IPV6|blacklist_ipv6" \
                      "$NFTBAN_TABLE_IPV4|blacklist_manual_ipv4" "$NFTBAN_TABLE_IPV6|blacklist_manual_ipv6"); removed=$grand ;;
    esac

    echo "This will remove:"
    [[ "$scope" != manual ]] && echo "  - feed + GeoBan interval blacklist entries (blacklist_ipv4/ipv6)"
    [[ "$scope" != feeds  ]] && echo "  - manual/admin + botscan blacklist entries (blacklist_manual_ipv4/ipv6)"
    echo ""
    echo "WARNING:"
    echo "  - Flushes KERNEL blacklist sets only; persistent blacklist.d/*.conf entries"
    echo "    may be re-added on the next reconcile/reload."
    echo "  - Whitelist and port-allow sets are PRESERVED."
    [[ "$scope" != manual ]] && echo "  - feeds and GeoBan share the interval set — this also clears GeoBan country blocks (repopulate via feeds/geoban refresh)."

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would flush:"
        local s
        for s in "${sets[@]}"; do echo "  - flush set ${s%%|*} ${s##*|}"; done
        return 0
    fi

    # Confirm
    if [[ "$skip_confirm" != "true" ]]; then
        echo ""
        read -r -p "Proceed? [y/N] " response
        case "$response" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; return 1 ;; esac
    fi

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    echo ""
    echo "Flushing blacklist sets (scope: $scope)..."
    local s tbl name
    for s in "${sets[@]}"; do
        tbl="${s%%|*}"; name="${s##*|}"
        if _flush_set_via_ipc "$tbl" "$name"; then
            echo "  [OK] Flushed $name"
        else
            echo "  [WARN] Failed to flush $name"
        fi
    done

    echo ""
    echo "Blacklist flush complete (scope: $scope):"
    echo "  - Removed ~$removed kernel entries (feed+geoban: $feed_total, manual+botscan: $manual_total)"
    echo "  - Whitelist: preserved"
    return 0
}

# Flush whitelist sets (with auto-restore of system whitelist)
_flush_whitelist() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "Flush target: whitelist (whitelist_ipv4 + whitelist_ipv6)"
    echo ""

    # Count current elements
    local count_v4 count_v6
    count_v4=$(timeout 10s nft list set "$NFTBAN_TABLE_IPV4" whitelist_ipv4 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || true)
    count_v4=${count_v4:-0}
    count_v6=$(timeout 10s nft list set "$NFTBAN_TABLE_IPV6" whitelist_ipv6 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9a-f]' || true)
    count_v6=${count_v6:-0}

    echo "Current whitelist:"
    echo "  IPv4: ~$count_v4 entries"
    echo "  IPv6: ~$count_v6 entries"
    echo ""
    echo "NOTE: System whitelist will be automatically restored after flush"

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would flush:"
        echo "  - flush set $NFTBAN_TABLE_IPV4 whitelist_ipv4"
        echo "  - flush set $NFTBAN_TABLE_IPV6 whitelist_ipv6"
        echo "  - Then restore system whitelist IPs"
        _restore_system_whitelist true
        return 0
    fi

    # Confirm
    _confirm_flush "whitelist" "$count_v4" "$count_v6" "$skip_confirm" || return 1

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    # Execute flush via IPC
    echo ""
    echo "Flushing whitelist sets..."

    if _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "whitelist_ipv4"; then
        echo "  [OK] Flushed whitelist_ipv4"
    else
        echo "  [WARN] Failed to flush whitelist_ipv4"
    fi

    if _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "whitelist_ipv6"; then
        echo "  [OK] Flushed whitelist_ipv6"
    else
        echo "  [WARN] Failed to flush whitelist_ipv6"
    fi

    # Restore system whitelist (anti-lockout)
    echo ""
    _restore_system_whitelist false

    echo ""
    echo "Whitelist flush complete:"
    echo "  - Removed ~$count_v4 manual IPv4 entries"
    echo "  - Removed ~$count_v6 manual IPv6 entries"
    echo "  - System whitelist: RESTORED (anti-lockout)"

    return 0
}

# Flush only feed-sourced IPs
_flush_feeds() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "Flush target: feeds (IPs from threat feed files)"
    echo ""

    # Find all feed files
    local feed_files=()
    mapfile -t feed_files < <(find "$NFTBAN_FEEDS_DIR" -name "*.list" -o -name "*.txt" 2>/dev/null)

    if [[ ${#feed_files[@]} -eq 0 ]]; then
        echo "No feed files found in $NFTBAN_FEEDS_DIR"
        return 0
    fi

    # Count IPs in feed files
    local count_v4=0 count_v6=0
    local cidrs_v4=() cidrs_v6=()

    for file in "${feed_files[@]}"; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^#.* ]] && continue

            if [[ "$line" =~ : ]]; then
                cidrs_v6+=("$line")
                # v1.19.20 FIX
                ((count_v6++)) || true
            else
                cidrs_v4+=("$line")
                # v1.19.20 FIX
                ((count_v4++)) || true
            fi
        done < "$file"
    done

    echo "Feed files found: ${#feed_files[@]}"
    echo "Feed IPs to remove:"
    echo "  IPv4: $count_v4 entries"
    echo "  IPv6: $count_v6 entries"

    if [[ $count_v4 -eq 0 ]] && [[ $count_v6 -eq 0 ]]; then
        echo ""
        echo "No feed IPs to flush."
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would delete $count_v4 IPv4 and $count_v6 IPv6 feed entries"
        return 0
    fi

    # Confirm
    _confirm_flush "feeds" "$count_v4" "$count_v6" "$skip_confirm" || return 1

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    # Execute deletion via IPC (not flush - selective delete)
    echo ""
    echo "Removing feed IPs from blacklist..."

    # IPv4 deletion
    if [[ ${#cidrs_v4[@]} -gt 0 ]]; then
        local cidr_list="${cidrs_v4[*]}"
        cidr_list="${cidr_list// /, }"

        # v1.19.0: Use mktemp instead of PID-based temp files (R16)
        local tmp_file
        tmp_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_flush_feeds_v4.XXXXXX.nft")
        echo "delete element $NFTBAN_TABLE_IPV4 blacklist_ipv4 { $cidr_list }" > "$tmp_file"

        if _apply_file_via_ipc "$tmp_file"; then
            echo "  [OK] Removed $count_v4 IPv4 feed entries"
        else
            echo "  [WARN] Some IPv4 entries may not exist in set"
        fi
        rm -f "$tmp_file"
    fi

    # IPv6 deletion
    if [[ ${#cidrs_v6[@]} -gt 0 ]]; then
        local cidr_list="${cidrs_v6[*]}"
        cidr_list="${cidr_list// /, }"

        # v1.19.0: Use mktemp instead of PID-based temp files (R16)
        local tmp_file
        tmp_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_flush_feeds_v6.XXXXXX.nft")
        echo "delete element $NFTBAN_TABLE_IPV6 blacklist_ipv6 { $cidr_list }" > "$tmp_file"

        if _apply_file_via_ipc "$tmp_file"; then
            echo "  [OK] Removed $count_v6 IPv6 feed entries"
        else
            echo "  [WARN] Some IPv6 entries may not exist in set"
        fi
        rm -f "$tmp_file"
    fi

    echo ""
    echo "Feed flush complete:"
    echo "  - Removed $count_v4 IPv4 feed entries"
    echo "  - Removed $count_v6 IPv6 feed entries"
    echo "  - Other sources preserved (geoban, manual)"

    return 0
}

# Flush only geoban-sourced IPs
_flush_geoban() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "Flush target: geoban (IPs from country block files)"
    echo ""

    # Find all geoban files
    local ban_files=()
    mapfile -t ban_files < <(find "$NFTBAN_GEOBAN_DIR" -name "50-ban-*.conf" 2>/dev/null)

    if [[ ${#ban_files[@]} -eq 0 ]]; then
        echo "No geoban files found in $NFTBAN_GEOBAN_DIR"
        return 0
    fi

    # Count IPs in geoban files
    local count_v4=0 count_v6=0
    local cidrs_v4=() cidrs_v6=()

    for file in "${ban_files[@]}"; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^#.* ]] && continue

            if [[ "$line" =~ : ]]; then
                cidrs_v6+=("$line")
                # v1.19.20 FIX
                ((count_v6++)) || true
            else
                cidrs_v4+=("$line")
                # v1.19.20 FIX
                ((count_v4++)) || true
            fi
        done < "$file"
    done

    # List blocked countries
    local countries=()
    for file in "${ban_files[@]}"; do
        local cc
        cc=$(basename "$file" | sed -n 's/50-ban-\(.*\)\.conf/\1/p')
        countries+=("$cc")
    done

    echo "Blocked countries: ${countries[*]}"
    echo "GeoBan IPs to remove:"
    echo "  IPv4: $count_v4 entries"
    echo "  IPv6: $count_v6 entries"

    if [[ $count_v4 -eq 0 ]] && [[ $count_v6 -eq 0 ]]; then
        echo ""
        echo "No geoban IPs to flush."
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would delete $count_v4 IPv4 and $count_v6 IPv6 geoban entries"
        return 0
    fi

    # Confirm
    _confirm_flush "geoban" "$count_v4" "$count_v6" "$skip_confirm" || return 1

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    # Execute deletion via IPC
    echo ""
    echo "Removing geoban IPs from blacklist..."

    # IPv4 deletion (batch to avoid command line limit)
    if [[ ${#cidrs_v4[@]} -gt 0 ]]; then
        # v1.19.0: Use mktemp instead of PID-based temp files (R16)
        local tmp_file
        tmp_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_flush_geoban_v4.XXXXXX.nft")
        echo -n "delete element $NFTBAN_TABLE_IPV4 blacklist_ipv4 { " > "$tmp_file"
        local first=true
        for cidr in "${cidrs_v4[@]}"; do
            [[ "$first" == "true" ]] && first=false || echo -n ", " >> "$tmp_file"
            echo -n "$cidr" >> "$tmp_file"
        done
        echo " }" >> "$tmp_file"

        if _apply_file_via_ipc "$tmp_file"; then
            echo "  [OK] Removed $count_v4 IPv4 geoban entries"
        else
            echo "  [WARN] Some IPv4 entries may not exist in set"
        fi
        rm -f "$tmp_file"
    fi

    # IPv6 deletion
    if [[ ${#cidrs_v6[@]} -gt 0 ]]; then
        # v1.19.0: Use mktemp instead of PID-based temp files (R16)
        local tmp_file
        tmp_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_flush_geoban_v6.XXXXXX.nft")
        echo -n "delete element $NFTBAN_TABLE_IPV6 blacklist_ipv6 { " > "$tmp_file"
        local first=true
        for cidr in "${cidrs_v6[@]}"; do
            [[ "$first" == "true" ]] && first=false || echo -n ", " >> "$tmp_file"
            echo -n "$cidr" >> "$tmp_file"
        done
        echo " }" >> "$tmp_file"

        if _apply_file_via_ipc "$tmp_file"; then
            echo "  [OK] Removed $count_v6 IPv6 geoban entries"
        else
            echo "  [WARN] Some IPv6 entries may not exist in set"
        fi
        rm -f "$tmp_file"
    fi

    echo ""
    echo "GeoBan flush complete:"
    echo "  - Removed $count_v4 IPv4 country entries"
    echo "  - Removed $count_v6 IPv6 country entries"
    echo "  - Other sources preserved (feeds, manual)"

    return 0
}

# Flush DDoS blocked set
_flush_ddos() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "Flush target: ddos (ddos_blocked set)"
    echo ""

    # Check if DDoS set exists (IPv4 or IPv6)
    local _v4_exists=false _v6_exists=false
    timeout 10s nft list set "$NFTBAN_TABLE_IPV4" ddos_blocked &>/dev/null && _v4_exists=true
    timeout 10s nft list set "$NFTBAN_TABLE_IPV6" ddos_blocked &>/dev/null && _v6_exists=true
    if [[ "$_v4_exists" == "false" && "$_v6_exists" == "false" ]]; then
        echo "DDoS set (ddos_blocked) not found - DDoS protection may not be active"
        return 0
    fi

    # Count entries (IPv4 + IPv6)
    local count_v4=0 count_v6=0 count
    [[ "$_v4_exists" == "true" ]] && count_v4=$(timeout 10s nft list set "$NFTBAN_TABLE_IPV4" ddos_blocked 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || true)
    count_v4=${count_v4:-0}
    [[ "$_v6_exists" == "true" ]] && count_v6=$(timeout 10s nft list set "$NFTBAN_TABLE_IPV6" ddos_blocked 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9a-f]' || true)
    count_v6=${count_v6:-0}
    count=$(( count_v4 + count_v6 ))

    echo "DDoS blocked IPs: ~$count entries (IPv4: $count_v4, IPv6: $count_v6)"
    echo ""
    echo "NOTE: DDoS entries have timeouts and auto-expire"

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would flush: ddos_blocked (IPv4 + IPv6)"
        return 0
    fi

    # Confirm
    _confirm_flush "ddos_blocked" "$count" "0" "$skip_confirm" || return 1

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    # Execute flush via IPC (IPv4 + IPv6)
    echo ""
    [[ "$_v4_exists" == "true" ]] && { _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "ddos_blocked" && echo "[OK] Flushed ddos_blocked (IPv4)" || echo "[WARN] Failed to flush ddos_blocked (IPv4)"; }
    [[ "$_v6_exists" == "true" ]] && { _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "ddos_blocked" && echo "[OK] Flushed ddos_blocked (IPv6)" || echo "[WARN] Failed to flush ddos_blocked (IPv6)"; }

    echo ""
    echo "DDoS flush complete:"
    echo "  - Removed ~$count blocked IPs (IPv4: $count_v4, IPv6: $count_v6)"

    return 0
}

# EMERGENCY: Flush ALL sets
_flush_all() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "=========================================="
    echo "  SOS EMERGENCY FLUSH - ALL SETS"
    echo "=========================================="
    echo ""
    echo "WARNING: This will flush:"
    echo "  - blacklist_ipv4 / blacklist_ipv6 (feed + GeoBan)"
    echo "  - blacklist_manual_ipv4 / blacklist_manual_ipv6 (manual + botscan)"
    echo "  - whitelist_ipv4 / whitelist_ipv6 (then restored)"
    echo "  - ddos_blocked / portscan_blocked (if present)"
    echo "  NOTE: persistent blacklist.d/*.conf entries re-add on reconcile/reload."
    echo ""
    echo "System whitelist will be IMMEDIATELY restored after flush."
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY-RUN] Would flush all sets and restore system whitelist"
        return 0
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        read -r -p "THIS IS A DESTRUCTIVE OPERATION. Type 'yes' to confirm: " response
        if [[ "$response" != "yes" ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    # v1.19.0: Check daemon or emergency gate (R20)
    _flush_check_daemon || return 1

    echo ""
    echo "Executing emergency flush..."

    # v1.19.0: Flush all sets via IPC (batched sequential requests)
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "blacklist_ipv4" && echo "[OK] Flushed blacklist_ipv4"
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "blacklist_ipv6" && echo "[OK] Flushed blacklist_ipv6"

    # v1.218.10: manual/botscan bans live here — MUST be flushed by "all" too.
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "blacklist_manual_ipv4" && echo "[OK] Flushed blacklist_manual_ipv4"
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "blacklist_manual_ipv6" && echo "[OK] Flushed blacklist_manual_ipv6"

    # Flush whitelist
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "whitelist_ipv4" && echo "[OK] Flushed whitelist_ipv4"
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "whitelist_ipv6" && echo "[OK] Flushed whitelist_ipv6"

    # Flush DDoS (IPv4 + IPv6)
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "ddos_blocked" && echo "[OK] Flushed ddos_blocked (IPv4)"
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "ddos_blocked" && echo "[OK] Flushed ddos_blocked (IPv6)"

    # Flush portscan (IPv4 + IPv6)
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV4" "portscan_blocked" && echo "[OK] Flushed portscan_blocked (IPv4)"
    _flush_set_via_ipc "$NFTBAN_TABLE_IPV6" "portscan_blocked" && echo "[OK] Flushed portscan_blocked (IPv6)"

    # CRITICAL: Restore system whitelist immediately
    echo ""
    _restore_system_whitelist false

    echo ""
    echo "=========================================="
    echo "  EMERGENCY FLUSH COMPLETE"
    echo "=========================================="
    echo ""
    echo "All sets flushed. System whitelist restored."
    echo ""
    echo "To reload configuration:"
    echo "  nftban-core sync    # Reload all feeds, geoban, etc."

    return 0
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_flush() {
    local target="${1:-}"
    shift || true

    # Parse options
    local skip_confirm=false
    local dry_run=false
    local subtarget=""   # optional scope for 'blacklist' (feeds|manual|all)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                skip_confirm=true
                ;;
            --dry-run|-n)
                dry_run=true
                ;;
            --help|-h)
                _nftban_flush_help
                return 0
                ;;
            *)
                # First bare positional = subtarget (e.g. `flush blacklist manual`).
                if [[ -z "$subtarget" ]]; then
                    subtarget="$1"
                else
                    echo "Unknown option: $1"
                    _nftban_flush_help
                    return 2
                fi
                ;;
        esac
        shift
    done

    case "$target" in
        blacklist)
            _flush_blacklist "$skip_confirm" "$dry_run" "$subtarget"
            ;;
        whitelist)
            _flush_whitelist "$skip_confirm" "$dry_run"
            ;;
        feeds)
            _flush_feeds "$skip_confirm" "$dry_run"
            ;;
        geoban)
            _flush_geoban "$skip_confirm" "$dry_run"
            ;;
        ddos)
            _flush_ddos "$skip_confirm" "$dry_run"
            ;;
        all)
            _flush_all "$skip_confirm" "$dry_run"
            ;;
        help|--help|-h|"")
            _nftban_flush_help
            return 0
            ;;
        *)
            echo "Unknown target: $target"
            echo ""
            echo "Valid targets: blacklist, whitelist, feeds, geoban, ddos, all"
            return 2
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_flush
