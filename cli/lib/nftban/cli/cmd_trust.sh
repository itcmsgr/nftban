#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.1.0 - Trust CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI handler for trusted provider IP range management
#
# meta:name="cmd_trust"
# meta:type="cli"
# meta:header="Trust CLI Handler"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for trusted provider IP whitelist management"
# meta:input="User commands (list, enable, disable, update, status)"
# meta:output="Manages trusted provider IP ranges (Cloudflare, AWS, Google, etc.)"
# meta:depends="bash,curl,nftban_trust.sh"
# meta:created_date="2026-01-15"
#
# meta:inventory.files="nftban_trust.sh,nftban_output.sh,strict.sh,version.sh"
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/trust.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="outbound:https (provider APIs)"
# meta:inventory.privileges="root"
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

IFS=$'\n\t'

# =============================================================================
# TRUST COMMAND HANDLER
# =============================================================================

nftban_cmd_trust() {
    # Strip flags (--json, -j) from positional args before parsing
    local -a positional=()
    for arg in "$@"; do
        case "$arg" in
            --json|-j) export NFTBAN_JSON="true" ;;
            *)         positional+=("$arg") ;;
        esac
    done

    local action="${positional[0]:-status}"
    local provider="${positional[1]:-}"

    # Load core trust module
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh" || return 1
    else
        echo "ERROR: Trust module not found" >&2
        exit 1
    fi

    # Check root for state-changing operations
    case "$action" in
        enable|disable|update|load)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                echo "Please run with sudo: sudo nftban trust $action $provider" >&2
                exit 1
            fi
            ;;
    esac

    case "$action" in
        list)
            nftban_trust_list
            ;;
        enable)
            if [[ -z "$provider" ]]; then
                echo "ERROR: Provider name required" >&2
                echo "Usage: nftban trust enable <PROVIDER>" >&2
                echo ""
                echo "Available providers:"
                nftban_trust_list_providers
                exit 1
            fi
            nftban_trust_enable "$provider"
            ;;
        disable)
            if [[ -z "$provider" ]]; then
                echo "ERROR: Provider name required" >&2
                echo "Usage: nftban trust disable <PROVIDER>" >&2
                exit 1
            fi
            nftban_trust_disable "$provider"
            ;;
        update)
            if [[ -n "$provider" ]]; then
                nftban_trust_update "$provider"
            else
                nftban_trust_update_all
            fi
            ;;
        load)
            nftban_trust_load
            ;;
        status)
            if [[ -n "$provider" ]]; then
                nftban_trust_status "$provider"
            else
                nftban_trust_status_all
            fi
            ;;
        config)
            _nftban_trust_config
            ;;
        stats)
            _nftban_trust_stats
            ;;
        test)
            _nftban_trust_test
            ;;
        help|--help|-h)
            _nftban_trust_help
            ;;
        *)
            echo "ERROR: Unknown trust action: $action" >&2
            echo ""
            _nftban_trust_help
            exit 1
            ;;
    esac
}

# =============================================================================
# CONFIG / STATS / TEST SUBCOMMANDS (v1.29.0)
# =============================================================================

_nftban_trust_config() {
    # Show trust module configuration
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/trust.conf"
    local config_local="${config_file}.local"

    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        if command -v jq &>/dev/null; then
            jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${TRUST_ENABLED:-true}" \
                --arg auto_update "${TRUST_AUTO_UPDATE:-true}" \
                --arg update_interval "${TRUST_AUTO_UPDATE_INTERVAL:-24}" \
                --arg cache_dir "${TRUST_CACHE_DIR:-/var/cache/nftban/trust}" \
                --arg log_file "${TRUST_LOG_FILE:-/var/log/nftban/trust.log}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "true"),
                        auto_update: ($auto_update == "true"),
                        update_interval_hours: ($update_interval | tonumber),
                        cache_dir: $cache_dir,
                        log_file: $log_file
                    }
                }'
        else
            printf '{"config_file":"%s","enabled":"%s"}\n' "$config_file" "${TRUST_ENABLED:-true}"
        fi
        return 0
    fi

    echo "Trust Module Configuration"
    echo "=========================="
    echo ""
    echo "  Config File:      $config_file"
    echo "  Override File:    $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:           [Override Active]"
    else
        echo "  Status:           [Using defaults]"
    fi
    echo ""
    echo "Settings:"
    echo "  Module Enabled:   ${TRUST_ENABLED:-true}"
    echo "  Auto-Update:      ${TRUST_AUTO_UPDATE:-true}"
    echo "  Update Interval:  ${TRUST_AUTO_UPDATE_INTERVAL:-24} hours"
    echo "  Cache Directory:  ${TRUST_CACHE_DIR:-/var/cache/nftban/trust}"
    echo "  Log File:         ${TRUST_LOG_FILE:-/var/log/nftban/trust.log}"
    echo "  Min Ranges:       ${TRUST_MIN_RANGES:-5}"
    echo "  Max Ranges:       ${TRUST_MAX_RANGES:-50000}"
    echo "  Download Timeout: ${TRUST_DOWNLOAD_TIMEOUT:-60}s"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

_nftban_trust_stats() {
    # Show trust module statistics
    local cache_dir="${TRUST_CACHE_DIR:-/var/cache/nftban/trust}"
    local total_ipv4=0
    local total_ipv6=0
    local enabled_count=0
    local total_providers=0

    # Count providers and ranges
    if declare -f nftban_trust_list_providers &>/dev/null; then
        for provider in "${TRUST_PROVIDER_LIST[@]:-}"; do
            [[ -z "$provider" ]] && continue
            ((total_providers++)) || true
            if _trust_is_enabled "$provider" 2>/dev/null; then
                ((enabled_count++)) || true
                local ipv4_cache ipv6_cache
                ipv4_cache=$(_trust_get_cache_file "$provider" "ipv4" 2>/dev/null || echo "")
                ipv6_cache=$(_trust_get_cache_file "$provider" "ipv6" 2>/dev/null || echo "")
                [[ -f "$ipv4_cache" ]] && total_ipv4=$((total_ipv4 + $(wc -l < "$ipv4_cache")))
                [[ -f "$ipv6_cache" ]] && total_ipv6=$((total_ipv6 + $(wc -l < "$ipv6_cache")))
            fi
        done
    fi

    # Check whitelist files
    local whitelist_count=0
    local whitelist_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d"
    if [[ -d "$whitelist_dir" ]]; then
        whitelist_count=$(find "$whitelist_dir" -name "30-trust-*.conf" 2>/dev/null | wc -l)
    fi

    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        if command -v jq &>/dev/null; then
            jq -n \
                --argjson total_providers "$total_providers" \
                --argjson enabled_count "$enabled_count" \
                --argjson total_ipv4 "$total_ipv4" \
                --argjson total_ipv6 "$total_ipv6" \
                --argjson whitelist_files "$whitelist_count" \
                '{
                    stats: {
                        total_providers: $total_providers,
                        enabled_providers: $enabled_count,
                        total_ipv4_ranges: $total_ipv4,
                        total_ipv6_ranges: $total_ipv6,
                        whitelist_files: $whitelist_files
                    }
                }'
        else
            printf '{"stats":{"enabled":%d,"ipv4":%d,"ipv6":%d}}\n' "$enabled_count" "$total_ipv4" "$total_ipv6"
        fi
        return 0
    fi

    echo "Trust Module Statistics"
    echo "======================"
    echo ""
    echo "  Providers:        $enabled_count / $total_providers enabled"
    echo "  IPv4 Ranges:      $total_ipv4"
    echo "  IPv6 Ranges:      $total_ipv6"
    echo "  Total Ranges:     $((total_ipv4 + total_ipv6))"
    echo "  Whitelist Files:  $whitelist_count"
    echo ""
}

_nftban_trust_test() {
    # Test trust module prerequisites and connectivity
    echo "Trust Module Test"
    echo "================="
    echo ""

    local errors=0

    # Test 1: Config file
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/trust.conf"
    if [[ -f "$config_file" ]]; then
        echo "  [PASS] Config file exists"
    else
        echo "  [FAIL] Config file missing: $config_file"
        ((errors++)) || true
    fi

    # Test 2: curl available
    if command -v curl &>/dev/null; then
        echo "  [PASS] curl available"
    else
        echo "  [FAIL] curl not available (required for provider downloads)"
        ((errors++)) || true
    fi

    # Test 3: Cache directory writable
    local cache_dir="${TRUST_CACHE_DIR:-/var/cache/nftban/trust}"
    if [[ -d "$cache_dir" ]] && [[ -w "$cache_dir" ]]; then
        echo "  [PASS] Cache directory writable: $cache_dir"
    elif [[ -d "$cache_dir" ]]; then
        echo "  [WARN] Cache directory not writable: $cache_dir"
    else
        echo "  [WARN] Cache directory missing: $cache_dir (will be created on first use)"
    fi

    # Test 4: Provider list loaded
    local provider_count=0
    if [[ -n "${TRUST_PROVIDER_LIST[*]:-}" ]]; then
        provider_count=${#TRUST_PROVIDER_LIST[@]}
    fi
    if [[ $provider_count -gt 0 ]]; then
        echo "  [PASS] $provider_count providers registered"
    else
        echo "  [FAIL] No providers registered"
        ((errors++)) || true
    fi

    # Test 5: Connectivity (try Cloudflare as canary)
    if curl -sf --max-time 5 "https://www.cloudflare.com/ips-v4" &>/dev/null; then
        echo "  [PASS] Internet connectivity (Cloudflare reachable)"
    else
        echo "  [WARN] Cannot reach Cloudflare — downloads may fail"
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        echo "All tests passed!"
        return 0
    else
        echo "Tests completed with $errors error(s)"
        return 1
    fi
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_trust_help() {
    # Load output module for standard banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi

    cat <<'HELP'

USAGE:
    nftban trust <command> [provider] [--json]

OPTIONS:
    --json, -j      Output in JSON format (machine-readable)

COMMANDS:
    list                List all available trusted providers
                        Shows enabled/disabled status for each

    enable <PROVIDER>   Enable a trusted provider
                        - Downloads provider IP ranges
                        - Adds to system whitelist
                        - Applies to nftables

    disable <PROVIDER>  Disable a trusted provider
                        - Removes from whitelist
                        - Removes from nftables

    update [PROVIDER]   Update IP ranges
                        - If PROVIDER specified, updates only that provider
                        - If omitted, updates all enabled providers

    load                Reload all enabled providers from disk
                        - Re-applies whitelist without downloading

    status [PROVIDER]   Show status
                        - If PROVIDER specified, shows detailed status
                        - If omitted, shows summary of all providers

    config              Show trust module configuration
    stats               Show trust module statistics
    test                Test prerequisites and connectivity
    help                Show this help message

SUPPORTED PROVIDERS:
    CLOUDFLARE          Cloudflare CDN/Proxy IP ranges
    QUICCLOUD           QUIC.cloud / LiteSpeed CDN IP ranges
    AWS                 Amazon Web Services IP ranges
    GOOGLE              Google Cloud Platform IP ranges
    AZURE               Microsoft Azure IP ranges
    DIGITALOCEAN        DigitalOcean IP ranges
    FASTLY              Fastly CDN IP ranges

EXAMPLES:
    # List all providers
    nftban trust list

    # Enable Cloudflare
    sudo nftban trust enable CLOUDFLARE

    # Enable AWS
    sudo nftban trust enable AWS

    # Check status
    nftban trust status

    # Update all enabled providers
    sudo nftban trust update

    # Update only Cloudflare
    sudo nftban trust update CLOUDFLARE

    # Disable Google Cloud
    sudo nftban trust disable GOOGLE

CONFIGURATION:
    Config file: /etc/nftban/conf.d/trust.conf
    User overrides: /etc/nftban/nftban.conf.local

    Key settings:
      TRUST_CLOUDFLARE_ENABLED="true|false"
      TRUST_AWS_ENABLED="true|false"
      TRUST_AUTO_UPDATE="true|false"

WHY USE TRUSTED PROVIDERS?
    If you use CDN/cloud services:
    - Traffic comes from provider IPs, not real client IPs
    - Need to whitelist them to avoid blocking legitimate traffic
    - Providers update their IP ranges periodically
    - Auto-update keeps your whitelist current

FILES:
    Cache: /var/cache/nftban/trust/
    Whitelist: /etc/nftban/whitelist.d/30-trust-*.conf
    Logs: ${NFTBAN_LOG_DIR}/trust.log

NOTES:
    - Auto-update checks for new ranges daily (configurable)
    - Provider IPs change occasionally
    - IPv4 and IPv6 support (where available)
    - Cloudflare is also accessible via: nftban cloudflare

For more information:
    https://docs.nftban.com/modules/trust

HELP
}

# =============================================================================
# EXPORT FUNCTION
# =============================================================================

export -f nftban_cmd_trust
export -f _nftban_trust_help
export -f _nftban_trust_config
export -f _nftban_trust_stats
export -f _nftban_trust_test

# =============================================================================
# END OF CLI HANDLER
# =============================================================================
