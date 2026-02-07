#!/usr/bin/env bash
# =============================================================================
# NFTBan - Logging Module (DEPRECATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
#
# DEPRECATION NOTICE:
# This module is deprecated and will be removed in a future release.
# Please update your scripts to source nftban_logger.sh instead:
#   source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/helpers/nftban_logger.sh"
#
# This shim sources nftban_logger.sh which provides backward-compatible
# aliases for: log_info, log_warn, log_error, log_debug, log_success
#
# meta:name="nftban_logging"
# meta:type="helper"
# meta:description="DEPRECATED: Shim that sources nftban_logger.sh for compatibility"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LOG_VERBOSE, NFTBAN_LOG_TIMESTAMP, DEBUG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_LOGGING_LOADED:-}" ]] && return 0
_NFTBAN_LOGGING_LOADED=1

# Source the canonical logging module (nftban_logger.sh)
# This provides all the log_* compatibility aliases
_NFTBAN_LOGGING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_NFTBAN_LOGGING_SCRIPT_DIR}/nftban_logger.sh"
