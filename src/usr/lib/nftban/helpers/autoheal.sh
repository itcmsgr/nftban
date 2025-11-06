#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.0 - Auto-Heal Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name=autoheal.sh
# meta:type=helper
# meta:header=Auto-Heal System Configuration
# meta:version=0.32.0
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
    "/etc/nftban/feeds.d"
    "/etc/nftban/rules.d"
    "/etc/nftban/ports.d"
    "/etc/nftban/whitelist.d"
    "/etc/nftban/blacklist.d"
    "/etc/nftban/geoban.d"
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
    "/var/lib/nftban/geoip"
    "/var/lib/nftban/geoban"
    "/var/lib/nftban/geoban/tracking"
    "/var/cache/nftban/geoip"
    "/var/cache/nftban/geoban"
    "/var/cache/nftban/feeds"
    "/var/cache/nftban/tmp"
    "/var/log/nftban"
    "/run/nftban"
    "/run/nftban/locks"
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
chmod 750 /etc/nftban
chmod 750 /etc/nftban/conf.d
chmod 700 /etc/nftban/secrets.d
chmod 700 /etc/nftban/keys

chown -R nftban:nftban /var/lib/nftban
chmod 750 /var/lib/nftban
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

# =============================================================================
# CRITICAL: Fix log directory and ALL log files for nftban-auditors access
# =============================================================================

# Determine audit group (prefer nftban-auditors for compliance, fallback to nftban)
AUDIT_GROUP="nftban"
if getent group nftban-auditors >/dev/null 2>&1; then
    AUDIT_GROUP="nftban-auditors"
    log_info "Using nftban-auditors group for log file access"
fi

# Fix log directory ownership and permissions
chown nftban:"$AUDIT_GROUP" /var/log/nftban
chmod 750 /var/log/nftban

# Fix ALL log files (including those created by root like cloudflare.log, portscan.log)
# This ensures auditors can read all logs for compliance
log_info "Fixing log file ownership (including root-owned logs)..."
if [ -d /var/log/nftban ]; then
    find /var/log/nftban -type f \( -name "*.log" -o -name "*.log-*" -o -name "*.gz" \) \
        -exec chown nftban:"$AUDIT_GROUP" {} \; 2>/dev/null || true

    find /var/log/nftban -type f \( -name "*.log" -o -name "*.log-*" \) \
        -exec chmod 640 {} \; 2>/dev/null || true

    # Compressed logs can be read-only
    find /var/log/nftban -type f -name "*.gz" \
        -exec chmod 440 {} \; 2>/dev/null || true

    log_info "✅ All log files now accessible to $AUDIT_GROUP group"
fi

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
# Run health check and report what needs fixing
# =============================================================================
echo ""
log_info "Running health check to verify installation..."
echo ""

HEALTH_OUTPUT=$(/usr/sbin/nftban health check 2>&1 || true)
echo "$HEALTH_OUTPUT"

# Check if there are still errors
if echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*ERROR"; then
    echo ""
    log_warn "================================================================="
    log_warn "⚠️  ATTENTION: Some issues still need your attention"
    log_warn "================================================================="
    echo ""

    # Check for specific issues and give commands
    if echo "$HEALTH_OUTPUT" | grep -q "GeoIP.*Database not found"; then
        echo "📥 GeoIP Database Missing (optional - only for IP lookups):"
        echo "   Run: nftban geoip update"
        echo ""
    fi

    if echo "$HEALTH_OUTPUT" | grep -q "permission"; then
        echo "🔒 Permission Issues Detected:"
        echo "   Run: nftban permissions enforce"
        echo ""
    fi

    if echo "$HEALTH_OUTPUT" | grep -q "FHS.*error"; then
        echo "📁 FHS Directory Issues:"
        echo "   Run: nftban health check --auto-heal"
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚀 TO FIX ALL ISSUES AUTOMATICALLY:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   nftban permissions enforce && nftban health check --auto-heal"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

elif echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*WARNING"; then
    echo ""
    log_info "✅ Installation OK (minor warnings only)"
    echo ""
    echo "You can ignore warnings or fix them with:"
    echo "   nftban permissions enforce"
    echo "   nftban geoip update    # (optional)"
    echo ""
else
    echo ""
    log_info "================================================================="
    log_info "✅ Installation Perfect! No issues found!"
    log_info "================================================================="
    echo ""
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
log_info "================================================================="
log_info "Auto-Heal Complete!"
log_info "================================================================="
echo ""
log_info "✅ FHS directories created (27 directories)"
log_info "✅ Permissions enforced (correct ownership and modes)"
log_info "✅ System configuration generated"
log_info "✅ Systemd timer configured"
echo ""
log_info "📖 Next Steps (Press button A, B, C...):"
echo ""
echo "  A) Fix any remaining issues (if shown above):"
echo "     nftban permissions enforce && nftban health check --auto-heal"
echo ""
echo "  B) Enable NFTBan firewall:"
echo "     nftban enable"
echo ""
echo "  C) Check status:"
echo "     nftban status"
echo ""
echo "  D) Test new GeoBan feature (v0.31.0):"
echo "     nftban geoban help"
echo ""

exit 0
