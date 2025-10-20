#!/usr/bin/env bash

# =============================================================================
# NFTBan Login Monitor Module
# Version: 0.9.0
# Location: lib/nftban_login_monitor_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Login event monitoring and alerting
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_LOGIN_MONITOR_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_MONITOR_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_LOGIN_MONITOR_LOG="${NFTBAN_LOG_DIR}/login-monitor.log"
readonly NFTBAN_LOGIN_ALERT_LOG="${NFTBAN_LOG_DIR}/login-alerts.log"
readonly NFTBAN_LOGIN_STATE_DIR="${NFTBAN_CACHE_DIR}/login-monitor"
readonly NFTBAN_LOGIN_SERVICE_FILE="/etc/systemd/system/nftban-login-monitor.service"
readonly NFTBAN_LOGIN_TIMER_FILE="/etc/systemd/system/nftban-login-monitor.timer"

# =============================================================================
# LOGIN MONITOR FUNCTIONS
# =============================================================================

# Install systemd service
nftban_login_monitor_install() {
    nftban_log_info "Installing login monitor service..."

    # Create service file
    cat > "$NFTBAN_LOGIN_SERVICE_FILE" << EOF
[Unit]
Description=nftban Login Monitor Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban login run
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Create timer file (runs every minute)
    cat > "$NFTBAN_LOGIN_TIMER_FILE" << EOF
[Unit]
Description=nftban Login Monitor Timer
Requires=nftban-login-monitor.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    nftban_log_success "Login monitor service installed"

    echo ""
    echo "Service files created:"
    echo "  - $NFTBAN_LOGIN_SERVICE_FILE"
    echo "  - $NFTBAN_LOGIN_TIMER_FILE"
    echo ""
    echo "Next steps:"
    echo "  1. Configure: edit ${NFTBAN_CONFIG_DIR}/nftban.conf.local"
    echo "  2. Test: nftban login test"
    echo "  3. Enable: nftban login enable"
    echo "  4. Start: nftban login start"
}

# Uninstall service
nftban_login_monitor_uninstall() {
    nftban_log_info "Uninstalling login monitor service..."

    systemctl stop nftban-login-monitor.timer 2>/dev/null || true
    systemctl disable nftban-login-monitor.timer 2>/dev/null || true

    rm -f "$NFTBAN_LOGIN_SERVICE_FILE" "$NFTBAN_LOGIN_TIMER_FILE"

    systemctl daemon-reload

    nftban_log_success "Login monitor service uninstalled"
}

# Enable service
nftban_login_monitor_enable() {
    systemctl enable nftban-login-monitor.timer
    nftban_log_success "Login monitor enabled (will start on boot)"
}

# Disable service
nftban_login_monitor_disable() {
    systemctl disable nftban-login-monitor.timer
    nftban_log_success "Login monitor disabled"
}

# Start service
nftban_login_monitor_start() {
    systemctl start nftban-login-monitor.timer
    nftban_log_success "Login monitor started"
}

# Stop service
nftban_login_monitor_stop() {
    systemctl stop nftban-login-monitor.timer
    nftban_log_success "Login monitor stopped"
}

# Restart service
nftban_login_monitor_restart() {
    systemctl restart nftban-login-monitor.timer
    nftban_log_success "Login monitor restarted"
}

# Show status
nftban_login_monitor_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Login Monitor Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Configuration
    echo -e "${NFTBAN_CYAN}Configuration:${NFTBAN_NC}"
    local monitor_enabled root_alert sudo_alert ssh_alert recipient
    monitor_enabled=$(nftban_get_config "NFTBAN_F2B_LOGIN_MONITOR" "false")
    root_alert=$(nftban_get_config "NFTBAN_F2B_ROOT_LOGIN_ALERT" "false")
    sudo_alert=$(nftban_get_config "NFTBAN_F2B_SUDO_ALERT" "false")
    ssh_alert=$(nftban_get_config "NFTBAN_F2B_SSH_LOGIN_ALERT" "false")
    recipient=$(nftban_get_config "NFTBAN_F2B_RECIPIENT" "<not set>")

    echo "  Monitoring: $monitor_enabled"
    echo "  Root login alerts: $root_alert"
    echo "  Sudo alerts: $sudo_alert"
    echo "  SSH alerts: $ssh_alert"
    echo "  Email recipient: $recipient"
    echo ""

    # Service status
    echo -e "${NFTBAN_CYAN}Service Status:${NFTBAN_NC}"
    if [[ -f "$NFTBAN_LOGIN_SERVICE_FILE" ]]; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Service installed"

        if systemctl is-active nftban-login-monitor.timer &>/dev/null; then
            echo -e "  ${NFTBAN_GREEN}● RUNNING${NFTBAN_NC}"
        else
            echo -e "  ${NFTBAN_RED}○ STOPPED${NFTBAN_NC}"
        fi

        if systemctl is-enabled nftban-login-monitor.timer &>/dev/null; then
            echo -e "  Boot: ${NFTBAN_GREEN}ENABLED${NFTBAN_NC}"
        else
            echo -e "  Boot: ${NFTBAN_YELLOW}DISABLED${NFTBAN_NC}"
        fi
    else
        echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Service not installed"
        echo "  Run: nftban login install"
    fi
    echo ""

    # Recent alerts
    if [[ -f "$NFTBAN_LOGIN_ALERT_LOG" ]]; then
        echo -e "${NFTBAN_CYAN}Recent Alerts (last 10):${NFTBAN_NC}"
        tail -10 "$NFTBAN_LOGIN_ALERT_LOG" 2>/dev/null | sed 's/^/  /' || echo "  No alerts yet"
    fi

    echo ""
}

# Test configuration
nftban_login_monitor_test_config() {
    echo ""
    echo "Testing login monitor configuration..."
    echo ""

    local monitor_enabled recipient
    monitor_enabled=$(nftban_get_config "NFTBAN_F2B_LOGIN_MONITOR" "false")
    recipient=$(nftban_get_config "NFTBAN_F2B_RECIPIENT" "")

    if [[ "$monitor_enabled" != "true" ]]; then
        nftban_log_error "Login monitoring is disabled"
        echo "  Set: NFTBAN_F2B_LOGIN_MONITOR=\"true\""
        return 1
    fi

    if [[ -z "$recipient" ]]; then
        nftban_log_error "Email recipient not configured"
        echo "  Set: NFTBAN_F2B_RECIPIENT=\"your@email.com\""
        return 1
    fi

    nftban_log_success "Configuration valid"

    echo ""
    echo "Send test email? (y/N): "
    read -r response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Sending test email to $recipient..."

        # Prepare test email content
        local subject="[nftban] Login Monitor Test Email"
        local body="nftban Login Monitor - Test Email

This is a test email from the nftban login monitoring system.

Configuration Test Results:
✓ Email notifications enabled
✓ Recipient configured: $recipient
✓ Login monitoring enabled

Timestamp: $(date +'%Y-%m-%d %H:%M:%S')
Server: $(hostname -f)

Current Configuration:
- Root login alerts: $(nftban_get_config 'NFTBAN_F2B_ROOT_LOGIN_ALERT' 'false')
- Sudo alerts: $(nftban_get_config 'NFTBAN_F2B_SUDO_ALERT' 'false')
- SSH alerts: $(nftban_get_config 'NFTBAN_F2B_SSH_LOGIN_ALERT' 'false')

If you received this email, your login monitoring is configured correctly!

---
This is a test message from nftban login monitor
https://itcms.gr"

        # Send test email using core module function
        if nftban_send_email "$recipient" "$subject" "$body" "normal"; then
            nftban_log_success "Test email sent successfully to $recipient"
            echo ""
            echo "✓ Check your inbox at: $recipient"
            echo "  (Check spam folder if not received within a few minutes)"
        else
            nftban_log_error "Failed to send test email"
            echo ""
            echo "Troubleshooting:"
            echo "  1. Check if 'mail' or 'sendmail' command is available"
            echo "  2. Verify mail server configuration"
            echo "  3. Check email logs: $NFTBAN_EMAIL_LOG"
            return 1
        fi
    fi
}

# Run monitoring cycle (called by systemd)
nftban_login_monitor_run() {
    # This would be called by systemd timer
    # Actual monitoring logic would be implemented here
    # For now, just log that it ran

    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] Monitor cycle completed" >> "$NFTBAN_LOGIN_MONITOR_LOG"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_login_monitor_install
export -f nftban_login_monitor_uninstall
export -f nftban_login_monitor_enable
export -f nftban_login_monitor_disable
export -f nftban_login_monitor_start
export -f nftban_login_monitor_stop
export -f nftban_login_monitor_restart
export -f nftban_login_monitor_status
export -f nftban_login_monitor_test_config
export -f nftban_login_monitor_run

nftban_log_debug "NFTBan Login Monitor Module loaded"
