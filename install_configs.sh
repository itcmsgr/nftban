#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Installation Script (Configs Module)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Configuration file installation functions
#
# meta:name="install_configs"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Install configuration files, templates, and dependencies"
# meta:parent="install.sh"
# meta:created_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="cp,chmod,chown,mkdir,install"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Loaded by: install.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_INSTALL_CONFIGS_LOADED:-}" ]] && return 0
_NFTBAN_INSTALL_CONFIGS_LOADED=1

# =============================================================================
# INSTALL CONFIG HELPER FUNCTIONS
# =============================================================================

# Create all required directories
_install_configs_directories() {
    # /etc/nftban structure
    mkdir -p /etc/nftban/{whitelist.d,blacklist.d,ports.d,conf.d,distros,suricata,rules.d,patterns.d,connectors,nftables.d}
    mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan,geoban,geoip,rbl}
    mkdir -p /etc/nftban/patterns.d/botscan
    mkdir -p /etc/nftban/suricata/{profiles,config,rules,cache,state/last-good}

    # /var/lib/nftban structure
    mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,panels,metrics,stats}
    mkdir -p /var/lib/nftban/reports/auditors
    mkdir -p /var/lib/nftban/stats/{history,profiles}
    mkdir -p /var/lib/nftban/queue/{pending,work,dlq}
    mkdir -p /var/lib/nftban/{mailspool,pro}

    # Runtime directories
    mkdir -p /var/log/nftban
    mkdir -p /var/log/nftban/metrics
    mkdir -p /var/cache/nftban
    mkdir -p /run/nftban
    mkdir -p /run/nftban-ui
}

# Create manual whitelist file if missing
_install_configs_manual_whitelist() {
    [[ -f /etc/nftban/whitelist.d/99-manual.conf ]] && return 0
    cat > /etc/nftban/whitelist.d/99-manual.conf << 'MANUAL_WL'
# =============================================================================
# NFTBan Manual Whitelist - User-Added IPs
# =============================================================================
# File: /etc/nftban/whitelist.d/99-manual.conf
#
# PURPOSE:
#   This file stores IPs manually whitelisted by the administrator using:
#     nftban whitelist add <ip> [comment]
#
# FORMAT:
#   <ip_address>   # Optional comment
#
# EXAMPLES:
#   192.168.1.100        # Office gateway
#   10.0.0.0/8           # Internal network
#   2001:db8::1          # IPv6 host
#
# NOTES:
#   - This file is managed by nftban CLI commands
#   - Manual edits are preserved during updates
#   - IPs here are NEVER blocked by nftban
#   - Use 'nftban whitelist list' to view all whitelisted IPs
#   - Use 'nftban whitelist remove <ip>' to remove entries
#
# =============================================================================

MANUAL_WL
}

# Create manual blacklist file if missing
_install_configs_manual_blacklist() {
    [[ -f /etc/nftban/blacklist.d/99-manual.conf ]] && return 0
    cat > /etc/nftban/blacklist.d/99-manual.conf << 'MANUAL_BL'
# =============================================================================
# NFTBan Manual Blacklist - User-Banned IPs
# =============================================================================
# File: /etc/nftban/blacklist.d/99-manual.conf
#
# PURPOSE:
#   This file stores IPs manually banned by the administrator using:
#     nftban ban <ip> [duration] [reason]
#
# FORMAT:
#   <ip_address>   # Optional comment with reason/date
#
# EXAMPLES:
#   203.0.113.50         # Brute force attacker - 2024-01-15
#   198.51.100.0/24      # Spam network
#   2001:db8:bad::0/48   # Malicious IPv6 range
#
# NOTES:
#   - This file is managed by nftban CLI commands
#   - Manual edits are preserved during updates
#   - IPs here are ALWAYS blocked by nftban
#   - Use 'nftban status' to view all banned IPs
#   - Use 'nftban unban <ip>' to remove entries
#
# =============================================================================

MANUAL_BL
}

# Set ownership and permissions on all directories
_install_configs_ownership() {
    # /etc/nftban ownership
    chown root:nftban /etc/nftban && chmod 750 /etc/nftban
    chown root:nftban /etc/nftban/conf.d && chmod 750 /etc/nftban/conf.d
    chown root:root /etc/nftban/distros && chmod 755 /etc/nftban/distros

    # v1.38.0: BUG-006 fix — use FHS spec as single source of truth for ownership
    # Source the generated FHS spec (contains NFTBAN_FHS_DIRECTORIES associative array)
    local fhs_spec="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_fhs_spec.sh"
    if [[ -f "$fhs_spec" ]]; then
        # shellcheck source=/dev/null
        source "$fhs_spec"
        # Apply ownership/permissions from FHS spec for all directories that exist
        local dir spec mode owner group
        for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
            [[ ! -d "$dir" ]] && continue
            spec="${NFTBAN_FHS_DIRECTORIES[$dir]}"
            mode="${spec%%|*}"; spec="${spec#*|}"
            owner="${spec%%|*}"; spec="${spec#*|}"
            group="${spec%%|*}"
            chown "${owner}:${group}" "$dir" 2>/dev/null || true
            chmod "$mode" "$dir" 2>/dev/null || true
        done
    else
        # Fallback: hardcoded list (kept in sync with fhs-spec.yaml v1.4.0)
        # Config subdirs
        for subdir in whitelist.d blacklist.d ports.d rules.d suricata patterns.d connectors nftables.d ssl; do
            [ -d "/etc/nftban/$subdir" ] && chown root:nftban "/etc/nftban/$subdir" && chmod 750 "/etc/nftban/$subdir"
        done
        for subdir in botscan ddos portscan login panels rbl geoban geoip botguard tunnel; do
            [ -d "/etc/nftban/conf.d/$subdir" ] && chown root:nftban "/etc/nftban/conf.d/$subdir" && chmod 750 "/etc/nftban/conf.d/$subdir"
        done
        for subdir in suricata/profiles suricata/config suricata/rules suricata/cache suricata/state suricata/state/last-good; do
            [ -d "/etc/nftban/$subdir" ] && chown root:nftban "/etc/nftban/$subdir" && chmod 750 "/etc/nftban/$subdir"
        done
        [ -d "/etc/nftban/patterns.d/botscan" ] && chown root:nftban "/etc/nftban/patterns.d/botscan" && chmod 750 "/etc/nftban/patterns.d/botscan"

        # /var/lib/nftban ownership
        chown root:nftban /var/lib/nftban && chmod 750 /var/lib/nftban
        chown nftban:nftban /var/lib/nftban/reports && chmod 750 /var/lib/nftban/reports
        [ -d "/var/lib/nftban/reports/auditors" ] && chown root:nftban-auditor /var/lib/nftban/reports/auditors && chmod 770 /var/lib/nftban/reports/auditors
        for subdir in banned whitelist feeds geoip config state panels metrics stats queue mailspool \
                      snapshots exports botguard tunnel analytics login portscan recorder staging \
                      suricata watchdog reports/archive reports/baseline reports/watchdog; do
            [ -d "/var/lib/nftban/$subdir" ] && chown nftban:nftban "/var/lib/nftban/$subdir" && chmod 750 "/var/lib/nftban/$subdir"
        done
        for subdir in backup update-backups pro; do
            [ -d "/var/lib/nftban/$subdir" ] && chown root:nftban "/var/lib/nftban/$subdir" && chmod 750 "/var/lib/nftban/$subdir"
        done
    fi

    # Fix feed files ownership
    find /var/lib/nftban/feeds -maxdepth 1 -type f -name "*.txt" -exec chown nftban:nftban {} \; 2>/dev/null || true
    find /var/lib/nftban/feeds -maxdepth 1 -type f -name "*.txt" -exec chmod 640 {} \; 2>/dev/null || true

    # Runtime directories
    chown nftban:nftban /var/log/nftban && chmod 750 /var/log/nftban
    chown nftban:nftban /var/cache/nftban && chmod 755 /var/cache/nftban
    chown nftban:nftban /run/nftban && chmod 755 /run/nftban
    find /run/nftban -maxdepth 1 -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
    chown root:nftban /run/nftban-ui && chmod 750 /run/nftban-ui

    ok "Directory ownership configured"
}

# Install a single config file (if not exists - don't overwrite content)
_install_config_file() {
    local src="$1" dst="$2" mode="$3" owner="${4:-root:nftban}"

    # Validate source exists (catches build issues early)
    if [[ ! -f "$src" ]]; then
        warn "Source config not found: $src (skipping)"
        return 0
    fi

    if [[ ! -f "$dst" ]]; then
        cp -f "$src" "$dst"
        chmod "$mode" "$dst"
        chown "$owner" "$dst"
        ok "Installed: $dst"
    else
        chmod "$mode" "$dst"
        chown "$owner" "$dst"
        ok "Config exists (permissions fixed): $dst"
    fi
}

# Install directory of config files
_install_config_dir() {
    local src_dir="$1" dst_dir="$2" glob="$3" mode="$4" owner="${5:-root:nftban}"
    local count=0

    [[ ! -d "$src_dir" ]] && return 0

    for src_file in "$src_dir"/$glob; do
        [[ -f "$src_file" ]] || continue
        local name
        name=$(basename "$src_file")
        if [[ ! -f "$dst_dir/$name" ]]; then
            cp -f "$src_file" "$dst_dir/$name"
        fi
        chmod "$mode" "$dst_dir/$name"
        chown "$owner" "$dst_dir/$name"
        ((count++))
    done

    [[ $count -gt 0 ]] && ok "Installed/fixed $count files in $dst_dir"
}

# Install all module configurations
_install_configs_modules() {
    # Main config
    _install_config_file "$SCRIPT_DIR/install/config/nftban.conf" "/etc/nftban/nftban.conf" "644"

    # Distro configs (always overwrite - system files)
    if [[ -d "$SCRIPT_DIR/etc/nftban/distros" ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/distros/"*.conf /etc/nftban/distros/ 2>/dev/null || true
        chmod 644 /etc/nftban/distros/*.conf 2>/dev/null || true
        chown root:root /etc/nftban/distros/*.conf 2>/dev/null || true
        local count
        count=$(ls -1 /etc/nftban/distros/*.conf 2>/dev/null | wc -l)
        ok "Installed $count distro config files"
    fi

    # Suricata profiles
    if [[ -d "$SCRIPT_DIR/etc/nftban/suricata/profiles" ]]; then
        cp -f "$SCRIPT_DIR/etc/nftban/suricata/profiles/"*.yaml /etc/nftban/suricata/profiles/ 2>/dev/null || true
        chmod 644 /etc/nftban/suricata/profiles/*.yaml 2>/dev/null || true
        chown root:nftban /etc/nftban/suricata/profiles/*.yaml 2>/dev/null || true
        local count
        count=$(ls -1 /etc/nftban/suricata/profiles/*.yaml 2>/dev/null | wc -l)
        ok "Installed $count Suricata profile templates"
    fi

    # Suricata rule config files
    if [[ -d "$SCRIPT_DIR/etc/nftban/suricata/rules" ]]; then
        _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/rules/disable.conf" "/etc/nftban/suricata/rules/disable.conf" "664"
        _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/rules/enable.conf" "/etc/nftban/suricata/rules/enable.conf" "664"
        _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/rules/categories.enabled" "/etc/nftban/suricata/rules/categories.enabled" "664"
        _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/rules/local.rules" "/etc/nftban/suricata/rules/local.rules" "664"
        chown root:nftban /etc/nftban/suricata/rules/disable.conf
        chown root:nftban /etc/nftban/suricata/rules/enable.conf
        chown root:nftban /etc/nftban/suricata/rules/categories.enabled
        chown root:nftban /etc/nftban/suricata/rules/local.rules
    fi

    # Suricata directories
    chown root:nftban /etc/nftban/suricata/rules
    chmod 775 /etc/nftban/suricata/rules
    mkdir -p /etc/nftban/suricata/state/last-good
    chown root:nftban /etc/nftban/suricata/state
    chown root:nftban /etc/nftban/suricata/state/last-good
    chmod 770 /etc/nftban/suricata/state
    chmod 770 /etc/nftban/suricata/state/last-good

    # Suricata YAML overlay
    _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/suricata.yaml.overlay" "/etc/nftban/suricata/suricata.yaml.overlay" "664"
    chown root:nftban /etc/nftban/suricata/suricata.yaml.overlay

    # Suricata profile configuration (controls which profile is active)
    _install_config_file "$SCRIPT_DIR/etc/nftban/suricata/config/profile.conf" "/etc/nftban/suricata/config/profile.conf" "664"
    chown root:nftban /etc/nftban/suricata/config/profile.conf

    # Core configs
    _install_config_file "$SCRIPT_DIR/install/config/feeds.conf" "/etc/nftban/conf.d/feeds.conf" "644"
    _install_config_file "$SCRIPT_DIR/install/config/conf.d/watchdog.conf" "/etc/nftban/conf.d/watchdog.conf" "644"
    _install_config_file "$SCRIPT_DIR/install/config/update.conf" "/etc/nftban/update.conf" "640"

    # Module configs
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/mail.conf" "/etc/nftban/conf.d/mail.conf" "644"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/stats.conf" "/etc/nftban/conf.d/stats.conf" "644"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/banner.conf" "/etc/nftban/conf.d/banner.conf" "644"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/trust.conf" "/etc/nftban/conf.d/trust.conf" "640"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/botscan/main.conf" "/etc/nftban/conf.d/botscan/main.conf" "640"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/geoban/main.conf" "/etc/nftban/conf.d/geoban/main.conf" "640"
    _install_config_file "$SCRIPT_DIR/etc/nftban/conf.d/geoip/main.conf" "/etc/nftban/conf.d/geoip/main.conf" "640"

    # Exporter configs
    _install_config_file "$SCRIPT_DIR/install/config/conf.d/zabbix.conf" "/etc/nftban/conf.d/zabbix.conf" "640"
    _install_config_file "$SCRIPT_DIR/install/config/conf.d/connectors.conf" "/etc/nftban/conf.d/connectors.conf" "640"
    _install_config_file "$SCRIPT_DIR/install/config/conf.d/metrics.conf" "/etc/nftban/conf.d/metrics.conf" "640"
    _install_config_file "$SCRIPT_DIR/install/config/conf.d/persistent.conf" "/etc/nftban/conf.d/persistent.conf" "640"

    # Pattern files
    _install_config_dir "$SCRIPT_DIR/etc/nftban/patterns.d/botscan" "/etc/nftban/patterns.d/botscan" "*.patterns" "640"

    # Module directories
    for module in login ddos portscan rbl; do
        _install_config_dir "$SCRIPT_DIR/etc/nftban/conf.d/$module" "/etc/nftban/conf.d/$module" "*.conf" "640"
        _install_config_dir "$SCRIPT_DIR/etc/nftban/conf.d/$module" "/etc/nftban/conf.d/$module" "*.local" "640"
    done
}

# Install panel configurations
_install_configs_panels() {
    local panels_src="$SCRIPT_DIR/etc/nftban/conf.d/panels"
    local panels_dst="/etc/nftban/conf.d/panels"

    [[ ! -d "$panels_src" ]] && return 0

    for panel_dir in "$panels_src"/*/; do
        [[ -d "$panel_dir" ]] || continue
        local panel_name
        panel_name=$(basename "$panel_dir")
        mkdir -p "$panels_dst/$panel_name"
        chown root:nftban "$panels_dst/$panel_name"
        chmod 750 "$panels_dst/$panel_name"

        for panel_conf in "$panel_dir"*.conf; do
            [[ -f "$panel_conf" ]] || continue
            local conf_name
            conf_name=$(basename "$panel_conf")
            if [[ ! -f "$panels_dst/$panel_name/$conf_name" ]]; then
                cp -f "$panel_conf" "$panels_dst/$panel_name/$conf_name"
                chmod 640 "$panels_dst/$panel_name/$conf_name"
                chown root:nftban "$panels_dst/$panel_name/$conf_name"
            fi
        done
    done

    local panel_count
    panel_count=$(find "$panels_dst" -name "*.conf" 2>/dev/null | wc -l)
    [[ $panel_count -gt 0 ]] && ok "Installed $panel_count panel config files"
}

# =============================================================================
# MAIN INSTALL CONFIGS FUNCTION
# =============================================================================

install_configs() {
    log "Installing Configuration Files..."

    _install_configs_directories
    _install_configs_manual_whitelist
    _install_configs_manual_blacklist
    _install_configs_ownership
    _install_configs_modules
    _install_configs_panels

    # Install GUI groups config
    _install_config_file "$SCRIPT_DIR/install/config/allowed-gui-groups" "/etc/nftban/allowed-gui-groups" "644"

    # Install PAM configuration
    install_pam || warn "PAM configuration failed (non-critical)"

    # Install templates
    install_templates

    ok "Configuration files installed"
    return 0
}

install_templates() {
    log "Installing Templates..."

    mkdir -p /usr/share/nftban/templates/{mail,reports,zabbix}
    mkdir -p /usr/share/nftban/dashboards/grafana

    # Install templates
    if [[ -d "$SCRIPT_DIR/install/share/nftban/templates" ]]; then
        cp -r "$SCRIPT_DIR/install/share/nftban/templates/"* /usr/share/nftban/templates/ 2>/dev/null || true
        local template_count
        template_count=$(find /usr/share/nftban/templates -type f -name "*.html" 2>/dev/null | wc -l)
        ok "Installed $template_count templates"
    fi

    # Install Zabbix templates
    if [[ -d "$SCRIPT_DIR/share/templates/zabbix" ]]; then
        cp -f "$SCRIPT_DIR/share/templates/zabbix/"* /usr/share/nftban/templates/zabbix/ 2>/dev/null || true
        ok "Installed Zabbix templates"
    fi

    # Install Grafana dashboards
    if [[ -d "$SCRIPT_DIR/share/dashboards/grafana" ]]; then
        cp -f "$SCRIPT_DIR/share/dashboards/grafana/"* /usr/share/nftban/dashboards/grafana/ 2>/dev/null || true
        ok "Installed Grafana dashboards"
    fi

    # Set permissions
    chown root:root /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates
    chmod 755 /usr/share/nftban/templates/mail
    chmod 755 /usr/share/nftban/templates/reports
    chmod 755 /usr/share/nftban/templates/zabbix 2>/dev/null || true
    find /usr/share/nftban/templates -type f -name "*.html" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -name "*.yaml" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -name "*.yml" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -name "*.xml" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -name "*.md" -exec chmod 644 {} \;
    find /usr/share/nftban/templates -type f -exec chown root:root {} \;
    find /usr/share/nftban/templates -type d -exec chown root:root {} \;

    # Install spec files
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

    # Install commands registry
    log "Installing commands registry..."
    if [[ -f "$SCRIPT_DIR/commands.registry.yml" ]]; then
        mkdir -p /usr/share/nftban
        cp -f "$SCRIPT_DIR/commands.registry.yml" /usr/share/nftban/commands.registry.yml
        chmod 644 /usr/share/nftban/commands.registry.yml
        chown root:root /usr/share/nftban/commands.registry.yml
        ok "Installed: /usr/share/nftban/commands.registry.yml"
    fi

    # Install man pages
    if [[ -f "$SCRIPT_DIR/install/man/man8/nftban.8" ]]; then
        mkdir -p /usr/share/man/man8
        install -m 0644 "$SCRIPT_DIR/install/man/man8/nftban.8" /usr/share/man/man8/
        ok "Installed man page -> /usr/share/man/man8/nftban.8"
    fi
    if [[ -f "$SCRIPT_DIR/install/man/man8/nftban-suricata.8" ]]; then
        install -m 0644 "$SCRIPT_DIR/install/man/man8/nftban-suricata.8" /usr/share/man/man8/
        ok "Installed man page -> /usr/share/man/man8/nftban-suricata.8"
    fi
    if command -v mandb &>/dev/null; then
        mandb -q 2>/dev/null || true
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

    if ! nftban_distro_init; then
        warn "Failed to detect distribution, skipping dependency installation"
        return 0
    fi

    local pkg_type="${DISTRO_PKGMGR[type]}"
    local install_cmd="${DISTRO_PKGMGR[install_cmd]}"
    local update_cmd="${DISTRO_PKGMGR[update_cmd]}"

    if [[ -z "$install_cmd" ]]; then
        warn "No package manager configured, skipping dependency installation"
        return 0
    fi

    log "Detected: ${DISTRO_INFO[name]} ${DISTRO_INFO[version]} (${pkg_type})"
    echo ""

    log "Updating package cache..."
    # R16: Use array expansion instead of eval for security (v1.19.12)
    local -a update_arr
    read -ra update_arr <<< "$update_cmd"
    if "${update_arr[@]}" >/dev/null 2>&1; then
        ok "Package cache updated"
    else
        warn "Package cache update failed (non-critical)"
    fi

    local required_packages=(nftables jq socat curl wget)

    log "Installing required packages..."
    local installed=0 failed=0

    for pkg_key in "${required_packages[@]}"; do
        local pkg_name="${DISTRO_PACKAGES[$pkg_key]}"

        if [[ -z "$pkg_name" ]]; then
            warn "Package '$pkg_key' not defined for this distro"
            failed=$((failed + 1))
            continue
        fi

        if command -v "$pkg_key" &>/dev/null || dpkg -l "$pkg_name" 2>/dev/null | grep -q "^ii"; then
            echo "  $pkg_name (already installed)"
            continue
        fi

        echo "  Installing $pkg_name..."
        # R16: Use array expansion instead of eval for security (v1.19.12)
        local -a install_arr
        read -ra install_arr <<< "$install_cmd"
        if "${install_arr[@]}" "$pkg_name" >/dev/null 2>&1; then
            ok "  $pkg_name"
            installed=$((installed + 1))
        else
            warn "  $pkg_name (failed)"
            failed=$((failed + 1))
        fi
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        warn "Some packages failed to install ($failed failed)"
    else
        ok "All dependencies installed ($installed new packages)"
    fi

    return 0
}
