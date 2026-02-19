#!/usr/bin/env bash

# =============================================================================

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
# NFTBan v1.0.0 - Services CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle services status CLI commands
#
# meta:name="cmd_services"
# meta:type="cli"
# meta:header="Services CLI Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for system services status reporting"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Strict mode
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

# Load services report core module if not already loaded
if [[ ! $(type -t nftban_report_services) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_report_services.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_report_services.sh"
    else
        echo "ERROR: nftban_report_services.sh not found at ${LIB_DIR}/core" >&2
        exit 1
    fi
fi

# Load output module for rendering
if [[ ! $(type -t nftban_render_banner) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_output.sh"
    fi
fi

# =============================================================================

# SERVICES COMMAND HANDLER
# =============================================================================


nftban_cmd_services() {
    # Handle services subcommands
    # Args: $@ = services subcommand and arguments

    local subcmd="${1:-status}"
    local json_mode=false

    # Check for --json flag in arguments
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    shift || true

    case "$subcmd" in
        status|list|detailed|"")
            # Show services status (terminal output - default detailed)
            # "list" is backwards compatible alias for "status"

            if [[ "$json_mode" == "true" ]]; then
                nftban_report_services "json"
            else
                # Show standard banner
                nftban_banner
                nftban_report_services "table"
            fi
            return $?
            ;;

        summary)
            # Show one-line summary
            nftban_report_services "summary"
            return $?
            ;;

        json|--json)
            # Show JSON output (backward compatibility)
            nftban_report_services "json"
            return $?
            ;;

        compact)
            # DEPRECATED: Use 'summary' instead
            nftban_report_services "summary"
            return $?
            ;;

        fix|start)
            # Auto-start stopped services
            nftban_services_fix
            return $?
            ;;

        check)
            # Check services and return exit code
            nftban_services_check_health
            return $?
            ;;

        help|--help|-h)
            nftban_services_show_help
            return 0
            ;;

        *)
            echo "ERROR: Unknown services subcommand: $subcmd" >&2
            echo "Run 'nftban services help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# SERVICE MANAGEMENT FUNCTIONS
# =============================================================================


#
# nftban_services_fix - Auto-start stopped services
#
nftban_services_fix() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Auto-Starting Services"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    # Scan services first
    nftban_services_scan

    local fixed=0
    local failed=0

    # Try to start nftables
    if [[ -n "${NFTBAN_SERVICE_STATUS[nftables]:-}" ]]; then
        local info="${NFTBAN_SERVICE_STATUS[nftables]}"
        local status="${info%%|*}"

        if [[ "$status" != "RUNNING" ]]; then
            echo "Starting nftables service..."
            if systemctl start nftables.service 2>/dev/null; then
                echo "  ✅ nftables started successfully"
                fixed=$((fixed + 1))
            else
                echo "  ❌ Failed to start nftables"
                failed=$((failed + 1))
            fi
        else
            echo "✅ nftables already running"
        fi
    fi

    # v2.1: fail2ban removed - use native login monitoring instead
    # NFTBan now handles intrusion prevention directly

    echo ""
    echo "Summary: ${fixed} started, ${failed} failed"
    echo ""

    return 0
}

#
# nftban_services_check_health - Check services health (return code)
#
nftban_services_check_health() {
    # Scan services
    nftban_services_scan

    local issues=0

    # Check critical services (v2.1: only nftables required, fail2ban removed)
    for service_name in "nftables"; do
        if [[ -n "${NFTBAN_SERVICE_STATUS[$service_name]:-}" ]]; then
            local info="${NFTBAN_SERVICE_STATUS[$service_name]}"
            local status="${info%%|*}"

            if [[ "$status" != "RUNNING" ]]; then
                echo "⚠ $service_name is not running" >&2
                issues=$((issues + 1))
            fi
        else
            echo "❌ $service_name not found" >&2
            issues=$((issues + 1))
        fi
    done

    if [[ $issues -eq 0 ]]; then
        echo "✅ All critical services are running"
        return 0
    else
        echo "❌ $issues service issues detected"
        return 1
    fi
}

#
# nftban_services_show_help - Show help message
#
nftban_services_show_help() {
    nftban_banner "services" 2>/dev/null || echo "NFTBan v1.0.0"
    echo ""
    echo "USAGE:"
    echo "    nftban services <command>"
    echo ""
    echo "COMMANDS:"
    echo "    [detailed]          Show all services status (default, FHS-style table)"
    echo "    summary             Show one-line summary"
    echo "    json                Show JSON output"
    echo "    fix                 Auto-start stopped services"
    echo "    check               Check services health (returns exit code)"
    echo "    help                Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "    nftban services                     # Show services status (FHS-style table)"
    echo "    nftban services summary             # Output: 'Services: 2/2 running, 4/4 tools'"
    echo "    nftban services json | jq .         # JSON output for parsing"
    echo "    nftban services fix                 # Start stopped services"
    echo "    nftban services check && echo OK    # Health check with exit code"
    echo ""
    echo "SERVICES MONITORED:"
    echo "    • nftables         Netfilter firewall (required)"
    echo "    • nftband          NFTBan daemon for IPC (recommended)"
    echo "    • golang           GeoIP features (optional)"
    echo "    • mailx            Email notifications (optional)"
    echo "    • curl             Feed downloads (required)"
    echo "    • jq               JSON processing (optional)"
    echo ""
    echo "NOTE: fail2ban removed in v2.1 - use native login monitoring instead"
    echo ""
}

# Export main function
export -f nftban_cmd_services
