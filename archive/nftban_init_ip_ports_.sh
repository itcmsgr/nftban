#!/bin/bash

################################################################################
# Script: nftban_init_ip_ports_.sh
#
# Version: 1.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates default ports and IPs if control panel is installed
# on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
################################################################################

# Configuration
BASE_DIR="/etc/nftban"
LOG_FILE="$BASE_DIR/init_install_ip_ports_process_$(date +%Y-%m-%d-%H%M%S).log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to detect control panel
detect_panel() {
    log_message "Checking for running control panel..."
    
    if [ -d "/usr/local/directadmin/" ]; then
        log_message "DirectAdmin detected."
        PANEL="directadmin"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/directadmin.conf"
    elif [ -d "/var/cpanel/" ]; then
        log_message "cPanel detected."
        PANEL="cpanel"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/cpanel.conf"
    elif [ -d "/usr/local/psa/" ]; then
        log_message "Plesk detected."
        PANEL="plesk"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/plesk.conf"
    else
        log_message "No common control panel (DirectAdmin, cPanel, Plesk) detected."
        PANEL="generic"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/generic.conf"
    fi
}

# Function to check if config file exists and fallback to generic if not
get_config_file() {
    local panel_config="$1"
    local panel_name="$2"
    
    if [ -f "$panel_config" ]; then
        log_message "Using $panel_name configuration file: $panel_config"
        echo "$panel_config"
        return 0
    else
        log_message "WARNING: $panel_name configuration file not found: $panel_config"
        log_message "Falling back to generic configuration: $BASE_DIR/templates/control-panels/generic.conf"
        
        if [ -f "$BASE_DIR/templates/control-panels/generic.conf" ]; then
            echo "$BASE_DIR/templates/control-panels/generic.conf"
            return 1
        else
            log_message "ERROR: Generic configuration file also not found!"
            echo ""
            return 2
        fi
    fi
}

# Function to process configuration file
process_config() {
    local config_file="$1"
    local panel_name="$2"
    
    # Output files
    TCP4_IN="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
    TCP4_OUT="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
    TCP6_IN="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
    TCP6_OUT="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
    IPV4_WHITELIST="$BASE_DIR/nftban-configuration-ipv4-whitelist-ip.conf"
    
    # Clear output files
    > "$TCP4_IN"
    > "$TCP4_OUT"
    > "$TCP6_IN"
    > "$TCP6_OUT"
    > "$IPV4_WHITELIST"
    
    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        log_message "ERROR: Configuration file $config_file not found!"
        return 1
    fi
    
    # Read and process the configuration file
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and whitespace
        line=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -z "$line" ]; then
            continue
        fi
        
        # Parse each variable
        case "$line" in
            TCP_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel ports input" >> "$TCP4_IN"
                echo "$ports" | tr ',' '\n' | while read port; do
                    if [ -n "$port" ]; then
                        echo "${port}T" >> "$TCP4_IN"
                    fi
                done
                echo "#### End of $panel_name ports" >> "$TCP4_IN"
                ;;
            TCP_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel ports output" >> "$TCP4_OUT"
                echo "$ports" | tr ',' '\n' | while read port; do
                    if [ -n "$port" ]; then
                        echo "${port}T" >> "$TCP4_OUT"
                    fi
                done
                echo "#### End of $panel_name ports" >> "$TCP4_OUT"
                ;;
            TCP6_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel IPv6 ports input" >> "$TCP6_IN"
                echo "$ports" | tr ',' '\n' | while read port; do
                    if [ -n "$port" ]; then
                        echo "${port}T" >> "$TCP6_IN"
                    fi
                done
                echo "#### End of $panel_name ports" >> "$TCP6_IN"
                ;;
            TCP6_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel IPv6 ports output" >> "$TCP6_OUT"
                echo "$ports" | tr ',' '\n' | while read port; do
                    if [ -n "$port" ]; then
                        echo "${port}T" >> "$TCP6_OUT"
                    fi
                done
                echo "#### End of $panel_name ports" >> "$TCP6_OUT"
                ;;
            IP_ADDRESS*)
                ips=$(echo "$line" | cut -d'"' -f2)
                if [ -n "$ips" ]; then
                    echo "# $panel_name panel IP addresses" >> "$IPV4_WHITELIST"
                    echo "$ips" | tr ',' '\n' | while read ip; do
                        if [ -n "$ip" ]; then
                            echo "$ip" >> "$IPV4_WHITELIST"
                        fi
                    done
                    echo "#### End of $panel_name IP addresses" >> "$IPV4_WHITELIST"
                else
                    echo "# No IP addresses found for $panel_name panel requirements" >> "$IPV4_WHITELIST"
                fi
                ;;
        esac
    done < "$config_file"
    
    # If no IP addresses were found, add a note
    if [ ! -s "$IPV4_WHITELIST" ]; then
        echo "# No IP addresses found for $panel_name panel requirements" > "$IPV4_WHITELIST"
    fi
    
    log_message "Configuration processed using $panel_name configuration"
}

# Create base directory if it doesn't exist
mkdir -p "$BASE_DIR/templates/control-panels"
mkdir -p "$(dirname "$LOG_FILE")"

# Start logging
log_message "Starting control panel detection and configuration process"
log_message "Base directory: $BASE_DIR"

# Main execution
detect_panel

# Get the appropriate config file (fallback to generic if needed)
ACTUAL_CONFIG_FILE=$(get_config_file "$CONFIG_FILE" "$PANEL")
config_result=$?

if [ $config_result -eq 2 ]; then
    log_message "ERROR: No configuration files available. Exiting."
    exit 1
fi

# Determine the actual panel name to use in the output files
if [ $config_result -eq 0 ]; then
    ACTUAL_PANEL="$PANEL"
else
    ACTUAL_PANEL="generic"
fi

# Process the configuration file
process_config "$ACTUAL_CONFIG_FILE" "$ACTUAL_PANEL"

log_message "Processing complete. Files created:"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-whitelist-ip.conf"

log_message "Process completed successfully"
