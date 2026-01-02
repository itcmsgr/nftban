#!/usr/bin/env bash
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

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
# NFTBan v1.0.0 - RBL CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for RBL (Real-time Blackhole List) monitoring
#
# meta:name=cmd_rbl
# meta:type=cli
# meta:header=RBL CLI Handler
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-12-31
# meta:updated_date=2025-12-31
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
  check       Check specific IP(s) against RBL servers
  server      Check full server (all IPs + hostname)
  status      Show RBL monitoring status
  list        List configured RBL providers
  enable      Enable scheduled RBL checks
  disable     Disable scheduled RBL checks
  cache       Manage RBL cache
  alert       Test alert system
  critical    Manage critical IPs (mail, web, panel servers)

CHECK OPTIONS:
  --ip IP           Check specific IP address
  --fresh           Ignore cache, force fresh check
  --json            Output in JSON format
  --verbose         Show all results (including clean)
  --quiet           Minimal output (for cron)
  --alert           Send alert email if listings found

CACHE OPTIONS:
  purge             Purge all cache files
  purge --ip IP     Purge cache for specific IP
  show              Show cache statistics

CRITICAL IPS OPTIONS:
  list              Show configured critical IPs
  add IP TAG        Add critical IP (tag: mail, web, panel)
  remove IP         Remove critical IP

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

CONFIGURATION:
  /etc/nftban/conf.d/rbl/main.conf     Main configuration
  /etc/nftban/conf.d/rbl/rbls.conf     RBL providers list
  /etc/nftban/conf.d/rbl/custom.conf   Custom enable/disable

CACHE LOCATION:
  /var/log/nftban/rbl/{IP}.cache       Cached results per IP

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

nftban_cmd_rbl_check() {
    # Check IPs against RBL servers
    # Options: --ip, --fresh, --json, --verbose, --quiet, --alert

    local ip=""
    local fresh=0
    local format="text"
    local verbose=0
    local quiet=0
    local alert=0

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
            # Perform fresh check
            local results
            results=$(nftban_rbl_check_ip "$check_ip" "$format")

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
    # Check full server: all IPs (IPv4 + IPv6) + hostname
    # Subcommands: check
    # Options: --fresh, --json, --verbose, --quiet, --alert

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
        ((ipv4_count++))
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
            ((ipv6_count++))
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
            # Perform fresh check
            local results
            results=$(nftban_rbl_check_ip "$check_ip" "$format")

            # Cache results
            echo "$results" | nftban_rbl_cache_set "$check_ip"

            # Output results
            echo "$results"

            # Track statistics
            if echo "$results" | grep -q "LISTED"; then
                any_listed=1
                ((total_listed++))

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
                ((total_clean++))
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
        ((count++))
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

    # Check if timer exists
    if ! systemctl list-unit-files | grep -q "nftban-rbl-check.timer"; then
        echo "Error: nftban-rbl-check.timer not found" >&2
        echo "Please install nftban RBL systemd units first" >&2
        return 1
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

    local subcmd="${1:-list}"
    shift || true

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"

    case "$subcmd" in
        list)
            echo "Critical IPs for RBL Monitoring"
            echo "─────────────────────────────────────────────────────────"

            # Get current value from config
            local current_ips=""
            if [[ -f "$config_file" ]]; then
                current_ips=$(grep -E "^NFTBAN_RBL_CRITICAL_IPS=" "$config_file" 2>/dev/null | cut -d'"' -f2 || echo "")
            fi

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
                ((count++))

                local severity
                severity=$(nftban_rbl_get_severity "$tag" 2>/dev/null || echo "medium")

                printf "  %d. %-20s  tag: %-10s  severity: %s\n" "$count" "$ip" "$tag" "$severity"
            done

            echo ""
            echo "─────────────────────────────────────────────────────────"
            echo "Total: $count critical IP(s)"
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

            # Get current value
            local current_ips=""
            if [[ -f "$config_file" ]]; then
                current_ips=$(grep -E "^NFTBAN_RBL_CRITICAL_IPS=" "$config_file" 2>/dev/null | cut -d'"' -f2 || echo "")
            fi

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

            # Update config file
            if grep -q "^NFTBAN_RBL_CRITICAL_IPS=" "$config_file" 2>/dev/null; then
                sed -i "s|^NFTBAN_RBL_CRITICAL_IPS=.*|NFTBAN_RBL_CRITICAL_IPS=\"$new_ips\"|" "$config_file"
            else
                echo "" >> "$config_file"
                echo "NFTBAN_RBL_CRITICAL_IPS=\"$new_ips\"" >> "$config_file"
            fi

            local severity
            severity=$(nftban_rbl_get_severity "$tag" 2>/dev/null || echo "medium")

            echo "✅ Added critical IP: $ip (tag: $tag, severity: $severity)"
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

            # Get current value
            local current_ips=""
            if [[ -f "$config_file" ]]; then
                current_ips=$(grep -E "^NFTBAN_RBL_CRITICAL_IPS=" "$config_file" 2>/dev/null | cut -d'"' -f2 || echo "")
            fi

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

            # Update config file
            sed -i "s|^NFTBAN_RBL_CRITICAL_IPS=.*|NFTBAN_RBL_CRITICAL_IPS=\"$new_ips\"|" "$config_file"

            echo "✅ Removed critical IP: $ip"
            ;;

        *)
            echo "Error: Unknown critical subcommand: $subcmd" >&2
            echo "Available: list, add, remove" >&2
            return 1
            ;;
    esac
}

# Export main function
export -f nftban_cmd_rbl
