#!/usr/bin/env bash
# =============================================================================
# NFTBan Web API - Uninstallation Script
# =============================================================================
# Description:  Remove nftban-api (Web API v2.0)
# Usage:        sudo ./uninstall-webapi.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NFTBan Web API - Uninstallation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Confirm
read -r -p "Remove NFTBan Web API? [y/N]: " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "Uninstall cancelled"
    exit 0
fi

# Step 1: Stop and disable service
log_info "Step 1/6: Stopping service..."

if systemctl is-active nftban-api &>/dev/null; then
    systemctl stop nftban-api
    log_success "Service stopped"
fi

if systemctl is-enabled nftban-api &>/dev/null; then
    systemctl disable nftban-api
    log_success "Service disabled"
fi

# Step 2: Remove binary
log_info "Step 2/6: Removing binary..."

if [[ -f /usr/sbin/nftban-api ]]; then
    rm -f /usr/sbin/nftban-api
    log_success "Binary removed"
fi

# Step 3: Remove web files
log_info "Step 3/6: Removing web files..."

read -r -p "Remove web files (/var/www/nftban/)? [y/N]: " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    if [[ -d /var/www/nftban ]]; then
        rm -rf /var/www/nftban
        log_success "Web files removed"
    fi
else
    log_info "Keeping web files"
fi

# Step 4: Remove systemd service
log_info "Step 4/6: Removing systemd service..."

if [[ -f /usr/lib/systemd/system/nftban-api.service ]]; then
    rm -f /usr/lib/systemd/system/nftban-api.service
    systemctl daemon-reload
    log_success "Systemd service removed"
fi

# Step 5: Remove PAM config
log_info "Step 5/6: Removing PAM configuration..."

if [[ -f /etc/pam.d/nftban-api ]]; then
    rm -f /etc/pam.d/nftban-api
    log_success "PAM config removed"
fi

# Step 6: TLS certificates
log_info "Step 6/6: TLS certificates..."

read -r -p "Remove TLS certificates (/etc/nftban/tls/)? [y/N]: " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    if [[ -d /etc/nftban/tls ]]; then
        rm -rf /etc/nftban/tls
        log_success "TLS certificates removed"
    fi
else
    log_info "Keeping TLS certificates"
fi

# Optional: Remove user and group
echo ""
read -r -p "Remove system user and group (nftban-www)? [y/N]: " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    if getent passwd nftban-www >/dev/null; then
        userdel nftban-www 2>/dev/null || true
        log_success "User removed"
    fi
    if getent group nftban-web >/dev/null; then
        groupdel nftban-web 2>/dev/null || true
        log_success "Group removed"
    fi
else
    log_info "Keeping user and group"
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ NFTBan Web API Uninstalled${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
