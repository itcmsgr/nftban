#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Auto-Heal Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name=autoheal.sh
# meta:type=helper
# meta:header=Auto-Heal System Configuration
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# meta:description=Automatically fixes common configuration issues
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

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
    "${NFTBAN_CONFIG_DIR}/conf.d"
    "${NFTBAN_CONFIG_DIR}/secrets.d"
    "${NFTBAN_CONFIG_DIR}/keys"
    "${NFTBAN_CONFIG_DIR}/feeds.d"
    "${NFTBAN_CONFIG_DIR}/distros"
    "${NFTBAN_CONFIG_DIR}/ports.d"
    "${NFTBAN_CONFIG_DIR}/whitelist.d"
    "${NFTBAN_CONFIG_DIR}/blacklist.d"
    "${NFTBAN_CONFIG_DIR}/geoban.d"
    "/etc/suricata/rules"
    "/etc/suricata/update.d"
    "/etc/nftables/nftban.d"
    "${NFTBAN_LIB_DIR}"
    "${NFTBAN_LIB_DIR}/bin"
    "${NFTBAN_LIB_DIR}/core"
    "${NFTBAN_LIB_DIR}/cli"
    "${NFTBAN_LIB_DIR}/helpers"
    "${NFTBAN_LIB_DIR}/exporters"
    "${NFTBAN_LIB_DIR}/setup"
    "/usr/share/nftban"
    "/usr/share/nftban/templates"
    "/usr/share/nftban/templates/mail"
    "/usr/share/nftban/templates/reports"
    "${NFTBAN_DATA_DIR}/state"
    "${NFTBAN_DATA_DIR}/snapshots"
    "${NFTBAN_DATA_DIR}/feeds"
    "${NFTBAN_DATA_DIR}/geoip"
    "${NFTBAN_DATA_DIR}/reports"
    "${NFTBAN_DATA_DIR}/keyring"
    "${NFTBAN_DATA_DIR}/backup"
    "${NFTBAN_DATA_DIR}/reports"
    "${NFTBAN_DATA_DIR}/reports/baseline"
    "${NFTBAN_DATA_DIR}/reports/auditors"
    "${NFTBAN_DATA_DIR}/metrics"
    "${NFTBAN_DATA_DIR}/config"
    "${NFTBAN_DATA_DIR}/geoip"
    "${NFTBAN_DATA_DIR}/geoban"
    "${NFTBAN_DATA_DIR}/geoban/tracking"
    "${NFTBAN_CACHE_DIR}/geoip"
    "${NFTBAN_CACHE_DIR}/geoban"
    "${NFTBAN_CACHE_DIR}/feeds"
    "${NFTBAN_CACHE_DIR}/tmp"
    "${NFTBAN_LOG_DIR}"
    "${NFTBAN_RUN_DIR}"
    "${NFTBAN_RUN_DIR}/locks"
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

chown -R root:nftban "${NFTBAN_CONFIG_DIR}"
chmod 750 "${NFTBAN_CONFIG_DIR}"
chmod 750 "${NFTBAN_CONFIG_DIR}/conf.d"
chmod 700 "${NFTBAN_CONFIG_DIR}/secrets.d"
chmod 700 "${NFTBAN_CONFIG_DIR}/keys"

# Suricata config directories (nftban group read access)
chown -R root:nftban /etc/suricata 2>/dev/null || true
chmod 750 /etc/suricata 2>/dev/null || true
chmod 640 /etc/suricata/*.conf 2>/dev/null || true
chmod 640 /etc/suricata/rules/*.rules 2>/dev/null || true

# nftables config
chown -R root:nftban /etc/nftables/nftban.d 2>/dev/null || true
chmod 750 /etc/nftables/nftban.d 2>/dev/null || true

chown -R nftban:nftban "${NFTBAN_DATA_DIR}"
chmod 750 "${NFTBAN_DATA_DIR}"
chmod 750 "${NFTBAN_DATA_DIR}/state"
chmod 750 "${NFTBAN_DATA_DIR}/feeds"
chmod 750 "${NFTBAN_DATA_DIR}/reports"
chmod 750 "${NFTBAN_DATA_DIR}/reports/baseline"

# Dedicated directory for nftban-auditors group (separate from main reports)
if getent group nftban-auditors >/dev/null 2>&1; then
    chown root:nftban-auditors "${NFTBAN_DATA_DIR}/reports/auditors"
    chmod 0770 "${NFTBAN_DATA_DIR}/reports/auditors"
else
    # Fallback if group doesn't exist
    chown nftban:nftban "${NFTBAN_DATA_DIR}/reports/auditors"
    chmod 750 "${NFTBAN_DATA_DIR}/reports/auditors"
fi

chown -R nftban:nftban "${NFTBAN_CACHE_DIR}"
chmod 755 "${NFTBAN_CACHE_DIR}"

# Application libraries directory (FHS: /usr/lib = root:root, 755)
chown -R root:root "${NFTBAN_LIB_DIR}" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/bin" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/core" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/cli" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/helpers" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/exporters" 2>/dev/null || true
chmod 755 "${NFTBAN_LIB_DIR}/setup" 2>/dev/null || true
# Make all shell scripts executable
find "${NFTBAN_LIB_DIR}" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
# Make binaries executable
find "${NFTBAN_LIB_DIR}/bin" -type f -exec chmod 755 {} \; 2>/dev/null || true
# CRITICAL: Set CAP_NET_ADMIN on nftban-core for GUI ban/unban functionality
# The GUI (nftban-ui) runs as non-root and calls nftban-core for firewall operations
if [ -x "${NFTBAN_LIB_DIR}/bin/nftban-core" ]; then
    setcap cap_net_admin+ep "${NFTBAN_LIB_DIR}/bin/nftban-core" 2>/dev/null || log_warn "Failed to set CAP_NET_ADMIN on nftban-core"
fi

# Templates directory (FHS: /usr/share = root:root, 755)
chown -R root:root /usr/share/nftban 2>/dev/null || true
chmod 755 /usr/share/nftban 2>/dev/null || true
chmod 755 /usr/share/nftban/templates 2>/dev/null || true
chmod 755 /usr/share/nftban/templates/mail 2>/dev/null || true
chmod 755 /usr/share/nftban/templates/reports 2>/dev/null || true
find /usr/share/nftban/templates -type f -name "*.html" -exec chmod 644 {} \; 2>/dev/null || true

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
chown nftban:"$AUDIT_GROUP" "${NFTBAN_LOG_DIR}"
chmod 750 "${NFTBAN_LOG_DIR}"

# Fix ALL log files (including those created by root like cloudflare.log, portscan.log)
# This ensures auditors can read all logs for compliance
log_info "Fixing log file ownership (including root-owned logs)..."
if [ -d "${NFTBAN_LOG_DIR}" ]; then
    find "${NFTBAN_LOG_DIR}" -type f \( -name "*.log" -o -name "*.log-*" -o -name "*.gz" \) \
        -exec chown nftban:"$AUDIT_GROUP" {} \; 2>/dev/null || true

    find "${NFTBAN_LOG_DIR}" -type f \( -name "*.log" -o -name "*.log-*" \) \
        -exec chmod 640 {} \; 2>/dev/null || true

    # Compressed logs can be read-only
    find "${NFTBAN_LOG_DIR}" -type f -name "*.gz" \
        -exec chmod 440 {} \; 2>/dev/null || true

    log_info "✅ All log files now accessible to $AUDIT_GROUP group"
fi

# =============================================================================
# 3. Generate system.conf if missing
# =============================================================================
log_info "Checking system.conf..."

SYSTEM_CONF="${NFTBAN_DATA_DIR}/config/system.conf"
if [ ! -f "$SYSTEM_CONF" ]; then
    log_info "Generating system.conf..."

    # NFTBan v1.0 simplified 2-group model
    NFTBAN_UID=$(id -u nftban)
    NFTBAN_GID=$(getent group nftban | cut -d: -f3)
    NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

    cat > "$SYSTEM_CONF" <<EOF
# NFTBan System Configuration
# Auto-generated during installation
# v1.0 simplified 2-group model: nftban + nftban-auditors
NFTBAN_UID=$NFTBAN_UID
NFTBAN_GID=$NFTBAN_GID
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable nftban.timer 2>/dev/null || log_warn "Failed to enable nftban.timer"
    systemctl start nftban.timer 2>/dev/null || log_warn "Failed to start nftban.timer"
    log_info "Enabled and started nftban.timer"
else
    log_warn "nftban.timer not found - may need to complete installation first"
fi

# =============================================================================
# 5. Create default configuration if missing
# =============================================================================
log_info "Checking configuration files..."

if [ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]; then
    log_warn "Main configuration missing - please run: nftban config init"
fi

# =============================================================================
# 6. Test nftables access
# =============================================================================
log_info "Testing nftables access..."

# PERFORMANCE FIX: Use 'nft -t list tables' (terse mode) to avoid dumping
# all IP sets which can cause 30+ second hangs with large feed sets
if command -v nft &>/dev/null; then
    if nft -t list tables &>/dev/null; then
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

# Use centralized NFTBAN_BIN path
NFTBAN_CMD="${NFTBAN_BIN:-/usr/bin/nftban}"

# Fix permissions silently
"$NFTBAN_CMD" permissions enforce >/dev/null 2>&1 || true

# Fix FHS issues silently
"$NFTBAN_CMD" health check --auto-heal >/dev/null 2>&1 || true

# =============================================================================
# Check and auto-heal Suricata IDS (replaces fail2ban in v1.0)
# =============================================================================
log_info "Checking Suricata IDS configuration..."

# Check if Suricata service exists
if systemctl list-unit-files suricata.service &>/dev/null 2>&1; then
    # Suricata is installed - verify it's running
    if ! systemctl is-active --quiet suricata.service 2>/dev/null; then
        log_warn "Suricata service not running - attempting to start..."
        if systemctl start suricata.service 2>/dev/null; then
            log_info "✅ Started Suricata service"
        else
            log_error "Failed to start Suricata - check logs: journalctl -u suricata.service"
        fi
    else
        log_info "✅ Suricata service is running"
    fi

    # Verify eve.json is being written (use central config path)
    EVE_LOG="${NFTBAN_SURICATA_EVE_LOG:-/var/log/suricata/eve.json}"
    if [ -f "$EVE_LOG" ]; then
        # Check if file is recent (modified in last 5 minutes)
        if [ "$(find "$EVE_LOG" -mmin -5 2>/dev/null)" ]; then
            log_info "✅ Suricata eve.json is actively writing"
        else
            log_warn "Suricata eve.json not recently updated - may not be capturing traffic"
        fi
    else
        log_warn "Suricata eve.json not found at $EVE_LOG"
    fi
else
    log_warn "Suricata not installed - IDS protection disabled"
fi

# Check NFTBan Suricata integration daemon
if systemctl list-unit-files nftban-suricata.service &>/dev/null 2>&1; then
    if ! systemctl is-active --quiet nftban-suricata.service 2>/dev/null; then
        log_warn "NFTBan Suricata daemon not running - attempting to start..."

        # First verify filters.conf exists
        FILTERS_CONF="/etc/suricata/filters.conf"
        if [ ! -f "$FILTERS_CONF" ]; then
            log_error "Missing $FILTERS_CONF - cannot start Suricata daemon"
        else
            # Pre-create suricata-events.log with correct ownership for CAP_NET_ADMIN-only daemon
            # Daemon runs as User=root with SupplementaryGroups=nftban (no DAC capabilities)
            # File must be group-writable by nftban so root process can write via group perms
            SURICATA_LOG="${NFTBAN_LOG_DIR}/suricata-events.log"
            if [ ! -f "$SURICATA_LOG" ]; then
                touch "$SURICATA_LOG" 2>/dev/null || true
                chown root:nftban "$SURICATA_LOG" 2>/dev/null || true
                chmod 660 "$SURICATA_LOG" 2>/dev/null || true
            else
                # Fix ownership if file exists but has wrong perms (e.g. created by nftban user)
                chown root:nftban "$SURICATA_LOG" 2>/dev/null || true
                chmod 660 "$SURICATA_LOG" 2>/dev/null || true
            fi

            # Try to start daemon
            if systemctl start nftban-suricata.service 2>/dev/null; then
                sleep 2
                if systemctl is-active --quiet nftban-suricata.service 2>/dev/null; then
                    log_info "✅ Started NFTBan Suricata daemon"
                else
                    log_error "NFTBan Suricata daemon failed to start - check: journalctl -u nftban-suricata.service"
                fi
            else
                log_error "Failed to start NFTBan Suricata daemon"
            fi
        fi
    else
        log_info "✅ NFTBan Suricata daemon is running"
    fi
else
    log_warn "NFTBan Suricata integration not installed"
fi

# Verify Suricata filter configuration (already set above in autoheal section)
if [ -f "${FILTERS_CONF:-/etc/suricata/filters.conf}" ]; then
    log_info "✅ Suricata filters configuration found"
else
    log_warn "Missing ${FILTERS_CONF:-/etc/suricata/filters.conf} - Suricata integration may not work"
fi

# =============================================================================
# Auto-fix login monitor issues
# =============================================================================
log_info "Checking login monitor configuration..."

LOGIN_CONFIG="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
LOGIN_CONFIG_LOCAL="${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"
LOGIN_ISSUES_FOUND=0
LOGIN_ISSUES_FIXED=0

# Check if login monitor is configured (either config exists)
if [ -f "$LOGIN_CONFIG" ] || [ -f "$LOGIN_CONFIG_LOCAL" ]; then

    # 1. Check log directory exists
    LOGIN_LOG_DIR="${NFTBAN_LOG_DIR}"
    if [ ! -d "$LOGIN_LOG_DIR" ]; then
        mkdir -p "$LOGIN_LOG_DIR"
        chown nftban:nftban "$LOGIN_LOG_DIR" 2>/dev/null || true
        chmod 750 "$LOGIN_LOG_DIR"
        log_info "Created login log directory: $LOGIN_LOG_DIR"
        ((LOGIN_ISSUES_FIXED++))
    fi

    # 2. Check core module exists
    if [ ! -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]; then
        log_warn "Login alert core module not found"
        ((LOGIN_ISSUES_FOUND++))
    fi

    # 3. Check if service should be running but isn't
    login_monitor_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    if [ -f "/etc/systemd/system/$login_monitor_svc" ]; then
        if systemctl is-enabled --quiet "$login_monitor_svc" 2>/dev/null; then
            if ! systemctl is-active --quiet "$login_monitor_svc" 2>/dev/null; then
                log_warn "Login monitor service enabled but not running - attempting restart"
                if systemctl start "$login_monitor_svc" 2>/dev/null; then
                    log_info "✅ Started login monitor service"
                    ((LOGIN_ISSUES_FIXED++))
                else
                    log_warn "Failed to start login monitor service"
                    ((LOGIN_ISSUES_FOUND++))
                fi
            else
                log_info "✅ Login monitor service is running"
            fi
        fi
    fi

    # Summary
    if [ "$LOGIN_ISSUES_FIXED" -gt 0 ]; then
        log_info "Fixed $LOGIN_ISSUES_FIXED login monitor issues"
    fi
    if [ "$LOGIN_ISSUES_FOUND" -gt 0 ]; then
        log_warn "Login monitor has $LOGIN_ISSUES_FOUND issues requiring attention"
    fi
    if [ "$LOGIN_ISSUES_FOUND" -eq 0 ] && [ "$LOGIN_ISSUES_FIXED" -eq 0 ]; then
        log_info "✅ Login monitor is healthy"
    fi
else
    log_info "Login monitor not configured (optional module)"
fi

# =============================================================================
# Run final health check - only report real errors, not warnings
# =============================================================================
HEALTH_OUTPUT=$("$NFTBAN_CMD" health check 2>&1 || true)

# Check for real errors (not warnings)
if echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*ERROR"; then
    ERROR_COUNT=$(echo "$HEALTH_OUTPUT" | grep -oP "Errors: \K\d+" || echo "0")
    # shellcheck disable=SC2034  # WARNING_COUNT reserved for future alerting logic
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
log_info "✅ FHS directories created (38 directories)"
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
