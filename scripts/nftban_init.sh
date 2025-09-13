#!/bin/bash

################################################################################
# Script: nftban_init.sh
#
# Version: 1.4.1
# Author: ITCMS Team (Antonios Voulvoulis) + Enhanced Control Panel Detection
# Description:
# This script automates the installation of Fail2Ban, whois, and dnsutils
# on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
# Enhanced with improved control panel detection and generic configuration option.
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
# ** NOTE: ONLY INSTALLS PACKAGES - NO SERVICE MANAGEMENT
################################################################################

# --- Script Configuration ---
BASE_DIR="/etc/nftban"
GITHUB_REPO="https://github.com/itcmsgr/nftban"
TMP_DIR="/tmp/nftban-repo"

# --- Package Definitions ---
FAIL2BAN_PKG="fail2ban"
WHOIS_PKG="whois"
DNSUTILS_DEB="dnsutils"          # Debian/Ubuntu
DNSUTILS_RHEL="bind-utils"       # RHEL/CentOS/Fedora

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- Detect Package Manager ---
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_CHECK="rpm -q"
    PKG_INSTALL="dnf install -y"
    DNSUTILS_PKG="$DNSUTILS_RHEL"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_CHECK="rpm -q"
    PKG_INSTALL="yum install -y"
    DNSUTILS_PKG="$DNSUTILS_RHEL"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
    PKG_CHECK="dpkg -l"
    PKG_INSTALL="apt install -y"
    DNSUTILS_PKG="$DNSUTILS_DEB"
else
    echo "Supported package manager not found (dnf/yum/apt)." >&2
    exit 1
fi

# --- EPEL Repository Check (RHEL/CentOS/Fedora only) ---
if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
    if ! rpm -q epel-release &>/dev/null; then
        read -p "EPEL repository is not installed. Do you want to install it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Installing EPEL repository..."
            $PKG_INSTALL epel-release || { echo "Failed to install EPEL repository."; exit 1; }
        else
            echo "EPEL repository is required. Exiting..."
            exit 1
        fi
    else
        echo "✓ EPEL repository already installed"
    fi
fi

# --- Setup Logging ---
LOG_DIR="/var/log/nftban"
LOG_FILE="$LOG_DIR/install_$(date +%Y-%m-%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Starting nftban package installation using $PKG_MGR ---"
echo "--- NOTE: Only installing packages - no service management ---"

# --- Update Package Cache (Debian/Ubuntu only) ---
if [[ "$PKG_MGR" == "apt" ]]; then
    echo "Updating package cache..."
    apt update -y
fi

# --- Confirm Package Installation ---
read -p "Do you want to proceed with installing $FAIL2BAN_PKG, $WHOIS_PKG, and $DNSUTILS_PKG? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Package installation cancelled by user. Exiting..."
    exit 1
fi

# --- Package Installation ---
echo "Installing required packages..."

# Install Fail2Ban
echo "Installing $FAIL2BAN_PKG..."
if ! $PKG_CHECK "$FAIL2BAN_PKG" &>/dev/null; then
    $PKG_INSTALL "$FAIL2BAN_PKG" || { echo "Failed to install $FAIL2BAN_PKG."; exit 1; }
    echo "✓ $FAIL2BAN_PKG installed successfully"
else
    echo "✓ $FAIL2BAN_PKG already installed"
fi

# Install whois
echo "Installing $WHOIS_PKG..."
if ! $PKG_CHECK "$WHOIS_PKG" &>/dev/null; then
    $PKG_INSTALL "$WHOIS_PKG" || { echo "Failed to install $WHOIS_PKG."; exit 1; }
    echo "✓ $WHOIS_PKG installed successfully"
else
    echo "✓ $WHOIS_PKG already installed"
fi

# Install dnsutils/bind-utils
echo "Installing $DNSUTILS_PKG..."
if ! $PKG_CHECK "$DNSUTILS_PKG" &>/dev/null; then
    $PKG_INSTALL "$DNSUTILS_PKG" || { echo "Failed to install $DNSUTILS_PKG."; exit 1; }
    echo "✓ $DNSUTILS_PKG installed successfully"
else
    echo "✓ $DNSUTILS_PKG already installed"
fi

# --- Directory Structure Setup ---
echo "Creating directory structure under $BASE_DIR..."
mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates,bin,templates/control-panels} || { echo "Failed to create directory structure."; exit 1; }

# Create symlink for logs
if [[ ! -L "$BASE_DIR/logs" ]]; then
    ln -sf "$LOG_DIR" "$BASE_DIR/logs"
    echo "✓ Symlink created from $BASE_DIR/logs to $LOG_DIR"
fi

# --- GitHub Repository Sync (Optional) ---
read -p "Do you want to sync configuration from GitHub? (y/N): " -n 1 -r
echo
GITHUB_SYNC_DONE=false
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Syncing repository from GitHub..."
    
    # Check and install Git if needed
    if ! command -v git &>/dev/null; then
        echo "Git is not installed. Installing..."
        $PKG_INSTALL git || { echo "Failed to install Git."; exit 1; }
    fi

    # Backup existing configuration
    echo "Creating backup..."
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    BACKUP_FILE="$BASE_DIR/backups/nftban_${TIMESTAMP}_bckp.tar.gz"
    tar -czf "$BACKUP_FILE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" --exclude='*/backups/*' 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "✓ Backup created: $BACKUP_FILE"
    else
        echo "⚠ Backup failed. Continuing..."
    fi

    # Clone and sync repository
    rm -rf "$TMP_DIR" 2>/dev/null
    if git clone --depth 1 "$GITHUB_REPO" "$TMP_DIR"; then
        # Copy files
        cp -rf "$TMP_DIR"/config/* "$BASE_DIR/config/" 2>/dev/null
        cp -rf "$TMP_DIR"/scripts/* "$BASE_DIR/scripts/" 2>/dev/null
        cp -rf "$TMP_DIR"/templates/* "$BASE_DIR/templates/" 2>/dev/null
        cp -rf "$TMP_DIR"/bin/* "$BASE_DIR/bin/" 2>/dev/null
        cp -f "$TMP_DIR"/README.md "$BASE_DIR/" 2>/dev/null

        # Clean up
        rm -rf "$TMP_DIR"
        echo "✓ Repository synced successfully"
        GITHUB_SYNC_DONE=true
    else
        echo "⚠ Failed to clone repository. Continuing without GitHub sync..."
    fi
else
    echo "Skipping GitHub sync"
fi

# --- Create basic nftban binary if missing ---
if [[ ! -f "$BASE_DIR/bin/nftban" ]]; then
    echo "Creating basic nftban binary..."
    mkdir -p "$BASE_DIR/bin"
    cat > "$BASE_DIR/bin/nftban" << 'NFTBAN_EOF'
#!/bin/bash

################################################################################
# nftban - Basic nftables firewall management tool
# This is a placeholder binary created by the installation script
################################################################################

BASE_DIR="/etc/nftban"
VERSION="1.0.0-placeholder"

show_help() {
    cat << 'EOF'
nftban - nftables firewall management tool

Usage: nftban [COMMAND] [OPTIONS]

Commands:
    help, --help, -h     Show this help message
    version, --version   Show version information
    status              Show nftables status
    list                List current nftables rules
    flush               Flush all nftables rules (WARNING: Use with caution!)
    init                Initialize nftables configuration
    reload              Reload nftables configuration

Configuration files location: /etc/nftban/config/
Log files location: /var/log/nftban/

Note: This is a basic placeholder binary. 
For full functionality, sync with the GitHub repository.
EOF
}

show_version() {
    echo "nftban version $VERSION"
    echo "Configuration directory: $BASE_DIR"
}

case "${1:-help}" in
    help|--help|-h)
        show_help
        ;;
    version|--version)
        show_version
        ;;
    status)
        echo "nftables status:"
        nft list tables 2>/dev/null || echo "No nftables rules found or nftables not available"
        ;;
    list)
        echo "Current nftables rules:"
        nft list ruleset 2>/dev/null || echo "No rules found or insufficient permissions"
        ;;
    flush)
        echo "⚠ WARNING: This will remove all nftables rules!"
        read -p "Are you sure? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            nft flush ruleset && echo "✓ nftables rules flushed" || echo "✗ Failed to flush rules"
        else
            echo "Operation cancelled"
        fi
        ;;
    init)
        if [[ -f "$BASE_DIR/scripts/nftban_init_nftables_conf.sh" ]]; then
            exec "$BASE_DIR/scripts/nftban_init_nftables_conf.sh"
        else
            echo "✗ nftables initialization script not found"
            echo "Run the installation script with GitHub sync enabled"
        fi
        ;;
    reload)
        if [[ -f "$BASE_DIR/config/nft_rules.conf.local" ]]; then
            nft -f "$BASE_DIR/config/nft_rules.conf.local" && echo "✓ nftables rules reloaded" || echo "✗ Failed to reload rules"
        else
            echo "✗ nftables configuration file not found"
            echo "Run: nftban init"
        fi
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'nftban help' for usage information"
        exit 1
        ;;
esac
NFTBAN_EOF

    chmod +x "$BASE_DIR/bin/nftban"
    echo "✓ Basic nftban binary created"
fi

# --- Enhanced Control Panel Detection and Default Ports Setup ---
read -p "Do you want to detect control panel and setup default ports? (y/N): " -n 1 -r
echo
CP_DETECTION_RUN=false
if [[ $REPLY =~ ^[Yy]$ ]]; then
    CP_DETECTION_RUN=true
    echo "Starting control panel detection and default ports setup..."
    
    # Create the enhanced control panel detection script
    CP_SCRIPT="$BASE_DIR/scripts/cp_detection.sh"
    
    cat > "$CP_SCRIPT" << 'EOF'
#!/bin/bash

BASE_DIR="/etc/nftban"
LOG_FILE="$BASE_DIR/logs/cp_detection_$(date +%Y-%m-%d-%H%M%S).log"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check if an IP is IPv4
is_ipv4() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]
}

# Function to check if an IP is IPv6
is_ipv6() {
    [[ "$1" =~ : ]] && [[ "$1" != *.* ]]
}

# Function to get SSH port from configuration
get_ssh_port() {
    local ssh_port
    ssh_port=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
    if [[ -z "$ssh_port" ]]; then
        ssh_port="22"
    fi
    echo "$ssh_port"
}

# Function to create generic configuration template
create_generic_template() {
    local template_file="$BASE_DIR/templates/control-panels/generic.conf"
    local ssh_port=$(get_ssh_port)
    
    log_message "Creating generic configuration template with SSH port: $ssh_port"
    
    mkdir -p "$(dirname "$template_file")"
    
    cat > "$template_file" << 'TEMPLATE_EOF'
# Generic server configuration
# This file contains basic ports for a typical web server setup
# 
# Format:
# TCP_IN="port1,port2,port3"    - Inbound TCP ports
# TCP_OUT="port1,port2,port3"   - Outbound TCP ports  
# TCP6_IN="port1,port2,port3"   - Inbound TCP IPv6 ports
# TCP6_OUT="port1,port2,port3"  - Outbound TCP IPv6 ports
# IP_ADDRESS="ip1,ip2,ip3"      - IP addresses to whitelist

# Basic inbound ports
TCP_IN="SSH_PORT_PLACEHOLDER,80,443"

# Basic outbound ports (DNS, HTTP, HTTPS, NTP)
TCP_OUT="53,80,443,123"

# Basic IPv6 inbound ports
TCP6_IN="SSH_PORT_PLACEHOLDER,80,443"

# Basic IPv6 outbound ports
TCP6_OUT="53,80,443,123"

# No specific IP addresses for generic setup
IP_ADDRESS=""
TEMPLATE_EOF

    # Replace SSH port placeholder
    sed -i "s/SSH_PORT_PLACEHOLDER/$ssh_port/g" "$template_file"
    
    if [[ -f "$template_file" ]]; then
        log_message "Generic configuration template created successfully: $template_file"
        return 0
    else
        log_message "ERROR: Failed to create generic configuration template"
        return 1
    fi
}

# Function to prompt user for generic configuration
prompt_for_generic_config() {
    local ssh_port=$(get_ssh_port)
    
    echo ""
    echo "======================================================"
    echo "No control panel detected on this system."
    echo "======================================================"
    echo ""
    echo "Would you like to create a generic configuration with basic web server ports?"
    echo ""
    echo "This will include:"
    echo "  - SSH port: $ssh_port (detected from /etc/ssh/sshd_config)"
    echo "  - HTTP port: 80"
    echo "  - HTTPS port: 443"
    echo "  - DNS port: 53 (outbound)"
    echo "  - NTP port: 123 (outbound)"
    echo ""
    echo "You can customize these ports later by editing the configuration files."
    echo ""
    
    while true; do
        read -p "Create generic configuration? (y/n): " -n 1 -r
        echo
        case $REPLY in
            [Yy])
                log_message "User selected to create generic configuration"
                return 0
                ;;
            [Nn])
                log_message "User declined to create generic configuration"
                return 1
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

# Function to create empty configuration files
create_empty_configs() {
    local config_dir="$BASE_DIR/config"
    mkdir -p "$config_dir"
    
    local files=(
        "nftban-configuration-ipv4-ports-input-allow.conf.local"
        "nftban-configuration-ipv4-ports-output-allow.conf.local"
        "nftban-configuration-ipv6-ports-input-allow.conf.local"
        "nftban-configuration-ipv6-ports-output-allow.conf.local"
        "nftban-configuration-user-whitelist_ips.conf.local"
    )
    
    for file in "${files[@]}"; do
        local full_path="$config_dir/$file"
        cat > "$full_path" << 'EMPTY_EOF'
# Empty configuration - manually configure as needed
# Generated on: TIMESTAMP_PLACEHOLDER
# 
# Format for port files:
# portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B
#
# Format for whitelist files:
# One IP address per line (IPv4 or IPv6)
# Example: 192.168.1.1, 10.0.0.0/8, 2001:db8::1

EMPTY_EOF
        # Replace timestamp placeholder
        sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "$full_path"
        log_message "Created empty configuration: $full_path"
    done
    
    log_message "Empty configuration files created. Manual configuration required."
}

detect_panel() {
    log_message "Checking for running control panel..."
    
    if [ -d "/usr/local/directadmin/" ]; then
        log_message "DirectAdmin detected."
        PANEL="directadmin"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/directadmin.conf"
        return 0
    elif [ -d "/var/cpanel/" ]; then
        log_message "cPanel detected."
        PANEL="cpanel"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/cpanel.conf"
        return 0
    elif [ -d "/usr/local/psa/" ]; then
        log_message "Plesk detected."
        PANEL="plesk"
        CONFIG_FILE="$BASE_DIR/templates/control-panels/plesk.conf"
        return 0
    else
        log_message "No common control panel (DirectAdmin, cPanel, Plesk) detected."
        
        # Interactive prompt for generic configuration
        if prompt_for_generic_config; then
            PANEL="generic"
            # Create the template first
            if create_generic_template; then
                CONFIG_FILE="$BASE_DIR/templates/control-panels/generic.conf"
                return 0
            else
                log_message "ERROR: Failed to create generic configuration template"
                return 1
            fi
        else
            log_message "User declined generic configuration. Creating empty config files."
            create_empty_configs
            return 2
        fi
    fi
}

get_config_file() {
    local panel_config="$1"
    local panel_name="$2"
    
    if [ -f "$panel_config" ]; then
        log_message "Using $panel_name configuration file: $panel_config"
        echo "$panel_config"
        return 0
    else
        log_message "ERROR: $panel_name configuration file not found: $panel_config"
        return 2
    fi
}

process_config() {
    local config_file="$1"
    local panel_name="$2"
    
    # Use config directory
    local config_dir="$BASE_DIR/config"
    mkdir -p "$config_dir"
    
    TCP4_IN="$config_dir/nftban-configuration-ipv4-ports-input-allow.conf.local"
    TCP4_OUT="$config_dir/nftban-configuration-ipv4-ports-output-allow.conf.local"
    TCP6_IN="$config_dir/nftban-configuration-ipv6-ports-input-allow.conf.local"
    TCP6_OUT="$config_dir/nftban-configuration-ipv6-ports-output-allow.conf.local"
    USER_WHITELIST="$config_dir/nftban-configuration-user-whitelist_ips.conf.local"
    
    # Initialize files with headers
    cat > "$TCP4_IN" << 'CONFIG_EOF'
# IPv4 Input Ports Configuration
# Generated on: TIMESTAMP_PLACEHOLDER
# Control Panel: PANEL_PLACEHOLDER
# Format: portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B

CONFIG_EOF

    cat > "$TCP4_OUT" << 'CONFIG_EOF'
# IPv4 Output Ports Configuration  
# Generated on: TIMESTAMP_PLACEHOLDER
# Control Panel: PANEL_PLACEHOLDER
# Format: portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B

CONFIG_EOF

    cat > "$TCP6_IN" << 'CONFIG_EOF'
# IPv6 Input Ports Configuration
# Generated on: TIMESTAMP_PLACEHOLDER
# Control Panel: PANEL_PLACEHOLDER
# Format: portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B

CONFIG_EOF

    cat > "$TCP6_OUT" << 'CONFIG_EOF'
# IPv6 Output Ports Configuration
# Generated on: TIMESTAMP_PLACEHOLDER
# Control Panel: PANEL_PLACEHOLDER
# Format: portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B

CONFIG_EOF

    cat > "$USER_WHITELIST" << 'CONFIG_EOF'
# User Whitelist IP Configuration
# Generated on: TIMESTAMP_PLACEHOLDER
# Control Panel: PANEL_PLACEHOLDER
# Format: One IP address per line (IPv4 or IPv6)
# Example: 192.168.1.1, 10.0.0.0/8, 2001:db8::1

CONFIG_EOF

    # Replace placeholders in all files
    for file in "$TCP4_IN" "$TCP4_OUT" "$TCP6_IN" "$TCP6_OUT" "$USER_WHITELIST"; do
        sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "$file"
        sed -i "s/PANEL_PLACEHOLDER/$panel_name/" "$file"
    done
    
    if [ ! -f "$config_file" ]; then
        log_message "ERROR: Configuration file $config_file not found!"
        return 1
    fi
    
    log_message "Processing configuration file: $config_file"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and trim whitespace
        line=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -z "$line" ]; then
            continue
        fi
        
        case "$line" in
            TCP_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                if [[ -n "$ports" ]]; then
                    echo "# $panel_name panel TCP input ports" >> "$TCP4_IN"
                    echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
                        port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        [ -n "$port" ] && echo "${port}T" >> "$TCP4_IN"
                    done
                    echo "" >> "$TCP4_IN"
                    log_message "Added TCP input ports: $ports"
                fi
                ;;
            TCP_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                if [[ -n "$ports" ]]; then
                    echo "# $panel_name panel TCP output ports" >> "$TCP4_OUT"
                    echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
                        port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        [ -n "$port" ] && echo "${port}T" >> "$TCP4_OUT"
                    done
                    echo "" >> "$TCP4_OUT"
                    log_message "Added TCP output ports: $ports"
                fi
                ;;
            TCP6_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                if [[ -n "$ports" ]]; then
                    echo "# $panel_name panel TCP IPv6 input ports" >> "$TCP6_IN"
                    echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
                        port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        [ -n "$port" ] && echo "${port}T" >> "$TCP6_IN"
                    done
                    echo "" >> "$TCP6_IN"
                    log_message "Added TCP6 input ports: $ports"
                fi
                ;;
            TCP6_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                if [[ -n "$ports" ]]; then
                    echo "# $panel_name panel TCP IPv6 output ports" >> "$TCP6_OUT"
                    echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
                        port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        [ -n "$port" ] && echo "${port}T" >> "$TCP6_OUT"
                    done
                    echo "" >> "$TCP6_OUT"
                    log_message "Added TCP6 output ports: $ports"
                fi
                ;;
            IP_ADDRESS*)
                ips=$(echo "$line" | cut -d'"' -f2)
                if [ -n "$ips" ]; then
                    echo "# $panel_name panel IP addresses" >> "$USER_WHITELIST"
                    echo "$ips" | tr ',' '\n' | while IFS= read -r ip; do
                        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        if [ -n "$ip" ]; then
                            if is_ipv4 "$ip" || is_ipv6 "$ip"; then
                                echo "$ip" >> "$USER_WHITELIST"
                                log_message "Added IP to whitelist: $ip"
                            else
                                log_message "WARNING: Invalid IP format: $ip"
                            fi
                        fi
                    done
                    echo "" >> "$USER_WHITELIST"
                fi
                ;;
        esac
    done < "$config_file"
    
    log_message "Configuration processed using $panel_name configuration"
    
    # Show summary of created files
    echo ""
    echo "=== Configuration Files Created ==="
    for file in "$TCP4_IN" "$TCP4_OUT" "$TCP6_IN" "$TCP6_OUT" "$USER_WHITELIST"; do
        if [ -f "$file" ]; then
            line_count=$(grep -v '^#' "$file" | grep -v '^$' | wc -l)
            echo "✓ $(basename "$file") ($line_count entries)"
            log_message "Created: $file ($line_count entries)"
        fi
    done
    echo "=================================="
    
    return 0
}

# Main execution
log_message "Starting control panel detection..."

# Initialize variables
PANEL=""
CONFIG_FILE=""

# Detect panel
detect_panel
panel_detection_result=$?

case $panel_detection_result in
    0)
        # Panel detected or generic config accepted
        log_message "Panel configuration: $PANEL"
        log_message "Config file: $CONFIG_FILE"
        
        ACTUAL_CONFIG_FILE=$(get_config_file "$CONFIG_FILE" "$PANEL")
        config_result=$?
        
        if [ $config_result -eq 0 ]; then
            if process_config "$ACTUAL_CONFIG_FILE" "$PANEL"; then
                echo ""
                echo "=== Control Panel Detection Complete ==="
                echo "✓ Detected: $PANEL"
                echo "✓ Configuration applied successfully"
                echo "✓ Files are ready for nftables initialization"
                echo ""
                echo "Next steps:"
                echo "1. Review the generated configuration files in: $BASE_DIR/config/"
                echo "2. Run: $BASE_DIR/scripts/nftban_init_nftables_conf.sh"
                echo "========================================="
                
                log_message "Control panel detection and configuration completed successfully"
                exit 0
            else
                log_message "ERROR: Failed to process configuration"
                exit 1
            fi
        else
            log_message "ERROR: Failed to get configuration file"
            exit 1
        fi
        ;;
    2)
        # User declined generic config - empty files created
        echo ""
        echo "=== Manual Configuration Required ==="
        echo "✓ Empty configuration files created"
        echo "✗ No automatic port configuration applied"
        echo ""
        echo "Manual steps required:"
        echo "1. Edit configuration files in: $BASE_DIR/config/"
        echo "2. Add required ports and IP addresses"
        echo "3. Run: $BASE_DIR/scripts/nftban_init_nftables_conf.sh"
        echo "====================================="
        
        log_message "Empty configuration files created. Manual configuration required."
        exit 0
        ;;
    *)
        log_message "ERROR: Panel detection failed with code: $panel_detection_result"
        exit 1
        ;;
esac

log_message "Process completed successfully"
exit 0
EOF

    chmod +x "$CP_SCRIPT"
    
    echo "Running enhanced control panel detection..."
    echo "This process will:"
    echo "  - Detect installed control panels (cPanel, DirectAdmin, Plesk)"
    echo "  - Offer generic configuration if no panel is found"
    echo "  - Create appropriate port configuration files"
    echo ""
    
    # Run the script directly (not in background) for interactive prompts
    if bash "$CP_SCRIPT"; then
        echo ""
        echo "✓ Control panel detection completed successfully"
        
        # Check what was created
        CONFIG_FILES_CREATED=$(find "$BASE_DIR/config" -name "nftban-configuration-*.conf.local" 2>/dev/null | wc -l)
        if [[ $CONFIG_FILES_CREATED -gt 0 ]]; then
            echo "✓ $CONFIG_FILES_CREATED configuration files created"
            echo ""
            echo "Generated configuration files:"
            find "$BASE_DIR/config" -name "nftban-configuration-*.conf.local" 2>/dev/null | while read file; do
                entries=$(grep -v '^#' "$file" | grep -v '^$' | wc -l 2>/dev/null || echo "0")
                echo "  - $(basename "$file") ($entries entries)"
            done
        else
            echo "⚠ No configuration files were created"
        fi
    else
        echo "⚠ Control panel detection encountered an issue"
        echo "Check the log file for details: $BASE_DIR/logs/cp_detection_*.log"
    fi
    
else
    echo "Skipping control panel detection"
    echo ""
    echo "⚠ Manual configuration will be required"
    echo "You'll need to create these files manually:"
    echo "  - $BASE_DIR/config/nftban-configuration-ipv4-ports-input-allow.conf.local"
    echo "  - $BASE_DIR/config/nftban-configuration-ipv4-ports-output-allow.conf.local"
    echo "  - $BASE_DIR/config/nftban-configuration-ipv6-ports-input-allow.conf.local"
    echo "  - $BASE_DIR/config/nftban-configuration-ipv6-ports-output-allow.conf.local"
    echo "  - $BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
fi

# --- Create Symlink ---
TARGET="$BASE_DIR/bin/nftban"
LINK="/usr/local/bin/nftban"

if [ ! -f "$TARGET" ]; then
    echo "Warning: Target file $TARGET does not exist, but continuing..."
elif [ -L "$LINK" ]; then
    echo "Symlink already exists: $LINK → $(readlink -f "$LINK")"
else
    echo "Creating symlink..."
    ln -s "$TARGET" "$LINK"
    echo "Symlink created: $LINK → $TARGET"
fi

# --- Set Executable Permissions ---
echo "Setting executable permissions..."
find "$BASE_DIR/scripts" -type f -name "*.sh" ! -perm -111 -exec chmod +x {} \; 2>/dev/null
if [[ -f "$BASE_DIR/bin/nftban" ]]; then
    chmod +x "$BASE_DIR/bin/nftban"
fi

# --- Enhanced Post-Installation Notes ---
echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "✓ Packages installed:"
echo "  - $FAIL2BAN_PKG"
echo "  - $WHOIS_PKG" 
echo "  - $DNSUTILS_PKG"
echo ""
echo "✓ nftban linked to /usr/local/bin/nftban"
echo ""
echo "✓ Scripts are executable"

# Enhanced status reporting for control panel detection
if [[ $CP_DETECTION_RUN == true ]]; then
    # Check if configuration files were created
    CONFIG_FILES_CREATED=$(find "$BASE_DIR/config" -name "nftban-configuration-*.conf.local" 2>/dev/null | wc -l)
    
    if [[ $CONFIG_FILES_CREATED -gt 0 ]]; then
        echo ""
        echo "=== CONTROL PANEL CONFIGURATION ==="
        
        # Determine what type of configuration was applied
        if [[ -f "$BASE_DIR/logs/cp_detection_"*.log ]]; then
            LATEST_LOG=$(ls -t "$BASE_DIR/logs/cp_detection_"*.log 2>/dev/null | head -1)
            if grep -q "DirectAdmin detected" "$LATEST_LOG" 2>/dev/null; then
                echo "✓ DirectAdmin control panel detected and configured"
            elif grep -q "cPanel detected" "$LATEST_LOG" 2>/dev/null; then
                echo "✓ cPanel control panel detected and configured"
            elif grep -q "Plesk detected" "$LATEST_LOG" 2>/dev/null; then
                echo "✓ Plesk control panel detected and configured"
            elif grep -q "User selected to create generic configuration" "$LATEST_LOG" 2>/dev/null; then
                SSH_PORT_USED=$(grep -o "SSH port: [0-9]*" "$LATEST_LOG" | cut -d' ' -f3)
                echo "✓ Generic web server configuration applied"
                echo "  - SSH port: ${SSH_PORT_USED:-22}"
                echo "  - HTTP/HTTPS ports: 80, 443"
                echo "  - DNS/NTP outbound: 53, 123"
            elif grep -q "User declined generic configuration" "$LATEST_LOG" 2>/dev/null; then
                echo "⚠ Empty configuration files created"
                echo "  Manual configuration required"
            fi
        fi
        
        echo ""
        echo "✓ Configuration files created ($CONFIG_FILES_CREATED files):"
        find "$BASE_DIR/config" -name "nftban-configuration-*.conf.local" 2>/dev/null | while read file; do
            entries=$(grep -v '^#' "$file" | grep -v '^$' | wc -l 2>/dev/null || echo "0")
            filename=$(basename "$file")
            case "$filename" in
                *"input"*) echo "  - $filename ($entries inbound rules)" ;;
                *"output"*) echo "  - $filename ($entries outbound rules)" ;;
                *"whitelist"*) echo "  - $filename ($entries whitelisted IPs)" ;;
                *) echo "  - $filename ($entries entries)" ;;
            esac
        done
        echo "==================================="
    else
        echo ""
        echo "⚠ Control panel detection completed but no configuration files were created"
        echo "Manual configuration will be required"
    fi
fi

echo ""
echo "=== NEXT STEPS ==="
echo "1. Initialize nftables environment:"
if [[ -f "$BASE_DIR/scripts/nftban_init_nftables_conf.sh" ]]; then
    echo "   sudo $BASE_DIR/scripts/nftban_init_nftables_conf.sh"
else
    echo "   ⚠ nftables initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
fi
echo ""

echo "2. Initialize fail2ban environment:"
if [[ -f "$BASE_DIR/scripts/nftban_init_fail2ban_conf.sh" ]]; then
    echo "   sudo $BASE_DIR/scripts/nftban_init_fail2ban_conf.sh"
else
    echo "   ⚠ fail2ban initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
fi
echo ""

# Conditional step 3 based on whether config files were created
CONFIG_FILES_CREATED=$(find "$BASE_DIR/config" -name "nftban-configuration-*.conf.local" 2>/dev/null | wc -l)
if [[ $CONFIG_FILES_CREATED -gt 0 ]]; then
    # Check if manual configuration is needed
    TOTAL_ENTRIES=0
    for file in "$BASE_DIR/config/nftban-configuration-"*".conf.local"; do
        if [[ -f "$file" ]]; then
            entries=$(grep -v '^#' "$file" | grep -v '^$' | wc -l 2>/dev/null || echo "0")
            TOTAL_ENTRIES=$((TOTAL_ENTRIES + entries))
        fi
    done
    
    if [[ $TOTAL_ENTRIES -gt 0 ]]; then
        echo "3. (Optional) Review and customize configuration:"
        echo "   Configuration files in: $BASE_DIR/config/"
        echo "   Current configuration has $TOTAL_ENTRIES total rules/entries"
    else
        echo "3. REQUIRED: Configure ports and IP addresses:"
        echo "   Edit files in: $BASE_DIR/config/"
        echo "   Add your required ports and whitelisted IPs"
    fi
else
    echo "3. REQUIRED: Create configuration files:"
    echo "   Create and configure files in: $BASE_DIR/config/"
    if [[ $GITHUB_SYNC_DONE == true ]]; then
        echo "   Templates available in: $BASE_DIR/templates/"
    else
        echo "   Consider re-running with GitHub sync enabled for templates"
    fi
fi

echo ""
echo "4. Start using nftban:"
echo "   nftban --help"
echo ""

# Show relevant log files
echo "=== LOG FILES ==="
echo "Installation log: $LOG_FILE"
if [[ -f "$BASE_DIR/logs/cp_detection_"*.log ]]; then
    LATEST_CP_LOG=$(ls -t "$BASE_DIR/logs/cp_detection_"*.log 2>/dev/null | head -1)
    echo "Control panel detection log: $LATEST_CP_LOG"
fi
echo "================================="

# Final status
echo ""
if [[ $GITHUB_SYNC_DONE == true ]]; then
    echo "🎉 Installation completed successfully with GitHub sync!"
else
    echo "⚠ Installation completed with basic functionality only."
    echo "For full features, consider re-running with GitHub sync enabled."
fi
echo ""
