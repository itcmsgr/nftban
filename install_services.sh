#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Installation Script (Services Module)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Service installation functions (systemd, polkit, post-install)
#
# meta:name="install_services"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Install systemd units, polkit rules, and post-install tasks"
# meta:parent="install.sh"
# meta:created_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,cp,chmod,chown"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban.service,nftban-health.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Loaded by: install.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_INSTALL_SERVICES_LOADED:-}" ]] && return 0
_NFTBAN_INSTALL_SERVICES_LOADED=1

# R31: Load distro config for nftban_distro_get_polkit_dir() (v1.19.12)
if [[ -z "${_NFTBAN_DISTRO_CONFIG_LOADED:-}" ]]; then
    if [[ -f "${SCRIPT_DIR:-}/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
        export NFTBAN_DISTRO_CONF_DIR="${SCRIPT_DIR}/etc/nftban/distros"
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/cli/lib/nftban/lib/nftban_distro_config.sh"
        nftban_distro_init 2>/dev/null || true
    fi
fi

# =============================================================================
# SERVICE INSTALLATION FUNCTIONS
# =============================================================================

install_safety_whitelist() {
    log "Auto-Detecting System IPs (Lockout Prevention)..."

    if [[ -f "$LIB_DIR/core/nftban_system_ip.sh" ]]; then
        source "$LIB_DIR/core/nftban_system_ip.sh"
    else
        warn "System IP module not found, skipping auto-whitelist"
        return 0
    fi

    mkdir -p /etc/nftban/whitelist.d

    local protected=0

    # Auto-detect SSH client IP
    local ssh_ip="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_ip" ]]; then
        if ! nftban_is_ip_whitelisted "$ssh_ip" 2>/dev/null; then
            nftban_add_system_ip "$ssh_ip" "SSH installer (auto-detected on $(date +'%Y-%m-%d'))" >/dev/null 2>&1 || true
            ok "Auto-whitelisted SSH client: $ssh_ip"
            protected=$((protected + 1))
        fi
    fi

    # Auto-detect server interface IPs
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

    # Auto-detect public IPs
    local public_ipv4
    public_ipv4=$(nftban_get_public_ip "ipv4" 2>/dev/null || true)
    if [[ -n "$public_ipv4" ]]; then
        if ! nftban_is_ip_whitelisted "$public_ipv4" 2>/dev/null; then
            nftban_add_system_ip "$public_ipv4" "Server public IPv4 (auto-detected)" >/dev/null 2>&1 || true
            ok "Auto-whitelisted public IPv4: $public_ipv4"
            protected=$((protected + 1))
        fi
    fi

    if [[ $protected -gt 0 ]]; then
        ok "Safety whitelist created ($protected IP(s) protected)"
        log "Whitelist file: /etc/nftban/whitelist.d/00-system.conf"
    else
        ok "System IPs already whitelisted"
    fi

    return 0
}

install_tmpfiles() {
    log "Installing tmpfiles.d Configuration..."

    if [[ -f "$SCRIPT_DIR/install/systemd/tmpfiles.d/nftban.conf" ]]; then
        mkdir -p /etc/tmpfiles.d
        cp -f "$SCRIPT_DIR/install/systemd/tmpfiles.d/nftban.conf" /etc/tmpfiles.d/
        chmod 644 /etc/tmpfiles.d/nftban.conf
        chown root:root /etc/tmpfiles.d/nftban.conf
        ok "Installed: /etc/tmpfiles.d/nftban.conf"

        if command -v systemd-tmpfiles &>/dev/null; then
            systemd-tmpfiles --create /etc/tmpfiles.d/nftban.conf 2>/dev/null || true
            ok "Applied tmpfiles configuration"
        fi
    else
        warn "tmpfiles.d config not found"
    fi

    return 0
}

install_polkit() {
    log "Installing Polkit Policies..."

    # R31: Use nftban_distro_get_polkit_dir() for distro-aware path (v1.19.12)
    # Debian/Ubuntu use /usr/share/polkit-1/rules.d/, RHEL/Fedora use /etc/polkit-1/rules.d/
    local polkit_dir
    if declare -f nftban_distro_get_polkit_dir >/dev/null 2>&1; then
        polkit_dir=$(nftban_distro_get_polkit_dir)
    elif [[ -d /usr/share/polkit-1/rules.d ]]; then
        polkit_dir="/usr/share/polkit-1/rules.d"
    else
        polkit_dir="/etc/polkit-1/rules.d"
    fi

    # Create directories - actions dir is always the same, rules dir is distro-specific
    mkdir -p "$POLKIT_ACTIONS_DIR"
    mkdir -p "$polkit_dir"
    log "Polkit rules directory: $polkit_dir"

    # Load central config for path values
    local NFTBAN_CONF="/etc/nftban/nftban.conf"
    if [[ -f "$NFTBAN_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_CONF"
    elif [[ -f "$SCRIPT_DIR/install/config/nftban.conf" ]]; then
        source "$SCRIPT_DIR/install/config/nftban.conf"
    fi

    : "${NFTBAN_BIN:=/usr/sbin/nftban}"
    : "${NFTBAN_AUTH_BIN:=/usr/libexec/nftban-ui-auth}"

    # Install consolidated polkit rules (v1.0.19)
    local rules=(
        "10-nftban-systemd.rules"
        "20-nftban-auditor.rules"
        "30-nftban-panel.rules"
    )

    for rule in "${rules[@]}"; do
        if [[ -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/$rule" ]]; then
            cp -f "$SCRIPT_DIR/packaging/polkit-1/rules.d/$rule" "$polkit_dir/"
            chmod 644 "$polkit_dir/$rule"
            ok "Installed: $rule -> $polkit_dir"
        else
            warn "Polkit rule not found: $SCRIPT_DIR/packaging/polkit-1/rules.d/$rule"
        fi
    done

    systemctl restart polkit 2>/dev/null || warn "Failed to restart polkit"
    ok "Polkit configured (v1.0.19: 3-group RBAC model)"

    return 0
}

install_logrotate() {
    log "Installing Logrotate Configuration..."

    local logrotate_dst="/etc/logrotate.d/nftban"

    if ! command -v logrotate &>/dev/null; then
        warn "logrotate not installed - skipping log rotation config"
        return 0
    fi

    # Auto-calculate rotation based on disk space
    local avail_gb=0
    local log_frequency="weekly"
    local log_rotate=4
    local suricata_rotate=7
    local report_rotate=3

    if [[ -d /var/log ]]; then
        avail_gb=$(df -BG /var/log 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print int($4)}' || echo "0")
    fi

    if [[ "$avail_gb" -lt 10 ]]; then
        log_frequency="daily"
        log_rotate=7
        suricata_rotate=3
        report_rotate=1
        info "Disk: ${avail_gb}GB (small) -> rotation: logs 7d, Suricata 3d"
    elif [[ "$avail_gb" -lt 30 ]]; then
        log_frequency="weekly"
        log_rotate=4
        suricata_rotate=7
        report_rotate=3
        info "Disk: ${avail_gb}GB (medium) -> rotation: logs 1 month, Suricata 7d"
    else
        log_frequency="weekly"
        log_rotate=8
        suricata_rotate=14
        report_rotate=6
        info "Disk: ${avail_gb}GB (large) -> rotation: logs 2 months, Suricata 14d"
    fi

    cat > "$logrotate_dst" << LOGROTATE
# NFTBan Log Rotation (auto-generated by installer)
# Disk space: ${avail_gb}GB - Policy adjusted automatically

/var/log/nftban/*.log {
    ${log_frequency}
    rotate ${log_rotate}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 nftban nftban
    copytruncate
}

/var/log/nftban/suricata/*.json /var/log/nftban/suricata/*.log {
    su suricata nftban
    daily
    rotate ${suricata_rotate}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 suricata nftban
    copytruncate
    size 50M
}

/var/lib/nftban/reports/*.html /var/lib/nftban/reports/*.json {
    monthly
    rotate ${report_rotate}
    compress
    delaycompress
    missingok
    notifempty
}
LOGROTATE

    chown root:root "$logrotate_dst"
    chmod 0644 "$logrotate_dst"
    ok "Logrotate config installed: $logrotate_dst"

    mkdir -p /var/lib/nftban/reports/archive 2>/dev/null || true
    chown nftban:nftban /var/lib/nftban/reports/archive 2>/dev/null || true

    return 0
}

install_systemd() {
    log "Installing Systemd Units..."

    # Initialize distro config if not already loaded
    if [[ -z "${NFTBAN_DISTRO_CONFIG_LOADED:-}" ]]; then
        if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
            if [[ -d "/etc/nftban/distros" ]]; then
                export NFTBAN_DISTRO_CONF_DIR="/etc/nftban/distros"
            else
                export NFTBAN_DISTRO_CONF_DIR="$SCRIPT_DIR/etc/nftban/distros"
            fi
            source "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh"
            nftban_distro_init 2>/dev/null || true
        fi
    fi

    local systemd_dir="${DISTRO_PATHS[systemd_system]:-/etc/systemd/system}"
    log "Systemd directory: $systemd_dir"

    # NFTBand daemon
    if [[ -f "$SCRIPT_DIR/install/systemd/nftband.socket" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftband.socket" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftband.service" "$systemd_dir/"
        ok "NFTBand daemon units -> $systemd_dir"
    fi

    # Firewall init
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-firewall-init.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-firewall-init.service" "$systemd_dir/"
        ok "Firewall init service -> $systemd_dir"
    fi

    # Health check timer
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-health.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health.timer" "$systemd_dir/"
        ok "Health timer units -> $systemd_dir"
    fi

    # Health fix service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-health-fix.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-health-fix.service" "$systemd_dir/"
        ok "Health fix service -> $systemd_dir"
    fi

    # GeoIP updater
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-core-geoip.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-core-geoip.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-core-geoip.timer" "$systemd_dir/"
        ok "GeoIP timer units -> $systemd_dir"
    fi

    # Feeds updater
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-core-feeds.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-core-feeds.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-core-feeds.timer" "$systemd_dir/"
        ok "Feeds timer units -> $systemd_dir"
    fi

    # Task queue processor
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-queue.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-queue.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-queue.timer" "$systemd_dir/"
        ok "Queue processor units -> $systemd_dir"
    fi

    # Unified exporter
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-unified-exporter.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-unified-exporter.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-unified-exporter.timer" "$systemd_dir/"
        ok "Unified exporter units -> $systemd_dir"
    fi

    # Service failure alert template
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-alert@.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-alert@.service" "$systemd_dir/"
        ok "Alert service template -> $systemd_dir"
    fi

    # Web GUI service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-ui.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui.service" "$systemd_dir/"
        ok "Web GUI service -> $systemd_dir"
    fi

    # Web GUI auth socket
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.socket" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.socket" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-ui-auth.service" "$systemd_dir/"
        ok "Web GUI auth units -> $systemd_dir"
    fi

    # Suricata IDS integration
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-suricata.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata.service" "$systemd_dir/"
        ok "Suricata daemon service -> $systemd_dir"
    fi

    # Suricata rules updater
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-suricata-update.timer" "$systemd_dir/"
        ok "Suricata rules updater units -> $systemd_dir"
    fi

    # Maintenance tasks
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-maintenance.timer" "$systemd_dir/"
        ok "Maintenance timer units -> $systemd_dir"
    fi

    # Snapshot service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-snapshot.timer" "$systemd_dir/"
        ok "Snapshot timer units -> $systemd_dir"
    fi

    # Rollback service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-rollback.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-rollback.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-rollback.timer" "$systemd_dir/"
        ok "Rollback timer units -> $systemd_dir"
    fi

    # Watchdog service
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-watchdog.timer" "$systemd_dir/"
        ok "Watchdog timer units -> $systemd_dir"
    fi

    # Pro subscription services
    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-license.timer" "$systemd_dir/"
        ok "Pro license timer units -> $systemd_dir"
    fi

    if [[ -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.service" ]]; then
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.service" "$systemd_dir/"
        cp -f "$SCRIPT_DIR/install/systemd/nftban-pro-inventory.timer" "$systemd_dir/"
        ok "Pro inventory timer units -> $systemd_dir"
    fi

    # Reload systemd
    systemctl daemon-reload
    ok "Systemd reloaded"

    # Enable and start timers
    log "Enabling timers..."

    # NFTBand daemon socket
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

    # Unified exporter timer (only if metrics enabled)
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" == "true" ]]; then
        systemctl enable --now nftban-unified-exporter.timer 2>/dev/null || warn "Unified exporter timer enable failed"
        ok "Metrics enabled (backend: ${NFTBAN_METRICS_BACKEND:-prometheus})"
    fi

    # GeoIP timer
    if [[ "${NFTBAN_GEOIP_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-core-geoip.timer" ]]; then
        systemctl enable --now nftban-core-geoip.timer 2>/dev/null || warn "GeoIP timer enable failed"
    fi

    # Feeds timer
    if [[ "${NFTBAN_FEEDS_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-core-feeds.timer" ]]; then
        systemctl enable --now nftban-core-feeds.timer 2>/dev/null || warn "Feeds timer enable failed"
    fi

    # Queue timer
    if [[ -f "$systemd_dir/nftban-queue.timer" ]]; then
        systemctl enable --now nftban-queue.timer 2>/dev/null || warn "Queue timer enable failed"
    fi

    # Suricata update timer
    if [[ "${NFTBAN_SURICATA_ENABLED:-false}" == "true" ]] && [[ -f "$systemd_dir/nftban-suricata-update.timer" ]]; then
        systemctl enable --now nftban-suricata-update.timer 2>/dev/null || warn "Suricata rules update timer enable failed"
    fi

    # Pro timers
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

    if ! command -v nftban &>/dev/null; then
        warn "nftban command not found, skipping post-install"
        return 0
    fi

    log "Fixing permissions..."
    nftban permissions enforce 2>/dev/null || warn "Permission enforcement failed"

    log "Running health check with auto-heal..."
    nftban health check --auto-heal --quiet 2>/dev/null || warn "Health check returned warnings"

    log "Auto-detecting SSH port..."
    _install_auto_whitelist_ssh_port

    log "Auto-whitelisting system IP..."
    _install_auto_whitelist_system_ip

    log "Reloading systemd daemon..."
    systemctl daemon-reload 2>/dev/null || true

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

    log "Starting nftables..."
    if systemctl is-active nftables >/dev/null 2>&1; then
        systemctl reload nftables 2>/dev/null || warn "nftables reload failed"
    else
        systemctl enable nftables 2>/dev/null || true
        systemctl start nftables 2>/dev/null || warn "nftables start failed"
    fi

    # Security: Protect nft_schema.sh from modification
    log "Applying security protections..."
    if [[ -f /usr/lib/nftban/lib/nft_schema.sh ]]; then
        chmod 444 /usr/lib/nftban/lib/nft_schema.sh
        chattr +i /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null || true
        ok "Security: nft_schema.sh protected (immutable)"
    fi

    ok "Post-install configuration completed"
    return 0
}

_install_auto_whitelist_ssh_port() {
    local ports_dir="/etc/nftban/ports.d"
    local ssh_conf="${ports_dir}/00-ssh.conf"
    local sshd_config="/etc/ssh/sshd_config"
    local ssh_port="22"

    if [[ -f "$sshd_config" ]]; then
        local detected_port
        detected_port=$(grep -E "^Port\s+" "$sshd_config" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$detected_port" && "$detected_port" =~ ^[0-9]+$ ]]; then
            ssh_port="$detected_port"
        fi
    fi

    mkdir -p "$ports_dir"

    if [[ ! -f "$ssh_conf" ]]; then
        cat > "$ssh_conf" << SSHEOF
# Auto-generated SSH port whitelist
# Created by: NFTBan installer
# Date: $(date -Iseconds)
# Detected from: $sshd_config
[ssh]
port=$ssh_port
protocol=tcp
SSHEOF
        chmod 640 "$ssh_conf"
        chown root:nftban "$ssh_conf"
        ok "Auto-whitelisted SSH port: $ssh_port"
    fi
}

_install_auto_whitelist_system_ip() {
    local whitelist_dir="/etc/nftban/whitelist.d"
    local system_conf="${whitelist_dir}/00-system.conf"

    mkdir -p "$whitelist_dir"

    # Check if already whitelisted
    [[ -f "$system_conf" ]] && return 0

    local ssh_ip="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_ip" ]]; then
        echo "# Auto-generated system whitelist" > "$system_conf"
        echo "# Created by: NFTBan installer" >> "$system_conf"
        echo "# Date: $(date -Iseconds)" >> "$system_conf"
        echo "" >> "$system_conf"
        echo "$ssh_ip  # SSH client IP (installer)" >> "$system_conf"
        chmod 640 "$system_conf"
        chown root:nftban "$system_conf"
        ok "Auto-whitelisted installer IP: $ssh_ip"
    fi
}

install_gui() {
    log "Installing Web GUI..."

    if [[ ! -f "$BIN_DIR/nftban-ui" ]]; then
        warn "nftban-ui binary not found, skipping GUI installation"
        return 0
    fi

    cp -f "$BIN_DIR/nftban-ui" "$GUI_INSTALL_PATH"
    chmod 755 "$GUI_INSTALL_PATH"
    chown root:root "$GUI_INSTALL_PATH"
    ok "Installed: $GUI_INSTALL_PATH"

    # Install nftban-ui-auth helper
    if [[ -f "$BIN_DIR/nftban-ui-auth" ]]; then
        mkdir -p /usr/libexec
        cp -f "$BIN_DIR/nftban-ui-auth" /usr/libexec/nftban-ui-auth
        chmod 755 /usr/libexec/nftban-ui-auth
        chown root:root /usr/libexec/nftban-ui-auth
        ok "Installed: /usr/libexec/nftban-ui-auth"
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
  --quiet, --yes, -y      Non-interactive mode (skip prompts, use defaults)
  --skip-xtables-fix      Skip automatic removal of xtables compat expressions

Environment Variables:
  NFTBAN_QUIET=1              Same as --quiet (non-interactive)
  NFTBAN_SKIP_XTABLES_FIX=1   Same as --skip-xtables-fix

This script installs NFTBan with all components:
  - Go binaries (nftban-core)
  - CLI commands and libraries
  - Polkit rules
  - Systemd timers
  - NFTables configuration
  - GeoIP database (free)

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
