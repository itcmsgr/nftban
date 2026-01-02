#!/usr/bin/env bash
# =============================================================================
# NFTBan Web API - Installation Script
# =============================================================================
# Description:  Install nftban-api (Web API v2.0) on any system
# Usage:        sudo ./install-webapi.sh
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

# Detect OS
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
else
    log_error "Cannot detect OS (no /etc/os-release)"
    exit 1
fi

log_info "Detected: $OS_ID $OS_VERSION"

# Determine source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [[ ! -d "$SRC_DIR/cmd/nftban-api" ]]; then
    log_error "Source not found at: $SRC_DIR/cmd/nftban-api"
    exit 1
fi

log_info "Source directory: $SRC_DIR"

# Step 1: Check dependencies
log_info "Step 1/7: Checking dependencies..."

missing_deps=()

# Check Go
if ! command -v go &>/dev/null; then
    missing_deps+=("golang")
fi

# Check openssl
if ! command -v openssl &>/dev/null; then
    missing_deps+=("openssl")
fi

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log_warn "Missing dependencies: ${missing_deps[*]}"
    log_info "Installing dependencies..."

    case "$OS_ID" in
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y golang openssl
            ;;
        debian|ubuntu)
            apt-get update
            apt-get install -y golang openssl
            ;;
        *)
            log_error "Unsupported OS: $OS_ID"
            log_error "Please install manually: ${missing_deps[*]}"
            exit 1
            ;;
    esac

    log_success "Dependencies installed"
else
    log_success "All dependencies present"
fi

# Step 2: Create system user
log_info "Step 2/7: Creating system user..."

if ! getent group nftban-web >/dev/null; then
    groupadd -r nftban-web
    log_success "Group nftban-web created"
else
    log_info "Group nftban-web exists"
fi

if ! getent passwd nftban-www >/dev/null; then
    useradd -r -g nftban-web -d /var/lib/nftban-www -s /sbin/nologin \
        -c "NFTBan Web API" nftban-www
    log_success "User nftban-www created"
else
    log_info "User nftban-www exists"
fi

# Step 3: Build binary
log_info "Step 3/7: Building nftban-api binary..."

cd "$SRC_DIR"
go mod tidy &>/dev/null || true
CGO_ENABLED=1 go build -o /usr/sbin/nftban-api ./cmd/nftban-api

if [[ -x /usr/sbin/nftban-api ]]; then
    SIZE=$(du -h /usr/sbin/nftban-api | awk '{print $1}')
    log_success "Binary built: /usr/sbin/nftban-api ($SIZE)"
else
    log_error "Build failed"
    exit 1
fi

# Step 4: Install web files
log_info "Step 4/7: Installing web files..."

mkdir -p /var/www/nftban
cp -r "$SRC_DIR/web/"* /var/www/nftban/
chown -R nftban-www:nftban-web /var/www/nftban
chmod -R 755 /var/www/nftban

log_success "Web files installed to /var/www/nftban/"

# Step 5: Install systemd service
log_info "Step 5/7: Installing systemd service..."

if [[ -f "$SRC_DIR/install/systemd/nftban-api.service" ]]; then
    cp "$SRC_DIR/install/systemd/nftban-api.service" /usr/lib/systemd/system/
    systemctl daemon-reload
    log_success "Systemd service installed"
else
    log_warn "Systemd service file not found, creating..."

    cat > /usr/lib/systemd/system/nftban-api.service << 'EOF'
[Unit]
Description=NFTBan Web API v2.0
Documentation=https://github.com/nftban/nftban
After=network.target nftables.service

[Service]
Type=simple
User=nftban-www
Group=nftban-web
ExecStart=/usr/sbin/nftban-api --listen=:3940
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nftban-www

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Systemd service created"
fi

# Step 6: Install PAM config
log_info "Step 6/7: Installing PAM configuration..."

if [[ -f "$SRC_DIR/install/pam.d/nftban-api" ]]; then
    cp "$SRC_DIR/install/pam.d/nftban-api" /etc/pam.d/
    log_success "PAM config installed"
else
    log_warn "PAM config not found, creating..."

    cat > /etc/pam.d/nftban-api << 'EOF'
#%PAM-1.0
auth       required     pam_unix.so
account    required     pam_unix.so
EOF

    log_success "PAM config created"
fi

# Step 7: Setup TLS
log_info "Step 7/7: Setting up TLS certificates..."

mkdir -p /etc/nftban/tls
chown nftban-www:nftban-web /etc/nftban/tls
chmod 750 /etc/nftban/tls

if [[ ! -f /etc/nftban/tls/cert.pem ]]; then
    log_info "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout /etc/nftban/tls/key.pem \
        -out /etc/nftban/tls/cert.pem \
        -days 365 -subj "/CN=$(hostname)" &>/dev/null

    chown nftban-www:nftban-web /etc/nftban/tls/*.pem
    chmod 600 /etc/nftban/tls/key.pem
    chmod 644 /etc/nftban/tls/cert.pem

    log_success "Self-signed certificate generated"
else
    log_info "TLS certificate exists"
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ NFTBan Web API Installed Successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Binary:        /usr/sbin/nftban-api"
echo "Web root:      /var/www/nftban/"
echo "Service:       nftban-api.service"
echo "User:          nftban-www"
echo "Group:         nftban-web"
echo ""
echo "To start:"
echo "  systemctl enable nftban-api"
echo "  systemctl start nftban-api"
echo ""
echo "Or use CLI:"
echo "  nftban gui enable"
echo ""
echo "Access:"
echo "  https://$(hostname -I | awk '{print $1}'):3940/"
echo ""
echo "Note: Open firewall port 3940 if needed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
