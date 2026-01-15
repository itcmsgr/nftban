#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Environment Loader
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="env"
# meta:type="library"
# meta:header="Environment Loader"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Central environment variable defaults for all NFTBan scripts"
# meta:input="None (sourced by other scripts)"
# meta:output="Exports NFTBAN_* environment variables with defaults"
# meta:depends="bash"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,NFTBAN_CACHE_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-01-15"
# =============================================================================
#
# PURPOSE:
# This is the SINGLE SOURCE OF TRUTH for NFTBan environment defaults.
# Source this file FIRST in any script that may run independently.
#
# USAGE:
#   source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh"
#
# =============================================================================

set -Eeuo pipefail

# Guard: prevent double-loading
[[ -n "${NFTBAN_ENV_LOADED:-}" ]] && return 0
NFTBAN_ENV_LOADED="true"

# =============================================================================
# CORE PATHS - Single source of truth for all NFTBan scripts
# =============================================================================
# These defaults match install/config/nftban.conf
# Config files can override these after this file is sourced

export NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
export NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
export NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"
export NFTBAN_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}"
export NFTBAN_DATA_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}"

# =============================================================================
# LOAD CONFIG (if not already loaded by main CLI)
# =============================================================================
# Only load config if the main nftban script hasn't already done it
# This allows scripts to run independently while still getting config values

if [[ -z "${NFTBAN_CONFIG_LOADED:-}" ]]; then
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/nftban.conf"
        export NFTBAN_CONFIG_LOADED="true"
    fi
fi
