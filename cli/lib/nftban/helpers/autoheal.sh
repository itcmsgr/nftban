#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="autoheal"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Automatically fixes common configuration issues using FHS spec"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# CRITICAL: Load FHS spec - single source of truth for directory structure
# shellcheck source=/usr/lib/nftban/core/nftban_fhs_spec.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_fhs_spec.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_fhs_spec.sh"
else
    echo "[AUTOHEAL] ERROR: FHS spec not found - cannot proceed" >&2
    exit 1
fi

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
# 1. Verify and create all FHS directories FROM SPEC (single source of truth)
# =============================================================================
log_info "Checking FHS directory structure from specification..."

# Use the FHS spec (already loaded above) - iterate through ALL defined paths
fixed_dirs=0
for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
    spec="${NFTBAN_FHS_DIRECTORIES[$path]}"

    # Parse spec: mode|owner|group|description
    IFS='|' read -r exp_mode exp_owner exp_group _description <<< "$spec"

    # Create directory if missing
    if [ ! -d "$path" ]; then
        install -d -o "$exp_owner" -g "$exp_group" -m "$exp_mode" "$path" 2>/dev/null || {
            log_warn "Failed to create: $path"
            continue
        }
        log_info "Created missing directory: $path"
        # v1.19.20 FIX
        ((fixed_dirs++)) || true
    fi
done

log_info "FHS directory check complete ($fixed_dirs directories created)"

# =============================================================================
# 2. Fix permissions FROM FHS SPEC (single source of truth)
# =============================================================================
log_info "Fixing permissions from FHS specification..."

fixed_perms=0
for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
    spec="${NFTBAN_FHS_DIRECTORIES[$path]}"

    # Parse spec: mode|owner|group|description
    IFS='|' read -r exp_mode exp_owner exp_group _description <<< "$spec"

    # Skip if directory doesn't exist
    [ ! -d "$path" ] && continue

    # Get actual values
    act_mode=$(stat -c "%a" "$path" 2>/dev/null || echo "000")
    act_owner=$(stat -c "%U" "$path" 2>/dev/null || echo "nobody")
    act_group=$(stat -c "%G" "$path" 2>/dev/null || echo "nogroup")

    # Normalize expected mode (strip leading 0)
    exp_mode_norm="${exp_mode#0}"

    # Fix ownership if wrong
    # v1.19.26: Check if user/group exist before chown to avoid silent failures
    if [ "$act_owner" != "$exp_owner" ] || [ "$act_group" != "$exp_group" ]; then
        # Verify user exists (skip if not - e.g., suricata user on non-Suricata systems)
        if id "$exp_owner" &>/dev/null || [ "$exp_owner" = "root" ]; then
            if getent group "$exp_group" &>/dev/null; then
                chown "$exp_owner:$exp_group" "$path" 2>/dev/null && {
                    log_info "Fixed ownership: $path → $exp_owner:$exp_group"
                    ((fixed_perms++)) || true
                }
            else
                log_warn "Group '$exp_group' does not exist, skipping ownership fix for $path"
            fi
        else
            log_warn "User '$exp_owner' does not exist, skipping ownership fix for $path"
        fi
    fi

    # Fix permissions if wrong
    if [ "$act_mode" != "$exp_mode_norm" ]; then
        # v1.19.26: Remove ACLs first - ACL mask can override chmod and prevent fixes
        if getfacl "$path" 2>/dev/null | grep -q "^mask::"; then
            setfacl -b "$path" 2>/dev/null || true
            log_info "Removed ACL from $path (was blocking chmod)"
        fi
        chmod "$exp_mode" "$path" 2>/dev/null && {
            log_info "Fixed permissions: $path → $exp_mode_norm"
            ((fixed_perms++)) || true
        }
    fi
done

log_info "Permission fixes complete ($fixed_perms items fixed)"

# Additional file-level fixes not in FHS spec (which only covers directories)
# Make all shell scripts executable
find "${NFTBAN_LIB_DIR:-/usr/lib/nftban}" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
# Make binaries executable
find "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin" -type f -exec chmod 755 {} \; 2>/dev/null || true

# =============================================================================
# CRITICAL: Fix /var/lib/nftban file permissions (feeds, banned, whitelist, etc.)
# v1.13.12: Go binaries may create files with root:root - fix them for exporter access
# =============================================================================
log_info "Fixing /var/lib/nftban file permissions..."
if [ -d "${NFTBAN_DATA_DIR:-/var/lib/nftban}" ]; then
    # Fix all files EXCEPT auditors directory (which has different ownership)
    find "${NFTBAN_DATA_DIR:-/var/lib/nftban}" -type f \
        -not -path "*/reports/auditors/*" \
        \( -not -user nftban -o -not -group nftban \) \
        -exec chown nftban:nftban {} \; 2>/dev/null || true

    find "${NFTBAN_DATA_DIR:-/var/lib/nftban}" -type f \
        -not -path "*/reports/auditors/*" \
        -not -perm 640 \
        -exec chmod 640 {} \; 2>/dev/null || true

    log_info "✅ /var/lib/nftban files fixed (nftban:nftban 0640)"
fi
# CRITICAL: Set CAP_NET_ADMIN on nftban-core for GUI ban/unban functionality
if [ -x "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core" ]; then
    setcap cap_net_admin+ep "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core" 2>/dev/null || log_warn "Failed to set CAP_NET_ADMIN on nftban-core"
fi
# Fix HTML templates
find /usr/share/nftban/templates -type f -name "*.html" -exec chmod 644 {} \; 2>/dev/null || true

# =============================================================================
# CRITICAL: Fix log directory and ALL log files for nftban-auditor access
# =============================================================================

# Determine audit group (prefer nftban-auditor for compliance, fallback to nftban)
AUDIT_GROUP="nftban"
if getent group nftban-auditor >/dev/null 2>&1; then
    AUDIT_GROUP="nftban-auditor"
    log_info "Using nftban-auditor group for log file access"
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
    NFTBAN_AUDITORS_GID=$(getent group nftban-auditor | cut -d: -f3)

    cat > "$SYSTEM_CONF" <<EOF
# NFTBan System Configuration
# Auto-generated during installation
# v1.0 simplified 2-group model: nftban + nftban-auditor
NFTBAN_UID=$NFTBAN_UID
NFTBAN_GID=$NFTBAN_GID
NFTBAN_AUDITORS_GID=$NFTBAN_AUDITORS_GID
EOF

    chmod 644 "$SYSTEM_CONF"
    chown root:nftban "$SYSTEM_CONF"
    log_info "Created $SYSTEM_CONF"
fi

# =============================================================================
# 4. Enable and start critical systemd timers
# =============================================================================
log_info "Configuring critical systemd timers..."

# Critical timers that must always be enabled
# These are auto-enabled by the health check mechanism
CRITICAL_TIMERS=(
    "nftban-maintenance.timer"   # CRITICAL: SSH/IP lockout prevention
    "nftban-health.timer"        # Health checks and auto-heal
)

# Conditionally add feeds timer only if feeds are enabled (save resources)
if [[ "${NFTBAN_FEEDS_ENABLED:-false}" == "true" ]]; then
    CRITICAL_TIMERS+=("nftban-core-feeds.timer")
fi

systemctl daemon-reload 2>/dev/null || true

for timer in "${CRITICAL_TIMERS[@]}"; do
    if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "^$timer"; then
        # Timer unit exists - check if enabled
        if ! systemctl is-enabled --quiet "$timer" 2>/dev/null; then
            log_warn "$timer not enabled - auto-enabling..."
            if systemctl enable "$timer" 2>/dev/null; then
                log_info "AUTO-FIXED: Enabled $timer"
            else
                log_error "Failed to enable $timer"
            fi
        fi

        # Check if active (running)
        if ! systemctl is-active --quiet "$timer" 2>/dev/null; then
            log_warn "$timer not active - auto-starting..."
            if systemctl start "$timer" 2>/dev/null; then
                log_info "AUTO-FIXED: Started $timer"
            else
                log_error "Failed to start $timer"
            fi
        else
            log_info "✅ $timer is active"
        fi
    else
        log_warn "$timer not installed - may need to run install.sh"
    fi
done

# =============================================================================
# 5. Check and auto-start nftband daemon (CRITICAL for feeds and bans)
# =============================================================================
log_info "Checking nftband daemon status..."

# Check nftband.socket first (socket activation)
if systemctl list-unit-files nftband.socket &>/dev/null 2>&1; then
    if ! systemctl is-active --quiet nftband.socket 2>/dev/null; then
        log_warn "nftband.socket not active - attempting to start..."
        if systemctl start nftband.socket 2>/dev/null; then
            log_info "AUTO-FIXED: Started nftband.socket"
        else
            log_error "Failed to start nftband.socket - check: journalctl -u nftband.socket"
        fi
    else
        log_info "✅ nftband.socket is active"
    fi
fi

# Check nftband.service (main daemon)
if systemctl list-unit-files nftband.service &>/dev/null 2>&1; then
    if ! systemctl is-active --quiet nftband.service 2>/dev/null; then
        log_warn "nftband daemon not running - feeds and bans will not work!"
        log_warn "Attempting to start nftband.service..."
        if systemctl start nftband.service 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet nftband.service 2>/dev/null; then
                log_info "AUTO-FIXED: Started nftband daemon"
            else
                log_error "nftband daemon failed to start - check: journalctl -u nftband.service"
            fi
        else
            log_error "Failed to start nftband daemon"
        fi
    else
        log_info "✅ nftband daemon is running"
    fi
else
    log_warn "nftband.service not installed - daemon functionality unavailable"
fi

# =============================================================================
# 6. Create default configuration if missing
# =============================================================================
log_info "Checking configuration files..."

if [ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]; then
    log_warn "Main configuration missing - please run: nftban config init"
fi

# =============================================================================
# 7. Test nftables access
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
# 8. Auto-fix cPanel/iptables-nft legacy rules (v1.17.5)
# =============================================================================
# cPanel and some systems create iptables-nft rules with "xt target REDIRECT"
# that modern nftables cannot load. This causes nftables.service to fail
# and can lock out servers during install/update.
log_info "Checking for incompatible xt target rules..."

NFT_CONFIG=""
if [ -f "/etc/sysconfig/nftables.conf" ]; then
    NFT_CONFIG="/etc/sysconfig/nftables.conf"
elif [ -f "/etc/nftables.conf" ]; then
    NFT_CONFIG="/etc/nftables.conf"
fi

if [ -n "$NFT_CONFIG" ]; then
    # Test if config can be loaded without errors
    NFT_CHECK=$(nft -c -f "$NFT_CONFIG" 2>&1 || true)
    if echo "$NFT_CHECK" | grep -qE "xt target|xtables compat"; then
        log_warn "Detected incompatible xt target rules in $NFT_CONFIG"
        log_info "AUTO-FIXING: Backing up and replacing config..."

        # Backup original
        cp "$NFT_CONFIG" "${NFT_CONFIG}.xt-backup.$(date +%Y%m%d%H%M%S)"
        log_info "Backup saved to ${NFT_CONFIG}.xt-backup.*"

        # Replace with clean include of NFTBan config
        cat > "$NFT_CONFIG" << 'NFTCLEAN'
#!/usr/sbin/nft -f
# NFTBan v1.17.5 - Clean nftables config (auto-fixed by autoheal)
# Original backed up with .xt-backup.* extension
# xt target rules removed to prevent nftables.service failure
include "/etc/nftban/nftables.conf"
NFTCLEAN

        log_info "✅ Fixed $NFT_CONFIG - xt target rules removed"

        # Restart nftables service if it was failed
        if systemctl is-failed --quiet nftables.service 2>/dev/null; then
            log_info "Restarting nftables.service after fix..."
            if systemctl restart nftables.service 2>/dev/null; then
                log_info "✅ nftables.service restarted successfully"
            else
                log_warn "nftables.service restart failed - check: journalctl -u nftables.service"
            fi
        fi
    else
        log_info "✅ No incompatible xt target rules detected"
    fi
else
    log_info "No system nftables.conf found (using NFTBan direct)"
fi

# =============================================================================
# 9. Remove rogue nftables tables (v1.17.6)
# =============================================================================
# iptables-nft, docker, fail2ban can create rogue tables like "ip raw", "ip filter"
# These interfere with NFTBan and cause schema corruption
log_info "Checking for rogue nftables tables..."

# Allowed tables (v1.18.0: ONLY ip/ip6 nftban - NO inet tables!)
# CVE-2025-NFTBAN-001: inet filter at priority 0 bypasses NFTBan protection
ALLOWED_TABLES_PATTERN="^table (ip|ip6) nftban$"

# Get all tables
ALL_TABLES=$(nft list tables 2>/dev/null || true)

# Find and remove rogue tables
ROGUE_COUNT=0
while IFS= read -r table_line; do
    [[ -z "$table_line" ]] && continue

    # Check if table is allowed
    if ! echo "$table_line" | grep -qE "$ALLOWED_TABLES_PATTERN"; then
        ROGUE_COUNT=$((ROGUE_COUNT + 1))
        log_warn "Detected rogue table: $table_line"

        # Extract table family and name (e.g., "table ip raw" -> "ip raw")
        TABLE_SPEC="${table_line#table }"

        # Delete the rogue table
        # v1.19.20 FIX
        if nft delete table "$TABLE_SPEC" 2>/dev/null; then
            log_info "✅ Deleted rogue table: $TABLE_SPEC"
        else
            log_error "Failed to delete rogue table: $TABLE_SPEC"
        fi
    fi
done <<< "$ALL_TABLES"

if [[ $ROGUE_COUNT -eq 0 ]]; then
    log_info "✅ No rogue tables detected - schema clean"
else
    log_info "Removed $ROGUE_COUNT rogue table(s)"
fi

# =============================================================================
# 10. Validate and auto-repair NFT schema (v1.17.7)
# =============================================================================
log_info "Validating NFT schema..."

NFTBAN_CMD="${NFTBAN_BIN:-/usr/sbin/nftban}"

# Check if required tables exist
if ! nft list table ip nftban &>/dev/null; then
    log_warn "NFTBan IPv4 table missing - attempting rebuild..."
    if "$NFTBAN_CMD" firewall rebuild --quiet 2>/dev/null; then
        log_info "✅ Schema rebuilt successfully"
    else
        log_error "Schema rebuild failed - manual intervention required"
        log_error "Try: nftban firewall reset --force"
    fi
elif ! nft list table ip6 nftban &>/dev/null; then
    log_warn "NFTBan IPv6 table missing - attempting rebuild..."
    if "$NFTBAN_CMD" firewall rebuild --quiet 2>/dev/null; then
        log_info "✅ Schema rebuilt successfully"
    else
        log_warn "IPv6 schema rebuild failed (IPv6 support optional)"
    fi
else
    # Tables exist - validate schema structure
    SCHEMA_ERRORS=$("$NFTBAN_CMD" firewall validate --quiet 2>&1 | grep -c "ERROR" || echo "0")
    if [[ "$SCHEMA_ERRORS" -gt 0 ]]; then
        log_warn "Schema validation found $SCHEMA_ERRORS error(s) - attempting rebuild..."
        if "$NFTBAN_CMD" firewall rebuild --quiet 2>/dev/null; then
            log_info "✅ Schema rebuilt after validation errors"
        else
            log_error "Schema rebuild failed - manual intervention required"
        fi
    else
        log_info "✅ NFT schema validation passed"
    fi
fi

# =============================================================================
# Automatically fix common issues
# =============================================================================
log_info "Running automated fixes..."

# Use centralized NFTBAN_BIN path
NFTBAN_CMD="${NFTBAN_BIN:-/usr/sbin/nftban}"

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

    # Verify eve-alerts.json exists and is being written (use central config path)
    EVE_LOG="${NFTBAN_SURICATA_EVE_LOG:-/var/log/nftban/suricata/eve-alerts.json}"
    EVE_DIR=$(dirname "$EVE_LOG")

    # Bug fix v1.12.9: Detect Suricata user (suricata on RHEL, root on Debian/Ubuntu)
    if id suricata >/dev/null 2>&1; then
        SURI_USER="suricata"
    else
        SURI_USER="root"
    fi

    # CRITICAL: Create EVE directory and file if missing
    # Bug fix v1.12.8: Suricata 7.x with threaded:yes only creates file on first event
    # nftban-suricata daemon requires file to exist on startup
    if [ ! -d "$EVE_DIR" ]; then
        mkdir -p "$EVE_DIR" 2>/dev/null
        chown "${SURI_USER}:nftban" "$EVE_DIR" 2>/dev/null
        chmod 770 "$EVE_DIR" 2>/dev/null
        log_info "Created Suricata log directory: $EVE_DIR (owner: $SURI_USER)"
    fi

    if [ ! -f "$EVE_LOG" ]; then
        touch "$EVE_LOG" 2>/dev/null
        chown "${SURI_USER}:nftban" "$EVE_LOG" 2>/dev/null
        chmod 640 "$EVE_LOG" 2>/dev/null
        log_info "Created Suricata EVE log file: $EVE_LOG"
    fi

    if [ -f "$EVE_LOG" ]; then
        # Check if file is recent (modified in last 5 minutes)
        if [ "$(find "$EVE_LOG" -mmin -5 2>/dev/null)" ]; then
            log_info "✅ Suricata eve-alerts.json is actively writing"
        else
            log_warn "Suricata eve-alerts.json not recently updated - may not be capturing traffic"
        fi
    else
        log_warn "Failed to create Suricata eve-alerts.json at $EVE_LOG"
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
# Auto-fix metrics exporters (node_exporter + VictoriaMetrics)
# =============================================================================
log_info "Checking metrics exporters configuration..."

# Fix node_exporter textfile collector directory permissions
# NOTE: This is INTENTIONAL external tool integration, NOT managed by nftban FHS spec
# node_exporter is a Prometheus exporter owned by its own package
# nftban writes metrics to textfile_collector; node_exporter reads them
if [ -d "/var/lib/node_exporter" ]; then
    # Parent directory: node_exporter package default (755 root:root)
    # We don't change ownership - just ensure readable
    chmod 755 /var/lib/node_exporter 2>/dev/null || true

    # Textfile collector directory - shared between node_exporter (read) and nftban (write)
    # Permission model: node_exporter:nftban 775 allows both services access
    if [ -d "/var/lib/node_exporter/textfile_collector" ]; then
        if id node_exporter &>/dev/null; then
            chown node_exporter:nftban /var/lib/node_exporter/textfile_collector 2>/dev/null || true
            chmod 775 /var/lib/node_exporter/textfile_collector 2>/dev/null || true
            log_info "Fixed node_exporter textfile collector permissions (node_exporter:nftban 775)"
        fi
    fi
fi

# Fix VictoriaMetrics scrape configuration (conflicting metric_relabel_configs)
VICTORIA_SCRAPE_CONF="/etc/victoriametrics/scrape.yml"
if [ -f "$VICTORIA_SCRAPE_CONF" ]; then
    # Check if config has the conflicting double-keep pattern
    if grep -q "action: keep" "$VICTORIA_SCRAPE_CONF" 2>/dev/null; then
        # Count how many "action: keep" lines exist
        KEEP_COUNT=$(grep -c "action: keep" "$VICTORIA_SCRAPE_CONF" 2>/dev/null || echo "0")

        if [ "$KEEP_COUNT" -gt 1 ]; then
            log_info "Fixing VictoriaMetrics scrape config (conflicting rules)..."

            # Backup original
            cp "$VICTORIA_SCRAPE_CONF" "${VICTORIA_SCRAPE_CONF}.bak" 2>/dev/null || true

            # Write corrected config
            cat > "$VICTORIA_SCRAPE_CONF" <<'VICTORIA_EOF'
global:
  scrape_interval: 60s

scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      # Keep NFTBan metrics and essential node_exporter metrics
      - source_labels: [__name__]
        regex: '(nftban_.*|node_(cpu|memory|disk|network).*)'
        action: keep
VICTORIA_EOF

            # Restart VictoriaMetrics if running
            if systemctl is-active --quiet victoriametrics 2>/dev/null; then
                systemctl restart victoriametrics 2>/dev/null || true
                log_info "Restarted VictoriaMetrics with fixed config"
            fi
        fi
    fi
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
        # v1.19.20 FIX
        ((LOGIN_ISSUES_FIXED++)) || true
    fi

    # 2. Check core module exists
    if [ ! -f "${NFTBAN_LIB_DIR}/core/nftban_login_alert.sh" ]; then
        log_warn "Login alert core module not found"
        # v1.19.20 FIX
        ((LOGIN_ISSUES_FOUND++)) || true
    fi

    # 3. Check if service should be running but isn't
    login_monitor_svc="${NFTBAN_SERVICE_LOGIN_MONITOR:-nftban-login-monitor.service}"
    if [ -f "/etc/systemd/system/$login_monitor_svc" ]; then
        if systemctl is-enabled --quiet "$login_monitor_svc" 2>/dev/null; then
            if ! systemctl is-active --quiet "$login_monitor_svc" 2>/dev/null; then
                log_warn "Login monitor service enabled but not running - attempting restart"
                if systemctl start "$login_monitor_svc" 2>/dev/null; then
                    log_info "✅ Started login monitor service"
                    # v1.19.20 FIX
                    ((LOGIN_ISSUES_FIXED++)) || true
                else
                    log_warn "Failed to start login monitor service"
                    # v1.19.20 FIX
                    ((LOGIN_ISSUES_FOUND++)) || true
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
log_info "✅ FHS directories verified from specification (${#NFTBAN_FHS_DIRECTORIES[@]} paths)"
log_info "✅ Permissions enforced from FHS spec (single source of truth)"
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
