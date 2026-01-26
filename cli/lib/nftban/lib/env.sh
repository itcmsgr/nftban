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
#
# NOTE: Use parameter expansion with guards to avoid readonly variable conflicts
# when nftban.conf has already been sourced (it declares these as readonly)

# Only set if not already defined (avoids readonly conflict)
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && export NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && export NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_LOG_DIR:-}" ]] && export NFTBAN_LOG_DIR="/var/log/nftban"
[[ -z "${NFTBAN_CACHE_DIR:-}" ]] && export NFTBAN_CACHE_DIR="/var/cache/nftban"
[[ -z "${NFTBAN_DATA_DIR:-}" ]] && export NFTBAN_DATA_DIR="/var/lib/nftban"

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
