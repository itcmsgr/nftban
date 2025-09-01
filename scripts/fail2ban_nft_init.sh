#!/bin/bash

################################################################################
# Script: fail2ban_nft_init.sh
#
# Version: 1.0.0
# Author: ITCMS Team ( Antonios Voulvoulis )
# Description:
# This script automates the installation and configuration of Fail2Ban
# and nftables on Red Hat 8+ systems, including CentOS and Fedora.
# It ensures both packages are installed and removes iptables to avoid conflicts.
# After setup, it initializes the environment by copying all relevant files
# from the GitHub repository into the appropriate system directories.
#
# Change Log:
#   1.0.0 - 2025-09-01
#     - Initial version of the script.
#     - Added logic to check for and install fail2ban.
#     - Added logic to check for and install nftables.
#     - Included a check to remove iptables if it's present.
#     - Added logging to a timestamped file under /etc/itcms/logs.
#
#   Future Changes:
#   - Add configuration for Fail2Ban after installation.
#   - Add basic NFTables firewall rules.
#
################################################################################

# Define the base directory for the nftban project
BASE_DIR="/etc/nftban"
# Define log directory and file name
LOG_DIR="/etc/nftban/logs"
LOG_FILE="$LOG_DIR/install_$(date +%Y-%m-%d-%H%M%S).log"
# Define repository information and local paths
GITHUB_REPO="https://github.com/itcmsgr/nftban"
TMP_DIR="/tmp/nftban-repo"

# Define packages
FAIL2BAN_PKG="fail2ban"
NFTABLES_PKG="nftables"
IPTABLES_PKG="iptables"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check for dnf availability
if ! command -v dnf &> /dev/null; then
    echo "❌ dnf package manager not found. This script requires dnf."
    exit 1
fi

# Check if the base directory already exists if not create
if [ ! -d "$BASE_DIR" ]; then
    echo "Directory structure for $BASE_DIR does not exist. Creating now..."
    # The -p flag creates parent directories if they don't exist,
    # and prevents an error if the directory already exists.
    mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates}
    echo "✅ Directory structure created successfully."
else
    echo "✅ Directory structure already exists at $BASE_DIR. No action needed."
fi

# Redirect all script output to the log file
exec &> "$LOG_FILE"

echo "🚀 Starting security package check and installation for Red Hat 8+..."
echo "--------------------------------------------------------"

# --- Fail2Ban Check and Installation ---
echo "➡️ Checking for Fail2Ban..."
if ! rpm -q "$FAIL2BAN_PKG" &> /dev/null; then
    echo "    $FAIL2BAN_PKG is not installed. Installing now..."
    dnf install -y "$FAIL2BAN_PKG"
    case $? in
        0) echo "    ✅ $FAIL2BAN_PKG installed successfully." ;;
        *) echo "    ❌ Failed to install $FAIL2BAN_PKG." ; exit 1 ;;
    esac
else
    echo "    ✅ $FAIL2BAN_PKG is already installed."
fi

echo "--------------------------------------------------------"

# --- NFTables Check and Installation (and IPTables Removal) ---
echo "➡️ Checking for NFTables and managing IPTables..."
if ! rpm -q "$NFTABLES_PKG" &> /dev/null; then
    echo "    $NFTABLES_PKG is not installed. Installing and removing $IPTABLES_PKG if present..."
    
    # Check if IPTables is installed and remove it to prevent conflicts
    if rpm -q "$IPTABLES_PKG" &> /dev/null; then
        echo "    ⚠️ $IPTABLES_PKG is installed. Removing it before installing $NFTABLES_PKG."
        dnf remove -y "$IPTABLES_PKG"
        case $? in
            0) echo "    ✅ $IPTABLES_PKG removed successfully." ;;
            *) echo "    ❌ Failed to remove $IPTABLES_PKG. Please do so manually and rerun." ; exit 1 ;;
        esac
    else
        echo "    ✅ $IPTABLES_PKG is not installed. Proceeding with $NFTABLES_PKG installation."
    fi

    dnf install -y "$NFTABLES_PKG"
    case $? in
        0) 
            echo "    ✅ $NFTABLES_PKG installed successfully."
            echo "    ✅ Enabling and starting $NFTABLES_PKG service..."
            systemctl enable --now nftables
            if [[ $? -eq 0 ]]; then
                echo "    ✅ NFTables service is now active."
            else
                echo "    ⚠️ Failed to enable or start nftables service."
            fi
            ;;
        *) 
            echo "    ❌ Failed to install $NFTABLES_PKG."
            exit 1 
            ;;
    esac
else
    echo "    ✅ $NFTABLES_PKG is already installed."
    
    # Check if IPTables is still present and suggest removal
    if rpm -q "$IPTABLES_PKG" &> /dev/null; then
        echo "    ⚠️ Warning: Both $NFTABLES_PKG and $IPTABLES_PKG are installed. It's recommended to remove $IPTABLES_PKG to avoid conflicts."
        echo "    To remove it, run: 'sudo dnf remove -y $IPTABLES_PKG'"
    fi
fi

echo "--------------------------------------------------------"
echo " Starting sync repo update script "
echo "--------------------------------------------------------"
# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Git is not installed. Please install it with: 'sudo dnf install git -y'"
    exit 1
fi

# --- Create a backup of the existing directory before syncing ---
echo "➡️ Creating a backup of the existing $BASE_DIR..."
# Get the current timestamp
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_FILE="$BASE_DIR/backups/nftban_"$TIMESTAMP"_bckp.tar.gz"

# Create the compressed tar archive, excluding the backup file itself to prevent issues
tar -czf "$BACKUP_FILE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" --exclude='*/backups/*'
if [[ $? -ne 0 ]]; then
    echo "❌ Failed to create backup. Continuing with sync..."
else
    echo "✅ Backup created successfully at $BACKUP_FILE."
fi

echo "🚀 Starting synchronization of GitHub repository to local directories..."
echo "--------------------------------------------------------"

# --- Clone the repository to a temporary directory ---
echo "➡️ Cloning repository from $GITHUB_REPO..."
git clone "$GITHUB_REPO" "$TMP_DIR"
if [[ $? -ne 0 ]]; then
    echo "❌ Failed to clone the repository. Please check the URL and your network connection."
    exit 1
fi
echo "✅ Repository cloned successfully to $TMP_DIR."

# --- Copy contents to the permanent directories ---
echo "➡️ Copying files to $BASE_DIR..."
# The -r flag ensures a recursive copy. The -f flag forces the overwrite of existing files.
cp -rf "$TMP_DIR"/config/* "$BASE_DIR/config/"
cp -rf "$TMP_DIR"/scripts/* "$BASE_DIR/scripts/"
cp -rf "$TMP_DIR"/templates/* "$BASE_DIR/templates/"
cp -f "$TMP_DIR"/README.md "$BASE_DIR/"

echo "✅ Files copied successfully."

# --- Cleanup temporary directory ---
echo "➡️ Cleaning up temporary directory $TMP_DIR..."
rm -rf "$TMP_DIR"
if [[ $? -eq 0 ]]; then
    echo "✅ Temporary directory cleaned up."
else
    echo "❌ Failed to remove temporary directory. Please remove manually."
    exit 1
fi

echo "--------------------------------------------------------"
echo "✅ Synchronization complete."
echo "✅ Script complete. System security packages are configured."
