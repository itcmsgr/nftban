#!/bin/bash
################################################################################
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 2.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# Automates fail2ban configuration on Linux (RHEL 8+/Fedora/CentOS/Debian/Ubuntu)
################################################################################

BASE_DIR="/etc/nftban"
JAIL_TEMPLATE_DIR="$BASE_DIR/templates/fail2ban/jail.d"
FAIL2BAN_TEMPLATE_DIR="/etc/fail2ban/jail.d"
timestamp=$(date +"%Y%m%d_%H%M%S")

# Check if fail2ban is running
if systemctl is-active --quiet fail2ban; then
    echo "Fail2Ban is running."
    echo "Options: [stop] [continue] [reset conf] [exit]"
    read -rp "Choose an option: " option
    case "$option" in
        stop)
            echo "Stopping Fail2Ban..."
            sudo systemctl stop fail2ban
            ;;
        continue)
            echo "Continuing..."
            ;;
        "reset conf")
            echo "Resetting configuration..."
            # Add actual reset logic here
            ;;
        exit)
            echo "Exiting script."
            exit 0
            ;;
        *)
            echo "Invalid option. Exiting."
            exit 1
            ;;
    esac
else
    echo "Fail2Ban is not running. This might be expected for configuration changes."
    read -rp "Do you want to continue? [yes/no]: " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        exit 1
    fi
fi

# Check if jail.local exists
if [ -f /etc/fail2ban/jail.local ]; then
    echo "File /etc/fail2ban/jail.local exists."
    read -rp "Do you want to rename it to jail.local_$timestamp? [yes/no]: " rename_jail
    if [[ "$rename_jail" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        sudo mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local_"$timestamp"
        echo "Renamed jail.local."
    else
        echo "Exiting."
        exit 0
    fi
fi

# Check if whitelist config exists
if [ ! -f "$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local" ]; then
    echo "Whitelist config not found."
    echo "You need to run 'nftables init' first: /etc/nftban/scripts/nftban_init_nftables_conf.sh"
    exit 1
fi

# Check if fail2ban config exists
fail2ban_conf="$BASE_DIR/config/nftban-configuration-fail2ban.conf"
template_conf="$BASE_DIR/templates/fail2ban/nftban-configuration-fail2ban.conf"

if [ ! -f "$fail2ban_conf" ]; then
    echo "Fail2Ban config not found."
    if [ -f "$template_conf" ]; then
        echo "Template exists. Copying..."
        cp "$template_conf" "$fail2ban_conf"
    else
        echo "Template not found. Cannot proceed."
        exit 1
    fi
else
    echo "Fail2Ban config exists and will be overwritten."
    read -rp "Do you want to continue? [yes/no]: " overwrite
    if [[ "$overwrite" =~ ^[Yy][Ee]?[Ss]?$ ]]; then
        cp "$template_conf" "$fail2ban_conf"
        echo "Overwritten."
    else
        echo "Exiting."
        exit 0
    fi
fi

# Copy .local version if not exists
local_conf="${fail2ban_conf}.local"
if [ ! -f "$local_conf" ]; then
    cp "$fail2ban_conf" "$local_conf"
    echo "Copied to .local version."
fi

# Copy all nftban-*.conf files
for file in "$JAIL_TEMPLATE_DIR"/nftban-*.conf; do
    if [ -f "$file" ]; then
        sudo cp "$file" "$FAIL2BAN_TEMPLATE_DIR"/
        echo "Copied $(basename "$file")"
    fi
done

# Check for any unknown files in template directory and handle them
for file in "$JAIL_TEMPLATE_DIR"/*.conf; do
    if [ -f "$file" ]; then
        base=$(basename "$file")
        if [[ "$base" != nftban-* ]]; then
            echo "Found unknown config file: $base"
            # Handle unknown files appropriately
        fi
    fi
done

echo "Script completed."
