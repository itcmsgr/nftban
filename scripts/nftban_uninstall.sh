#!/bin/bash
# =============================================================================
# NFTBan Uninstaller
# Version: 1.0.0
# Complete and safe removal of NFTBan system
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
INSTALL_DIR="/etc/nftban"
LOG_DIR="/var/log/nftban"

# User-controlled removal options (defaults to preserve)
REMOVE_LOGS="${REMOVE_LOGS:-false}"
REMOVE_BACKUPS="${REMOVE_BACKUPS:-false}"
REMOVE_CONFIG="${REMOVE_CONFIG:-false}"
CREATE_FINAL_BACKUP="${CREATE_FINAL_BACKUP:-true}"

# Colors for output
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $1"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $1" >&2; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2; }
log_fatal() { echo -e "${COLOR_RED}[FATAL]${COLOR_RESET} $1" >&2; exit 1; }

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root. Use: sudo $0"
    fi
}

check_installation() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "NFTBan installation not found at: $INSTALL_DIR"
        exit 1
    fi
}

# =============================================================================
# USER CONFIRMATION
# =============================================================================
confirm_uninstall() {
    cat << EOF

${COLOR_RED}╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║                    ⚠️  WARNING - UNINSTALL                    ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝${COLOR_RESET}

${COLOR_YELLOW}This will remove:${COLOR_RESET}
  • NFTBan executables and libraries
  • Fail2ban integration
  • NFTables rules and sets
  • Log rotation configuration
  • Threat intelligence feeds data
  • Command symlink (/usr/local/bin/nftban)
  • Systemd units (services/timers)

${COLOR_YELLOW}Optional removal (will ask):${COLOR_RESET}
  • Configuration files (preserved by default)
  • Log files (preserved by default)
  • Backup files (preserved by default)

${COLOR_BLUE}What will be preserved:${COLOR_RESET}
  • Fail2ban service (if used by other tools)
  • NFTables service (if used by other tools)
  • System packages (fail2ban, nftables)

EOF

    read -p "Are you sure you want to uninstall NFTBan? [y/N]: " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi

    echo
    read -p "Remove configuration files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_CONFIG="true"

    read -p "Remove log files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_LOGS="true"

    read -p "Remove backup files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_BACKUPS="true"

    if [[ "$REMOVE_CONFIG" == "false" ]] || [[ "$REMOVE_LOGS" == "false" ]] || [[ "$REMOVE_BACKUPS" == "false" ]]; then
        read -p "Create final backup before uninstall? [Y/n]: " response
        if [[ ! "$response" =~ ^[Nn]$ ]]; then
            CREATE_FINAL_BACKUP="true"
        else
            CREATE_FINAL_BACKUP="false"
        fi
    fi

    echo
    log_warning "Starting uninstallation in 3 seconds... (Ctrl+C to cancel)"
    sleep 3
}

# =============================================================================
# BACKUP BEFORE REMOVAL
# =============================================================================
create_final_backup() {
    if [[ "$CREATE_FINAL_BACKUP" != "true" ]]; then
        return 0
    fi

    log_info "Creating final backup..."

    local backup_dir="/tmp/nftban-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    # Backup configuration
    if [[ -d "$INSTALL_DIR/config" ]]; then
        cp -r "$INSTALL_DIR/config" "$backup_dir/" 2>/dev/null || true
    fi

    # Backup logs
    if [[ -d "$LOG_DIR" ]]; then
        cp -r "$LOG_DIR" "$backup_dir/logs" 2>/dev/null || true
    fi

    # Backup existing backups
    if [[ -d "$INSTALL_DIR/data/backups" ]]; then
        cp -r "$INSTALL_DIR/data/backups" "$backup_dir/" 2>/dev/null || true
    fi

    # Create archive
    local archive_file="${backup_dir}.tar.gz"
    tar -czf "$archive_file" -C /tmp "$(basename "$backup_dir")" 2>/dev/null || true
    rm -rf "$backup_dir"

    log_success "Final backup created: $archive_file"

    cat << EOF

═══════════════════════════════════════════════════════════════
To restore this backup:

  1. Extract archive:
     tar -xzf $archive_file -C /tmp

  2. Restore configuration:
     sudo cp -r /tmp/$(basename "$backup_dir")/config/* /etc/nftban/config/

  3. Restore logs:
     sudo cp -r /tmp/$(basename "$backup_dir")/logs/* /var/log/nftban/

═══════════════════════════════════════════════════════════════

EOF
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

stop_services() {
    log_info "Stopping services..."

    # Stop fail2ban (but don't disable system-wide)
    systemctl stop fail2ban 2>/dev/null || true

    # Stop and disable NFTBan-specific services
    systemctl stop nftban-login-monitor 2>/dev/null || true
    systemctl disable nftban-login-monitor 2>/dev/null || true

    # Stop any NFTBan timers
    for timer in /etc/systemd/system/nftban-*.timer; do
        if [[ -f "$timer" ]]; then
            systemctl stop "$(basename "$timer")" 2>/dev/null || true
            systemctl disable "$(basename "$timer")" 2>/dev/null || true
        fi
    done

    log_success "Services stopped"
}

clean_nftables() {
    log_info "Cleaning nftables..."

    # Remove all nftban tables (handles inet, ip, ip6 families)
    nft list tables 2>/dev/null | \
    awk '/nftban|NFTBAN/ {print $2, $3}' | \
    while read -r family table; do
        log_info "  Removing table: $family $table"
        nft delete table "$family" "$table" 2>/dev/null || true
    done

    log_success "NFTables cleaned"
}

clean_iptables() {
    log_info "Cleaning legacy iptables..."

    for tool in iptables ip6tables; do
        if command -v "$tool" &>/dev/null; then
            if $tool -S 2>/dev/null | grep -q nftban; then
                $tool -F nftban 2>/dev/null || true
                $tool -X nftban 2>/dev/null || true
                log_info "  Cleaned $tool rules"
            fi
        fi
    done

    log_success "Legacy iptables cleaned"
}

remove_fail2ban() {
    log_info "Removing Fail2ban integration..."

    # Remove NFTBan jail configurations
    rm -f /etc/fail2ban/jail.d/nftban*.conf
    rm -f /etc/fail2ban/filter.d/nftban*.conf
    rm -f /etc/fail2ban/action.d/nftban*.conf
    rm -f /etc/fail2ban/action.d/nftban*.local

    # Reload fail2ban if running
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
        log_info "  Fail2ban reloaded"
    fi

    log_success "Fail2ban integration removed"
}

remove_cron() {
    log_info "Removing cron jobs..."

    # Remove from user crontab
    crontab -l 2>/dev/null | grep -v nftban | crontab - 2>/dev/null || true

    # Remove from system cron directories
    for dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
        if [[ -d "$dir" ]]; then
            find "$dir" -type f -name "*nftban*" -delete 2>/dev/null || true
        fi
    done

    log_success "Cron jobs removed"
}

remove_systemd() {
    log_info "Removing systemd units..."

    # Remove NFTBan systemd units
    rm -f /etc/systemd/system/nftban-*.service
    rm -f /etc/systemd/system/nftban-*.timer

    # Reload systemd
    systemctl daemon-reload

    log_success "Systemd units removed"
}

remove_logrotate() {
    log_info "Removing logrotate config..."
    rm -f /etc/logrotate.d/nftban
    log_success "Logrotate config removed"
}

remove_files() {
    log_info "Removing files..."

    # Remove CLI symlink
    rm -f /usr/local/bin/nftban
    log_info "  Removed CLI symlink"

    # Determine what to remove based on user choices
    if [[ "$REMOVE_CONFIG" == "true" ]] && [[ "$REMOVE_LOGS" == "true" ]] && [[ "$REMOVE_BACKUPS" == "true" ]]; then
        # Complete removal
        rm -rf "$INSTALL_DIR"
        rm -rf "$LOG_DIR"
        log_success "Complete removal: all files deleted"
    else
        # Selective removal
        log_info "  Performing selective removal..."

        # Always remove these
        rm -rf "$INSTALL_DIR/lib"
        rm -rf "$INSTALL_DIR/bin"
        rm -rf "$INSTALL_DIR/scripts"
        rm -rf "$INSTALL_DIR/templates"
        rm -rf "$INSTALL_DIR/cache"
        rm -rf "$INSTALL_DIR/docs"

        # Conditional removals
        if [[ "$REMOVE_CONFIG" == "true" ]]; then
            rm -rf "$INSTALL_DIR/config"
            log_info "  Removed configuration files"
        fi

        if [[ "$REMOVE_LOGS" == "true" ]]; then
            rm -rf "$LOG_DIR"
            log_info "  Removed log files"
        fi

        if [[ "$REMOVE_BACKUPS" == "true" ]]; then
            rm -rf "$INSTALL_DIR/data/backups"
            log_info "  Removed backup files"
        fi

        # Clean up empty directories
        rmdir "$INSTALL_DIR/data" 2>/dev/null || true
        rmdir "$INSTALL_DIR" 2>/dev/null || true

        log_success "Selective removal completed"
    fi
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Uninstaller"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    check_root
    check_installation
    confirm_uninstall

    echo ""
    log_info "Beginning uninstallation..."
    echo ""

    # Create backup before any changes
    create_final_backup

    # Execute removal steps
    stop_services
    clean_nftables
    clean_iptables
    remove_fail2ban
    remove_cron
    remove_systemd
    remove_logrotate
    remove_files

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    log_success "Uninstallation complete!"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Show what was preserved
    if [[ "$REMOVE_CONFIG" == "false" ]] || [[ "$REMOVE_LOGS" == "false" ]] || [[ "$REMOVE_BACKUPS" == "false" ]]; then
        echo "${COLOR_BLUE}Preserved files:${COLOR_RESET}"
        [[ "$REMOVE_CONFIG" == "false" ]] && echo "  • Configuration: $INSTALL_DIR/config/"
        [[ "$REMOVE_LOGS" == "false" ]] && echo "  • Logs: $LOG_DIR/"
        [[ "$REMOVE_BACKUPS" == "false" ]] && echo "  • Backups: $INSTALL_DIR/data/backups/"
        echo ""
    fi

    echo "Thank you for using NFTBan!"
    echo "For reinstallation: cd /home/gituser/github/nftban && sudo bash lib/installer/installer_main.sh install"
    echo ""
}

# Execute main function
main "$@"
