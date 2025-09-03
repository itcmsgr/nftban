#!/bin/bash

################################################################################
# Script: nftban_init.sh
#
# Version: 1.2.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates the installation and configuration of Fail2Ban
# and nftables on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
# It ensures both packages are installed and removes iptables to avoid conflicts.
# After setup, it initializes the environment by copying all relevant files
# from the GitHub repository into the appropriate system directories.
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
################################################################################

#!/bin/bash

# --- Script Configuration ---
BASE_DIR="/etc/nftban"
GITHUB_REPO="https://github.com/itcmsgr/nftban"
TMP_DIR="/tmp/nftban-repo"

# --- Package and Service Definitions ---
FAIL2BAN_PKG="fail2ban"
NFTABLES_PKG="nftables"
IPTABLES_PKG="iptables"
FIREWALLD_PKG="firewalld"
UFW_PKG="ufw"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- Detect Package Manager ---
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_CHECK="rpm -q"
    PKG_REMOVE="dnf remove -y"
    PKG_INSTALL="dnf install -y"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_CHECK="rpm -q"
    PKG_REMOVE="yum remove -y"
    PKG_INSTALL="yum install -y"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
    PKG_CHECK="dpkg -l"
    PKG_REMOVE="apt remove -y"
    PKG_INSTALL="apt install -y"
    apt update -y
else
    echo "Supported package manager not found (dnf/yum/apt)." >&2
    exit 1
fi

# --- Setup Logging ---
LOG_DIR="/var/log/nftban"
LOG_FILE="$LOG_DIR/install_$(date +%Y-%m-%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Starting nftban installation using $PKG_MGR ---"

# --- Directory Tree Initialization ---
echo "Creating directory structure under $BASE_DIR..."
mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates,bin} || { echo "Failed to create directory structure."; exit 1; }

# Create a symlink for logs, ensuring it's pointing to the correct location
if [[ ! -L "$BASE_DIR/logs" ]]; then
    ln -sf "$LOG_DIR" "$BASE_DIR/logs"
    echo "Symlink created from $BASE_DIR/logs to $LOG_DIR."
fi

# --- Package Installation and Removal ---

# Check and install Fail2Ban
echo "Checking for Fail2Ban..."
if ! $PKG_CHECK "$FAIL2BAN_PKG" &>/dev/null; then
    echo "$FAIL2BAN_PKG not installed. Installing..."
    $PKG_INSTALL "$FAIL2BAN_PKG" || { echo "Failed to install $FAIL2BAN_PKG."; exit 1; }
else
    echo "$FAIL2BAN_PKG already installed."
fi

# Remove other firewalls
echo "Checking for other firewall packages..."

# Remove FirewallD
if $PKG_CHECK "$FIREWALLD_PKG" &>/dev/null; then
    echo "$FIREWALLD_PKG found. Stopping and disabling service..."
    systemctl stop firewalld &>/dev/null
    systemctl disable firewalld &>/dev/null
    echo "Removing $FIREWALLD_PKG..."
    $PKG_REMOVE "$FIREWALLD_PKG"
fi

# Remove UFW
if $PKG_CHECK "$UFW_PKG" &>/dev/null; then
    echo "$UFW_PKG found. Stopping and disabling service..."
    systemctl stop ufw &>/dev/null
    systemctl disable ufw &>/dev/null
    echo "Removing $UFW_PKG..."
    $PKG_REMOVE "$UFW_PKG"
fi

# Install NFTables and remove IPTables
echo "Checking for NFTables..."
if ! $PKG_CHECK "$NFTABLES_PKG" &>/dev/null; then
    echo "$NFTABLES_PKG not installed. Installing..."
    if $PKG_CHECK "$IPTABLES_PKG" &>/dev/null; then
        echo "$IPTABLES_PKG found. Removing..."
        $PKG_REMOVE "$IPTABLES_PKG"
    fi
    $PKG_INSTALL "$NFTABLES_PKG" || { echo "Failed to install $NFTABLES_PKG."; exit 1; }
else
    echo "$NFTABLES_PKG already installed."
    if $PKG_CHECK "$IPTABLES_PKG" &>/dev/null; then
        echo "Warning: $IPTABLES_PKG also installed. Consider removing it with: sudo $PKG_REMOVE $IPTABLES_PKG"
    fi
fi

# Check and install Git
echo "Checking for Git..."
if ! command -v git &>/dev/null; then
    echo "Git is not installed. Installing..."
    $PKG_INSTALL git || { echo "Failed to install Git."; exit 1; }
fi

# --- Backup Existing Configuration ---
echo "Creating backup..."
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_FILE="$BASE_DIR/backups/nftban_${TIMESTAMP}_bckp.tar.gz"
tar -czf "$BACKUP_FILE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" --exclude='*/backups/*'
if [[ $? -eq 0 ]]; then
    echo "Backup created: $BACKUP_FILE"
else
    echo "Backup failed. Continuing..."
fi

# --- Sync Repository Files ---
echo "Syncing repository..."
rm -rf "$TMP_DIR"
git clone --depth 1 "$GITHUB_REPO" "$TMP_DIR" || { echo "Failed to clone repo."; exit 1; }

# Copying files from the temporary directory to the correct location
cp -rf "$TMP_DIR"/config/* "$BASE_DIR/config/"
cp -rf "$TMP_DIR"/scripts/* "$BASE_DIR/scripts/"
cp -rf "$TMP_DIR"/templates/* "$BASE_DIR/templates/"
cp -rf "$TMP_DIR"/bin/* "$BASE_DIR/bin/"
cp -f "$TMP_DIR"/README.md "$BASE_DIR/"

# Clean up
rm -rf "$TMP_DIR"

echo "Repository synced successfully."
echo "--- Installation complete. Logs are available in $LOG_FILE ---"
