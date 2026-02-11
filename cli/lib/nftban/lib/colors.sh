#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="colors" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Shared terminal color definitions for consistent output"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_COLORS_LOADED:-}" ]] && return 0
_NFTBAN_COLORS_LOADED=1

# Terminal colors (only if stdout is a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[0;37m'
    BOLD='\033[1m'
    NC='\033[0m'  # No Color / Reset
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    BOLD=''
    NC=''
fi

# Export for subshells
export RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD NC
