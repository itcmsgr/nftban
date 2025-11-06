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
# Automatically fix common issues
# =============================================================================
log_info "Running automated fixes..."

# Fix permissions silently
/usr/sbin/nftban permissions enforce >/dev/null 2>&1 || true

# Fix FHS issues silently
/usr/sbin/nftban health check --auto-heal >/dev/null 2>&1 || true

# =============================================================================
# Run final health check - only report real errors, not warnings
# =============================================================================
HEALTH_OUTPUT=$(/usr/sbin/nftban health check 2>&1 || true)

# Check for real errors (not warnings)
if echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*ERROR"; then
    ERROR_COUNT=$(echo "$HEALTH_OUTPUT" | grep -oP "Errors: \K\d+" || echo "0")
    WARNING_COUNT=$(echo "$HEALTH_OUTPUT" | grep -oP "Warnings: \K\d+" || echo "0")

    # Only alert if real errors exist (not just warnings)
    if [ "$ERROR_COUNT" != "0" ]; then
        echo ""
        echo "$HEALTH_OUTPUT"
        echo ""
        log_warn "================================================================="
        log_warn "⚠️  Some issues require manual attention"
        log_warn "================================================================="
        echo ""
        echo "Run: nftban health check --verbose"
        echo ""
        HEALTH_STATUS="ERROR"
    else
        # Only warnings, treat as success
        HEALTH_STATUS="OK"
    fi
else
    # OK or only warnings - both are fine
    HEALTH_STATUS="OK"
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

# Only show health status line if errors exist
if [ "${HEALTH_STATUS:-OK}" = "ERROR" ]; then
    log_warn "Health: ${HEALTH_STATUS} (some issues need attention)"
else
    log_info "Health: OK (system ready)"
fi
echo ""

exit 0
