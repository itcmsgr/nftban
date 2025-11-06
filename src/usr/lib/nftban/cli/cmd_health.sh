#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.0 - Health Check CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for system health checks and diagnostics
#
# meta:name=cmd_health
# meta:type=cli
# meta:header=Health Check CLI Handler
# meta:version=0.32.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-11-05
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_HEALTH_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_HEALTH_LOADED=1

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_health() {
    # Main health command handler
    # Args: subcommand [options]

    local subcommand="${1:-}"

    if [[ -z "$subcommand" ]]; then
        nftban_health_cmd_help
        return 1
    fi

    # Shift to get remaining args
    shift

    case "$subcommand" in
        check|detailed|"")
            # Default detailed health check (full terminal output)
            nftban_health_cmd_check "$@"
            ;;
        summary)
            # One-line summary
            nftban_health_cmd_summary "$@"
            ;;
        json)
            # JSON output
            nftban_health_cmd_json "$@"
            ;;
        report)
            nftban_health_cmd_report "$@"
            ;;
        fix)
            nftban_health_cmd_fix "$@"
            ;;
        services)
            nftban_health_cmd_services "$@"
            ;;
        modules)
            nftban_health_cmd_modules "$@"
            ;;
        binaries)
            nftban_health_cmd_binaries "$@"
            ;;
        permissions)
            nftban_health_cmd_permissions "$@"
            ;;
        geoip)
            nftban_health_cmd_geoip "$@"
            ;;
        help|--help|-h)
            nftban_health_cmd_help
            ;;
        *)
            echo "ERROR: Unknown health command: $subcommand" >&2
            echo "Run 'nftban health help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND IMPLEMENTATIONS
# =============================================================================

nftban_health_cmd_check() {
    # Run comprehensive health check
    # Args: [--auto-heal] [--quiet]

    local auto_heal=0
    local quiet=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-heal)
                auto_heal=1
                shift
                ;;
            --quiet)
                quiet=1
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Usage: nftban health check [--auto-heal] [--quiet]" >&2
                return 1
                ;;
        esac
    done

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    if [[ $quiet -eq 0 ]]; then
        echo "Running NFTBan system health check..."
        [[ $auto_heal -eq 1 ]] && echo "Auto-heal: ENABLED"
        echo ""
    fi

    # Run all checks (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_all $auto_heal || result=$?

    # Render results (unless quiet)
    if [[ $quiet -eq 0 ]]; then
        nftban_health_render_terminal
    else
        # In quiet mode, only show summary if there are issues
        if [[ $result -gt 0 ]]; then
            nftban_health_render_summary
        fi
    fi

    return $result
}

nftban_health_cmd_summary() {
    # Run health check and show one-line summary
    # Args: none

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    # Run all checks (capture result)
    local result=0
    nftban_health_check_all >/dev/null 2>&1 || result=$?

    # Render summary
    nftban_health_render_summary

    return $result
}

nftban_health_cmd_json() {
    # Run health check and output JSON
    # Args: none

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    # Run all checks (capture result)
    local result=0
    nftban_health_check_all >/dev/null 2>&1 || result=$?

    # Render JSON
    nftban_health_render_json

    return $result
}

nftban_health_cmd_report() {
    # Generate health check report
    # Args: $1 = format (optional: terminal|html|json)

    local format="${1:-terminal}"

    # Load health module
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    # Run checks (ignore return value to avoid strict mode issues)
    nftban_health_check_all || true

    case "$format" in
        terminal)
            nftban_health_render_terminal
            ;;
        html)
            echo "HTML report generation not yet implemented" >&2
            echo "Use 'nftban health check' for terminal output" >&2
            return 1
            ;;
        json)
            echo "JSON report generation not yet implemented" >&2
            echo "Use 'nftban health check' for terminal output" >&2
            return 1
            ;;
        *)
            echo "ERROR: Invalid format: $format" >&2
            echo "Valid formats: terminal, html, json" >&2
            return 1
            ;;
    esac
}

nftban_health_cmd_fix() {
    # Auto-fix common issues
    # Args: $1 = what to fix (optional: permissions|directories|services|all)

    local what="${1:-all}"

    # Load health module
    if ! declare -f nftban_health_fix_permissions >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Health Fix"
    echo "================="
    echo ""

    # Show privilege level
    if [[ $EUID -eq 0 ]]; then
        echo "Running as: root (can fix everything)"
    else
        echo "Running as: $(whoami) (can fix owned files, will report what needs root)"
    fi
    echo ""

    case "$what" in
        permissions)
            nftban_health_fix_permissions
            ;;
        directories)
            nftban_health_fix_directories
            ;;
        services)
            nftban_health_fix_services
            ;;
        config|system)
            nftban_health_fix_system_config
            ;;
        all)
            nftban_health_fix_directories
            nftban_health_fix_permissions
            nftban_health_fix_system_config
            nftban_health_fix_services
            ;;
        *)
            echo "ERROR: Invalid fix target: $what" >&2
            echo "Valid targets: permissions, directories, services, config, all" >&2
            return 1
            ;;
    esac

    echo ""
    echo "✓ Fix complete!"
    echo ""
    echo "Run 'nftban health check' to verify"
    return 0
}

nftban_health_cmd_services() {
    # Check systemd services status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_services >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Services Status"
    echo "======================"
    echo ""

    nftban_health_init

    # Check services (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_services || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All services: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Services: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[services]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[services]}"
        fi
    else
        echo "❌ Services: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[services]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[services]}"
        fi
    fi

    echo ""
    return $result
}

nftban_health_cmd_modules() {
    # Check loaded modules
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_modules >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Modules Status"
    echo "====================="
    echo ""

    nftban_health_init

    # Check modules (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_modules || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All modules: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Modules: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[modules]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[modules]}"
        fi
    else
        echo "❌ Modules: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[modules]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[modules]}"
        fi
    fi

    echo ""
    return $result
}

nftban_health_cmd_binaries() {
    # Check required binaries
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_binaries >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Binaries Status"
    echo "======================"
    echo ""

    nftban_health_init

    # Check binaries (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_binaries || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All binaries: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Binaries: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[binaries]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[binaries]}"
        fi
    else
        echo "❌ Binaries: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[binaries]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[binaries]}"
        fi
    fi

    echo ""
    return $result
}

nftban_health_cmd_permissions() {
    # Check file permissions
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_permissions >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Permissions Status"
    echo "========================="
    echo ""

    nftban_health_init

    # Check permissions (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_permissions || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ Permissions: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Permissions: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[permissions]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[permissions]}"
        fi
    else
        echo "❌ Permissions: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[permissions]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[permissions]}"
        fi
    fi

    echo ""
    return $result
}

nftban_health_cmd_geoip() {
    # Check GeoIP system status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_geoip >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_health.sh || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan GeoIP System Status"
    echo "=========================="
    echo ""

    nftban_health_init

    # Check GeoIP (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_geoip || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ GeoIP system: OK"

        # Show additional details if available
        local binary_path="/usr/lib/nftban/bin/nftban-geoip"
        local db_path="/var/lib/nftban/geoip/GeoLite2-City.mmdb"

        if [[ -x "$binary_path" ]]; then
            local version
            version=$("$binary_path" version 2>/dev/null || echo "unknown")
            echo "  Binary: $binary_path"
            echo "  Version: $version"
        fi

        if [[ -f "$db_path" ]]; then
            local db_size
            db_size=$(du -h "$db_path" | cut -f1)
            echo "  Database: $db_path"
            echo "  Size: $db_size"
        fi

        # Performance test
        if [[ -x "$binary_path" && -f "$db_path" ]]; then
            echo ""
            echo "  Performance test (8.8.8.8):"
            local start_time end_time elapsed
            start_time=$(date +%s%N)
            "$binary_path" lookup 8.8.8.8 >/dev/null 2>&1
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000 ))
            echo "  Lookup time: ${elapsed} microseconds"
        fi
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  GeoIP system: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[geoip]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[geoip]}"
        fi
    else
        echo "❌ GeoIP system: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[geoip]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[geoip]}"
        fi
    fi

    echo ""
    return $result
}

nftban_health_cmd_help() {
    # Show help text

    nftban_render_banner simple
    echo ""

    cat << 'EOF'
nftban health - System health check and diagnostics

USAGE:
    nftban health <command> [options]

COMMANDS:
    check [--auto-heal] [--quiet]
                            Run comprehensive health check (default)
                            Full terminal output with all checks
                            --auto-heal: Automatically fix detected issues (requires root)
                            --quiet: Minimal output (for cron/timer use)

    summary                 Show one-line summary
                            Output: "Health: OK" or "Health: WARNING (2 warnings)"

    json                    Output JSON format
                            Machine-readable health data

    report [format]         Generate health report (deprecated - use json)
                            Formats: terminal (default), html, json

    fix [target]            Auto-fix common issues (requires root)
                            Targets: permissions, directories, services, all

    services                Check systemd services status (DEPRECATED)
                            Use: nftban services

    modules                 Check loaded modules (DEPRECATED)
                            Use: nftban module

    binaries                Check required binaries
                            Verifies nft, systemctl, jq, curl, etc.

    permissions             Check file permissions (DEPRECATED)
                            Use: nftban fhs

    geoip                   Check GeoIP system status
                            Tests binary, database, performance

    help                    Show this help message

EXAMPLES:
    # Full system health check
    nftban health check
    nftban health              # Same as 'check'

    # Quick summary for scripts
    nftban health summary      # Output: "Health: WARNING (2 warnings)"

    # JSON for dashboards
    nftban health json | jq .

    # Check specific component
    nftban health geoip
    nftban health binaries

    # Auto-heal during check (combines check + fix)
    sudo nftban health check --auto-heal

    # Quiet mode for cron/timer
    nftban health check --auto-heal --quiet

    # Manual fix (traditional approach)
    sudo nftban health fix all
    sudo nftban health fix permissions

    # Generate report
    nftban health report terminal

HEALTH STATUS CODES:
    ✅ OK       - All checks passed
    ⚠️  WARNING - Non-critical issues found
    ❌ ERROR    - Critical issues found

AUTO-FIX CAPABILITIES:
    - Create missing directories
    - Fix file ownership (nftban:nftban)
    - Fix file permissions (755, 750, 644, 640)
    - Restart failed services
    - Fix executable permissions

NOTES:
    - Most commands can run as regular user
    - 'fix' command requires root/sudo privileges
    - Run 'check' after 'fix' to verify repairs
    - Health checks are non-destructive

nftban — Simplifying Linux Firewall Management
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main handler
export -f nftban_cmd_health

# Export subcommand functions
export -f nftban_health_cmd_check
export -f nftban_health_cmd_summary
export -f nftban_health_cmd_json
export -f nftban_health_cmd_report
export -f nftban_health_cmd_fix
export -f nftban_health_cmd_services
export -f nftban_health_cmd_modules
export -f nftban_health_cmd_binaries
export -f nftban_health_cmd_permissions
export -f nftban_health_cmd_geoip
export -f nftban_health_cmd_help
