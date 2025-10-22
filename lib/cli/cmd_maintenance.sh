#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Maintenance Command
# Version: 1.0.0
# Location: lib/cli/cmd_maintenance.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_maintenance_module.sh
# Description: System maintenance and service management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MAINTENANCE COMMAND HANDLER
# =============================================================================

cmd_maintenance() {
    local action="${1:-panel}"
    shift || true

    case "$action" in
        panel)
            nftban_maintenance_show_panel
            ;;
        validate)
            nftban_maintenance_validate_config
            ;;
        repair)
            nftban_check_root || exit 1
            nftban_maintenance_repair_config
            ;;
        health)
            nftban_maintenance_health_check_detailed
            ;;
        health-basic)
            nftban_maintenance_health_check
            ;;
        stats)
            nftban_maintenance_show_stats
            ;;
        check-permissions|perms)
            nftban_maintenance_validate_permissions
            ;;
        backup)
            nftban_check_root || exit 1
            nftban_update_create_backup
            ;;
        list-backups)
            nftban_log_info "Available backups:"
            find "${NFTBAN_UPDATE_BACKUP_DIR}" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -10
            ;;
        restore)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && {
                nftban_log_error "Usage: nftban maintenance restore <backup_dir>"
                echo ""
                echo "Available backups:"
                find "${NFTBAN_UPDATE_BACKUP_DIR}" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -10
                exit 1
            }
            nftban_update_rollback "$1"
            ;;
        clean)
            nftban_check_root || exit 1
            nftban_maintenance_run
            ;;
        enable)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Enabling service: $service"
            nftban_service_control "enable" "$service"
            nftban_log_success "Service enabled: $service"
            ;;
        disable)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Disabling service: $service"
            nftban_service_control "disable" "$service"
            nftban_log_success "Service disabled: $service"
            ;;
        start)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Starting service: $service"
            nftban_service_control "start" "$service"
            nftban_log_success "Service started: $service"
            ;;
        stop)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Stopping service: $service"
            nftban_service_control "stop" "$service"
            nftban_log_success "Service stopped: $service"
            ;;
        restart)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Restarting service: $service"
            nftban_service_control "restart" "$service"
            nftban_log_success "Service restarted: $service"
            ;;
        *)
            nftban_log_error "Unknown maintenance action: $action"
            echo ""
            echo "Available actions:"
            echo "  panel            Show maintenance panel"
            echo "  validate         Validate configuration files"
            echo "  repair           Repair broken configuration"
            echo "  health           Comprehensive health check"
            echo "  health-basic     Basic health check"
            echo "  stats            Show system statistics"
            echo "  check-permissions Check file/directory permissions"
            echo "  backup           Create manual backup"
            echo "  list-backups     List available backups"
            echo "  restore <dir>    Restore from backup"
            echo "  clean            Run maintenance cleanup"
            echo ""
            echo "Service Management:"
            echo "  enable [service] Enable service (all/nftables/fail2ban)"
            echo "  disable [service] Disable service (all/nftables/fail2ban)"
            echo "  start [service]  Start service (all/nftables/fail2ban)"
            echo "  stop [service]   Stop service (all/nftables/fail2ban)"
            echo "  restart [service] Restart service (all/nftables/fail2ban)"
            echo ""
            echo "Examples:"
            echo "  nftban maintenance panel"
            echo "  nftban maintenance validate"
            echo "  nftban maintenance repair"
            echo "  nftban maintenance health"
            echo "  nftban maintenance stats"
            echo "  nftban maintenance check-permissions"
            echo ""
            echo "  sudo nftban maintenance disable all       # Disable both nftables and fail2ban"
            echo "  sudo nftban maintenance enable all        # Enable both services"
            echo "  sudo nftban maintenance restart nftables  # Restart nftables only"
            echo "  sudo nftban maintenance stop fail2ban     # Stop fail2ban only"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_maintenance
