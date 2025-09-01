#!/bin/bash

################################################################################
# Script: nftban_service_control.sh
# Version: 1.1.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Description:
#   Interactive menu to enable/disable Fail2Ban and nftables services,
#   and placeholder for future configuration check.
# Change Log:
#   1.0.0 - 2025-09-02
#     - Initial version.
#     - Added logic to enable or disable both services.
#
################################################################################


SERVICE_F2B="fail2ban"
SERVICE_NFT="nftables"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Function to enable services
enable_services() {
    echo "➡️ Enabling and starting $SERVICE_F2B..."
    systemctl enable --now "$SERVICE_F2B"
    echo "➡️ Enabling and starting $SERVICE_NFT..."
    systemctl enable --now "$SERVICE_NFT"
    echo "✅ Services enabled."
}

# Function to disable services
disable_services() {
    echo "➡️ Stopping and disabling $SERVICE_F2B..."
    systemctl disable --now "$SERVICE_F2B"
    echo "➡️ Stopping and disabling $SERVICE_NFT..."
    systemctl disable --now "$SERVICE_NFT"
    echo "✅ Services disabled."
}

# Placeholder for configuration check
check_configuration() {
    echo "🔍 Configuration check feature is under development."
}

# Placeholder for recreate configuration
recreate_configuration() {
    echo "🔧 Recreate configuration feature is under development."
}

# Display menu
while true; do
    echo "
===== nftban Service Control Menu ====="
    echo "1) Enable Services"
    echo "2) Disable Services"
    echo "3) Check Configuration (Coming Soon)"
    echo "4) Recreate Configuration (Coming Soon)"
    echo "5) Exit"
    read -p "Select an option [1-5]: " choice

    case $choice in
        1) enable_services ;;
        2) disable_services ;;
        3) check_configuration ;;
        4) recreate_configuration ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please select 1-5." ;;
    esac

done
