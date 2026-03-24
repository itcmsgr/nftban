#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Check Functions Library (Loader)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Load all health check function modules
#
# meta:name="nftban_health_checks"
# meta:type="lib"
# meta:header="Health Check Functions"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Loader for health check functions (split for maintainability)"
# meta:input="System state and configuration"
# meta:output="Health status codes and issue reports"
#
# **Inventory & Requirements**
# meta:depends="nftban_health.sh"
# meta:inventory.files="nftban_health_checks_*.sh"
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2026-01-09"
# meta:updated_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_LOADED=1

# =============================================================================
# MODULE LOADER
# =============================================================================
# Health check functions are split into separate files for maintainability:
#
# nftban_health_checks_core.sh        - Helpers, binaries, paths, permissions, resources, fhs
# nftban_health_checks_security.sh    - nftables_security, firewalls, protection, polkit, ssh
# nftban_health_checks_services.sh    - daemon, suricata, services, timers
# nftban_health_checks_modules.sh     - modules, geoip, geoban, databases, rbl
# nftban_health_checks_config.sh      - config, registry, v030_helpers, bash_completion, cli_errors
# nftban_health_checks_integrations.sh - metrics, zabbix, connectors, pro, gui
# =============================================================================

# Determine library directory
_HEALTH_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core"

# Load all health check modules
_health_modules=(
    "nftban_health_checks_core.sh"
    "nftban_health_checks_security.sh"
    "nftban_health_checks_services.sh"
    "nftban_health_checks_modules.sh"
    "nftban_health_checks_config.sh"
    "nftban_health_checks_integrations.sh"
)

for _module in "${_health_modules[@]}"; do
    _module_path="${_HEALTH_LIB_DIR}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck source=/dev/null
        source "$_module_path" || {
            echo "ERROR: Failed to load health module: $_module" >&2
            return 1
        }
    else
        echo "WARNING: Health module not found: $_module_path" >&2
    fi
done

# Cleanup temporary variables
unset _HEALTH_LIB_DIR _health_modules _module _module_path
