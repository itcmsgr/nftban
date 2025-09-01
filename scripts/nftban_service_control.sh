#!/bin/bash

################################################################################
# Script: nftban_service_control.sh
# Description:
#   A utility script to enable or disable the Fail2ban and NFTables services.
#
# Usage:
#   sudo ./service_control.sh [enable|disable]
#
# Change Log:
#   1.0.0 - 2025-09-02
#     - Initial version.
#     - Added logic to enable or disable both services.
#
################################################################################

# Define service names
SERVICE_F2B="fail2ban"
SERVICE_NFT="nftables"

# --- Pre-flight Checks ---
# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check for a valid argument
if [[ -z "$1" ]]; then
    echo "Usage: sudo $0 [enable|disable]"
    exit 1
fi

ACTION=$1

# --- Perform action based on argument ---
case "$ACTION" in
    enable)
        echo "➡️ Enabling and starting $SERVICE_F2B service..."
        systemctl enable --now "$SERVICE_F2B"
        if [[ $? -eq 0 ]]; then
            echo "✅ $SERVICE_F2B service is now active."
        else
            echo "❌ Failed to enable or start $SERVICE_F2B."
        fi

        echo ""

        echo "➡️ Enabling and starting $SERVICE_NFT service..."
        systemctl enable --now "$SERVICE_NFT"
        if [[ $? -eq 0 ]]; then
            echo "✅ $SERVICE_NFT service is now active."
        else
            echo "❌ Failed to enable or start $SERVICE_NFT."
        fi
        ;;

    disable)
        echo "➡️ Stopping and disabling $SERVICE_F2B service..."
        systemctl disable --now "$SERVICE_F2B"
        if [[ $? -eq 0 ]]; then
            echo "✅ $SERVICE_F2B service is now inactive."
        else
            echo "❌ Failed to disable or stop $SERVICE_F2B."
        fi

        echo ""

        echo "➡️ Stopping and disabling $SERVICE_NFT service..."
        systemctl disable --now "$SERVICE_NFT"
        if [[ $? -eq 0 ]]; then
            echo "✅ $SERVICE_NFT service is now inactive."
        else
            echo "❌ Failed to disable or stop $SERVICE_NFT."
        fi
        ;;

    *)
        echo "Invalid argument: $ACTION"
        echo "Usage: sudo $0 [enable|disable]"
        exit 1
        ;;
esac

echo ""
echo "Operation completed."
