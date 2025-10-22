#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Fail2ban Command
# Version: 1.0.0
# Location: lib/cli/cmd_fail2ban.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_fail2ban_module.sh
# Description: Fail2ban integration and jail management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# FAIL2BAN COMMAND HANDLER
# =============================================================================

cmd_fail2ban() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        setup)
            nftban_check_root || exit 1
            nftban_fail2ban_setup
            ;;
        status)
            nftban_fail2ban_show_status
            ;;
        monitor|panel)
            nftban_fail2ban_monitor_panel
            ;;
        list)
            nftban_fail2ban_list_jails
            ;;
        enable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban fail2ban enable <jail_name>"; exit 1; }
            nftban_fail2ban_enable_jail "$1"
            ;;
        disable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban fail2ban disable <jail_name>"; exit 1; }
            nftban_fail2ban_disable_jail "$1"
            ;;
        start)
            nftban_check_root || exit 1
            nftban_log_info "Starting fail2ban service..."
            systemctl start fail2ban
            nftban_log_success "fail2ban service started"
            ;;
        stop)
            nftban_check_root || exit 1
            nftban_log_info "Stopping fail2ban service..."
            systemctl stop fail2ban
            nftban_log_success "fail2ban service stopped"
            ;;
        restart)
            nftban_check_root || exit 1
            nftban_log_info "Restarting fail2ban service..."
            systemctl restart fail2ban
            nftban_log_success "fail2ban service restarted"
            ;;
        service-enable)
            nftban_check_root || exit 1
            nftban_log_info "Enabling fail2ban service at boot..."
            systemctl enable fail2ban
            nftban_log_success "fail2ban service enabled at boot"
            ;;
        service-disable)
            nftban_check_root || exit 1
            nftban_log_info "Disabling fail2ban service at boot..."
            systemctl disable fail2ban
            nftban_log_success "fail2ban service disabled at boot"
            ;;
        *)
            nftban_log_error "Unknown fail2ban action: $action"
            echo ""
            echo "Available actions:"
            echo "  setup                  Setup fail2ban integration"
            echo "  status                 Show fail2ban status and jail details"
            echo "  monitor                Show beautiful service monitoring panel"
            echo "  list                   List active jails"
            echo ""
            echo "Service Management:"
            echo "  start                  Start fail2ban service"
            echo "  stop                   Stop fail2ban service"
            echo "  restart                Restart fail2ban service"
            echo "  service-enable         Enable fail2ban at boot"
            echo "  service-disable        Disable fail2ban at boot"
            echo ""
            echo "Jail Management:"
            echo "  enable <jail>          Enable specific jail"
            echo "  disable <jail>         Disable specific jail"
            echo ""
            echo "Examples:"
            echo "  sudo nftban fail2ban setup"
            echo "  nftban fail2ban status"
            echo "  nftban fail2ban monitor      # Beautiful colored panel!"
            echo "  sudo nftban fail2ban start   # Start service"
            echo "  sudo nftban fail2ban restart # Restart service"
            echo "  sudo nftban fail2ban service-enable  # Enable at boot"
            echo "  nftban fail2ban list"
            echo "  sudo nftban fail2ban enable sshd     # Enable sshd jail"
            echo "  sudo nftban fail2ban disable sshd    # Disable sshd jail"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_fail2ban
