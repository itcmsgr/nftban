#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.4 - ConfigAudit Command (Alias for config audit)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI alias for config audit - delegates to config audit subcommand
#
# meta:name="cmd_configaudit"
# meta:type="cli"
# meta:header="ConfigAudit Command (config audit Alias)"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI alias for configuration audit - checks for drift, deprecated keys, new options"
# meta:input="Command line arguments (--json, --verbose)"
# meta:output="Configuration audit results"
# meta:depends="bash,cmd_config.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Guard against multiple sourcing
[[ -n "${CMD_CONFIGAUDIT_LOADED:-}" ]] && return 0
readonly CMD_CONFIGAUDIT_LOADED=1

# Determine library directory
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Source the config handler
CONFIG_HANDLER="${NFTBAN_LIB_DIR}/cli/cmd_config.sh"
if [[ -f "$CONFIG_HANDLER" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_HANDLER" || return 1
else
    echo "ERROR: Config handler not found: $CONFIG_HANDLER" >&2
    return 1
fi

# =============================================================================
# COMMAND HANDLER
# =============================================================================

cmd_configaudit_help() {
    echo "Usage: nftban configaudit [options]"
    echo ""
    echo "Alias for 'nftban config audit' - checks for drift, deprecated keys, new options"
    echo ""
    echo "Options passed to config audit subcommand."
    echo "Run 'nftban config audit --help' for details."
}

nftban_cmd_configaudit() {
    # ConfigAudit command - alias for config audit
    # Delegates all arguments to nftban_cmd_config_audit
    case "${1:-}" in
        -h|--help|help) cmd_configaudit_help; return 0 ;;
    esac
    nftban_cmd_config_audit "$@"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_configaudit

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_configaudit "$@"
fi
