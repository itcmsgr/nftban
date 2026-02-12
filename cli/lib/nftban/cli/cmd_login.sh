#!/usr/bin/env bash
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh"
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
# NFTBan v1.0.0 - Login Alert CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Provides CLI interface for login monitoring and alerting
#
# meta:name="cmd_login"
# meta:type="cli"
# meta:header="Login Alert CLI Handler"
# meta:version="1.0.0"
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
    source "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh"
else
    echo "ERROR: Login alert module not found at ${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" >&2
    exit 1
fi

# Load main login module (for multi-service detection: SSH, Dovecot, Postfix, Exim)
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_login.sh"
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
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
    local config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"

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

    # Check service
    if systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
        echo "✅ Service: Running"
    elif systemctl is-enabled --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
        echo "⚠️  Service: Enabled but stopped (run 'nftban login enable' to start)"
    else
        echo "⚪ Service: Disabled (run 'nftban login enable' to start)"
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
        local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
        local config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"
        local config_exists="false"
        local module_exists="false"
        local service_status="not_installed"
        local log_lines=0

        [[ -f "$config_file" ]] || [[ -f "$config_local" ]] && config_exists="true"
        [[ -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]] && module_exists="true"

        if systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
            service_status="running"
        elif systemctl is-enabled --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
            service_status="stopped"
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
    # Install/verify systemd service
    # NOTE: Package installs service to /lib/systemd/system/ - don't duplicate!

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service installation requires root privileges" >&2
        return 1
    fi

    local service_name="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"

    echo "Installing NFTBan Login Monitor Service"
    echo "========================================"
    echo ""

    # Check if service already exists (from package)
    if [[ -f "/lib/systemd/system/${service_name}" ]] || \
       [[ -f "/usr/lib/systemd/system/${service_name}" ]]; then
        echo "✅ Service file exists (from package)"

        # Remove any duplicate in /etc/systemd/system/ that may override
        if [[ -f "/etc/systemd/system/${service_name}" ]]; then
            echo "Removing duplicate override in /etc/systemd/system/..."
            rm -f "/etc/systemd/system/${service_name}"
            systemctl daemon-reload
            echo "✅ Duplicate removed, using package service"
        fi
    else
        # No package service - this shouldn't happen with proper install
        echo "WARNING: No package service file found" >&2
        echo "Please reinstall nftban package" >&2
        return 1
    fi

    echo ""
    echo "Service ready!"
    echo ""
    echo "To start monitoring:"
    echo "  nftban login enable"
    echo ""
    echo "To check status:"
    echo "  nftban login status"
}

nftban_login_cmd_enable() {
    # Enable monitoring for specific type or service
    # Usage: nftban login enable [ssh|su|sudo|console|service|all]

    local target="${1:-}"
    local config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"

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
        mkdir -p "$(dirname "$config_local")"
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
            # Enable and start systemd service (auto-install if needed)
            local service_name="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
            if [[ ! -f "/etc/systemd/system/${service_name}" ]] && \
               [[ ! -f "/lib/systemd/system/${service_name}" ]] && \
               [[ ! -f "/usr/lib/systemd/system/${service_name}" ]]; then
                echo "Installing login monitor service..."
                nftban_login_cmd_install >/dev/null 2>&1
                echo "✅ Service installed"
            fi
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "true" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "true" "$config_local"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable "${service_name}" >/dev/null 2>&1
            if systemctl start "${service_name}" 2>&1; then
                # Verify the service is actually running
                sleep 1
                if systemctl is-active --quiet "${service_name}"; then
                    echo "✅ Login monitoring enabled and started (SSH alerts active)"
                else
                    echo "⚠️  Service enabled but failed to stay running" >&2
                    echo "" >&2
                    echo "Recent logs:" >&2
                    journalctl -u "${service_name}" -n 10 --no-pager 2>/dev/null || true
                    return 1
                fi
            else
                echo "❌ Failed to start login monitor service" >&2
                echo "" >&2
                echo "Check service logs:" >&2
                journalctl -u "${service_name}" -n 10 --no-pager 2>/dev/null || true
                return 1
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
    local config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Requires root privileges" >&2
        return 1
    fi

    # Ensure local config exists
    if [[ ! -f "$config_local" ]]; then
        mkdir -p "$(dirname "$config_local")"
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
            # Stop and disable systemd service
            local service_name="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_ENABLED" "false" "$config_local"
            _nftban_login_set_config "NFTBAN_LOGIN_ALERT_SSH" "false" "$config_local"
            # Check all possible service file locations
            if [[ -f "/etc/systemd/system/${service_name}" ]] || \
               [[ -f "/lib/systemd/system/${service_name}" ]] || \
               [[ -f "/usr/lib/systemd/system/${service_name}" ]]; then
                systemctl stop "${service_name}" 2>/dev/null || true
                systemctl disable "${service_name}" 2>/dev/null || true
            fi
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
        mkdir -p "$(dirname "$file")"
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
    echo "Service logs (last $lines lines):"
    echo "=================================="
    journalctl -u ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} -n "$lines" --no-pager 2>/dev/null || echo "Service not running"
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
        exit 1
    fi

    # Use consolidated login module (SSH + mail services)
    if declare -f nftban_login_start &>/dev/null; then
        # Initialize and detect services
        nftban_login_init || {
            echo "ERROR: Failed to initialize login module" >&2
            exit 1
        }

        # Build detected services list for banner
        local detected_services=""
        local all_services="ssh dovecot postfix exim"
        for svc in $all_services; do
            if nftban_login_service_detected "$svc" 2>/dev/null; then
                [[ -n "$detected_services" ]] && detected_services+=","
                detected_services+="$svc"
            fi
        done
        [[ -z "$detected_services" ]] && detected_services="ssh"

        # Startup banner for debugging
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] NFTBan Login Monitor starting"
        echo "[$timestamp] Mode: ${_LOGIN_ACTIVE_MODE:-classic}"
        echo "[$timestamp] Services monitored: $all_services"
        echo "[$timestamp] Services detected: $detected_services"
        logger -t nftban-login-monitor "Started: mode=${_LOGIN_ACTIVE_MODE:-classic} detected=$detected_services"

        # Start consolidated monitoring (SSH + Dovecot + Postfix + Exim)
        nftban_login_start
    else
        # Fallback to alert-only mode if main module not loaded
        echo "WARNING: Main login module not loaded, using alert-only mode (SSH only)" >&2
        logger -t nftban-login-monitor "Started: mode=alert-only (SSH only)"
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

    # Service uptime
    if systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
        local uptime
        uptime=$(systemctl show ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        echo "Service Started: $uptime"
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

        if systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
            service_running="true"
            service_uptime=$(systemctl show ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} --property=ActiveEnterTimestamp --value 2>/dev/null) || service_uptime=""
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
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
    if [[ ! -f "$config_file" ]]; then
        echo "❌ Configuration file missing: $config_file"
        ((issues_found++))

        if [[ $EUID -eq 0 ]]; then
            echo "   Creating default configuration..."
            mkdir -p "$(dirname "$config_file")"
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
NFTBAN_LOGIN_FAILED_THRESHOLD=3
NFTBAN_LOGIN_FAILED_WINDOW=300
CONF
            chmod 640 "$config_file"
            chown root:nftban "$config_file" 2>/dev/null || true
            echo "   ✅ Created default configuration"
            ((issues_fixed++))
        fi
    else
        echo "✅ Configuration file exists"
    fi

    # 2. Check log directory
    local log_dir
    log_dir=$(dirname "$NFTBAN_LOGIN_ALERT_LOG")
    if [[ ! -d "$log_dir" ]]; then
        echo "❌ Log directory missing: $log_dir"
        ((issues_found++))

        if [[ $EUID -eq 0 ]]; then
            mkdir -p "$log_dir"
            chown nftban:nftban "$log_dir" 2>/dev/null || true
            chmod 750 "$log_dir"
            echo "   ✅ Created log directory"
            ((issues_fixed++))
        fi
    else
        echo "✅ Log directory exists"
    fi

    # 3. Check service file
    local service_name="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    if [[ ! -f "/etc/systemd/system/${service_name}" ]] && \
       [[ ! -f "/lib/systemd/system/${service_name}" ]] && \
       [[ ! -f "/usr/lib/systemd/system/${service_name}" ]]; then
        echo "⚠️  Service not installed (run 'nftban login install')"
        ((issues_found++))
    else
        echo "✅ Service file exists"

        # 4. Check if service should be running but isn't
        if systemctl is-enabled --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
            if ! systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
                echo "❌ Service enabled but not running"
                ((issues_found++))

                if [[ $EUID -eq 0 ]]; then
                    echo "   Attempting to start service..."
                    if systemctl start ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
                        echo "   ✅ Service started"
                        ((issues_fixed++))
                    else
                        echo "   ❌ Failed to start service"
                    fi
                fi
            else
                echo "✅ Service running"
            fi
        fi
    fi

    # 5. Check core module
    if [[ ! -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]]; then
        echo "❌ Core module not installed"
        ((issues_found++))
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
        echo "✅ Login monitor is healthy"
    fi

    return 0
}

nftban_login_cmd_restart() {
    # Restart login monitoring service

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service management requires root privileges" >&2
        return 1
    fi

    echo "Restarting NFTBan Login Monitor"
    echo "================================"
    echo ""

    if [[ ! -f "/etc/systemd/system/${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" ]] && \
       [[ ! -f "/lib/systemd/system/${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" ]] && \
       [[ ! -f "/usr/lib/systemd/system/${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}" ]]; then
        echo "ERROR: Service not installed. Run 'nftban login install' first." >&2
        return 1
    fi

    echo "Restarting service..."
    systemctl restart ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}
    echo "✅ Service restarted"
    echo ""

    systemctl status ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} --no-pager -l
}

nftban_login_cmd_mode() {
    # Set login alert email mode: realtime, digest, or both
    # Usage: nftban login mode <realtime|digest|both>

    local mode="${1:-}"

    if [[ -z "$mode" ]]; then
        # Show current mode
        local current_mode="${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
        local digest_time="${NFTBAN_LOGIN_DIGEST_TIME:-08:00}"
        local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/login_digest.json}"
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
    local config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"
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

    # Restart service if running
    if systemctl is-active --quiet ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null; then
        echo ""
        echo "Restarting login monitor service..."
        systemctl restart ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service} 2>/dev/null || true
        echo "✅ Service restarted"
    fi
}

nftban_login_cmd_digest() {
    # Manage login digest
    # Usage: nftban login digest <status|send|clear>

    local action="${1:-status}"

    case "$action" in
        status)
            local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/login_digest.json}"
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
                local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/login_digest.json}"
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

SYSTEMD SERVICE:
    Service: ${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}
    Status:  systemctl status nftban-login-monitor
    Logs:    journalctl -u nftban-login-monitor -f

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
    local json_mode=false
    shift || true

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    # Load output module (for help banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi

    case "$subcommand" in
        status)
            _nftban_login_cmd_status_json "$json_mode"
            ;;
        stats)
            _nftban_login_cmd_stats_json "$json_mode"
            ;;
        install)
            nftban_login_cmd_install "$@"
            ;;
        enable)
            nftban_login_cmd_enable "$@"
            ;;
        disable)
            nftban_login_cmd_disable "$@"
            ;;
        restart)
            nftban_login_cmd_restart "$@"
            ;;
        health-fix)
            echo "NOTE: Login health checks are now part of the main autoheal system."
            echo ""
            echo "Use: nftban health check --auto-heal"
            echo ""
            ;;
        logs)
            nftban_login_cmd_logs "$@"
            ;;
        test)
            nftban_login_cmd_test "$@"
            ;;
        run)
            nftban_login_cmd_run "$@"
            ;;
        mode)
            nftban_login_cmd_mode "$@"
            ;;
        digest)
            nftban_login_cmd_digest "$@"
            ;;
        help|--help|-h)
            nftban_login_cmd_help
            ;;
        *)
            nftban_banner
            echo "ERROR: Unknown command: $subcommand" >&2
            echo "Run 'nftban login help' for usage information" >&2
            exit 1
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
