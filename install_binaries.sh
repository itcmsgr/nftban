#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Installation Script (Binaries Module)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Binary and library installation functions
#
# meta:name="install_binaries"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Install Go binaries, CLI, shell libraries, users/groups"
# meta:parent="install.sh"
# meta:created_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="cp,chmod,chown,mkdir,useradd,groupadd"
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
[[ -n "${_NFTBAN_INSTALL_BINARIES_LOADED:-}" ]] && return 0
_NFTBAN_INSTALL_BINARIES_LOADED=1

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

    if ! check_binary "$BIN_DIR/nftban-core"; then
        warn "Core binaries not found in $BIN_DIR/"
        warn "Skipping binary installation (CLI will use bash fallbacks)"
        warn "To build binaries: run ./build.sh first"
        return 0
    fi

    mkdir -p "$CORE_BIN_DIR"

    # Install nftban-core
    log "Installing nftban-core..."
    cp -f "$BIN_DIR/nftban-core" "$CORE_INSTALL_PATH"
    chmod 755 "$CORE_INSTALL_PATH"
    chown root:root "$CORE_INSTALL_PATH"
    ok "Installed: $CORE_INSTALL_PATH"

    # Set capabilities for nftban-core
    if command -v setcap &>/dev/null; then
        setcap 'cap_net_admin+ep' "$CORE_INSTALL_PATH" 2>/dev/null && \
            ok "CAP_NET_ADMIN set on nftban-core" || \
            warn "Could not set CAP_NET_ADMIN on nftban-core"

        # v1.59.0 SEC-1: Removed setcap on /usr/sbin/nft — granting CAP_NET_ADMIN
        # to system nft binary affects ALL users, not just nftban (privilege escalation).
        # nftban CLI runs as root, nftband runs as root service, nftban-core has its own cap.
    else
        warn "setcap not found - install libcap for capability support"
    fi

    # Install nftband (single-writer daemon)
    if [[ -f "$BIN_DIR/nftband" ]]; then
        log "Installing nftband (single nftables writer daemon)..."
        cp -f "$BIN_DIR/nftband" "$CORE_BIN_DIR/nftband"
        chmod 755 "$CORE_BIN_DIR/nftband"
        chown root:root "$CORE_BIN_DIR/nftband"
        ok "Installed: $CORE_BIN_DIR/nftband"

        if command -v setcap &>/dev/null; then
            setcap 'cap_net_admin+ep' "$CORE_BIN_DIR/nftband" 2>/dev/null && \
                ok "CAP_NET_ADMIN set on nftband" || \
                warn "Could not set CAP_NET_ADMIN on nftband"
        fi
    else
        warn "nftband binary not found in $BIN_DIR/"
    fi

    return 0
}

install_cli() {
    log "Installing CLI..."

    # Clean up OLD location from pre-1.8.13 DEB packages
    if [[ -f "/usr/bin/nftban" ]] && [[ ! -L "/usr/bin/nftban" ]]; then
        rm -f "/usr/bin/nftban"
        ok "Removed old CLI from /usr/bin/nftban (migrated to /usr/sbin)"
    fi

    if [[ -f "/usr/sbin/nftban" ]] && [[ ! -L "/usr/sbin/nftban" ]]; then
        rm -f "/usr/sbin/nftban"
    fi

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

    # Install helper scripts
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
    ok "Installed helper scripts -> $sbin_dir"

    return 0
}

install_libraries() {
    log "Installing Shell Libraries..."

    mkdir -p "$LIB_DIR"/{lib,cli,core,exporters,cron,helpers,setup,tests}

    # Safety: Remove duplicate nested nftban directories
    if [[ -n "$LIB_DIR" ]] && [[ -d "$LIB_DIR/lib/nftban" ]]; then
        rm -rf "$LIB_DIR/lib/nftban"
    fi

    # Remove immutable flag from nft_schema.sh before overwriting
    if [[ -f "$LIB_DIR/lib/nft_schema.sh" ]]; then
        chattr -i "$LIB_DIR/lib/nft_schema.sh" 2>/dev/null || true
    fi

    # Copy libraries from source to target
    cp -r "$SCRIPT_DIR/cli/lib/nftban/lib/"* "$LIB_DIR/lib/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/cli/"* "$LIB_DIR/cli/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/core/"* "$LIB_DIR/core/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/exporters/"* "$LIB_DIR/exporters/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/cron/"* "$LIB_DIR/cron/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/helpers/"* "$LIB_DIR/helpers/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/cli/lib/nftban/setup/"* "$LIB_DIR/setup/" 2>/dev/null || true

    # Copy systemd helper scripts
    if [[ -f "$SCRIPT_DIR/install/helpers/firewall-init-with-delay.sh" ]]; then
        install -m 0755 -o root -g root \
            "$SCRIPT_DIR/install/helpers/firewall-init-with-delay.sh" \
            "$LIB_DIR/helpers/firewall-init-with-delay.sh"
    fi

    # Copy test scripts
    cp -r "$SCRIPT_DIR/cli/lib/nftban/tests/"* "$LIB_DIR/tests/" 2>/dev/null || true

    # Copy root-level library files
    cp "$SCRIPT_DIR/cli/lib/nftban/nftban_help.sh" "$LIB_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/cli/lib/nftban/helpers/json_output.sh" "$LIB_DIR/" 2>/dev/null || true

    # Copy README explaining install-mirror layout
    cp "$SCRIPT_DIR/cli/lib/nftban/README.md" "$LIB_DIR/" 2>/dev/null || true

    # Copy VERSION file
    if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
        install -m 0644 -o root -g nftban "$SCRIPT_DIR/VERSION" "$LIB_DIR/VERSION"
    fi

    # Set permissions
    find "$LIB_DIR" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$LIB_DIR" -type f -name "*.conf" -exec chmod 644 {} \;
    find "$LIB_DIR" -type d -exec chmod 755 {} \;

    if [[ -d "$LIB_DIR/bin" ]]; then
        find "$LIB_DIR/bin" -type f -exec chmod 755 {} \;
        find "$LIB_DIR/bin" -type f -exec chown root:root {} \;
    fi

    # Set ownership
    chown root:nftban "$LIB_DIR"
    find "$LIB_DIR" -type d -exec chown root:nftban {} \;
    find "$LIB_DIR" -type f ! -path "$LIB_DIR/bin/*" -exec chown root:nftban {} \;

    ok "Shell libraries installed to $LIB_DIR"
    return 0
}

install_completion() {
    log "Installing Bash Completion..."

    mkdir -p "$(dirname "$COMPLETION_PATH")"

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

    if [[ -f "$SCRIPT_DIR/install/nftables/nftables.conf" ]]; then
        cp -f "$SCRIPT_DIR/install/nftables/nftables.conf" /etc/nftables.conf
        chmod 644 /etc/nftables.conf
        chown root:root /etc/nftables.conf
        ok "Installed: /etc/nftables.conf"
    else
        error "NFTables config not found: $SCRIPT_DIR/install/nftables/nftables.conf"
        return 1
    fi

    # Create symlink for RHEL-family distros
    if [[ "${DISTRO_INFO[family]:-}" == "rhel" ]] || [[ -f /etc/redhat-release ]]; then
        log "Creating symlink for RHEL-family distro..."
        mkdir -p /etc/sysconfig
        ln -sf /etc/nftables.conf /etc/sysconfig/nftables.conf
        ok "Created symlink: /etc/sysconfig/nftables.conf -> /etc/nftables.conf"
    fi

    # Install nftables.d directory
    mkdir -p /etc/nftban/nftables.d
    if [[ -f "$SCRIPT_DIR/install/nftables/nftables.d/00-placeholder.nft" ]]; then
        cp -f "$SCRIPT_DIR/install/nftables/nftables.d/00-placeholder.nft" /etc/nftban/nftables.d/
        chmod 644 /etc/nftban/nftables.d/00-placeholder.nft
        ok "Installed: /etc/nftban/nftables.d/00-placeholder.nft"
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

    # Remove obsolete Polkit rules
    rm -f /etc/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null && ok "Removed: 10-nftban-core.rules"
    rm -f /etc/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null && ok "Removed: 20-nftban-suricata.rules"
    rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null && ok "Removed: 50-nftban-auth.rules"
    rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules.in 2>/dev/null && ok "Removed: 50-nftban-auth.rules.in"
    rm -f /etc/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null && ok "Removed: 50-nftban-v030.rules"
    rm -f /etc/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null && ok "Removed: 60-nftban-services.rules"
    rm -f /usr/share/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null
    rm -f /usr/share/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null

    # Remove obsolete Polkit actions
    rm -f /usr/share/polkit-1/actions/com.nftban.suricata.policy 2>/dev/null && ok "Removed: com.nftban.suricata.policy"

    # Remove obsolete port-status rules
    rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null && ok "Removed: 50-nftban-port-status.rules"
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

    # DEPRECATED: nftban-cli group is no longer used
    # Admin access now uses 'nftban' group directly
    # Keeping for backwards compatibility only
    if ! getent group nftban-cli >/dev/null 2>&1; then
        # Skip creation - use 'nftban' group instead
        warn "nftban-cli group deprecated - use 'nftban' group for admin access"
    else
        warn "nftban-cli group exists (deprecated) - use 'nftban' group instead"
    fi

    # Create nftban-auditor group
    if ! getent group nftban-auditor >/dev/null 2>&1; then
        groupadd --system nftban-auditor
        ok "Created group: nftban-auditor"
    else
        ok "Group already exists: nftban-auditor"
    fi

    # Create nftban-panel group
    if ! getent group nftban-panel >/dev/null 2>&1; then
        groupadd --system nftban-panel
        ok "Created group: nftban-panel"
    else
        ok "Group already exists: nftban-panel"
    fi

    # Backward compatibility: Migrate nftban-auditors -> nftban-auditor
    if getent group nftban-auditors >/dev/null 2>&1; then
        log "Migrating nftban-auditors -> nftban-auditor group..."
        for user in $(getent group nftban-auditors | cut -d: -f4 | tr ',' ' '); do
            if [ -n "$user" ]; then
                usermod -aG nftban-auditor "$user" 2>/dev/null || warn "Could not migrate user: $user"
                ok "Migrated user to nftban-auditor: $user"
            fi
        done
    fi

    # Add root to nftban group
    if ! id -nG root | grep -qw nftban 2>/dev/null; then
        usermod -aG nftban root 2>/dev/null || warn "Could not add root to nftban"
        ok "Added root to nftban group"
    fi

    echo ""
    log "Groups Summary (v1.0.19: 3-group RBAC model):"
    echo "  nftban         - Operators (CLI, Web GUI, full service management)"
    echo "  nftban-auditor - Auditors (read-only: logs, reports, status queries)"
    echo "  nftban-panel   - Panel integration (limited reload, read-only data)"
    echo ""

    # DirectAdmin: Add nftban to mysyslog group for logger access
    if [[ -d /usr/local/directadmin ]]; then
        if getent group mysyslog &>/dev/null; then
            if ! id -nG nftban 2>/dev/null | grep -qw mysyslog; then
                usermod -a -G mysyslog nftban 2>/dev/null && \
                    ok "DirectAdmin: Added nftban to mysyslog group (syslog access)"
            fi
        fi
    fi

    ok "User and group setup complete"

    return 0
}

install_pam() {
    log "Installing PAM Configuration..."

    if [[ -f "$SCRIPT_DIR/install/pam/nftban-ui" ]]; then
        cp -f "$SCRIPT_DIR/install/pam/nftban-ui" /etc/pam.d/nftban-ui
        chmod 644 /etc/pam.d/nftban-ui
        chown root:root /etc/pam.d/nftban-ui
        ok "Installed: /etc/pam.d/nftban-ui"
    else
        error "PAM config not found: $SCRIPT_DIR/install/pam/nftban-ui"
        return 1
    fi

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
