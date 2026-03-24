#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - System Enable/Disable CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable NFTBan system (nftables + suricata + login monitor)
#
# meta:name="cmd_system"
# meta:type="cli"
# meta:header="System Enable/Disable CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Enable or disable NFTBan system with comprehensive config validation"
# meta:input="enable|disable|restart|status command with safety checks"
# meta:output="System status, validation results, and service management"
# meta:depends="bash,systemctl,nft,service_control.sh,nftban_health.sh,nftban_firewall.sh"
#
# meta:inventory.files="service_control.sh,nftban_health.sh,nftban_firewall.sh"
# meta:inventory.binaries="systemctl,nft"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="nftban.conf"
# meta:inventory.systemd_units="nftband.service,nftables.service,suricata.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-18"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main configuration (sets readonly paths, service names)
source "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true

# Load service control library
if [[ -f "${NFTBAN_LIB_DIR}/lib/service_control.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/service_control.sh" || return 1
fi

# =============================================================================
# SYSTEM ENABLE - Check config and enable services
# =============================================================================

nftban_system_enable() {
    local target="${1:-all}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan System Enable"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    case "$target" in
        all)
            # Single source of truth: nftban_enable_all (v1.22.0)
            nftban_enable_all
            ;;
        nftables)
            echo "Enabling nftables management..."
            if declare -f _nftban_set_config &>/dev/null; then
                _nftban_set_config "NFTABLES_ENABLED" "true"
            fi
            if declare -f nftban_service_start &>/dev/null; then
                nftban_service_start "nftables"
            else
                systemctl enable nftables.service 2>/dev/null || true
                systemctl start nftables.service 2>/dev/null || true
            fi
            echo "  nftables management enabled"
            ;;
        suricata)
            echo "Enabling Suricata IDS..."
            if declare -f _nftban_set_config &>/dev/null; then
                _nftban_set_config "SURICATA_ENABLED" "true"
            fi
            if command -v suricata &>/dev/null; then
                systemctl enable suricata.service 2>/dev/null || true
                systemctl start suricata.service 2>/dev/null || true
                echo "  Suricata management enabled"
            else
                echo "  WARNING: Suricata not installed"
                echo "  Install with: nftban setup suricata"
            fi
            ;;
        login)
            echo "Enabling login monitoring..."
            # Delegate to login module
            if declare -f nftban_login_cmd_enable &>/dev/null; then
                nftban_login_cmd_enable "service"
            else
                systemctl enable "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null || true
                systemctl start "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null || true
                echo "  Login monitoring enabled"
            fi
            ;;
        timers)
            echo "Enabling all NFTBan timers..."
            _nftban_timers_control "enable"
            ;;
        help|--help|-h)
            echo "Usage: nftban enable [TARGET]"
            echo ""
            echo "Targets:"
            echo "  all       - Enable all NFTBan services (default)"
            echo "  nftables  - Enable nftables firewall management"
            echo "  suricata  - Enable Suricata IDS"
            echo "  login     - Enable login monitoring"
            echo "  timers    - Enable all maintenance timers"
            return 0
            ;;
        *)
            echo "ERROR: Unknown target: $target" >&2
            echo "" >&2
            echo "Usage: nftban enable [TARGET]" >&2
            echo "" >&2
            echo "Targets:" >&2
            echo "  all       - Enable all NFTBan services (default)" >&2
            echo "  nftables  - Enable nftables firewall management" >&2
            echo "  suricata  - Enable Suricata IDS" >&2
            echo "  login     - Enable login monitoring" >&2
            echo "  timers    - Enable all maintenance timers" >&2
            return 1
            ;;
    esac

    echo ""
    echo "Run 'nftban services status' to verify"
    return 0
}

# =============================================================================
# AUTO-WHITELIST HELPERS
# =============================================================================

# Auto-whitelist system's primary IP address
_nftban_auto_whitelist_system_ip() {
    local whitelist_dir="${NFTBAN_CONFIG_DIR}/whitelist.d"
    local whitelist_file="${whitelist_dir}/00-system-ip.conf"

    # Get primary IP (non-loopback)
    local system_ip
    system_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)

    if [[ -z "$system_ip" ]]; then
        # Fallback: get first non-loopback IP
        system_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -n "$system_ip" ]]; then
        mkdir -p "$whitelist_dir" || return 1
        if [[ ! -f "$whitelist_file" ]] || ! grep -q "$system_ip" "$whitelist_file" 2>/dev/null; then
            cat > "$whitelist_file" << EOF
# Auto-generated system IP whitelist
# Created by: nftban system enable
# Date: $(date -Iseconds)
$system_ip
EOF
            chmod 644 "$whitelist_file"
            echo "  ✅ System IP whitelisted: $system_ip"
        else
            echo "  ✅ System IP already whitelisted: $system_ip"
        fi
    else
        echo "  ⚠️  Could not detect system IP"
    fi
}

# Auto-detect SSH port from sshd_config and whitelist it
_nftban_auto_whitelist_ssh_port() {
    local ports_dir="${NFTBAN_CONFIG_DIR}/ports.d"
    local ssh_conf="${ports_dir}/00-ssh.conf"
    local sshd_config="/etc/ssh/sshd_config"
    local ssh_port="22"

    # Try to detect SSH port from sshd_config
    if [[ -f "$sshd_config" ]]; then
        local detected_port
        detected_port=$(grep -E "^Port\s+" "$sshd_config" 2>/dev/null | awk '{print $2}' | head -1 || true)
        if [[ -n "$detected_port" && "$detected_port" =~ ^[0-9]+$ ]]; then
            ssh_port="$detected_port"
        fi
    fi

    # Fallback: detect from running sshd (handles Ubuntu 24.04 socket activation
    # where sshd_config Port may not reflect the actual listening port)
    if [[ "$ssh_port" == "22" ]]; then
        local ss_port
        ss_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|"ssh"' | grep -oP ':(\d+)\s' | head -1 | tr -d ':[:space:]' || true)
        if [[ -n "$ss_port" && "$ss_port" =~ ^[0-9]+$ && "$ss_port" != "22" ]]; then
            ssh_port="$ss_port"
        fi
    fi

    mkdir -p "$ports_dir" || return 1

    # Create or update SSH port config (Go-compatible PORT/PROTOCOL/DIRECTION format)
    if [[ ! -f "$ssh_conf" ]] || ! grep -q "^${ssh_port}/" "$ssh_conf" 2>/dev/null; then
        cat > "$ssh_conf" << EOF
# Auto-generated SSH port whitelist
# Created by: nftban system enable
# Date: $(date -Iseconds)
# Detected from: $sshd_config
# Format: PORT/PROTOCOL/DIRECTION (T=TCP, I=Input)
${ssh_port}/T/I
EOF
        chmod 644 "$ssh_conf"
        echo "  ✅ SSH port whitelisted: $ssh_port/tcp"
    else
        echo "  ✅ SSH port already whitelisted: $ssh_port/tcp"
    fi
}

# =============================================================================
# SYSTEM DISABLE - Stop and disable services (EMERGENCY)
# =============================================================================

nftban_system_disable() {
    local target="${1:-}"

    # Require explicit target for safety
    if [[ -z "$target" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "NFTBan System Disable"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Usage: nftban disable <TARGET> [OPTIONS]"
        echo ""
        echo "Targets:"
        echo "  all       - EMERGENCY: Disable all NFTBan services"
        echo "  nftables  - Disable nftables management only"
        echo "  suricata  - Disable Suricata management only"
        echo "  login     - Disable login monitoring only"
        echo "  timers    - Disable all maintenance timers"
        echo ""
        echo "Options:"
        echo "  --flush-rules  Also flush nft firewall rules from kernel (with 'all' only)"
        echo ""
        echo "WARNING: 'nftban disable all' is for emergencies only!"
        echo "         Your server will be UNPROTECTED!"
        echo ""
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan System Disable"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # v1.38.0: Collect extra flags (e.g., --flush-rules) for pass-through
    shift || true
    local extra_flags=("$@")

    case "$target" in
        all)
            echo "WARNING: This will disable ALL NFTBan services!"
            local has_flush=false
            for _f in "${extra_flags[@]}"; do [[ "$_f" == "--flush-rules" ]] && has_flush=true; done
            if [[ "$has_flush" == "true" ]]; then
                echo "         Firewall rules WILL BE FLUSHED from kernel."
            else
                echo "         Firewall rules will remain active but unmanaged."
                echo "         Use --flush-rules to also remove firewall rules."
            fi
            echo ""
            read -r -p "Are you sure? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                echo "Aborted."
                return 1
            fi

            # Single source of truth: nftban_disable_all (v1.22.0)
            nftban_disable_all "${extra_flags[@]}"
            ;;
        nftables)
            echo "Disabling nftables management..."
            if declare -f _nftban_set_config &>/dev/null; then
                _nftban_set_config "NFTABLES_ENABLED" "false"
            fi
            echo "  nftables management disabled"
            echo "  Note: nftables service still running, just not managed by NFTBan"
            ;;
        suricata)
            echo "Disabling Suricata management..."
            if declare -f _nftban_set_config &>/dev/null; then
                _nftban_set_config "SURICATA_ENABLED" "false"
            fi
            systemctl stop suricata.service 2>/dev/null || true
            echo "  Suricata management disabled"
            ;;
        login)
            echo "Disabling login monitoring..."
            if declare -f nftban_login_cmd_disable &>/dev/null; then
                nftban_login_cmd_disable "service"
            else
                systemctl stop "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null || true
                systemctl disable "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null || true
                echo "  Login monitoring disabled"
            fi
            ;;
        timers)
            echo "Disabling all NFTBan timers..."
            _nftban_timers_control "disable"
            ;;
        help|--help|-h)
            echo "Usage: nftban disable [TARGET]"
            echo ""
            echo "Targets:"
            echo "  all       - Disable all NFTBan services"
            echo "  nftables  - Disable nftables firewall management"
            echo "  suricata  - Disable Suricata IDS"
            echo "  login     - Disable login monitoring"
            echo "  timers    - Disable all maintenance timers"
            return 0
            ;;
        *)
            echo "ERROR: Unknown target: $target" >&2
            echo "Use 'nftban disable help' for usage" >&2
            return 1
            ;;
    esac

    echo ""
    return 0
}

# =============================================================================
# SYSTEM RESTART - Restart services
# =============================================================================

nftban_system_restart() {
    local target="${1:-all}"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Must be root to restart services" >&2
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan System Restart"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    case "$target" in
        all)
            echo "Restarting all NFTBan services..."
            echo ""

            # Core NFTBan daemon
            echo "  Restarting nftband.service..."
            systemctl restart nftband.service 2>/dev/null || echo "    (not running)"

            # nftables
            echo "  Restarting nftables.service..."
            systemctl restart nftables.service 2>/dev/null || echo "    (not running)"

            # Suricata (if enabled)
            if declare -f nftban_service_is_enabled &>/dev/null && nftban_service_is_enabled "suricata"; then
                echo "  Restarting suricata.service..."
                systemctl restart suricata.service 2>/dev/null || echo "    (not running)"
            elif command -v suricata &>/dev/null; then
                echo "  Suricata: disabled in config (skipping)"
            fi

            # Login monitor (if active)
            if systemctl is-active --quiet "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null; then
                echo "  Restarting ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}..."
                systemctl restart "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" || true
            fi
            ;;
        nftables)
            echo "Restarting nftables..."
            systemctl restart nftables.service
            ;;
        suricata)
            echo "Restarting Suricata..."
            systemctl restart suricata.service
            ;;
        login)
            echo "Restarting login monitor..."
            systemctl restart "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
            ;;
        timers)
            echo "Restarting all NFTBan timers..."
            _nftban_timers_control "restart"
            ;;
        help|--help|-h)
            echo "Usage: nftban restart [TARGET]"
            echo ""
            echo "Targets:"
            echo "  all       - Restart all NFTBan services (default)"
            echo "  nftables  - Restart nftables service"
            echo "  suricata  - Restart Suricata IDS"
            echo "  login     - Restart login monitoring"
            echo "  timers    - Restart all maintenance timers"
            return 0
            ;;
        *)
            echo "ERROR: Unknown target: $target" >&2
            echo "Use 'nftban restart help' for usage" >&2
            return 1
            ;;
    esac

    echo ""
    echo "Done."
    return 0
}

# =============================================================================
# SERVICE STATUS - Show status of all services
# =============================================================================

nftban_system_status() {
    local json_mode="${1:-}"

    # Check for NFTBAN_JSON env var (set by cmd entry point)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        json_mode="--json"
    fi

    # Use centralized status if available
    if declare -f nftban_services_status &>/dev/null; then
        nftban_services_status "$json_mode"
        return $?
    fi

    # Check kernel kill-switch
    local kernel_disabled="false"
    if grep -q 'nftban=disabled' /proc/cmdline 2>/dev/null; then
        kernel_disabled="true"
    fi

    # Collect service statuses
    local nft_status
    nft_status=$(systemctl is-active nftables.service 2>/dev/null || echo "inactive")

    local nftban_status
    nftban_status=$(systemctl is-active nftband.service 2>/dev/null || echo "inactive")

    local suri_status="not_installed"
    local suri_installed="false"
    if command -v suricata &>/dev/null; then
        suri_installed="true"
        suri_status=$(systemctl is-active suricata.service 2>/dev/null || echo "inactive")
    fi

    local login_status
    login_status=$(systemctl is-active "${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" 2>/dev/null || echo "inactive")

    # JSON output mode
    if [[ "$json_mode" == "--json" || "$json_mode" == "-j" ]]; then
        # Collect timer statuses for JSON
        local timers_json="["
        local first_timer="true"
        local timers=(
            "nftban-maintenance.timer"
            "nftban-health.timer"
            "nftban-core-feeds.timer"
            "nftban-core-geoip.timer"
            "nftban-unified-exporter.timer"
            "nftban-watchdog.timer"
            "nftban-queue.timer"
            "nftban-rbl-check.timer"
            "nftban-suricata-update.timer"
            "nftban-snapshot.timer"
            "nftban-rollback.timer"
            "nftban-pro-inventory.timer"
            "nftban-pro-license.timer"
            "nftban-update.timer"
        )
        for timer in "${timers[@]}"; do
            if systemctl list-unit-files "$timer" &>/dev/null 2>&1; then
                local t_status t_enabled
                t_status=$(systemctl is-active "$timer" 2>/dev/null || echo "inactive")
                t_enabled=$(systemctl is-enabled "$timer" 2>/dev/null || echo "disabled")
                [[ "$first_timer" == "true" ]] || timers_json+=","
                first_timer="false"
                timers_json+="{\"name\":\"$timer\",\"status\":\"$t_status\",\"enabled\":\"$t_enabled\"}"
            fi
        done
        timers_json+="]"

        cat <<EOF
{"kernel_disabled":$kernel_disabled,"services":{"nftables":"$nft_status","nftband":"$nftban_status","suricata":"$suri_status","suricata_installed":$suri_installed,"login_monitor":"$login_status"},"timers":$timers_json}
EOF
        return 0
    fi

    # Human-readable output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Service Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$kernel_disabled" == "true" ]]; then
        echo "KERNEL: nftban=disabled (emergency kill-switch active)"
        echo ""
    fi

    echo "Services:"
    echo "  nftables:         $nft_status"
    echo "  nftband:          $nftban_status"
    if [[ "$suri_installed" == "true" ]]; then
        echo "  suricata:         $suri_status"
    else
        echo "  suricata:         not installed"
    fi
    echo "  login-monitor:    $login_status"

    echo ""
    echo "Timers:"
    _nftban_timers_status

    echo ""
}

# =============================================================================
# TIMER CONTROL HELPER
# =============================================================================

_nftban_timers_control() {
    local action="$1"

    local timers=(
        "nftban-maintenance.timer"
        "nftban-health.timer"
        "nftban-core-feeds.timer"
        "nftban-core-geoip.timer"
        "nftban-unified-exporter.timer"
        "nftban-watchdog.timer"
        "nftban-queue.timer"
        "nftban-rbl-check.timer"
        "nftban-suricata-update.timer"
        "nftban-snapshot.timer"
        "nftban-rollback.timer"
        "nftban-pro-inventory.timer"
        "nftban-pro-license.timer"
        "nftban-update.timer"
    )

    for timer in "${timers[@]}"; do
        if systemctl list-unit-files "$timer" &>/dev/null 2>&1; then
            case "$action" in
                enable)
                    systemctl enable "$timer" 2>/dev/null && systemctl start "$timer" 2>/dev/null && echo "  Enabled: $timer"
                    ;;
                disable)
                    systemctl stop "$timer" 2>/dev/null && systemctl disable "$timer" 2>/dev/null && echo "  Disabled: $timer"
                    ;;
                restart)
                    systemctl restart "$timer" 2>/dev/null && echo "  Restarted: $timer"
                    ;;
            esac
        fi
    done
}

_nftban_timers_status() {
    local timers=(
        "nftban-maintenance.timer"
        "nftban-health.timer"
        "nftban-core-feeds.timer"
        "nftban-core-geoip.timer"
        "nftban-unified-exporter.timer"
        "nftban-watchdog.timer"
        "nftban-queue.timer"
        "nftban-rbl-check.timer"
        "nftban-suricata-update.timer"
        "nftban-snapshot.timer"
        "nftban-rollback.timer"
        "nftban-pro-inventory.timer"
        "nftban-pro-license.timer"
        "nftban-update.timer"
    )

    for timer in "${timers[@]}"; do
        if systemctl list-unit-files "$timer" &>/dev/null 2>&1; then
            local status
            status=$(systemctl is-active "$timer" 2>/dev/null || echo "inactive")
            local enabled
            enabled=$(systemctl is-enabled "$timer" 2>/dev/null || echo "disabled")
            printf "  %-30s %s (%s)\n" "$timer" "$status" "$enabled"
        fi
    done
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_system() {
    local action="${1:-}"

    # Check for --json flag and export for submodules
    for arg in "$@"; do
        if [[ "$arg" == "--json" || "$arg" == "-j" ]]; then
            export NFTBAN_JSON="true"
        fi
    done

    # Show banner if available (skip in JSON mode)
    if [[ "${NFTBAN_JSON:-}" != "true" ]] && [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if declare -f nftban_banner &>/dev/null; then
            nftban_banner 2>/dev/null || true
        fi
    fi

    case "$action" in
        enable)
            shift
            nftban_system_enable "$@"
            ;;
        disable)
            shift
            nftban_system_disable "$@"
            ;;
        restart)
            shift
            nftban_system_restart "$@"
            ;;
        status|services)
            shift
            nftban_system_status "$@"
            ;;
        help|--help|-h)
            _nftban_system_help
            ;;
        *)
            _nftban_system_help
            return 1
            ;;
    esac
}

_nftban_system_help() {
    cat <<'EOF'
NFTBan Service Control

USAGE:
    nftban enable [TARGET]         Enable NFTBan services
    nftban disable [TARGET]        Disable NFTBan services
    nftban restart [TARGET]        Restart NFTBan services
    nftban services status [--json] Show service status

OPTIONS:
    --json, -j    Output in JSON format (machine-readable)

TARGETS:
    all       - All NFTBan services (default for enable/restart)
    nftables  - nftables firewall management
    suricata  - Suricata IDS
    login     - Login monitoring
    timers    - Maintenance timers

EXAMPLES:
    # Enable everything
    sudo nftban enable

    # Disable Suricata only
    sudo nftban disable suricata

    # Restart all services
    sudo nftban restart

    # Check status
    nftban services status

    # Check status (JSON for scripts/automation)
    nftban services status --json

    # EMERGENCY: Disable all NFTBan
    sudo nftban disable all

CONFIGURATION:
    ${NFTBAN_CONFIG_DIR}/conf.d/services.conf        - Service settings
    ${NFTBAN_CONFIG_DIR}/conf.d/services.conf.local  - User overrides

    Edit services.conf.local instead of services.conf to preserve
    settings across package updates.

KERNEL EMERGENCY DISABLE:
    Add 'nftban=disabled' to kernel command line at boot to
    completely bypass NFTBan (useful for recovery).

    At GRUB menu:
    1. Press 'e' to edit boot entry
    2. Add 'nftban=disabled' to kernel line
    3. Press Ctrl+X to boot

See also: nftban login help
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_system
export -f nftban_system_enable
export -f nftban_system_disable
export -f nftban_system_restart
export -f nftban_system_status

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
# =============================================================================
