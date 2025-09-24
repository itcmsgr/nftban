#!/bin/bash

################################################################################
# Script: nftban_uninstall.sh
#
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis) + Enhanced Cleanup
# Description:
# Complete uninstallation of nftban with thorough cleanup
# - Removes all configurations created by installation scripts
# - Cleans up NFTables rules and tables
# - Removes all fail2ban configurations
# - Optional package removal
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
################################################################################

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- Configuration ---
BASE_DIR="/etc/nftban"
LOG_DIR="/var/log/nftban"
PKG_MGR=""
PKG_REMOVE=""
LINK_NFTBAN="/usr/local/bin/nftban"
FAIL2BAN_JAIL_DIR="/etc/fail2ban/jail.d"
FAIL2BAN_FILTER_DIR="/etc/fail2ban/filter.d"
FAIL2BAN_ACTION_DIR="/etc/fail2ban/action.d"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Detect Package Manager ---
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_REMOVE="dnf remove -y"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_REMOVE="yum remove -y"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
    PKG_REMOVE="apt remove -y"
else
    echo "Supported package manager not found (dnf/yum/apt)." >&2
    exit 1
fi

# --- Functions ---
log_action() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

confirm_action() {
    local message="$1"
    local default="${2:-N}"
    
    if [[ "$default" == "Y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi
    
    while true; do
        echo -n -e "${YELLOW}$message $prompt${NC} "
        read -n 1 -r
        echo
        case "$REPLY" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            "") 
                if [[ "$default" == "Y" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# --- Stop and disable services ---
stop_services() {
    log_action "Stopping NFTBAN services..."
    
    # Stop fail2ban
    if systemctl is-active --quiet fail2ban; then
        systemctl stop fail2ban
        echo -e "${GREEN}✓${NC} Stopped fail2ban service"
    fi
    
    # Stop login monitor if exists
    if systemctl is-active --quiet nftban-login-monitor 2>/dev/null; then
        systemctl stop nftban-login-monitor
        systemctl disable nftban-login-monitor
        echo -e "${GREEN}✓${NC} Stopped and disabled login monitor service"
    fi
    
    # Disable fail2ban
    systemctl disable fail2ban &>/dev/null
    echo -e "${GREEN}✓${NC} Disabled fail2ban service"
}

# --- Clean NFTables rules ---
clean_nftables() {
    log_action "Cleaning NFTables rules created by NFTBAN..."
    
    # List all NFTBAN tables
    local nftban_tables=$(nft list tables 2>/dev/null | grep -E "(nftban|NFTBAN_F2B)" | awk '{print $3}')
    
    if [[ -n "$nftban_tables" ]]; then
        echo "Found NFTBAN tables:"
        for table in $nftban_tables; do
            echo "  - $table"
        done
        
        if confirm_action "Remove these NFTables tables?"; then
            for table in $nftban_tables; do
                local table_family=$(nft list tables 2>/dev/null | grep "$table" | awk '{print $2}')
                nft delete table $table_family $table 2>/dev/null && echo -e "${GREEN}✓${NC} Removed table: $table_family $table"
            done
        fi
    else
        echo "No NFTBAN tables found"
    fi
    
    # Clean up any remaining nftban chains or sets
    echo "Checking for remaining NFTBAN components..."
    nft list ruleset 2>/dev/null | grep -i nftban >/dev/null && echo -e "${YELLOW}⚠${NC} Some NFTBAN components may remain in ruleset"
}

# --- Remove fail2ban configurations ---
remove_fail2ban_configs() {
    log_action "Removing NFTBAN fail2ban configurations..."
    
    # Remove jail configurations
    local jail_files=$(find "$FAIL2BAN_JAIL_DIR" -name "nftban-*.conf" 2>/dev/null)
    if [[ -n "$jail_files" ]]; then
        echo "Found jail configurations:"
        echo "$jail_files" | sed 's/^/  - /'
        
        if confirm_action "Remove these jail files?"; then
            find "$FAIL2BAN_JAIL_DIR" -name "nftban-*.conf" -exec echo "Removing: {}" \; -exec rm -f {} \;
            echo -e "${GREEN}✓${NC} Removed jail configurations"
        fi
    fi
    
    # Remove filter configurations
    local filter_files=$(find "$FAIL2BAN_FILTER_DIR" -name "nftban-*.conf" 2>/dev/null)
    if [[ -n "$filter_files" ]]; then
        echo "Found filter configurations:"
        echo "$filter_files" | sed 's/^/  - /'
        
        if confirm_action "Remove these filter files?"; then
            find "$FAIL2BAN_FILTER_DIR" -name "nftban-*.conf" -exec echo "Removing: {}" \; -exec rm -f {} \;
            echo -e "${GREEN}✓${NC} Removed filter configurations"
        fi
    fi
    
    # Remove action configurations
    local action_files=$(find "$FAIL2BAN_ACTION_DIR" -name "nftban-*.conf" -o -name "nftban-*.local" 2>/dev/null)
    if [[ -n "$action_files" ]]; then
        echo "Found action configurations:"
        echo "$action_files" | sed 's/^/  - /'
        
        if confirm_action "Remove these action files?"; then
            find "$FAIL2BAN_ACTION_DIR" -name "nftban-*.conf" -exec echo "Removing: {}" \; -exec rm -f {} \;
            find "$FAIL2BAN_ACTION_DIR" -name "nftban-*.local" -exec echo "Removing: {}" \; -exec rm -f {} \;
            echo -e "${GREEN}✓${NC} Removed action configurations"
        fi
    fi
}

# --- Remove system scripts ---
remove_system_scripts() {
    log_action "Removing system scripts..."
    
    local scripts=(
        "/usr/local/bin/nftban-send-alert.sh"
        "/usr/local/bin/nftban-analyze-offenders.sh" 
        "/usr/local/bin/nftban-check-whitelist.sh"
        "/usr/local/bin/nftban-login-monitor.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            rm -f "$script"
            echo -e "${GREEN}✓${NC} Removed script: $script"
        fi
    done
}

# --- Remove systemd services ---
remove_systemd_services() {
    log_action "Removing systemd services..."
    
    local services=(
        "/etc/systemd/system/nftban-login-monitor.service"
    )
    
    for service in "${services[@]}"; do
        if [[ -f "$service" ]]; then
            rm -f "$service"
            echo -e "${GREEN}✓${NC} Removed service: $service"
        fi
    done
    
    # Reload systemd if any services were removed
    systemctl daemon-reload
}

# --- Remove configuration files ---
remove_configs() {
    log_action "Removing configuration files and directories..."
    
    # Show what will be removed
    if [[ -d "$BASE_DIR" ]]; then
        echo "Directory structure to be removed:"
        find "$BASE_DIR" -type d | sed 's/^/  📁 /'
        echo "Files to be removed:"
        find "$BASE_DIR" -type f | wc -l | sed 's/^/  📄 Total files: /'
        
        if confirm_action "Remove $BASE_DIR directory completely?"; then
            rm -rf "$BASE_DIR"
            echo -e "${GREEN}✓${NC} Removed $BASE_DIR"
        else
            echo -e "${YELLOW}⚠${NC} Keeping $BASE_DIR directory"
            
            # Offer to remove specific subdirectories
            local subdirs=("config" "templates" "scripts" "bin")
            for subdir in "${subdirs[@]}"; do
                if [[ -d "$BASE_DIR/$subdir" ]] && confirm_action "Remove $BASE_DIR/$subdir?"; then
                    rm -rf "$BASE_DIR/$subdir"
                    echo -e "${GREEN}✓${NC} Removed $BASE_DIR/$subdir"
                fi
            done
        fi
    else
        echo "$BASE_DIR not found. Skipping."
    fi
}

# --- Remove log directories ---
remove_logs() {
    if [[ -d "$LOG_DIR" ]]; then
        echo "Log directory contains:"
        ls -la "$LOG_DIR" 2>/dev/null | sed 's/^/  /'
        
        if confirm_action "Remove log directory $LOG_DIR?"; then
            rm -rf "$LOG_DIR"
            echo -e "${GREEN}✓${NC} Removed $LOG_DIR"
        else
            if confirm_action "Remove only NFTBAN log files (keep directory)?"; then
                find "$LOG_DIR" -name "*nftban*" -delete 2>/dev/null
                echo -e "${GREEN}✓${NC} Removed NFTBAN log files"
            fi
        fi
    else
        echo "$LOG_DIR not found. Skipping."
    fi
}

# --- Remove symlinks ---
remove_symlinks() {
    log_action "Removing symlinks..."
    
    if [[ -L "$LINK_NFTBAN" ]]; then
        rm "$LINK_NFTBAN"
        echo -e "${GREEN}✓${NC} Removed symlink: $LINK_NFTBAN"
    else
        echo "Symlink $LINK_NFTBAN not found. Skipping."
    fi
}

# --- Remove logrotate configuration ---
remove_logrotate() {
    local logrotate_files=(
        "/etc/logrotate.d/nftban"
        "/etc/logrotate.d/nftban-login-monitor"
    )
    
    for file in "${logrotate_files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            echo -e "${GREEN}✓${NC} Removed logrotate config: $file"
        fi
    done
}

# --- Remove packages ---
remove_packages() {
    if confirm_action "Do you want to completely remove fail2ban, whois, and DNS utility packages?"; then
        log_action "Removing packages..."
        
        local packages_to_remove=""
        
        # Determine packages based on package manager
        case "$PKG_MGR" in
            "dnf"|"yum")
                packages_to_remove="fail2ban whois bind-utils"
                ;;
            "apt")
                packages_to_remove="fail2ban whois dnsutils"
                ;;
        esac
        
        if [[ -n "$packages_to_remove" ]]; then
            echo "Removing packages: $packages_to_remove"
            $PKG_REMOVE $packages_to_remove
            echo -e "${GREEN}✓${NC} Packages removed"
        fi
    else
        echo -e "${YELLOW}⚠${NC} Packages will remain installed. Only services stopped and configs removed."
    fi
}

# --- Clean up NFTables configuration file ---
clean_nftables_config() {
    if [[ -f "/etc/nftables.conf" ]]; then
        if confirm_action "Remove or clean /etc/nftables.conf (main nftables config)?"; then
            if confirm_action "Completely remove /etc/nftables.conf?" "N"; then
                rm -f /etc/nftables.conf
                echo -e "${GREEN}✓${NC} Removed /etc/nftables.conf"
            else
                # Create backup and clean NFTBAN-specific rules
                cp /etc/nftables.conf /etc/nftables.conf.pre-nftban-removal
                
                # Remove NFTBAN-specific lines (basic cleanup)
                sed -i '/nftban\|NFTBAN/Id' /etc/nftables.conf
                echo -e "${GREEN}✓${NC} Cleaned NFTBAN rules from /etc/nftables.conf"
                echo -e "${BLUE}ℹ${NC} Backup saved as /etc/nftables.conf.pre-nftban-removal"
            fi
        fi
    fi
}

# --- Validate removal ---
validate_removal() {
    log_action "Validating removal..."
    
    local issues=0
    
    # Check for remaining files
    local remaining_files=$(find /etc /usr/local/bin /var/log -name "*nftban*" 2>/dev/null)
    if [[ -n "$remaining_files" ]]; then
        echo -e "${YELLOW}⚠${NC} Some NFTBAN files may still exist:"
        echo "$remaining_files" | sed 's/^/  /'
        issues=$((issues + 1))
    fi
    
    # Check for remaining NFTables rules
    if nft list ruleset 2>/dev/null | grep -qi nftban; then
        echo -e "${YELLOW}⚠${NC} Some NFTBAN NFTables rules may still exist"
        issues=$((issues + 1))
    fi
    
    # Check for remaining fail2ban configurations
    local remaining_f2b=$(find /etc/fail2ban -name "*nftban*" 2>/dev/null)
    if [[ -n "$remaining_f2b" ]]; then
        echo -e "${YELLOW}⚠${NC} Some NFTBAN fail2ban files may still exist:"
        echo "$remaining_f2b" | sed 's/^/  /'
        issues=$((issues + 1))
    fi
    
    if [[ $issues -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} NFTBAN appears to be completely removed"
    else
        echo -e "${YELLOW}⚠${NC} Removal completed with $issues potential issues"
        echo "You may need to manually clean remaining components"
    fi
}

# --- Show removal summary ---
show_summary() {
    echo ""
    echo "=== NFTBAN UNINSTALL SUMMARY ==="
    echo -e "${BLUE}Actions completed:${NC}"
    echo "✓ Services stopped and disabled"
    echo "✓ NFTables rules cleaned"
    echo "✓ Fail2ban configurations removed"
    echo "✓ System scripts removed"
    echo "✓ Configuration directories removed"
    echo "✓ Symlinks removed"
    echo "✓ Log rotation configs removed"
    
    if [[ "$PACKAGES_REMOVED" == "true" ]]; then
        echo "✓ Packages removed"
    else
        echo "- Packages kept (user choice)"
    fi
    
    echo ""
    echo -e "${GREEN}NFTBAN uninstallation completed${NC}"
    echo ""
    echo "If you plan to reinstall NFTBAN:"
    echo "1. Reboot the system to ensure clean state"
    echo "2. Run the installation script again"
    echo ""
    echo "For complete system cleanup, consider:"
    echo "• Rebooting the system"
    echo "• Checking for any remaining custom firewall rules"
    echo "• Reviewing /etc/nftables.conf if it still exists"
}

# --- Main execution ---
main() {
    echo -e "${RED}=== NFTBAN COMPLETE UNINSTALLER ===${NC}"
    echo ""
    echo -e "${YELLOW}WARNING: This will remove ALL NFTBAN components including:${NC}"
    echo "• All configuration files and directories"
    echo "• NFTables rules and tables created by NFTBAN"
    echo "• Fail2ban jail, filter, and action configurations"
    echo "• System scripts and services"
    echo "• Log files and directories"
    echo "• Symlinks and system integration"
    echo ""
    
    if ! confirm_action "Are you sure you want to proceed with complete removal?" "N"; then
        echo "Uninstall cancelled."
        exit 0
    fi
    
    echo ""
    log_action "Starting NFTBAN uninstallation..."
    
    # Execute removal steps
    stop_services
    clean_nftables
    remove_fail2ban_configs
    remove_system_scripts
    remove_systemd_services
    remove_symlinks
    remove_logrotate
    remove_configs
    remove_logs
    clean_nftables_config
    
    # Ask about package removal
    PACKAGES_REMOVED="false"
    if confirm_action "Remove packages (fail2ban, whois, DNS utilities)?"; then
        remove_packages
        PACKAGES_REMOVED="true"
    fi
    
    # Validate and summarize
    echo ""
    validate_removal
    show_summary
}

# Execute main function
main "$@"
