#!/bin/bash

################################################################################
# Script: nftban_service_control.sh
# Version: 1.3.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Description:
#   Interactive menu to enable/disable Fail2Ban and nftables services,
#   check their configuration, inspect Fail2Ban jails/rules,
#   and view currently banned IPs.
# Change Log:
#   1.0.0 - 2025-09-02
#     - Initial version with enable/disable services.
#   1.2.0 - 2025-09-02
#     - Added config checks, jail status, fail2ban rules.
#   1.3.0 - 2025-09-02
#     - Added banned IPs view for Fail2Ban and nftables.
#
################################################################################

SERVICE_F2B="fail2ban"
SERVICE_NFT="nftables"

# Root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Enable services
enable_services() {
    echo "Enabling and starting $SERVICE_F2B..."
    systemctl enable --now "$SERVICE_F2B"
    echo "Enabling and starting $SERVICE_NFT..."
    systemctl enable --now "$SERVICE_NFT"
    echo "Services enabled."
}

# Disable services
disable_services() {
    echo "Stopping and disabling $SERVICE_F2B..."
    systemctl disable --now "$SERVICE_F2B"
    echo "Stopping and disabling $SERVICE_NFT..."
    systemctl disable --now "$SERVICE_NFT"
    echo "Services disabled."
}

# Check Fail2Ban configuration
check_fail2ban_config() {
    echo "Checking Fail2Ban configuration..."
    fail2ban-client ping &>/dev/null
    if [[ $? -eq 0 ]]; then
        fail2ban-client status
    else
        echo "Fail2Ban is not running or not responding."
    fi
}

# Check nftables configuration
check_nftables_config() {
    echo "Checking nftables configuration..."
    if systemctl is-active --quiet "$SERVICE_NFT"; then
        nft list ruleset
    else
        echo "nftables service is not active."
    fi
}

# View available Fail2Ban jails
view_jails() {
    echo "Listing enabled Fail2Ban jails..."
    fail2ban-client status 2>/dev/null | grep "Jail list:" || echo "No jails found or Fail2Ban not running."
}

# View Fail2Ban jail rules
view_fail2ban_rules() {
    read -p "Enter jail name to view details (e.g., sshd): " jail
    if [[ -n "$jail" ]]; then
        fail2ban-client status "$jail" 2>/dev/null || echo "Jail '$jail' not found or Fail2Ban not running."
    else
        echo "No jail name entered."
    fi
}

# View banned IPs in Fail2Ban
view_banned_ips_fail2ban() {
    echo "Checking banned IPs in Fail2Ban..."
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2)
    if [[ -z "$jails" ]]; then
        echo "No jails found or Fail2Ban not running."
        return
    fi
    for jail in $jails; do
        echo "--- Jail: $jail ---"
        fail2ban-client status "$jail" | grep "Banned IP list"
    done
}

# View banned IPs in nftables
view_banned_ips_nft() {
    echo "Checking banned IPs in nftables..."
    if systemctl is-active --quiet "$SERVICE_NFT"; then
        nft list ruleset | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
    else
        echo "nftables service is not active."
    fi
}

# Display menu
while true; do
    echo "
===== nftban Service Control Menu =====
1) Enable Services
2) Disable Services
3) Check Fail2Ban Configuration
4) Check nftables Configuration
5) View Enabled Fail2Ban Jails
6) View Fail2Ban Jail Rules
7) View Banned IPs (Fail2Ban)
8) View Banned IPs (nftables)
9) Exit"
    read -p "Select an option [1-9]: " choice

    case $choice in
        1) enable_services ;;
        2) disable_services ;;
        3) check_fail2ban_config ;;
        4) check_nftables_config ;;
        5) view_jails ;;
        6) view_fail2ban_rules ;;
        7) view_banned_ips_fail2ban ;;
        8) view_banned_ips_nft ;;
        9) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please select 1-9." ;;
    esac
done
