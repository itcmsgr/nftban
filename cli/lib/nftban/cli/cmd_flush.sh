#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Flush CLI Handler
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
# meta:version="1.0.0"
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
# meta:updated_date="2026-01-18"
# =============================================================================

set -Eeuo pipefail

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_is_json_mode, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh"

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
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban flush <target> [options]

TARGETS:
    blacklist           Flush ALL IPs from blacklist_ipv4/ipv6 sets
    whitelist           Flush whitelist sets (system whitelist auto-restored)
    feeds               Flush only feed-sourced IPs from blacklist
    geoban              Flush only geoban-sourced IPs from blacklist
    ddos                Flush DDoS blocked set
    all                 EMERGENCY: Flush everything (system whitelist restored)

OPTIONS:
    --yes               Skip confirmation prompt
    --dry-run           Show what would be flushed without executing
    --json              Output in JSON format

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

HELP
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Count IPs in a set
_count_set_elements() {
    local table="$1"
    local set="$2"

    timeout 10s nft list set $table "$set" 2>/dev/null | grep -c "elements = {" || echo "0"
    # More accurate count
    local count
    count=$(timeout 10s nft list set $table "$set" 2>/dev/null | grep -oP '(?<=elements = \{ ).*(?= \})' | tr ',' '\n' | wc -l)
    [[ $count -gt 0 ]] && echo "$count" || echo "0"
}

# Count IPs in files
_count_file_ips() {
    local dir="$1"
    local pattern="$2"
    local count=0

    for file in "$dir"/$pattern; do
        [[ -f "$file" ]] || continue
        # Count non-comment, non-empty lines
        count=$((count + $(grep -cE '^[0-9a-fA-F]' "$file" 2>/dev/null || echo 0)))
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
                ((count_v6++))
            else
                [[ -n "$ips_v4" ]] && ips_v4+=","
                ips_v4+="$line"
                ((count_v4++))
            fi
        done < "$NFTBAN_SYSTEM_WHITELIST"
    fi

    # Also add current SSH source IP (anti-lockout)
    local ssh_ip="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_ip" ]] && [[ ! "$ips_v4" =~ $ssh_ip ]]; then
        [[ -n "$ips_v4" ]] && ips_v4+=","
        ips_v4+="$ssh_ip"
        ((count_v4++))
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "  [DRY-RUN] Would restore IPv4: $ips_v4"
        echo "  [DRY-RUN] Would restore IPv6: $ips_v6"
        return 0
    fi

    # Add IPv4 system IPs back via IPC (v1.18.0: IPC-only writes)
    if [[ -n "$ips_v4" ]]; then
        if declare -f nft_ipc_add_element &>/dev/null; then
            for ip in $ips_v4; do
                nft_ipc_add_element "$NFTBAN_TABLE_IPV4" "whitelist_ipv4" "$ip" 2>/dev/null || true
            done
        else
            # Fallback for emergency - direct nft (should rarely be used)
            nft add element $NFTBAN_TABLE_IPV4 whitelist_ipv4 "{ $ips_v4 }" 2>/dev/null || true
        fi
        echo "  Restored $count_v4 IPv4 system IPs"
    fi

    # Add IPv6 system IPs back via IPC (v1.18.0: IPC-only writes)
    if [[ -n "$ips_v6" ]]; then
        if declare -f nft_ipc_add_element &>/dev/null; then
            for ip in $ips_v6; do
                nft_ipc_add_element "$NFTBAN_TABLE_IPV6" "whitelist_ipv6" "$ip" 2>/dev/null || true
            done
        else
            # Fallback for emergency - direct nft (should rarely be used)
            nft add element $NFTBAN_TABLE_IPV6 whitelist_ipv6 "{ $ips_v6 }" 2>/dev/null || true
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
# FLUSH IMPLEMENTATIONS
# =============================================================================

# Flush entire blacklist sets
_flush_blacklist() {
    local skip_confirm="${1:-false}"
    local dry_run="${2:-false}"

    echo "Flush target: blacklist (blacklist_ipv4 + blacklist_ipv6)"
    echo ""

    # Count current elements
    local count_v4 count_v6
    count_v4=$(timeout 10s nft list set $NFTBAN_TABLE_IPV4 blacklist_ipv4 2>/dev/null | grep -oP '\d+(?= elements)' || echo "0")
    count_v6=$(timeout 10s nft list set $NFTBAN_TABLE_IPV6 blacklist_ipv6 2>/dev/null | grep -oP '\d+(?= elements)' || echo "0")

    # Fallback count method
    [[ "$count_v4" == "0" ]] && count_v4=$(timeout 10s nft list set $NFTBAN_TABLE_IPV4 blacklist_ipv4 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || echo "0")
    [[ "$count_v6" == "0" ]] && count_v6=$(timeout 10s nft list set $NFTBAN_TABLE_IPV6 blacklist_ipv6 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9a-f]' || echo "0")

    echo "Current blacklist:"
    echo "  IPv4: ~$count_v4 entries"
    echo "  IPv6: ~$count_v6 entries"

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would flush:"
        echo "  - flush set $NFTBAN_TABLE_IPV4 blacklist_ipv4"
        echo "  - flush set $NFTBAN_TABLE_IPV6 blacklist_ipv6"
        return 0
    fi

    # Confirm
    _confirm_flush "blacklist" "$count_v4" "$count_v6" "$skip_confirm" || return 1

    # Execute flush
    echo ""
    echo "Flushing blacklist sets..."

    if nft flush set $NFTBAN_TABLE_IPV4 blacklist_ipv4 2>/dev/null; then
        echo "  [OK] Flushed blacklist_ipv4"
    else
        echo "  [WARN] Failed to flush blacklist_ipv4"
    fi

    if nft flush set $NFTBAN_TABLE_IPV6 blacklist_ipv6 2>/dev/null; then
        echo "  [OK] Flushed blacklist_ipv6"
    else
        echo "  [WARN] Failed to flush blacklist_ipv6"
    fi

    echo ""
    echo "Blacklist flush complete:"
    echo "  - Removed ~$count_v4 IPv4 entries"
    echo "  - Removed ~$count_v6 IPv6 entries"
    echo "  - System whitelist: preserved (in whitelist set)"

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
    count_v4=$(timeout 10s nft list set $NFTBAN_TABLE_IPV4 whitelist_ipv4 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || echo "0")
    count_v6=$(timeout 10s nft list set $NFTBAN_TABLE_IPV6 whitelist_ipv6 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9a-f]' || echo "0")

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

    # Execute flush
    echo ""
    echo "Flushing whitelist sets..."

    if nft flush set $NFTBAN_TABLE_IPV4 whitelist_ipv4 2>/dev/null; then
        echo "  [OK] Flushed whitelist_ipv4"
    else
        echo "  [WARN] Failed to flush whitelist_ipv4"
    fi

    if nft flush set $NFTBAN_TABLE_IPV6 whitelist_ipv6 2>/dev/null; then
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
                ((count_v6++))
            else
                cidrs_v4+=("$line")
                ((count_v4++))
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

    # Execute deletion (not flush - selective delete)
    echo ""
    echo "Removing feed IPs from blacklist..."

    # IPv4 deletion
    if [[ ${#cidrs_v4[@]} -gt 0 ]]; then
        local cidr_list="${cidrs_v4[*]}"
        cidr_list="${cidr_list// /, }"

        local tmp_file="/tmp/nftban_flush_feeds_v4_$$.nft"
        echo "delete element $NFTBAN_TABLE_IPV4 blacklist_ipv4 { $cidr_list }" > "$tmp_file"

        if nft -f "$tmp_file" 2>/dev/null; then
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

        local tmp_file="/tmp/nftban_flush_feeds_v6_$$.nft"
        echo "delete element $NFTBAN_TABLE_IPV6 blacklist_ipv6 { $cidr_list }" > "$tmp_file"

        if nft -f "$tmp_file" 2>/dev/null; then
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
                ((count_v6++))
            else
                cidrs_v4+=("$line")
                ((count_v4++))
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

    # Execute deletion
    echo ""
    echo "Removing geoban IPs from blacklist..."

    # IPv4 deletion (batch to avoid command line limit)
    if [[ ${#cidrs_v4[@]} -gt 0 ]]; then
        local tmp_file="/tmp/nftban_flush_geoban_v4_$$.nft"
        echo -n "delete element $NFTBAN_TABLE_IPV4 blacklist_ipv4 { " > "$tmp_file"
        local first=true
        for cidr in "${cidrs_v4[@]}"; do
            [[ "$first" == "true" ]] && first=false || echo -n ", " >> "$tmp_file"
            echo -n "$cidr" >> "$tmp_file"
        done
        echo " }" >> "$tmp_file"

        if nft -f "$tmp_file" 2>/dev/null; then
            echo "  [OK] Removed $count_v4 IPv4 geoban entries"
        else
            echo "  [WARN] Some IPv4 entries may not exist in set"
        fi
        rm -f "$tmp_file"
    fi

    # IPv6 deletion
    if [[ ${#cidrs_v6[@]} -gt 0 ]]; then
        local tmp_file="/tmp/nftban_flush_geoban_v6_$$.nft"
        echo -n "delete element $NFTBAN_TABLE_IPV6 blacklist_ipv6 { " > "$tmp_file"
        local first=true
        for cidr in "${cidrs_v6[@]}"; do
            [[ "$first" == "true" ]] && first=false || echo -n ", " >> "$tmp_file"
            echo -n "$cidr" >> "$tmp_file"
        done
        echo " }" >> "$tmp_file"

        if nft -f "$tmp_file" 2>/dev/null; then
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

    # Check if DDoS set exists
    if ! timeout 10s nft list set $NFTBAN_TABLE_IPV4 ddos_blocked &>/dev/null; then
        echo "DDoS set (ddos_blocked) not found - DDoS protection may not be active"
        return 0
    fi

    # Count entries
    local count
    count=$(timeout 10s nft list set $NFTBAN_TABLE_IPV4 ddos_blocked 2>/dev/null | tr ',' '\n' | grep -cE '^[0-9]' || echo "0")

    echo "DDoS blocked IPs: ~$count entries"
    echo ""
    echo "NOTE: DDoS entries have timeouts and auto-expire"

    if [[ "$dry_run" == "true" ]]; then
        echo ""
        echo "[DRY-RUN] Would flush: flush set $NFTBAN_TABLE_IPV4 ddos_blocked"
        return 0
    fi

    # Confirm
    _confirm_flush "ddos_blocked" "$count" "0" "$skip_confirm" || return 1

    # Execute flush
    echo ""
    if nft flush set $NFTBAN_TABLE_IPV4 ddos_blocked 2>/dev/null; then
        echo "[OK] Flushed ddos_blocked set"
    else
        echo "[WARN] Failed to flush ddos_blocked"
    fi

    echo ""
    echo "DDoS flush complete:"
    echo "  - Removed ~$count blocked IPs"

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
    echo "  - blacklist_ipv4 / blacklist_ipv6"
    echo "  - whitelist_ipv4 / whitelist_ipv6 (then restored)"
    echo "  - ddos_blocked (if exists)"
    echo "  - portscan_blocked (if exists)"
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

    echo ""
    echo "Executing emergency flush..."

    # Flush blacklist
    nft flush set $NFTBAN_TABLE_IPV4 blacklist_ipv4 2>/dev/null && echo "[OK] Flushed blacklist_ipv4"
    nft flush set $NFTBAN_TABLE_IPV6 blacklist_ipv6 2>/dev/null && echo "[OK] Flushed blacklist_ipv6"

    # Flush whitelist
    nft flush set $NFTBAN_TABLE_IPV4 whitelist_ipv4 2>/dev/null && echo "[OK] Flushed whitelist_ipv4"
    nft flush set $NFTBAN_TABLE_IPV6 whitelist_ipv6 2>/dev/null && echo "[OK] Flushed whitelist_ipv6"

    # Flush DDoS
    nft flush set $NFTBAN_TABLE_IPV4 ddos_blocked 2>/dev/null && echo "[OK] Flushed ddos_blocked"

    # Flush portscan
    nft flush set $NFTBAN_TABLE_IPV4 portscan_blocked 2>/dev/null && echo "[OK] Flushed portscan_blocked"

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
    # shellcheck disable=SC2034  # Reserved for future JSON output support
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)
                skip_confirm=true
                ;;
            --dry-run|-n)
                dry_run=true
                ;;
            --json)
                # shellcheck disable=SC2034  # Reserved for future JSON output
                json_mode=true
                ;;
            --help|-h)
                _nftban_flush_help
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                _nftban_flush_help
                return 1
                ;;
        esac
        shift
    done

    case "$target" in
        blacklist)
            _flush_blacklist "$skip_confirm" "$dry_run"
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
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_flush
