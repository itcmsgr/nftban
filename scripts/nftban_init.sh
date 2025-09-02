#!/bin/bash

################################################################################
# Script: nftban_init.sh
#
# Version: 1.1.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates the installation and configuration of Fail2Ban
# and nftables on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
# It ensures both packages are installed and removes iptables to avoid conflicts.
# After setup, it initializes the environment by copying all relevant files
# from the GitHub repository into the appropriate system directories.
#
################################################################################

BASE_DIR="/etc/nftban"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/install_$(date +%Y-%m-%d-%H%M%S).log"
GITHUB_REPO="https://github.com/itcmsgr/nftban"
TMP_DIR="/tmp/nftban-repo"

FAIL2BAN_PKG="fail2ban"
NFTABLES_PKG="nftables"
IPTABLES_PKG="iptables"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
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
    echo "Supported package manager not found (dnf/yum/apt)."
    exit 1
fi

# --- Directory Setup ---
if [ ! -d "$BASE_DIR" ]; then
    echo "Creating directory structure under $BASE_DIR..."
    mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates}
    echo "Directory structure created."
else
    echo "Directory structure already exists."
fi

# --- Redirect Logs ---
exec &> "$LOG_FILE"

echo "Starting installation using $PKG_MGR"
echo "--------------------------------------------------------"

# --- Fail2Ban ---
echo "Checking for Fail2Ban..."
if ! $PKG_CHECK "$FAIL2BAN_PKG" &>/dev/null; then
    echo "$FAIL2BAN_PKG not installed. Installing..."
    $PKG_INSTALL "$FAIL2BAN_PKG"
    [[ $? -eq 0 ]] && echo "$FAIL2BAN_PKG installed successfully." || { echo "Failed to install $FAIL2BAN_PKG."; exit 1; }
else
    echo "$FAIL2BAN_PKG already installed."
fi

# --- NFTables & Remove IPTables ---
echo "Checking for NFTables..."
if ! $PKG_CHECK "$NFTABLES_PKG" &>/dev/null; then
    echo "$NFTABLES_PKG not installed. Installing..."
    if $PKG_CHECK "$IPTABLES_PKG" &>/dev/null; then
        echo "$IPTABLES_PKG found. Removing..."
        $PKG_REMOVE "$IPTABLES_PKG"
    fi
    $PKG_INSTALL "$NFTABLES_PKG"
    [[ $? -eq 0 ]] && echo "$NFTABLES_PKG installed successfully." || { echo "Failed to install $NFTABLES_PKG."; exit 1; }
else
    echo "$NFTABLES_PKG already installed."
    if $PKG_CHECK "$IPTABLES_PKG" &>/dev/null; then
        echo "Warning: $IPTABLES_PKG also installed. Consider removing it with: sudo $PKG_REMOVE $IPTABLES_PKG"
    fi
fi

# --- Git ---
echo "Checking for Git..."
if ! command -v git &>/dev/null; then
    echo "Git is not installed. Installing..."
    $PKG_INSTALL git || { echo "Failed to install Git."; exit 1; }
fi

# --- Backup ---
echo "Creating backup..."
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_FILE="$BASE_DIR/backups/nftban_${TIMESTAMP}_bckp.tar.gz"
tar -czf "$BACKUP_FILE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" --exclude='*/backups/*'
[[ $? -eq 0 ]] && echo "Backup created: $BACKUP_FILE" || echo "Backup failed. Continuing..."

# --- Sync Repo ---
echo "Syncing repository..."
rm -rf "$TMP_DIR"
git clone "$GITHUB_REPO" "$TMP_DIR" || { echo "Failed to clone repo."; exit 1; }
cp -rf "$TMP_DIR"/config/* "$BASE_DIR/config/"
cp -rf "$TMP_DIR"/scripts/* "$BASE_DIR/scripts/"
cp -rf "$TMP_DIR"/templates/* "$BASE_DIR/templates/"
cp -f "$TMP_DIR"/README.md "$BASE_DIR/"
rm -rf "$TMP_DIR"

echo "Repository synced."
echo "--------------------------------------------------------"
echo "Installation complete. Logs: $LOG_FILE"
