#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Installation Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Install NFTBan on the local system
#
# meta:name="nftban_install"
# meta:type="cli"
# meta:header="NFTBan Installer"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Main installation script for NFTBan firewall management system"
# meta:input="Interactive prompts for configuration options"
# meta:output="Installed NFTBan system with binaries, configs, and systemd units"
# meta:depends="bash,curl,systemctl,useradd,chmod,chown,mkdir,cp,ln"
# meta:created_date="2025-10-26"
#
# meta:inventory.files=""
# meta:inventory.binaries="curl,systemctl,useradd,groupadd,chmod,chown,mkdir,cp,ln,tput,id"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban.service,nftban-watchdog.timer,nftban-metrics-exporter.timer,nftban-queue.timer"
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
#
# One question: Enable metrics? (prometheus/victoriametrics)
#
# Later (via CLI):
#   - nftban gui enable
#   - nftban suricata setup
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

# Check and install yq (REQUIRED for documentation generation)
check_yq() {
    log "Checking yq (YAML processor)..."

    if command -v yq &>/dev/null; then
        ok "yq found: $(yq --version 2>/dev/null | head -1 || echo 'version unknown')"
        return 0
    fi

    warn "yq not found - installing..."

    # Detect package manager and install
    # yq is available in different forms:
    # - pip install yq (Python wrapper around jq)
    # - System packages (newer distros)
    # - Standalone binary (mikefarah/yq)

    if command -v pip3 &>/dev/null; then
        log "Installing yq via pip3..."
        pip3 install yq || {
            warn "Failed to install yq via pip3, trying pip..."
            if command -v pip &>/dev/null; then
                pip install yq || { error "Failed to install yq via pip"; exit 1; }
            else
                error "pip not found. Please install python3-pip first."
                exit 1
            fi
        }
    elif command -v dnf &>/dev/null; then
        # Fedora/RHEL 9+ has yq in EPEL
        dnf install -y python3-pip && pip3 install yq || { error "Failed to install yq"; exit 1; }
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS - install pip first
        yum install -y python3-pip && pip3 install yq || { error "Failed to install yq"; exit 1; }
    elif command -v apt-get &>/dev/null; then
        # Debian/Ubuntu - install pip first
        apt-get update && apt-get install -y python3-pip && pip3 install yq || { error "Failed to install yq"; exit 1; }
    else
        error "Cannot install yq automatically. Please install manually:"
        error "  pip3 install yq"
        error "  OR download from: https://github.com/mikefarah/yq/releases"
        exit 1
    fi

    ok "yq installed successfully"
}

# Check and install PAM (REQUIRED for nftban-ui-auth)
check_pam() {
    log "Checking PAM (Pluggable Authentication Modules)..."

    # Check for PAM library (not just headers)
    if ldconfig -p 2>/dev/null | grep -q libpam.so || [[ -f /lib64/libpam.so.0 ]] || [[ -f /lib/x86_64-linux-gnu/libpam.so.0 ]]; then
        ok "PAM library found"
        return 0
    fi

    warn "PAM library not found - installing..."

    # Detect package manager and install
    if command -v dnf &>/dev/null; then
        dnf install -y pam || { error "Failed to install PAM"; exit 1; }
    elif command -v yum &>/dev/null; then
        yum install -y pam || { error "Failed to install PAM"; exit 1; }
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y libpam0g || { error "Failed to install PAM"; exit 1; }
    elif command -v zypper &>/dev/null; then
        zypper install -y pam || { error "Failed to install PAM"; exit 1; }
    else
        error "Unknown package manager. Please install PAM manually."
        exit 1
    fi

    ok "PAM installed successfully"
}

# Comprehensive prerequisite checks
check_prerequisites() {
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "  NFTBan v1.0.0 - Installation Prerequisite Checks"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""

    local PREREQ_FAILED=0

    # -------------------------------------------------------------------------
    # CHECK 1: Operating System Version
    # -------------------------------------------------------------------------
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        ok "Operating System: $PRETTY_NAME"

        # Check for supported OS families
        case "$ID" in
            rhel|rocky|almalinux|centos|fedora)
                ok "Supported OS family: RHEL/Rocky/AlmaLinux/CentOS/Fedora"
                ;;
            ubuntu|debian|linuxmint)
                ok "Supported OS family: Debian/Ubuntu"
                ;;
            *)
                warn "Untested OS: $ID (may work, but not officially supported)"
                ;;
        esac
    else
        error "Cannot detect OS version (/etc/os-release missing)"
        PREREQ_FAILED=1
    fi

    # -------------------------------------------------------------------------
    # CHECK 2: Required Commands
    # -------------------------------------------------------------------------
    echo ""
    log "Checking required commands..."

    for cmd in nft systemctl ip iptables curl jq yq; do
        if command -v $cmd &>/dev/null; then
            ok "Found: $cmd"
        else
            error "MISSING: $cmd"
            PREREQ_FAILED=1
        fi
    done

    # -------------------------------------------------------------------------
    # CHECK 3: Kernel nftables Support
    # -------------------------------------------------------------------------
    echo ""
    log "Checking kernel nftables support..."

    if [[ -d /proc/sys/net/netfilter ]]; then
        ok "Netfilter subsystem available"
    else
        error "Netfilter not available in kernel"
        PREREQ_FAILED=1
    fi

    # Check if nft can list rulesets
    if nft list ruleset &>/dev/null; then
        ok "nftables kernel modules loaded"
    else
        warn "nftables modules not loaded (will auto-load on first use)"
    fi

    # -------------------------------------------------------------------------
    # CHECK 4: Network Connectivity (for GeoIP download)
    # -------------------------------------------------------------------------
    echo ""
    log "Checking network connectivity..."

    if curl -sI --connect-timeout 5 https://github.com &>/dev/null; then
        ok "Internet connectivity: OK (github.com reachable)"
    else
        warn "Cannot reach github.com - GeoIP download may fail"
        info "You can manually download later: nftban-core geoip update"
    fi

    # -------------------------------------------------------------------------
    # FINAL RESULT
    # -------------------------------------------------------------------------
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════"

    if [[ $PREREQ_FAILED -eq 1 ]]; then
        echo ""
        error "PREREQUISITE CHECK FAILED"
        echo ""
        echo "Critical requirements are missing. Please fix the errors above and try again."
        echo ""
        echo "Installation commands by OS:"
        echo "  RHEL/Rocky/Alma: dnf install -y nftables curl jq"
        echo "  Ubuntu/Debian:   apt install -y nftables curl jq"
        echo "  Fedora:          dnf install -y nftables curl jq"
        echo ""
        echo "════════════════════════════════════════════════════════════════════════════════"
        echo ""
        exit 1
    fi

    ok "All critical prerequisites satisfied"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# Check for conflicting firewalls (CRITICAL - prevents conflicts)
backup_firewall_rules() {
    # Create backup directory
    local backup_dir="/var/backups/nftban/firewall-migration"
    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_path="${backup_dir}/${timestamp}"

    mkdir -p "$backup_path" 2>/dev/null || {
        warn "Could not create backup directory at $backup_path"
        return 1
    }

    log "Backing up existing firewall rules to: $backup_path"

    # Backup iptables rules
    if command -v iptables-save &>/dev/null; then
        if iptables-save > "${backup_path}/iptables-rules.v4" 2>/dev/null; then
            ok "Backed up IPv4 iptables rules"
        fi
    fi

    if command -v ip6tables-save &>/dev/null; then
        if ip6tables-save > "${backup_path}/iptables-rules.v6" 2>/dev/null; then
            ok "Backed up IPv6 iptables rules"
        fi
    fi

    # Backup UFW rules
    if command -v ufw &>/dev/null && [[ -d /etc/ufw ]]; then
        if tar czf "${backup_path}/ufw-config.tar.gz" /etc/ufw 2>/dev/null; then
            ok "Backed up UFW configuration"
        fi

        # Export UFW status
        ufw status verbose > "${backup_path}/ufw-status.txt" 2>/dev/null || true
    fi

    # Backup firewalld configuration
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --list-all-zones > "${backup_path}/firewalld-zones.txt" 2>/dev/null || true
        firewall-cmd --list-all > "${backup_path}/firewalld-default-zone.txt" 2>/dev/null || true

        if [[ -d /etc/firewalld ]]; then
            tar czf "${backup_path}/firewalld-config.tar.gz" /etc/firewalld 2>/dev/null && \
                ok "Backed up firewalld configuration"
        fi
    fi

    # Create README
    cat > "${backup_path}/README.txt" <<EOF
NFTBan Firewall Migration Backup
=================================
Date: $(date)
Host: $(hostname)

This directory contains backups of your previous firewall configuration
that was disabled during NFTBan installation.

⚠️ IMPORTANT: NFTBan does NOT automatically migrate rules!

Files in this backup:
- iptables-rules.v4      : IPv4 iptables rules
- iptables-rules.v6      : IPv6 iptables rules
- ufw-config.tar.gz      : UFW configuration
- ufw-status.txt         : UFW status output
- firewalld-config.tar.gz: firewalld configuration
- firewalld-zones.txt    : firewalld zones configuration

To manually review your old rules:
  # For iptables:
  less ${backup_path}/iptables-rules.v4

  # For UFW:
  cat ${backup_path}/ufw-status.txt

  # For firewalld:
  cat ${backup_path}/firewalld-zones.txt

To recreate rules in NFTBan, see:
  https://github.com/itcmsgr/nftban/wiki/Migrating-from-iptables-UFW-firewalld

For help: https://github.com/itcmsgr/nftban/issues
EOF

    chmod 600 "${backup_path}"/* 2>/dev/null || true

    info "Backup completed: $backup_path"
    echo ""
    return 0
}

analyze_firewall_rules() {
    # Analyze and display summary of current firewall rules
    local has_rules=0

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "CURRENT FIREWALL RULES SUMMARY:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Analyze iptables
    if command -v iptables &>/dev/null; then
        local ipt_count
        local ipt6_count
        ipt_count=$(iptables -S 2>/dev/null | grep -v "^-P" | wc -l)
        ipt6_count=$(ip6tables -S 2>/dev/null | grep -v "^-P" | wc -l)

        if [[ $ipt_count -gt 0 ]] || [[ $ipt6_count -gt 0 ]]; then
            echo "iptables:"
            echo "  • IPv4 rules: $ipt_count"
            echo "  • IPv6 rules: $ipt6_count"
            has_rules=1
        fi
    fi

    # Analyze UFW
    if command -v ufw &>/dev/null; then
        local ufw_count
        ufw_count=$(ufw status numbered 2>/dev/null | grep -c "^\[" || echo "0")
        if [[ $ufw_count -gt 0 ]]; then
            echo "UFW:"
            echo "  • Active rules: $ufw_count"
            ufw status numbered 2>/dev/null | head -10
            if [[ $ufw_count -gt 10 ]]; then
                echo "  ... and $((ufw_count - 10)) more rules"
            fi
            has_rules=1
        fi
    fi

    # Analyze firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        local zone_count
        zone_count=$(firewall-cmd --get-active-zones 2>/dev/null | grep -c "^[a-z]" || echo "0")
        if [[ $zone_count -gt 0 ]]; then
            echo "firewalld:"
            echo "  • Active zones: $zone_count"
            firewall-cmd --list-all 2>/dev/null | head -15
            has_rules=1
        fi
    fi

    echo ""

    if [[ $has_rules -eq 0 ]]; then
        info "No active firewall rules detected"
    else
        warn "⚠️  These rules will be DISABLED when you proceed!"
        echo ""
        echo "NFTBan will:"
        echo "  ✓ Backup your rules to /var/backups/nftban/firewall-migration/"
        echo "  ✓ Stop and disable the conflicting firewall service(s)"
        echo "  ✗ NOT automatically convert or migrate your rules"
        echo ""
        echo "After installation, you will need to:"
        echo "  1. Review your backed-up rules"
        echo "  2. Manually recreate needed rules using NFTBan commands"
        echo "  3. See: https://github.com/itcmsgr/nftban/wiki/Migration-Guide"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

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

    # Show current firewall rules summary
    analyze_firewall_rules

    # Ask user if they want automatic fix
    read -p "Would you like NFTBan to automatically stop and disable these firewalls? [y/N]: " auto_fix

    if [[ "${auto_fix,,}" == "y" || "${auto_fix,,}" == "yes" ]]; then
        echo ""

        # Backup existing rules before disabling
        backup_firewall_rules || warn "Backup failed, but continuing..."

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

# Check and fix xtables compatibility expressions in nftables.conf
# These are created by cPanel and other systems that translate iptables rules
# Native nftables cannot load xtables compat expressions
check_xtables_compat() {
    log "Checking for xtables compatibility expressions..."

    # Possible nftables config file locations
    local nft_configs=(
        "/etc/sysconfig/nftables.conf"   # RHEL/CentOS/AlmaLinux
        "/etc/nftables.conf"              # Debian/Ubuntu
    )

    local found_compat=0
    local fixed_files=()

    for config_file in "${nft_configs[@]}"; do
        if [[ -f "$config_file" ]]; then
            # Check for xtables compat expressions
            if grep -qE 'xt (target|match)' "$config_file" 2>/dev/null; then
                found_compat=1
                warn "Found xtables compat expressions in: $config_file"

                # Show what we found
                echo ""
                echo "  Incompatible rules detected:"
                grep -n 'xt target\|xt match' "$config_file" 2>/dev/null | head -5 | while read -r line; do
                    echo "    $line"
                done
                echo ""

                # Create backup
                local backup_dir="/var/backups/nftban/firewall-migration"
                local timestamp
                timestamp=$(date +"%Y%m%d-%H%M%S")
                local backup_path="${backup_dir}/${timestamp}"
                mkdir -p "$backup_path" 2>/dev/null || true

                if cp "$config_file" "${backup_path}/$(basename "$config_file").backup" 2>/dev/null; then
                    ok "Backed up to: ${backup_path}/$(basename "$config_file").backup"
                fi

                # Create cleaned version (remove xt target/match lines)
                local temp_file
                temp_file=$(mktemp)
                grep -v 'xt target\|xt match' "$config_file" > "$temp_file" 2>/dev/null || true

                # Replace original with cleaned version
                if mv "$temp_file" "$config_file" 2>/dev/null; then
                    ok "Removed xtables compat expressions from: $config_file"
                    fixed_files+=("$config_file")
                else
                    warn "Could not modify $config_file (check permissions)"
                    rm -f "$temp_file" 2>/dev/null || true
                fi
            fi
        fi
    done

    if [[ $found_compat -eq 1 ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        info "xtables Compatibility Fix Applied"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "NFTBan detected xtables compat expressions (commonly created by cPanel"
        echo "mail routing or iptables-translate). These are incompatible with native"
        echo "nftables and have been removed."
        echo ""
        echo "What this means:"
        echo "  • nftables.service will now start correctly"
        echo "  • cPanel mail routing continues via iptables-nft (parallel system)"
        echo "  • Original files backed up to: /var/backups/nftban/firewall-migration/"
        echo ""
        echo "If you experience issues, see:"
        echo "  nftban uninstall --restore-firewall"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    else
        ok "No xtables compat expressions found (clean nftables config)"
    fi

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

# Download FREE GeoIP database (DB-IP Lite or MaxMind GeoLite2)
download_geoip_database() {
    log "Downloading FREE GeoIP database..."

    local geoip_dir="/var/lib/nftban/geoip"

    mkdir -p "$geoip_dir"
    chown nftban:nftban "$geoip_dir" 2>/dev/null || true
    chmod 750 "$geoip_dir"

    # Check if recent database exists (less than 30 days old)
    # Check for any supported database
    local existing_db=""
    for check_db in "${geoip_dir}/dbip-country-lite.mmdb" "${geoip_dir}/GeoLite2-City.mmdb" "${geoip_dir}/GeoLite2-Country.mmdb"; do
        if [[ -f "$check_db" ]]; then
            existing_db="$check_db"
            break
        fi
    done

    if [[ -n "$existing_db" ]]; then
        local file_age
        local now_ts
        local file_ts
        now_ts=$(date +%s)
        file_ts=$(stat -c %Y "$existing_db" 2>/dev/null || echo 0)
        file_age=$(( (now_ts - file_ts) / 86400 ))
        if [[ $file_age -lt 30 ]]; then
            ok "GeoIP database exists (${file_age} days old)"
            return 0
        fi
    fi

    # Use nftban-core to download (same as RPM/DEB packages)
    if [[ -x "/usr/lib/nftban/bin/nftban-core" ]]; then
        log "Using nftban-core to download GeoIP database..."
        if /usr/lib/nftban/bin/nftban-core geoip update 2>/dev/null; then
            ok "GeoIP database downloaded successfully"
        else
            warn "Could not download GeoIP database (will retry via timer)"
            info "Manual download: nftban geoip update"
        fi
    else
        warn "nftban-core not found, skipping GeoIP download"
        info "Will download on first use via: nftban geoip update"
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

    # Install nftband (single-writer daemon for nftables operations)
    # This is CRITICAL for the single-writer architecture - all nft writes go through IPC
    if [[ -f "$BIN_DIR/nftband" ]]; then
        log "Installing nftband (single nftables writer daemon)..."
        cp -f "$BIN_DIR/nftband" "$CORE_BIN_DIR/nftband"
        chmod 755 "$CORE_BIN_DIR/nftband"
        chown root:root "$CORE_BIN_DIR/nftband"
        ok "Installed: $CORE_BIN_DIR/nftband"

        # Set capabilities for nftband (CAP_NET_ADMIN only - minimal privilege)
        if command -v setcap &>/dev/null; then
            setcap 'cap_net_admin+ep' "$CORE_BIN_DIR/nftband" 2>/dev/null && \
                ok "CAP_NET_ADMIN set on nftband" || \
                warn "Could not set CAP_NET_ADMIN on nftband"
        fi
    else
        warn "nftband binary not found in $BIN_DIR/"
        warn "IPC-based nftables operations will not work without nftband"
        warn "To build: go build -o bin/nftband ./cmd/nftband"
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

    # Install helper scripts to /usr/lib/nftban/sbin/
    local sbin_dir="$LIB_DIR/sbin"
    mkdir -p "$sbin_dir"

    for script in nftban-apply nftban-confirm nftban-panelctl nftban-queue-processor \
                  nftban-rollback nftban-service-alert; do
        if [[ -f "$SCRIPT_DIR/cli/sbin/$script" ]]; then
            cp -f "$SCRIPT_DIR/cli/sbin/$script" "$sbin_dir/"
            chmod 755 "$sbin_dir/$script"
            chown root:nftban "$sbin_dir/$script"
        fi
    done
    ok "Installed helper scripts → $sbin_dir"

    return 0
}

install_libraries() {
    log "Installing Shell Libraries..."

    # Create directories
    mkdir -p "$LIB_DIR"/{lib,cli,core,exporters,cron,helpers,setup,tests}

    # Safety: Remove duplicate nested nftban directories (legacy cleanup)
    # Guard against empty LIB_DIR variable (defense in depth)
    if [[ -n "$LIB_DIR" ]] && [[ -d "$LIB_DIR/lib/nftban" ]]; then
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

    # Copy systemd helper scripts (security-critical, immutable)
    # These scripts are called directly by systemd to prevent command injection
    if [[ -f "$SCRIPT_DIR/install/helpers/firewall-init-with-delay.sh" ]]; then
        install -m 0755 -o root -g root \
            "$SCRIPT_DIR/install/helpers/firewall-init-with-delay.sh" \
            "$LIB_DIR/helpers/firewall-init-with-delay.sh"
    fi

    # Copy test scripts
    cp -r "$SCRIPT_DIR/cli/lib/nftban/tests/"* "$LIB_DIR/tests/" 2>/dev/null || true

    # Copy root-level library files (help, json_output, etc.)
    cp "$SCRIPT_DIR/cli/lib/nftban/nftban_help.sh" "$LIB_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/cli/lib/nftban/json_output.sh" "$LIB_DIR/" 2>/dev/null || true

    # Set permissions - ALL shell scripts need to be executable for sourcing
    # The CLI sources these via 'source' or '.' which requires read+execute
    find "$LIB_DIR" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$LIB_DIR" -type f -name "*.conf" -exec chmod 644 {} \;
    find "$LIB_DIR" -type d -exec chmod 755 {} \;

    # Set ownership on lib directory and contents (explicit, not recursive on parent)
    chown root:nftban "$LIB_DIR"
    find "$LIB_DIR" -type d -exec chown root:nftban {} \;
    find "$LIB_DIR" -type f -exec chown root:nftban {} \;

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

cleanup_obsolete_files() {
    log "Cleaning up obsolete files from previous versions..."

    # Remove obsolete Polkit rules (v1.0.18 and earlier)
    rm -f /etc/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null && ok "Removed: 10-nftban-core.rules"
    rm -f /etc/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null && ok "Removed: 20-nftban-suricata.rules"
    rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null && ok "Removed: 50-nftban-auth.rules"
    rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules.in 2>/dev/null && ok "Removed: 50-nftban-auth.rules.in"
    rm -f /etc/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null && ok "Removed: 50-nftban-v030.rules"
    rm -f /etc/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null && ok "Removed: 60-nftban-services.rules (UNSAFE wildcard)"
    rm -f /usr/share/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null

    # Remove obsolete Polkit actions
    rm -f /usr/share/polkit-1/actions/com.nftban.suricata.policy 2>/dev/null && ok "Removed: com.nftban.suricata.policy"

    # Remove obsolete port-status rules (v1.0.15 and earlier - security risk)
    rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null && ok "Removed: 50-nftban-port-status.rules (security risk)"
    rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules.in 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null

    ok "Obsolete file cleanup complete"

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

    # Create nftban-auditor group (Read-only auditors)
    # NFTBan v1.0.19 uses 3-group model:
    #   nftban: All operators (CLI, Web, full service management)
    #   nftban-auditor: Read-only audit access (renamed from nftban-auditors)
    #   nftban-panel: Panel integration (limited reload access)
    if ! getent group nftban-auditor >/dev/null 2>&1; then
        groupadd --system nftban-auditor
        ok "Created group: nftban-auditor"
    else
        ok "Group already exists: nftban-auditor"
    fi

    # Create nftban-panel group (Panel integration)
    if ! getent group nftban-panel >/dev/null 2>&1; then
        groupadd --system nftban-panel
        ok "Created group: nftban-panel"
    else
        ok "Group already exists: nftban-panel"
    fi

    # Backward compatibility: Migrate nftban-auditors → nftban-auditor (v1.0.19)
    if getent group nftban-auditors >/dev/null 2>&1; then
        log "Migrating nftban-auditors → nftban-auditor group..."
        # Copy members from old group to new group
        for user in $(getent group nftban-auditors | cut -d: -f4 | tr ',' ' '); do
            if [ -n "$user" ]; then
                usermod -aG nftban-auditor "$user" 2>/dev/null || warn "Could not migrate user: $user"
                ok "Migrated user to nftban-auditor: $user"
            fi
        done
    fi

    # Add root to nftban group (for CLI access)
    if ! id -nG root | grep -qw nftban 2>/dev/null; then
        usermod -aG nftban root 2>/dev/null || warn "Could not add root to nftban"
        ok "Added root to nftban group"
    fi

    echo ""
    log "Groups Summary (v1.0.19: 3-group RBAC model):"
    echo "  • nftban         - Operators (CLI, Web GUI, full service management)"
    echo "  • nftban-auditor - Auditors (read-only: logs, reports, status queries)"
    echo "  • nftban-panel   - Panel integration (limited reload, read-only data)"
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
    mkdir -p /etc/nftban/{whitelist.d,blacklist.d,ports.d,conf.d,distros,suricata,rules.d,patterns.d}
    mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan}
    mkdir -p /etc/nftban/patterns.d/botscan
    mkdir -p /etc/nftban/suricata/{profiles,config,rules,cache}
    mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,panels,metrics,stats}
    mkdir -p /var/lib/nftban/reports/auditors
    mkdir -p /var/lib/nftban/stats/{history,profiles}
    mkdir -p /var/lib/nftban/queue/{pending,work,dlq}
    mkdir -p /var/lib/nftban/mailspool
    mkdir -p /var/lib/nftban/pro
    mkdir -p /var/log/nftban
    mkdir -p /var/cache/nftban
    mkdir -p /run/nftban
    mkdir -p /run/nftban-ui

    # Set ownership (nftban user/group must exist first)
    # IMPORTANT: Use explicit per-directory chown, NOT recursive -R on /etc
    # to avoid overwriting user-edited file permissions
    chown root:nftban /etc/nftban
    chmod 750 /etc/nftban
    chown root:nftban /etc/nftban/conf.d
    chmod 750 /etc/nftban/conf.d
    chown root:root /etc/nftban/distros
    chmod 755 /etc/nftban/distros
    # Set ownership on config subdirs (not recursive into files)
    for subdir in whitelist.d blacklist.d ports.d rules.d suricata patterns.d; do
        [ -d "/etc/nftban/$subdir" ] && chown root:nftban "/etc/nftban/$subdir" && chmod 750 "/etc/nftban/$subdir"
    done
    # Set ownership on conf.d subdirectories (botscan, ddos, portscan, login, panels, rbl)
    for subdir in botscan ddos portscan login panels rbl; do
        [ -d "/etc/nftban/conf.d/$subdir" ] && chown root:nftban "/etc/nftban/conf.d/$subdir" && chmod 750 "/etc/nftban/conf.d/$subdir"
    done
    # Set ownership on patterns.d subdirectories
    [ -d "/etc/nftban/patterns.d/botscan" ] && chown root:nftban "/etc/nftban/patterns.d/botscan" && chmod 750 "/etc/nftban/patterns.d/botscan"

    # /var/lib/nftban: Set directory ownership only, files created at runtime
    chown nftban:nftban /var/lib/nftban
    chmod 750 /var/lib/nftban
    chown nftban:nftban /var/lib/nftban/reports
    chmod 750 /var/lib/nftban/reports
    chmod 770 /var/lib/nftban/reports/auditors
    chown root:nftban-auditor /var/lib/nftban/reports/auditors
    # Set ownership on state subdirs (not recursive into files)
    for subdir in banned whitelist feeds geoip config state panels metrics stats queue mailspool pro; do
        [ -d "/var/lib/nftban/$subdir" ] && chown nftban:nftban "/var/lib/nftban/$subdir" && chmod 750 "/var/lib/nftban/$subdir"
    done

    chown nftban:nftban /var/log/nftban
    chmod 750 /var/log/nftban

    chown nftban:nftban /var/cache/nftban
    chmod 755 /var/cache/nftban

    chown nftban:nftban /run/nftban
    chmod 755 /run/nftban

    # UI auth service runtime directory (root:nftban for PAM auth daemon)
    chown root:nftban /run/nftban-ui
    chmod 750 /run/nftban-ui

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

    # Install Suricata profile templates
    if [[ -d "$SCRIPT_DIR/etc/nftban/suricata/profiles" ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/suricata/profiles/"*.yaml /etc/nftban/suricata/profiles/
        chmod 644 /etc/nftban/suricata/profiles/*.yaml
        chown root:nftban /etc/nftban/suricata/profiles/*.yaml
        local count
        count=$(ls -1 /etc/nftban/suricata/profiles/*.yaml 2>/dev/null | wc -l)
        ok "Installed $count Suricata profile templates"
    fi

    # Removed: fail2ban config installation (v1.0 migration to Suricata)

    # Install feeds config if exists
    if [[ -f "$SCRIPT_DIR/install/config/feeds.conf" ]]; then
        cp -f "$SCRIPT_DIR/install/config/feeds.conf" /etc/nftban/conf.d/feeds.conf
        chmod 644 /etc/nftban/conf.d/feeds.conf
        chown root:nftban /etc/nftban/conf.d/feeds.conf
        ok "Installed: /etc/nftban/conf.d/feeds.conf (15 feeds)"
    fi

    # Install watchdog config if exists
    if [[ -f "$SCRIPT_DIR/install/config/conf.d/watchdog.conf" ]]; then
        cp -f "$SCRIPT_DIR/install/config/conf.d/watchdog.conf" /etc/nftban/conf.d/watchdog.conf
        chmod 644 /etc/nftban/conf.d/watchdog.conf
        chown root:nftban /etc/nftban/conf.d/watchdog.conf
        ok "Installed: /etc/nftban/conf.d/watchdog.conf"
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

    # Install stats configuration (if not exists - don't overwrite user config)
    if [[ -f "$SCRIPT_DIR/etc/nftban/conf.d/stats.conf" ]] && [[ ! -f /etc/nftban/conf.d/stats.conf ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/conf.d/stats.conf" /etc/nftban/conf.d/stats.conf
        chmod 644 /etc/nftban/conf.d/stats.conf
        chown root:nftban /etc/nftban/conf.d/stats.conf
        ok "Installed: /etc/nftban/conf.d/stats.conf"
    elif [[ -f /etc/nftban/conf.d/stats.conf ]]; then
        ok "Stats config exists (not overwriting): /etc/nftban/conf.d/stats.conf"
    fi

    # Install banner configuration (if not exists - don't overwrite user config)
    if [[ -f "$SCRIPT_DIR/etc/nftban/conf.d/banner.conf" ]] && [[ ! -f /etc/nftban/conf.d/banner.conf ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/conf.d/banner.conf" /etc/nftban/conf.d/banner.conf
        chmod 644 /etc/nftban/conf.d/banner.conf
        chown root:nftban /etc/nftban/conf.d/banner.conf
        ok "Installed: /etc/nftban/conf.d/banner.conf"
    elif [[ -f /etc/nftban/conf.d/banner.conf ]]; then
        ok "Banner config exists (not overwriting): /etc/nftban/conf.d/banner.conf"
    fi

    # Install botscan configuration (if not exists - don't overwrite user config)
    if [[ -f "$SCRIPT_DIR/etc/nftban/conf.d/botscan/main.conf" ]] && [[ ! -f /etc/nftban/conf.d/botscan/main.conf ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/conf.d/botscan/main.conf" /etc/nftban/conf.d/botscan/main.conf
        chmod 640 /etc/nftban/conf.d/botscan/main.conf
        chown root:nftban /etc/nftban/conf.d/botscan/main.conf
        ok "Installed: /etc/nftban/conf.d/botscan/main.conf"
    elif [[ -f /etc/nftban/conf.d/botscan/main.conf ]]; then
        ok "Botscan config exists (not overwriting): /etc/nftban/conf.d/botscan/main.conf"
    fi

    # Install botscan pattern files (if not exists - don't overwrite user patterns)
    if [[ -d "$SCRIPT_DIR/etc/nftban/patterns.d/botscan" ]]; then
        for pattern_file in "$SCRIPT_DIR/etc/nftban/patterns.d/botscan"/*.patterns; do
            if [[ -f "$pattern_file" ]]; then
                pattern_name=$(basename "$pattern_file")
                if [[ ! -f "/etc/nftban/patterns.d/botscan/$pattern_name" ]]; then
                    cp -f "$pattern_file" "/etc/nftban/patterns.d/botscan/$pattern_name"
                    chmod 640 "/etc/nftban/patterns.d/botscan/$pattern_name"
                    chown root:nftban "/etc/nftban/patterns.d/botscan/$pattern_name"
                fi
            fi
        done
        local pattern_count
        pattern_count=$(ls -1 /etc/nftban/patterns.d/botscan/*.patterns 2>/dev/null | wc -l)
        ok "Installed $pattern_count botscan pattern files"
    fi

    # Install module config directories (login, ddos, portscan, rbl)
    # These contain mode-specific configurations (classic.conf, suricata.conf, etc.)
    for module in login ddos portscan rbl; do
        local src_dir="$SCRIPT_DIR/etc/nftban/conf.d/$module"
        local dst_dir="/etc/nftban/conf.d/$module"
        if [[ -d "$src_dir" ]]; then
            for conf_file in "$src_dir"/*.conf; do
                if [[ -f "$conf_file" ]]; then
                    local conf_name
                    conf_name=$(basename "$conf_file")
                    if [[ ! -f "$dst_dir/$conf_name" ]]; then
                        cp -f "$conf_file" "$dst_dir/$conf_name"
                        chmod 640 "$dst_dir/$conf_name"
                        chown root:nftban "$dst_dir/$conf_name"
                    fi
                fi
            done
            local conf_count
            conf_count=$(ls -1 "$dst_dir"/*.conf 2>/dev/null | wc -l)
            ok "Installed $conf_count $module config files"
        fi
    done

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

    # Install templates (mail, reports, email, partials)
    if [[ -d "$SCRIPT_DIR/install/share/nftban/templates" ]]; then
        cp -r "$SCRIPT_DIR/install/share/nftban/templates/"* /usr/share/nftban/templates/ 2>/dev/null || true
        local template_count
        template_count=$(find /usr/share/nftban/templates -type f -name "*.html" 2>/dev/null | wc -l)
        ok "Installed $template_count templates"
    fi

    # Set permissions (explicit ownership, not recursive on parent)
    chown root:root /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates/mail
    chmod 755 /usr/share/nftban/templates/reports
    find /usr/share/nftban/templates -type f -name "*.html" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -exec chown root:root {} \;
    find /usr/share/nftban/templates -type d -exec chown root:root {} \;

    # Install spec files (for nftban validate)
    mkdir -p /usr/share/nftban/specs
    if [[ -d "$SCRIPT_DIR/install/share/nftban/specs" ]]; then
        cp -f "$SCRIPT_DIR/install/share/nftban/specs/"*.json /usr/share/nftban/specs/ 2>/dev/null || true
        local spec_count
        spec_count=$(ls -1 /usr/share/nftban/specs/*.json 2>/dev/null | wc -l)
        ok "Installed $spec_count spec files"
    fi
    chown root:root /usr/share/nftban/specs
    chmod 755 /usr/share/nftban/specs
    find /usr/share/nftban/specs -type f -name "*.json" -exec chmod 644 {} \;
    find /usr/share/nftban/specs -type f -exec chown root:root {} \;

    # Install commands registry (v1.0.16 - single source of truth)
    log "Installing commands registry..."
    if [[ -f "$SCRIPT_DIR/commands.registry.yml" ]]; then
        install -m 0644 "$SCRIPT_DIR/commands.registry.yml" /etc/nftban/
        ok "Installed commands registry → /etc/nftban/commands.registry.yml"
    fi

    # Install documentation generators (v1.0.16)
    log "Installing documentation generators..."
    mkdir -p /usr/lib/nftban/scripts
    if [[ -f "$SCRIPT_DIR/scripts/generate-help.sh" ]]; then
        install -m 0755 "$SCRIPT_DIR/scripts/generate-help.sh" /usr/lib/nftban/scripts/
        install -m 0755 "$SCRIPT_DIR/scripts/generate-wiki-operator.sh" /usr/lib/nftban/scripts/
        install -m 0755 "$SCRIPT_DIR/scripts/generate-wiki-auditor.sh" /usr/lib/nftban/scripts/
        ok "Installed documentation generators → /usr/lib/nftban/scripts/"
    fi

    # Documentation moved to wiki (v1.0.20+)
    # See: https://github.com/itcmsgr/nftban/wiki

    # Install man page
    log "Installing man pages..."
    if [[ -f "$SCRIPT_DIR/install/man/man8/nftban.8" ]]; then
        mkdir -p /usr/share/man/man8
        install -m 0644 "$SCRIPT_DIR/install/man/man8/nftban.8" /usr/share/man/man8/
        ok "Installed man page → /usr/share/man/man8/nftban.8"
        # Update man database if available
        if command -v mandb &>/dev/null; then
            mandb -q 2>/dev/null || true
        fi
    fi

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

    # ==========================================================================
    # v1.0.19: Consolidated Polkit rules (Panel Integration Phase 1)
    # ==========================================================================
    # Removed: 10-nftban-core.rules + 20-nftban-suricata.rules (merged)
    # Removed: 50-nftban-auth.rules (auth-helper never existed)
    # Removed: 50-nftban-v030.rules (auditor placeholder)
    # Removed: 60-nftban-services.rules (unsafe wildcard pattern)
    # Removed: com.nftban.suricata.policy (unused custom actions)
    #
    # New: 10-nftban-systemd.rules (nftban group - operators)
    # New: 20-nftban-auditor.rules (nftban-auditor group - read-only)
    # New: 30-nftban-panel.rules (nftban-panel group - limited reload)
    # ==========================================================================

    # Install consolidated polkit rules (v1.0.19)
    local rules=(
        "10-nftban-systemd.rules"
        "20-nftban-auditor.rules"
        "30-nftban-panel.rules"
    )

    for rule in "${rules[@]}"; do
        if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/$rule" ]]; then
            cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/$rule" "$POLKIT_RULES_DIR_ETC/"
            chmod 644 "$POLKIT_RULES_DIR_ETC/$rule"
            ok "Installed: $rule"
        else
            warn "Polkit rule not found: $SCRIPT_DIR/packaging/polkit-1/rules.d/$rule"
        fi
    done

    # Install PAM auth policy if it exists (legacy UI auth)
    if [[ -f "$SCRIPT_DIR/install/pam/com.nftban.auth.policy" ]]; then
        cp -f "$SCRIPT_DIR/install/pam/com.nftban.auth.policy" "$POLKIT_ACTIONS_DIR/"
        chmod 644 "$POLKIT_ACTIONS_DIR/com.nftban.auth.policy"
        ok "Installed: com.nftban.auth.policy"
    fi

    # Start/restart polkit service
    systemctl restart polkit 2>/dev/null || warn "Failed to restart polkit"
    ok "Polkit configured (v1.0.19: 3-group RBAC model)"

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

    # NFTBand daemon (SINGLE nftables writer - CRITICAL for architecture)
    # Socket activation: nftband.socket creates socket, service receives FD
    if [[ -f "$SCRIPT_DIR/install/systemd/nftband.socket" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftband.socket" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftband.service" "$systemd_dir/"
        ok "NFTBand daemon units → $systemd_dir"
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

    # Service failure alert template
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-alert@.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-alert@.service" "$systemd_dir/"
        ok "Alert service template → $systemd_dir"
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

    # Login monitor
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-login-monitor.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-login-monitor.service" "$systemd_dir/"
        ok "Login monitor service → $systemd_dir"
    fi

    # Maintenance tasks
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.timer" "$systemd_dir/"
        ok "Maintenance timer units → $systemd_dir"
    fi

    # Snapshot service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.timer" "$systemd_dir/"
        ok "Snapshot timer units → $systemd_dir"
    fi

    # Rollback service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-rollback.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-rollback.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-rollback.timer" "$systemd_dir/"
        ok "Rollback timer units → $systemd_dir"
    fi

    # Watchdog service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.timer" "$systemd_dir/"
        ok "Watchdog timer units → $systemd_dir"
    fi

    # Pro subscription services (license check, inventory)
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.timer" "$systemd_dir/"
        ok "Pro license timer units → $systemd_dir"
    fi

    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.timer" "$systemd_dir/"
        ok "Pro inventory timer units → $systemd_dir"
    fi

    # Reload systemd
    systemctl daemon-reload
    ok "Systemd reloaded"

    # Enable and start timers
    log "Enabling timers..."

    # NFTBand daemon socket (CRITICAL - MUST start before health timer)
    # Socket activation: systemd creates socket, daemon receives FD on first connection
    if [[ -f "$systemd_dir/nftband.socket" ]]; then
        systemctl enable nftband.socket 2>/dev/null || warn "NFTBand socket enable failed"
        systemctl enable nftband.service 2>/dev/null || warn "NFTBand service enable failed"
        systemctl start nftband.socket 2>/dev/null || warn "NFTBand socket start failed"
        ok "NFTBand daemon enabled (single nftables writer)"
    fi

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

    # Pro timers (only if Pro enabled)
    if [[ "${NFTBAN_PRO_ENABLED:-false}" == "true" ]]; then
        if [[ -f "$systemd_dir/nftban-pro-license.timer" ]]; then
            systemctl enable --now nftban-pro-license.timer 2>/dev/null || warn "Pro license timer enable failed"
        fi
        if [[ -f "$systemd_dir/nftban-pro-inventory.timer" ]]; then
            systemctl enable --now nftban-pro-inventory.timer 2>/dev/null || warn "Pro inventory timer enable failed"
        fi
        ok "Pro timers enabled"
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

    # Run health check with auto-heal to fix any remaining issues
    log "Running health check with auto-heal..."
    nftban health check --auto-heal --quiet 2>/dev/null || warn "Health check returned warnings"

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

    # Start or reload nftables to apply config
    log "Starting nftables..."
    if systemctl is-active nftables >/dev/null 2>&1; then
        systemctl reload nftables 2>/dev/null || warn "nftables reload failed"
    else
        systemctl enable nftables 2>/dev/null || true
        systemctl start nftables 2>/dev/null || warn "nftables start failed"
    fi

    # ==========================================================================
    # SECURITY: Protect nft_schema.sh from modification (P0 CRITICAL)
    # ==========================================================================
    # Make nft_schema.sh immutable to prevent command injection attacks
    # This file defines the canonical nftables schema used by all components
    log "Applying security protections..."
    if [[ -f /usr/lib/nftban/lib/nft_schema.sh ]]; then
        chmod 444 /usr/lib/nftban/lib/nft_schema.sh
        chattr +i /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null || true
        ok "Security: nft_schema.sh protected (immutable)"
    fi

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
  $0 [OPTIONS]

Options:
  --help, -h              Show this help message
  --skip-xtables-fix      Skip automatic removal of xtables compat expressions
                          (Use if you manage nftables.conf manually)

Environment Variables:
  NFTBAN_SKIP_XTABLES_FIX=1   Same as --skip-xtables-fix

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

# Installation flags (can be set via CLI or environment)
SKIP_XTABLES_FIX="${NFTBAN_SKIP_XTABLES_FIX:-0}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h|help)
            show_usage
            exit 0
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

# Run comprehensive prerequisite checks first
check_prerequisites

check_root
check_nftables
check_yq
check_pam
check_conflicting_firewalls

# Check for xtables compat expressions (cPanel, etc.)
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
# Create login_alert.conf if not exists (required for 'nftban login status')
if [[ ! -f /etc/nftban/conf.d/login_alert.conf ]]; then
    mkdir -p /etc/nftban/conf.d
    cat > /etc/nftban/conf.d/login_alert.conf << 'LOGINEOF'
# NFTBan Login Alert Configuration (auto-generated by installer)
NFTBAN_LOGIN_ALERT_ENABLED="true"
NFTBAN_LOGIN_ALERT_SSH="true"
NFTBAN_LOGIN_ALERT_SU="true"
NFTBAN_LOGIN_ALERT_SUDO="true"
NFTBAN_LOGIN_ALERT_GEOIP="true"
NFTBAN_LOGIN_ALERT_MODE="realtime"
NFTBAN_LOGIN_ALERT_FORMAT="html"
LOGINEOF
    chmod 644 /etc/nftban/conf.d/login_alert.conf
    chown root:nftban /etc/nftban/conf.d/login_alert.conf 2>/dev/null || true
fi
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
# STEP 7: Panel Detection and Auto-Enable
# =============================================================================
log "Checking for web hosting panels..."

DETECTED_PANEL=""
PANEL_ENABLED=""

# Detect cPanel
if [[ -d "/usr/local/cpanel" ]]; then
    DETECTED_PANEL="cpanel"
    info "Detected: cPanel/WHM"
fi

# Detect DirectAdmin
if [[ -d "/usr/local/directadmin" ]]; then
    DETECTED_PANEL="directadmin"
    info "Detected: DirectAdmin"
fi

# Detect Plesk
if [[ -d "/usr/local/psa" ]]; then
    DETECTED_PANEL="plesk"
    info "Detected: Plesk"
fi

# Detect CWP
if [[ -d "/usr/local/cwpsrv" ]]; then
    DETECTED_PANEL="cwp"
    info "Detected: CentOS Web Panel"
fi

# Detect CyberPanel
if [[ -d "/usr/local/CyberCP" ]]; then
    DETECTED_PANEL="cyberpanel"
    info "Detected: CyberPanel"
fi

# If panel detected, auto-enable ports
if [[ -n "$DETECTED_PANEL" ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🖥️  Web Hosting Panel Detected: ${DETECTED_PANEL^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "Auto-enabling ${DETECTED_PANEL} panel ports..."

    # Mark panel as enabled in state file
    PANEL_STATE_DIR="/var/lib/nftban/panels"
    PANEL_STATE_FILE="$PANEL_STATE_DIR/enabled.conf"
    mkdir -p "$PANEL_STATE_DIR" 2>/dev/null || true

    {
        echo "# NFTBan Panel State Configuration"
        echo "# Auto-generated during installation"
        echo "${DETECTED_PANEL}=enabled"
    } > "$PANEL_STATE_FILE"
    chmod 640 "$PANEL_STATE_FILE" 2>/dev/null || true
    chown root:nftban "$PANEL_STATE_FILE" 2>/dev/null || true

    PANEL_ENABLED="$DETECTED_PANEL"
    ok "${DETECTED_PANEL} panel ports: AUTO-ENABLED"
    echo ""
else
    ok "No web hosting panel detected (standalone server)"
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
if [[ -n "${PANEL_ENABLED:-}" ]]; then
    echo "  ✓ ${PANEL_ENABLED^} panel ports"
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
