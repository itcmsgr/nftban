#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="env" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Central environment variable defaults for all NFTBan scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,NFTBAN_CACHE_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

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
        source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
    fi
    # v1.19.0: Source .local override (user customizations survive package updates)
    # v1.19.26: Also check -r (readable) to prevent crash when running as nftban user
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]] && [[ -r "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" || true
    fi
    export NFTBAN_CONFIG_LOADED="true"
fi
