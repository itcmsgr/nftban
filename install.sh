#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic paths, cannot follow
# =============================================================================
# NFTBan v1.9.3 - Installation Script (Loader)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Install NFTBan on the local system
#
# meta:name="nftban_install"
# meta:type="cli"
# meta:header="NFTBan Installer"
# meta:version="1.7.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Main installation script for NFTBan firewall management system (loader)"
# meta:input="Interactive prompts for configuration options"
# meta:output="Installed NFTBan system with binaries, configs, and systemd units"
# meta:depends="bash,curl,systemctl,useradd,chmod,chown,mkdir,cp,ln"
# meta:created_date="2025-10-26"
# meta:updated_date="2026-02-04"
#
# **Inventory & Requirements**
# meta:inventory.files=""
# meta:inventory.binaries="curl,systemctl,useradd,groupadd,chmod,chown,mkdir,cp,ln,tput,id"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban.service,nftban-watchdog.timer,nftban-queue.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Installs:
#   - Go binaries (nftban-core, nftband, nftban-ui)
#   - CLI modules and libraries
#   - Polkit rules
#   - Systemd timers
#   - NFTables base config
#   - GeoIP database (free)
# =============================================================================

set -Eeuo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[INSTALL]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK   ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN  ]${NC} $*"; }
error() { echo -e "${RED}[ ERROR ]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[  INFO ]${NC} $*"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR="$(pwd)"
cd "$SCRIPT_DIR"

# Configuration (exported for submodules)
export BIN_DIR="$SCRIPT_DIR/bin"

# Installation paths (exported for submodules)
export CORE_BIN_DIR="/usr/lib/nftban/bin"
export CORE_INSTALL_PATH="$CORE_BIN_DIR/nftban-core"
export CLI_INSTALL_PATH="/usr/sbin/nftban"
export GUI_INSTALL_PATH="/usr/sbin/nftban-ui"
export LIB_DIR="/usr/lib/nftban"
export COMPLETION_PATH="/usr/share/bash-completion/completions/nftban"
export POLKIT_ACTIONS_DIR="/usr/share/polkit-1/actions"
export POLKIT_RULES_DIR_SHARE="/usr/share/polkit-1/rules.d"
export POLKIT_RULES_DIR_ETC="/etc/polkit-1/rules.d"

# =============================================================================
# MODULE LOADER
# =============================================================================
# Installation functions are split into separate files for maintainability:
#
# install_prerequisites.sh  - Prerequisite checks, firewall detection, GeoIP
# install_binaries.sh       - Binary/CLI/library installation, users/groups
# install_configs.sh        - Configuration files, templates, dependencies
# install_services.sh       - Systemd units, polkit, post-install tasks
# =============================================================================

_install_modules=(
    "install_prerequisites.sh"
    "install_binaries.sh"
    "install_configs.sh"
    "install_services.sh"
)

for _module in "${_install_modules[@]}"; do
    _module_path="${SCRIPT_DIR}/${_module}"
    if [[ -f "$_module_path" ]]; then
        source "$_module_path" || {
            error "Failed to load install module: $_module"
            exit 1
        }
    else
        error "Install module not found: $_module_path"
        exit 1
    fi
done

# Cleanup temporary variables
unset _install_modules _module _module_path

# =============================================================================
# MAIN INSTALLATION LOGIC
# =============================================================================

# Installation flags (can be set via CLI or environment)
SKIP_XTABLES_FIX="${NFTBAN_SKIP_XTABLES_FIX:-0}"
NFTBAN_QUIET="${NFTBAN_QUIET:-0}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h|help)
            show_usage
            exit 0
            ;;
        --quiet|--yes|-y)
            NFTBAN_QUIET=1
            shift
            ;;
        --skip-xtables-fix)
            SKIP_XTABLES_FIX=1
            shift
            ;;
        *)
            warn "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Print banner
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NFTBan Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# STEP 1: Prerequisites
# =============================================================================
log "Step 1: Checking prerequisites..."
echo ""

check_prerequisites
check_root
check_nftables
check_yq
check_pam
check_conflicting_firewalls

if [[ "$SKIP_XTABLES_FIX" == "1" ]]; then
    info "Skipping xtables compat fix (--skip-xtables-fix)"
else
    check_xtables_compat
fi

check_go_binaries

echo ""

# =============================================================================
# STEP 2: Ask about metrics
# =============================================================================
ask_metrics_question

# =============================================================================
# STEP 3: Install everything
# =============================================================================
log "Step 2: Installing NFTBan..."
echo ""

install_dependencies || warn "Dependency installation failed (non-critical)"
echo ""

cleanup_obsolete_files || warn "Cleanup had some errors (non-critical)"
echo ""

create_users_groups || exit 1
echo ""

install_core || exit 1
echo ""

install_cli || exit 1
echo ""

install_libraries || exit 1
echo ""

install_completion || exit 1
echo ""

install_configs || exit 1
echo ""

install_nftables || exit 1
echo ""

install_safety_whitelist || warn "Auto-whitelist failed (non-critical)"
echo ""

install_tmpfiles || warn "tmpfiles.d installation failed (non-critical)"
echo ""

install_polkit || exit 1
echo ""

install_logrotate || warn "Logrotate installation failed (non-critical)"
echo ""

install_systemd || exit 1
echo ""

# =============================================================================
# STEP 4: Download GeoIP database
# =============================================================================
download_geoip_database
echo ""

# =============================================================================
# STEP 5: Configure metrics if enabled
# =============================================================================
if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
    log "Configuring metrics (${NFTBAN_METRICS_BACKEND})..."

    if [[ -f /etc/nftban/nftban.conf ]]; then
        sed -i "s/^NFTBAN_METRICS_ENABLED=.*/NFTBAN_METRICS_ENABLED=\"true\"/" /etc/nftban/nftban.conf
        sed -i "s/^NFTBAN_METRICS_BACKEND=.*/NFTBAN_METRICS_BACKEND=\"${NFTBAN_METRICS_BACKEND}\"/" /etc/nftban/nftban.conf
        ok "Metrics configuration updated"
    fi

    if [[ -f /etc/systemd/system/nftban-unified-exporter.timer ]]; then
        systemctl enable --now nftban-unified-exporter.timer 2>/dev/null || true
        ok "Unified exporter timer enabled"
    fi
    echo ""
fi

# =============================================================================
# STEP 6: Auto-enable default features (login, geoip)
# =============================================================================
log "Enabling default features..."

# Enable login monitoring
if [[ ! -f /etc/nftban/conf.d/login_alert.conf ]]; then
    mkdir -p /etc/nftban/conf.d
    cat > /etc/nftban/conf.d/login_alert.conf << 'LOGIN_CONF'
# NFTBan Login Alert Configuration
# Auto-generated by installer

# Enable login alerts (SSH, etc.)
NFTBAN_LOGIN_ALERT_ENABLED="YES"

# Alert methods: mail, webhook, both
NFTBAN_LOGIN_ALERT_METHOD="mail"

# Alert on successful logins (in addition to failures)
NFTBAN_LOGIN_ALERT_SUCCESS="NO"
LOGIN_CONF
    chmod 640 /etc/nftban/conf.d/login_alert.conf
    chown root:nftban /etc/nftban/conf.d/login_alert.conf
fi

# Enable login monitor service
if systemctl list-unit-files nftban-login-monitor.service &>/dev/null 2>&1; then
    systemctl enable nftban-login-monitor.service 2>/dev/null || true
    systemctl start nftban-login-monitor.service 2>/dev/null || true
    ok "Login monitoring enabled"
fi

# Enable GeoIP
if [[ -f /etc/nftban/conf.d/geoip/main.conf ]]; then
    if ! grep -q "^NFTBAN_GEOIP_ENABLED=" /etc/nftban/conf.d/geoip/main.conf 2>/dev/null; then
        echo 'NFTBAN_GEOIP_ENABLED="YES"' >> /etc/nftban/conf.d/geoip/main.conf
    fi
fi
if systemctl list-unit-files nftban-core-geoip.timer &>/dev/null 2>&1; then
    systemctl enable nftban-core-geoip.timer 2>/dev/null || true
    systemctl start nftban-core-geoip.timer 2>/dev/null || true
    ok "GeoIP auto-update enabled"
fi

echo ""

# =============================================================================
# STEP 7: Panel Detection and Auto-Enable
# =============================================================================
log "Checking for web hosting panels..."

PANEL_ENABLED=""

# cPanel/WHM detection
if [[ -d /usr/local/cpanel ]]; then
    PANEL_ENABLED="cpanel"
    ok "Detected: cPanel/WHM"
    info "cPanel ports will be auto-whitelisted"
fi

# Plesk detection
if [[ -d /usr/local/psa ]]; then
    PANEL_ENABLED="plesk"
    ok "Detected: Plesk"
fi

# DirectAdmin detection
if [[ -d /usr/local/directadmin ]]; then
    PANEL_ENABLED="directadmin"
    ok "Detected: DirectAdmin"
fi

# CyberPanel detection
if [[ -d /usr/local/CyberCP ]]; then
    PANEL_ENABLED="cyberpanel"
    ok "Detected: CyberPanel"
fi

if [[ -n "$PANEL_ENABLED" ]]; then
    info "Panel integration: $PANEL_ENABLED"
    info "Run 'nftban panel $PANEL_ENABLED enable' to configure"
    echo ""
else
    ok "No web hosting panel detected (standalone server)"
fi

# Security: rpcbind exposure check
if ss -lunpt 2>/dev/null | grep -q ':111 '; then
    echo ""
    warn "Security: Port 111 (rpcbind) is exposed"
    info "Consider: nftban port block 111  OR  systemctl disable rpcbind"
fi

echo ""

# =============================================================================
# STEP 8: Post-install and verification
# =============================================================================
run_post_install || exit 1
echo ""

# Run verification
log "Verifying installation..."
if [[ -f "$SCRIPT_DIR/install/verify_installation.sh" ]]; then
    bash "$SCRIPT_DIR/install/verify_installation.sh"
    VERIFY_EXIT=$?
    echo ""
    if [[ $VERIFY_EXIT -eq 0 ]]; then
        ok "Installation verification PASSED"
    else
        warn "Some verification checks failed (review output above)"
    fi
fi

# =============================================================================
# COMPLETE
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NFTBan Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Auto-enabled:"
echo "  Login monitoring (SSH alerts)"
echo "  GeoIP blocking"
echo "  Core timers (health, maintenance)"
if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
    echo "  Metrics (${NFTBAN_METRICS_BACKEND})"
    echo "  Watchdog (system monitoring)"
fi
if [[ -n "${PANEL_ENABLED:-}" ]]; then
    echo "  ${PANEL_ENABLED^} panel ports"
fi
echo ""

# Panel-specific instructions
if [[ -n "${PANEL_ENABLED:-}" ]]; then
    echo "Panel commands:"
    echo "  nftban panel $PANEL_ENABLED status   # Check panel port status"
    echo "  nftban panel $PANEL_ENABLED test     # Test panel connectivity"
    echo "  nftban port status                   # View all port rules"
    echo ""
fi

echo "Enable optional features:"
echo "  nftban feeds enable      # Threat intel feeds"
echo "  nftban portscan enable   # Port scan detection"
echo "  nftban ddos enable       # DDoS protection"
echo "  nftban gui enable        # Web GUI"
echo "  nftban suricata setup    # IDS integration"
if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]]; then
    echo "  nftban metrics enable    # Metrics collection"
    echo "  nftban watchdog enable   # System monitoring"
fi
echo ""
echo "Check status:"
echo "  nftban status            # System status"
echo "  nftban health            # Health check"
echo "  nftban port status       # Port/firewall status"
echo ""
