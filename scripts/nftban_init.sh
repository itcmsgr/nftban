#!/bin/bash

################################################################################
# Script: nftban_init.sh
#
# Version: 1.3.1
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates the installation of Fail2Ban, whois, and dnsutils
# on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
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
    git clone --depth 1 "$GITHUB_REPO" "$TMP_DIR" || { echo "Failed to clone repo."; exit 1; }

    # Copy files
    cp -rf "$TMP_DIR"/config/* "$BASE_DIR/config/" 2>/dev/null
    cp -rf "$TMP_DIR"/scripts/* "$BASE_DIR/scripts/" 2>/dev/null
    cp -rf "$TMP_DIR"/templates/* "$BASE_DIR/templates/" 2>/dev/null
    cp -rf "$TMP_DIR"/bin/* "$BASE_DIR/bin/" 2>/dev/null
    cp -f "$TMP_DIR"/README.md "$BASE_DIR/" 2>/dev/null

    # Clean up
    rm -rf "$TMP_DIR"
    echo "✓ Repository synced successfully"
else
    echo "Skipping GitHub sync"
fi

# --- Control Panel Detection and Default Ports Setup ---
read -p "Do you want to detect control panel and setup default ports? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting control panel detection and default ports setup..."
    
    # Create control panel detection script
    CP_SCRIPT="$BASE_DIR/scripts/cp_detection.sh"
    cat > "$CP_SCRIPT" << 'EOF'
#!/bin/bash

BASE_DIR="/etc/nftban"
LOG_FILE="$BASE_DIR/cp_detection_$(date +%Y-%m-%d-%H%M%S).log"

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

process_config() {
    local config_file="$1"
    local panel_name="$2"
    
    TCP4_IN="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
    TCP4_OUT="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
    TCP6_IN="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
    TCP6_OUT="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
    IPV4_WHITELIST="$BASE_DIR/nftban-configuration-ipv4-whitelist-ip.conf"
    IPV6_WHITELIST="$BASE_DIR/nftban-configuration-ipv6-whitelist-ip.conf"
    
    > "$TCP4_IN"
    > "$TCP4_OUT"
    > "$TCP6_IN"
    > "$TCP6_OUT"
    > "$IPV4_WHITELIST"
    > "$IPV6_WHITELIST"
    
    if [ ! -f "$config_file" ]; then
        log_message "ERROR: Configuration file $config_file not found!"
        return 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -z "$line" ]; then
            continue
        fi
        
        case "$line" in
            TCP_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel ports input" >> "$TCP4_IN"
                echo "$ports" | tr ',' '\n' | while read port; do
                    [ -n "$port" ] && echo "${port}T" >> "$TCP4_IN"
                done
                echo "#### End of $panel_name ports" >> "$TCP4_IN"
                ;;
            TCP_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel ports output" >> "$TCP4_OUT"
                echo "$ports" | tr ',' '\n' | while read port; do
                    [ -n "$port" ] && echo "${port}T" >> "$TCP4_OUT"
                done
                echo "#### End of $panel_name ports" >> "$TCP4_OUT"
                ;;
            TCP6_IN*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel IPv6 ports input" >> "$TCP6_IN"
                echo "$ports" | tr ',' '\n' | while read port; do
                    [ -n "$port" ] && echo "${port}T" >> "$TCP6_IN"
                done
                echo "#### End of $panel_name ports" >> "$TCP6_IN"
                ;;
            TCP6_OUT*)
                ports=$(echo "$line" | cut -d'"' -f2)
                echo "# $panel_name panel IPv6 ports output" >> "$TCP6_OUT"
                echo "$ports" | tr ',' '\n' | while read port; do
                    [ -n "$port" ] && echo "${port}T" >> "$TCP6_OUT"
                done
                echo "#### End of $panel_name ports" >> "$TCP6_OUT"
                ;;
            IP_ADDRESS*)
                ips=$(echo "$line" | cut -d'"' -f2)
                if [ -n "$ips" ]; then
                    echo "# $panel_name panel IP addresses" >> "$IPV4_WHITELIST"
                    echo "# $panel_name panel IP addresses" >> "$IPV6_WHITELIST"
                    echo "$ips" | tr ',' '\n' | while read ip; do
                        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        if [ -n "$ip" ]; then
                            if is_ipv4 "$ip"; then
                                echo "$ip" >> "$IPV4_WHITELIST"
                            elif is_ipv6 "$ip"; then
                                echo "$ip" >> "$IPV6_WHITELIST"
                            else
                                log_message "WARNING: Invalid IP format: $ip"
                            fi
                        fi
                    done
                    echo "#### End of $panel_name IP addresses" >> "$IPV4_WHITELIST"
                    echo "#### End of $panel_name IP addresses" >> "$IPV6_WHITELIST"
                else
                    echo "# No IP addresses found for $panel_name panel requirements" >> "$IPV4_WHITELIST"
                    echo "# No IP addresses found for $panel_name panel requirements" >> "$IPV6_WHITELIST"
                fi
                ;;
        esac
    done < "$config_file"
    
    if [ ! -s "$IPV4_WHITELIST" ]; then
        echo "# No IP addresses found for $panel_name panel requirements" > "$IPV4_WHITELIST"
    fi
    
    if [ ! -s "$IPV6_WHITELIST" ]; then
        echo "# No IP addresses found for $panel_name panel requirements" > "$IPV6_WHITELIST"
    fi
    
    log_message "Configuration processed using $panel_name configuration"
}

detect_panel

ACTUAL_CONFIG_FILE=$(get_config_file "$CONFIG_FILE" "$PANEL")
config_result=$?

if [ $config_result -eq 2 ]; then
    log_message "ERROR: No configuration files available. Exiting."
    exit 1
fi

if [ $config_result -eq 0 ]; then
    ACTUAL_PANEL="$PANEL"
else
    ACTUAL_PANEL="generic"
fi

process_config "$ACTUAL_CONFIG_FILE" "$ACTUAL_PANEL"

log_message "Processing complete. Files created:"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv4-whitelist-ip.conf"
log_message "  - $BASE_DIR/nftban-configuration-ipv6-whitelist-ip.conf"

log_message "Process completed successfully"
exit 0
EOF

    chmod +x "$CP_SCRIPT"
    CP_LOG_FILE="$BASE_DIR/cp_detection_$(date +%Y-%m-%d-%H%M%S).log"
    
    echo "Running control panel detection in background..."
    echo "Check log file for details: $CP_LOG_FILE"
    
    nohup bash "$CP_SCRIPT" > "$CP_LOG_FILE" 2>&1 &
    CP_PID=$!
    
    echo "Control panel detection process started with PID: $CP_PID"
    echo "You can check progress with: tail -f $CP_LOG_FILE"
    
    echo "$CP_PID" > "$BASE_DIR/cp_detection.pid"
    echo "✓ Control panel detection started in background"
else
    echo "Skipping control panel detection"
fi

# --- Create Symlink ---
TARGET="$BASE_DIR/bin/nftban"
LINK="/usr/local/bin/nftban"

if [ ! -f "$TARGET" ]; then
    echo "Error: Target file $TARGET does not exist."
    exit 1
fi

if [ -L "$LINK" ]; then
    echo "Symlink already exists: $LINK → $(readlink -f "$LINK")"
else
    echo "Creating symlink..."
    ln -s "$TARGET" "$LINK"
    echo "Symlink created: $LINK → $TARGET"
fi

# --- Set Executable Permissions ---
echo "Setting executable permissions..."
find "$BASE_DIR/scripts" -type f -name "*.sh" ! -perm -111 -exec chmod +x {} \;
chmod +x "$BASE_DIR/bin/nftban"

# --- Post-Installation Notes ---
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

if [[ $REPLY =~ ^[Yy]$ ]] && [[ -f "$BASE_DIR/cp_detection.pid" ]]; then
    CP_PID=$(cat "$BASE_DIR/cp_detection.pid" 2>/dev/null)
    CP_LOG_FILE=$(ls -t "$BASE_DIR/cp_detection_"*.log 2>/dev/null | head -1)
    
    if ps -p "$CP_PID" > /dev/null 2>&1; then
        echo "✓ Control panel detection is running in background (PID: $CP_PID)"
        echo "  Check progress: tail -f $CP_LOG_FILE"
    else
        echo "✓ Control panel detection completed"
        echo "  Check results: cat $CP_LOG_FILE"
        echo "  Files created:"
        echo "    - $BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
        echo "    - $BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
        echo "    - $BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
        echo "    - $BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
        echo "    - $BASE_DIR/nftban-configuration-ipv4-whitelist-ip.conf"
        echo "    - $BASE_DIR/nftban-configuration-ipv6-whitelist-ip.conf"
    fi
    echo ""
fi

echo "=== MANUAL STEPS REQUIRED ==="
echo "1. Initialize nftables environment:"
echo "   execute $BASE_DIR/scripts/nftban_init_nftables_conf.sh"
echo ""
echo "2. Initialize fail2ban environment:"
echo "   execute $BASE_DIR/scripts/nftban_init_fail2ban_conf.sh"
echo ""
echo "3. Review and customize nftban configuration:"
echo "   Check $BASE_DIR/config/ directory"
echo ""
echo "4. Start to use with command: nftban"
echo ""
echo "Installation logs are available in: $LOG_FILE"
echo "================================="
