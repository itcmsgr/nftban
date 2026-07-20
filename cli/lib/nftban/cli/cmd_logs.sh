#!/usr/bin/env bash
# =============================================================================
# NFTBan - Logs Command (log-retention visibility)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Operator-facing, READ-ONLY visibility into the effective log-retention
#          policy. Delegates to `nftban-core logretention status`, which reports
#          the authoritative generated-state + live filesystem/usage/override
#          facts. Mutating retention (regeneration) is not exposed here — it is an
#          install/timer/config-change action.
#
# meta:name="cmd_logs"
# meta:type="cli"
# meta:header="Logs Command"
# meta:version="1.222.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Read-only log-retention visibility: nftban logs retention status [--json]"
# meta:inventory.files="/etc/nftban/conf.d/logs.conf"
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars="NFTBAN_CORE_BIN,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/logs.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
#
# meta:created_date="2026-07-19"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
if [[ -n "${_NFTBAN_CMD_LOGS_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NFTBAN_CMD_LOGS_LOADED=1

_nftban_logs_core_bin() {
    printf '%s' "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
}

_nftban_logs_help() {
    cat <<'EOF'
Usage: nftban logs <subcommand>

Subcommands:
  retention status [--json]   Show the effective log-retention policy (read-only).

The effective policy is derived from the /var/log filesystem capacity and host
profile, with operator overrides in /etc/nftban/conf.d/logs.conf. The generated
logrotate file (/etc/logrotate.d/nftban) is derived state — do not edit it.
EOF
}

_nftban_logs_retention() {
    local action="${1:-status}"; shift || true
    local core_bin; core_bin="$(_nftban_logs_core_bin)"
    case "$action" in
        status)
            if [[ ! -x "$core_bin" ]]; then
                echo "ERROR: nftban-core not found at $core_bin" >&2
                return 1
            fi
            "$core_bin" logretention status "$@"
            ;;
        help|--help|-h)
            echo "Usage: nftban logs retention status [--json]"
            ;;
        *)
            echo "Unknown 'logs retention' action: $action" >&2
            echo "Usage: nftban logs retention status [--json]" >&2
            return 2
            ;;
    esac
}

nftban_cmd_logs() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        retention)
            _nftban_logs_retention "$@"
            ;;
        help|--help|-h|"")
            _nftban_logs_help
            ;;
        *)
            echo "Unknown 'logs' subcommand: $sub" >&2
            _nftban_logs_help
            return 2
            ;;
    esac
}
