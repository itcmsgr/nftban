#!/usr/bin/env bash

# =============================================================================
# NFTBan Installer - Directory Structure Module
# Version: 0.9.0
# Location: lib/installer/installer_structure.sh
# Provides: Directory creation, permissions, symlink management
# =============================================================================

[[ -n "${INSTALLER_STRUCTURE_LOADED:-}" ]] && return 0
readonly INSTALLER_STRUCTURE_LOADED=1

# =============================================================================
# DIRECTORY STRUCTURE CREATION
# =============================================================================

installer_create_directories() {
    installer_log_info "Creating directory structure..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would create directory structure"
        return 0
    fi
    
    local directories=(
        # Base directories
        "$INSTALL_DIR"
        "$INSTALL_DIR/lib"
        "$INSTALL_DIR/lib/installer"
        "$INSTALL_DIR/bin"
        "$INSTALL_DIR/config"
        "$INSTALL_DIR/config/ports"
        "$INSTALL_DIR/config/feeds"
        "$INSTALL_DIR/data"
        "$INSTALL_DIR/data/geoip"
        "$INSTALL_DIR/data/geoip/cache"
        "$INSTALL_DIR/data/geoip/sets"
        "$INSTALL_DIR/data/backups"
        "$INSTALL_DIR/data/feeds"
        "$INSTALL_DIR/cache"
        "$INSTALL_DIR/cache/geoip"
        "$INSTALL_DIR/cache/autorebuild"
        "$INSTALL_DIR/cache/feeds"
        "$INSTALL_DIR/templates"
        "$INSTALL_DIR/templates/conf"
        "$INSTALL_DIR/templates/fail2ban"
        "$INSTALL_DIR/templates/fail2ban/DEBIAN"
        "$INSTALL_DIR/templates/fail2ban/DEBIAN/jail.d"
        "$INSTALL_DIR/templates/fail2ban/DEBIAN/filter.d"
        "$INSTALL_DIR/templates/fail2ban/DEBIAN/action.d"
        "$INSTALL_DIR/templates/fail2ban/REDHAT"
        "$INSTALL_DIR/templates/fail2ban/REDHAT/jail.d"
        "$INSTALL_DIR/templates/fail2ban/REDHAT/filter.d"
        "$INSTALL_DIR/templates/fail2ban/REDHAT/action.d"
        "$INSTALL_DIR/templates/control-panels"
        "$INSTALL_DIR/docs"
        "$INSTALL_DIR/scripts"

        # Log directory
        "$LOG_DIR"

        # Backup directory
        "$BACKUP_DIR"
    )
    
    local created=0
    local skipped=0
    
    for dir in "${directories[@]}"; do
        if [[ -d "$dir" ]]; then
            installer_log_debug "Directory exists: $dir"
            ((skipped++)) || true
        else
            if mkdir -p "$dir" 2>/dev/null; then
                chmod 755 "$dir" 2>/dev/null || true
                installer_log_debug "Created: $dir"
                ((created++)) || true
            else
                installer_log_error "Failed to create: $dir"
                return 1
            fi
        fi
    done
    
    installer_log_success "Directory structure created: $created new, $skipped existing"
    return 0
}

# =============================================================================
# SYMLINK MANAGEMENT
# =============================================================================

installer_create_symlinks() {
    installer_log_info "Creating symlinks..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would create symlinks"
        return 0
    fi
    
    # Create logs symlink in install dir
    if [[ ! -L "$INSTALL_DIR/logs" ]]; then
        ln -sf "$LOG_DIR" "$INSTALL_DIR/logs" 2>&1 | tee -a "$INSTALL_LOG"
        installer_log_debug "Created symlink: $INSTALL_DIR/logs -> $LOG_DIR"
    fi
    
    installer_log_success "Symlinks created"
    return 0
}

# =============================================================================
# CLI SETUP
# =============================================================================

installer_setup_cli() {
    installer_log_info "Setting up CLI..."
    
    local cli_source="$INSTALL_DIR/bin/nftban"
    local cli_target="/usr/local/bin/nftban"
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would create CLI at: $cli_target"
        return 0
    fi
    
    # Check if CLI source exists
    if [[ ! -f "$cli_source" ]]; then
        installer_log_warn "CLI source not found, creating minimal wrapper"
        installer_create_minimal_cli
    fi
    
    # Make executable
    chmod +x "$cli_source" 2>&1 | tee -a "$INSTALL_LOG"
    
    # Create global symlink
    if [[ -L "$cli_target" || -f "$cli_target" ]]; then
        rm -f "$cli_target"
    fi
    
    ln -sf "$cli_source" "$cli_target" 2>&1 | tee -a "$INSTALL_LOG"
    
    installer_log_success "CLI installed: $cli_target"
    
    # Verify CLI works
    if "$cli_target" version &>/dev/null; then
        installer_log_success "CLI verification passed"
    else
        installer_log_warn "CLI may not be fully functional yet"
    fi
    
    return 0
}

installer_create_minimal_cli() {
    local cli_file="$INSTALL_DIR/bin/nftban"

    cat > "$cli_file" << 'EOF'
#!/usr/bin/env bash
# =============================================================================
# NFTBan CLI Entry Point
# Version: 1.0.0
# Location: lib/installer/installer_structure.sh
# Smart wrapper with fallback mechanisms and helpful error messages
# =============================================================================

set -euo pipefail

readonly LIB_DIR="/etc/nftban/lib"
readonly MAIN_CLI="${LIB_DIR}/nftban_main_cli.sh"

# =============================================================================
# ATTEMPT 1: Use main CLI (preferred)
# =============================================================================
if [[ -f "$MAIN_CLI" ]]; then
    exec bash "$MAIN_CLI" "$@"
fi

# =============================================================================
# ATTEMPT 2: Fallback to core module with helpful error
# =============================================================================
if [[ -f "${LIB_DIR}/nftban_core.sh" ]]; then
    source "${LIB_DIR}/nftban_core.sh"

    cat << 'ERROR_MSG' >&2

╔═══════════════════════════════════════════════════════════════╗
║                        ⚠️  ERROR                              ║
╚═══════════════════════════════════════════════════════════════╝

Main CLI not found at: /etc/nftban/lib/nftban_main_cli.sh

This usually means:
  • NFTBan installation is incomplete
  • Files were manually deleted
  • Update failed partway through

RECOVERY OPTIONS:

  Option 1 - Repair Installation:
    cd /home/gituser/github/nftban
    sudo bash lib/installer/installer_main.sh install

  Option 2 - Check file integrity:
    ls -la /etc/nftban/lib/

  Option 3 - Reinstall from scratch:
    cd /home/gituser/github/nftban
    sudo bash lib/installer/installer_main.sh uninstall
    sudo bash lib/installer/installer_main.sh install

═══════════════════════════════════════════════════════════════

ERROR_MSG
    exit 1
fi

# =============================================================================
# ATTEMPT 3: Critical failure (no core module)
# =============================================================================
cat << 'CRITICAL_MSG' >&2

╔═══════════════════════════════════════════════════════════════╗
║                    ❌ CRITICAL ERROR                          ║
╚═══════════════════════════════════════════════════════════════╝

NFTBan is not properly installed.

Core module not found at: /etc/nftban/lib/nftban_core.sh

RECOVERY:

  1. Verify installation directory exists:
     ls -la /etc/nftban/

  2. If missing, reinstall:
     cd /home/gituser/github/nftban
     sudo bash lib/installer/installer_main.sh install

  3. If directory exists but files missing, check permissions:
     sudo chmod -R 755 /etc/nftban
     sudo chmod 644 /etc/nftban/lib/*.sh

═══════════════════════════════════════════════════════════════

CRITICAL_MSG
exit 1
EOF

    chmod +x "$cli_file"
    installer_log_debug "Created smart CLI wrapper with fallbacks"
}

# =============================================================================
# BASH COMPLETION SETUP
# =============================================================================

installer_setup_bash_completion() {
    installer_log_info "Setting up bash completion..."

    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would install bash completion"
        return 0
    fi

    # Determine completion directory based on distro
    local completion_dir=""
    if [[ -d "/usr/share/bash-completion/completions" ]]; then
        completion_dir="/usr/share/bash-completion/completions"
    elif [[ -d "/etc/bash_completion.d" ]]; then
        completion_dir="/etc/bash_completion.d"
    else
        installer_log_warn "Bash completion directory not found, skipping"
        return 0
    fi

    # Source completion script location
    local completion_source="${SCRIPT_DIR}/completions/nftban-completion.bash"
    local completion_target="${completion_dir}/nftban"

    # Check if source exists
    if [[ ! -f "$completion_source" ]]; then
        installer_log_warn "Bash completion script not found at: $completion_source"
        return 0
    fi

    # Copy completion script
    if cp "$completion_source" "$completion_target" 2>&1 | tee -a "$INSTALL_LOG"; then
        chmod 644 "$completion_target"
        installer_log_success "Bash completion installed: $completion_target"
        installer_log_info "Tab completion will be available in new shells"
    else
        installer_log_warn "Failed to install bash completion"
        return 0  # Non-critical, don't fail installation
    fi

    return 0
}

# =============================================================================
# PERMISSIONS MANAGEMENT
# =============================================================================

installer_set_permissions() {
    installer_log_info "Setting permissions..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would set permissions"
        return 0
    fi
    
    # Set directory permissions
    find "$INSTALL_DIR" -type d -exec chmod 755 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    
    # Set lib file permissions (readable, not executable)
    find "$INSTALL_DIR/lib" -type f -name "*.sh" -exec chmod 644 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    
    # Set bin file permissions (executable)
    if [[ -d "$INSTALL_DIR/bin" ]]; then
        find "$INSTALL_DIR/bin" -type f -exec chmod 755 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    fi
    
    # Set config file permissions (readable/writable by root only)
    if [[ -d "$INSTALL_DIR/config" ]]; then
        find "$INSTALL_DIR/config" -type f -exec chmod 644 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    fi
    
    # Set script permissions (executable)
    if [[ -d "$INSTALL_DIR/scripts" ]]; then
        find "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod 755 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    fi
    
    # Set log directory permissions
    if [[ -d "$LOG_DIR" ]]; then
        chmod 755 "$LOG_DIR"
        find "$LOG_DIR" -type f -exec chmod 644 {} \; 2>&1 | tee -a "$INSTALL_LOG"
    fi
    
    installer_log_success "Permissions set"
    return 0
}

# =============================================================================
# CLEANUP OLD INSTALLATIONS
# =============================================================================

installer_cleanup_old() {
    installer_log_info "Cleaning up old installation artifacts..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would cleanup old artifacts"
        return 0
    fi
    
    # Remove old deprecated files
    local old_files=(
        "$INSTALL_DIR/nftban.sh"
        "$INSTALL_DIR/install.sh"
        "$INSTALL_DIR/lib/nftban-old.sh"
    )
    
    local removed=0
    for file in "${old_files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            installer_log_debug "Removed old file: $file"
            ((removed++))
        fi
    done
    
    if [[ $removed -gt 0 ]]; then
        installer_log_success "Cleaned up $removed old files"
    else
        installer_log_debug "No old files to clean up"
    fi
    
    return 0
}

# =============================================================================
# STRUCTURE VERIFICATION
# =============================================================================

installer_verify_structure() {
    installer_log_info "Verifying directory structure..."
    
    local errors=0
    
    # Check critical directories
    local critical_dirs=(
        "$INSTALL_DIR"
        "$INSTALL_DIR/lib"
        "$INSTALL_DIR/config"
        "$LOG_DIR"
    )
    
    for dir in "${critical_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            installer_log_error "Missing critical directory: $dir"
            ((errors++))
        fi
    done
    
    # Check CLI
    if [[ ! -x "/usr/local/bin/nftban" ]]; then
        installer_log_error "CLI not found or not executable"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        installer_log_success "Structure verification passed"
        return 0
    else
        installer_log_error "Structure verification failed: $errors error(s)"
        return 1
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f installer_create_directories
export -f installer_create_symlinks
export -f installer_setup_cli
export -f installer_create_minimal_cli
export -f installer_setup_bash_completion
export -f installer_set_permissions
export -f installer_cleanup_old
export -f installer_verify_structure

installer_log_debug "Directory structure module loaded"
