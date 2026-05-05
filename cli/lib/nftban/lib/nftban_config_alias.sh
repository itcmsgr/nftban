#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_config_alias" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Generic canonical/alias key resolver for already-sourced shell variables (Strategy C; canonical wins on conflict; warn-only)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Module guard
[[ -n "${NFTBAN_CONFIG_ALIAS_LOADED:-}" ]] && return 0
readonly NFTBAN_CONFIG_ALIAS_LOADED=1

# =============================================================================
# nftban_config_alias_env — read canonical OR alias from already-sourced env
# =============================================================================
# Resolves a canonical/alias key pair against the current shell environment
# (variables previously sourced via `source <conf>`). Implements Strategy C
# from PR-C3: canonical wins on conflict, alias is read when canonical is
# unset, warning emitted to stderr (one line) when both are set with
# conflicting values.
#
# Args:
#   $1 = canonical variable name (e.g. DDOS_ENABLED)
#   $2 = alias variable name     (e.g. NFTBAN_DDOS_ENABLED)
#   $3 = optional fallback value when neither is set (default: empty)
#
# Output (stdout):
#   - canonical value if set and non-empty
#   - else alias value if set and non-empty
#   - else $3 fallback
#
# Side effects:
#   - one-line WARN to stderr when both are non-empty and differ
#   - never fatal; never mutates either variable; never writes to disk
nftban_config_alias_env() {
    local canonical_name="$1"
    local alias_name="$2"
    local fallback="${3-}"

    local canonical_val="${!canonical_name-}"
    local alias_val="${!alias_name-}"

    if [[ -n "$canonical_val" && -n "$alias_val" && "$canonical_val" != "$alias_val" ]]; then
        printf 'WARN nftban_config_alias: both %s=%q and %s=%q set with conflicting values; using %s (canonical)\n' \
            "$canonical_name" "$canonical_val" "$alias_name" "$alias_val" "$canonical_name" >&2
    fi

    if [[ -n "$canonical_val" ]]; then
        printf '%s' "$canonical_val"
    elif [[ -n "$alias_val" ]]; then
        printf '%s' "$alias_val"
    else
        printf '%s' "$fallback"
    fi
}
