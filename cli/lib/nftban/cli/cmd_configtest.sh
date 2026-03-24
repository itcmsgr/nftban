#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.4 - ConfigTest Command (Alias for config test)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI alias for config test - validates configuration against schema
#
# meta:name="cmd_configtest"
# meta:type="cli"
# meta:header="ConfigTest Command (config test Alias)"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI alias for configuration validation - checks config against schema"
# meta:input="Command line arguments (--json, --verbose)"
# meta:output="Configuration validation results"
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
[[ -n "${CMD_CONFIGTEST_LOADED:-}" ]] && return 0
readonly CMD_CONFIGTEST_LOADED=1

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

cmd_configtest_help() {
    echo "Usage: nftban configtest [options]"
    echo ""
    echo "Alias for 'nftban config test' - validates configuration against schema"
    echo ""
    echo "Options passed to config test subcommand."
    echo "Run 'nftban config test --help' for details."
}

nftban_cmd_configtest() {
    # ConfigTest command - alias for config test
    # Delegates all arguments to nftban_cmd_config_test
    case "${1:-}" in
        -h|--help|help) cmd_configtest_help; return 0 ;;
    esac
    nftban_cmd_config_test "$@"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_configtest

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_configtest "$@"
fi
