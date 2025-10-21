#!/usr/bin/env bash

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027


# Version: 0.9.2
# Location: lib/installer/installer_verification.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# =============================================================================
# NFTBan Installer - Verification Module
# Provides: Installation verification, repair, status reporting
# =============================================================================

[[ -n "${INSTALLER_VERIFICATION_LOADED:-}" ]] && return 0
readonly INSTALLER_VERIFICATION_LOADED=1

# =============================================================================
# VERIFICATION
# =============================================================================

installer_cmd_verify() {
    installer_log_info "Verifying nftban installation..."
    
    local errors=0
    
    # Check installation directory
    if [[ ! -d "$INSTALL_DIR" ]]; then
        installer_log_error "Installation directory not found: $INSTALL_DIR"
        ((errors++))
    fi
    
    # Check core module
    if [[ ! -f "${INSTALL_DIR}/lib/nftban_core.sh" ]]; then
        installer_log_error "Core module missing"
        ((errors++))
    fi
    
    # Check essential modules
    local required_modules=(
        "nftban_nftables_module.sh"
        "nftban_whitelist_module.sh"
        "nftban_blacklist_module.sh"
    )
    
    for module in "${required_modules[@]}"; do
        if [[ ! -f "${INSTALL_DIR}/lib/$module" ]]; then
            installer_log_error "Missing module: $module"
            ((errors++))
        fi
    done
    
    # Check CLI
    if [[ ! -x "/usr/local/bin/nftban" ]]; then
        installer_log_error "CLI not found or not executable"
        ((errors++))
    fi
    
    # Check dependencies
    installer_verify_dependencies || ((errors++))
    
    # Results
    if [[ $errors -eq 0 ]]; then
        installer_log_success "Verification passed: Installation is healthy"
        return 0
    else
        installer_log_error "Verification failed: $errors error(s) found"
        installer_log_info "Run 'nftban installer repair' to fix issues"
        return 1
    fi
}

# =============================================================================
# REPAIR
# =============================================================================

installer_cmd_repair() {
    installer_log_info "Repairing nftban installation..."
    
    if ! installer_confirm "This will attempt to repair the installation. Continue?"; then
        installer_log_info "Repair cancelled"
        return 0
    fi
    
    # Recreate directory structure
    installer_create_directories
    
    # Fix permissions
    installer_log_info "Fixing permissions..."
    installer_set_permissions
    
    # Recreate CLI
    installer_setup_cli
    
    # Recreate symlinks
    installer_create_symlinks
    
    # Rebuild search index if possible
    if [[ -f "${INSTALL_DIR}/lib/nftban_core.sh" ]]; then
        # shellcheck disable=SC1091
        source "${INSTALL_DIR}/lib/nftban_core.sh" 2>/dev/null || true
        
        if command -v nftban_search_build_index >/dev/null 2>&1; then
            installer_log_info "Rebuilding search index..."
            nftban_search_build_index 2>/dev/null || installer_log_warn "Failed to rebuild search index"
        fi
    fi
    
    installer_log_success "Repair complete"
    
    # Verify after repair
    installer_cmd_verify
}

# =============================================================================
# STATUS
# =============================================================================

installer_cmd_status() {
    echo ""
    echo "================================================================="
    echo "  NFTBan Installation Status"
    echo "================================================================="
    echo ""
    
    # Installation info
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${C_GREEN}✓${C_RESET} Installation directory: $INSTALL_DIR"
        
        # Version
        if [[ -f "$VERSION_FILE" ]]; then
            local version
            version=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
            echo "  Version: $version"
        fi
        
        # Installation date
        if [[ -f "$INSTALL_STATE" ]]; then
            # shellcheck disable=SC1090
            source "$INSTALL_STATE" 2>/dev/null || true
            [[ -n "${INSTALL_DATE:-}" ]] && echo "  Installed: $INSTALL_DATE"
            [[ -n "${INSTALLER_METHOD:-}" ]] && echo "  Method: $INSTALLER_METHOD"
        fi
    else
        echo -e "${C_RED}✗${C_RESET} Installation directory: NOT FOUND"
        echo ""
        echo "nftban is not installed. Install with:"
        echo "  sudo nftban installer install --github"
        return 1
    fi
    
    echo ""
    
    # Modules
    echo "Modules:"
    local modules=(
        "nftban_core.sh:Core"
        "nftban_nftables_module.sh:nftables"
        "nftban_whitelist_module.sh:Whitelist"
        "nftban_blacklist_module.sh:Blacklist"
        "nftban_fail2ban_module.sh:Fail2ban"
        "nftban_search_module.sh:Search"
        "nftban_cloudflare_module.sh:Cloudflare"
        "nftban_geo_module.sh:GEO"
        "nftban_stats_module.sh:Stats"
        "nftban_port_module.sh:Port"
        "nftban_template_module.sh:Template"
        "nftban_ipprotect_module.sh:IP Protect"
        "nftban_ratelimit_module.sh:Rate Limit"
        "nftban_autorebuild_module.sh:Auto-Rebuild"
        "nftban_login_monitor_module.sh:Login Monitor"
        "nftban_maintenance_module.sh:Maintenance"
        "nftban_geoip_module.sh:GeoIP"
    )
    
    local module_count=0
    for module in "${modules[@]}"; do
        IFS=':' read -r file name <<< "$module"
        if [[ -f "${INSTALL_DIR}/lib/$file" ]]; then
            echo -e "  ${C_GREEN}✓${C_RESET} $name"
            ((module_count++))
        else
            echo -e "  ${C_RED}✗${C_RESET} $name"
        fi
    done
    
    echo ""
    echo "  Total: $module_count/${#modules[@]} modules"
    echo ""
    
    # CLI
    if [[ -x "/usr/local/bin/nftban" ]]; then
        echo -e "${C_GREEN}✓${C_RESET} CLI: /usr/local/bin/nftban"
    else
        echo -e "${C_RED}✗${C_RESET} CLI: NOT FOUND"
    fi
    
    echo ""
    
    # Dependencies
    echo "Dependencies:"
    local deps=(
        "nft:nftables"
        "fail2ban-client:fail2ban"
        "whois:whois"
        "ipcalc:ipcalc"
        "sipcalc:sipcalc"
        "git:git"
    )
    
    local dep_count=0
    for dep in "${deps[@]}"; do
        IFS=':' read -r cmd name <<< "$dep"
        if installer_command_exists "$cmd"; then
            echo -e "  ${C_GREEN}✓${C_RESET} $name"
            ((dep_count++))
        else
            echo -e "  ${C_YELLOW}!${C_RESET} $name (optional)"
        fi
    done
    
    echo ""
    
    # Git repository status
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        echo "Git Repository:"
        echo -e "  ${C_GREEN}✓${C_RESET} Initialized"
        local branch
        branch=$(cd "$INSTALL_DIR" && git branch --show-current 2>/dev/null || echo "unknown")
        echo "  Branch: $branch"
        
        local last_commit
        last_commit=$(cd "$INSTALL_DIR" && git log -1 --format="%h - %s (%ar)" 2>/dev/null || echo "unknown")
        echo "  Last commit: $last_commit"
    else
        echo "Git Repository:"
        echo "  Not a git installation (installed via ZIP)"
    fi
    
    echo ""
    echo "================================================================="
}

# =============================================================================
# COMMAND FUNCTIONS
# =============================================================================

installer_cmd_install() {
    installer_parse_args "$@"
    installer_check_root
    
    installer_log_info "Starting installation..."
    installer_log_info "Method: $INSTALLER_METHOD"
    
    # Check if already installed
    if [[ -d "$INSTALL_DIR" && "$INSTALLER_FORCE" == "false" ]]; then
        installer_log_warn "nftban is already installed"
        if ! installer_confirm "Reinstall anyway?"; then
            installer_log_info "Installation cancelled"
            exit 0
        fi
        # Create backup before reinstall
        installer_create_backup
    fi
    
    # Create structure
    installer_create_directories
    
    # Install dependencies
    installer_install_dependencies
    
    # Download based on method
    installer_download_check_network
    
    case "$INSTALLER_METHOD" in
        github)
            installer_download_from_github || die "GitHub download failed"
            ;;
        zip)
            installer_download_from_zip || die "ZIP download failed"
            ;;
        *)
            die "Unknown method: $INSTALLER_METHOD"
            ;;
    esac
    
    # Setup
    installer_setup_cli
    installer_create_symlinks
    installer_set_permissions
    
    # Configure
    installer_detect_control_panel
    installer_initialize_system
    installer_setup_auto_update
    
    # Save state
    installer_save_version
    installer_save_state
    
    # Verify
    if installer_cmd_verify; then
        installer_log_success "Installation completed successfully!"
        installer_show_completion
    else
        installer_log_error "Installation completed with errors"
        exit 1
    fi
}

installer_cmd_update() {
    installer_parse_args "$@"
    installer_check_root
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        die "nftban is not installed. Use 'install' command first."
    fi
    
    installer_log_info "Updating nftban..."
    
    # Create backup
    installer_create_backup
    
    # Update based on current method
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        installer_log_info "Updating via git..."
        installer_download_git_sync || {
            installer_log_warn "Git sync failed, trying ZIP method..."
            installer_download_from_zip
        }
    else
        installer_log_info "Updating via ZIP..."
        installer_download_from_zip
    fi
    
    # Reinitialize
    installer_initialize_system
    
    # Update version
    installer_save_version
    
    installer_log_success "Update complete"
    installer_cmd_verify
}

installer_cmd_uninstall() {
    installer_parse_args "$@"
    installer_check_root
    
    installer_log_info "Uninstalling nftban..."
    
    if ! installer_confirm "Are you sure you want to uninstall nftban?"; then
        installer_log_info "Uninstall cancelled"
        exit 0
    fi
    
    # Backup before uninstall
    if [[ "$INSTALLER_PURGE" == "false" && "$INSTALLER_NO_BACKUP" == "false" ]]; then
        installer_create_backup
    fi
    
    # Remove symlink
    rm -f "/usr/local/bin/nftban"
    
    # Remove installation
    rm -rf "$INSTALL_DIR"
    
    # Handle purge
    if [[ "$INSTALLER_PURGE" == "true" ]]; then
        installer_log_info "Purging all data..."
        rm -rf "$LOG_DIR"
        rm -rf "$BACKUP_DIR"
        rm -rf /etc/fail2ban/jail.d/nftban-*.conf
        rm -rf /etc/fail2ban/filter.d/nftban-*.conf
        rm -rf /etc/fail2ban/action.d/nftban-*.conf
    fi

    installer_log_success "nftban uninstalled successfully"
}

# =============================================================================
# SELF UPDATE
# =============================================================================

installer_cmd_self_update() {
    installer_log_info "Self-update not yet implemented"
    installer_log_info "Please download latest version from GitHub"
    return 0
}
