#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.1.0 - Cloudflare Core Module (DEPRECATED)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# DEPRECATED: This module has been replaced by the unified Trust module.
#             Use nftban_trust.sh instead.
#
# This file provides backward-compatible function stubs that delegate to
# the trust module. Kept for compatibility with any external scripts.
#
# meta:name="nftban_cloudflare"
# meta:type="module"
# meta:header="Cloudflare Integration Module (DEPRECATED)"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:deprecated="true"
# meta:replacement="nftban_trust.sh"
#
# meta:description="Backward-compatible stubs delegating to trust module"
# meta:input="Function calls from legacy scripts"
# meta:output="Delegates to nftban_trust.sh equivalents"
# meta:depends="bash,nftban_trust.sh"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-15"
#
# meta:inventory.files="nftban_trust.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Module guard - prevent double-loading
[[ -n "${NFTBAN_CLOUDFLARE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLOUDFLARE_LOADED=1

# Load the trust module which handles all the actual work
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh"
fi

# =============================================================================
# DEPRECATED FUNCTION STUBS
# =============================================================================
# These functions delegate to the trust module for backward compatibility
# =============================================================================

nftban_cloudflare_banner() {
    nftban_trust_banner
}

nftban_cloudflare_init() {
    nftban_trust_init
}

nftban_cloudflare_download_ips() {
    _trust_download_provider "CLOUDFLARE"
}

nftban_cloudflare_write_to_whitelist() {
    _trust_write_whitelist "CLOUDFLARE"
}

nftban_cloudflare_clear_whitelist() {
    _trust_clear_whitelist "CLOUDFLARE"
}

nftban_cloudflare_enable() {
    nftban_trust_enable "CLOUDFLARE"
}

nftban_cloudflare_disable() {
    nftban_trust_disable "CLOUDFLARE"
}

nftban_cloudflare_update() {
    nftban_trust_update "CLOUDFLARE"
}

nftban_cloudflare_status() {
    nftban_trust_status "CLOUDFLARE"
}

nftban_cloudflare_auto_update() {
    # Only update if TRUST_CLOUDFLARE_ENABLED is true
    if [[ "${TRUST_CLOUDFLARE_ENABLED:-false}" == "true" ]]; then
        nftban_trust_update "CLOUDFLARE"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS (for backward compatibility)
# =============================================================================
export -f nftban_cloudflare_banner
export -f nftban_cloudflare_init
export -f nftban_cloudflare_download_ips
export -f nftban_cloudflare_write_to_whitelist
export -f nftban_cloudflare_clear_whitelist
export -f nftban_cloudflare_enable
export -f nftban_cloudflare_disable
export -f nftban_cloudflare_update
export -f nftban_cloudflare_status
export -f nftban_cloudflare_auto_update

# =============================================================================
# END OF DEPRECATED MODULE
# =============================================================================
