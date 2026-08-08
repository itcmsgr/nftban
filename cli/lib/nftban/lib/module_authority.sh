#!/usr/bin/env bash
# =============================================================================
# NFTBan - module enablement authority (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="module_authority"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="THE single answer to 'is module X enabled?'. Before v1.228.7 that question had at least four different answers depending on the code path: the module loader read main.conf then main.conf.local; the firewall rebuild's DDoS re-apply gate read main.conf.local ONLY (a host declaring DDOS_ENABLED=true in main.conf silently lost DDoS on every rebuild); PortScan's gate read .local then fell back to main.conf but could not express main=true+local=false; and stale generated fragments on disk acted as de-facto policy wherever they were re-applied without any config check (measured: dns1 enforcing 4 DDoS chains for months with effective config false). Every lifecycle consumer must ask THIS function and nothing else. Fragment presence is NEVER authority."
# meta:inventory.files="/etc/nftban/conf.d/<module>/main.conf, main.conf.local"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/*/main.conf,conf.d/*/main.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
# =============================================================================

# Guard against double-sourcing.
[[ -n "${_NFTBAN_MODULE_AUTHORITY_LOADED:-}" ]] && return 0
_NFTBAN_MODULE_AUTHORITY_LOADED=1

# The per-module enablement variable. Modules are not uniform, so the mapping
# is EXPLICIT — an unknown module is an error, never a guessed variable name.
_nftban_module_enable_var() {
    case "$1" in
        ddos)     echo "DDOS_ENABLED" ;;
        portscan) echo "PORTSCAN_ENABLED" ;;
        botguard) echo "HTTP_BOTGUARD_ENABLED" ;;
        geoban)   echo "GEOBAN_ENABLED" ;;
        feeds)    echo "FEEDS_ENABLED" ;;
        *)        return 1 ;;
    esac
}

# _nftban_module_read_key <file> <KEY> — echo the last bare value of KEY="..."
# in <file>, or nothing. grep only; never sources (config is data, not code).
_nftban_module_read_key() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -oP "^[[:space:]]*${key}=\"?\K[^\"]+" "$file" 2>/dev/null | tail -1
}

# nftban_module_effective_enabled <module> [KEY]
# Returns 0 iff the module is EFFECTIVELY enabled, resolved exactly as the
# production loader resolves it: base value from main.conf, then main.conf.local
# OVERRIDES iff it assigns the key. An explicit false in .local turns off a true
# in the base (the case the old gates could not express). Missing files resolve
# to disabled — absence of configuration is absence of enablement, never an
# error. Fragment presence on disk is deliberately NOT consulted.
#
# KEY is optional: omit it to use the canonical variable for <module>; pass it
# for the two-argument form kept for existing call sites.
nftban_module_effective_enabled() {
    local module="$1" key="${2:-}"
    if [[ -z "$key" ]]; then
        key="$(_nftban_module_enable_var "$module")" || {
            echo "nftban_module_effective_enabled: unknown module '$module'" >&2
            return 2
        }
    fi
    local base="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}/main.conf"
    local val="false" v

    v="$(_nftban_module_read_key "$base" "$key")"
    [[ -n "$v" ]] && val="$v"
    v="$(_nftban_module_read_key "${base}.local" "$key")"
    [[ -n "$v" ]] && val="$v"

    [[ "$val" == "true" ]]
}

export -f _nftban_module_enable_var _nftban_module_read_key nftban_module_effective_enabled
