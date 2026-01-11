#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Config Test CLI Wrapper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Top-level alias for 'nftban config test'
#
# meta:name="cmd_configtest"
# meta:type="cli"
# meta:header="Configuration Validation Wrapper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Validates configuration against schema"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load the config command module
if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_config.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/cli/cmd_config.sh"
else
    echo "ERROR: Configuration module not found"
    exit 1
fi

# Main command handler - routes to config test
nftban_cmd_configtest() {
    nftban_cmd_config "test" "$@"
}

export -f nftban_cmd_configtest

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_configtest "$@"
fi
