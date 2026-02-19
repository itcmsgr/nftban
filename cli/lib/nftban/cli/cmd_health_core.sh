#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Health Check CLI Command - Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Core health check commands: check, summary, json, report, fix
#
# meta:name="cmd_health_core"
# meta:type="cli"
# meta:header="Health Check Core Module"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Core health check commands: check, summary, json, report, fix"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# Loaded by: cmd_health.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_HEALTH_CORE_LOADED:-}" ]] && return 0
_CMD_HEALTH_CORE_LOADED="true"

# =============================================================================
# COMMAND: check
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

# =============================================================================
# COMMAND: summary
# =============================================================================

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

    # Render summary and return its exit code (0=OK, 1=WARNING, 2=ERROR)
    # BUG-LOW-002 FIX: Use render_summary's return code, not check_all's
    nftban_health_render_summary
    return $?
}

# =============================================================================
# COMMAND: json
# =============================================================================

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

# =============================================================================
# COMMAND: report
# =============================================================================

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

# =============================================================================
# COMMAND: fix
# =============================================================================

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
            # CRITICAL: Always sync whitelist BEFORE fixing nftables
            # ROOT CAUSE: nftables fix creates chains with DROP policy
            # Without whitelist sync first, SSH gets blocked = lockout
            echo "=== WHITELIST SYNC (lockout prevention) ==="
            nftban_health_fix_whitelist || {
                echo "  ⚠ Whitelist sync failed - aborting nftables fix"
                echo "  Manual fix: nftban whitelist sync && nftban health fix nftables"
                return 1
            }
            echo ""
            nftban_health_fix_nftables
            ;;
        daemon|memory)
            nftban_health_fix_daemon_memory
            ;;
        whitelist)
            # Sync server IPs to whitelist (lockout prevention)
            echo "=== WHITELIST SYNC ==="
            nftban_health_fix_whitelist
            ;;
        all)
            # =================================================================
            # FIX ORDER IS CRITICAL TO PREVENT SSH LOCKOUT
            # =================================================================
            # ROOT CAUSE (v1.16.0 bug): nftban_health_fix_nftables() creates
            # chains with "policy drop" which blocks all traffic including SSH.
            # If whitelist is not synced FIRST, the admin gets locked out.
            #
            # CORRECT ORDER:
            # 1. Fix directories (needed for whitelist sync)
            # 2. Fix permissions (needed for nftables access)
            # 3. Fix whitelist (MUST be BEFORE nftables creates DROP chains)
            # 4. Fix nftables (safe now - whitelist has SSH IPs)
            # 5. Fix everything else
            # =================================================================
            nftban_health_fix_directories
            nftban_health_fix_permissions
            nftban_health_fix_system_config
            nftban_health_fix_services
            # CRITICAL: Sync whitelist BEFORE creating DROP policy chains
            # This ensures SSH and server IPs are whitelisted first
            echo ""
            echo "=== WHITELIST SYNC (lockout prevention) ==="
            nftban_health_fix_whitelist || {
                echo "  ⚠ Whitelist sync failed - proceeding with caution"
            }
            echo ""
            # Now safe to create/fix nftables structure
            nftban_health_fix_nftables
            nftban_health_fix_polkit
            nftban_health_fix_daemon_memory
            # Run inline auto-heal checks (from log analysis bugs)
            echo "Fixing detected issues (queue, locks, ipc)..."
            nftban_health_check_queue_processor 1 2>/dev/null || true
            nftban_health_check_maintenance_lock 1 2>/dev/null || true
            ;;
        *)
            echo "ERROR: Invalid fix target: $what" >&2
            echo "Valid targets: permissions, directories, services, config, polkit, nftables, whitelist, daemon, all" >&2
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

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_health_cmd_check
export -f nftban_health_cmd_summary
export -f nftban_health_cmd_json
export -f nftban_health_cmd_report
export -f nftban_health_cmd_fix
