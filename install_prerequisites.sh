#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Installation Script (Prerequisites Module)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Prerequisite checks for NFTBan installation
#
# meta:name="install_prerequisites"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Prerequisite checks including nftables, conflicting firewalls, Go binaries"
# meta:parent="install.sh"
# meta:created_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Loaded by: install.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_INSTALL_PREREQUISITES_LOADED:-}" ]] && return 0
_NFTBAN_INSTALL_PREREQUISITES_LOADED=1

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

# Check and install yq v4 (mikefarah/yq) - REQUIRED
#
# WHY v4 IS REQUIRED:
#   - yq v3 (Python-based pip install yq) is ~10x slower (0.17s vs 0.017s per call)
#   - generate-help.sh makes 100+ yq calls, causing 20s+ delay with v3 vs 2s with v4
#   - yq v3 and v4 have different syntax (if/then vs select(), // empty vs // "")
#   - NFTBan 1.12.7+ standardized on mikefarah/yq v4 syntax
#
check_yq() {
    log "Checking yq v4 (YAML processor)..."

    local yq_version=""
    local need_install=false

    if command -v yq &>/dev/null; then
        yq_version=$(yq --version 2>/dev/null | head -1 || echo "")

        # Check if it's mikefarah/yq v4 (contains "mikefarah" or version starts with "v4")
        if [[ "$yq_version" == *"mikefarah"* ]] || [[ "$yq_version" == *"version v4"* ]]; then
            ok "yq v4 found: $yq_version"
            return 0
        else
            # Python yq v3 detected - need to upgrade
            warn "yq v3 (Python) detected: $yq_version"
            warn "NFTBan requires mikefarah/yq v4 for performance (10x faster)"
            need_install=true
        fi
    else
        warn "yq not found - installing mikefarah/yq v4..."
        need_install=true
    fi

    if [[ "$need_install" == "true" ]]; then
        install_yq_v4
    fi
}

# Install mikefarah/yq v4 from GitHub releases
# R44: Added SHA256 checksum verification (v1.19.12)
install_yq_v4() {
    local YQ_VERSION="v4.44.1"
    local YQ_BINARY="yq_linux_amd64"
    local YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    local YQ_CHECKSUMS_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums"

    log "Installing mikefarah/yq ${YQ_VERSION}..."

    # Backup old yq if exists
    if command -v yq &>/dev/null; then
        local old_yq
        old_yq=$(command -v yq)
        if [[ -f "$old_yq" ]] && [[ ! -L "$old_yq" ]]; then
            mv "$old_yq" "${old_yq}.v3.bak" 2>/dev/null || true
            log "Backed up old yq to ${old_yq}.v3.bak"
        fi
    fi

    # Download to temp file first for checksum verification
    local temp_yq temp_checksums
    temp_yq=$(mktemp)
    temp_checksums=$(mktemp)

    # Download binary and checksums
    if ! curl -sL "$YQ_URL" -o "$temp_yq"; then
        rm -f "$temp_yq" "$temp_checksums"
        error "Failed to download yq v4 from $YQ_URL"
        error "Please install manually: https://github.com/mikefarah/yq/releases"
        exit 1
    fi

    if ! curl -sL "$YQ_CHECKSUMS_URL" -o "$temp_checksums"; then
        rm -f "$temp_yq" "$temp_checksums"
        error "Failed to download yq checksums from $YQ_CHECKSUMS_URL"
        exit 1
    fi

    # Extract expected checksum for our binary
    local expected_checksum
    expected_checksum=$(grep "${YQ_BINARY}\$" "$temp_checksums" | awk '{print $1}')
    if [[ -z "$expected_checksum" ]]; then
        rm -f "$temp_yq" "$temp_checksums"
        error "Could not find checksum for ${YQ_BINARY} in checksums file"
        exit 1
    fi

    # Verify SHA256 checksum
    local actual_checksum
    actual_checksum=$(sha256sum "$temp_yq" | awk '{print $1}')
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        rm -f "$temp_yq" "$temp_checksums"
        error "SHA256 checksum mismatch for yq!"
        error "Expected: $expected_checksum"
        error "Got:      $actual_checksum"
        exit 1
    fi

    log "SHA256 checksum verified: ${actual_checksum:0:16}..."
    rm -f "$temp_checksums"

    # Install verified binary
    mv "$temp_yq" /usr/local/bin/yq
    chmod +x /usr/local/bin/yq

    # Create symlink in /usr/bin if not exists
    if [[ ! -e /usr/bin/yq ]]; then
        ln -sf /usr/local/bin/yq /usr/bin/yq
    fi

    # Verify installation
    if /usr/local/bin/yq --version 2>/dev/null | grep -q "mikefarah"; then
        ok "yq v4 installed successfully: $(/usr/local/bin/yq --version)"
    else
        error "yq v4 installation verification failed"
        exit 1
    fi
}

# Check and install PAM (REQUIRED for nftban-ui-auth)
check_pam() {
    log "Checking PAM (Pluggable Authentication Modules)..."

    if ldconfig -p 2>/dev/null | grep -q libpam.so || [[ -f /lib64/libpam.so.0 ]] || [[ -f /lib/x86_64-linux-gnu/libpam.so.0 ]]; then
        ok "PAM library found"
        return 0
    fi

    warn "PAM library not found - installing..."

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

    # CHECK 1: Operating System Version
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        ok "Operating System: $PRETTY_NAME"

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

    # CHECK 2: Required Commands (auto-install missing packages)
    echo ""
    log "Checking required commands..."

    # Map commands to packages by OS family
    declare -A CMD_TO_PKG_DEB=(
        [nft]="nftables"
        [systemctl]="systemd"
        [ip]="iproute2"
        [iptables]="iptables"
        [curl]="curl"
        [jq]="jq"
        [yq]="yq"
        [gawk]="gawk"
        [bc]="bc"
    )
    declare -A CMD_TO_PKG_RPM=(
        [nft]="nftables"
        [systemctl]="systemd"
        [ip]="iproute"
        [iptables]="iptables"
        [curl]="curl"
        [jq]="jq"
        [yq]="yq"
        [gawk]="gawk"
        [bc]="bc"
    )

    local missing_pkgs=()
    for cmd in nft systemctl ip iptables curl jq yq gawk bc; do
        if command -v $cmd &>/dev/null; then
            ok "Found: $cmd"
        else
            warn "MISSING: $cmd - will attempt to install"
            case "$ID" in
                ubuntu|debian)
                    [[ -n "${CMD_TO_PKG_DEB[$cmd]:-}" ]] && missing_pkgs+=("${CMD_TO_PKG_DEB[$cmd]}")
                    ;;
                rhel|centos|rocky|almalinux|fedora)
                    [[ -n "${CMD_TO_PKG_RPM[$cmd]:-}" ]] && missing_pkgs+=("${CMD_TO_PKG_RPM[$cmd]}")
                    ;;
            esac
        fi
    done

    # Auto-install missing packages
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing_pkgs[*]}"
        case "$ID" in
            ubuntu|debian)
                # yq not in apt, install from GitHub with checksum verification (R44)
                if [[ " ${missing_pkgs[*]} " =~ " yq " ]]; then
                    missing_pkgs=("${missing_pkgs[@]/yq/}")
                    install_yq_v4
                fi
                [[ ${#missing_pkgs[@]} -gt 0 ]] && apt-get update -qq && apt-get install -y "${missing_pkgs[@]}"
                ;;
            rhel|centos|rocky|almalinux)
                # yq not in dnf, install from GitHub with checksum verification (R44)
                if [[ " ${missing_pkgs[*]} " =~ " yq " ]]; then
                    missing_pkgs=("${missing_pkgs[@]/yq/}")
                    install_yq_v4
                fi
                [[ ${#missing_pkgs[@]} -gt 0 ]] && dnf install -y "${missing_pkgs[@]}"
                ;;
            fedora)
                # yq install from GitHub with checksum verification (R44)
                if [[ " ${missing_pkgs[*]} " =~ " yq " ]]; then
                    missing_pkgs=("${missing_pkgs[@]/yq/}")
                    install_yq_v4
                fi
                [[ ${#missing_pkgs[@]} -gt 0 ]] && dnf install -y "${missing_pkgs[@]}"
                ;;
        esac

        # Verify installation
        for cmd in nft systemctl ip iptables curl jq yq gawk bc; do
            if command -v $cmd &>/dev/null; then
                ok "Verified: $cmd"
            else
                error "FAILED to install: $cmd"
                PREREQ_FAILED=1
            fi
        done
    fi

    # CHECK 3: Kernel nftables Support
    echo ""
    log "Checking kernel nftables support..."

    if [[ -d /proc/sys/net/netfilter ]]; then
        ok "Netfilter subsystem available"
    else
        error "Netfilter not available in kernel"
        PREREQ_FAILED=1
    fi

    if nft list ruleset &>/dev/null; then
        ok "nftables kernel modules loaded"
    else
        warn "nftables modules not loaded (will auto-load on first use)"
    fi

    # CHECK 4: Network Connectivity (for GeoIP download)
    echo ""
    log "Checking network connectivity..."

    if curl -sI --connect-timeout 5 https://github.com &>/dev/null; then
        ok "Internet connectivity: OK (github.com reachable)"
    else
        warn "Cannot reach github.com - GeoIP download may fail"
        info "You can manually download later: nftban-core geoip update"
    fi

    # FINAL RESULT
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

For help: https://github.com/itcmsgr/nftban/issues
EOF

    chmod 600 "${backup_path}"/* 2>/dev/null || true
    info "Backup completed: $backup_path"
    echo ""
    return 0
}

analyze_firewall_rules() {
    local has_rules=0

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "CURRENT FIREWALL RULES SUMMARY:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Analyze iptables
    if command -v iptables &>/dev/null; then
        local ipt_count ipt6_count
        ipt_count=$(iptables -S 2>/dev/null | grep -v "^-P" | wc -l)
        ipt6_count=$(ip6tables -S 2>/dev/null | grep -v "^-P" | wc -l)

        if [[ $ipt_count -gt 0 ]] || [[ $ipt6_count -gt 0 ]]; then
            echo "iptables:"
            echo "  IPv4 rules: $ipt_count"
            echo "  IPv6 rules: $ipt6_count"
            has_rules=1
        fi
    fi

    # Analyze UFW
    if command -v ufw &>/dev/null; then
        local ufw_count
        ufw_count=$(ufw status numbered 2>/dev/null | grep -c "^\[" || echo "0")
        if [[ $ufw_count -gt 0 ]]; then
            echo "UFW:"
            echo "  Active rules: $ufw_count"
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
            echo "  Active zones: $zone_count"
            firewall-cmd --list-all 2>/dev/null | head -15
            has_rules=1
        fi
    fi

    echo ""

    if [[ $has_rules -eq 0 ]]; then
        info "No active firewall rules detected"
    else
        warn "These rules will be DISABLED when you proceed!"
        echo ""
        echo "NFTBan will:"
        echo "  Backup your rules to /var/backups/nftban/firewall-migration/"
        echo "  Stop and disable the conflicting firewall service(s)"
        echo "  NOT automatically convert or migrate your rules"
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

    # 2. Check iptables - differentiate iptables-nft (conflict) vs iptables-legacy (OK)
    if command -v iptables &>/dev/null; then
        local ipt_svc_version
        ipt_svc_version=$(iptables --version 2>/dev/null || echo "")
        local is_iptables_nft=0
        if [[ "$ipt_svc_version" == *"nf_tables"* ]]; then
            is_iptables_nft=1
        fi

        if systemctl is-active --quiet iptables 2>/dev/null; then
            if [[ $is_iptables_nft -eq 1 ]]; then
                firewall_issues+=("iptables-nft service is ACTIVE (creates nftables tables)")
                conflicts_found=1
            else
                info "iptables-legacy service is ACTIVE (co-exists with nftables)"
            fi
        elif systemctl is-enabled --quiet iptables 2>/dev/null; then
            if [[ $is_iptables_nft -eq 1 ]]; then
                firewall_issues+=("iptables-nft service is ENABLED (not running)")
                conflicts_found=1
            else
                info "iptables-legacy service is ENABLED (co-exists with nftables)"
            fi
        fi
    fi

    # 3. Check ufw (Ubuntu/Debian)
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_issues+=("ufw is ACTIVE")
            conflicts_found=1
        fi
    fi

    # 4. Check fail2ban with iptables-nft backend
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local ipt_version
            ipt_version=$(iptables --version 2>/dev/null || echo "")
            if [[ "$ipt_version" == *"nf_tables"* ]]; then
                if nft list table ip filter &>/dev/null 2>&1; then
                    firewall_issues+=("fail2ban with iptables-nft is ACTIVE (creates 'ip filter' table)")
                    conflicts_found=1
                fi
            fi
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
    error "CONFLICTING FIREWALL(S) DETECTED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    warn "NFTBan uses nftables and CANNOT coexist with these firewalls:"
    echo ""
    for issue in "${firewall_issues[@]}"; do
        echo "  $issue"
    done
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show current firewall rules summary
    analyze_firewall_rules

    # In quiet mode, skip prompt and auto-fix
    local auto_fix="n"
    if [[ "${NFTBAN_QUIET:-0}" == "1" ]]; then
        auto_fix="y"
        info "Quiet mode: Automatically fixing conflicting firewalls"
    else
        read -p "Would you like NFTBan to automatically stop and disable these firewalls? [y/N]: " auto_fix
    fi

    if [[ "${auto_fix,,}" == "y" || "${auto_fix,,}" == "yes" ]]; then
        echo ""
        backup_firewall_rules || warn "Backup failed, but continuing..."
        log "Automatically stopping and disabling conflicting firewalls..."

        local fixed=0 failed=0

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

        # Fix iptables - only auto-disable if iptables-nft
        if systemctl is-active --quiet iptables 2>/dev/null || systemctl is-enabled --quiet iptables 2>/dev/null; then
            local autofix_ipt_version
            autofix_ipt_version=$(iptables --version 2>/dev/null || echo "")
            if [[ "$autofix_ipt_version" == *"nf_tables"* ]]; then
                log "Stopping iptables-nft (conflicts with nftables)..."
                if systemctl stop iptables 2>/dev/null && systemctl disable iptables 2>/dev/null; then
                    systemctl stop ip6tables 2>/dev/null || true
                    systemctl disable ip6tables 2>/dev/null || true
                    ok "iptables-nft stopped and disabled"
                    fixed=$((fixed + 1))
                else
                    warn "Failed to stop/disable iptables-nft"
                    failed=$((failed + 1))
                fi
            else
                info "Skipping iptables-legacy (co-exists with nftables)"
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
            exit 1
        else
            ok "All conflicting firewalls have been stopped and disabled ($fixed fixed)"
        fi
    else
        echo ""
        error "Installation cannot continue with conflicting firewalls active"
        exit 1
    fi

    echo ""
    return 0
}

# Check and fix xtables compatibility expressions in nftables.conf
check_xtables_compat() {
    log "Checking for xtables compatibility expressions..."

    local nft_configs=(
        "/etc/sysconfig/nftables.conf"
        "/etc/nftables.conf"
    )

    local found_compat=0

    for config_file in "${nft_configs[@]}"; do
        if [[ -f "$config_file" ]]; then
            if grep -qE 'xt (target|match)' "$config_file" 2>/dev/null; then
                found_compat=1
                warn "Found xtables compat expressions in: $config_file"

                # Create backup
                local backup_dir="/var/backups/nftban/firewall-migration"
                local timestamp
                timestamp=$(date +"%Y%m%d-%H%M%S")
                local backup_path="${backup_dir}/${timestamp}"
                mkdir -p "$backup_path" 2>/dev/null || true

                if cp "$config_file" "${backup_path}/$(basename "$config_file").backup" 2>/dev/null; then
                    ok "Backed up to: ${backup_path}/$(basename "$config_file").backup"
                fi

                # Create cleaned version
                local temp_file
                temp_file=$(mktemp)
                grep -v 'xt target\|xt match' "$config_file" > "$temp_file" 2>/dev/null || true

                if mv "$temp_file" "$config_file" 2>/dev/null; then
                    ok "Removed xtables compat expressions from: $config_file"
                else
                    warn "Could not modify $config_file (check permissions)"
                    rm -f "$temp_file" 2>/dev/null || true
                fi
            fi
        fi
    done

    if [[ $found_compat -eq 0 ]]; then
        ok "No xtables compat expressions found (clean nftables config)"
    fi

    return 0
}

# Check Go binaries exist (REQUIRED)
check_go_binaries() {
    log "Checking Go binaries..."

    local missing=0

    if [[ ! -f "$BIN_DIR/nftban-core" ]]; then
        warn "Missing: $BIN_DIR/nftban-core"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        log "Go binaries not found, attempting auto-download..."

        local download_script="$SCRIPT_DIR/install/download-binaries.sh"
        if [[ -f "$download_script" ]]; then
            log "Running download-binaries.sh..."
            mkdir -p "$BIN_DIR"

            if SKIP_INSTALL=1 DOWNLOAD_DIR="$BIN_DIR" bash "$download_script" 2>&1; then
                local arch
                arch=$(uname -m)
                case "$arch" in
                    x86_64)  arch="amd64" ;;
                    aarch64) arch="arm64" ;;
                esac

                for binary in nftban-core nftband nftban-ui nftban-ui-auth; do
                    local downloaded="$BIN_DIR/${binary}-linux-${arch}"
                    local target="$BIN_DIR/${binary}"
                    if [[ -f "$downloaded" ]] && [[ ! -f "$target" ]]; then
                        mv "$downloaded" "$target"
                        chmod 755 "$target"
                    fi
                done

                if [[ -f "$BIN_DIR/nftban-core" ]]; then
                    ok "Go binaries downloaded successfully"
                    return 0
                fi
            fi

            error "Auto-download failed"
        fi

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

# Download FREE GeoIP database
download_geoip_database() {
    log "Downloading FREE GeoIP database..."

    local geoip_dir="/var/lib/nftban/geoip"

    mkdir -p "$geoip_dir"
    chown nftban:nftban "$geoip_dir" 2>/dev/null || true
    chmod 750 "$geoip_dir"

    # Check if recent database exists
    local existing_db=""
    for check_db in "${geoip_dir}/dbip-country-lite.mmdb" "${geoip_dir}/GeoLite2-City.mmdb" "${geoip_dir}/GeoLite2-Country.mmdb"; do
        if [[ -f "$check_db" ]]; then
            existing_db="$check_db"
            break
        fi
    done

    if [[ -n "$existing_db" ]]; then
        local file_age now_ts file_ts
        now_ts=$(date +%s)
        file_ts=$(stat -c %Y "$existing_db" 2>/dev/null || echo 0)
        file_age=$(( (now_ts - file_ts) / 86400 ))
        if [[ $file_age -lt 30 ]]; then
            ok "GeoIP database exists (${file_age} days old)"
            return 0
        fi
    fi

    # Try nftban-core first
    if [[ -x "/usr/lib/nftban/bin/nftban-core" ]]; then
        log "Using nftban-core to download GeoIP database..."
        if /usr/lib/nftban/bin/nftban-core geoip update 2>/dev/null; then
            ok "GeoIP database downloaded successfully"
            return 0
        fi
        warn "nftban-core download failed, trying direct download..."
    fi

    # Fallback: Download free DB-IP database directly
    local current_month
    current_month=$(date +%Y-%m)
    local db_url="https://download.db-ip.com/free/dbip-country-lite-${current_month}.mmdb.gz"
    local db_file="${geoip_dir}/dbip-country-lite.mmdb"
    # R17: Use mktemp for secure temp files (v1.19.12)
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/dbip-country-lite.XXXXXXXXXX.mmdb.gz")

    log "Downloading free DB-IP Lite database..."

    if curl -fsSL -o "$tmp_file" "$db_url" --max-time 60; then
        if gunzip -c "$tmp_file" > "$db_file" 2>/dev/null; then
            rm -f "$tmp_file"
            chmod 644 "$db_file"
            chown nftban:nftban "$db_file" 2>/dev/null || true
            ok "GeoIP database downloaded successfully (DB-IP Lite)"
            info "Attribution: IP Geolocation by DB-IP (https://db-ip.com)"
            return 0
        else
            rm -f "$tmp_file"
            warn "Failed to decompress GeoIP database"
        fi
    else
        rm -f "$tmp_file" 2>/dev/null
        warn "Failed to download GeoIP database"
    fi

    warn "Could not download GeoIP database (will retry via timer)"
    info "Manual download: nftban geoip update"
}

# Ask user about metrics
ask_metrics_question() {
    if [[ "${NFTBAN_QUIET:-0}" == "1" ]]; then
        NFTBAN_METRICS_ENABLED="${NFTBAN_METRICS_ENABLED:-true}"
        NFTBAN_METRICS_BACKEND="${NFTBAN_METRICS_BACKEND:-}"
        info "Quiet mode: Metrics enabled (file storage)"
        return 0
    fi

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
