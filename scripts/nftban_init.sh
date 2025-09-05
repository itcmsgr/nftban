#!/bin/bash

################################################################################
# Script: nftban_init.sh
#
# Version: 1.2.2
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
mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates,bin} || { echo "Failed to create directory structure."; exit 1; }

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

 # Check if exist link to make nftban available without need the full path
TARGET="$BASE_DIR/bin/nftban"
LINK="/usr/local/bin/nftban"

# Check if the nftban file exists under 
if [ ! -f "$TARGET" ]; then
    echo "Error: Target file $TARGET does not exist."
    exit 1
fi

# Check if the symlink already exists
if [ -L "$LINK" ]; then
    echo "Symlink already exists: $LINK → $(readlink -f "$LINK")"
else
    echo "Creating symlink..."
    sudo ln -s "$TARGET" "$LINK"
    echo "Symlink created: $LINK → $TARGET"
fi

# Ensure the nftban file is executable
if [ ! -x "$TARGET" ]; then
    chmod +x "$TARGET"
fi


# --- Post-Installation Notes ---
echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "✓ Packages installed:"
echo "  - $FAIL2BAN_PKG"
echo "  - $WHOIS_PKG" 
echo "  - $DNSUTILS_PKG"
echo ""
echo "=== MANUAL STEPS REQUIRED ==="
echo "1. Configure fail2ban:"
echo "   Edit /etc/fail2ban/jail.local or /etc/fail2ban/jail.d/*.conf"
echo ""
echo "2. Start services manually when ready:"
echo "   systemctl enable fail2ban"
echo "   systemctl start fail2ban"
echo ""
echo "3. Review and customize nftban configuration:"
echo "   Check /etc/nftban/config/ directory"
echo ""
echo "Logs are available in: $LOG_FILE"
echo "================================="
