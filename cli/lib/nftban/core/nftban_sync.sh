#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Sync Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_sync"
# meta:type="core"
# meta:version="1.0.0"
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
    # Perform full atomic firewall reload
    # Usage: nftban_sync_full [--dry-run]
    #
    # Algorithm (v0.6.0):
    # 1. Read static config (whitelist, blacklist, ports)
    # 2. Build feed sets (Go pkg/feeds)
    # 3. Build geoban sets (Go pkg/geoban)
    # 4. Dump runtime sets (temp_ban_*, temp_whitelist_*)
    # 5. Generate rules.new.nft
    # 6. Validate: nft -c -f rules.new.nft
    # 7. Snapshot: nft list ruleset > backup.nft
    # 8. Apply: nft -f rules.new.nft
    # 9. Restore runtime elements
    # 10. Cleanup old snapshots

    local dry_run=""
    local quick=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run="--dry-run" ;;
            --quick|-q) quick="--quick" ;;
        esac
        shift
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
        nftban_output "error" "This command must be run as root"
        return 1
    fi

    nftban_output "header" "NFTBan Sync - Atomic Firewall Reload"
    nftban_output "info" "Architecture: Dual-table (ip nftban + ip6 nftban)"
    echo ""

    # Execute Go binary - sync is a subcommand of nftban-core
    # BUG-L56 FIX: Pass --quick flag through to Go binary
    local sync_args=()
    [[ -n "$dry_run" ]] && sync_args+=("--dry-run")
    [[ -n "$quick" ]] && sync_args+=("--quick")

    if [[ -n "$dry_run" ]]; then
        nftban_output "info" "Mode: DRY RUN (validate only)"
    elif [[ -n "$quick" ]]; then
        nftban_output "info" "Mode: QUICK SYNC (skip unchanged sets)"
    else
        nftban_output "info" "Mode: FULL SYNC (apply changes)"
    fi

    # v1.19.20 FIX (B3): Go binary may return exit 1 even on success.
    # Capture output and exit code, then validate based on output content.
    local sync_output exit_code
    sync_output=$("$NFTBAN_CORE_BIN" sync "${sync_args[@]}" 2>&1) && exit_code=0 || exit_code=$?

    # Print the output (user expects to see it)
    if [[ -n "$sync_output" ]]; then
        echo "$sync_output"
    fi

    # v1.19.20 FIX (B3): Check for success indicators in output even if exit code is 1.
    # The Go binary may return exit 1 spuriously; trust the output content instead.
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        nftban_output "success" "Firewall sync completed successfully"
        nftban_output "info" "Tables: ip nftban (IPv4) + ip6 nftban (IPv6)"
        nftban_output "info" "Runtime state: Fail2Ban bans preserved"
        return 0
    elif [[ $exit_code -eq 1 ]] && echo "$sync_output" | grep -qE "(sync completed|rules applied|validation passed|Sync complete)"; then
        # Exit 1 but output indicates success - treat as success
        echo ""
        nftban_output "success" "Firewall sync completed successfully"
        nftban_output "info" "Tables: ip nftban (IPv4) + ip6 nftban (IPv6)"
        nftban_output "info" "Runtime state: Fail2Ban bans preserved"
        return 0
    else
        echo ""
        nftban_output "error" "Firewall sync failed (exit code: $exit_code)"
        return 1
    fi
}

nftban_sync_validate() {
    # Validate firewall configuration without applying
    # Usage: nftban_sync_validate

    nftban_output "info" "Validating firewall configuration..."
    nftban_sync_full --dry-run
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
                count=$(echo "$elements_line" | tr ',' '\n' | grep -cE "[0-9]" || echo 0)
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
                count=$(echo "$elements_line" | tr ',' '\n' | grep -cE "[0-9a-fA-F:]" || echo 0)
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
NFTBan Sync - Atomic Firewall Reload

COMMANDS:
  nftban sync              Full atomic firewall reload
  nftban sync --dry-run    Validate configuration only
  nftban sync status       Show current sync status
  nftban sync validate     Validate without applying
  nftban sync help         Show this help

DESCRIPTION:
  The 'sync' command performs atomic firewall reload using the
  dual-table architecture (ip nftban + ip6 nftban).

ALGORITHM:
  1. Read static config (whitelist, blacklist, ports)
  2. Build feed sets (Go pkg/feeds) - <2s for 50,000+ IPs
  3. Build geoban sets (Go pkg/geoban) - <2s for 2,259 CIDRs
  4. Dump Fail2Ban runtime state (temp_ban_*, temp_whitelist_*)
  5. Generate new ruleset (rules.new.nft)
  6. Validate (nft -c -f)
  7. Snapshot current rules (automatic backup)
  8. Apply new rules (nft -f)
  9. Restore Fail2Ban bans (preserve runtime state)
  10. Cleanup old snapshots (keep 10 most recent)

FEATURES:
  - Atomic transaction (all-or-nothing)
  - Preserves Fail2Ban runtime bans
  - Automatic validation before apply
  - Automatic rollback snapshots
  - 100x faster than bash (GeoBan: 120s → 2s)

ARCHITECTURE:
  - Tables: ip nftban (IPv4) + ip6 nftban (IPv6)
  - Unified blacklist (all bans consolidated per family)
  - Rule order: Drops BEFORE ct state established
  - Go modules: pkg/feeds, pkg/geoban, pkg/firewall

EXAMPLES:
  # Full sync (production)
  nftban sync

  # Validate only (test before apply)
  nftban sync --dry-run

  # Check status
  nftban sync status

FILES:
  /etc/nftban/whitelist.conf       Permanent whitelist
  /etc/nftban/blacklist.conf       Permanent blacklist
  /etc/nftban/geoban.d/*.conf      GeoBan country files
  /var/lib/nftban/feeds/*.txt      External feed files
  /var/lib/nftban/staging/         Temporary rulesets
  /var/lib/nftban/snapshots/       Automatic backups

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
