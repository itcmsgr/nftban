#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_logging"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="DEPRECATED: Shim that sources nftban_logger.sh for compatibility"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_LOGGING_LOADED:-}" ]] && return 0
readonly _NFTBAN_LOGGING_LOADED=1

# Source the canonical logging module (nftban_logger.sh)
# This provides all the log_* compatibility aliases
_NFTBAN_LOGGING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_NFTBAN_LOGGING_SCRIPT_DIR}/nftban_logger.sh"
