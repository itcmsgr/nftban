#!/usr/bin/env bash
# =============================================================================
# NFTBan - Sync Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_sync"
# meta:type="core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Atomic firewall reload using Go-based sync engine"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core,nft"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

set -Eeuo pipefail
umask 027

# Constants - sync is a subcommand of nftban-core, not a separate binary
readonly NFTBAN_CORE_BIN="${NFTBAN_CORE_BIN:-/usr/lib/nftban/bin/nftban-core}"
# NFTBAN_LIB_DIR is set by the calling script - don't set it here

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" || return 1
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" || return 1
fi

# Load output library for nftban_output function
# shellcheck source=/usr/lib/nftban/core/nftban_output.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh" || return 1
fi

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

nftban_sync_full() {
    # Ask the daemon for a full (or --quick) sync of the durable sources into the
    # NFTBan sets, and wait for it. Usage:
    #   nftban_sync_full [--quick] [--wait <seconds>] [--join <generation>]
    #
    # v1.236: the daemon runs the sync off the IPC connection and joins repeated
    # requests by generation (nftband daemon_sync_coord.go). The exit code of
    # `nftban-core sync` is returned AS IS, because callers act on it:
    #   0 completed (applied or partial)   1 failed / refused / usage
    #   69 not delivered (nothing ran)      74 completion unknown
    #   75 still running when --wait ran out (join with --join <generation>)
    #
    # BUG-SYNC-DRY-RUN-AND-VALIDATE-PERFORM-REAL-SYNC (D1): --dry-run used to reach
    # nftban-core, which ignored it and ran a REAL sync. There is no dry-run sync, so
    # it is refused here and nothing is changed.

    local quick="" wait_s="" join=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                nftban_output "error" "sync has no dry-run mode; nothing was changed"
                nftban_output "info" "Read-only view: nftban sync status"
                return 1
                ;;
            --quick|-q) quick="--quick" ;;
            --wait) wait_s="${2:-}"; shift || true ;;
            --join) join="${2:-}"; shift || true ;;
        esac
        shift || true
    done

    # Check if Go binary exists
    if [[ ! -x "$NFTBAN_CORE_BIN" ]]; then
        nftban_output "error" "nftban-core binary not found: $NFTBAN_CORE_BIN"
        nftban_output "info" "Install the Go binary or build from source:"
        nftban_output "info" "  cd /path/to/nftban/cmd/nftban-core"
        nftban_output "info" "  go build -o $NFTBAN_CORE_BIN ."
        return 1
    fi

    # Check root
    if [[ $EUID -ne 0 ]]; then
        nftban_output "error" "PolicyKit/polkit authorization failed or insufficient privileges"
        return 1
    fi

    nftban_output "header" "NFTBan Sync - durable sources to the NFTBan sets"
    echo ""

    # Execute Go binary - sync is a subcommand of nftban-core
    # BUG-L56 FIX: Pass --quick flag through to Go binary
    local sync_args=()
    [[ -n "$quick" ]] && sync_args+=("--quick")
    [[ -n "$wait_s" ]] && sync_args+=("--wait" "$wait_s")
    [[ -n "$join" ]] && sync_args+=("--join" "$join")

    if [[ -n "$join" ]]; then
        nftban_output "info" "Mode: JOIN generation ${join} (no new sync submitted)"
    elif [[ -n "$quick" ]]; then
        nftban_output "info" "Mode: QUICK SYNC (whitelist/blacklist.d/ports; feeds and geoban skipped)"
    else
        nftban_output "info" "Mode: FULL SYNC (apply changes)"
    fi

    # v1.236: the exit code is the result (the v1.19.20 "trust the output text over
    # exit 1" heuristic is removed: it could turn a failure into a success).
    local exit_code=0
    "$NFTBAN_CORE_BIN" sync "${sync_args[@]}" 2>&1 || exit_code=$?

    echo ""
    case "$exit_code" in
        0)  nftban_output "success" "Firewall sync completed" ;;
        69) nftban_output "error" "Firewall sync NOT delivered: daemon unreachable, nothing ran (exit 69)" ;;
        74) nftban_output "error" "Firewall sync completion UNKNOWN: no answer from the daemon (exit 74)" ;;
        75) nftban_output "warning" "Firewall sync still RUNNING at the wait limit; not reported as complete (exit 75)" ;;
        *)  nftban_output "error" "Firewall sync failed (exit code: $exit_code)" ;;
    esac
    return "$exit_code"
}

nftban_sync_validate() {
    # v1.236 D1: there is no validate-only sync; this used to run a real sync.
    # Usage: nftban_sync_validate
    nftban_output "error" "sync validate has no validate-only mode; nothing was changed"
    nftban_output "info" "Read-only view: nftban sync status"
    return 1
}

nftban_sync_status() {
    # Show current sync status and statistics
    # Usage: nftban_sync_status

    nftban_output "header" "NFTBan Sync Status"
    echo ""

    # Check if tables exist (v0.7.3 dual-table architecture)
    local tables_ok=true
    if nft list table ${NFTBAN_TABLE_IPV4} &>/dev/null; then
        nftban_output "success" "Table '${NFTBAN_TABLE_IPV4}' exists"
    else
        nftban_output "error" "Table '${NFTBAN_TABLE_IPV4}' not found"
        tables_ok=false
    fi

    if nft list table ${NFTBAN_TABLE_IPV6} &>/dev/null; then
        nftban_output "success" "Table '${NFTBAN_TABLE_IPV6}' exists"
    else
        nftban_output "warning" "Table '${NFTBAN_TABLE_IPV6}' not found (IPv6 disabled?)"
    fi

    if [[ "$tables_ok" == "false" ]]; then
        nftban_output "info" "Run: nftban sync"
        return 1
    fi

    # Count sets (v0.7.3: check both IPv4 and IPv6 tables)
    echo ""
    nftban_output "info" "Sets in tables:"

    local ipv4_sets ipv6_sets
    ipv4_sets=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | { grep -E "^\s+set " || true; } | wc -l)
    ipv6_sets=$(nft list table ${NFTBAN_TABLE_IPV6} 2>/dev/null | { grep -E "^\s+set " || true; } | wc -l)
    nftban_output "info" "  IPv4 table sets: $ipv4_sets"
    nftban_output "info" "  IPv6 table sets: $ipv6_sets"

    # Count elements in key sets (v0.7.3: unified blacklist architecture)
    echo ""
    nftban_output "info" "Key sets (IPv4):"
    local set_name
    for set_name in whitelist_ipv4 blacklist_ipv4; do
        local count=0
        if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} "$set_name" &>/dev/null; then
            # Count elements properly - handle empty sets and multiline output
            local elements_line
            elements_line=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV4} "$set_name" 2>/dev/null | grep -oE "elements = \{[^}]*\}" || true)
            if [[ -n "$elements_line" && "$elements_line" != "elements = { }" ]]; then
                count=$(echo "$elements_line" | tr ',' '\n' | grep -cE "[0-9]" || true)
                count=${count:-0}
            fi
        fi
        # Ensure count is a valid integer
        [[ ! "$count" =~ ^[0-9]+$ ]] && count=0
        printf "  %-20s %d elements\n" "$set_name:" "$count"
    done

    echo ""
    nftban_output "info" "Key sets (IPv6):"
    for set_name in whitelist_ipv6 blacklist_ipv6; do
        local count=0
        if timeout 10s nft list set ${NFTBAN_TABLE_IPV6} "$set_name" &>/dev/null; then
            # Count elements properly - handle empty sets and multiline output
            local elements_line
            elements_line=$(timeout 10s nft list set ${NFTBAN_TABLE_IPV6} "$set_name" 2>/dev/null | grep -oE "elements = \{[^}]*\}" || true)
            if [[ -n "$elements_line" && "$elements_line" != "elements = { }" ]]; then
                count=$(echo "$elements_line" | tr ',' '\n' | grep -cE "[0-9a-fA-F:]" || true)
                count=${count:-0}
            fi
        fi
        # Ensure count is a valid integer
        [[ ! "$count" =~ ^[0-9]+$ ]] && count=0
        printf "  %-20s %d elements\n" "$set_name:" "$count"
    done

    # Last snapshot
    echo ""
    local snapshot_dir="${NFTBAN_DATA_DIR}/snapshots"
    if [[ -d "$snapshot_dir" ]]; then
        local latest_snapshot=""
        # Use find instead of ls to avoid pipefail errors on empty directories
        latest_snapshot=$(find "$snapshot_dir" -maxdepth 1 -name "snapshot-*.nft" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [[ -n "$latest_snapshot" && -f "$latest_snapshot" ]]; then
            local snapshot_time
            snapshot_time=$(stat -c %y "$latest_snapshot" 2>/dev/null | cut -d'.' -f1)
            nftban_output "info" "Last snapshot: $snapshot_time"
            nftban_output "info" "  File: $(basename "$latest_snapshot")"
        else
            nftban_output "warning" "No snapshots found"
        fi
    else
        nftban_output "warning" "Snapshots directory not found"
    fi

    echo ""
    return 0
}

nftban_sync_help() {
    # Show help for sync commands
    cat <<'EOF'
NFTBan Sync - durable sources to the NFTBan sets

COMMANDS:
  nftban sync                     Full sync (whitelist.d, blacklist.d, ports, feeds, geoban)
  nftban sync --quick             Skip feeds and geoban
  nftban sync --wait <seconds>    Bound the wait (default 300 full, 30 quick)
  nftban sync --join <generation> Report an earlier sync without starting a new one
  nftban sync status              Show the tables and key set sizes (read-only)
  nftban sync help                Show this help

DESCRIPTION:
  The daemon (nftband) reads the durable sources and updates the sets in
  ip nftban and ip6 nftban. It does not reload the ruleset; use
  'nftban firewall reload' or 'nftban firewall rebuild' for that.

  The daemon runs one sync at a time. A request made while a sync runs is
  answered by the next sync, which starts after the request (it never reports
  an older sync as covering newer configuration). Waiting longer joins the
  same sync instead of starting another one.

  There is no dry-run or validate-only mode: 'sync --dry-run' and
  'sync validate' refuse and change nothing.

EXIT CODES:
  0   completed (a partial result is printed as a warning)
  1   failed, refused, or usage error
  69  daemon unreachable, nothing ran
  74  completion unknown (no answer)
  75  still running at the wait limit; join with --join <generation>

FILES:
  /etc/nftban/whitelist.d/*.conf   Whitelist
  /etc/nftban/blacklist.d/*.conf   Blacklist (single IPs and CIDRs)
  /etc/nftban/geoban.d/*.conf      GeoBan country files
  /var/lib/nftban/feeds/*.txt      Feed files

SEE ALSO:
  nftban geoban, nftban feeds, nftban firewall
EOF
}

# =============================================================================
# MODULE EXPORTS
# =============================================================================

# Export functions for use by CLI
export -f nftban_sync_full
export -f nftban_sync_validate
export -f nftban_sync_status
export -f nftban_sync_help
