#!/usr/bin/env bash
# =============================================================================
# NFTBan Installation Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Install NFTBan on the local system
# Usage: ./install.sh
#
# Installs:
#   - Go binaries (nftban-core, nftban-ui)
#   - CLI modules and libraries
#   - Polkit rules
#   - Systemd timers
#   - NFTables base config
#   - GeoIP database (free)
#
# One question: Enable metrics? (prometheus/victoriametrics)
#
# Later (via CLI):
#   - nftban gui enable
#   - nftban suricata setup
# =============================================================================

set -euo pipefail

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
BIN_DIR="$SCRIPT_DIR/bin"

# Installation paths
CORE_BIN_DIR="/usr/lib/nftban/bin"
CORE_INSTALL_PATH="$CORE_BIN_DIR/nftban-core"
CLI_INSTALL_PATH="/usr/bin/nftban"
GUI_INSTALL_PATH="/usr/sbin/nftban-ui"
LIB_DIR="/usr/lib/nftban"
COMPLETION_PATH="/usr/share/bash-completion/completions/nftban"
POLKIT_ACTIONS_DIR="/usr/share/polkit-1/actions"
POLKIT_RULES_DIR_SHARE="/usr/share/polkit-1/rules.d"
POLKIT_RULES_DIR_ETC="/etc/polkit-1/rules.d"

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        echo "Try: sudo $0"
        exit 1
    fi
}

# Check and install nftables (REQUIRED)
check_nftables() {
    log "Checking nftables..."

    if command -v nft &>/dev/null; then
        ok "nftables found: $(nft --version 2>/dev/null | head -1)"
        return 0
    fi

    warn "nftables not found - installing..."

    # Detect package manager and install
    if command -v dnf &>/dev/null; then
        dnf install -y nftables || { error "Failed to install nftables"; exit 1; }
    elif command -v yum &>/dev/null; then
        yum install -y nftables || { error "Failed to install nftables"; exit 1; }
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y nftables || { error "Failed to install nftables"; exit 1; }
    elif command -v zypper &>/dev/null; then
        zypper install -y nftables || { error "Failed to install nftables"; exit 1; }
    else
        error "Unknown package manager. Please install nftables manually."
        exit 1
    fi

    ok "nftables installed successfully"
}

# Check for conflicting firewalls (CRITICAL - prevents conflicts)
check_conflicting_firewalls() {
    log "Checking for conflicting firewalls..."

    local conflicts_found=0
    local firewall_issues=()

    # 1. Check firewalld
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall_issues+=("firewalld is ACTIVE")
            conflicts_found=1
        elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
            firewall_issues+=("firewalld is ENABLED (not running)")
            conflicts_found=1
        fi
    fi

    # 2. Check iptables (legacy service)
    if command -v iptables &>/dev/null; then
        if systemctl is-active --quiet iptables 2>/dev/null; then
            firewall_issues+=("iptables service is ACTIVE")
            conflicts_found=1
        elif systemctl is-enabled --quiet iptables 2>/dev/null; then
            firewall_issues+=("iptables service is ENABLED (not running)")
            conflicts_found=1
        fi
    fi

    # 3. Check iptables-services (RHEL/CentOS)
    if systemctl is-active --quiet iptables.service 2>/dev/null || \
       systemctl is-active --quiet ip6tables.service 2>/dev/null; then
        firewall_issues+=("iptables-services is ACTIVE")
        conflicts_found=1
    fi

    # 4. Check ufw (Ubuntu/Debian)
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_issues+=("ufw is ACTIVE")
            conflicts_found=1
        fi
    fi

    # If no conflicts, all good
    if [[ $conflicts_found -eq 0 ]]; then
        ok "No conflicting firewalls detected"
        return 0
    fi

    # CONFLICT DETECTED - Show warnings
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    error "⚠ CONFLICTING FIREWALL(S) DETECTED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    warn "NFTBan uses nftables and CANNOT coexist with these firewalls:"
    echo ""
    for issue in "${firewall_issues[@]}"; do
        echo "  ✗ $issue"
    done
    echo ""
    echo "These firewalls will conflict with NFTBan and cause:"
    echo "  • Duplicate filtering rules"
    echo "  • Unpredictable blocking behavior"
    echo "  • Performance degradation"
    echo "  • NFTBan blocks may not work"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "MANUAL FIX INSTRUCTIONS:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show specific commands for each detected firewall
    for issue in "${firewall_issues[@]}"; do
        if [[ "$issue" == *"firewalld"* ]]; then
            echo "Disable firewalld:"
            echo "  systemctl stop firewalld"
            echo "  systemctl disable firewalld"
            echo ""
        fi
        if [[ "$issue" == *"iptables"* ]]; then
            echo "Disable iptables:"
            echo "  systemctl stop iptables"
            echo "  systemctl disable iptables"
            echo "  systemctl stop ip6tables 2>/dev/null || true"
            echo "  systemctl disable ip6tables 2>/dev/null || true"
            echo ""
        fi
        if [[ "$issue" == *"ufw"* ]]; then
            echo "Disable ufw:"
            echo "  ufw disable"
            echo "  systemctl stop ufw 2>/dev/null || true"
            echo "  systemctl disable ufw 2>/dev/null || true"
            echo ""
        fi
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Ask user if they want automatic fix
    read -p "Would you like NFTBan to automatically stop and disable these firewalls? [y/N]: " auto_fix

    if [[ "${auto_fix,,}" == "y" || "${auto_fix,,}" == "yes" ]]; then
        echo ""
        log "Automatically stopping and disabling conflicting firewalls..."

        local fixed=0
        local failed=0

        # Fix firewalld
        if systemctl is-active --quiet firewalld 2>/dev/null || systemctl is-enabled --quiet firewalld 2>/dev/null; then
            log "Stopping firewalld..."
            if systemctl stop firewalld 2>/dev/null && systemctl disable firewalld 2>/dev/null; then
                ok "firewalld stopped and disabled"
                fixed=$((fixed + 1))
            else
                warn "Failed to stop/disable firewalld"
                failed=$((failed + 1))
            fi
        fi

        # Fix iptables
        if systemctl is-active --quiet iptables 2>/dev/null || systemctl is-enabled --quiet iptables 2>/dev/null; then
            log "Stopping iptables..."
            if systemctl stop iptables 2>/dev/null && systemctl disable iptables 2>/dev/null; then
                systemctl stop ip6tables 2>/dev/null || true
                systemctl disable ip6tables 2>/dev/null || true
                ok "iptables stopped and disabled"
                fixed=$((fixed + 1))
            else
                warn "Failed to stop/disable iptables"
                failed=$((failed + 1))
            fi
        fi

        # Fix ufw
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            log "Disabling ufw..."
            if ufw --force disable 2>/dev/null && \
               systemctl stop ufw 2>/dev/null && \
               systemctl disable ufw 2>/dev/null; then
                ok "ufw disabled"
                fixed=$((fixed + 1))
            else
                warn "Failed to disable ufw"
                failed=$((failed + 1))
            fi
        fi

        echo ""
        if [[ $failed -gt 0 ]]; then
            error "Some firewalls could not be disabled automatically"
            echo "Please disable them manually using the commands above."
            exit 1
        else
            ok "All conflicting firewalls have been stopped and disabled ($fixed fixed)"
            echo ""
            info "NFTBan will now take over firewall management using nftables"
        fi
    else
        echo ""
        error "Installation cannot continue with conflicting firewalls active"
        echo ""
        echo "Please disable the conflicting firewalls manually and re-run:"
        echo "  sudo ./install.sh"
        echo ""
        exit 1
    fi

    echo ""
    return 0
}

# Check Go binaries exist (REQUIRED)
check_go_binaries() {
    log "Checking Go binaries..."

    local missing=0

    if [[ ! -f "$BIN_DIR/nftban-core" ]]; then
        error "Missing: $BIN_DIR/nftban-core"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        error "Go binaries not found!"
        echo ""
        echo "Build them first:"
        echo "  ./build.sh"
        echo ""
        echo "Or download pre-built binaries:"
        echo "  ./install/download-binaries.sh"
        echo ""
        exit 1
    fi

    ok "Go binaries found in $BIN_DIR/"
}

# Download FREE GeoIP database (DB-IP)
download_geoip_database() {
    log "Downloading FREE GeoIP database..."

    local geoip_dir="/var/lib/nftban/geoip"
    local db_file="${geoip_dir}/dbip-country-lite.mmdb"
    local download_url
    download_url="https://download.db-ip.com/free/dbip-country-lite-$(date +%Y-%m).mmdb.gz"

    mkdir -p "$geoip_dir"

    # Check if recent database exists (less than 30 days old)
    if [[ -f "$db_file" ]]; then
        local file_age
        local now_ts
        local file_ts
        now_ts=$(date +%s)
        file_ts=$(stat -c %Y "$db_file" 2>/dev/null || echo 0)
        file_age=$(( (now_ts - file_ts) / 86400 ))
        if [[ $file_age -lt 30 ]]; then
            ok "GeoIP database exists (${file_age} days old)"
            return 0
        fi
    fi

    # Download DB-IP free database
    if curl -fsSL "$download_url" -o "${db_file}.gz" 2>/dev/null; then
        gunzip -f "${db_file}.gz" 2>/dev/null || true
        chown nftban:nftban "$db_file" 2>/dev/null || true
        chmod 644 "$db_file"
        ok "GeoIP database downloaded: $db_file"
    else
        warn "Could not download GeoIP database (will retry on first use)"
        info "Manual download: nftban geoip update"
    fi
}

# Ask user about metrics
ask_metrics_question() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  METRICS CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Metrics provide monitoring dashboards (Grafana) for:"
    echo "  - Firewall statistics (bans, rules, traffic)"
    echo "  - System resources (CPU, RAM, disk)"
    echo "  - Security events"
    echo ""

    read -r -p "Enable metrics collection? [y/N]: " enable_metrics

    if [[ "${enable_metrics,,}" == "y" || "${enable_metrics,,}" == "yes" ]]; then
        echo ""
        echo "Select metrics backend:"
        echo "  1) prometheus        - Industry standard"
        echo "  2) victoriametrics   - 10x compression, recommended"
        echo ""
        read -r -p "Choice [2]: " backend_choice

        case "${backend_choice:-2}" in
            1|prometheus)
                NFTBAN_METRICS_ENABLED="true"
                NFTBAN_METRICS_BACKEND="prometheus"
                ok "Metrics: prometheus"
                ;;
            2|victoriametrics|*)
                NFTBAN_METRICS_ENABLED="true"
                NFTBAN_METRICS_BACKEND="victoriametrics"
                ok "Metrics: victoriametrics (recommended)"
                ;;
        esac
    else
        NFTBAN_METRICS_ENABLED="false"
        NFTBAN_METRICS_BACKEND=""
        info "Metrics disabled (enable later: nftban metrics enable)"
    fi
    echo ""
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================

check_binary() {
    local binary="$1"
    if [[ ! -f "$binary" ]]; then
        error "Binary not found: $binary"
        echo ""
        echo "Run ./build.sh first to build binaries"
        return 1
    fi
    return 0
}

install_core() {
    log "Installing Core Binaries..."

    # Check if binaries exist
    if ! check_binary "$BIN_DIR/nftban-core"; then
        warn "Core binaries not found in $BIN_DIR/"
        warn "Skipping binary installation (CLI will use bash fallbacks)"
        warn "To build binaries: run ./build.sh first"
        return 0
    fi

    # Create directories
    mkdir -p "$CORE_BIN_DIR"

    # Install nftban-core
    log "Installing nftban-core..."
    cp -f "$BIN_DIR/nftban-core" "$CORE_INSTALL_PATH"
    chmod 755 "$CORE_INSTALL_PATH"
    chown root:root "$CORE_INSTALL_PATH"
    ok "Installed: $CORE_INSTALL_PATH"

    # Set capabilities for nftban-core (allows non-root nftables operations)
    if command -v setcap &>/dev/null; then
        setcap 'cap_net_admin+ep' "$CORE_INSTALL_PATH" 2>/dev/null && \
            ok "CAP_NET_ADMIN set on nftban-core" || \
            warn "Could not set CAP_NET_ADMIN on nftban-core"

        # Set capabilities for nft binary (required for CLI fallback operations)
        if [[ -x /usr/sbin/nft ]]; then
            setcap 'cap_net_admin+ep' /usr/sbin/nft 2>/dev/null && \
                ok "CAP_NET_ADMIN set on /usr/sbin/nft" || \
                warn "Could not set CAP_NET_ADMIN on /usr/sbin/nft"
        fi
    else
        warn "setcap not found - install libcap for capability support"
    fi

    return 0
}

install_cli() {
    log "Installing CLI..."

    # Install CLI wrapper
    if [[ -f "$SCRIPT_DIR/cli/sbin/nftban" ]]; then
        cp -f "$SCRIPT_DIR/cli/sbin/nftban" "$CLI_INSTALL_PATH"
        chmod 755 "$CLI_INSTALL_PATH"
        chown root:root "$CLI_INSTALL_PATH"
        ok "Installed: $CLI_INSTALL_PATH"
    else
        error "CLI script not found: $SCRIPT_DIR/cli/sbin/nftban"
        return 1
    fi

    return 0
}

install_libraries() {
    log "Installing Shell Libraries..."

    # Create directories
    mkdir -p "$LIB_DIR"/{lib,cli,core,exporters,cron,helpers,setup,tests}

    # Safety: Remove duplicate nested nftban directories (legacy cleanup)
    if [ -d "$LIB_DIR/lib/nftban" ]; then
        rm -rf "$LIB_DIR/lib/nftban"
    fi

    # Copy libraries from source to target
    # Source: cli/lib/nftban/{lib,cli,core,exporters,cron,helpers,setup}/
    # Target: /usr/lib/nftban/{lib,cli,core,exporters,cron,helpers,setup}/
    cp -r "$SCRIPT_DIR/cli/lib/nftban/lib/"* "$LIB_DIR/lib/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/cli/"* "$LIB_DIR/cli/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/core/"* "$LIB_DIR/core/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/exporters/"* "$LIB_DIR/exporters/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/cron/"* "$LIB_DIR/cron/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/helpers/"* "$LIB_DIR/helpers/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/setup/"* "$LIB_DIR/setup/" 2>/dev/null || true

    # Copy test scripts
    cp -r "$SCRIPT_DIR/tests/"* "$LIB_DIR/tests/" 2>/dev/null || true

    # Copy root-level library files (help, json_output, etc.)
    cp "$SCRIPT_DIR/cli/lib/nftban/nftban_help.sh" "$LIB_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/cli/lib/nftban/json_output.sh" "$LIB_DIR/" 2>/dev/null || true

    # Set permissions - ALL shell scripts need to be executable for sourcing
    # The CLI sources these via 'source' or '.' which requires read+execute
    find "$LIB_DIR" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$LIB_DIR" -type f -name "*.conf" -exec chmod 644 {} \;
    find "$LIB_DIR" -type d -exec chmod 755 {} \;

    chown -R root:nftban "$LIB_DIR"

    ok "Shell libraries installed to $LIB_DIR"
    return 0
}

install_completion() {
    log "Installing Bash Completion..."

    # Create directory
    mkdir -p "$(dirname "$COMPLETION_PATH")"

    # Copy completion file
    if [[ -f "$SCRIPT_DIR/install/bash-completion/nftban" ]]; then
        cp -f "$SCRIPT_DIR/install/bash-completion/nftban" "$COMPLETION_PATH"
        chmod 644 "$COMPLETION_PATH"
        chown root:root "$COMPLETION_PATH"
        ok "Installed: $COMPLETION_PATH"
    else
        warn "Bash completion file not found"
    fi

    return 0
}

install_nftables() {
    log "Installing NFTables Configuration..."

    # Install nftables.conf to /etc/nftables.conf
    if [[ -f "$SCRIPT_DIR/install/nftables/nftables.conf" ]]; then
        cp -f "$SCRIPT_DIR/install/nftables/nftables.conf" /etc/nftables.conf
        chmod 644 /etc/nftables.conf
        chown root:root /etc/nftables.conf
        ok "Installed: /etc/nftables.conf"
    else
        error "NFTables config not found: $SCRIPT_DIR/install/nftables/nftables.conf"
        return 1
    fi

    # Create symlink for RHEL-family distros (CentOS, Rocky, Alma, Fedora)
    # These distros expect /etc/sysconfig/nftables.conf
    if [[ "${DISTRO_INFO[family]:-}" == "rhel" ]] || [[ -f /etc/redhat-release ]]; then
        log "Creating symlink for RHEL-family distro..."
        mkdir -p /etc/sysconfig
        ln -sf /etc/nftables.conf /etc/sysconfig/nftables.conf
        ok "Created symlink: /etc/sysconfig/nftables.conf -> /etc/nftables.conf"
    fi

    # Enable and start nftables service
    log "Enabling nftables service..."
    systemctl enable nftables 2>/dev/null || warn "Failed to enable nftables"
    systemctl restart nftables 2>/dev/null || warn "Failed to start nftables"
    ok "NFTables service enabled and started"

    return 0
}

create_users_groups() {
    log "Creating NFTBan Users and Groups..."

    # Create nftban system group
    if ! getent group nftban >/dev/null 2>&1; then
        groupadd --system nftban
        ok "Created group: nftban"
    else
        ok "Group already exists: nftban"
    fi

    # Create nftban system user
    if ! getent passwd nftban >/dev/null 2>&1; then
        useradd --system --home-dir /var/lib/nftban --shell /usr/sbin/nologin \
                --gid nftban --comment "NFTBan System User" nftban
        ok "Created user: nftban"
    else
        ok "User already exists: nftban"
    fi

    # Create nftban-auditors group (Read-only auditors)
    # NFTBan v1.0 uses simplified 2-group model:
    #   nftban: All operators (CLI, Web, services)
    #   nftban-auditors: Read-only audit access
    if ! getent group nftban-auditors >/dev/null 2>&1; then
        groupadd --system nftban-auditors
        ok "Created group: nftban-auditors"
    else
        ok "Group already exists: nftban-auditors"
    fi

    # Add root to nftban group (for CLI access)
    if ! id -nG root | grep -qw nftban 2>/dev/null; then
        usermod -aG nftban root 2>/dev/null || warn "Could not add root to nftban"
        ok "Added root to nftban group"
    fi

    echo ""
    log "Groups Summary (v1.0 simplified model):"
    echo "  • nftban          - All operators (CLI, Web GUI, service management)"
    echo "  • nftban-auditors - Read-only auditors (logs, reports)"
    echo ""
    ok "User and group setup complete"

    return 0
}

install_pam() {
    log "Installing PAM Configuration..."

    # Install PAM config for nftban-ui (GUI authentication)
    if [[ -f "$SCRIPT_DIR/install/pam/nftban-ui" ]]; then
        cp -f "$SCRIPT_DIR/install/pam/nftban-ui" /etc/pam.d/nftban-ui
        chmod 644 /etc/pam.d/nftban-ui
        chown root:root /etc/pam.d/nftban-ui
        ok "Installed: /etc/pam.d/nftban-ui"
    else
        error "PAM config not found: $SCRIPT_DIR/install/pam/nftban-ui"
        return 1
    fi

    # Install gui-groups file (list of groups allowed to use GUI)
    # This file is used by pam_listfile.so or pam_succeed_if.so
    if [[ ! -f /etc/nftban/gui-groups ]]; then
        echo "nftban" > /etc/nftban/gui-groups
        chmod 644 /etc/nftban/gui-groups
        chown root:nftban /etc/nftban/gui-groups
        ok "Created: /etc/nftban/gui-groups (default: nftban)"
    else
        ok "GUI groups file exists: /etc/nftban/gui-groups"
    fi

    ok "PAM configuration installed"
    return 0
}

install_configs() {
    log "Installing Configuration Files..."

    # Create config directories
    mkdir -p /etc/nftban/{whitelist.d,blacklist.d,ports.d,conf.d,distros}
    mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels}
    mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state}
    mkdir -p /var/lib/nftban/reports/auditors
    mkdir -p /var/log/nftban
    mkdir -p /var/cache/nftban
    mkdir -p /run/nftban

    # Set ownership (nftban user/group must exist first)
    chown -R root:nftban /etc/nftban
    chmod 750 /etc/nftban
    chmod 750 /etc/nftban/conf.d
    chmod 755 /etc/nftban/distros

    chown -R nftban:nftban /var/lib/nftban
    chmod 750 /var/lib/nftban
    chmod 750 /var/lib/nftban/reports
    chmod 770 /var/lib/nftban/reports/auditors
    chown root:nftban-auditors /var/lib/nftban/reports/auditors

    chown -R nftban:nftban /var/log/nftban
    chmod 750 /var/log/nftban

    chown -R nftban:nftban /var/cache/nftban
    chmod 755 /var/cache/nftban

    chown -R nftban:nftban /run/nftban
    chmod 755 /run/nftban

    ok "Directory ownership configured"

    # Install main configuration file (if not exists - don't overwrite user config)
    if [[ -f "$SCRIPT_DIR/install/config/nftban.conf" ]] && [[ ! -f /etc/nftban/nftban.conf ]]; then
        cp -f "$SCRIPT_DIR/install/config/nftban.conf" /etc/nftban/nftban.conf
        chmod 644 /etc/nftban/nftban.conf
        chown root:nftban /etc/nftban/nftban.conf
        ok "Installed: /etc/nftban/nftban.conf"
    elif [[ -f /etc/nftban/nftban.conf ]]; then
        ok "Main config exists (not overwriting): /etc/nftban/nftban.conf"
    fi

    # Install distro configuration files
    if [[ -d "$SCRIPT_DIR/etc/nftban/distros" ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/distros/"*.conf /etc/nftban/distros/
        chmod 644 /etc/nftban/distros/*.conf
        chown root:root /etc/nftban/distros/*.conf
        local count
        count=$(ls -1 /etc/nftban/distros/*.conf 2>/dev/null | wc -l)
        ok "Installed $count distro config files"
    fi

    # Removed: fail2ban config installation (v1.0 migration to Suricata)

    # Install feeds config if exists
    if [[ -f "$SCRIPT_DIR/install/config/feeds.conf" ]]; then
        cp -f "$SCRIPT_DIR/install/config/feeds.conf" /etc/nftban/conf.d/feeds.conf
        chmod 644 /etc/nftban/conf.d/feeds.conf
        chown root:nftban /etc/nftban/conf.d/feeds.conf
        ok "Installed: /etc/nftban/conf.d/feeds.conf (15 feeds)"
    fi

    # Install mail configuration (if not exists - don't overwrite user config)
    if [[ -f "$SCRIPT_DIR/etc/nftban/conf.d/mail.conf" ]] && [[ ! -f /etc/nftban/conf.d/mail.conf ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/conf.d/mail.conf" /etc/nftban/conf.d/mail.conf
        chmod 644 /etc/nftban/conf.d/mail.conf
        chown root:nftban /etc/nftban/conf.d/mail.conf
        ok "Installed: /etc/nftban/conf.d/mail.conf"
    elif [[ -f /etc/nftban/conf.d/mail.conf ]]; then
        ok "Mail config exists (not overwriting): /etc/nftban/conf.d/mail.conf"
    fi

    # Install GUI groups config if exists
    if [[ -f "$SCRIPT_DIR/install/config/allowed-gui-groups" ]]; then
        cp -f "$SCRIPT_DIR/install/config/allowed-gui-groups" /etc/nftban/
        chmod 644 /etc/nftban/allowed-gui-groups
        chown root:nftban /etc/nftban/allowed-gui-groups
        ok "Installed: /etc/nftban/allowed-gui-groups"
    fi

    # Install PAM configuration for nftban-ui authentication
    install_pam || warn "PAM configuration failed (non-critical)"

    # Install templates (mail and reports)
    install_templates

    ok "Configuration files installed"
    return 0
}

install_templates() {
    log "Installing Templates..."

    # Create template directories
    mkdir -p /usr/share/nftban/templates/{mail,reports}

    # Install mail templates
    if [[ -d "$SCRIPT_DIR/cli/share/nftban/templates/mail" ]]; then
        cp -f "$SCRIPT_DIR/cli/share/nftban/templates/mail/"*.html /usr/share/nftban/templates/mail/ 2>/dev/null || true
        local mail_count
        mail_count=$(ls -1 /usr/share/nftban/templates/mail/*.html 2>/dev/null | wc -l)
        ok "Installed $mail_count mail templates"
    fi

    # Install report templates
    if [[ -d "$SCRIPT_DIR/cli/share/nftban/templates/reports" ]]; then
        cp -f "$SCRIPT_DIR/cli/share/nftban/templates/reports/"*.html /usr/share/nftban/templates/reports/ 2>/dev/null || true
        local report_count
        report_count=$(ls -1 /usr/share/nftban/templates/reports/*.html 2>/dev/null | wc -l)
        ok "Installed $report_count report templates"
    fi

    # Set permissions
    chown -R root:root /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates/mail
    chmod 755 /usr/share/nftban/templates/reports
    find /usr/share/nftban/templates -type f -name "*.html" -exec chmod 644 {} \;

    # Install spec files (for nftban validate)
    mkdir -p /usr/share/nftban/specs
    if [[ -d "$SCRIPT_DIR/cli/share/nftban/specs" ]]; then
        cp -f "$SCRIPT_DIR/cli/share/nftban/specs/"*.json /usr/share/nftban/specs/ 2>/dev/null || true
        local spec_count
        spec_count=$(ls -1 /usr/share/nftban/specs/*.json 2>/dev/null | wc -l)
        ok "Installed $spec_count spec files"
    fi
    chown -R root:root /usr/share/nftban/specs
    chmod 755 /usr/share/nftban/specs
    find /usr/share/nftban/specs -type f -name "*.json" -exec chmod 644 {} \;

    return 0
}

install_dependencies() {
    log "Installing Required Dependencies..."

    # Source distro config loader
    if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
        export NFTBAN_DISTRO_CONF_DIR="$SCRIPT_DIR/etc/nftban/distros"
        source "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh"
    else
        warn "Distro config system not found, skipping dependency installation"
        return 0
    fi

    # Initialize distro detection
    if ! nftban_distro_init; then
        warn "Failed to detect distribution, skipping dependency installation"
        return 0
    fi

    # Check if package manager is available
    local pkg_type="${DISTRO_PKGMGR[type]}"
    local install_cmd="${DISTRO_PKGMGR[install_cmd]}"
    local update_cmd="${DISTRO_PKGMGR[update_cmd]}"

    if [[ -z "$install_cmd" ]]; then
        warn "No package manager configured, skipping dependency installation"
        return 0
    fi

    log "Detected: ${DISTRO_INFO[name]} ${DISTRO_INFO[version]} (${pkg_type})"
    echo ""

    # Update package cache
    log "Updating package cache..."
    if eval "$update_cmd" >/dev/null 2>&1; then
        ok "Package cache updated"
    else
        warn "Package cache update failed (non-critical)"
    fi

    # Required packages for NFTBan
    local required_packages=(
        nftables
        curl
        suricata
        suricata_update
        jq
    )

    # Optional packages (install if available)
    local optional_packages=(
        wget
        git
        prometheus
        node_exporter
    )

    # Install required packages
    log "Installing required packages..."
    local installed=0
    local failed=0

    for pkg_key in "${required_packages[@]}"; do
        local pkg_name="${DISTRO_PACKAGES[$pkg_key]}"

        if [[ -z "$pkg_name" ]]; then
            warn "Package '$pkg_key' not defined for this distro"
            failed=$((failed + 1))
            continue
        fi

        # Check if already installed
        if command -v "$pkg_key" &>/dev/null || dpkg -l "$pkg_name" 2>/dev/null | grep -q "^ii"; then
            echo "  ✓ $pkg_name (already installed)"
            continue
        fi

        # Install package
        echo "  Installing $pkg_name..."
        if eval "$install_cmd $pkg_name" >/dev/null 2>&1; then
            ok "  ✓ $pkg_name"
            installed=$((installed + 1))
        else
            warn "  ✗ $pkg_name (failed)"
            failed=$((failed + 1))
        fi
    done

    # Install optional packages (fail silently)
    for pkg_key in "${optional_packages[@]}"; do
        local pkg_name="${DISTRO_PACKAGES[$pkg_key]}"
        [[ -z "$pkg_name" ]] && continue

        if command -v "$pkg_key" &>/dev/null; then
            continue
        fi

        eval "$install_cmd $pkg_name" >/dev/null 2>&1 && installed=$((installed + 1)) || true
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        warn "Some packages failed to install ($failed failed)"
        echo "    You may need to install them manually"
    else
        ok "All dependencies installed ($installed new packages)"
    fi

    return 0
}

install_safety_whitelist() {
    log "Auto-Detecting System IPs (Lockout Prevention)..."

    # Source system IP detection module
    if [[ -f "$LIB_DIR/core/nftban_system_ip.sh" ]]; then
        source "$LIB_DIR/core/nftban_system_ip.sh"
    else
        warn "System IP module not found, skipping auto-whitelist"
        return 0
    fi

    # Ensure whitelist directory exists
    mkdir -p /etc/nftban/whitelist.d

    local protected=0

    # 1. Auto-detect SSH client IP (CRITICAL - prevents lockout)
    local ssh_ip="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_ip" ]]; then
        if ! nftban_is_ip_whitelisted "$ssh_ip" 2>/dev/null; then
            nftban_add_system_ip "$ssh_ip" "SSH installer (auto-detected on $(date +'%Y-%m-%d'))" >/dev/null 2>&1 || true
            ok "Auto-whitelisted SSH client: $ssh_ip"
            protected=$((protected + 1))
        fi
    fi

    # 2. Auto-detect server interface IPs
    local interface_ips
    interface_ips=$(nftban_get_interface_ips 2>/dev/null || true)
    if [[ -n "$interface_ips" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            if ! nftban_is_ip_whitelisted "$ip" 2>/dev/null; then
                nftban_add_system_ip "$ip" "Server interface (auto-detected)" >/dev/null 2>&1 || true
                protected=$((protected + 1))
            fi
        done <<< "$interface_ips"
        ok "Auto-whitelisted $protected interface IP(s)"
    fi

    # 3. Auto-detect public IPs (optional, can fail if no internet)
    local public_ipv4
    public_ipv4=$(nftban_get_public_ip "ipv4" 2>/dev/null || true)
    if [[ -n "$public_ipv4" ]]; then
        if ! nftban_is_ip_whitelisted "$public_ipv4" 2>/dev/null; then
            nftban_add_system_ip "$public_ipv4" "Server public IPv4 (auto-detected)" >/dev/null 2>&1 || true
            ok "Auto-whitelisted public IPv4: $public_ipv4"
            protected=$((protected + 1))
        fi
    fi

    # Summary
    if [[ $protected -gt 0 ]]; then
        ok "Safety whitelist created ($protected IP(s) protected)"
        echo ""
        log "Whitelist file: /etc/nftban/whitelist.d/00-system.conf"
    else
        ok "System IPs already whitelisted"
    fi

    return 0
}

install_tmpfiles() {
    log "Installing tmpfiles.d Configuration..."

    # Install tmpfiles.d configuration for runtime directories
    if [[ -f "$SCRIPT_DIR/install/tmpfiles.d/nftban.conf" ]]; then
        mkdir -p /etc/tmpfiles.d
        cp -f "$SCRIPT_DIR/install/tmpfiles.d/nftban.conf" /etc/tmpfiles.d/
        chmod 644 /etc/tmpfiles.d/nftban.conf
        chown root:root /etc/tmpfiles.d/nftban.conf
        ok "Installed: /etc/tmpfiles.d/nftban.conf"

        # Apply tmpfiles configuration immediately
        if command -v systemd-tmpfiles &>/dev/null; then
            systemd-tmpfiles --create /etc/tmpfiles.d/nftban.conf 2>/dev/null || true
            ok "Applied tmpfiles configuration"
        fi
    else
        warn "tmpfiles.d config not found: $SCRIPT_DIR/install/tmpfiles.d/nftban.conf"
    fi

    return 0
}

install_polkit() {
    log "Installing Polkit Policies..."

    # Create polkit directories
    mkdir -p "$POLKIT_ACTIONS_DIR"
    mkdir -p "$POLKIT_RULES_DIR_SHARE"
    mkdir -p "$POLKIT_RULES_DIR_ETC"

    # ==========================================================================
    # IMPORTANT: Polkit rules with paths must be GENERATED from central config
    # Templates use @NFTBAN_BIN@, @NFTBAN_AUTH_BIN@ placeholders
    # These are replaced with values from /etc/nftban/nftban.conf
    # ==========================================================================

    # Load central config for path values
    local NFTBAN_CONF="/etc/nftban/nftban.conf"
    if [[ -f "$NFTBAN_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_CONF"
    else
        # Use source file if not installed yet
        if [[ -f "$SCRIPT_DIR/install/config/nftban.conf" ]]; then
            # shellcheck source=/dev/null
            source "$SCRIPT_DIR/install/config/nftban.conf"
        fi
    fi

    # Ensure required variables are set
    : "${NFTBAN_BIN:=/usr/bin/nftban}"
    : "${NFTBAN_AUTH_BIN:=/usr/libexec/nftban-ui-auth}"

    # Install polkit policies if they exist
    if [[ -f "$SCRIPT_DIR/install/pam/com.nftban.auth.policy" ]]; then
        cp -f "$SCRIPT_DIR/install/pam/com.nftban.auth.policy" "$POLKIT_ACTIONS_DIR/"
        chmod 644 "$POLKIT_ACTIONS_DIR/com.nftban.auth.policy"
        ok "Installed: com.nftban.auth.policy"
    fi

    # Install polkit rules for nftban services (v1.0 simplified - all operators in nftban group)
    if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/60-nftban-services.rules" ]]; then
        cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/60-nftban-services.rules" "$POLKIT_RULES_DIR_SHARE/"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/60-nftban-services.rules"
        ok "Installed: 60-nftban-services.rules"
    else
        warn "Polkit services rules not found: $SCRIPT_DIR/packaging/polkit-1/rules.d/60-nftban-services.rules"
    fi

    # Install polkit rules for Suricata management
    if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/20-nftban-suricata.rules" ]]; then
        cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/20-nftban-suricata.rules" "$POLKIT_RULES_DIR_SHARE/"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/20-nftban-suricata.rules"
        ok "Installed: 20-nftban-suricata.rules"
    fi

    # ==========================================================================
    # GENERATE polkit rules from templates (replace placeholders with config values)
    # ==========================================================================

    # Generate 50-nftban-port-status.rules from template
    if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-port-status.rules.in" ]]; then
        sed "s|@NFTBAN_BIN@|$NFTBAN_BIN|g" \
            "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-port-status.rules.in" \
            > "$POLKIT_RULES_DIR_SHARE/50-nftban-port-status.rules"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/50-nftban-port-status.rules"
        ok "Generated: 50-nftban-port-status.rules (NFTBAN_BIN=$NFTBAN_BIN)"
    elif [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-port-status.rules" ]]; then
        # Fallback to non-template file if template doesn't exist
        cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-port-status.rules" "$POLKIT_RULES_DIR_SHARE/"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/50-nftban-port-status.rules"
        ok "Installed: 50-nftban-port-status.rules (legacy, non-template)"
    fi

    # Generate 50-nftban-auth.rules from template
    if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-auth.rules.in" ]]; then
        sed "s|@NFTBAN_AUTH_BIN@|$NFTBAN_AUTH_BIN|g" \
            "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-auth.rules.in" \
            > "$POLKIT_RULES_DIR_SHARE/50-nftban-auth.rules"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/50-nftban-auth.rules"
        ok "Generated: 50-nftban-auth.rules (NFTBAN_AUTH_BIN=$NFTBAN_AUTH_BIN)"
    elif [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-auth.rules" ]]; then
        # Fallback to non-template file if template doesn't exist
        cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-auth.rules" "$POLKIT_RULES_DIR_SHARE/"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/50-nftban-auth.rules"
        ok "Installed: 50-nftban-auth.rules (legacy, non-template)"
    fi

    # Install polkit rules for nftban-auditors group
    if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-v030.rules" ]]; then
        cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-v030.rules" "$POLKIT_RULES_DIR_SHARE/"
        chmod 644 "$POLKIT_RULES_DIR_SHARE/50-nftban-v030.rules"
        ok "Installed: 50-nftban-v030.rules"
    else
        warn "Polkit auditors rules not found: $SCRIPT_DIR/packaging/polkit-1/rules.d/50-nftban-v030.rules"
    fi

    # Install polkit rules for nftban-core services (systemd management)
    if [[ -f "$SCRIPT_DIR/cmd/nftban-core/polkit/10-nftban-core.rules" ]]; then
        cp -f "$SCRIPT_DIR/cmd/nftban-core/polkit/10-nftban-core.rules" "$POLKIT_RULES_DIR_ETC/"
        chmod 644 "$POLKIT_RULES_DIR_ETC/10-nftban-core.rules"
        ok "Installed: 10-nftban-core.rules"
    else
        warn "Polkit nftban-core rules not found: $SCRIPT_DIR/cmd/nftban-core/polkit/10-nftban-core.rules"
    fi

    # Install Suricata IDS integration polkit policy
    if [[ -f "$SCRIPT_DIR/install/polkit/com.nftban.suricata.policy" ]]; then
        cp -f "$SCRIPT_DIR/install/polkit/com.nftban.suricata.policy" "$POLKIT_ACTIONS_DIR/"
        chmod 644 "$POLKIT_ACTIONS_DIR/com.nftban.suricata.policy"
        ok "Installed: com.nftban.suricata.policy"
    fi

    # Start/restart polkit service
    systemctl restart polkit 2>/dev/null || warn "Failed to restart polkit"
    ok "Polkit configured"

    return 0
}

install_systemd() {
    log "Installing Systemd Units..."

    # Initialize distro config if not already loaded
    if [[ -z "${NFTBAN_DISTRO_CONFIG_LOADED:-}" ]]; then
        if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
            # Try installed location first, fallback to source
            if [[ -d "/etc/nftban/distros" ]]; then
                export NFTBAN_DISTRO_CONF_DIR="/etc/nftban/distros"
            else
                export NFTBAN_DISTRO_CONF_DIR="$SCRIPT_DIR/etc/nftban/distros"
            fi
            source "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh"
            nftban_distro_init 2>/dev/null || true
        fi
    fi

    # Get systemd directory from distro config (with fallback)
    local systemd_dir="${DISTRO_PATHS[systemd_system]:-/etc/systemd/system}"

    log "Systemd directory: $systemd_dir"

    # Metrics exporter
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-metrics-exporter.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-metrics-exporter.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-metrics-exporter.timer" "$systemd_dir/"
        ok "Metrics exporter units → $systemd_dir"
    fi

    # Health check timer
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-health.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health.timer" "$systemd_dir/"
        ok "Health timer units → $systemd_dir"
    fi

    # Health fix service (companion to health check)
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-health-fix.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health-fix.service" "$systemd_dir/"
        ok "Health fix service → $systemd_dir"
    fi

    # GeoIP updater
    if [[ -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-geoip.service" ]]; then
        cp -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-geoip.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-geoip.timer" "$systemd_dir/"
        ok "GeoIP timer units → $systemd_dir"
    fi

    # Feeds updater
    if [[ -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-feeds.service" ]]; then
        cp -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-feeds.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/cmd/nftban-core/systemd/nftban-core-feeds.timer" "$systemd_dir/"
        ok "Feeds timer units → $systemd_dir"
    fi

    # Task queue processor
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-queue.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-queue.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-queue.timer" "$systemd_dir/"
        ok "Queue processor units → $systemd_dir"
    fi

    # Web GUI service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-ui.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui.service" "$systemd_dir/"
        ok "Web GUI service → $systemd_dir"
    fi

    # Web GUI auth socket
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.socket" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.socket" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.service" "$systemd_dir/"
        ok "Web GUI auth units → $systemd_dir"
    fi

    # Suricata IDS integration
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-suricata.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata.service" "$systemd_dir/"
        ok "Suricata daemon service → $systemd_dir"
    fi

    # Suricata rules updater
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.timer" "$systemd_dir/"
        ok "Suricata rules updater units → $systemd_dir"
    fi

    # Reload systemd
    systemctl daemon-reload
    ok "Systemd reloaded"

    # Enable and start timers
    log "Enabling timers..."

    # Health timer (always enabled)
    if [[ -f "$systemd_dir/nftban-health.timer" ]]; then
        systemctl enable --now nftban-health.timer 2>/dev/null || warn "Health timer enable failed"
    fi

    # Metrics timer (only if metrics enabled)
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
        systemctl enable --now nftban-metrics-exporter.timer 2>/dev/null || warn "Metrics timer enable failed"
        ok "Metrics enabled (backend: ${NFTBAN_METRICS_BACKEND:-prometheus})"
    else
        log "Metrics disabled (enable with: nftban config set NFTBAN_METRICS_ENABLED=true)"
    fi

    # GeoIP timer (only if enabled)
    if [[ "${NFTBAN_GEOIP_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-core-geoip.timer" ]]; then
        systemctl enable --now nftban-core-geoip.timer 2>/dev/null || warn "GeoIP timer enable failed"
    fi

    # Feeds timer (only if enabled)
    if [[ "${NFTBAN_FEEDS_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-core-feeds.timer" ]]; then
        systemctl enable --now nftban-core-feeds.timer 2>/dev/null || warn "Feeds timer enable failed"
    fi

    # Queue timer (always enabled if exists)
    if [[ -f "$systemd_dir/nftban-queue.timer" ]]; then
        systemctl enable --now nftban-queue.timer 2>/dev/null || warn "Queue timer enable failed"
    fi

    # Suricata update timer (only if suricata enabled)
    if [[ "${NFTBAN_SURICATA_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-suricata-update.timer" ]]; then
        systemctl enable --now nftban-suricata-update.timer 2>/dev/null || warn "Suricata rules update timer enable failed"
    fi

    ok "Timers enabled and started"

    return 0
}

run_post_install() {
    log "Running Post-Install Configuration..."

    # Check if nftban command exists
    if ! command -v nftban &>/dev/null; then
        warn "nftban command not found, skipping post-install"
        return 0
    fi

    # Fix permissions
    log "Fixing permissions..."
    nftban permissions enforce 2>/dev/null || warn "Permission enforcement failed"

    # Auto-detect SSH port from sshd_config
    log "Auto-detecting SSH port..."
    _install_auto_whitelist_ssh_port

    # Auto-whitelist system IP (prevents lockout)
    log "Auto-whitelisting system IP..."
    _install_auto_whitelist_system_ip

    # Reload systemd daemon to pick up new units
    log "Reloading systemd daemon..."
    systemctl daemon-reload 2>/dev/null || true

    # Enable essential timers
    log "Enabling health and maintenance timers..."
    local timers=(
        "nftban-health.timer"
        "nftban-maintenance.timer"
    )
    for timer in "${timers[@]}"; do
        if systemctl list-unit-files "$timer" &>/dev/null 2>&1; then
            systemctl enable "$timer" 2>/dev/null && \
            systemctl start "$timer" 2>/dev/null && \
            ok "Enabled: $timer"
        fi
    done

    # Reload nftables to apply config
    log "Reloading nftables..."
    systemctl reload nftables 2>/dev/null || warn "nftables reload failed"

    ok "Post-install configuration completed"
    return 0
}

# Auto-detect SSH port from sshd_config and whitelist it
_install_auto_whitelist_ssh_port() {
    local ports_dir="/etc/nftban/ports.d"
    local ssh_conf="${ports_dir}/00-ssh.conf"
    local sshd_config="/etc/ssh/sshd_config"
    local ssh_port="22"

    # Try to detect SSH port from sshd_config
    if [[ -f "$sshd_config" ]]; then
        local detected_port
        detected_port=$(grep -E "^Port\s+" "$sshd_config" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$detected_port" && "$detected_port" =~ ^[0-9]+$ ]]; then
            ssh_port="$detected_port"
        fi
    fi

    mkdir -p "$ports_dir"

    # Create or update SSH port config
    if [[ ! -f "$ssh_conf" ]]; then
        cat > "$ssh_conf" << SSHEOF
# Auto-generated SSH port whitelist
# Created by: NFTBan installer
# Date: $(date -Iseconds)
# Detected from: $sshd_config
[ssh]
port=$ssh_port
protocol=tcp
direction=input
SSHEOF
        chmod 644 "$ssh_conf"
        chown root:nftban "$ssh_conf"
        ok "SSH port whitelisted: $ssh_port/tcp (from sshd_config)"
    else
        ok "SSH port config exists: $ssh_conf"
    fi
}

# Auto-whitelist system's primary IP address (prevents lockout)
_install_auto_whitelist_system_ip() {
    local whitelist_dir="/etc/nftban/whitelist.d"
    local whitelist_file="${whitelist_dir}/00-system-ip.conf"

    # Get primary IP (non-loopback)
    local system_ip
    system_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)

    if [[ -z "$system_ip" ]]; then
        # Fallback: get first non-loopback IP
        system_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -n "$system_ip" ]]; then
        mkdir -p "$whitelist_dir"
        if [[ ! -f "$whitelist_file" ]] || ! grep -q "$system_ip" "$whitelist_file" 2>/dev/null; then
            cat > "$whitelist_file" << IPEOF
# Auto-generated system IP whitelist
# Created by: NFTBan installer
# Date: $(date -Iseconds)
# Purpose: Prevent lockout from this server
$system_ip
IPEOF
            chmod 644 "$whitelist_file"
            chown root:nftban "$whitelist_file" 2>/dev/null || true
            ok "System IP whitelisted: $system_ip"
        else
            ok "System IP already whitelisted: $system_ip"
        fi
    else
        warn "Could not detect system IP for whitelist"
    fi
}

install_gui() {
    log "Installing GUI locally..."

    check_binary "$BIN_DIR/nftban-ui" || return 1

    # Copy binary
    log "Copying binary to $GUI_INSTALL_PATH..."
    cp -f "$BIN_DIR/nftban-ui" "$GUI_INSTALL_PATH"
    chmod +x "$GUI_INSTALL_PATH"
    chown root:root "$GUI_INSTALL_PATH"
    ok "Binary installed: $GUI_INSTALL_PATH"

    # Restart service if running
    if systemctl list-unit-files | grep -q "nftban-ui.service" 2>/dev/null; then
        if systemctl is-active --quiet nftban-ui 2>/dev/null; then
            log "Restarting nftban-ui service..."
            systemctl restart nftban-ui
            ok "Service restarted"

            # Show status
            echo ""
            log "Service status:"
            systemctl status nftban-ui --no-pager -l | head -12
        else
            warn "Service nftban-ui exists but not running"
            echo "    Start with: systemctl start nftban-ui"
        fi
    else
        warn "Service nftban-ui.service not found"
        echo "    Install service file first"
    fi

    return 0
}


show_usage() {
    cat << EOF
NFTBan Installation Script

Usage:
  $0 [--help]

This script installs NFTBan with all components:
  - Go binaries (nftban-core)
  - CLI commands and libraries
  - Polkit rules
  - Systemd timers
  - NFTables configuration
  - GeoIP database (free)

One question: Enable metrics? (prometheus/victoriametrics)

After installation, enable features via CLI:
  nftban login enable      # Login monitoring
  nftban geoip enable      # Country blocking
  nftban feeds enable      # Threat feeds
  nftban gui enable        # Web GUI (separate)
  nftban suricata setup    # IDS integration (separate)

Prerequisites:
  - Root privileges (run with sudo)
  - Go binaries built (./build.sh) or downloaded (./install/download-binaries.sh)

EOF
}

# =============================================================================
# MAIN INSTALLATION LOGIC
# =============================================================================

# Handle --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
    show_usage
    exit 0
fi

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

check_root
check_nftables
check_conflicting_firewalls
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

install_safety_whitelist || warn "Auto-whitelist failed (non-critical)"
echo ""

install_nftables || exit 1
echo ""

install_tmpfiles || warn "tmpfiles.d installation failed (non-critical)"
echo ""

install_polkit || exit 1
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

    # Update config file
    if [[ -f /etc/nftban/nftban.conf ]]; then
        sed -i "s/^NFTBAN_METRICS_ENABLED=.*/NFTBAN_METRICS_ENABLED=\"true\"/" /etc/nftban/nftban.conf
        sed -i "s/^NFTBAN_METRICS_BACKEND=.*/NFTBAN_METRICS_BACKEND=\"${NFTBAN_METRICS_BACKEND}\"/" /etc/nftban/nftban.conf
        ok "Metrics configuration updated"
    fi

    # Enable metrics timer
    if [[ -f /etc/systemd/system/nftban-metrics-exporter.timer ]]; then
        systemctl enable --now nftban-metrics-exporter.timer 2>/dev/null || true
        ok "Metrics exporter timer enabled"
    fi
    echo ""
fi

# =============================================================================
# STEP 6: Auto-enable default features (login, geoip)
# =============================================================================
log "Enabling default features..."

# Enable login monitoring (SSH alerts)
if [[ -f /etc/nftban/nftban.conf ]]; then
    sed -i "s/^NFTBAN_LOGIN_ALERT_ENABLED=.*/NFTBAN_LOGIN_ALERT_ENABLED=\"true\"/" /etc/nftban/nftban.conf 2>/dev/null || true
    sed -i "s/^NFTBAN_LOGIN_ALERT_SSH=.*/NFTBAN_LOGIN_ALERT_SSH=\"true\"/" /etc/nftban/nftban.conf 2>/dev/null || true
fi
if [[ -f /etc/systemd/system/nftban-login-monitor.service ]]; then
    systemctl enable nftban-login-monitor.service 2>/dev/null || true
    systemctl start nftban-login-monitor.service 2>/dev/null || true
    ok "Login monitoring: ENABLED"
else
    # Install and enable via CLI if available
    if command -v nftban &>/dev/null; then
        nftban login enable 2>/dev/null && ok "Login monitoring: ENABLED" || warn "Login monitoring: manual enable needed"
    fi
fi

# Enable GeoIP blocking
if [[ -f /etc/nftban/nftban.conf ]]; then
    sed -i "s/^NFTBAN_GEOIP_ENABLED=.*/NFTBAN_GEOIP_ENABLED=\"true\"/" /etc/nftban/nftban.conf 2>/dev/null || true
    ok "GeoIP blocking: ENABLED"
fi

# Enable core timers (health, maintenance) - watchdog only with metrics
log "Enabling core timers..."
for timer in nftban-health.timer nftban-maintenance.timer; do
    if [[ -f "/etc/systemd/system/$timer" ]]; then
        systemctl enable --now "$timer" 2>/dev/null || true
    fi
done
ok "Core timers: ENABLED (health, maintenance)"

# Enable watchdog only if metrics enabled (exports Prometheus metrics)
if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
    if [[ -f "/etc/systemd/system/nftban-watchdog.timer" ]]; then
        systemctl enable --now nftban-watchdog.timer 2>/dev/null || true
        # Update config
        if [[ -f /etc/nftban/conf.d/watchdog.conf ]]; then
            sed -i 's/^NFTBAN_WATCHDOG_ENABLED=.*/NFTBAN_WATCHDOG_ENABLED="true"/' /etc/nftban/conf.d/watchdog.conf 2>/dev/null || true
        fi
        ok "Watchdog: ENABLED (with metrics)"
    fi
else
    info "Watchdog: disabled (enable with: nftban watchdog enable)"
fi

echo ""

# =============================================================================
# STEP 7: Post-install and verification
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
echo "  ✅ NFTBan Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Auto-enabled:"
echo "  ✓ Login monitoring (SSH alerts)"
echo "  ✓ GeoIP blocking"
echo "  ✓ Core timers (health, maintenance)"
if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
    echo "  ✓ Metrics (${NFTBAN_METRICS_BACKEND})"
    echo "  ✓ Watchdog (system monitoring)"
fi
echo ""
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
echo ""
