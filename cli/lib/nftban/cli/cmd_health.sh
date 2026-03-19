#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Health Check CLI Handler (Loader)
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
#
# =============================================================================
# MODULE LOADER
# =============================================================================
# Health CLI functions are split into separate files for maintainability:
#
# cmd_health_core.sh       - check, summary, json, report, fix
# cmd_health_components.sh - services, modules, binaries, permissions, geoip, pro, install, registries
# cmd_health_analysis.sh   - conflicts, config, rbl, posture, gui
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

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_HEALTH_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_HEALTH_LOADED=1

# =============================================================================
# MODULE LOADER
# =============================================================================

# Get the directory where this script is located
_cmd_health_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cmd_health_modules=(
    "cmd_health_core.sh"
    "cmd_health_components.sh"
    "cmd_health_analysis.sh"
)

for _module in "${_cmd_health_modules[@]}"; do
    _module_path="${_cmd_health_dir}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck source=/dev/null
        source "$_module_path" || {
            echo "ERROR: Failed to load health module: $_module" >&2
            exit 1
        }
    else
        echo "ERROR: Health module not found: $_module_path" >&2
        exit 1
    fi
done

# Cleanup temporary variables
unset _cmd_health_modules _module _module_path _cmd_health_dir

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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
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
        --brief|brief)
            # v1.24.0: One-line health output for CI/fleet/monitoring
            nftban_health_cmd_brief "$@"
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
        fix|enforce|--fix)
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
        botguard)
            nftban_health_cmd_botguard "$@"
            ;;
        fhs)
            # Redirect to top-level nftban fhs command
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_fhs.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/cli/cmd_fhs.sh"
                nftban_cmd_fhs "$@"
            else
                echo "ERROR: cmd_fhs.sh not found" >&2
                return 1
            fi
            ;;
        posture|security)
            nftban_health_cmd_posture "$@"
            ;;
        help|-h|--help)
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
# HELP
# =============================================================================

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
    nftban health botguard     # HTTP Bot Guard health
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

NFTBan — Open-source Linux IPS and nftables firewall manager
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main handler
export -f nftban_cmd_health

# Export subcommand functions (loaded from modules)
export -f nftban_health_cmd_check
export -f nftban_health_cmd_brief
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
export -f nftban_health_cmd_botguard
export -f nftban_health_cmd_posture
export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_config
export -f nftban_health_cmd_gui
export -f nftban_health_cmd_install
export -f nftban_health_cmd_help
