#!/usr/bin/env bash

# =============================================================================
# NFTBan Installer - Download Module (WITH VALIDATION)
# Version: 7.0.1
# Provides: GitHub clone, ZIP download, network checks, SHA256 validation
# =============================================================================

[[ -n "${INSTALLER_DOWNLOAD_LOADED:-}" ]] && return 0
readonly INSTALLER_DOWNLOAD_LOADED=1

# =============================================================================
# DOWNLOAD CONFIGURATION
# =============================================================================
readonly REPO_URL="https://github.com/itcmsgr/nftban"
readonly REPO_BRANCH="${REPO_BRANCH:-main}"
readonly ZIP_URL="https://github.com/itcmsgr/nftban/archive/refs/heads/main.zip"

# Working directory for downloads
DOWNLOAD_WORK_DIR=""

# =============================================================================
# NETWORK CONNECTIVITY
# =============================================================================

installer_download_check_network() {
    installer_log_info "Checking network connectivity..."
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        installer_log_error "Neither curl nor wget found"
        return 1
    fi
    
    # Try to reach GitHub
    if command -v curl >/dev/null 2>&1; then
        if curl -fsI --connect-timeout 5 "https://github.com" >/dev/null 2>&1; then
            installer_log_success "Network connectivity verified"
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget --spider --timeout=5 "https://github.com" >/dev/null 2>&1; then
            installer_log_success "Network connectivity verified"
            return 0
        fi
    fi
    
    installer_log_warn "Cannot reach https://github.com"
    
    if [[ "$INSTALLER_ASSUME_YES" == "false" ]] && ! installer_confirm "Network check failed. Continue anyway?"; then
        installer_log_error "Installation cancelled by user"
        return 1
    fi
    
    return 0
}

# =============================================================================
# WORKING DIRECTORY
# =============================================================================

installer_download_prepare_workdir() {
    DOWNLOAD_WORK_DIR=$(mktemp -d /tmp/nftban_install.XXXXXX)
    
    if [[ ! -d "$DOWNLOAD_WORK_DIR" ]]; then
        installer_log_error "Failed to create working directory"
        return 1
    fi
    
    installer_log_debug "Working directory: $DOWNLOAD_WORK_DIR"
    return 0
}

installer_download_cleanup_workdir() {
    if [[ -n "$DOWNLOAD_WORK_DIR" && -d "$DOWNLOAD_WORK_DIR" ]]; then
        rm -rf "$DOWNLOAD_WORK_DIR" 2>/dev/null || {
            installer_log_warn "Failed to cleanup: $DOWNLOAD_WORK_DIR"
        }
    fi
}

# =============================================================================
# VALIDATION FUNCTION (NEW)
# =============================================================================

installer_download_validate_files() {
    local source_dir="$1"
    
    installer_log_info "Validating downloaded files against GitHub SHA256SUMS.txt..."
    
    # Source the GitHub validator module
    local validator_github="${source_dir}/lib/nftban-validator-github.sh"
    
    if [[ ! -f "$validator_github" ]]; then
        installer_log_warn "GitHub validator not found - skipping validation"
        return 0
    fi
    
    # Source the validator
    # shellcheck source=/dev/null
    source "$validator_github" 2>/dev/null || {
        installer_log_warn "Failed to load GitHub validator - skipping validation"
        return 0
    }
    
    # Check if SHA256SUMS.txt exists on GitHub
    if ! github_check_sha256sums_exists; then
        installer_log_info "SHA256SUMS.txt not available - skipping validation"
        installer_log_info "This is normal for initial installations"
        return 0
    fi
    
    # Download SHA256SUMS.txt
    if ! github_download_sha256sums; then
        installer_log_warn "Could not download SHA256SUMS.txt - skipping validation"
        return 0
    fi
    
    # Validate the lib directory
    local validation_failed=false
    local fail_count=0
    local unknown_count=0
    
    installer_log_info "Validating modules..."
    
    while IFS= read -r filepath; do
        local filename
        filename="$(basename "$filepath")"
        
        local result
        result=$(github_validate_file "$filepath")
        local status=$?
        
        case $status in
            0)
                # OK - silent success
                ;;
            1)
                # CHECKSUM MISMATCH
                installer_log_warn "⚠️  $filename: Checksum mismatch!"
                ((fail_count++))
                validation_failed=true
                ;;
            4)
                # UNKNOWN FILE (not in SHA256SUMS.txt)
                installer_log_info "ℹ️  $filename: Not in SHA256SUMS.txt (new file?)"
                ((unknown_count++))
                ;;
            *)
                # OTHER ERRORS
                installer_log_warn "⚠️  $filename: Validation error (status: $status)"
                ;;
        esac
        
    done < <(find "${source_dir}/lib" -type f -name "*.sh" 2>/dev/null)
    
    # Summary
    echo ""
    if [[ "$validation_failed" == "true" ]]; then
        installer_log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        installer_log_warn "⚠️  VALIDATION WARNINGS DETECTED"
        installer_log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        installer_log_warn "  Failed validations: $fail_count"
        [[ $unknown_count -gt 0 ]] && installer_log_info "  Unknown files: $unknown_count"
        installer_log_warn ""
        installer_log_warn "⚠️  Installation will continue, but some files may be"
        installer_log_warn "   corrupted or modified. Review issues with:"
        installer_log_warn ""
        installer_log_warn "   sudo nftban validate panel"
        installer_log_warn ""
        installer_log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Give user time to read the warning
        sleep 3
    else
        if [[ $unknown_count -gt 0 ]]; then
            installer_log_info "ℹ️  $unknown_count new file(s) not yet in SHA256SUMS.txt"
        fi
        installer_log_success "File validation completed (no critical issues)"
    fi
    
    # ALWAYS return 0 (non-blocking)
    return 0
}

# =============================================================================
# GITHUB DOWNLOAD
# =============================================================================

installer_download_from_github() {
    installer_log_info "Downloading from GitHub repository..."
    installer_log_info "Repository: $REPO_URL"
    installer_log_info "Branch: $REPO_BRANCH"
    
    if ! command -v git >/dev/null 2>&1; then
        installer_log_error "git is required for GitHub installation"
        return 1
    fi
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would clone from: $REPO_URL"
        return 0
    fi
    
    # Check network
    installer_download_check_network || return 1
    
    # Prepare working directory
    installer_download_prepare_workdir || return 1
    
    # Check if already a git repository
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        installer_log_info "Existing repository found - syncing..."
        return installer_download_git_sync
    fi
    
    # Clone repository
    installer_log_info "Cloning repository..."
    
    if ! git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$DOWNLOAD_WORK_DIR/nftban" 2>&1 | tee -a "$INSTALL_LOG"; then
        installer_log_error "Failed to clone repository"
        installer_download_cleanup_workdir
        return 1
    fi
    
    installer_log_success "Repository cloned successfully"
    
    # Validate cloned files (NON-BLOCKING)
    installer_download_validate_files "$DOWNLOAD_WORK_DIR/nftban" || {
        installer_log_warn "Validation encountered issues - review with 'nftban validate panel'"
    }
    
    # Copy files to installation directory
    if ! installer_download_copy_files "$DOWNLOAD_WORK_DIR/nftban"; then
        installer_log_error "Failed to copy files"
        installer_download_cleanup_workdir
        return 1
    fi
    
    installer_download_cleanup_workdir
    return 0
}

installer_download_git_sync() {
    installer_log_info "Syncing existing repository..."
    
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        installer_log_error "Not a git repository: $INSTALL_DIR"
        return 1
    fi
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would sync repository"
        return 0
    fi
    
    pushd "$INSTALL_DIR" >/dev/null || return 1
    
    # Fetch updates
    if ! git fetch --all --quiet 2>&1 | tee -a "$INSTALL_LOG"; then
        installer_log_error "Failed to fetch updates"
        popd >/dev/null || true
        return 1
    fi
    
    # Reset to origin
    if ! git reset --hard "origin/$REPO_BRANCH" --quiet 2>&1 | tee -a "$INSTALL_LOG"; then
        installer_log_error "Failed to reset repository"
        popd >/dev/null || true
        return 1
    fi
    
    # Pull updates
    if ! git pull --quiet --rebase 2>&1 | tee -a "$INSTALL_LOG"; then
        installer_log_error "Failed to pull updates"
        popd >/dev/null || true
        return 1
    fi
    
    popd >/dev/null || true
    
    installer_log_success "Repository synced successfully"
    return 0
}

# =============================================================================
# ZIP DOWNLOAD
# =============================================================================

installer_download_from_zip() {
    installer_log_info "Downloading from ZIP archive..."
    installer_log_info "URL: $ZIP_URL"
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        installer_log_error "curl or wget is required for ZIP installation"
        return 1
    fi
    
    if ! command -v unzip >/dev/null 2>&1; then
        installer_log_error "unzip is required for ZIP installation"
        return 1
    fi
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would download from: $ZIP_URL"
        return 0
    fi
    
    # Check network
    installer_download_check_network || return 1
    
    # Prepare working directory
    installer_download_prepare_workdir || return 1
    
    local zip_file="$DOWNLOAD_WORK_DIR/nftban.zip"
    
    # Download ZIP
    installer_log_info "Downloading ZIP archive..."
    
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$ZIP_URL" -o "$zip_file" 2>&1 | tee -a "$INSTALL_LOG"; then
            installer_log_error "Failed to download ZIP"
            installer_download_cleanup_workdir
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q "$ZIP_URL" -O "$zip_file" 2>&1 | tee -a "$INSTALL_LOG"; then
            installer_log_error "Failed to download ZIP"
            installer_download_cleanup_workdir
            return 1
        fi
    fi
    
    # Verify download
    if [[ ! -s "$zip_file" ]]; then
        installer_log_error "Download failed (empty file)"
        installer_download_cleanup_workdir
        return 1
    fi
    
    installer_log_success "ZIP archive downloaded"
    
    # Test archive
    installer_log_info "Verifying archive..."
    if ! unzip -t "$zip_file" >/dev/null 2>&1; then
        installer_log_error "Corrupt ZIP archive"
        installer_download_cleanup_workdir
        return 1
    fi
    
    # Extract archive
    installer_log_info "Extracting archive..."
    if ! unzip -q "$zip_file" -d "$DOWNLOAD_WORK_DIR" 2>&1 | tee -a "$INSTALL_LOG"; then
        installer_log_error "Failed to extract ZIP"
        installer_download_cleanup_workdir
        return 1
    fi
    
    # Find extracted directory
    local extracted_dir
    extracted_dir=$(find "$DOWNLOAD_WORK_DIR" -maxdepth 1 -type d -name 'nftban-*' -print -quit)
    
    if [[ -z "$extracted_dir" ]]; then
        installer_log_error "Could not find extracted directory"
        installer_download_cleanup_workdir
        return 1
    fi
    
    installer_log_success "Archive extracted successfully"
    
    # Validate downloaded files (NON-BLOCKING)
    installer_download_validate_files "$extracted_dir" || {
        installer_log_warn "Validation encountered issues - review with 'nftban validate panel'"
    }
    
    # Copy files to installation directory
    if ! installer_download_copy_files "$extracted_dir"; then
        installer_log_error "Failed to copy files"
        installer_download_cleanup_workdir
        return 1
    fi
    
    installer_download_cleanup_workdir
    return 0
}

# =============================================================================
# FILE OPERATIONS
# =============================================================================

installer_download_copy_files() {
    local source_dir="$1"
    
    if [[ ! -d "$source_dir" ]]; then
        installer_log_error "Source directory not found: $source_dir"
        return 1
    fi
    
    installer_log_info "Copying installation files..."
    
    # Create target directory if it doesn't exist
    mkdir -p "$INSTALL_DIR" || {
        installer_log_error "Failed to create target directory: $INSTALL_DIR"
        return 1
    }
    
    # Copy lib modules
    if [[ -d "$source_dir/lib" ]]; then
        mkdir -p "$INSTALL_DIR/lib"
        cp -r "$source_dir/lib/"* "$INSTALL_DIR/lib/" 2>&1 | tee -a "$INSTALL_LOG" || {
            installer_log_error "Failed to copy lib files"
            return 1
        }
        installer_log_debug "Copied lib modules"
    fi
    
    # Copy bin files
    if [[ -d "$source_dir/bin" ]]; then
        mkdir -p "$INSTALL_DIR/bin"
        cp -r "$source_dir/bin/"* "$INSTALL_DIR/bin/" 2>&1 | tee -a "$INSTALL_LOG" || {
            installer_log_error "Failed to copy bin files"
            return 1
        }
        chmod +x "$INSTALL_DIR/bin"/* 2>/dev/null || true
        installer_log_debug "Copied bin files"
    fi
    
    # Copy templates
    if [[ -d "$source_dir/templates" ]]; then
        mkdir -p "$INSTALL_DIR/templates"
        cp -r "$source_dir/templates/"* "$INSTALL_DIR/templates/" 2>&1 | tee -a "$INSTALL_LOG" || {
            installer_log_error "Failed to copy templates"
            return 1
        }
        installer_log_debug "Copied templates"
    fi
    
    # Copy config examples (don't overwrite existing)
    if [[ -d "$source_dir/config" ]]; then
        mkdir -p "$INSTALL_DIR/config"
        for file in "$source_dir/config"/*; do
            local basename
            basename=$(basename "$file")
            local target="$INSTALL_DIR/config/$basename"
            
            if [[ ! -f "$target" ]]; then
                cp "$file" "$target" 2>&1 | tee -a "$INSTALL_LOG" || true
            fi
        done
        installer_log_debug "Copied config examples"
    fi
    
    # Copy docs
    if [[ -d "$source_dir/docs" ]]; then
        mkdir -p "$INSTALL_DIR/docs"
        cp -r "$source_dir/docs/"* "$INSTALL_DIR/docs/" 2>&1 | tee -a "$INSTALL_LOG" || true
        installer_log_debug "Copied documentation"
    fi
    
    # Copy README
    if [[ -f "$source_dir/README.md" ]]; then
        cp "$source_dir/README.md" "$INSTALL_DIR/" 2>&1 | tee -a "$INSTALL_LOG" || true
    fi
    
    installer_log_success "Installation files copied"
    return 0
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f installer_download_check_network
export -f installer_download_prepare_workdir
export -f installer_download_cleanup_workdir
export -f installer_download_from_github
export -f installer_download_git_sync
export -f installer_download_from_zip
export -f installer_download_copy_files
export -f installer_download_validate_files

installer_log_debug "Download module loaded"
