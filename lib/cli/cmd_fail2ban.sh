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
        sync)
            nftban_check_root || exit 1
            nftban_fail2ban_sync
            ;;
        config)
            local subaction="${1:-show}"
            shift || true

            case "$subaction" in
                show)
                    nftban_fail2ban_config_show "$@"
                    ;;
                set)
                    nftban_check_root || exit 1
                    [[ $# -lt 3 ]] && {
                        nftban_log_error "Usage: nftban fail2ban config set <jail> <setting> <value>"
                        echo ""
                        echo "Examples:"
                        echo "  nftban fail2ban config set sshd maxretry 5"
                        echo "  nftban fail2ban config set sshd bantime 7200"
                        echo "  nftban fail2ban config set postfix maxretry 10"
                        exit 1
                    }
                    nftban_fail2ban_config_set "$1" "$2" "$3"
                    ;;
                *)
                    nftban_log_error "Unknown config action: $subaction"
                    echo "Usage: nftban fail2ban config [show|set]"
                    exit 1
                    ;;
            esac
            ;;
        *)
            nftban_log_error "Unknown fail2ban action: $action"
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo "  NFTBan Fail2ban Integration (v0.9.4)"
            echo "═══════════════════════════════════════════════════════"
            echo ""
            echo "Status & Monitoring:"
            echo "  status                 Show fail2ban status and jail details"
            echo "  monitor                Show beautiful service monitoring panel"
            echo "  list                   List active jails"
            echo ""
            echo "Configuration Management (NEW in v0.9.4):"
            echo "  sync                   Sync nftban config → fail2ban jail.local"
            echo "  config show            Show current jail configuration"
            echo "  config show <jail>     Show specific jail configuration"
            echo "  config set <jail> <setting> <value>"
            echo "                         Update jail setting in nftban.conf.local"
            echo ""
            echo "  NOTE: Whitelisting uses: nftban whitelist add/remove"
            echo "        Then run: nftban fail2ban sync"
            echo ""
            echo "Service Management:"
            echo "  setup                  Setup fail2ban integration"
            echo "  start                  Start fail2ban service"
            echo "  stop                   Stop fail2ban service"
            echo "  restart                Restart fail2ban service"
            echo "  service-enable         Enable fail2ban at boot"
            echo "  service-disable        Disable fail2ban at boot"
            echo ""
            echo "Jail Management (Legacy):"
            echo "  enable <jail>          Enable specific jail"
            echo "  disable <jail>         Disable specific jail"
            echo ""
            echo "Examples:"
            echo "  # Show configuration"
            echo "  nftban fail2ban config show"
            echo "  nftban fail2ban config show sshd"
            echo ""
            echo "  # Change SSH jail settings"
            echo "  sudo nftban fail2ban config set sshd maxretry 5"
            echo "  sudo nftban fail2ban config set sshd bantime 3600"
            echo ""
            echo "  # Whitelist your IP and sync"
            echo "  sudo nftban whitelist add 203.0.113.100 \"My IP\""
            echo "  sudo nftban fail2ban sync"
            echo ""
            echo "  # Monitor service"
            echo "  nftban fail2ban monitor"
            echo "  nftban fail2ban status"
            echo ""
            echo "═══════════════════════════════════════════════════════"
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_fail2ban
