#!/usr/bin/env bash
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_DATA_DIR:-}" ]] && readonly NFTBAN_DATA_DIR="/var/lib/nftban"
[[ -z "${NFTBAN_CACHE_DIR:-}" ]] && readonly NFTBAN_CACHE_DIR="/var/cache/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" || return 1
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load timestamp library for consistent date formatting
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# NFTBan v1.7.0 - GeoBan CLI Handler
# =============================================================================
#
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for country-based IP blocking (wrapper for geoip)
#
# meta:name="cmd_geoban"
# meta:type="cli"
# meta:header="GeoBan CLI Handler"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for country-based IP blocking (GeoBan)"
# meta:input="Command line arguments (enable, disable, ban, unban, list, status)"
# meta:output="GeoBan management output"
# meta:depends="bash,nftban_geoban.sh,nftban_prereq.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/geoban/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-06"
# meta:updated_date="2026-01-28"
# =============================================================================


# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_GEOBAN_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_GEOBAN_LOADED=1

# =============================================================================

# MAIN CLI HANDLER
# =============================================================================


nftban_cmd_geoban() {
    # Main GeoBan command handler - wraps geoip commands
    # Args: subcommand [options]
    #
    # This provides a user-friendly alias:
    #   nftban geoban ban CN    ->  nftban geoban ban CN
    #   nftban geoban whitelist US  ->  nftban geoban whitelist US

    local subcommand="${1:-help}"

    # Check if --json flag is present - skip banner for JSON output
    local json_mode="false"
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    # Show banner (skip for JSON output)
    if [[ "$json_mode" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    # Load geoip command handler
    if ! declare -f nftban_cmd_geoip >/dev/null 2>&1; then
        source /usr/lib/nftban/cli/cmd_geoip.sh || {
            echo "ERROR: Failed to load geoip command handler" >&2
            return 1
        }
    fi

    # Map geoban subcommands to geoip subcommands
    case "$subcommand" in
        stats)
            # Stats command for scripts/API - provides JSON output
            nftban_geoban_stats "$@"
            ;;
        test)
            # Test geoban configuration and connectivity
            nftban_geoban_test "$@"
            ;;
        config)
            # Show GeoBan configuration
            nftban_geoban_config "$@"
            ;;
        enable)
            # Enable GeoBan module (persists to .local file)
            nftban_geoban_enable
            ;;
        disable)
            # Disable GeoBan module (persists to .local file)
            nftban_geoban_disable
            ;;
        ban|unban|whitelist|unwhitelist|list|update|status|refresh)
            # Pass directly to geoip handler
            nftban_cmd_geoip "$@"
            ;;
        help|-h|--help)
            nftban_geoban_help
            ;;
        *)
            echo "ERROR: Unknown geoban command: $subcommand" >&2
            nftban_geoban_help
            return 1
            ;;
    esac
}

# =============================================================================
# ENABLE/DISABLE FUNCTIONS (persist to .local file)
# =============================================================================

nftban_geoban_enable() {
    # Enable GeoBan module by writing to .local config file
    # This follows the standard pattern: base.conf + base.conf.local for overrides

    # Check prerequisites (nftban-core binary required for GeoBan)
    if declare -F nftban_prereq_check_geoban >/dev/null 2>&1; then
        nftban_prereq_check_geoban
        if ! nftban_prereq_satisfied; then
            nftban_prereq_report
            return 1
        fi
    fi

    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf.local"

    # Ensure directory exists
    mkdir -p "$(dirname "$config_local")" 2>/dev/null || return 1

    # Source atomic file ops if not already loaded
    if ! declare -F nftban_atomic_write >/dev/null 2>&1; then
        # shellcheck source=../core/nftban_file_ops.sh
        source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" 2>/dev/null || true
    fi

    # Build content atomically: update existing key or create new file
    local content
    if [[ -f "$config_local" ]] && grep -q "^GEOBAN_ENABLED=" "$config_local"; then
        content=$(sed 's/^GEOBAN_ENABLED=.*/GEOBAN_ENABLED="true"/' "$config_local")
    elif [[ -f "$config_local" ]]; then
        content=$(cat "$config_local")
        content="${content}"$'\n'"GEOBAN_ENABLED=\"true\""
    else
        content="# GeoBan local overrides (user-managed)
# Generated by: nftban geoban enable
# Date: $(if declare -F nftban_timestamp >/dev/null 2>&1; then nftban_timestamp; else date -u +%Y-%m-%dT%H:%M:%SZ; fi)

GEOBAN_ENABLED=\"true\""
    fi

    if declare -F nftban_atomic_write >/dev/null 2>&1; then
        echo "$content" | nftban_atomic_write "$config_local"
    else
        echo "$content" > "$config_local"
        chmod 640 "$config_local" 2>/dev/null || true
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    echo "✓ GeoBan module ENABLED"
    echo ""
    echo "Configuration saved to: $config_local"
    echo ""
    echo "Next steps:"
    echo "  nftban geoban ban CN RU    # Block countries"
    echo "  nftban geoban list         # List active blocks"
    echo "  nftban geoban status       # Check module status"
}

nftban_geoban_disable() {
    # Disable GeoBan module by writing to .local config file
    # This follows the standard pattern: base.conf + base.conf.local for overrides

    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf.local"

    # Ensure directory exists
    mkdir -p "$(dirname "$config_local")" 2>/dev/null || return 1

    # Source atomic file ops if not already loaded
    if ! declare -F nftban_atomic_write >/dev/null 2>&1; then
        # shellcheck source=../core/nftban_file_ops.sh
        source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" 2>/dev/null || true
    fi

    # Build content atomically: update existing key or create new file
    local content
    if [[ -f "$config_local" ]] && grep -q "^GEOBAN_ENABLED=" "$config_local"; then
        content=$(sed 's/^GEOBAN_ENABLED=.*/GEOBAN_ENABLED="false"/' "$config_local")
    elif [[ -f "$config_local" ]]; then
        content=$(cat "$config_local")
        content="${content}"$'\n'"GEOBAN_ENABLED=\"false\""
    else
        content="# GeoBan local overrides (user-managed)
# Generated by: nftban geoban disable
# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)

GEOBAN_ENABLED=\"false\""
    fi

    if declare -F nftban_atomic_write >/dev/null 2>&1; then
        echo "$content" | nftban_atomic_write "$config_local"
    else
        echo "$content" > "$config_local"
        chmod 640 "$config_local" 2>/dev/null || true
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    echo "✓ GeoBan module DISABLED"
    echo ""
    echo "Configuration saved to: $config_local"
    echo ""
    echo "Note: Existing country bans remain in configuration but are not applied."
    echo "To re-enable: nftban geoban enable"
}

# =============================================================================
# STATS FUNCTION (for scripts/API)
# =============================================================================

nftban_geoban_stats() {
    local json_mode="false"

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    # Get banned countries from geoban.d directory
    local banned_countries=()
    local whitelisted_countries=()
    local total_blocked_ips=0

    # Read banned countries
    local geoban_dir="${NFTBAN_CONFIG_DIR}/geoban.d"
    if [[ -d "$geoban_dir" ]]; then
        # Use glob safely - check if files exist
        shopt -s nullglob 2>/dev/null || true
        for file in "$geoban_dir"/*.conf; do
            [[ -f "$file" ]] || continue
            local cc
            cc=$(basename "$file" .conf)
            # Check if it's a ban or whitelist
            if grep -q "^MODE=.*ban" "$file" 2>/dev/null; then
                banned_countries+=("$cc")
                # Count IPs in the country file
                local ip_file="${NFTBAN_CACHE_DIR}/geoban/${cc}.txt"
                if [[ -f "$ip_file" ]]; then
                    local count
                    count=$(wc -l < "$ip_file" 2>/dev/null) || count=0
                    total_blocked_ips=$((total_blocked_ips + count))
                fi
            elif grep -q "^MODE=.*whitelist" "$file" 2>/dev/null; then
                whitelisted_countries+=("$cc")
            fi
        done
        shopt -u nullglob 2>/dev/null || true
    fi

    local banned_count=${#banned_countries[@]}
    local whitelisted_count=${#whitelisted_countries[@]}

    # Check if geoip database is available
    local geoip_enabled="false"
    local db_path
    db_path=$(cmd_get_geoip_database 2>/dev/null) || db_path=""
    [[ -n "$db_path" ]] && [[ -f "$db_path" ]] && geoip_enabled="true"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local banned_json="["
        local first=true
        for cc in "${banned_countries[@]}"; do
            [[ "$first" == "false" ]] && banned_json+=","
            banned_json+="\"$cc\""
            first=false
        done
        banned_json+="]"

        local whitelist_json="["
        first=true
        for cc in "${whitelisted_countries[@]}"; do
            [[ "$first" == "false" ]] && whitelist_json+=","
            whitelist_json+="\"$cc\""
            first=false
        done
        whitelist_json+="]"

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --argjson banned_count "$banned_count" \
                --argjson whitelisted_count "$whitelisted_count" \
                --argjson total_blocked_ips "$total_blocked_ips" \
                --argjson geoip_enabled "$geoip_enabled" \
                --argjson banned_countries "$banned_json" \
                --argjson whitelisted_countries "$whitelist_json" \
                '{
                    geoban: {
                        enabled: $geoip_enabled,
                        banned_countries: $banned_count,
                        whitelisted_countries: $whitelisted_count,
                        total_blocked_ips: $total_blocked_ips,
                        countries_banned: $banned_countries,
                        countries_whitelisted: $whitelisted_countries
                    }
                }')
        else
            data="{\"geoban\":{\"enabled\":$geoip_enabled,\"banned_countries\":$banned_count,\"whitelisted_countries\":$whitelisted_count,\"total_blocked_ips\":$total_blocked_ips,\"countries_banned\":$banned_json,\"countries_whitelisted\":$whitelist_json}}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "GeoBan Statistics"
    echo "================="
    echo ""
    echo "  GeoIP Enabled:      $geoip_enabled"
    echo "  Banned Countries:   $banned_count"
    echo "  Whitelisted:        $whitelisted_count"
    echo "  Total Blocked IPs:  $total_blocked_ips"
    echo ""
    if [[ $banned_count -gt 0 ]]; then
        echo "  Countries Banned:   ${banned_countries[*]}"
    fi
    if [[ $whitelisted_count -gt 0 ]]; then
        echo "  Countries Allowed:  ${whitelisted_countries[*]}"
    fi
}

# =============================================================================
# CONFIG FUNCTION
# =============================================================================

nftban_geoban_config() {
    # Display GeoBan configuration settings
    # Args: json_mode (optional) - if "true", output JSON format
    local json_mode="${1:-false}"

    # Check for --json flag in arguments
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf"
    local config_local="${config_file}.local"
    local geoban_dir="${NFTBAN_CONFIG_DIR}/geoban.d"
    local cache_dir="${NFTBAN_CACHE_DIR}/geoban"

    # Source config file if it exists to get current values
    # shellcheck source=/dev/null
    source "$config_file" 2>/dev/null || true
    # shellcheck source=/dev/null
    _source_local "$config_local"

    # Count configured countries
    local banned_count=0
    local whitelisted_count=0
    if [[ -d "$geoban_dir" ]]; then
        shopt -s nullglob 2>/dev/null || true
        for file in "$geoban_dir"/*.conf; do
            [[ -f "$file" ]] || continue
            if grep -q "^MODE=.*ban" "$file" 2>/dev/null; then
                ((banned_count++)) || true
            elif grep -q "^MODE=.*whitelist" "$file" 2>/dev/null; then
                ((whitelisted_count++)) || true
            fi
        done
        shopt -u nullglob 2>/dev/null || true
    fi

    # Calculate cache size
    local cache_size="0"
    if [[ -d "$cache_dir" ]]; then
        cache_size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1) || cache_size="0"
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${GEOBAN_ENABLED:-true}" \
                --arg atomic "${GEOBAN_ATOMIC:-true}" \
                --arg default_policy "${GEOBAN_DEFAULT_POLICY:-allow}" \
                --arg logging "${GEOBAN_LOGGING:-true}" \
                --arg log_blocks "${GEOBAN_LOG_BLOCKS:-false}" \
                --arg geoban_dir "$geoban_dir" \
                --arg cache_dir "$cache_dir" \
                --arg cache_size "$cache_size" \
                --argjson banned_count "$banned_count" \
                --argjson whitelisted_count "$whitelisted_count" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "true"),
                        atomic: ($atomic == "true"),
                        default_policy: $default_policy,
                        logging: ($logging == "true"),
                        log_blocks: ($log_blocks == "true")
                    },
                    paths: {
                        geoban_dir: $geoban_dir,
                        cache_dir: $cache_dir,
                        cache_size: $cache_size
                    },
                    countries: {
                        banned: $banned_count,
                        whitelisted: $whitelisted_count
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\",\"enabled\":${GEOBAN_ENABLED:-true}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "GeoBan Configuration"
    echo "===================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Module Settings:"
    echo "  Enabled:        ${GEOBAN_ENABLED:-true}"
    echo "  Atomic Mode:    ${GEOBAN_ATOMIC:-true}"
    echo "  Default Policy: ${GEOBAN_DEFAULT_POLICY:-allow}"
    echo ""
    echo "Logging Settings:"
    echo "  Logging:        ${GEOBAN_LOGGING:-true}"
    echo "  Log Blocks:     ${GEOBAN_LOG_BLOCKS:-false}"
    echo ""
    echo "Paths:"
    echo "  Country Files:  $geoban_dir"
    echo "  Cache Dir:      $cache_dir"
    echo "  Cache Size:     $cache_size"
    echo ""
    echo "Countries:"
    echo "  Banned:         $banned_count"
    echo "  Whitelisted:    $whitelisted_count"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

# =============================================================================
# TEST FUNCTION
# =============================================================================

nftban_geoban_test() {
    # Test GeoBan module configuration and connectivity
    local json_mode="false"
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    echo "GeoBan Module Test"
    echo "=================="
    echo ""

    local errors=0

    # Test 1: Check config directory
    local config_dir="${NFTBAN_CONFIG_DIR}/conf.d/geoban"
    if [[ -d "$config_dir" ]] || [[ -f "${config_dir}/main.conf" ]]; then
        echo "  [PASS] Config directory exists"
    else
        echo "  [WARN] Config directory not found: $config_dir"
    fi

    # Test 2: Check nftban-core binary (Go implementation)
    local core_bin="${NFTBAN_LIB_DIR}/bin/nftban-core"
    if [[ -x "$core_bin" ]]; then
        echo "  [PASS] nftban-core binary found"
    else
        echo "  [FAIL] nftban-core binary not found: $core_bin"
        ((errors++)) || true
    fi

    # Test 3: Check cache directory
    local cache_dir="${NFTBAN_CACHE_DIR}/geoban"
    if [[ -d "$cache_dir" ]]; then
        echo "  [PASS] Cache directory exists"
    else
        echo "  [INFO] Cache directory will be created on first use"
    fi

    # Test 4: Check network connectivity to RIR
    if curl -s --max-time 5 --head "https://ftp.ripe.net" &>/dev/null; then
        echo "  [PASS] Network connectivity to RIRs OK"
    else
        echo "  [WARN] Cannot reach RIPE NCC (network issue?)"
    fi

    # Test 5: Check nftables
    if command -v nft &>/dev/null; then
        echo "  [PASS] nftables available"
    else
        echo "  [FAIL] nftables not found"
        ((errors++)) || true
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
# HELP
# =============================================================================


nftban_geoban_help() {
    cat <<'EOF'
GeoBan Country Blocking

Usage:
  nftban geoban enable                     # Enable GeoBan module
  nftban geoban disable                    # Disable GeoBan module
  nftban geoban ban <CC> [CC...]           # Ban country traffic
  nftban geoban unban <CC> [CC...]         # Remove country ban
  nftban geoban whitelist <CC> [CC...]     # Whitelist country (allow)
  nftban geoban unwhitelist <CC> [CC...]   # Remove country whitelist
  nftban geoban list                       # List active country blocks
  nftban geoban status                     # Show GeoBan status
  nftban geoban update                     # Update all active countries
  nftban geoban refresh                    # Refresh country IP data from RIRs
  nftban geoban config                     # Show GeoBan configuration
  nftban geoban stats                      # Show GeoBan statistics
  nftban geoban test                       # Test GeoBan config/connectivity
  nftban geoban help                       # Show this help

Country Codes:
  Use ISO 3166-1 alpha-2 codes (2 letters, uppercase)
  Examples: CN (China), RU (Russia), US (United States), GB (United Kingdom)

Examples:
  nftban geoban ban CN RU              # Block China and Russia
  nftban geoban whitelist US GB        # Allow USA and UK
  nftban geoban list                   # Show active blocks
  nftban geoban unban CN               # Remove China block
  nftban geoban status                 # Check GeoBan status

Features:
  • Atomic Operations: Zero-downtime updates via netlink
  • RIR Data Sources: ARIN, RIPE, APNIC, LACNIC, AFRINIC
  • ETag Caching: Reduces bandwidth and API rate limits
  • CIDR Merging: Optimizes memory footprint
  • Safety Limits: CPU/RAM monitoring prevents system overload

Notes:
  • GeoBan uses the nftban-geoip Go binary for performance
  • Changes are applied atomically to running firewall
  • Country IP lists are stored in /var/lib/nftban/geoip/
  • Configuration files stored in /etc/nftban/geoban.d/

EOF
}

# Export the main function
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "geoban"

export -f nftban_cmd_geoban
export -f nftban_geoban_enable
export -f nftban_geoban_disable
export -f nftban_geoban_stats
export -f nftban_geoban_config
export -f nftban_geoban_test
export -f nftban_geoban_help
