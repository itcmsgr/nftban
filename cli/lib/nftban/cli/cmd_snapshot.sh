#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Snapshot Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Create configuration and statistics snapshots
#
# meta:name="cmd_snapshot"
# meta:type="cli"
# meta:header="Snapshot Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Create snapshots of NFTBan configuration and statistics"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-snapshot.service,nftban-snapshot.timer"
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# meta:created_date="2026-02-01"
# meta:updated_date="2026-02-01"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${CMD_SNAPSHOT_LOADED:-}" ]] && return 0

# Load common CLI helpers
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh"

# Initialize CLI environment
cmd_init

readonly CMD_SNAPSHOT_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_snapshot() {
    # Create or list snapshots
    # Usage: nftban snapshot [create|list]

    local subcmd="${1:-create}"
    shift 2>/dev/null || true

    case "$subcmd" in
        create)
            nftban_snapshot_create "$@"
            ;;
        list)
            nftban_snapshot_list "$@"
            ;;
        -h|--help|help)
            nftban_snapshot_help
            ;;
        *)
            # Default to create for backwards compatibility with systemd service
            nftban_snapshot_create "$@"
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: CREATE
# =============================================================================

nftban_snapshot_create() {
    # Create a snapshot of current state
    local snapshot_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/snapshots"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_file="${snapshot_dir}/snapshot-${timestamp}.json"

    # Ensure directory exists
    mkdir -p "$snapshot_dir"

    # Collect snapshot data
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"version\": \"$(cat /usr/share/nftban/VERSION 2>/dev/null || echo 'unknown')\","
        echo "  \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\","

        # NFT stats (v1.18.0: use ip/ip6 tables, not inet)
        local banned_v4=0 banned_v6=0
        if command -v nft &>/dev/null; then
            banned_v4=$(nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -c "elements" || echo "0")
            banned_v6=$(nft list set ip6 nftban blacklist_ipv6 2>/dev/null | grep -c "elements" || echo "0")
        fi
        echo "  \"banned_ipv4\": $banned_v4,"
        echo "  \"banned_ipv6\": $banned_v6,"

        # Service status
        local services_running=0
        for svc in nftband nftban-login-monitor nftban-watchdog; do
            systemctl is-active "$svc" &>/dev/null && ((++services_running)) || true
        done
        echo "  \"services_running\": $services_running"

        echo "}"
    } > "$snapshot_file"

    chmod 640 "$snapshot_file"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "Snapshot created: ${snapshot_file}"
    else
        echo "[OK] Snapshot: ${snapshot_file}"
    fi
}

# =============================================================================
# SUBCOMMAND: LIST
# =============================================================================

nftban_snapshot_list() {
    local snapshot_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/snapshots"

    if [[ ! -d "$snapshot_dir" ]]; then
        echo "No snapshots found"
        return 0
    fi

    echo "Available snapshots:"
    ls -1t "$snapshot_dir"/snapshot-*.json 2>/dev/null | head -20 || echo "  (none)"
}

# =============================================================================
# HELP
# =============================================================================

nftban_snapshot_help() {
    cat <<EOF
NFTBan Snapshot Command

Usage: nftban snapshot [SUBCOMMAND]

Subcommands:
  create    Create a new snapshot (default)
  list      List available snapshots
  help      Show this help

Examples:
  nftban snapshot              # Create snapshot
  nftban snapshot create       # Create snapshot
  nftban snapshot list         # List snapshots

EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_snapshot
export -f nftban_snapshot_help

# Execute if sourced with arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ -n "${1:-}" ]]; then
    nftban_cmd_snapshot "$@"
fi
