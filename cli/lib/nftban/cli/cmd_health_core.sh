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
# meta:version="1.48.0"
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
    # Args: [--auto-heal] [--quiet] [--cache-status] [--strict]

    local auto_heal=0
    local quiet=0
    local cache_status=0
    local strict_mode=0

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
            --strict)
                # v1.39.0: Treat warnings as failures (for CI pipelines)
                strict_mode=1
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Usage: nftban health check [--auto-heal] [--quiet] [--cache-status] [--strict]" >&2
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
    nftban_health_check_all "$auto_heal" || result=$?

    # v1.24.1: Use exported scalar counts from check_all() (ground truth)
    # check_all() now derives counts from NFTBAN_HEALTH_RESULTS[] associative
    # array and exports them as scalars. This avoids the bash +x test bug with
    # associative arrays and the divergence between ERRORS[]/WARNINGS[] arrays
    # and RESULTS[] values.
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"

    # Diagnostics exit codes: 0=OK, 1=WARNING(strict), 2=ERROR
    # v1.37.1: Warnings about OPTIONAL features (Web GUI, metrics, etc.)
    # must NOT cause non-zero exit. Only real errors (broken firewall,
    # missing binaries, failed checks) should fail.
    # v1.39.0: --strict mode makes warnings return exit 1 (for CI pipelines)
    if [[ $error_count -gt 0 ]]; then
        result=2
    elif [[ $strict_mode -eq 1 && $warning_count -gt 0 ]]; then
        result=1
    else
        result=0
    fi

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
            # Status codes: 0=OK, 1=WARNING, 2=ERROR
            local _hc_tmp="${cache_dir}/health_status.cache.tmp"
            case "$result" in
                0) echo "PROTECTED" > "$_hc_tmp" ;;
                1) echo "WARNING" > "$_hc_tmp" ;;
                2) echo "ERROR" > "$_hc_tmp" ;;
                *) echo "UNKNOWN" > "$_hc_tmp" ;;
            esac
            chmod 644 "$_hc_tmp" 2>/dev/null || true
            mv -f "$_hc_tmp" "${cache_dir}/health_status.cache" 2>/dev/null || true
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
# COMMAND: brief (v1.24.0)
# =============================================================================

nftban_health_cmd_brief() {
    # v1.24.0: One-line diagnostics output for CI/fleet/monitoring
    # Output: OK | 26 checks passed | 4 info
    # Returns: 0=OK (including warnings), 1=warning(strict), 2=errors
    # v1.39.0: Supports --strict flag (warnings → exit 1)

    local strict_mode=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict) strict_mode=1; shift ;;
            *) shift ;;
        esac
    done

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    # Run all checks silently
    nftban_health_check_all >/dev/null 2>&1 || true

    # v1.24.1: Use exported scalar counts (reliable across all bash scoping)
    # NFTBAN_HEALTH_RESULTS+x test is broken for associative arrays declared
    # via dynamic sourcing (bash quirk). Use exported scalars from check_all().
    local total_checks="${NFTBAN_HEALTH_TOTAL_CHECKS:-0}"
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"
    local ok_count=$((total_checks - error_count - warning_count))
    [[ $ok_count -lt 0 ]] && ok_count=0

    local info_count=$((warning_count + error_count))
    if [[ $error_count -gt 0 ]]; then
        echo "ERROR | ${ok_count} checks passed | ${error_count} errors, ${warning_count} warnings"
        return 2
    elif [[ $warning_count -gt 0 ]]; then
        # v1.38.0: Show specific warning reasons instead of generic "info"
        local reasons=""
        # Detect common optional-feature warnings
        if ! command -v nftban-ui &>/dev/null && ! [[ -f /usr/lib/nftban/bin/nftban-ui ]]; then
            reasons="${reasons:+$reasons, }gui-not-installed"
        fi
        if ! systemctl is-active --quiet nftban-prometheus-exporter.timer 2>/dev/null; then
            reasons="${reasons:+$reasons, }metrics-inactive"
        fi
        if [[ -z "$reasons" ]]; then
            reasons="optional-features"
        fi
        echo "OK | ${ok_count} checks passed | ${info_count} info (${reasons})"
        # v1.39.0: --strict makes warnings fail
        [[ $strict_mode -eq 1 ]] && return 1
        return 0
    else
        echo "OK | ${total_checks} checks passed | 0 info"
        return 0
    fi
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

    # v1.37.1: render_summary now returns 0=OK/WARNING, 2=ERROR
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

    # Render JSON (uses exported scalar counts for summary)
    nftban_health_render_json

    # v1.37.1: Warnings exit 0 (optional features are not errors)
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    if [[ $error_count -gt 0 ]]; then
        return 2
    fi
    return 0
}

# v1.83 DEAD-1: nftban_health_cmd_report() removed — unreachable since v1.39.0.
# The CLI dispatcher in cmd_health.sh returns an error for "nftban health report"
# with a message directing users to "nftban health json".

# =============================================================================
# COMMAND: fix
# =============================================================================

nftban_health_cmd_fix() {
    # Auto-fix common issues
    # Args: $1 = what to fix (optional: permissions|directories|services|all)
    # Flags: --dry-run, --skip-downloads, --yes

    local what="${1:-all}"
    local dry_run=0
    local skip_downloads=0
    local auto_yes=0

    # v1.43.0 P3-27: Parse flags
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --skip-downloads) skip_downloads=1 ;;
            --yes|-y) auto_yes=1 ;;
            *) args+=("$arg") ;;
        esac
    done
    [[ ${#args[@]} -gt 0 ]] && what="${args[0]}"

    # Export flags for sub-functions
    export NFTBAN_FIX_DRY_RUN="$dry_run"
    export NFTBAN_FIX_SKIP_DOWNLOADS="$skip_downloads"
    export NFTBAN_FIX_AUTO_YES="$auto_yes"

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

    if [[ $dry_run -eq 1 ]]; then
        echo "MODE: DRY-RUN (no changes will be made)"
        echo ""
    fi

    if [[ $skip_downloads -eq 1 ]]; then
        echo "NOTE: Downloads will be skipped (--skip-downloads)"
        echo ""
    fi

    # Show privilege level
    if [[ $EUID -eq 0 ]]; then
        echo "Running as: root (can fix everything)"
    else
        echo "Running as: $(whoami) (can fix owned files, will report what needs root)"
    fi
    echo ""

    # Confirmation prompt (unless --yes or --dry-run)
    if [[ "$what" == "all" && $auto_yes -eq 0 && $dry_run -eq 0 && -t 0 ]]; then
        printf "This will attempt to fix all detected issues. Continue? [y/N] "
        local reply
        read -r reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "Aborted."
                return 1
                ;;
        esac
    fi

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
            # 1. Remove conflicting firewalls (v1.18.7)
            # 2. Fix directories (needed for whitelist sync)
            # 3. Fix permissions (needed for nftables access)
            # 4. Fix whitelist (MUST be BEFORE nftables creates DROP chains)
            # 5. Fix nftables (safe now - whitelist has SSH IPs)
            # 6. Auto-detect and enable services (v1.18.7)
            # 7. Fix everything else
            # =================================================================

            # v1.48.0: Remove ALL conflicting firewalls automatically
            echo "[1/9] Removing conflicting firewalls..."
            if command -v apt-get &>/dev/null; then
                # Debian/Ubuntu
                apt-get remove -y ufw 2>/dev/null && echo "  ✓ Removed UFW" || true
            elif command -v dnf &>/dev/null; then
                # RHEL/Fedora
                systemctl disable --now firewalld 2>/dev/null && echo "  ✓ Disabled firewalld" || true
            fi
            systemctl disable --now fail2ban 2>/dev/null && echo "  ✓ Disabled fail2ban" || true
            # v1.48.0: CSF removal was missing — caused ghost tables on DirectAdmin/cPanel
            if command -v csf &>/dev/null || [[ -f /etc/csf/csf.conf ]]; then
                csf -x 2>/dev/null || true
                systemctl stop lfd csf 2>/dev/null || true
                systemctl disable lfd csf 2>/dev/null || true
                echo "  ✓ Disabled CSF/LFD"
            fi

            echo ""
            echo "[2/9] Fixing directories..."
            nftban_health_fix_directories

            echo ""
            echo "[3/9] Fixing permissions..."
            nftban_health_fix_permissions
            nftban_health_fix_system_config
            nftban_health_fix_services

            # CRITICAL: Sync whitelist BEFORE creating DROP policy chains
            # This ensures SSH and server IPs are whitelisted first
            echo ""
            echo "[4/9] WHITELIST SYNC (lockout prevention)..."
            nftban_health_fix_whitelist || {
                echo "  ⚠ Whitelist sync failed - proceeding with caution"
            }

            # v1.48.0: Centralized ghost table cleanup (replaces hardcoded list)
            echo ""
            echo "[5/9] Cleaning ghost nftables tables..."
            if declare -f nftban_cleanup_ghost_tables &>/dev/null; then
                nftban_cleanup_ghost_tables
            else
                # Fallback if function not loaded
                for rogue_table in "ip filter" "ip6 filter" "ip nat" "ip mangle" "inet filter" "inet firewalld" "inet nftban_install_emergency"; do
                    if nft list table $rogue_table &>/dev/null; then
                        echo "  Removing: $rogue_table"
                        nft delete table $rogue_table 2>/dev/null || true
                    fi
                done
            fi

            echo ""
            echo "[6/9] Fixing nftables structure..."
            # Now safe to create/fix nftables structure
            nftban_health_fix_nftables

            # v1.48.0: Sync ports to nft sets (catches SSH port changes)
            # The health CHECK updates 00-ssh.conf and tries IPC, but IPC may fail.
            # A full sync directly applies port config to nft sets.
            if command -v nftban &>/dev/null; then
                echo "  Syncing ports to firewall..."
                nftban sync --quick 2>/dev/null || true
            fi

            # v1.18.7: Download GeoIP database if missing
            echo ""
            echo "[7/9] Updating GeoIP database..."
            if command -v nftban &>/dev/null; then
                nftban geoip update 2>/dev/null || echo "  ⚠ GeoIP update failed (non-critical)"
            fi

            # v1.18.7: Auto-detect and enable services/panels
            echo ""
            echo "[8/9] Auto-detecting services and panels..."
            if command -v nftban &>/dev/null; then
                local detected_panel
                detected_panel=$(nftban panel detect 2>/dev/null || echo "none")
                if [[ "$detected_panel" != "none" && -n "$detected_panel" ]]; then
                    echo "  Detected panel: $detected_panel"
                    nftban panel "$detected_panel" enable 2>/dev/null || true
                fi
                nftban login enable 2>/dev/null && echo "  ✓ Login monitor enabled" || true
            fi

            echo ""
            echo "[9/9] Fixing remaining components..."
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
# COMMAND: nagios (v1.43.0 P3-29)
# =============================================================================

nftban_health_cmd_nagios() {
    # v1.43.0 P3-29: Nagios/Icinga/monitoring plugin compatible output
    # Output format: STATUS - summary | perfdata
    # Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN

    # Load health module if not already loaded
    if ! declare -f nftban_health_check_all >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "UNKNOWN - Failed to load health check module"
            return 3
        }
    fi

    # Run all checks silently
    nftban_health_check_all >/dev/null 2>&1 || true

    local total_checks="${NFTBAN_HEALTH_TOTAL_CHECKS:-0}"
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"
    local ok_count=$((total_checks - error_count - warning_count))
    [[ $ok_count -lt 0 ]] && ok_count=0

    # Get ban count for perfdata
    local ban_count=0
    if declare -f nftban_stats_count_active_bans >/dev/null 2>&1; then
        ban_count=$(nftban_stats_count_active_bans 2>/dev/null || echo 0)
    fi

    # Perfdata format: label=value[;warn;crit;min;max]
    local perfdata="checks=${total_checks} ok=${ok_count} warnings=${warning_count} errors=${error_count} bans=${ban_count}"

    if [[ $error_count -gt 0 ]]; then
        echo "CRITICAL - NFTBan: ${error_count} errors, ${warning_count} warnings of ${total_checks} checks | ${perfdata}"
        return 2
    elif [[ $warning_count -gt 0 ]]; then
        echo "WARNING - NFTBan: ${warning_count} warnings of ${total_checks} checks | ${perfdata}"
        return 1
    else
        echo "OK - NFTBan: ${total_checks} checks passed | ${perfdata}"
        return 0
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_health_cmd_check
export -f nftban_health_cmd_brief
export -f nftban_health_cmd_summary
export -f nftban_health_cmd_json
# v1.83: export removed — function deleted (DEAD-1)
export -f nftban_health_cmd_fix
export -f nftban_health_cmd_nagios
