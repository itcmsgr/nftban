#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Check System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System health checks and diagnostics
#
# meta:name="nftban_health"
# meta:type="core"
# meta:header="Health Check System"
# meta:version="1.50.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Comprehensive system health verification and auto-fix capabilities"
# meta:input="System state and configuration files"
# meta:output="Health status reports and automated fixes"
#
# **Inventory & Requirements**
# meta:depends="nftban_fhs_spec.sh,nft,systemctl"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================

set -Eeuo pipefail

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_HEALTH_LOADED:-}" ]] && return 0
readonly NFTBAN_HEALTH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Health check results storage
declare -A NFTBAN_HEALTH_RESULTS
declare -A NFTBAN_HEALTH_ISSUES
declare -a NFTBAN_HEALTH_WARNINGS
declare -a NFTBAN_HEALTH_ERRORS

# Health status codes (exported for callers)
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_OK=0
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_WARNING=1
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_ERROR=2
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_CRITICAL=3
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_NOT_INSTALLED=4
# shellcheck disable=SC2034  # Constants exported for external use
readonly HEALTH_DISABLED=5

# Load main configuration (service names, paths)
# shellcheck source=/etc/nftban/nftban.conf
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi

# Load metrics configuration (defaults then user overrides)
# shellcheck source=/dev/null
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf" 2>/dev/null || true
# shellcheck source=/dev/null
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf.local" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf.local" 2>/dev/null || true

# Metrics endpoint defaults (fallbacks if not set in config)
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"
: "${NFTBAN_METRICS_VICTORIA_ADDR:=localhost:8428}"
: "${NFTBAN_TIMEOUT_FAST:=5}"

# Load NFT schema (single source of truth for table/set names)
# NFTBAN_LIB_DIR is set by the calling script (cmd_health.sh, etc.)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" || return 1
fi

# =============================================================================
# INITIALIZATION & DEPENDENCIES
# =============================================================================

nftban_health_init() {
    # Initialize health check system and load report modules

    # Clear previous results (MUST be associative arrays)
    # shellcheck disable=SC2034  # Arrays used by render functions
    declare -gA NFTBAN_HEALTH_RESULTS=()
    # shellcheck disable=SC2034  # Arrays used by render functions
    declare -gA NFTBAN_HEALTH_ISSUES=()
    # shellcheck disable=SC2034  # Arrays used by render functions
    declare -ga NFTBAN_HEALTH_WARNINGS=()
    # shellcheck disable=SC2034  # Arrays used by render functions
    declare -ga NFTBAN_HEALTH_ERRORS=()

    # Load report modules (orchestrate, don't duplicate!)
    local lib_dir="${NFTBAN_LIB_DIR}"

    # Load module report
    if ! declare -f nftban_module_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_module.sh" ]]; then
            source "${lib_dir}/core/nftban_report_module.sh" 2>/dev/null || true
        fi
    fi

    # Load FHS report
    if ! declare -f nftban_fhs_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_fhs.sh" ]]; then
            source "${lib_dir}/core/nftban_report_fhs.sh" 2>/dev/null || true
        fi
    fi

    # Load distro config module for cross-distro compatibility
    if ! declare -f nftban_distro_get_service >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/lib/nftban_distro_config.sh" ]]; then
            source "${lib_dir}/lib/nftban_distro_config.sh" 2>/dev/null || true
        fi
    fi

    # Load services report
    if ! declare -f nftban_services_report_summary >/dev/null 2>&1; then
        if [[ -f "${lib_dir}/core/nftban_report_services.sh" ]]; then
            source "${lib_dir}/core/nftban_report_services.sh" 2>/dev/null || true
        fi
    fi

    return 0
}

# =============================================================================
# LOAD HEALTH CHECK LIBRARIES
# =============================================================================

# Load health check functions
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_checks.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_checks.sh" || return 1
fi

# Load health fix functions
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_fixes.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_fixes.sh" || return 1
fi

# Load health render functions
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_render.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_health_render.sh" || return 1
fi

# =============================================================================
# INSTALLATION VERIFICATION
# =============================================================================

nftban_health_verify_installation() {
    # Comprehensive installation verification
    # Returns: 0=COMPLETE, 1=INCOMPLETE (warnings), 2=BROKEN (errors)
    # Args: $1 = verbose (0=summary, 1=detailed)

    local verbose="${1:-0}"
    local status=0
    local missing_required=()
    local missing_optional=()

    echo ""
    echo "NFTBan Installation Verification"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 1. REQUIRED TIMERS
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED TIMERS"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_timers=(
        "nftban-maintenance.timer"      # CRITICAL: SSH/IP lockout prevention
        "nftban-health.timer"           # Health checks
        "nftban-core-feeds.timer"       # Threat feeds
        "nftban-core-geoip.timer"       # GeoIP updates
        "nftban-queue.timer"            # Ban queue
        "nftban-watchdog.timer"         # System monitoring
        "nftban-unified-exporter.timer" # Unified metrics export
    )

    local -A timer_desc=(
        ["nftban-maintenance.timer"]="SSH/IP lockout prevention (CRITICAL)"
        ["nftban-health.timer"]="Health checks and auto-heal"
        ["nftban-core-feeds.timer"]="Threat feeds sync"
        ["nftban-core-geoip.timer"]="GeoIP database updates"
        ["nftban-queue.timer"]="Ban queue processing"
        ["nftban-watchdog.timer"]="System resource monitoring"
        ["nftban-unified-exporter.timer"]="Unified metrics export"
    )

    local timer_ok=0
    local timer_missing=0

    for timer in "${required_timers[@]}"; do
        if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
            if systemctl is-active --quiet "$timer" 2>/dev/null; then
                printf "  ✔ %-30s ACTIVE\n" "$timer"
                timer_ok=$((timer_ok + 1))
            elif systemctl is-enabled --quiet "$timer" 2>/dev/null; then
                printf "  ⚠ %-30s ENABLED (stopped)\n" "$timer"
                timer_ok=$((timer_ok + 1))
            else
                printf "  ✖ %-30s DISABLED\n" "$timer"
                missing_required+=("Timer: $timer (${timer_desc[$timer]})")
                timer_missing=$((timer_missing + 1))
            fi
        else
            printf "  ✖ %-30s NOT INSTALLED\n" "$timer"
            missing_required+=("Timer: $timer (${timer_desc[$timer]})")
            timer_missing=$((timer_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d timers OK\n" "$timer_ok" "${#required_timers[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 2. REQUIRED SERVICES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED SERVICES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_services=(
        "nftables.service"
        "nftband.service"
    )

    local -a optional_services=(
        "nftban-login-monitor.service"
        "nftban-suricata.service"
        "nftban-ui.service"
    )

    local -a optional_binaries=(
        "/usr/lib/nftban/bin/nftban-ui"
        "/usr/lib/nftban/bin/nftban-ui-auth"
    )

    local svc_ok=0
    local svc_missing=0

    for svc in "${required_services[@]}"; do
        if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q "^$svc"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf "  ✔ %-30s ACTIVE\n" "$svc"
                svc_ok=$((svc_ok + 1))
            elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                printf "  ⚠ %-30s ENABLED (stopped)\n" "$svc"
                svc_ok=$((svc_ok + 1))
            else
                printf "  ✖ %-30s DISABLED\n" "$svc"
                missing_required+=("Service: $svc")
                svc_missing=$((svc_missing + 1))
            fi
        else
            printf "  ✖ %-30s NOT INSTALLED\n" "$svc"
            missing_required+=("Service: $svc")
            svc_missing=$((svc_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d services OK\n" "$svc_ok" "${#required_services[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 3. REQUIRED BINARIES (using distro config paths)
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED BINARIES"
    echo "───────────────────────────────────────────────────────────────"

    # Load distro config for correct paths
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" 2>/dev/null || true
        nftban_distro_load 2>/dev/null || true
    fi

    # Required binaries - check using command -v for distro independence
    local -a required_bins=(
        "nftban"
        "nft"
        "jq"
        "curl"
        "systemctl"
    # Optional binaries - reserved for future validation
    # required_bins consumed in loop below
    # shellcheck disable=SC2034
    )

    # shellcheck disable=SC2034  # Reserved for optional binary checks
    local -a optional_bins=(
        "nftban-core"
        "nftban-ui"
        "suricata"
    )

    local bin_ok=0
    local bin_missing=0
    local total_required=${#required_bins[@]}

    for name in "${required_bins[@]}"; do
        local bin_path=""

        # Try distro config path first
        if [[ -n "${DISTRO_PATHS[$name]:-}" ]] && [[ -x "${DISTRO_PATHS[$name]}" ]]; then
            bin_path="${DISTRO_PATHS[$name]}"
            printf "  ✔ %-15s OK (%s)\n" "$name" "$bin_path"
            bin_ok=$((bin_ok + 1))
        elif command -v "$name" &>/dev/null; then
            bin_path=$(command -v "$name")
            printf "  ✔ %-15s OK (%s)\n" "$name" "$bin_path"
            bin_ok=$((bin_ok + 1))
        else
            printf "  ✖ %-15s MISSING\n" "$name"
            missing_required+=("Binary: $name")
            bin_missing=$((bin_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d binaries OK\n" "$bin_ok" "$total_required"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 4. REQUIRED DIRECTORIES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED DIRECTORIES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_dirs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
        "${NFTBAN_DATA_DIR:-/var/lib/nftban}"
        "${NFTBAN_LOG_DIR:-/var/log/nftban}"
        "${NFTBAN_RUN_DIR:-/run/nftban}"
    )

    local dir_ok=0
    local dir_missing=0

    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            printf "  ✔ %-30s OK\n" "$dir"
            dir_ok=$((dir_ok + 1))
        else
            printf "  ✖ %-30s MISSING\n" "$dir"
            missing_required+=("Directory: $dir")
            dir_missing=$((dir_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d directories OK\n" "$dir_ok" "${#required_dirs[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 5. REQUIRED CONFIG FILES
    # ─────────────────────────────────────────────────────────────────────
    echo "REQUIRED CONFIG FILES"
    echo "───────────────────────────────────────────────────────────────"

    local -a required_configs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d/00-system.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/00-ssh.conf"
    )

    local cfg_ok=0
    local cfg_missing=0

    for cfg in "${required_configs[@]}"; do
        if [[ -f "$cfg" ]]; then
            printf "  ✔ %-40s OK\n" "$cfg"
            cfg_ok=$((cfg_ok + 1))
        else
            printf "  ✖ %-40s MISSING\n" "$cfg"
            missing_required+=("Config: $cfg")
            cfg_missing=$((cfg_missing + 1))
        fi
    done

    echo ""
    printf "  Summary: %d/%d config files OK\n" "$cfg_ok" "${#required_configs[@]}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────
    # 6. OPTIONAL COMPONENTS
    # ─────────────────────────────────────────────────────────────────────
    if [[ $verbose -eq 1 ]]; then
        echo "OPTIONAL COMPONENTS"
        echo "───────────────────────────────────────────────────────────────"

        for svc in "${optional_services[@]}"; do
            if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q "^$svc"; then
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    printf "  ✔ %-30s ACTIVE\n" "$svc"
                else
                    printf "  ○ %-30s INSTALLED (inactive)\n" "$svc"
                fi
            else
                printf "  ○ %-30s NOT INSTALLED\n" "$svc"
                missing_optional+=("$svc")
            fi
        done

        for bin in "${optional_binaries[@]}"; do
            if [[ -x "$bin" ]]; then
                printf "  ✔ %-30s OK\n" "$bin"
            else
                printf "  ○ %-30s NOT INSTALLED\n" "$bin"
                missing_optional+=("$bin")
            fi
        done
        echo ""
    fi

    # ─────────────────────────────────────────────────────────────────────
    # SUMMARY
    # ─────────────────────────────────────────────────────────────────────
    echo "════════════════════════════════════════════════════════════════"

    if [[ ${#missing_required[@]} -eq 0 ]]; then
        echo "✔ INSTALLATION COMPLETE"
        echo ""
        echo "All required components are installed and configured."
        status=0
    else
        echo "✖ INSTALLATION INCOMPLETE"
        echo ""
        echo "Missing required components (${#missing_required[@]}):"
        for item in "${missing_required[@]}"; do
            echo "  - $item"
        done
        echo ""
        echo "To fix, run:"
        echo "  nftban health fix"
        echo ""
        echo "Or reinstall the package."
        status=2
    fi

    if [[ ${#missing_optional[@]} -gt 0 && $verbose -eq 1 ]]; then
        echo ""
        echo "Optional components not installed (${#missing_optional[@]}):"
        for item in "${missing_optional[@]}"; do
            echo "  - $item"
        done
    fi

    echo "════════════════════════════════════════════════════════════════"
    echo ""

    return $status
}

# =============================================================================
# MAIN HEALTH CHECK FUNCTION
# =============================================================================

nftban_health_check_all() {
    # Run all health checks and collect results
    # Args: $1 = auto_heal (1 to auto-fix, 0 to just report)
    # Returns: 0=OK, 1=warnings, 2=errors

    local auto_heal="${1:-0}"
    local result=0
    local errors=0
    local warnings=0

    # Initialize health state
    nftban_health_init

    # v1.19.20 FIX: Added || true to all ((var++)) to prevent set -e failures
    # Run core checks
    nftban_health_check_binaries || { ((errors++)) || true; }
    nftban_health_check_binary_integrity || { ((errors++)) || true; }
    nftban_health_check_paths || { ((errors++)) || true; }
    nftban_health_check_permissions || { ((warnings++)) || true; }
    nftban_health_check_auditor_acls "$auto_heal" || { ((warnings++)) || true; }
    nftban_health_check_config || { ((warnings++)) || true; }
    nftban_health_check_nftban_bin || { ((errors++)) || true; }
    nftban_health_check_queue_processor "$auto_heal" || { ((errors++)) || true; }
    nftban_health_check_resources || { ((warnings++)) || true; }

    # Run security checks
    nftban_health_check_nftables_security || { ((warnings++)) || true; }
    nftban_health_check_set_sizes || { ((warnings++)) || true; }
    nftban_health_check_conflicting_firewalls || { ((warnings++)) || true; }
    nftban_health_check_ssh_port || { ((warnings++)) || true; }
    nftban_health_check_systemd_hardening || { ((warnings++)) || true; }
    nftban_health_check_memory_protection || { ((warnings++)) || true; }
    nftban_health_check_boot_safety || { ((errors++)) || true; }
    nftban_health_check_portscan_placement || { ((warnings++)) || true; }
    nftban_health_check_module_jump_placement || { ((errors++)) || true; }

    # Run service checks
    nftban_health_check_services || { ((warnings++)) || true; }
    nftban_health_check_daemon "$auto_heal" || { ((errors++)) || true; }
    nftban_health_check_timers "$auto_heal" || { ((warnings++)) || true; }
    nftban_health_check_protection || { ((warnings++)) || true; }
    nftban_health_check_maintenance_lock "$auto_heal" || { ((warnings++)) || true; }
    nftban_health_check_login_monitor_ipc || { ((errors++)) || true; }
    nftban_health_check_hung_processes "$auto_heal" || { ((warnings++)) || true; }
    nftban_health_check_suricata 2>/dev/null || { ((warnings++)) || true; }
    nftban_health_check_suricata_capture 2>/dev/null || { ((warnings++)) || true; }

    # Run structure validation checks
    nftban_health_check_fhs || { ((warnings++)) || true; }
    nftban_health_check_nft_schema || { ((errors++)) || true; }
    nftban_health_check_polkit "$auto_heal" || { ((warnings++)) || true; }
    nftban_health_check_registry || { ((warnings++)) || true; }
    nftban_health_check_cli_errors || { ((warnings++)) || true; }

    # Run optional feature checks (don't count as errors)
    nftban_health_check_modules 2>/dev/null || true
    nftban_health_check_geoip 2>/dev/null || true
    nftban_health_check_geoban 2>/dev/null || true
    nftban_health_check_rbl 2>/dev/null || true
    nftban_health_check_botguard 2>/dev/null || true
    nftban_health_check_tunnel 2>/dev/null || true
    nftban_health_check_databases 2>/dev/null || true
    nftban_health_check_metrics 2>/dev/null || true
    nftban_health_check_zabbix 2>/dev/null || true
    nftban_health_check_connectors 2>/dev/null || true
    nftban_health_check_watchdog 2>/dev/null || true
    # v1.19.20 FIX
    nftban_health_check_portscan_prefix 2>/dev/null || { ((warnings++)) || true; }
    nftban_health_check_v030_helpers 2>/dev/null || true
    nftban_health_check_bash_completion 2>/dev/null || true
    nftban_health_check_gui 2>/dev/null || true
    nftban_health_check_pro 2>/dev/null || true

    # Auto-heal if requested
    if [[ "$auto_heal" == "1" ]] && [[ $errors -gt 0 || $warnings -gt 0 ]]; then
        echo ""
        echo "Running auto-fix..."
        nftban_health_fix_permissions 2>/dev/null || true
        nftban_health_fix_directories 2>/dev/null || true
        nftban_health_fix_services 2>/dev/null || true
        nftban_health_fix_nftables 2>/dev/null || true
        nftban_health_fix_polkit 2>/dev/null || true
        nftban_health_fix_geoip 2>/dev/null || true
        nftban_health_fix_whitelist 2>/dev/null || true
        nftban_health_fix_metrics 2>/dev/null || true
    fi

    # Set return value
    if [[ $errors -gt 0 ]]; then
        result=2
    elif [[ $warnings -gt 0 ]]; then
        result=1
    fi

    # v1.24.1: Derive accurate counts from NFTBAN_HEALTH_RESULTS[] (ground truth)
    # The local errors/warnings counters only count function return codes, but many
    # check functions return 0 while setting NFTBAN_HEALTH_RESULTS[x]=2 internally.
    local derived_errors=0
    local derived_warnings=0
    local derived_total=0
    for _rk in "${!NFTBAN_HEALTH_RESULTS[@]}"; do
        derived_total=$((derived_total + 1))
        case "${NFTBAN_HEALTH_RESULTS[$_rk]}" in
            2|3) derived_errors=$((derived_errors + 1)) ;;
            1)   derived_warnings=$((derived_warnings + 1)) ;;
        esac
    done

    # Re-derive result from RESULTS[] array (not from local counters)
    if [[ $derived_errors -gt 0 ]]; then
        result=2
    elif [[ $derived_warnings -gt 0 ]]; then
        result=1
    else
        result=0
    fi

    # Store results for render functions (as scalar values, not arrays)
    export NFTBAN_HEALTH_ERROR_COUNT=$derived_errors
    export NFTBAN_HEALTH_WARNING_COUNT=$derived_warnings
    export NFTBAN_HEALTH_TOTAL_CHECKS=$derived_total

    return $result
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main functions
export -f nftban_health_init
export -f nftban_health_check_all

# Export check functions (from nftban_health_checks.sh)
export -f nftban_health_check_nftables_security
export -f nftban_health_check_conflicting_firewalls
export -f nftban_health_check_binaries
export -f nftban_health_check_binary_integrity
export -f nftban_health_check_paths
export -f nftban_health_check_permissions
export -f nftban_health_check_auditor_acls
export -f nftban_health_check_services
export -f nftban_health_check_daemon
export -f nftban_health_check_protection
export -f nftban_health_check_modules
export -f nftban_health_check_geoip
export -f nftban_health_check_geoban
export -f nftban_health_check_databases
export -f nftban_health_check_config
export -f nftban_health_check_registry
export -f nftban_health_check_metrics
export -f nftban_health_check_zabbix
export -f nftban_health_check_connectors
export -f nftban_health_check_pro
export -f nftban_health_check_rbl
export -f nftban_health_check_botguard
export -f nftban_health_check_tunnel
export -f nftban_health_check_timers
export -f nftban_health_check_gui
export -f nftban_health_check_fhs
export -f nftban_health_check_nft_schema
export -f nftban_health_check_polkit
export -f nftban_health_check_boot_safety
export -f nftban_health_should_alert

# Export fix functions (from nftban_health_fixes.sh)
export -f nftban_health_fix_permissions
export -f nftban_health_fix_directories
export -f nftban_health_fix_services
export -f nftban_health_fix_geoip
export -f nftban_health_fix_whitelist
export -f nftban_health_fix_metrics
export -f nftban_health_fix_nftables
export -f nftban_health_fix_polkit
export -f nftban_health_fix_registry

# Export render functions (from nftban_health_render.sh)
export -f nftban_health_render_terminal
export -f nftban_health_render_summary
export -f nftban_health_render_json

# Export installation verification
export -f nftban_health_verify_installation
