#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Config Audit CLI Wrapper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Top-level alias for 'nftban config audit'
#
# meta:name="cmd_configaudit"
# meta:type="cli"
# meta:header="Configuration Audit Wrapper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Audits configuration for drift, deprecated keys, and new options"
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

# Main command handler - routes to config audit
nftban_cmd_configaudit() {
    nftban_cmd_config "audit" "$@"
}

export -f nftban_cmd_configaudit

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_configaudit "$@"
fi
