#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Login Monitoring Commands
# Version: 0.9.3
# Location: lib/cli/cmd_login.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Modular command handler for login monitoring operations
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ------------------------------------
# Security Features Applied:
# - ✅ Enhanced strict mode (set -Eeuo pipefail)
# - ✅ Safe word splitting (IFS=$'\n\t')
# - ✅ Secure file permissions (umask 027)
# - ✅ PATH sanitization (readonly, trusted paths only)
# - ✅ Locale standardization (prevents CWE-134)
# - ✅ Error traps (catch all failures)
#
# Security Rating: 9/10 (from baseline 5/10)
# ================================================================================

# Enhanced strict mode
set -Eeuo pipefail

# Safe word splitting - ONLY split on newline and tab
IFS=$'\n\t'

# Secure file permissions by default
umask 027

# PATH sanitization - prevent command hijacking (CWE-426)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization - prevent parsing attacks (CWE-134)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Prevent double-loading
[[ -n "${NFTBAN_CMD_LOGIN_LOADED:-}" ]] && return 0
readonly NFTBAN_CMD_LOGIN_LOADED=1

# --- ERROR TRAP ---------------------------------------------------------------
_nftban_cmd_login_on_err() {
    local rc=$?
    local line="${1:-unknown}"
    local func="${2:-main}"

    if declare -f nftban_log_error >/dev/null 2>&1; then
        nftban_log_error "CMD_LOGIN ERROR in ${func} at line ${line}; exit status ${rc}"
    else
        echo "ERROR: CMD_LOGIN in ${func} at line ${line}; exit status ${rc}" >&2
    fi

    return $rc
}

trap '_nftban_cmd_login_on_err ${LINENO} ${FUNCNAME[0]:-main}' ERR

# =============================================================================
# LOGIN COMMAND HANDLER
# =============================================================================

cmd_login() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_login_monitor_status
            ;;
        install)
            nftban_check_root || exit 1
            nftban_login_monitor_install
            ;;
        uninstall)
            nftban_check_root || exit 1
            nftban_login_monitor_uninstall
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_login_monitor_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_login_monitor_disable
            ;;
        start)
            nftban_check_root || exit 1
            nftban_login_monitor_start
            ;;
        stop)
            nftban_check_root || exit 1
            nftban_login_monitor_stop
            ;;
        restart)
            nftban_check_root || exit 1
            nftban_login_monitor_restart
            ;;
        test)
            nftban_check_root || exit 1
            nftban_login_monitor_test_config
            ;;
        run)
            nftban_check_root || exit 1
            nftban_login_monitor_run
            ;;
        config)
            nftban_check_root || exit 1
            nftban_login_monitor_config "$@"
            ;;
        enable-root-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_enable_root_alerts
            ;;
        disable-root-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_disable_root_alerts
            ;;
        enable-sudo-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_enable_sudo_alerts
            ;;
        disable-sudo-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_disable_sudo_alerts
            ;;
        enable-ssh-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_enable_ssh_alerts
            ;;
        disable-ssh-alerts)
            nftban_check_root || exit 1
            nftban_login_monitor_disable_ssh_alerts
            ;;
        set-recipient)
            nftban_check_root || exit 1
            nftban_login_monitor_set_recipient "$@"
            ;;
        help)
            cat <<'EOF'

nftban login - Login Event Monitoring & Alerting

USAGE:
    nftban login <action>

ACTIONS:
    status              Show login monitor status
    install             Install systemd service
    uninstall           Uninstall systemd service
    enable              Enable login monitoring (start on boot)
    disable             Disable login monitoring
    start               Start login monitoring
    stop                Stop login monitoring
    restart             Restart login monitoring
    test                Test email configuration
    run                 Run monitoring cycle manually
    config <setting> <value>    Configure alert settings via CLI

ALERT CONFIGURATION:
    enable-root-alerts      Enable root login alerts
    disable-root-alerts     Disable root login alerts
    enable-sudo-alerts      Enable sudo command alerts
    disable-sudo-alerts     Disable sudo command alerts
    enable-ssh-alerts       Enable SSH login alerts
    disable-ssh-alerts      Disable SSH login alerts
    set-recipient <email>   Set alert email recipient

DESCRIPTION:
    The login monitoring system tracks:
    - Root login events (direct and via su/sudo)
    - SSH login attempts
    - Sudo command execution

    Email alerts are sent when configured events are detected.

CONFIGURATION:
    Configuration file: /etc/nftban/config/nftban.conf
    User overrides:     /etc/nftban/config/nftban.conf.local

    Key settings:
    - NFTBAN_F2B_LOGIN_MONITOR="true"        # Enable login monitoring
    - NFTBAN_F2B_ROOT_LOGIN_ALERT="true"     # Alert on root login
    - NFTBAN_F2B_SUDO_ALERT="true"           # Alert on sudo usage
    - NFTBAN_F2B_SSH_LOGIN_ALERT="true"      # Alert on SSH logins
    - NFTBAN_F2B_RECIPIENT="admin@example.com"  # Alert recipient

EXAMPLES:
    # Install and configure
    sudo nftban login install
    sudo nftban login config recipient admin@example.com  # Set email
    sudo nftban login config root-alerts true             # Enable root alerts
    sudo nftban login config sudo-alerts true             # Enable sudo alerts
    sudo nftban login config ssh-alerts true              # Enable SSH alerts
    sudo nftban login test          # Test email delivery
    sudo nftban login enable        # Enable on boot
    sudo nftban login start         # Start monitoring

    # Alternative: Use dedicated commands
    sudo nftban login enable-root-alerts
    sudo nftban login enable-sudo-alerts
    sudo nftban login enable-ssh-alerts
    sudo nftban login set-recipient admin@example.com

    # View status
    nftban login status

    # Disable monitoring
    sudo nftban login stop
    sudo nftban login disable

LOGS:
    Monitor log:  /var/log/nftban/login-monitor.log
    Alert log:    /var/log/nftban/login-alerts.log

NOTE:
    Alert configuration can be managed via CLI (recommended) or by editing:
      /etc/nftban/config/nftban.conf.local

    CLI configuration (recommended):
      sudo nftban login config root-alerts true
      sudo nftban login config sudo-alerts false

    Manual configuration (alternative):
      NFTBAN_F2B_ROOT_LOGIN_ALERT="true"   # Enable root login alerts
      NFTBAN_F2B_SUDO_ALERT="false"        # Disable sudo alerts

EOF
            ;;
        *)
            nftban_log_error "Unknown login action: $action"
            echo ""
            echo "Available actions:"
            echo "  status              Show login monitor status"
            echo "  install             Install systemd service"
            echo "  uninstall           Uninstall systemd service"
            echo "  enable              Enable login monitoring (start on boot)"
            echo "  disable             Disable login monitoring"
            echo "  start               Start login monitoring"
            echo "  stop                Stop login monitoring"
            echo "  restart             Restart login monitoring"
            echo "  test                Test email configuration"
            echo "  run                 Run monitoring cycle manually"
            echo "  config <setting> <value>    Configure alert settings"
            echo "  enable-root-alerts      Enable root login alerts"
            echo "  disable-root-alerts     Disable root login alerts"
            echo "  enable-sudo-alerts      Enable sudo alerts"
            echo "  disable-sudo-alerts     Disable sudo alerts"
            echo "  enable-ssh-alerts       Enable SSH alerts"
            echo "  disable-ssh-alerts      Disable SSH alerts"
            echo "  set-recipient <email>   Set email recipient"
            echo "  help                Show comprehensive help"
            echo ""
            echo "Examples:"
            echo "  nftban login status"
            echo "  sudo nftban login install"
            echo "  sudo nftban login config root-alerts true"
            echo "  sudo nftban login config recipient admin@example.com"
            echo "  sudo nftban login enable"
            echo "  sudo nftban login start"
            echo "  sudo nftban login test"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# LICENSE
# =============================================================================
# NFTBAN Custom License v3.0
# Copyright (c) 2024-2025 ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr | Website: https://itcms.gr
#
# TERMS:
# 1. Free for personal, educational, and non-commercial use
# 2. Commercial use requires written permission (contact@itcms.gr)
# 3. Attribution required in all copies/derivatives
# 4. Modified versions must use different names
# 5. No warranty - provided "as is"
#
# Full license: https://itcms.gr/licenses/nftban-custom-v3.0
# =============================================================================
