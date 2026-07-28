#!/usr/bin/env bash
# =============================================================================
# NFTBan - Snapshot Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Create configuration and statistics snapshots
#
# meta:name="cmd_snapshot"
# meta:type="cli"
# meta:header="Snapshot Command"
# meta:version="1.39.0"
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
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

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
            # v1.228.2 (OPEN_SNAPSHOT_SOURCE_TIME_DOUBLE_DISPATCH): this arm used
            # to fall through to `nftban_snapshot_create`, so any unrecognised
            # token — including the `restore` that bash-completion advertises —
            # silently CREATED a snapshot. The stated reason was "backwards
            # compatibility with systemd service", but
            # install/systemd/nftban-snapshot.service invokes
            # `nftban snapshot create` explicitly, and a bare `nftban snapshot`
            # still defaults to create via `subcmd="${1:-create}"` above. Nothing
            # depended on the catch-all, so an unsupported action now refuses.
            echo "ERROR: unsupported snapshot action: ${subcmd}" >&2
            echo "Supported: create, list, help" >&2
            return 2
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

    # Ensure directory exists (polkit-aware refusal instead of a raw write leak)
    mkdir -p "$snapshot_dir" 2>/dev/null || true
    if [[ $EUID -ne 0 && ! -w "$snapshot_dir" ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (create snapshot)" >&2
        return 1
    fi

    # Collect snapshot data
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"version\": \"$(cat /usr/share/nftban/VERSION 2>/dev/null || echo 'unknown')\","
        echo "  \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\","

        # NFT stats (v1.18.0: use ip/ip6 tables, not inet)
        local banned_v4=0 banned_v6=0
        if command -v nft &>/dev/null; then
            banned_v4=$(timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -c "elements" || true)
            banned_v4=${banned_v4:-0}
            banned_v6=$(timeout 10s nft list set ip6 nftban blacklist_ipv6 2>/dev/null | grep -c "elements" || true)
            banned_v6=${banned_v6:-0}
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

# Execute ONLY when run directly, never when sourced.
#
# v1.228.2 (OPEN_SNAPSHOT_SOURCE_TIME_DOUBLE_DISPATCH): the previous guard also
# fired on `[[ -n "${1:-}" ]]`. The router sources command modules with the
# caller's positional parameters still set (cli/sbin/nftban:1128 assigns
# `cmd="${1:-hello}"` and does NOT shift before the `source` at :1236), so $1 was
# always the literal command token "snapshot". That made the guard true for every
# invocation, executing nftban_cmd_snapshot at SOURCE time with subcmd="snapshot",
# which falls to the `*)` default-to-create arm — and the router then dispatched
# the real subcommand a second time. Measured: `snapshot create` created twice,
# `snapshot list` created once before listing, and the hourly
# nftban-snapshot.service path double-wrote in production.
#
# The systemd unit invokes `/usr/sbin/nftban snapshot create` through the router,
# so nothing ever depended on the sourced-with-args behaviour.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_snapshot "$@"
fi
