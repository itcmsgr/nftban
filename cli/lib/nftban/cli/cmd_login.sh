#!/usr/bin/env bash
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_DATA_DIR:-}" ]] && readonly NFTBAN_DATA_DIR="/var/lib/nftban"

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" || return 1
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load distro config for dynamic paths (DISTRO_PATHS[systemd_system])
# shellcheck source=/dev/null
if [[ -z "${NFTBAN_DISTRO_CONFIG_LOADED:-}" ]] && [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# NFTBan v1.0.0 - Login Alert CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Provides CLI interface for login monitoring and alerting
#
# meta:name="cmd_login"
# meta:type="cli"
# meta:header="Login Alert CLI Handler"
# meta:version="1.48.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI commands for login monitoring and alerting"
# meta:input="CLI arguments"
# meta:output="Status messages and service control"
# meta:depends="nftban_login_alert.sh,systemctl"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-15"
#
# meta:inventory.files="nftban_login_alert.sh,json_output.sh"
# meta:inventory.binaries="systemctl,journalctl"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_SERVICE_LOGIN_MONITOR"
# meta:inventory.config_files="/etc/nftban/conf.d/login_alert.conf,/etc/nftban/conf.d/login_alert.conf.local"
# meta:inventory.systemd_units="nftban-login-monitor.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================


# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_LOGIN_CLI_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_CLI_LOADED=1

# =============================================================================

# DEPENDENCIES
# =============================================================================


# Load login alert module (for alert functions)
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" || return 1
else
    echo "ERROR: Login alert module not found at ${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" >&2
    return 1
fi

# Load main login module (for multi-service detection: SSH, Dovecot, Postfix, Exim)
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_login.sh" || return 1
fi

# =============================================================================

# CLI COMMANDS
# =============================================================================


nftban_login_cmd_status() {
    # Show login monitoring status
    # Show unified banner
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "login"
        echo ""
    fi
    echo "NFTBan Login Alert Status"
    echo "========================="
    echo ""

    # Check configuration
    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"

    if [[ -f "$config_file" ]] || [[ -f "$config_local" ]]; then
        if [[ -f "$config_local" ]]; then
            echo "✅ Configuration: $config_local (user overrides)"
        else
            echo "✅ Configuration: $config_file"
        fi
    else
        echo "❌ Configuration: NOT CONFIGURED"
        echo ""
        echo "Login alert monitoring is not set up yet."
        echo ""
        echo "📋 Quick Setup:"
        echo ""
        echo "    nftban login enable"
        echo ""
        echo "This will install and start login monitoring with SSH alerts."
        echo ""
        return 0
    fi

    # Check module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]]; then
        echo "✅ Core Module: Installed"
    else
        echo "❌ Core Module: NOT FOUND"
        return 1
    fi

    # v1.48.0: Check nftband daemon (loginmon module), not removed bash service
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        echo "✅ Daemon: nftband running (loginmon module active)"
    else
        echo "⚠️  Daemon: nftband not running (login monitoring inactive)"
        echo "   Start with: systemctl start nftband"
    fi

    echo ""
    echo "Configuration:"
    echo "  Enabled: ${NFTBAN_LOGIN_ALERT_ENABLED:-false}"
    echo "  Email: ${NFTBAN_MAIL_RECIPIENT:-(not set)}"
    echo "  Format: ${NFTBAN_LOGIN_ALERT_FORMAT:-text}"
    echo "  Mode: ${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
    echo "  GeoIP: ${NFTBAN_LOGIN_ALERT_GEOIP:-false}"
    echo ""
    echo "Monitoring:"
    echo "  SSH: ${NFTBAN_LOGIN_ALERT_SSH:-false}"
    echo "  SU: ${NFTBAN_LOGIN_ALERT_SU:-false}"
    echo "  SUDO: ${NFTBAN_LOGIN_ALERT_SUDO:-false}"
    echo "  Console: ${NFTBAN_LOGIN_ALERT_CONSOLE:-false}"

    # Show detected mail services (if main login module loaded)
    if declare -f nftban_login_init &>/dev/null; then
        nftban_login_init 2>/dev/null || true
        echo ""
        echo "Mail Services (auto-detected):"
        for svc in dovecot postfix exim; do
            if nftban_login_service_detected "$svc" 2>/dev/null; then
                echo "  $svc: ✅ detected"
            else
                echo "  $svc: ⚪ not installed"
            fi
        done
        echo ""
        echo "Active Mode: ${_LOGIN_ACTIVE_MODE:-classic}"
    fi

    echo ""
    echo "Failed Attempts:"
    echo "  Alert on Failed: ${NFTBAN_LOGIN_ALERT_FAILED:-false}"
    echo "  Threshold: ${NFTBAN_LOGIN_FAILED_THRESHOLD:-5} attempts"
    echo "  Time Window: ${NFTBAN_LOGIN_FAILED_WINDOW:-300} seconds"
    echo ""

    # Check log file
    local log_file="${NFTBAN_LOGIN_ALERT_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/login_alerts.log}"
    if [[ -f "$log_file" ]]; then
        local lines
        lines=$(wc -l < "$log_file")
        echo "Log File: $log_file ($lines lines)"
    else
        echo "Log File: $log_file (not created yet)"
    fi
}

# JSON-aware status function
_nftban_login_cmd_status_json() {
    local json_mode="${1:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local config_file="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
        local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"
        local config_exists="false"
        local module_exists="false"
        local service_status="not_installed"
        local log_lines=0

        [[ -f "$config_file" ]] || [[ -f "$config_local" ]] && config_exists="true"
        [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]] && module_exists="true"

        # v1.48.0: Check nftband daemon, not removed bash service
        if systemctl is-active --quiet nftband.service 2>/dev/null; then
            service_status="running"
        fi

        if [[ -f "$NFTBAN_LOGIN_ALERT_LOG" ]]; then
            log_lines=$(wc -l < "$NFTBAN_LOGIN_ALERT_LOG" 2>/dev/null || echo "0")
        fi

        local data
        if command -v jq &>/dev/null; then
            # Use default values for config variables if they're not set
            data=$(jq -n \
                --arg config_exists "$config_exists" \
                --arg module_exists "$module_exists" \
                --arg service_status "$service_status" \
                --arg enabled "${NFTBAN_LOGIN_ALERT_ENABLED:-false}" \
                --arg email "${NFTBAN_LOGIN_ALERT_EMAIL:-}" \
                --arg format "${NFTBAN_LOGIN_ALERT_FORMAT:-text}" \
                --arg geoip "${NFTBAN_LOGIN_ALERT_GEOIP:-false}" \
                --arg ssh "${NFTBAN_LOGIN_ALERT_SSH:-false}" \
                --arg su "${NFTBAN_LOGIN_ALERT_SU:-false}" \
                --arg sudo "${NFTBAN_LOGIN_ALERT_SUDO:-false}" \
                --arg console "${NFTBAN_LOGIN_ALERT_CONSOLE:-false}" \
                --arg alert_failed "${NFTBAN_LOGIN_ALERT_FAILED:-false}" \
                --arg threshold "${NFTBAN_LOGIN_FAILED_THRESHOLD:-5}" \
                --arg window "${NFTBAN_LOGIN_FAILED_WINDOW:-300}" \
                --arg log_lines "$log_lines" \
                '{
                    config_exists: ($config_exists == "true"),
                    module_exists: ($module_exists == "true"),
                    service_status: $service_status,
                    config: {
                        enabled: ($enabled == "true"),
                        email: $email,
                        format: $format,
                        geoip: ($geoip == "true")
                    },
                    monitoring: {
                        ssh: ($ssh == "true"),
                        su: ($su == "true"),
                        sudo: ($sudo == "true"),
                        console: ($console == "true")
                    },
                    failed_attempts: {
                        alert_on_failed: ($alert_failed == "true"),
                        threshold: ($threshold | tonumber),
                        window_seconds: ($window | tonumber)
                    },
                    log_lines: ($log_lines | tonumber)
                }')
        else
            # Fallback for systems without jq - use default values
            local enabled="${NFTBAN_LOGIN_ALERT_ENABLED:-false}"
            local threshold="${NFTBAN_LOGIN_FAILED_THRESHOLD:-5}"
            data="{\"config_exists\":$config_exists,\"module_exists\":$module_exists,\"service_status\":\"$service_status\",\"enabled\":$enabled,\"log_lines\":$log_lines,\"threshold\":$threshold}"
        fi

        json_output "true" "$data"
        return 0
    fi

    nftban_login_cmd_status
}

nftban_login_cmd_install() {
    # v1.48.0: Login monitoring is handled by the Go daemon (nftband) loginmon module
    # The standalone nftban-login-monitor.service was removed in v1.23.0

    echo "NFTBan Login Monitor"
    echo "===================="
    echo ""
    echo "Login monitoring is built into the nftband daemon (loginmon module)."
    echo "No separate service installation is needed."
    echo ""

    # Check if daemon is running
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        echo "✅ nftband daemon is running (loginmon module active)"
    else
        echo "⚠️  nftband daemon is not running"
        echo "   Start it with: systemctl start nftband"
    fi

    echo ""
    echo "To configure login monitoring:"
    echo "  nftban login enable       Enable login alerts"
    echo "  nftban login status       Check monitoring status"
    echo ""
    echo "Configuration: /etc/nftban/conf.d/login/main.conf"
}

nftban_login_cmd_enable() {
    # Enable monitoring for specific type or service
    # Usage: nftban login enable [ssh|su|sudo|console|service|all]

    local target="${1:-}"
    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Requires root privileges" >&2
        return 1
    fi

    # Check mail prerequisites (non-blocking — alerts still log without MTA)
    if declare -F nftban_prereq_check_mail >/dev/null 2>&1; then
        nftban_prereq_check_mail
        if ! nftban_prereq_satisfied; then
            echo "  [INFO] Email alerts require a mail transport agent"
            nftban_prereq_report || true
            echo "  Continuing — login monitoring will log events even without email."
            echo ""
        fi
    fi

    # Ensure local config exists
    if [[ ! -f "$config_local" ]]; then
        mkdir -p "$(dirname "$config_local")" || return 1
        echo "# NFTBan Login Alert - User Overrides" > "$config_local"
        echo "# This file overrides defaults from login_alert.conf" >> "$config_local"
        chmod 640 "$config_local"
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    case "$target" in
        ssh)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "true" "$config_local"
            echo "✅ SSH login monitoring enabled"
            ;;
        su)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SU" "true" "$config_local"
            echo "✅ SU login monitoring enabled"
            ;;
        sudo)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SUDO" "true" "$config_local"
            echo "✅ SUDO monitoring enabled"
            ;;
        console)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_CONSOLE" "true" "$config_local"
            echo "✅ Console login monitoring enabled"
            ;;
        all)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "true" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "true" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SU" "true" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SUDO" "true" "$config_local"
            echo "✅ All login monitoring enabled (ssh, su, sudo)"
            ;;
        service|"")
            # v1.48.0: Login monitoring handled by nftband daemon loginmon module
            # Enable config + ensure daemon is running (no separate service needed)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "true" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "true" "$config_local"

            # Also set LOGIN_ENABLED=true for Go daemon loginmon module
            local login_main_local="${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf.local"
            if [[ ! -f "$login_main_local" ]]; then
                mkdir -p "$(dirname "$login_main_local")" || true
                echo "# NFTBan Login Monitor - User Overrides" > "$login_main_local"
                chmod 640 "$login_main_local"
                chown root:nftban "$login_main_local" 2>/dev/null || true
            fi
            _nftban_login_set_config "LOGIN_ENABLED" "true" "$login_main_local"

            # Check if nftband daemon is running (it contains the loginmon module)
            if systemctl is-active --quiet nftband.service 2>/dev/null; then
                echo "✅ Login monitoring enabled (nftband daemon loginmon module active)"
                echo ""
                echo "  Detected services are monitored automatically:"
                echo "  - SSH (journalctl)"
                echo "  - DirectAdmin, cPanel, Plesk (file watchers)"
                echo "  - Dovecot, Postfix, Exim (journalctl)"
                echo ""
                echo "  Reload daemon to pick up config changes:"
                echo "    systemctl reload nftband 2>/dev/null || systemctl restart nftband"
            else
                echo "⚠️  Login monitoring configured but nftband daemon is not running"
                echo ""
                echo "  Start the daemon:"
                echo "    systemctl start nftband"
            fi
            ;;
        *)
            echo "ERROR: Unknown target: $target" >&2
            echo "Usage: nftban login enable [ssh|su|sudo|console|service|all]" >&2
            return 1
            ;;
    esac
}

nftban_login_cmd_disable() {
    # Disable monitoring for specific type or service
    # Usage: nftban login disable [ssh|su|sudo|console|service|all]

    local target="${1:-}"
    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Requires root privileges" >&2
        return 1
    fi

    # Ensure local config exists
    if [[ ! -f "$config_local" ]]; then
        mkdir -p "$(dirname "$config_local")" || return 1
        echo "# NFTBan Login Alert - User Overrides" > "$config_local"
        chmod 640 "$config_local"
        chown root:nftban "$config_local" 2>/dev/null || true
    fi

    case "$target" in
        ssh)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "false" "$config_local"
            echo "✅ SSH login monitoring disabled"
            ;;
        su)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SU" "false" "$config_local"
            echo "✅ SU login monitoring disabled"
            ;;
        sudo)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SUDO" "false" "$config_local"
            echo "✅ SUDO monitoring disabled"
            ;;
        console)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_CONSOLE" "false" "$config_local"
            echo "✅ Console login monitoring disabled"
            ;;
        all)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "false" "$config_local"
            echo "✅ All login monitoring disabled"
            ;;
        service|"")
            # v1.48.0: Disable login monitoring in config (daemon picks up on reload)
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "false" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "false" "$config_local"

            # Also disable in Go daemon loginmon config
            local login_main_local="${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf.local"
            if [[ -f "$login_main_local" ]]; then
                _nftban_login_set_config "LOGIN_ENABLED" "false" "$login_main_local"
            fi

            # Clean up legacy service if still present
            local service_name="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
            systemctl stop "${service_name}" 2>/dev/null || true
            systemctl disable "${service_name}" 2>/dev/null || true
            echo "✅ Login monitoring disabled"
            ;;
        *)
            echo "ERROR: Unknown target: $target" >&2
            echo "Usage: nftban login disable [ssh|su|sudo|console|service|all]" >&2
            return 1
            ;;
    esac
}

_nftban_login_set_config() {
    # Helper: Set config value in local override file
    local key="$1"
    local value="$2"
    local file="$3"

    # Ensure file exists and has correct permissions
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")" || return 1
        touch "$file"
        chmod 640 "$file"
        chown root:nftban "$file" 2>/dev/null || true
    fi

    # Write with quotes for consistency with base config
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

nftban_login_cmd_logs() {
    # Show login alert logs
    local lines="${1:-50}"

    echo "NFTBan Login Alert Logs (last $lines lines)"
    echo "==========================================="
    echo ""

    if [[ -f "$NFTBAN_LOGIN_ALERT_LOG" ]]; then
        tail -n "$lines" "$NFTBAN_LOGIN_ALERT_LOG"
    else
        echo "No log file found at: $NFTBAN_LOGIN_ALERT_LOG"
    fi

    echo ""
    echo "Daemon logs (last $lines lines):"
    echo "================================="
    journalctl -u nftband.service -n "$lines" --no-pager 2>/dev/null || echo "Daemon not running"
}

nftban_login_cmd_test() {
    # Test login alert system
    nftban_login_test
}

nftban_login_cmd_run() {
    # Run login monitoring (for service)
    # Uses consolidated login module for multi-service detection

    # Normalize boolean value (accepts true/TRUE/yes/YES/1/on/ON)
    local alert_enabled
    if declare -f nftban_normalize_boolean >/dev/null 2>&1; then
        alert_enabled="$(nftban_normalize_boolean "$NFTBAN_LOGIN_ALERT_ENABLED")"
    else
        # Local fallback normalization
        local val="${NFTBAN_LOGIN_ALERT_ENABLED,,}"  # lowercase
        case "$val" in
            true|yes|1|on) alert_enabled="true" ;;
            *) alert_enabled="false" ;;
        esac
    fi

    if [[ "$alert_enabled" != "true" ]]; then
        echo "ERROR: Login alerts are disabled in configuration" >&2
        return 1
    fi

    # Use consolidated login module (SSH + mail services)
    if declare -f nftban_login_start &>/dev/null; then
        # Initialize and detect services
        nftban_login_init || {
            echo "ERROR: Failed to initialize login module" >&2
            return 1
        }

        # Build detected services list for banner
        local detected_services=""
        local all_services="ssh dovecot exim postfix apache nginx pureftpd vsftpd proftpd directadmin cpanel plesk"
        for svc in $all_services; do
            if nftban_login_service_detected "$svc" 2>/dev/null; then
                [[ -n "$detected_services" ]] && detected_services+=" "
                detected_services+="$svc"
            fi
        done
        [[ -z "$detected_services" ]] && detected_services="ssh"

        # Startup banner for debugging
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] NFTBan Login Monitor starting"
        echo "[$timestamp] Mode: ${_LOGIN_ACTIVE_MODE:-classic}"
        echo "[$timestamp] Services detected: $detected_services"
        logger -t nftban-login-monitor "Started: mode=${_LOGIN_ACTIVE_MODE:-classic} detected=$detected_services" 2>/dev/null || true

        # Start consolidated monitoring (SSH + Dovecot + Postfix + Exim)
        nftban_login_start
    else
        # Fallback to alert-only mode if main module not loaded
        echo "WARNING: Main login module not loaded, using alert-only mode (SSH only)" >&2
        logger -t nftban-login-monitor "Started: mode=alert-only (SSH only)" 2>/dev/null || true
        nftban_login_monitor_all
    fi
}

nftban_login_cmd_stats() {
    # Show login statistics for Prometheus/metrics
    local log_file="$NFTBAN_LOGIN_ALERT_LOG"
    local total_events=0
    local success_events=0
    local failed_events=0
    local today_events=0
    local today
    today=$(date '+%Y-%m-%d')

    if [[ -f "$log_file" ]]; then
        total_events=$(wc -l < "$log_file" 2>/dev/null)
        total_events=${total_events:-0}
        success_events=$(grep -c "SUCCESS" "$log_file" 2>/dev/null) || success_events=0
        failed_events=$(grep -c "FAILED" "$log_file" 2>/dev/null) || failed_events=0
        today_events=$(grep -c "\[$today" "$log_file" 2>/dev/null) || today_events=0
    fi

    echo "NFTBan Login Statistics"
    echo "======================="
    echo ""
    echo "Total Events: $total_events"
    echo "  Successful: $success_events"
    echo "  Failed:     $failed_events"
    echo "  Today:      $today_events"
    echo ""

    # Daemon uptime (v1.48.0: use nftband, not removed service)
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        local uptime
        uptime=$(systemctl show nftband.service --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        echo "Daemon Started: $uptime"
    fi
}

# JSON-aware stats function
_nftban_login_cmd_stats_json() {
    local json_mode="${1:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local log_file="$NFTBAN_LOGIN_ALERT_LOG"
        local total_events=0
        local success_events=0
        local failed_events=0
        local today_events=0
        local today
        today=$(date '+%Y-%m-%d')
        local service_running="false"
        local service_uptime=""

        if [[ -f "$log_file" ]]; then
            total_events=$(wc -l < "$log_file" 2>/dev/null)
            total_events=${total_events:-0}
            success_events=$(grep -c "SUCCESS" "$log_file" 2>/dev/null) || success_events=0
            failed_events=$(grep -c "FAILED" "$log_file" 2>/dev/null) || failed_events=0
            today_events=$(grep -c "\[$today" "$log_file" 2>/dev/null) || today_events=0
        fi

        # v1.48.0: Check nftband daemon, not removed service
        if systemctl is-active --quiet nftband.service 2>/dev/null; then
            service_running="true"
            service_uptime=$(systemctl show nftband.service --property=ActiveEnterTimestamp --value 2>/dev/null) || service_uptime=""
        fi

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg total "$total_events" \
                --arg success "$success_events" \
                --arg failed "$failed_events" \
                --arg today "$today_events" \
                --arg running "$service_running" \
                --arg uptime "$service_uptime" \
                '{
                    events: {
                        total: ($total | tonumber),
                        success: ($success | tonumber),
                        failed: ($failed | tonumber),
                        today: ($today | tonumber)
                    },
                    service: {
                        running: ($running == "true"),
                        uptime: $uptime
                    }
                }')
        else
            data="{\"total\":$total_events,\"success\":$success_events,\"failed\":$failed_events,\"today\":$today_events,\"service_running\":$service_running}"
        fi

        json_output "true" "$data"
        return 0
    fi

    nftban_login_cmd_stats
}

nftban_login_cmd_health_fix() {
    # Check and auto-fix login monitor issues

    echo "NFTBan Login Monitor Health Check"
    echo "=================================="
    echo ""

    local issues_found=0
    local issues_fixed=0

    # 1. Check config file exists
    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
    if [[ ! -f "$config_file" ]]; then
        echo "❌ Configuration file missing: $config_file"
        # v1.19.20 FIX
        ((issues_found++)) || true

        if [[ $EUID -eq 0 ]]; then
            echo "   Creating default configuration..."
            mkdir -p "$(dirname "$config_file")" || return 1
            cat > "$config_file" <<'CONF'
# NFTBan Login Alert Configuration
# =============================================================================
# NOTE: Email recipient is configured globally in /etc/nftban/conf.d/mail.conf
#       using NFTBAN_MAIL_RECIPIENT - no need to configure email here!
#
# To override any setting, create /etc/nftban/conf.d/login_alert.conf.local
# and set your custom values there (they will override these defaults).
# =============================================================================

# Enable/disable login monitoring (master switch)
NFTBAN_LOGIN_ALERT_ENABLED=false

# What to monitor (all disabled by default - enable via CLI)
# Use: nftban login enable ssh|su|sudo|console
NFTBAN_LOGIN_ALERT_SSH=false
NFTBAN_LOGIN_ALERT_SU=false
NFTBAN_LOGIN_ALERT_SUDO=false
NFTBAN_LOGIN_ALERT_CONSOLE=false

# GeoIP enrichment (adds location info to alerts)
NFTBAN_LOGIN_ALERT_GEOIP=true

# Alert format: html or text
NFTBAN_LOGIN_ALERT_FORMAT=html

# Log file location
NFTBAN_LOGIN_ALERT_LOG=${NFTBAN_LOG_DIR:-/var/log/nftban}/login_alert.log

# Monitor interval (seconds)
NFTBAN_LOGIN_MONITOR_INTERVAL=5

# IP whitelist (space-separated, these IPs won't trigger alerts)
NFTBAN_LOGIN_WHITELIST=

# Failed login tracking
NFTBAN_LOGIN_ALERT_FAILED=true
NFTBAN_LOGIN_FAILED_THRESHOLD=9
NFTBAN_LOGIN_FAILED_WINDOW=300
CONF
            chmod 640 "$config_file"
            chown root:nftban "$config_file" 2>/dev/null || true
            echo "   ✅ Created default configuration"
            # v1.19.20 FIX
            ((issues_fixed++)) || true
        fi
    else
        echo "✅ Configuration file exists"
    fi

    # 2. Check log directory (atomic creation avoids TOCTOU race)
    local log_dir
    log_dir=$(dirname "$NFTBAN_LOGIN_ALERT_LOG")
    if [[ $EUID -eq 0 ]]; then
        # Try atomic creation - if it already exists, mkdir -p succeeds silently
        if mkdir -p "$log_dir" 2>/dev/null; then
            chown nftban:nftban "$log_dir" 2>/dev/null || true
            chmod 750 "$log_dir" 2>/dev/null || true
        fi
    fi
    if [[ ! -d "$log_dir" ]]; then
        echo "X Log directory missing: $log_dir"
        # v1.19.20 FIX
        ((issues_found++)) || true
    else
        echo "✅ Log directory exists"
    fi

    # 3. Check nftband daemon (loginmon module) — replaces removed bash service
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        echo "✅ nftband daemon running (loginmon module active)"
    else
        echo "❌ nftband daemon not running (login monitoring inactive)"
        ((issues_found++)) || true

        if [[ $EUID -eq 0 ]]; then
            echo "   Attempting to start nftband..."
            if systemctl start nftband.service 2>/dev/null; then
                echo "   ✅ nftband started"
                ((issues_fixed++)) || true
            else
                echo "   ❌ Failed to start nftband"
            fi
        fi
    fi

    # Clean up legacy bash service if still lingering
    if systemctl is-enabled --quiet nftban-login-monitor.service 2>/dev/null; then
        echo "⚠️  Legacy nftban-login-monitor.service still enabled (removed in v1.23.0)"
        if [[ $EUID -eq 0 ]]; then
            systemctl disable --now nftban-login-monitor.service 2>/dev/null || true
            echo "   ✅ Legacy service disabled"
        fi
    fi

    # 5. Check core module
    if [[ ! -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]]; then
        echo "❌ Core module not installed"
        # v1.19.20 FIX
        ((issues_found++)) || true
    else
        echo "✅ Core module installed"
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────"
    echo "Issues found:  $issues_found"
    echo "Issues fixed:  $issues_fixed"

    if [[ $issues_found -gt $issues_fixed ]]; then
        echo ""
        echo "Some issues require manual attention or root privileges."
        return 1
    elif [[ $issues_found -eq 0 ]]; then
        echo ""
        echo "✅ Login monitor: OK (no issues)"
    fi

    return 0
}

nftban_login_cmd_restart() {
    # v1.48.0: Restart nftband daemon (loginmon module), not removed bash service

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service management requires root privileges" >&2
        return 1
    fi

    echo "Restarting NFTBan Login Monitor (nftband daemon)"
    echo "================================================="
    echo ""

    if ! systemctl is-active --quiet nftband.service 2>/dev/null && \
       ! systemctl is-enabled --quiet nftband.service 2>/dev/null; then
        echo "ERROR: nftband daemon not installed." >&2
        echo "Login monitoring requires the nftband daemon." >&2
        return 1
    fi

    echo "Restarting nftband daemon..."
    systemctl restart nftband.service
    echo "✅ nftband restarted (loginmon module will reinitialize)"
    echo ""

    systemctl status nftband.service --no-pager -l 2>/dev/null | head -20
}

nftban_login_cmd_mode() {
    # Set login alert email mode: realtime, digest, or both
    # Usage: nftban login mode <realtime|digest|both>

    local mode="${1:-}"

    if [[ -z "$mode" ]]; then
        # Show current mode
        local current_mode="${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
        local digest_time="${NFTBAN_LOGIN_DIGEST_TIME:-08:00}"
        local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR}/login_digest.json}"
        local digest_count=0

        if [[ -f "$digest_file" ]] && command -v jq &>/dev/null; then
            digest_count=$(jq 'length' "$digest_file" 2>/dev/null || echo "0")
        fi

        echo "Login Alert Email Mode"
        echo "======================"
        echo ""
        echo "Current Mode: $current_mode"
        echo ""
        echo "Modes:"
        echo "  realtime  - Send email immediately on each trigger"
        echo "  digest    - Collect alerts and send daily summary only"
        echo "  both      - Send realtime alerts AND include in daily digest"
        echo ""
        echo "Digest Settings:"
        echo "  Schedule: Daily at $digest_time (with daily report)"
        echo "  File: $digest_file"
        echo "  Pending alerts: $digest_count"
        echo ""
        echo "Usage: nftban login mode <realtime|digest|both>"
        return 0
    fi

    # Validate mode
    case "$mode" in
        realtime|digest|both)
            ;;
        *)
            echo "ERROR: Invalid mode: $mode" >&2
            echo "Valid modes: realtime, digest, both" >&2
            return 1
            ;;
    esac

    # Set the mode in local config file
    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"
    _nftban_login_set_config "NFTBAN_LOGIN_ALERT_MODE" "$mode" "$config_local"

    echo "✅ Login alert mode set to: $mode"
    echo ""

    case "$mode" in
        realtime)
            echo "Emails will be sent immediately when alerts are triggered."
            ;;
        digest)
            echo "Alerts will be collected and sent as a daily digest."
            echo "Digest is sent with the daily report (nftban report run daily)."
            ;;
        both)
            echo "Realtime emails will be sent AND alerts included in daily digest."
            ;;
    esac

    # Restart daemon if running (to pick up config change)
    if systemctl is-active --quiet nftband.service 2>/dev/null; then
        echo ""
        echo "Restarting nftband daemon..."
        systemctl restart nftband.service 2>/dev/null || true
        echo "✅ Daemon restarted"
    fi
}

nftban_login_cmd_digest() {
    # Manage login digest
    # Usage: nftban login digest <status|send|clear>

    local action="${1:-status}"

    case "$action" in
        status)
            local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR}/login_digest.json}"
            local count=0

            if [[ -f "$digest_file" ]] && command -v jq &>/dev/null; then
                count=$(jq 'length' "$digest_file" 2>/dev/null || echo "0")
            fi

            echo "Login Digest Status"
            echo "==================="
            echo ""
            echo "File: $digest_file"
            echo "Pending alerts: $count"
            echo ""

            if [[ "$count" -gt 0 ]] && command -v jq &>/dev/null; then
                echo "Recent alerts:"
                jq -r '.[-5:] | .[] | "  [\(.timestamp)] \(.user)@\(.ip) - \(.status)"' "$digest_file" 2>/dev/null || true
            fi
            ;;
        send)
            echo "Sending login digest..."
            if type -t nftban_login_digest_send >/dev/null 2>&1; then
                nftban_login_digest_send
            else
                echo "ERROR: Digest send function not available" >&2
                return 1
            fi
            ;;
        clear)
            echo "Clearing login digest..."
            if type -t nftban_login_digest_clear >/dev/null 2>&1; then
                nftban_login_digest_clear
                echo "✅ Digest cleared"
            else
                local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR}/login_digest.json}"
                echo "[]" > "$digest_file"
                echo "✅ Digest cleared"
            fi
            ;;
        *)
            echo "ERROR: Unknown action: $action" >&2
            echo "Usage: nftban login digest <status|send|clear>" >&2
            return 1
            ;;
    esac
}

nftban_login_cmd_config() {
    # Show login module configuration
    local json_mode="${1:-false}"
    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
    local config_local="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local active_file="$config_file"
        [[ -f "$config_local" ]] && active_file="$config_local"

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg active_file "$active_file" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg enabled "${NFTBAN_LOGIN_ALERT_ENABLED:-false}" \
                --arg email "${NFTBAN_MAIL_RECIPIENT:-}" \
                --arg format "${NFTBAN_LOGIN_ALERT_FORMAT:-text}" \
                --arg mode "${NFTBAN_LOGIN_ALERT_MODE:-realtime}" \
                --arg geoip "${NFTBAN_LOGIN_ALERT_GEOIP:-false}" \
                --arg ssh "${NFTBAN_LOGIN_ALERT_SSH:-false}" \
                --arg threshold "${NFTBAN_LOGIN_FAILED_THRESHOLD:-5}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    active_file: $active_file,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        enabled: ($enabled == "true"),
                        email: $email,
                        format: $format,
                        mode: $mode,
                        geoip: ($geoip == "true"),
                        ssh: ($ssh == "true"),
                        threshold: ($threshold | tonumber)
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\",\"enabled\":${NFTBAN_LOGIN_ALERT_ENABLED:-false}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Human-readable output
    echo "Login Alert Configuration"
    echo "========================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Current Settings:"
    echo "  Enabled:        ${NFTBAN_LOGIN_ALERT_ENABLED:-false}"
    echo "  Email:          ${NFTBAN_MAIL_RECIPIENT:-(not set)}"
    echo "  Format:         ${NFTBAN_LOGIN_ALERT_FORMAT:-text}"
    echo "  Mode:           ${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
    echo "  GeoIP:          ${NFTBAN_LOGIN_ALERT_GEOIP:-false}"
    echo ""
    echo "Monitoring:"
    echo "  SSH:            ${NFTBAN_LOGIN_ALERT_SSH:-false}"
    echo "  SU:             ${NFTBAN_LOGIN_ALERT_SU:-false}"
    echo "  SUDO:           ${NFTBAN_LOGIN_ALERT_SUDO:-false}"
    echo "  Console:        ${NFTBAN_LOGIN_ALERT_CONSOLE:-false}"
    echo ""
    echo "Failed Login Threshold: ${NFTBAN_LOGIN_FAILED_THRESHOLD:-5} attempts in ${NFTBAN_LOGIN_FAILED_WINDOW:-300}s"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

nftban_login_cmd_help() {
    # Show help
    nftban_banner "login"
    echo ""

    cat <<EOF
NFTBan Login Alert - Monitor and Alert on System Logins

USAGE:
    nftban login <command> [options]

COMMANDS:
    status [--json]     Show login monitoring status and configuration
    stats [--json]      Show login statistics (for Prometheus/metrics)
    enable [TARGET]     Enable monitoring (ssh|su|sudo|console|all)
    disable [TARGET]    Disable monitoring (ssh|su|sudo|console|all)
    restart             Restart login monitoring service
    logs [N]            Show last N lines of logs (default: 50)
    test                Send a test alert email
    run                 Run login monitoring (used by service)
    mode [MODE]         Set email alert mode (realtime|digest|both)
    digest [ACTION]     Manage daily digest (status|send|clear)
    help                Show this help message

NOTE: Login health checks are handled by 'nftban health check --auto-heal'

MONITORED SERVICES (auto-detected):
    System:
      • SSH (sshd)        - Failed/successful logins
      • SU                - Switch user attempts
      • SUDO              - Privilege escalation

    Email:
      • Postfix           - SMTP authentication failures
      • Exim              - SMTP authentication failures
      • Dovecot           - IMAP/POP3 login failures

    Web/CMS:
      • WordPress         - wp-login.php + xmlrpc.php attacks
      • Roundcube         - Webmail login failures

    FTP:
      • Pure-FTPd         - FTP login failures
      • vsftpd            - FTP login failures
      • ProFTPD           - FTP login failures

    Panel:
      • DirectAdmin       - Control panel login failures

BAN THRESHOLDS:
    Default: 5 failed attempts in 5 minutes = Auto-ban

    All services use the same threshold for simplicity:
      LOGIN_FAIL_THRESHOLD=5      # Failed attempts before ban
      LOGIN_FAIL_WINDOW=300       # Time window (300 sec = 5 min)

    Override per-service in /etc/nftban/conf.d/login_thresholds.conf:
      LOGIN_SERVICE_SSH_FAIL_THRESHOLD=3        # Stricter for SSH
      LOGIN_SERVICE_WORDPRESS_FAIL_THRESHOLD=10 # More lenient for WP

TARGETS:
    ssh                 SSH login monitoring
    su                  SU command monitoring
    sudo                SUDO command monitoring
    console             Console/TTY login monitoring
    service             Systemd service (default)
    all                 All monitoring types

EXAMPLES:
    # Quick setup (one command - enables all monitoring)
    sudo nftban login enable

    # Check status (shows detected services)
    nftban login status

    # Enable all monitoring types
    sudo nftban login enable all

    # Disable login monitoring
    sudo nftban login disable

    # Send test alert
    nftban login test

    # View recent logs
    nftban login logs 100

CONFIGURATION:
    /etc/nftban/conf.d/login_alert.conf

    Key settings:
    - NFTBAN_LOGIN_ALERT_ENABLED: Enable/disable alerts
    - NFTBAN_LOGIN_ALERT_EMAIL: Destination email address
    - NFTBAN_LOGIN_ALERT_GEOIP: Include GeoIP information
    - NFTBAN_LOGIN_ALERT_FORMAT: html or text
    - LOGIN_FAIL_THRESHOLD: Failed attempts before ban (default: 5)
    - LOGIN_FAIL_WINDOW: Time window in seconds (default: 300)

DAEMON (loginmon module):
    Service: nftband.service (built-in loginmon module)
    Status:  systemctl status nftband
    Logs:    journalctl -u nftband -f

For more information: https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference

NFTBan — Open-source Linux IPS and nftables firewall manager
EOF
}

# =============================================================================

# MAIN ENTRY POINT
# =============================================================================


nftban_cmd_login() {
    # Main login CLI handler
    local subcommand="${1:-status}"
    shift || true

    # v1.83 F3 fix: scan for --json and build clean args array.
    # --json is consumed by the dispatcher and must not leak to
    # downstream functions that don't understand it.
    local json_mode=false
    local -a clean_args=()
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            json_mode=true
        else
            clean_args+=("$arg")
        fi
    done

    # Load output module (for help banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    fi

    case "$subcommand" in
        status)
            _nftban_login_cmd_status_json "$json_mode"
            ;;
        stats)
            _nftban_login_cmd_stats_json "$json_mode"
            ;;
        config)
            nftban_login_cmd_config "$json_mode"
            ;;
        install)
            nftban_login_cmd_install "${clean_args[@]}"
            ;;
        enable)
            nftban_login_cmd_enable "${clean_args[@]}"
            ;;
        disable)
            nftban_login_cmd_disable "${clean_args[@]}"
            ;;
        restart)
            nftban_login_cmd_restart "${clean_args[@]}"
            ;;
        health-fix)
            echo "NOTE: Login health checks are now part of the main autoheal system."
            echo ""
            echo "Use: nftban health check --auto-heal"
            echo ""
            ;;
        logs)
            nftban_login_cmd_logs "${clean_args[@]}"
            ;;
        test)
            nftban_login_cmd_test "${clean_args[@]}"
            ;;
        run)
            nftban_login_cmd_run "${clean_args[@]}"
            ;;
        mode)
            nftban_login_cmd_mode "${clean_args[@]}"
            ;;
        digest)
            nftban_login_cmd_digest "${clean_args[@]}"
            ;;
        help|--help|-h)
            nftban_login_cmd_help
            ;;
        *)
            nftban_banner
            echo "ERROR: Unknown command: $subcommand" >&2
            echo "Run 'nftban login help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# EXPORTS
# =============================================================================


export -f nftban_cmd_login
export -f nftban_login_cmd_status
export -f _nftban_login_cmd_status_json
export -f nftban_login_cmd_stats
export -f _nftban_login_cmd_stats_json
export -f nftban_login_cmd_config
export -f nftban_login_cmd_install
export -f nftban_login_cmd_enable
export -f nftban_login_cmd_disable
export -f _nftban_login_set_config
export -f nftban_login_cmd_restart
export -f nftban_login_cmd_logs
export -f nftban_login_cmd_test
export -f nftban_login_cmd_run
export -f nftban_login_cmd_mode
export -f nftban_login_cmd_digest
export -f nftban_login_cmd_help
