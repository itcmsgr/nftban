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
# NFTBan v1.0.0 - Health Check CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for system health checks and diagnostics
#
# meta:name="cmd_health"
# meta:type="cli"
# meta:header="Health Check CLI Handler"
# meta:version="1.0.31"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="CLI commands for health checks including registry validation"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-13"
#
# meta:inventory.files=""
# meta:inventory.binaries="python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
# =============================================================================


# Enhanced strict mode
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

    local subcommand="${1:-check}"
    local json_mode=false

    # Check for --json flag in arguments
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    # Shift to get remaining args
    shift || true

    # Load output module (for help banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi

    case "$subcommand" in
        check|detailed|""|--auto-heal|--quiet)
            # Default detailed health check (full terminal output)
            # Handle --auto-heal or --quiet as first arg (pass it back to check)
            if [[ "$subcommand" == "--auto-heal" || "$subcommand" == "--quiet" ]]; then
                set -- "$subcommand" "$@"
            fi
            if [[ "$json_mode" == "true" ]]; then
                nftban_health_cmd_json "$@"
            else
                nftban_health_cmd_check "$@"
            fi
            ;;
        summary)
            # One-line summary
            nftban_health_cmd_summary "$@"
            ;;
        json|--json)
            # JSON output (backward compatibility)
            nftban_health_cmd_json "$@"
            ;;
        report)
            nftban_health_cmd_report "$@"
            ;;
        fix|enforce)
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
        pro)
            nftban_health_cmd_pro "$@"
            ;;
        registries|registry)
            nftban_health_cmd_registries "$@"
            ;;
        gui|ui)
            nftban_health_cmd_gui "$@"
            ;;
        install|verify)
            nftban_health_cmd_install "$@"
            ;;
        conflicts)
            nftban_health_cmd_conflicts "$@"
            ;;
        config)
            nftban_health_cmd_config "$@"
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
    # Args: [--auto-heal] [--quiet] [--cache-status]

    local auto_heal=0
    local quiet=0
    local cache_status=0

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
            --cache-status)
                # Write health status to cache for banner health indicator
                cache_status=1
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Usage: nftban health check [--auto-heal] [--quiet] [--cache-status]" >&2
                return 1
                ;;
        esac
    done

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    if [[ $quiet -eq 0 ]]; then
        # Show unified banner with health indicator
        if type -t nftban_banner >/dev/null 2>&1; then
            nftban_banner "health"
        fi
        echo "Running NFTBan system health check..."
        [[ $auto_heal -eq 1 ]] && echo "Auto-heal: ENABLED"
        echo ""
    fi

    # Run all checks (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_all $auto_heal || result=$?

    # Write health status to cache file (for banner display)
    if [[ $cache_status -eq 1 ]]; then
        # Load output module for cache write function
        if ! declare -f nftban_health_cache_write >/dev/null 2>&1; then
            if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
                source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" 2>/dev/null || true
            fi
        fi
        # Write cache (0=OK, 1=WARNING, 2=ERROR)
        if declare -f nftban_health_cache_write >/dev/null 2>&1; then
            nftban_health_cache_write "$result"
        else
            # Fallback: write directly
            local cache_dir="${NFTBAN_CACHE_DIR}/health"
            mkdir -p "$cache_dir" 2>/dev/null || true
            # Status codes: 0=OK, 1=WARNING, 2=ERROR, 3=SKIPPED, 4=NOT_INSTALLED
            case "$result" in
                0|3|4) echo "OK" > "${cache_dir}/health_status.cache" ;;      # OK, SKIPPED, NOT_INSTALLED = OK for banner
                1) echo "WARNING" > "${cache_dir}/health_status.cache" ;;
                2) echo "ERROR" > "${cache_dir}/health_status.cache" ;;
                *) echo "UNKNOWN" > "${cache_dir}/health_status.cache" ;;
            esac
            chmod 644 "${cache_dir}/health_status.cache" 2>/dev/null || true
        fi
    fi

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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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

    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "health"
    return 0
}

nftban_health_cmd_services() {
    # Check systemd services status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_services >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
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
        local binary_path="${NFTBAN_LIB_DIR}/bin/nftban-geoip"
        local db_path
        db_path=$(cmd_get_geoip_database 2>/dev/null) || db_path=""

        if [[ -x "$binary_path" ]]; then
            local version
            version=$("$binary_path" version 2>/dev/null || echo "unknown")
            echo "  Binary: $binary_path"
            echo "  Version: $version"
        fi

        if [[ -n "$db_path" ]] && [[ -f "$db_path" ]]; then
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
        # Check if it's just "not installed" (info) vs actual warning
        local issues="${NFTBAN_HEALTH_ISSUES[geoip]:-}"
        if [[ "$issues" == *"not installed (optional feature)"* ]]; then
            echo "ℹ️  GeoIP system: NOT INSTALLED (optional)"
            echo "  └─ To enable GeoIP features: nftban geoip update"
        else
            echo "⚠️  GeoIP system: WARNING"
            if [[ -n "$issues" ]]; then
                echo "  ${issues}"
            fi
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

nftban_health_cmd_pro() {
    # Check NFTBan Pro subscription status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_pro >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Pro Subscription Status"
    echo "==============================="
    echo ""

    nftban_health_init

    # Check Pro (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_pro || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ Pro subscription: OK"
    elif [[ $result -eq 4 ]]; then
        # HEALTH_NOT_INSTALLED
        echo "ℹ️  Pro subscription: NOT ENABLED"
        echo "  └─ To enable: nftban pro enroll"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Pro subscription: WARNING"
    else
        echo "❌ Pro subscription: ERROR"
    fi

    # Show detailed issues if available
    if [[ -n "${NFTBAN_HEALTH_ISSUES[pro]:-}" ]]; then
        echo ""
        echo "Details:"
        # Format with proper indentation
        echo "  ${NFTBAN_HEALTH_ISSUES[pro]}" | sed 's/^/  /'
    fi

    echo ""
    return $result
}

nftban_health_cmd_install() {
    # Verify installation completeness
    # Usage: nftban health install [--verbose]

    local verbose=0

    for arg in "$@"; do
        case "$arg" in
            --verbose|-v) verbose=1 ;;
            --help|-h)
                echo "Usage: nftban health install [--verbose]"
                echo ""
                echo "Verify NFTBan installation completeness."
                echo "Checks all required timers, services, binaries, directories, and configs."
                echo ""
                echo "Options:"
                echo "  --verbose, -v    Show optional components status"
                return 0
                ;;
        esac
    done

    # Ensure function is loaded
    if ! declare -f nftban_health_verify_installation >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_health.sh"
        fi
    fi

    if ! declare -f nftban_health_verify_installation >/dev/null 2>&1; then
        echo "ERROR: Installation verification function not available" >&2
        return 1
    fi

    nftban_banner "health"
    nftban_health_verify_installation "$verbose"
}

nftban_health_cmd_registries() {
    # Check NFTBan registry files validity
    # Args: [--json]

    local format="text"

    for arg in "$@"; do
        case "$arg" in
            --json) format="json" ;;
        esac
    done

    # Use dedicated registry check script if available
    local registry_check="${NFTBAN_LIB_DIR}/health/check_registries.sh"

    if [[ -x "$registry_check" ]]; then
        "$registry_check" "$format"
        return $?
    fi

    # Fallback: inline check
    echo "NFTBan Registry Validation"
    echo "=========================="
    echo ""

    local errors=0
    local warnings=0

    # Registry paths
    local commands_reg="${NFTBAN_LIB_DIR}/../commands.registry.yml"
    local config_reg="${NFTBAN_LIB_DIR}/data/config-registry.json"
    local schema_reg="${NFTBAN_LIB_DIR}/data/config-schema.json"
    local reports_reg="${NFTBAN_LIB_DIR}/data/reports-registry.json"

    # Check commands registry (YAML)
    if [[ -f "$commands_reg" ]]; then
        if python3 -c "import yaml; yaml.safe_load(open('$commands_reg'))" 2>/dev/null; then
            echo "  ✓ commands.registry.yml: Valid"
        else
            echo "  ✗ commands.registry.yml: Invalid YAML"
            ((errors++))
        fi
    else
        echo "  ⚠ commands.registry.yml: Not found"
        ((warnings++))
    fi

    # Check JSON registries
    for reg_file in "$config_reg" "$schema_reg" "$reports_reg"; do
        local reg_name
        reg_name=$(basename "$reg_file")
        if [[ -f "$reg_file" ]]; then
            if python3 -m json.tool "$reg_file" >/dev/null 2>&1; then
                echo "  ✓ $reg_name: Valid"
            else
                echo "  ✗ $reg_name: Invalid JSON"
                ((errors++))
            fi
        else
            echo "  ⚠ $reg_name: Not found"
            ((warnings++))
        fi
    done

    echo ""
    echo "─────────────────────────────────────────────────────────"

    if [[ $errors -gt 0 ]]; then
        echo "Status: ERROR ($errors errors, $warnings warnings)"
        return 2
    elif [[ $warnings -gt 0 ]]; then
        echo "Status: WARNING ($warnings warnings)"
        return 1
    else
        echo "Status: OK (all registries valid)"
        return 0
    fi
}

nftban_health_cmd_help() {
    # Show help text

    nftban_banner "health"
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

    fix, enforce [target]   Auto-fix common issues (requires root)
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

    pro                     Check NFTBan Pro subscription status
                            Validates token, vmagent, server ID, timers

    registries              Check registry files validity
                            Validates JSON/YAML syntax for:
                            - commands.registry.yml (CLI commands)
                            - config-registry.json (config files)
                            - config-schema.json (config keys)
                            - reports-registry.json (report types)
                            Use --json for machine-readable output

    install, verify         Verify installation completeness
                            Checks all required timers, services, binaries,
                            directories, and config files
                            --verbose: Show optional components

    conflicts [--fix]       Detect/remove conflicting firewalls
                            Panel+distro aware detection
                            --fix: Remove detected conflicts
                            --yes: Auto-confirm (no prompts)
                            Detects: fail2ban, ufw, firewalld, CSF

    config [--verbose]      Show module and config status
                            Displays enabled modules, their services,
                            and whether config reload is needed
                            --verbose: Show config file paths

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
    nftban health pro          # Pro subscription status

    # Auto-heal during check (combines check + fix)
    sudo nftban health check --auto-heal

    # Quiet mode for cron/timer
    nftban health check --auto-heal --quiet

    # Manual fix (traditional approach)
    sudo nftban health fix all
    sudo nftban health fix permissions

    # Or use 'enforce' (alias for 'fix')
    sudo nftban health enforce all

    # Generate report
    nftban health report terminal

    # Verify installation completeness
    nftban health install
    nftban health install --verbose  # Include optional components

    # Check config and module status
    nftban health config             # Show enabled modules + config status
    nftban health config --verbose   # Include config file paths

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

nftban_health_cmd_conflicts() {
    # Detect and optionally remove conflicting firewalls
    # Usage: nftban health conflicts [--fix] [--yes]
    # Args: --fix = remove conflicts, --yes = auto-confirm

    local fix_mode=false
    local auto_yes=false

    for arg in "$@"; do
        case "$arg" in
            --fix|--remove) fix_mode=true ;;
            --yes|-y) auto_yes=true ;;
            --help|-h)
                echo "Usage: nftban health conflicts [--fix] [--yes]"
                echo ""
                echo "Detect and optionally remove conflicting firewalls."
                echo ""
                echo "Options:"
                echo "  --fix, --remove    Remove detected conflicts"
                echo "  --yes, -y          Auto-confirm removal (no prompts)"
                echo ""
                echo "Detects: fail2ban, ufw, firewalld, CSF, iptables"
                echo "Panel-aware: Uses correct conflicts per panel+distro"
                return 0
                ;;
        esac
    done

    # Load firewall conflicts module
    if ! declare -f nftban_detect_all_conflicts >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh"
        else
            echo "ERROR: Firewall conflicts module not found" >&2
            return 1
        fi
    fi

    # Detect panel and distro
    local panel distro
    panel=$(nftban_detect_panel)
    distro=$(nftban_detect_distro)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Firewall Conflict Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  System:  $panel on $distro"
    echo ""

    # Run detection FIRST (returns severity as exit code, don't let set -e kill us)
    nftban_detect_all_conflicts || true

    # Show DETECTED CONFLICTS (what's ACTUALLY active)
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│ ACTIVE CONFLICTS (detected on this system)                 │"
    echo "├────────────────────────────────────────────────────────────┤"

    local has_conflicts=false

    # Check each potential conflict and show status
    # fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "│  ✗ fail2ban      ACTIVE (running)                         │"
        has_conflicts=true
    elif systemctl is-enabled --quiet fail2ban 2>/dev/null; then
        echo "│  ⚠ fail2ban      ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ fail2ban      not installed/disabled                   │"
    fi

    # firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "│  ✗ firewalld     ACTIVE (running)                         │"
        has_conflicts=true
    elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
        echo "│  ⚠ firewalld     ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ firewalld     not installed/disabled                   │"
    fi

    # ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        echo "│  ✗ ufw           ACTIVE (enabled)                         │"
        has_conflicts=true
    elif command -v ufw &>/dev/null; then
        echo "│  ✓ ufw           installed but inactive                   │"
    else
        echo "│  ✓ ufw           not installed                            │"
    fi

    # CSF
    if [[ -f /etc/csf/csf.conf ]] && grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
        echo "│  ✗ CSF           ACTIVE (production mode)                 │"
        has_conflicts=true
    elif [[ -f /etc/csf/csf.conf ]]; then
        echo "│  ⚠ CSF           installed (testing mode)                 │"
        has_conflicts=true
    else
        echo "│  ✓ CSF           not installed                            │"
    fi

    # iptables service
    if systemctl is-active --quiet iptables 2>/dev/null || systemctl is-active --quiet ip6tables 2>/dev/null; then
        echo "│  ✗ iptables      ACTIVE (service running)                 │"
        has_conflicts=true
    elif systemctl is-enabled --quiet iptables 2>/dev/null; then
        echo "│  ⚠ iptables      ENABLED (not running)                    │"
        has_conflicts=true
    else
        echo "│  ✓ iptables      service not active                       │"
    fi

    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    # Show verdict
    if [[ "$has_conflicts" == true ]]; then
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  ⚠️  CONFLICTS DETECTED                                   │"
        echo "  │                                                          │"
        echo "  │  These firewalls may interfere with NFTBan.              │"
        echo "  │  Run: nftban health conflicts --fix                      │"
        echo "  └──────────────────────────────────────────────────────────┘"
    else
        echo "  ┌──────────────────────────────────────────────────────────┐"
        echo "  │  ✅ NO CONFLICTS DETECTED                                 │"
        echo "  │                                                          │"
        echo "  │  System is clean. NFTBan can operate without conflicts.  │"
        echo "  └──────────────────────────────────────────────────────────┘"
    fi
    echo ""

    # Show registry info as reference (smaller, informational)
    local expected_conflicts
    expected_conflicts=$(nftban_get_panel_conflicts "$panel" "$distro")
    echo "  Registry (known conflicts for $panel on $distro):"
    echo "    $expected_conflicts"
    echo ""

    # Fix if requested
    if [[ "$fix_mode" == true ]]; then
        echo ""
        if [[ "$auto_yes" == true ]]; then
            nftban_remove_conflicts --yes --panel "$panel"
        else
            nftban_remove_conflicts --panel "$panel"
        fi
    fi

    # Return based on actual conflicts found
    if [[ "$has_conflicts" == true ]]; then
        return 1
    fi
    return 0
}

nftban_health_cmd_config() {
    # Show enabled modules and their config status
    # Usage: nftban health config [--verbose]
    # Shows: Module enabled/disabled, config files, reload needed

    local verbose=false
    for arg in "$@"; do
        [[ "$arg" == "--verbose" || "$arg" == "-v" ]] && verbose=true
    done

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local track_dir="/run/nftban/config-loaded"

    echo ""
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│           NFTBan Configuration Status                     │"
    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    # Protection modules and their status
    declare -A modules=(
        ["portscan"]="Port Scan Detection"
        ["ddos"]="DDoS Protection"
        ["login"]="Login Monitor"
        ["geoban"]="GeoIP Blocking"
        ["feeds"]="Threat Feeds"
        ["suricata"]="Suricata IDS"
    )

    declare -A module_services=(
        ["portscan"]="nftband"
        ["ddos"]="nftband"
        ["login"]="nftban-login-monitor"
        ["geoban"]="nftband"
        ["feeds"]="timer"
        ["suricata"]="nftban-suricata"
    )

    local needs_reload=false

    printf "%-12s %-8s %-18s %-20s\n" "MODULE" "STATUS" "SERVICE" "CONFIG"
    echo "────────────────────────────────────────────────────────────"

    for module in portscan ddos login geoban feeds suricata; do
        local enabled="OFF"
        local service="${module_services[$module]}"
        local config_status="-"
        local conf_file=""

        # Check if module is enabled
        # Look for ENABLED=true in module config or check service status
        if [[ -f "$config_dir/conf.d/$module/main.conf" ]]; then
            conf_file="$config_dir/conf.d/$module/main.conf"
            if grep -qE "^[A-Z_]*ENABLED.*=.*[\"']?true" "$conf_file" 2>/dev/null || \
               grep -qE "^[A-Z_]*ENABLED.*=.*[\"']?YES" "$conf_file" 2>/dev/null; then
                enabled="ON"
            fi
        elif [[ -f "$config_dir/conf.d/${module}.conf" ]]; then
            conf_file="$config_dir/conf.d/${module}.conf"
            enabled="ON"  # Presence means enabled for simple configs
        fi

        # Check local override
        local local_conf="${conf_file}.local"
        [[ -f "$config_dir/conf.d/$module/main.conf.local" ]] && local_conf="$config_dir/conf.d/$module/main.conf.local"

        # Service status
        local svc_status="stopped"
        if [[ "$service" == "timer" ]]; then
            svc_status="timer"
        elif systemctl is-active "${service}.service" &>/dev/null; then
            svc_status="running"
        fi

        # Config status (only if service running)
        if [[ "$svc_status" == "running" && -f "$track_dir/.timestamp" ]]; then
            # Check if local config changed since load
            if [[ -f "$local_conf" ]]; then
                local curr_hash loaded_hash hash_file
                curr_hash=$(sha256sum "$local_conf" 2>/dev/null | cut -d' ' -f1)
                hash_file="$track_dir/$(basename "$local_conf").sha256"
                loaded_hash=$(cat "$hash_file" 2>/dev/null || echo "none")
                if [[ "$curr_hash" != "$loaded_hash" && "$loaded_hash" != "none" ]]; then
                    config_status="CHANGED"
                    needs_reload=true
                else
                    config_status="current"
                fi
            else
                config_status="default"
            fi
        elif [[ "$svc_status" == "running" ]]; then
            config_status="not tracked"
        fi

        # Format output
        local status_icon="○"
        [[ "$enabled" == "ON" ]] && status_icon="●"

        printf "%-12s %-8s %-18s %-20s\n" "$module" "$status_icon $enabled" "$svc_status" "$config_status"

        # Verbose: show config files
        if [[ "$verbose" == true && -n "$conf_file" ]]; then
            echo "             └─ $conf_file"
            [[ -f "$local_conf" ]] && echo "             └─ $local_conf (override)"
        fi
    done

    echo ""

    # Show last reload time
    if [[ -f "$track_dir/.timestamp" ]]; then
        local ts
        ts=$(cat "$track_dir/.timestamp" 2>/dev/null)
        echo "Last config reload: $(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    else
        echo "Last config reload: Never (using startup config)"
    fi

    echo ""

    # Show reload hint if needed
    if [[ "$needs_reload" == true ]]; then
        echo "┌────────────────────────────────────────────────────────────┐"
        echo "│  ⚠️  Config changed on disk. Run: nftban config reload     │"
        echo "└────────────────────────────────────────────────────────────┘"
    else
        echo "✓ All running services have current config"
    fi
    echo ""
}

nftban_health_cmd_gui() {
    # Validate GOTH GUI components against ui-registry.json
    # Args: [--json]
    # Usage: nftban health gui [--json]

    local json_mode=""
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="--json"
    done

    echo "NFTBan GUI Registry Validation"
    echo "==============================="
    echo ""

    # Find the GUI check script
    local gui_check_script="${NFTBAN_LIB_DIR}/health/check_gui.sh"

    # Also check in development location
    local dev_check_script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dev_check_script="${script_dir}/../health/check_gui.sh"

    if [[ -f "$gui_check_script" ]]; then
        bash "$gui_check_script" $json_mode
        return $?
    elif [[ -f "$dev_check_script" ]]; then
        bash "$dev_check_script" $json_mode
        return $?
    else
        echo "❌ GUI check script not found"
        echo "  Expected: $gui_check_script"
        return 1
    fi
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
export -f nftban_health_cmd_pro
export -f nftban_health_cmd_registries
export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_gui
export -f nftban_health_cmd_help
