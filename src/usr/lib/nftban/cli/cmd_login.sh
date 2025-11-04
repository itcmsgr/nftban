#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Login Alert CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Provides CLI interface for login monitoring and alerting
#
# meta:name=cmd_login
# meta:type=cli
# meta:header=Login Alert CLI Handler
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-10-28
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_LOGIN_CLI_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_CLI_LOADED=1

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Load login alert module
if [[ -f "/usr/lib/nftban/core/nftban_login_alert.sh" ]]; then
    source "/usr/lib/nftban/core/nftban_login_alert.sh"
else
    echo "ERROR: Login alert module not found" >&2
    exit 1
fi

# =============================================================================
# CLI COMMANDS
# =============================================================================

nftban_login_cmd_status() {
    # Show login monitoring status
    echo "NFTBan Login Alert Status"
    echo "========================="
    echo ""

    # Check configuration
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
    if [[ -f "$config_file" ]]; then
        echo "✅ Configuration: $config_file"
    else
        echo "❌ Configuration: NOT FOUND"
        return 1
    fi

    # Check module
    if [[ -f "/usr/lib/nftban/core/nftban_login_alert.sh" ]]; then
        echo "✅ Core Module: Installed"
    else
        echo "❌ Core Module: NOT FOUND"
        return 1
    fi

    # Check service
    if systemctl is-active --quiet nftban-login-monitor.service 2>/dev/null; then
        echo "✅ Service: Running"
    elif systemctl is-enabled --quiet nftban-login-monitor.service 2>/dev/null; then
        echo "⚠️  Service: Installed but not running"
    else
        echo "❌ Service: Not installed"
    fi

    echo ""
    echo "Configuration:"
    echo "  Enabled: $NFTBAN_LOGIN_ALERT_ENABLED"
    echo "  Email: $NFTBAN_LOGIN_ALERT_EMAIL"
    echo "  Format: $NFTBAN_LOGIN_ALERT_FORMAT"
    echo "  GeoIP: $NFTBAN_LOGIN_ALERT_GEOIP"
    echo ""
    echo "Monitoring:"
    echo "  SSH: $NFTBAN_LOGIN_ALERT_SSH"
    echo "  SU: $NFTBAN_LOGIN_ALERT_SU"
    echo "  SUDO: $NFTBAN_LOGIN_ALERT_SUDO"
    echo "  Console: $NFTBAN_LOGIN_ALERT_CONSOLE"
    echo ""
    echo "Failed Attempts:"
    echo "  Alert on Failed: $NFTBAN_LOGIN_ALERT_FAILED"
    echo "  Threshold: $NFTBAN_LOGIN_FAILED_THRESHOLD attempts"
    echo "  Time Window: $NFTBAN_LOGIN_FAILED_WINDOW seconds"
    echo ""

    # Check log file
    if [[ -f "$NFTBAN_LOGIN_ALERT_LOG" ]]; then
        local lines=$(wc -l < "$NFTBAN_LOGIN_ALERT_LOG")
        echo "Log File: $NFTBAN_LOGIN_ALERT_LOG ($lines lines)"
    else
        echo "Log File: $NFTBAN_LOGIN_ALERT_LOG (not created yet)"
    fi
}

nftban_login_cmd_install() {
    # Install systemd service

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service installation requires root privileges" >&2
        return 1
    fi

    echo "Installing NFTBan Login Monitor Service"
    echo "========================================"
    echo ""

    # Create service file
    local service_file="/etc/systemd/system/nftban-login-monitor.service"
    echo "Creating service file: $service_file"

    cat > "$service_file" <<'EOF'
[Unit]
Description=NFTBan Login Monitor
Documentation=https://nftban.com
After=network.target sshd.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/sbin/nftban login run
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nftban-login-monitor

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/nftban

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Service file created"
    echo ""

    # Reload systemd
    echo "Reloading systemd daemon..."
    systemctl daemon-reload
    echo "✅ Systemd reloaded"
    echo ""

    echo "Service installed successfully!"
    echo ""
    echo "To start monitoring:"
    echo "  systemctl start nftban-login-monitor"
    echo ""
    echo "To enable on boot:"
    echo "  systemctl enable nftban-login-monitor"
    echo ""
    echo "To check status:"
    echo "  nftban login status"
}

nftban_login_cmd_enable() {
    # Enable and start service

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service management requires root privileges" >&2
        return 1
    fi

    echo "Enabling NFTBan Login Monitor"
    echo "============================="
    echo ""

    # Check if service exists
    if [[ ! -f "/etc/systemd/system/nftban-login-monitor.service" ]]; then
        echo "ERROR: Service not installed. Run 'nftban login install' first." >&2
        return 1
    fi

    # Enable service
    echo "Enabling service..."
    systemctl enable nftban-login-monitor.service
    echo "✅ Service enabled"
    echo ""

    # Start service
    echo "Starting service..."
    systemctl start nftban-login-monitor.service
    echo "✅ Service started"
    echo ""

    # Show status
    systemctl status nftban-login-monitor.service --no-pager -l
}

nftban_login_cmd_disable() {
    # Disable and stop service

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Service management requires root privileges" >&2
        return 1
    fi

    echo "Disabling NFTBan Login Monitor"
    echo "=============================="
    echo ""

    # Stop service
    echo "Stopping service..."
    systemctl stop nftban-login-monitor.service 2>/dev/null || true
    echo "✅ Service stopped"
    echo ""

    # Disable service
    echo "Disabling service..."
    systemctl disable nftban-login-monitor.service 2>/dev/null || true
    echo "✅ Service disabled"
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
    journalctl -u nftban-login-monitor.service -n "$lines" --no-pager 2>/dev/null || echo "Service not running"
}

nftban_login_cmd_test() {
    # Test login alert system
    nftban_login_test
}

nftban_login_cmd_run() {
    # Run login monitoring (for service)

    if [[ "$NFTBAN_LOGIN_ALERT_ENABLED" != "true" ]]; then
        echo "ERROR: Login alerts are disabled in configuration" >&2
        exit 1
    fi

    # Start monitoring
    nftban_login_monitor_all
}

nftban_login_cmd_help() {
    # Show help
    nftban_render_banner simple
    echo ""

    cat <<EOF
NFTBan Login Alert - Monitor and Alert on System Logins

USAGE:
    nftban login <command> [options]

COMMANDS:
    status              Show login monitoring status and configuration
    install             Install systemd service for login monitoring
    enable              Enable and start login monitoring service
    disable             Disable and stop login monitoring service
    logs [N]            Show last N lines of logs (default: 50)
    test                Send a test alert email
    run                 Run login monitoring (used by service)
    help                Show this help message

EXAMPLES:
    # Check status
    nftban login status

    # Install and enable monitoring
    sudo nftban login install
    sudo nftban login enable

    # Send test alert
    nftban login test

    # View recent logs
    nftban login logs 100

    # Disable monitoring
    sudo nftban login disable

CONFIGURATION:
    /etc/nftban/conf.d/login_alert.conf

    Key settings:
    - NFTBAN_LOGIN_ALERT_ENABLED: Enable/disable alerts
    - NFTBAN_LOGIN_ALERT_EMAIL: Destination email address
    - NFTBAN_LOGIN_ALERT_GEOIP: Include GeoIP information
    - NFTBAN_LOGIN_ALERT_FORMAT: html or text
    - NFTBAN_LOGIN_FAILED_THRESHOLD: Failed attempts before alert

MONITORING:
    - SSH logins (success and failed attempts)
    - GeoIP enrichment (location information)
    - Failed attempt tracking with thresholds
    - HTML or text email alerts
    - IP whitelisting support

SYSTEMD SERVICE:
    Service: nftban-login-monitor.service
    Status:  systemctl status nftban-login-monitor
    Logs:    journalctl -u nftban-login-monitor -f

For more information, visit: https://nftban.com

nftban — Simplifying Linux Firewall Management
EOF
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_login() {
    # Main login CLI handler
    local subcommand="${1:-status}"
    shift || true

    case "$subcommand" in
        status)
            nftban_login_cmd_status "$@"
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
        logs)
            nftban_login_cmd_logs "$@"
            ;;
        test)
            nftban_login_cmd_test "$@"
            ;;
        run)
            nftban_login_cmd_run "$@"
            ;;
        help|--help|-h)
            nftban_login_cmd_help
            ;;
        *)
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
export -f nftban_login_cmd_install
export -f nftban_login_cmd_enable
export -f nftban_login_cmd_disable
export -f nftban_login_cmd_logs
export -f nftban_login_cmd_test
export -f nftban_login_cmd_run
export -f nftban_login_cmd_help
