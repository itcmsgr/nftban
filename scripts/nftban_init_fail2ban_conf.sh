#!/bin/bash
################################################################################
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 1.1
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# Automates fail2ban configuration on Linux (RHEL 8+/Fedora/CentOS/Debian/Ubuntu)
################################################################################

#!/bin/bash

# Function to get current timestamp
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
            # Add reset logic here if needed
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
    echo "Fail2Ban is not running."
    exit 1
fi

# Check if jail.local exists
if [ -f /etc/fail2ban/jail.local ]; then
    echo "File /etc/fail2ban/jail.local exists."
    read -rp "Do you want to rename it to jail.local_$timestamp? [yes/no]: " rename_jail
    if [ "$rename_jail" == "yes" ]; then
        mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local_"$timestamp"
        echo "Renamed jail.local."
    else
        echo "Exiting."
        exit 0
    fi
fi

# Check if whitelist config exists
if [ ! -f /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local ]; then
    echo "Whitelist config not found."
    echo "You need to run 'nftables init' first.: /etc/nftban/scripts/nftban_init_nftables_conf.sh"
    exit 1
fi

# Check if fail2ban config exists
fail2ban_conf="/etc/nftban/config/nftban-configuration-fail2ban.conf"
template_conf="/etc/fail2ban/templates/fail2ban/nftban-configuration-fail2ban.conf"

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
    if [ "$overwrite" == "yes" ]; then
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

# Overwrite all nftban-*.conf files
template_dir="/etc/fail2ban/templates/fail2ban"
target_dir="/etc/fail2ban"

for file in "$template_dir"/nftban-*.conf; do
    cp "$file" "$target_dir"/
    echo "Copied $(basename "$file")"
done

# Rename unknown jail.d templates
jail_template_dir="/etc/fail2ban/templates/fail2ban/jail.d"
jail_dir="/etc/fail2ban/jail.d"

for file in "$jail_dir"/fail2ban-*.conf; do
    base=$(basename "$file")
    if [ ! -f "$jail_template_dir/$base" ]; then
        mv "$file" "$jail_dir/unknown-$base"
        echo "Renamed $base to unknown-$base"
    fi
done

echo "Script completed."
