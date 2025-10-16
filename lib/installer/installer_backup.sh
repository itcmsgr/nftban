#!/usr/bin/env bash

# =============================================================================
# NFTBan Installer - Backup Module
# Provides: Backup creation, restoration, management
# =============================================================================

[[ -n "${INSTALLER_BACKUP_LOADED:-}" ]] && return 0
readonly INSTALLER_BACKUP_LOADED=1

# =============================================================================
# BACKUP CREATION
# =============================================================================

installer_create_backup() {
    if [[ "$INSTALLER_NO_BACKUP" == "true" ]]; then
        installer_log_info "Skipping backup (--no-backup)"
        return 0
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        installer_log_debug "Nothing to backup"
        return 0
    fi
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/nftban_${timestamp}.tar.gz"
    
    installer_log_info "Creating backup..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would create backup: $backup_file"
        return 0
    fi
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR" || {
        installer_log_error "Failed to create backup directory"
        return 1
    }
    
    # Create backup
    if tar -czf "$backup_file" -C / "${INSTALL_DIR#/}" 2>/dev/null; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        installer_log_success "Backup created: $backup_file ($size)"
        
        # Cleanup old backups (keep last 10)
        installer_cleanup_old_backups
        
        return 0
    else
        installer_log_error "Failed to create backup"
        return 1
    fi
}

installer_cleanup_old_backups() {
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -name "nftban_*.tar.gz" -type f | wc -l)
    
    if [[ $backup_count -gt 10 ]]; then
        installer_log_debug "Cleaning old backups (keeping last 10)..."
        find "$BACKUP_DIR" -name "nftban_*.tar.gz" -type f -printf '%T@ %p\n' | \
            sort -n | head -n -10 | cut -d' ' -f2- | xargs -r rm -f
    fi
}

# =============================================================================
# BACKUP RESTORATION
# =============================================================================

installer_cmd_restore() {
    installer_parse_args "$@"
    installer_check_root
    
    local backup_file="$1"
    
    if [[ -z "$backup_file" ]]; then
        installer_log_error "No backup file specified"
        installer_list_backups
        echo ""
        echo "Usage: nftban installer restore <backup_file>"
        exit 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        installer_log_error "Backup file not found: $backup_file"
        exit 1
    fi
    
    installer_log_info "Restoring from backup: $backup_file"
    
    if ! installer_confirm "This will overwrite the current installation. Continue?"; then
        installer_log_info "Restore cancelled"
        exit 0
    fi
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would restore from: $backup_file"
        return 0
    fi
    
    # Create backup of current state before restore
    installer_log_info "Backing up current installation..."
    installer_create_backup
    
    # Remove current installation
    installer_log_info "Removing current installation..."
    rm -rf "$INSTALL_DIR"
    
    # Extract backup
    installer_log_info "Extracting backup..."
    if tar -xzf "$backup_file" -C / 2>/dev/null; then
        installer_log_success "Backup restored successfully"
        
        # Verify
        installer_cmd_verify
    else
        installer_log_error "Failed to restore backup"
        exit 1
    fi
}

# =============================================================================
# BACKUP MANAGEMENT
# =============================================================================

installer_cmd_backup() {
    installer_parse_args "$@"
    installer_check_root
    
    installer_log_info "Creating manual backup..."
    
    if installer_create_backup; then
        installer_list_backups
    else
        exit 1
    fi
}

installer_list_backups() {
    echo ""
    echo "Available Backups:"
    echo "================================================================="
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "No backups directory found"
        return 0
    fi
    
    local backups
    mapfile -t backups < <(find "$BACKUP_DIR" -name "nftban_*.tar.gz" -type f -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backups found"
        return 0
    fi
    
    local count=0
    for backup in "${backups[@]}"; do
        ((count++))
        local size timestamp basename
        size=$(du -h "$backup" | cut -f1)
        basename=$(basename "$backup")
        timestamp=$(echo "$basename" | sed 's/nftban_\(.*\)\.tar\.gz/\1/' | sed 's/_/ /')
        
        echo "$count. $basename"
        echo "   Size: $size"
        echo "   Date: $timestamp"
        echo "   Path: $backup"
        echo ""
    done
    
    echo "================================================================="
    echo "Total backups: ${#backups[@]}"
    echo ""
    echo "To restore: sudo nftban installer restore <backup_file>"
}

installer_delete_backup() {
    local backup_file="$1"
    
    if [[ -z "$backup_file" ]]; then
        installer_log_error "No backup file specified"
        return 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        installer_log_error "Backup not found: $backup_file"
        return 1
    fi
    
    if ! installer_confirm "Delete backup: $(basename "$backup_file")?"; then
        installer_log_info "Deletion cancelled"
        return 0
    fi
    
    if rm -f "$backup_file"; then
        installer_log_success "Backup deleted"
    else
        installer_log_error "Failed to delete backup"
        return 1
    fi
}

# =============================================================================
# BACKUP VERIFICATION
# =============================================================================

installer_verify_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        installer_log_error "Backup not found: $backup_file"
        return 1
    fi
    
    installer_log_info "Verifying backup: $(basename "$backup_file")"
    
    # Check if it's a valid tar.gz
    if tar -tzf "$backup_file" >/dev/null 2>&1; then
        local file_count
        file_count=$(tar -tzf "$backup_file" 2>/dev/null | wc -l)
        installer_log_success "Backup is valid ($file_count files)"
        return 0
    else
        installer_log_error "Backup is corrupted or invalid"
        return 1
    fi
}

# =============================================================================
# EXPORT BACKUP
# =============================================================================

installer_export_backup() {
    local backup_file="$1"
    local export_path="${2:-/tmp}"
    
    if [[ -z "$backup_file" ]]; then
        installer_log_error "No backup file specified"
        return 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        installer_log_error "Backup not found: $backup_file"
        return 1
    fi
    
    local basename
    basename=$(basename "$backup_file")
    local target="${export_path}/${basename}"
    
    installer_log_info "Exporting backup to: $target"
    
    if cp "$backup_file" "$target"; then
        installer_log_success "Backup exported"
        echo "Exported to: $target"
    else
        installer_log_error "Failed to export backup"
        return 1
    fi
}

# =============================================================================
# SELF-UPDATE
# =============================================================================

installer_cmd_self_update() {
    installer_check_root
    
    installer_log_info "Updating installer modules..."
    
    local installer_dir="${INSTALL_DIR}/lib/installer"
    
    if [[ ! -d "$installer_dir" ]]; then
        installer_log_error "Installer directory not found"
        exit 1
    fi
    
    # Backup current installer
    local backup_file="${BACKUP_DIR}/installer_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$backup_file" -C "${INSTALL_DIR}/lib" installer 2>/dev/null
    
    # Download updated modules
    local modules=(
        "installer_main.sh"
        "installer_core.sh"
        "installer_package.sh"
        "installer_download.sh"
        "installer_structure.sh"
        "installer_config.sh"
        "installer_verification.sh"
        "installer_backup.sh"
    )
    
    local base_url="https://raw.githubusercontent.com/itcmsgr/nftban/main/lib/installer"
    
    for module in "${modules[@]}"; do
        installer_log_info "Updating: $module"
        if curl -fsSL "${base_url}/${module}" -o "${installer_dir}/${module}.tmp"; then
            mv "${installer_dir}/${module}.tmp" "${installer_dir}/${module}"
            chmod 644 "${installer_dir}/${module}"
            installer_log_success "Updated: $module"
        else
            installer_log_error "Failed to update: $module"
        fi
    done
    
    installer_log_success "Installer self-update complete"
}

# =============================================================================
# EXPORT
# =============================================================================
export -f installer_create_backup
export -f installer_cmd_restore
export -f installer_cmd_backup
export -f installer_list_backups
export -f installer_verify_backup
export -f installer_cmd_self_update

installer_log_debug "Backup module loaded"
