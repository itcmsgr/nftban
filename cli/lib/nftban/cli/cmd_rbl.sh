#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - RBL CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for RBL (Real-time Blackhole List) monitoring
#
# meta:name="cmd_rbl"
# meta:type="cli"
# meta:header="RBL CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="CLI commands for RBL monitoring and watchlist management"
# meta:created_date="2025-12-31"
# meta:updated_date="2026-01-13"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/rbl/main.conf, /etc/nftban/conf.d/rbl/watchlist.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh"
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# =============================================================================

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_RBL_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_RBL_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load RBL core module
if [[ ! $(type -t nftban_rbl_check_ip) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_rbl.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_rbl.sh"
    else
        echo "ERROR: nftban_rbl.sh not found" >&2
        exit 1
    fi
fi

# Load output module for banner
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
fi

# =============================================================================
# HELP FUNCTIONS
# =============================================================================

nftban_cmd_rbl_help() {
    # Show RBL command help

    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════╗
║         NFTBan v1.0.0 - RBL Monitoring                          ║
╚══════════════════════════════════════════════════════════════════╝

USAGE:
  nftban rbl <subcommand> [options]

SUBCOMMANDS:
  check       Check specific IP(s) against RBL servers (parallel DNS)
  server      Check full server (all IPs + hostname)
  status      Show RBL monitoring status
  list        List configured RBL providers
  enable      Enable scheduled RBL checks
  disable     Disable scheduled RBL checks
  cache       Manage RBL cache
  alert       Test alert system
  critical    Manage critical IPs (mail, web, panel servers)
  watchlist   Monitor external IPs of interest (customers, partners)

CHECK OPTIONS:
  --ip IP           Check specific IP address
  --fresh           Ignore cache, force fresh check
  --json            Output in JSON format
  --verbose         Show all results (including clean)
  --quiet           Minimal output (for cron)
  --alert           Send alert email if listings found
  --sequential      Use sequential DNS (default: parallel)

CACHE OPTIONS:
  purge             Purge all cache files
  purge --ip IP     Purge cache for specific IP
  show              Show cache statistics

CRITICAL IPS OPTIONS:
  list              Show configured critical IPs
  add IP TAG        Add critical IP (tag: mail, web, panel)
  remove IP         Remove critical IP

WATCHLIST OPTIONS:
  list              Show all watched IPs
  add IP [DESC]     Add IP to watchlist with description
  remove IP         Remove IP from watchlist
  check             Check all watched IPs against RBLs
  check --alert     Check watched IPs and send alerts

EXAMPLES:
  # Check full server (all IPs + hostname)
  nftban rbl server check

  # Check full server with fresh results
  nftban rbl server check --fresh

  # Check specific IP
  nftban rbl check --ip 1.2.3.4

  # Check with alert email
  nftban rbl check --alert

  # Show status
  nftban rbl status

  # List RBL providers
  nftban rbl list

  # Enable daily checks
  nftban rbl enable

  # Purge cache
  nftban rbl cache purge

  # Add mail server as critical IP
  nftban rbl critical add 203.0.113.10 mail

  # List critical IPs
  nftban rbl critical list

  # Add customer server to watchlist
  nftban rbl watchlist add 198.51.100.5 "Customer ABC mail server"

  # Check all watched IPs
  nftban rbl watchlist check --alert

CONFIGURATION:
  /etc/nftban/conf.d/rbl/main.conf       Main configuration
  /etc/nftban/conf.d/rbl/main.conf.local User overrides
  /etc/nftban/conf.d/rbl/rbls.conf       RBL providers list
  /etc/nftban/conf.d/rbl/custom.conf     Custom enable/disable
  /etc/nftban/conf.d/rbl/watchlist.conf  Watched IPs

CACHE LOCATION:
  /var/log/nftban/rbl/{IP}.cache       Cached results per IP

PERFORMANCE:
  Parallel DNS queries (default): ~10-15 seconds for 41 RBLs
  Sequential DNS queries: ~2-3 minutes for 41 RBLs

For more information: https://nftban.com/docs/rbl
EOF
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_rbl() {
    # Main RBL command handler
    # Args: subcommand [options]

    local subcommand="${1:-}"

    if [[ -z "$subcommand" ]] || [[ "$subcommand" == "help" ]] || [[ "$subcommand" == "--help" ]]; then
        nftban_cmd_rbl_help
        return 0
    fi

    # Shift to get remaining args
    shift

    case "$subcommand" in
        check)
            nftban_cmd_rbl_check "$@"
            ;;
        server)
            nftban_cmd_rbl_server "$@"
            ;;
        status)
            nftban_cmd_rbl_status "$@"
            ;;
        config)
            nftban_cmd_rbl_config "$@"
            ;;
        stats)
            nftban_cmd_rbl_stats "$@"
            ;;
        test)
            nftban_cmd_rbl_test "$@"
            ;;
        list)
            nftban_cmd_rbl_list "$@"
            ;;
        enable)
            nftban_cmd_rbl_enable "$@"
            ;;
        disable)
            nftban_cmd_rbl_disable "$@"
            ;;
        cache)
            nftban_cmd_rbl_cache "$@"
            ;;
        alert)
            nftban_cmd_rbl_alert "$@"
            ;;
        critical)
            nftban_cmd_rbl_critical "$@"
            ;;
        watchlist)
            nftban_cmd_rbl_watchlist "$@"
            ;;
        *)
            echo "Error: Unknown subcommand: $subcommand" >&2
            echo "Run 'nftban rbl help' for usage" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND IMPLEMENTATIONS
# =============================================================================

# =============================================================================
# CONFIG AND STATS COMMANDS
# =============================================================================

nftban_cmd_rbl_config() {
    # Show RBL configuration
    local format="text"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) format="json"; shift ;;
            *) shift ;;
        esac
    done

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"
    local config_local="${config_file}.local"

    if [[ "$format" == "json" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${NFTBAN_RBL_ENABLED:-YES}" \
                --arg auto_discover "${NFTBAN_RBL_AUTO_DISCOVER_IPS:-YES}" \
                --arg check_ipv6 "${NFTBAN_RBL_CHECK_IPV6:-YES}" \
                --arg cache_ttl "${NFTBAN_RBL_CACHE_TTL:-24}" \
                --arg alert_email "${NFTBAN_RBL_ALERT_EMAIL:-}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "YES"),
                        auto_discover: ($auto_discover == "YES"),
                        check_ipv6: ($check_ipv6 == "YES"),
                        cache_ttl_hours: ($cache_ttl | tonumber),
                        alert_email: $alert_email
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\"}"
        fi
        json_output "true" "$data"
        return 0
    fi

    echo "RBL Configuration"
    echo "================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Settings:"
    echo "  Enabled:        ${NFTBAN_RBL_ENABLED:-YES}"
    echo "  Auto-Discover:  ${NFTBAN_RBL_AUTO_DISCOVER_IPS:-YES}"
    echo "  Check IPv6:     ${NFTBAN_RBL_CHECK_IPV6:-YES}"
    echo "  Cache TTL:      ${NFTBAN_RBL_CACHE_TTL:-24} hours"
    echo "  Alert Email:    ${NFTBAN_RBL_ALERT_EMAIL:-(not set)}"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

nftban_cmd_rbl_stats() {
    # Show RBL statistics
    local format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) format="json"; shift ;;
            *) shift ;;
        esac
    done

    # Count cache entries
    local cache_count=0
    if [[ -d "${NFTBAN_RBL_CACHE_DIR:-/var/log/nftban/rbl}" ]]; then
        cache_count=$(find "${NFTBAN_RBL_CACHE_DIR:-/var/log/nftban/rbl}" -name "*.cache" 2>/dev/null | wc -l)
    fi

    # Get last check time
    local last_check=""
    local last_check_file="${NFTBAN_RBL_CACHE_DIR:-/var/log/nftban/rbl}/last_check"
    if [[ -f "$last_check_file" ]]; then
        last_check=$(cat "$last_check_file" 2>/dev/null || echo "")
    fi

    # Count providers
    local provider_count=0
    provider_count=$(nftban_rbl_load_providers 2>/dev/null | wc -l) || provider_count=0

    if [[ "$format" == "json" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --argjson cache_count "$cache_count" \
                --argjson provider_count "$provider_count" \
                --arg last_check "$last_check" \
                '{
                    stats: {
                        cached_ips: $cache_count,
                        rbl_providers: $provider_count,
                        last_check: (if $last_check == "" then null else $last_check end)
                    }
                }')
        else
            data="{\"stats\":{\"cached_ips\":$cache_count,\"rbl_providers\":$provider_count}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    echo "RBL Statistics"
    echo "=============="
    echo ""
    echo "  Cached IPs:     $cache_count"
    echo "  RBL Providers:  $provider_count"
    echo "  Last Check:     ${last_check:-(never)}"
    echo ""
}

nftban_cmd_rbl_test() {
    # Test RBL module configuration and connectivity
    echo "RBL Module Test"
    echo "==============="
    echo ""

    local errors=0

    # Test 1: Check config file
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"
    if [[ -f "$config_file" ]]; then
        echo "  [PASS] Config file exists"
    else
        echo "  [FAIL] Config file missing: $config_file"
        ((errors++)) || true
    fi

    # Test 2: Check DNS resolution capability
    if command -v dig &>/dev/null || command -v host &>/dev/null || command -v nslookup &>/dev/null; then
        echo "  [PASS] DNS lookup tool available"
    else
        echo "  [FAIL] No DNS lookup tool (dig, host, or nslookup)"
        ((errors++)) || true
    fi

    # Test 3: Test DNS resolution
    if host -W 3 google.com &>/dev/null 2>&1 || dig +short +time=3 google.com &>/dev/null 2>&1; then
        echo "  [PASS] DNS resolution working"
    else
        echo "  [WARN] DNS resolution may have issues"
    fi

    # Test 4: Check RBL providers loaded
    local provider_count
    provider_count=$(nftban_rbl_load_providers 2>/dev/null | wc -l) || provider_count=0
    if [[ $provider_count -gt 0 ]]; then
        echo "  [PASS] $provider_count RBL providers loaded"
    else
        echo "  [FAIL] No RBL providers loaded"
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
# IP CHECK COMMANDS
# =============================================================================

nftban_cmd_rbl_check() {
    # Check IPs against RBL servers (parallel DNS by default)
    # Options: --ip, --fresh, --json, --verbose, --quiet, --alert, --sequential

    local ip=""
    local fresh=0
    local format="text"
    local verbose=0
    local quiet=0
    local alert=0
    local sequential=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)
                ip="$2"
                shift 2
                ;;
            --fresh)
                fresh=1
                shift
                ;;
            --json)
                format="json"
                shift
                ;;
            --verbose)
                verbose=1
                export NFTBAN_RBL_VERBOSE="YES"
                shift
                ;;
            --quiet)
                quiet=1
                shift
                ;;
            --alert)
                alert=1
                shift
                ;;
            --sequential)
                sequential=1
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Get IPs to check
    local ips_to_check=()

    if [[ -n "$ip" ]]; then
        # Check specific IP
        ips_to_check+=("$ip")
    else
        # Auto-discover IPs
        if [[ "${NFTBAN_RBL_AUTO_DISCOVER_IPS:-YES}" == "YES" ]]; then
            while IFS= read -r discovered_ip; do
                ips_to_check+=("$discovered_ip")
            done < <(nftban_rbl_get_public_ips)
        fi

        # Add critical IPs
        while IFS=: read -r critical_ip tag; do
            ips_to_check+=("$critical_ip:$tag")
        done < <(nftban_rbl_get_critical_ips)
    fi

    if [[ ${#ips_to_check[@]} -eq 0 ]]; then
        echo "Error: No IPs to check" >&2
        return 1
    fi

    # Check each IP
    local any_listed=0
    for ip_entry in "${ips_to_check[@]}"; do
        local check_ip="${ip_entry%%:*}"
        local ip_tag="${ip_entry#*:}"
        [[ "$ip_tag" == "$check_ip" ]] && ip_tag=""

        [[ $quiet -eq 0 ]] && echo ""
        [[ $quiet -eq 0 ]] && [[ -n "$ip_tag" ]] && echo "Checking: $check_ip (tag: $ip_tag)"
        [[ $quiet -eq 0 ]] && [[ -z "$ip_tag" ]] && echo "Checking: $check_ip"

        # Check cache if not fresh
        local cache_file
        if [[ $fresh -eq 0 ]] && cache_file=$(nftban_rbl_cache_get "$check_ip"); then
            [[ $quiet -eq 0 ]] && echo "(Using cached results)"
            cat "$cache_file"
        else
            # Perform fresh check (parallel DNS by default)
            local results
            if [[ $sequential -eq 1 ]]; then
                results=$(nftban_rbl_check_ip "$check_ip" "$format")
            else
                results=$(nftban_rbl_check_ip_parallel "$check_ip" "$format")
            fi

            # Cache results
            echo "$results" | nftban_rbl_cache_set "$check_ip"

            # Output results
            echo "$results"

            # Check if listed and send alert if requested
            if [[ $alert -eq 1 ]] && echo "$results" | grep -q "LISTED"; then
                any_listed=1
                # Extract first RBL and reason for alert
                local first_rbl
                local first_reason
                first_rbl=$(echo "$results" | grep "LISTED:" | head -n1 | awk '{print $3}')
                first_reason=$(echo "$results" | grep "Reason:" | head -n1 | sed 's/.*Reason: //')

                if [[ "${NFTBAN_RBL_ALERT_ON_NEW_LISTING:-YES}" == "YES" ]]; then
                    if nftban_rbl_check_new_listing "$check_ip" "listed"; then
                        nftban_rbl_send_alert "$check_ip" "$first_rbl" "$first_reason" "$ip_tag"
                    fi
                fi

                # Update state
                nftban_rbl_update_state "$check_ip" "listed"
            else
                nftban_rbl_update_state "$check_ip" "clean"
            fi
        fi
    done

    # Update last check timestamp
    mkdir -p "${NFTBAN_RBL_CACHE_DIR}"
    date -Iseconds > "${NFTBAN_RBL_CACHE_DIR}/last_check"

    # Return exit code based on listings
    return $any_listed
}

nftban_cmd_rbl_server() {
    # Check full server: all IPs (IPv4 + IPv6) + hostname (parallel DNS by default)
    # Subcommands: check
    # Options: --fresh, --json, --verbose, --quiet, --alert, --sequential

    local subcmd="${1:-check}"
    shift || true

    if [[ "$subcmd" != "check" ]]; then
        echo "Error: Unknown server subcommand: $subcmd" >&2
        echo "Usage: nftban rbl server check [options]" >&2
        return 1
    fi

    local fresh=0
    local format="text"
    local verbose=0
    local quiet=0
    local alert=0
    local sequential=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fresh)
                fresh=1
                shift
                ;;
            --json)
                format="json"
                shift
                ;;
            --verbose)
                verbose=1
                export NFTBAN_RBL_VERBOSE="YES"
                shift
                ;;
            --quiet)
                quiet=1
                shift
                ;;
            --alert)
                alert=1
                shift
                ;;
            --sequential)
                sequential=1
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    [[ $quiet -eq 0 ]] && echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ $quiet -eq 0 ]] && echo "NFTBan RBL Server Check"
    [[ $quiet -eq 0 ]] && echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ $quiet -eq 0 ]] && echo ""

    # Get server hostname
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    [[ $quiet -eq 0 ]] && echo "Server: $hostname"
    [[ $quiet -eq 0 ]] && echo ""

    # Collect all IPs
    local all_ips=()

    # 1. Auto-discovered IPv4
    [[ $quiet -eq 0 ]] && echo "━━━ IPv4 Addresses ━━━"
    local ipv4_count=0
    while IFS= read -r ip; do
        all_ips+=("$ip:ipv4")
        # v1.19.20 FIX
        ((ipv4_count++)) || true
        [[ $quiet -eq 0 ]] && echo "  ✓ $ip"
    done < <(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | sort -u)
    [[ $quiet -eq 0 ]] && [[ $ipv4_count -eq 0 ]] && echo "  (none found)"
    [[ $quiet -eq 0 ]] && echo ""

    # 2. Auto-discovered IPv6 (if enabled)
    if [[ "${NFTBAN_RBL_CHECK_IPV6:-YES}" == "YES" ]]; then
        [[ $quiet -eq 0 ]] && echo "━━━ IPv6 Addresses ━━━"
        local ipv6_count=0
        while IFS= read -r ip; do
            all_ips+=("$ip:ipv6")
            # v1.19.20 FIX
            ((ipv6_count++)) || true
            [[ $quiet -eq 0 ]] && echo "  ✓ $ip"
        done < <(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1' | grep -v '^fe80:' | grep -v '^fc00:' | grep -v '^fd00:' | sort -u)
        [[ $quiet -eq 0 ]] && [[ $ipv6_count -eq 0 ]] && echo "  (none found)"
        [[ $quiet -eq 0 ]] && echo ""
    fi

    # 3. Hostname resolution
    [[ $quiet -eq 0 ]] && echo "━━━ Hostname Resolution ━━━"
    while IFS= read -r ip; do
        all_ips+=("$ip:hostname")
        [[ $quiet -eq 0 ]] && echo "  ✓ $hostname → $ip"
    done < <(host "$hostname" 2>/dev/null | grep "has address" | awk '{print $NF}')
    [[ $quiet -eq 0 ]] && echo ""

    if [[ ${#all_ips[@]} -eq 0 ]]; then
        echo "Error: No IPs found to check" >&2
        return 1
    fi

    [[ $quiet -eq 0 ]] && echo "━━━ RBL Checks ━━━"
    [[ $quiet -eq 0 ]] && echo "Total IPs to check: ${#all_ips[@]}"
    [[ $quiet -eq 0 ]] && echo ""

    # Check each IP
    local any_listed=0
    local total_listed=0
    local total_clean=0

    for ip_entry in "${all_ips[@]}"; do
        local check_ip="${ip_entry%%:*}"
        local ip_source="${ip_entry#*:}"

        # Filter public IPs only
        if ! nftban_rbl_is_public_ip "$check_ip"; then
            [[ $quiet -eq 0 ]] && echo "⚠️  Skipping private IP: $check_ip ($ip_source)"
            continue
        fi

        [[ $quiet -eq 0 ]] && echo "─────────────────────────────────────────────────────────────"
        [[ $quiet -eq 0 ]] && echo "Checking: $check_ip (source: $ip_source)"
        [[ $quiet -eq 0 ]] && echo ""

        # Check cache if not fresh
        local cache_file
        if [[ $fresh -eq 0 ]] && cache_file=$(nftban_rbl_cache_get "$check_ip"); then
            [[ $quiet -eq 0 ]] && echo "(Using cached results)"
            cat "$cache_file"
        else
            # Perform fresh check (parallel DNS by default)
            local results
            if [[ $sequential -eq 1 ]]; then
                results=$(nftban_rbl_check_ip "$check_ip" "$format")
            else
                results=$(nftban_rbl_check_ip_parallel "$check_ip" "$format")
            fi

            # Cache results
            echo "$results" | nftban_rbl_cache_set "$check_ip"

            # Output results
            echo "$results"

            # Track statistics
            if echo "$results" | grep -q "LISTED"; then
                any_listed=1
                # v1.19.20 FIX
                ((total_listed++)) || true

                # Send alert if requested
                if [[ $alert -eq 1 ]] && [[ "${NFTBAN_RBL_ALERT_ON_NEW_LISTING:-YES}" == "YES" ]]; then
                    if nftban_rbl_check_new_listing "$check_ip" "listed"; then
                        local first_rbl
                        local first_reason
                        first_rbl=$(echo "$results" | grep "LISTED:" | head -n1 | awk '{print $3}')
                        first_reason=$(echo "$results" | grep "Reason:" | head -n1 | sed 's/.*Reason: //')
                        nftban_rbl_send_alert "$check_ip" "$first_rbl" "$first_reason" "$ip_source"
                    fi
                fi
                nftban_rbl_update_state "$check_ip" "listed"
            else
                # v1.19.20 FIX
                ((total_clean++)) || true
                nftban_rbl_update_state "$check_ip" "clean"
            fi
        fi

        [[ $quiet -eq 0 ]] && echo ""
    done

    # Final summary
    [[ $quiet -eq 0 ]] && echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ $quiet -eq 0 ]] && echo "Server RBL Check Summary"
    [[ $quiet -eq 0 ]] && echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ $quiet -eq 0 ]] && echo "Server: $hostname"
    [[ $quiet -eq 0 ]] && echo "IPs Checked: ${#all_ips[@]}"
    [[ $quiet -eq 0 ]] && echo "Listed: $total_listed"
    [[ $quiet -eq 0 ]] && echo "Clean: $total_clean"
    [[ $quiet -eq 0 ]] && echo ""

    if [[ $total_listed -gt 0 ]]; then
        [[ $quiet -eq 0 ]] && echo "⚠️  WARNING: Server has $total_listed IP(s) on RBL blacklists!"
    else
        [[ $quiet -eq 0 ]] && echo "✅ All IPs are clean (not blacklisted)"
    fi

    # Update last check timestamp
    mkdir -p "${NFTBAN_RBL_CACHE_DIR}"
    date -Iseconds > "${NFTBAN_RBL_CACHE_DIR}/last_check"

    # Return exit code based on listings
    return $any_listed
}

nftban_cmd_rbl_status() {
    # Show RBL monitoring status
    # Options: --json

    local format="text"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                format="json"
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    nftban_rbl_status "$format"

    # Show .local override file info (text format only)
    if [[ "$format" == "text" ]]; then
        local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"
        echo ""
        echo "  Config File:    $config_file"
        local local_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf.local"
        echo -n "  Override File:  $local_file  "
        if [[ -f "$local_file" ]]; then
            echo "[Active]"
        else
            echo "[Not created]"
        fi
        echo ""
        echo "  Note: Put custom settings in main.conf.local (survives upgrades)"
    fi
}

nftban_cmd_rbl_list() {
    # List configured RBL providers
    # Options: --verbose

    local verbose=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)
                verbose=1
                shift
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    echo "RBL Providers"
    echo "─────────────────────────────────────────────────────────"

    local count=0
    while IFS=: read -r rbl_domain rbl_url; do
        # v1.19.20 FIX
        ((count++)) || true
        if [[ $verbose -eq 1 ]]; then
            echo "$count. $rbl_domain"
            echo "   URL: $rbl_url"
        else
            echo "$count. $rbl_domain"
        fi
    done < <(nftban_rbl_load_providers)

    echo "─────────────────────────────────────────────────────────"
    echo "Total: $count RBL providers"
}

nftban_cmd_rbl_enable() {
    # Enable scheduled RBL checks (systemd timer)

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "Error: Must run as root to enable timer" >&2
        return 1
    fi

    # Check prerequisites (DNS lookup tool required for RBL)
    if declare -F nftban_prereq_check_rbl >/dev/null 2>&1; then
        nftban_prereq_check_rbl
        if ! nftban_prereq_satisfied; then
            nftban_prereq_report
            return 1
        fi
    fi

    # Check if timer exists
    if ! systemctl list-unit-files | grep -q "nftban-rbl-check.timer"; then
        echo "Error: nftban-rbl-check.timer not found" >&2
        echo "Please install nftban RBL systemd units first" >&2
        return 1
    fi

    # Persist to config
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf.local"
    mkdir -p "$(dirname "$local_conf")"
    if grep -q "^NFTBAN_RBL_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^NFTBAN_RBL_ENABLED=.*/NFTBAN_RBL_ENABLED="YES"/' "$local_conf"
    else
        echo 'NFTBAN_RBL_ENABLED="YES"' >> "$local_conf"
    fi

    # Enable and start timer
    systemctl daemon-reload
    systemctl enable nftban-rbl-check.timer
    systemctl start nftban-rbl-check.timer

    echo "✅ RBL monitoring enabled"
    echo ""
    echo "Next run:"
    systemctl status nftban-rbl-check.timer | grep "Trigger:" || echo "  (Check with: systemctl status nftban-rbl-check.timer)"
}

nftban_cmd_rbl_disable() {
    # Disable scheduled RBL checks (systemd timer)

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "Error: Must run as root to disable timer" >&2
        return 1
    fi

    # Persist to config
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf.local"
    mkdir -p "$(dirname "$local_conf")"
    if grep -q "^NFTBAN_RBL_ENABLED=" "$local_conf" 2>/dev/null; then
        sed -i 's/^NFTBAN_RBL_ENABLED=.*/NFTBAN_RBL_ENABLED="NO"/' "$local_conf"
    else
        echo 'NFTBAN_RBL_ENABLED="NO"' >> "$local_conf"
    fi

    # Stop and disable timer
    systemctl stop nftban-rbl-check.timer 2>/dev/null || true
    systemctl disable nftban-rbl-check.timer 2>/dev/null || true

    echo "✅ RBL monitoring disabled"
}

nftban_cmd_rbl_cache() {
    # Manage RBL cache
    # Subcommands: purge, show

    local subcmd="${1:-show}"
    shift || true

    case "$subcmd" in
        purge)
            local ip=""

            # Parse options
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --ip)
                        ip="$2"
                        shift 2
                        ;;
                    *)
                        echo "Error: Unknown option: $1" >&2
                        return 1
                        ;;
                esac
            done

            nftban_rbl_cache_purge "$ip"
            ;;
        show)
            echo "RBL Cache Statistics"
            echo "─────────────────────────────────────────────────────────"
            echo "Cache directory: ${NFTBAN_RBL_CACHE_DIR}"
            echo "Cache TTL: ${NFTBAN_RBL_CACHE_TTL} hours"
            echo ""

            local cache_count
            cache_count=$(find "${NFTBAN_RBL_CACHE_DIR}" -name "*.cache" 2>/dev/null | wc -l)
            echo "Cached IPs: $cache_count"

            if [[ $cache_count -gt 0 ]]; then
                echo ""
                echo "Cache files:"
                find "${NFTBAN_RBL_CACHE_DIR}" -name "*.cache" -exec basename {} \; | \
                    sed 's/.cache$//' | \
                    head -n 20
                [[ $cache_count -gt 20 ]] && echo "... and $((cache_count - 20)) more"
            fi
            ;;
        *)
            echo "Error: Unknown cache subcommand: $subcmd" >&2
            echo "Available: purge, show" >&2
            return 1
            ;;
    esac
}

nftban_cmd_rbl_alert() {
    # Test RBL alert system
    # Options: --ip, --rbl, --reason

    local ip=""
    local rbl="test.rbl.nftban.com"
    local reason="Test alert message"
    local tag="test"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            test)
                # Allow "alert test" syntax
                shift
                ;;
            --ip)
                ip="$2"
                shift 2
                ;;
            --rbl)
                rbl="$2"
                shift 2
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ -z "$ip" ]]; then
        echo "Error: --ip required for test alert" >&2
        return 1
    fi

    echo "Sending test RBL alert..."
    echo "  IP: $ip"
    echo "  RBL: $rbl"
    echo "  Reason: $reason"
    echo "  Email: ${NFTBAN_RBL_ALERT_EMAIL:-not configured}"
    echo ""

    if [[ -z "${NFTBAN_RBL_ALERT_EMAIL:-}" ]]; then
        echo "Error: NFTBAN_RBL_ALERT_EMAIL not configured" >&2
        echo "Set in: /etc/nftban/conf.d/rbl/main.conf" >&2
        return 1
    fi

    nftban_rbl_send_alert "$ip" "$rbl" "$reason" "$tag"

    echo "✅ Test alert sent to: ${NFTBAN_RBL_ALERT_EMAIL}"
}

nftban_cmd_rbl_critical() {
    # Manage critical IPs for RBL monitoring
    # Subcommands: list, add, remove
    # Uses .conf.local override architecture (never modifies package defaults)

    local subcmd="${1:-list}"
    shift || true

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl"
    local main_conf="${config_dir}/main.conf"
    local local_conf="${config_dir}/main.conf.local"

    # Helper: Get current critical IPs (checks .local first, then main)
    _get_critical_ips() {
        local value=""
        # Check .conf.local first (user overrides)
        if [[ -f "$local_conf" ]]; then
            value=$(grep -E "^NFTBAN_RBL_CRITICAL_IPS=" "$local_conf" 2>/dev/null | tail -1 | cut -d'"' -f2)
        fi
        # Fallback to main.conf if not in .local
        if [[ -z "$value" ]] && [[ -f "$main_conf" ]]; then
            value=$(grep -E "^NFTBAN_RBL_CRITICAL_IPS=" "$main_conf" 2>/dev/null | tail -1 | cut -d'"' -f2)
        fi
        echo "$value"
    }

    # Helper: Set critical IPs (always writes to .conf.local)
    _set_critical_ips() {
        local new_value="$1"

        # Create .conf.local if it doesn't exist
        if [[ ! -f "$local_conf" ]]; then
            cat > "$local_conf" << 'EOF'
# =============================================================================
# NFTBan RBL Local Overrides
# =============================================================================
# User customizations - survives package updates
# This file takes precedence over main.conf
# =============================================================================

EOF
        fi

        # Update or add the setting
        if grep -q "^NFTBAN_RBL_CRITICAL_IPS=" "$local_conf" 2>/dev/null; then
            sed -i "s|^NFTBAN_RBL_CRITICAL_IPS=.*|NFTBAN_RBL_CRITICAL_IPS=\"$new_value\"|" "$local_conf"
        else
            echo "NFTBAN_RBL_CRITICAL_IPS=\"$new_value\"" >> "$local_conf"
        fi
    }

    case "$subcmd" in
        list)
            echo "Critical IPs for RBL Monitoring"
            echo "─────────────────────────────────────────────────────────"

            # Get current value using config architecture
            local current_ips
            current_ips=$(_get_critical_ips)

            if [[ -z "$current_ips" ]]; then
                echo "(No critical IPs configured)"
                echo ""
                echo "Add critical IPs with:"
                echo "  nftban rbl critical add <IP> <tag>"
                echo ""
                echo "Tags: mail, web, panel, smtp, dns"
                return 0
            fi

            echo ""
            local count=0
            IFS=',' read -ra ips <<< "$current_ips"
            for entry in "${ips[@]}"; do
                local ip="${entry%%:*}"
                local tag="${entry#*:}"
                [[ "$tag" == "$ip" ]] && tag="default"
                # v1.19.20 FIX
                ((count++)) || true

                local severity
                severity=$(nftban_rbl_get_severity "$tag" 2>/dev/null || echo "medium")

                printf "  %d. %-20s  tag: %-10s  severity: %s\n" "$count" "$ip" "$tag" "$severity"
            done

            echo ""
            echo "─────────────────────────────────────────────────────────"
            echo "Total: $count critical IP(s)"

            # Show config source
            if [[ -f "$local_conf" ]] && grep -q "^NFTBAN_RBL_CRITICAL_IPS=" "$local_conf" 2>/dev/null; then
                echo "Config: ${local_conf}"
            fi
            ;;

        add)
            local ip="${1:-}"
            local tag="${2:-default}"

            if [[ -z "$ip" ]]; then
                echo "Error: IP address required" >&2
                echo "Usage: nftban rbl critical add <IP> [tag]" >&2
                echo "" >&2
                echo "Tags: mail, web, panel, smtp, dns" >&2
                return 1
            fi

            # Validate IP format
            if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
               ! [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                echo "Error: Invalid IP address format: $ip" >&2
                return 1
            fi

            # Check if running as root
            if [[ $EUID -ne 0 ]]; then
                echo "Error: Must run as root to modify configuration" >&2
                return 1
            fi

            # Get current value using config architecture
            local current_ips
            current_ips=$(_get_critical_ips)

            # Check if already exists
            if [[ "$current_ips" == *"$ip:"* ]] || [[ "$current_ips" == *"$ip,"* ]] || [[ "$current_ips" == "$ip" ]]; then
                echo "Warning: IP $ip already in critical list (updating tag)" >&2
                # Remove old entry before adding new one
                current_ips=$(echo "$current_ips" | sed "s/${ip}:[^,]*,*//g" | sed 's/,$//')
            fi

            # Build new value
            local new_ips
            if [[ -z "$current_ips" ]]; then
                new_ips="${ip}:${tag}"
            else
                new_ips="${current_ips},${ip}:${tag}"
            fi

            # Write to .conf.local (never modifies package defaults)
            _set_critical_ips "$new_ips"

            local severity
            severity=$(nftban_rbl_get_severity "$tag" 2>/dev/null || echo "medium")

            echo "✅ Added critical IP: $ip (tag: $tag, severity: $severity)"
            echo "Config: ${local_conf}"
            echo ""
            echo "Run 'nftban rbl check' to check this IP immediately"
            ;;

        remove)
            local ip="${1:-}"

            if [[ -z "$ip" ]]; then
                echo "Error: IP address required" >&2
                echo "Usage: nftban rbl critical remove <IP>" >&2
                return 1
            fi

            # Check if running as root
            if [[ $EUID -ne 0 ]]; then
                echo "Error: Must run as root to modify configuration" >&2
                return 1
            fi

            # Get current value using config architecture
            local current_ips
            current_ips=$(_get_critical_ips)

            if [[ -z "$current_ips" ]]; then
                echo "Error: No critical IPs configured" >&2
                return 1
            fi

            # Check if IP exists
            if ! [[ "$current_ips" == *"$ip:"* ]] && ! [[ "$current_ips" == *"$ip,"* ]] && ! [[ "$current_ips" == "$ip" ]]; then
                echo "Error: IP $ip not found in critical list" >&2
                return 1
            fi

            # Remove IP entry
            local new_ips
            new_ips=$(echo "$current_ips" | sed "s/${ip}:[^,]*,*//g" | sed 's/,$//' | sed 's/^,//')

            # Write to .conf.local (never modifies package defaults)
            _set_critical_ips "$new_ips"

            echo "✅ Removed critical IP: $ip"
            echo "Config: ${local_conf}"
            ;;

        *)
            echo "Error: Unknown critical subcommand: $subcmd" >&2
            echo "Available: list, add, remove" >&2
            return 1
            ;;
    esac
}

nftban_cmd_rbl_watchlist() {
    # Manage watchlist IPs for external RBL monitoring (customers, partners, etc.)
    # Subcommands: list, add, remove, check
    # Uses config-based file architecture

    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list)
            local format="text"

            # Parse options
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --json)
                        format="json"
                        shift
                        ;;
                    *)
                        echo "Error: Unknown option: $1" >&2
                        return 1
                        ;;
                esac
            done

            nftban_rbl_watchlist_list "$format"
            ;;

        add)
            local ip="${1:-}"
            local description="${2:-}"
            local tags="${3:-}"
            local notify_email="${4:-}"

            if [[ -z "$ip" ]]; then
                echo "Error: IP address required" >&2
                echo "Usage: nftban rbl watchlist add <IP> [description] [tags] [notify_email]" >&2
                echo "" >&2
                echo "Tags: customer, partner, mail, web, critical (comma-separated)" >&2
                return 1
            fi

            # Check if running as root
            if [[ $EUID -ne 0 ]]; then
                echo "Error: Must run as root to modify watchlist" >&2
                return 1
            fi

            nftban_rbl_watchlist_add "$ip" "$description" "$tags" "$notify_email"
            ;;

        remove)
            local ip="${1:-}"

            if [[ -z "$ip" ]]; then
                echo "Error: IP address required" >&2
                echo "Usage: nftban rbl watchlist remove <IP>" >&2
                return 1
            fi

            # Check if running as root
            if [[ $EUID -ne 0 ]]; then
                echo "Error: Must run as root to modify watchlist" >&2
                return 1
            fi

            nftban_rbl_watchlist_remove "$ip"
            ;;

        check)
            local alert=0
            local format="text"
            local verbose=0
            local sequential=0

            # Parse options
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --alert)
                        alert=1
                        shift
                        ;;
                    --json)
                        format="json"
                        shift
                        ;;
                    --verbose)
                        verbose=1
                        export NFTBAN_RBL_VERBOSE="YES"
                        shift
                        ;;
                    --sequential)
                        sequential=1
                        shift
                        ;;
                    *)
                        echo "Error: Unknown option: $1" >&2
                        return 1
                        ;;
                esac
            done

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "NFTBan RBL Watchlist Check"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            local total_checked=0
            local total_listed=0
            local total_clean=0

            # Check each watchlist entry
            while IFS='|' read -r ip description tags notify_email; do
                [[ -z "$ip" ]] && continue
                # v1.19.20 FIX
                ((total_checked++)) || true

                echo "─────────────────────────────────────────────────────────────"
                echo "Checking: $ip"
                [[ -n "$description" ]] && echo "Description: $description"
                [[ -n "$tags" ]] && echo "Tags: $tags"
                echo ""

                # Use parallel or sequential DNS
                local results
                if [[ $sequential -eq 1 ]]; then
                    results=$(nftban_rbl_check_ip "$ip" "$format")
                else
                    results=$(nftban_rbl_check_ip_parallel "$ip" "$format")
                fi

                # Cache results
                echo "$results" | nftban_rbl_cache_set "$ip"

                # Output results
                echo "$results"

                # Check if listed
                if echo "$results" | grep -q "LISTED"; then
                    # v1.19.20 FIX
                    ((total_listed++)) || true
                    nftban_rbl_update_state "$ip" "listed"

                    # Send alert if requested
                    if [[ $alert -eq 1 ]]; then
                        local alert_email="${notify_email:-${NFTBAN_RBL_ALERT_EMAIL:-}}"
                        if [[ -n "$alert_email" ]]; then
                            # Extract first RBL and reason for alert
                            local first_rbl
                            local first_reason
                            first_rbl=$(echo "$results" | grep "LISTED:" | head -n1 | awk '{print $3}')
                            first_reason=$(echo "$results" | grep "Reason:" | head -n1 | sed 's/.*Reason: //')

                            if nftban_rbl_check_new_listing "$ip" "listed"; then
                                NFTBAN_RBL_ALERT_EMAIL="$alert_email" \
                                    nftban_rbl_send_alert "$ip" "$first_rbl" "$first_reason" "watchlist"
                            fi
                        fi
                    fi
                else
                    # v1.19.20 FIX
                    ((total_clean++)) || true
                    nftban_rbl_update_state "$ip" "clean"
                fi

                echo ""
            done < <(nftban_rbl_watchlist_get)

            if [[ $total_checked -eq 0 ]]; then
                echo "(No IPs in watchlist)"
                echo ""
                echo "Add IPs with: nftban rbl watchlist add <IP> [description]"
                return 0
            fi

            # Final summary
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Watchlist Check Summary"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "IPs Checked: $total_checked"
            echo "Listed: $total_listed"
            echo "Clean: $total_clean"
            echo ""

            if [[ $total_listed -gt 0 ]]; then
                echo "⚠️  WARNING: $total_listed watchlist IP(s) on RBL blacklists!"
            else
                echo "✅ All watchlist IPs are clean (not blacklisted)"
            fi

            # Return exit code based on listings
            [[ $total_listed -gt 0 ]] && return 1
            return 0
            ;;

        *)
            echo "Error: Unknown watchlist subcommand: $subcmd" >&2
            echo "Available: list, add, remove, check" >&2
            return 1
            ;;
    esac
}

# Export main function and subcommands
export -f nftban_cmd_rbl
export -f nftban_cmd_rbl_alert
export -f nftban_cmd_rbl_cache
export -f nftban_cmd_rbl_check
export -f nftban_cmd_rbl_config
export -f nftban_cmd_rbl_critical
export -f nftban_cmd_rbl_disable
export -f nftban_cmd_rbl_enable
export -f nftban_cmd_rbl_help
export -f nftban_cmd_rbl_list
export -f nftban_cmd_rbl_server
export -f nftban_cmd_rbl_stats
export -f nftban_cmd_rbl_status
export -f nftban_cmd_rbl_test
export -f nftban_cmd_rbl_watchlist
