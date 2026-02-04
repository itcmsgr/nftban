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
        rbl)
            nftban_health_cmd_rbl "$@"
            ;;
        posture|security)
            nftban_health_cmd_posture "$@"
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
        polkit)
            nftban_health_fix_polkit
            ;;
        nftables)
            nftban_health_fix_nftables
            ;;
        daemon|memory)
            nftban_health_fix_daemon_memory
            ;;
        all)
            nftban_health_fix_directories
            nftban_health_fix_permissions
            nftban_health_fix_system_config
            nftban_health_fix_services
            nftban_health_fix_nftables
            nftban_health_fix_polkit
            nftban_health_fix_daemon_memory
            ;;
        *)
            echo "ERROR: Invalid fix target: $what" >&2
            echo "Valid targets: permissions, directories, services, config, polkit, nftables, daemon, all" >&2
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

    posture, security       Check security posture (low noise)
                            Smart limited scope, NOT an audit replacement
                            Checks: SSH config, sudoers, systemd hardening,
                            config integrity. For audits use lynis/oscap.

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

    # Security posture (low noise check)
    nftban health posture            # SSH, sudo, systemd hardening basics

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

nftban_health_cmd_rbl() {
    # Check RBL (Real-time Blocklist) system health
    # Args: none
    # Checks: enabled status, timer, last check, cache directory

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local rbl_config="$config_dir/conf.d/rbl/main.conf"
    local rbl_cache_dir="/var/log/nftban/rbl"
    local last_check_file="$rbl_cache_dir/last_check"

    # Status tracking
    local overall_status="OK"
    local status_color="\033[32m"  # Green

    # Check results
    local rbl_enabled="NO"
    local timer_active="NO"
    local last_check_status="N/A"
    local last_check_time=""
    local cache_dir_status="missing"

    echo ""
    echo "RBL Health Check"
    echo "─────────────────────────────────────────"

    # 1. Check RBL enabled status from main.conf
    if [[ -f "$rbl_config" ]]; then
        if grep -qE "^RBL_ENABLED.*=.*[\"']?(true|yes|1|YES|TRUE)" "$rbl_config" 2>/dev/null; then
            rbl_enabled="YES"
        fi
    fi

    # 2. Check timer status
    if systemctl is-active --quiet nftban-rbl-check.timer 2>/dev/null; then
        timer_active="YES"
    elif systemctl is-enabled --quiet nftban-rbl-check.timer 2>/dev/null; then
        timer_active="ENABLED (not running)"
        if [[ "$overall_status" == "OK" ]]; then
            overall_status="WARNING"
            status_color="\033[33m"  # Yellow
        fi
    else
        timer_active="NO"
        if [[ "$rbl_enabled" == "YES" ]]; then
            # RBL enabled but timer not active = warning
            if [[ "$overall_status" == "OK" ]]; then
                overall_status="WARNING"
                status_color="\033[33m"  # Yellow
            fi
        fi
    fi

    # 3. Check last check timestamp
    if [[ -f "$last_check_file" ]]; then
        local last_ts current_ts age_seconds age_hours
        last_ts=$(cat "$last_check_file" 2>/dev/null | head -1)

        # Handle both epoch timestamp and ISO date formats
        if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
            # Epoch timestamp
            current_ts=$(date +%s)
            age_seconds=$((current_ts - last_ts))
        else
            # Try to parse as date string
            last_ts=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
            current_ts=$(date +%s)
            age_seconds=$((current_ts - last_ts))
        fi

        age_hours=$((age_seconds / 3600))

        if [[ $age_hours -lt 1 ]]; then
            local age_minutes=$((age_seconds / 60))
            last_check_time="${age_minutes} minutes ago"
        elif [[ $age_hours -lt 24 ]]; then
            last_check_time="${age_hours} hours ago"
        else
            local age_days=$((age_hours / 24))
            last_check_time="${age_days} days ago"
        fi

        # Check if within 48 hours (172800 seconds)
        if [[ $age_seconds -le 172800 ]]; then
            last_check_status="$last_check_time (OK)"
        else
            last_check_status="$last_check_time (STALE)"
            if [[ "$rbl_enabled" == "YES" ]]; then
                overall_status="WARNING"
                status_color="\033[33m"  # Yellow
            fi
        fi
    else
        last_check_status="Never"
        if [[ "$rbl_enabled" == "YES" ]]; then
            overall_status="WARNING"
            status_color="\033[33m"  # Yellow
        fi
    fi

    # 4. Check cache directory
    if [[ -d "$rbl_cache_dir" ]]; then
        if [[ -w "$rbl_cache_dir" ]]; then
            cache_dir_status="$rbl_cache_dir (writable)"
        else
            cache_dir_status="$rbl_cache_dir (not writable)"
            overall_status="ERROR"
            status_color="\033[31m"  # Red
        fi
    else
        cache_dir_status="$rbl_cache_dir (missing)"
        if [[ "$rbl_enabled" == "YES" ]]; then
            overall_status="ERROR"
            status_color="\033[31m"  # Red
        fi
    fi

    # If RBL is disabled, overall status should still be OK unless there's an error
    if [[ "$rbl_enabled" == "NO" && "$overall_status" == "WARNING" ]]; then
        # Reset to OK if RBL is disabled - warnings only matter when enabled
        overall_status="OK"
        status_color="\033[32m"  # Green
    fi

    # Display results
    printf "  RBL Enabled:     %s\n" "$rbl_enabled"
    printf "  Timer Active:    %s\n" "$timer_active"
    printf "  Last Check:      %s\n" "$last_check_status"
    printf "  Cache Dir:       %s\n" "$cache_dir_status"
    echo ""
    printf "  Status: %b%s%b\n" "$status_color" "$overall_status" "\033[0m"
    echo ""

    # Return appropriate exit code
    case "$overall_status" in
        OK) return 0 ;;
        WARNING) return 1 ;;
        ERROR) return 2 ;;
        *) return 1 ;;
    esac
}

nftban_health_cmd_posture() {
    # Check security posture (low noise, limited scope - NOT audit replacement)
    # Args: none
    # Checks: SSH config, sudoers basics, systemd hardening, config integrity

    echo ""
    echo "Security Posture Check"
    echo "─────────────────────────────────────────"
    echo "  (Low noise, limited scope - not an audit replacement)"
    echo ""

    local warnings=0
    local issues=0
    local total_checks=0

    # Load posture collection if available
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_report_data.sh" 2>/dev/null || true
    fi

    # ───────────────────────────────────────────────────────────────────────
    # 1. SSH CONFIGURATION BASICS
    # ───────────────────────────────────────────────────────────────────────
    echo "SSH Configuration"
    echo "  ─────────────────────────────────────"

    local ssh_config="/etc/ssh/sshd_config"
    if [[ -f "$ssh_config" ]]; then
        ((total_checks++))
        # PasswordAuthentication
        local pass_auth
        pass_auth=$(grep -E "^PasswordAuthentication" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$pass_auth" == "no" ]]; then
            printf "  %-28s ✅ Disabled (key-only)\n" "PasswordAuthentication"
        else
            printf "  %-28s ⚠️  Enabled (consider disabling)\n" "PasswordAuthentication"
            ((warnings++))
        fi

        ((total_checks++))
        # PermitRootLogin
        local root_login
        root_login=$(grep -E "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
            printf "  %-28s ✅ %s\n" "PermitRootLogin" "$root_login"
        else
            printf "  %-28s ⚠️  %s (consider 'no' or 'prohibit-password')\n" "PermitRootLogin" "$root_login"
            ((warnings++))
        fi

        ((total_checks++))
        # X11Forwarding
        local x11_fwd
        x11_fwd=$(grep -E "^X11Forwarding" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
        if [[ "$x11_fwd" == "no" ]]; then
            printf "  %-28s ✅ Disabled\n" "X11Forwarding"
        else
            printf "  %-28s ℹ️  Enabled (minor risk)\n" "X11Forwarding"
        fi
    else
        printf "  %-28s ⚠️  Config not found\n" "sshd_config"
        ((warnings++))
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 2. SUDOERS BASICS
    # ───────────────────────────────────────────────────────────────────────
    echo "Sudoers Configuration"
    echo "  ─────────────────────────────────────"

    local sudoers_dir="/etc/sudoers.d"
    if [[ -d "$sudoers_dir" ]]; then
        ((total_checks++))
        local risky_count=0
        local nftban_sudoers_ok=false

        for sfile in "$sudoers_dir"/*; do
            [[ -f "$sfile" ]] || continue
            local sname
            sname=$(basename "$sfile")

            # NFTBan's own sudoers file is expected
            if [[ "$sname" == "nftban" ]]; then
                nftban_sudoers_ok=true
                continue
            fi

            # Skip backup files
            [[ "$sname" == *~ ]] && continue
            [[ "$sname" == *.bak ]] && continue

            # Flag ALL NOPASSWD (risky)
            if grep -qE "NOPASSWD:\s*ALL" "$sfile" 2>/dev/null; then
                printf "  %-28s ⚠️  %s has ALL NOPASSWD\n" "Sudoers" "$sname"
                ((risky_count++))
            fi
        done

        if [[ $risky_count -eq 0 ]]; then
            printf "  %-28s ✅ No risky NOPASSWD patterns\n" "Sudoers"
        else
            ((warnings += risky_count))
        fi

        if [[ "$nftban_sudoers_ok" == true ]]; then
            printf "  %-28s ✅ Present (scoped)\n" "NFTBan sudoers"
        fi
    else
        printf "  %-28s ℹ️  /etc/sudoers.d not found\n" "Sudoers"
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 3. SYSTEMD SERVICE HARDENING
    # ───────────────────────────────────────────────────────────────────────
    echo "Systemd Service Hardening"
    echo "  ─────────────────────────────────────"

    local hardening_checks=("NoNewPrivileges" "PrivateTmp" "ProtectSystem")
    local systemd_found=false

    for unit_dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        [[ -d "$unit_dir" ]] || continue
        for svc in "$unit_dir"/nftban*.service; do
            [[ -f "$svc" ]] || continue
            systemd_found=true
            local svc_name
            svc_name=$(basename "$svc" .service)
            local hardened=0
            local total=${#hardening_checks[@]}

            for check in "${hardening_checks[@]}"; do
                if grep -qE "^${check}=(true|yes|strict|full)" "$svc" 2>/dev/null; then
                    ((hardened++))
                fi
            done

            ((total_checks++))
            if [[ $hardened -eq $total ]]; then
                printf "  %-28s ✅ %d/%d hardening options\n" "$svc_name" "$hardened" "$total"
            elif [[ $hardened -gt 0 ]]; then
                printf "  %-28s ℹ️  %d/%d hardening options\n" "$svc_name" "$hardened" "$total"
            else
                printf "  %-28s ⚠️  No hardening options\n" "$svc_name"
                ((warnings++))
            fi
        done
        [[ "$systemd_found" == true ]] && break
    done

    [[ "$systemd_found" != true ]] && printf "  %-28s ℹ️  No NFTBan services found\n" "Services"
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # 4. CONFIG INTEGRITY
    # ───────────────────────────────────────────────────────────────────────
    echo "Config Integrity"
    echo "  ─────────────────────────────────────"

    local conf_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local integrity_file="${conf_dir}/.config_checksums"

    ((total_checks++))
    if [[ -f "$integrity_file" ]]; then
        local drift_count=0
        local checked_count=0

        while IFS=' ' read -r stored_hash fpath; do
            [[ -z "$fpath" ]] && continue
            [[ "$fpath" == "#"* ]] && continue
            [[ -f "$fpath" ]] || continue
            ((checked_count++))
            local current_hash
            current_hash=$(sha256sum "$fpath" 2>/dev/null | cut -d' ' -f1 || echo "")
            if [[ -n "$current_hash" && "$current_hash" != "$stored_hash" ]]; then
                ((drift_count++))
            fi
        done < "$integrity_file"

        if [[ $drift_count -eq 0 ]]; then
            printf "  %-28s ✅ %d files verified\n" "Config integrity" "$checked_count"
        else
            printf "  %-28s ⚠️  %d file(s) modified since install\n" "Config integrity" "$drift_count"
            ((warnings++))
        fi
    else
        printf "  %-28s ℹ️  Checksums not available\n" "Config integrity"
    fi
    echo ""

    # ───────────────────────────────────────────────────────────────────────
    # SUMMARY
    # ───────────────────────────────────────────────────────────────────────
    echo "─────────────────────────────────────────"
    if [[ $warnings -eq 0 && $issues -eq 0 ]]; then
        echo "  Status: ✅ OK ($total_checks checks passed)"
        echo ""
        echo "  Note: This is a basic posture check, not a security audit."
        echo "  For comprehensive auditing, use dedicated tools like:"
        echo "    - lynis audit system"
        echo "    - oscap xccdf eval"
        return 0
    elif [[ $issues -eq 0 ]]; then
        echo "  Status: ⚠️  $warnings advisory finding(s)"
        echo ""
        echo "  These are recommendations, not critical issues."
        echo "  Review and address as appropriate for your environment."
        return 1
    else
        echo "  Status: ❌ $issues issue(s), $warnings warning(s)"
        return 2
    fi
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
export -f nftban_health_cmd_rbl
export -f nftban_health_cmd_posture
export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_gui
export -f nftban_health_cmd_help
