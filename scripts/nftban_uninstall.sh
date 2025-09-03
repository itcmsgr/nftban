##!/bin/bash

################################################################################
# Script: nftban_uninstall.sh
#
# Version: 1.2.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates the unistall of nftban script
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
################################################################################

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

echo "--- Starting nftban uninstall ---"

BASE_DIR="/etc/nftban"
LOG_DIR="/var/log/nftban"
PKG_MGR=""
PKG_REMOVE=""
PKG_INSTALL=""

# --- Detect Package Manager ---
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    PKG_REMOVE="dnf remove -y"
    PKG_INSTALL="dnf install -y"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    PKG_REMOVE="yum remove -y"
    PKG_INSTALL="yum install -y"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
    PKG_REMOVE="apt remove -y"
    PKG_INSTALL="apt install -y"
else
    echo "Supported package manager not found (dnf/yum/apt)." >&2
    exit 1
fi

# --- Ask user for full removal ---
read -p "Do you want to completely remove nftables and fail2ban packages? [y/N]: " FULL_REMOVE

# --- Stop and disable Fail2Ban ---
echo "Stopping Fail2Ban service..."
systemctl stop fail2ban &>/dev/null
systemctl disable fail2ban &>/dev/null

# --- Remove nftban directory ---
if [[ -d "$BASE_DIR" ]]; then
    echo "Removing $BASE_DIR..."
    rm -rf "$BASE_DIR"
else
    echo "$BASE_DIR not found. Skipping."
fi

# --- Remove log directory ---
if [[ -d "$LOG_DIR" ]]; then
    echo "Removing $LOG_DIR..."
    rm -rf "$LOG_DIR"
fi

# --- Remove packages if requested ---
if [[ "$FULL_REMOVE" =~ ^[Yy]$ ]]; then
    echo "Removing fail2ban and nftables packages..."
    $PKG_REMOVE fail2ban nftables
else
    echo "Packages will remain installed. Only services stopped and configs removed."
fi

echo "--- nftban uninstall complete ---"
