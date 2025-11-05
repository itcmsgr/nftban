#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - Auto-Heal Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name=autoheal.sh
# meta:type=helper
# meta:header=Auto-Heal System Configuration
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# meta:description=Automatically fixes common configuration issues
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Colors for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() {
    echo -e "${GREEN}[AUTOHEAL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[AUTOHEAL]${NC} $*"
}

log_error() {
    echo -e "${RED}[AUTOHEAL]${NC} $*"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

log_info "Starting NFTBan Auto-Heal..."

# =============================================================================
# 1. Verify and create all FHS directories
# =============================================================================
log_info "Checking FHS directory structure..."

DIRS=(
    "/etc/nftban/conf.d"
    "/etc/nftban/secrets.d"
    "/etc/nftban/keys"
    "/var/lib/nftban/state"
    "/var/lib/nftban/snapshots"
    "/var/lib/nftban/feeds"
    "/var/lib/nftban/keyring"
    "/var/lib/nftban/backup"
    "/var/lib/nftban/reports"
    "/var/lib/nftban/reports/baseline"
    "/var/lib/nftban/reports/auditors"
    "/var/lib/nftban/metrics"
    "/var/lib/nftban/config"
    "/var/cache/nftban/geoip"
    "/var/cache/nftban/tmp"
    "/var/log/nftban"
)

for DIR in "${DIRS[@]}"; do
    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR"
        log_info "Created missing directory: $DIR"
    fi
done

# =============================================================================
# 2. Fix permissions
# =============================================================================
log_info "Fixing permissions..."

chown -R root:nftban /etc/nftban
chmod 755 /etc/nftban
chmod 755 /etc/nftban/conf.d
chmod 700 /etc/nftban/secrets.d
chmod 700 /etc/nftban/keys

chown -R nftban:nftban /var/lib/nftban
chmod 755 /var/lib/nftban
chmod 750 /var/lib/nftban/state
chmod 750 /var/lib/nftban/feeds
chmod 750 /var/lib/nftban/reports
chmod 750 /var/lib/nftban/reports/baseline

# Dedicated directory for nftban-auditors group (separate from main reports)
if getent group nftban-auditors >/dev/null 2>&1; then
    chown root:nftban-auditors /var/lib/nftban/reports/auditors
    chmod 0770 /var/lib/nftban/reports/auditors
else
    # Fallback if group doesn't exist
    chown nftban:nftban /var/lib/nftban/reports/auditors
    chmod 750 /var/lib/nftban/reports/auditors
fi

chown -R nftban:nftban /var/cache/nftban
chmod 755 /var/cache/nftban

chown -R nftban:nftban /var/log/nftban
chmod 750 /var/log/nftban

# =============================================================================
# 3. Generate system.conf if missing
# =============================================================================
log_info "Checking system.conf..."

SYSTEM_CONF="/var/lib/nftban/config/system.conf"
if [ ! -f "$SYSTEM_CONF" ]; then
    log_info "Generating system.conf..."

    NFTBAN_UID=$(id -u nftban)
    NFTBAN_GID=$(getent group nftban | cut -d: -f3)
    NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)
    NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

    cat > "$SYSTEM_CONF" <<EOF
# NFTBan System Configuration
# Auto-generated during installation
NFTBAN_UID=$NFTBAN_UID
NFTBAN_GID=$NFTBAN_GID
NFTBAN_CLI_GID=$NFTBAN_CLI_GID
NFTBAN_AUDITORS_GID=$NFTBAN_AUDITORS_GID
EOF

    chmod 644 "$SYSTEM_CONF"
    chown root:nftban "$SYSTEM_CONF"
    log_info "Created $SYSTEM_CONF"
fi

# =============================================================================
# 4. Enable and start systemd timer
# =============================================================================
log_info "Configuring systemd timer..."

if systemctl list-unit-files | grep -q "nftban.timer"; then
    systemctl daemon-reload
    systemctl enable nftban.timer
    systemctl start nftban.timer
    log_info "Enabled and started nftban.timer"
else
    log_warn "nftban.timer not found - may need to complete installation first"
fi

# =============================================================================
# 5. Create default configuration if missing
# =============================================================================
log_info "Checking configuration files..."

if [ ! -f "/etc/nftban/nftban.conf" ]; then
    log_warn "Main configuration missing - please run: nftban config init"
fi

# =============================================================================
# 6. Test nftables access
# =============================================================================
log_info "Testing nftables access..."

if command -v nft &>/dev/null; then
    if nft list tables &>/dev/null; then
        log_info "nftables access: OK"
    else
        log_warn "nftables access: FAILED - check permissions"
    fi
else
    log_warn "nftables (nft command) not found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_info "================================================================="
log_info "Auto-Heal Complete!"
log_info "================================================================="
echo ""
log_info "✅ FHS directory structure verified"
log_info "✅ Permissions fixed"
log_info "✅ System configuration generated"
log_info "✅ Systemd timer configured"
echo ""
log_info "Next steps:"
echo "  1. systemctl status nftban.timer  # Check timer status"
echo "  2. nftban config show              # View configuration"
echo "  3. nftban health check             # Run health check"
echo ""

exit 0
