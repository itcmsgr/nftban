#!/usr/bin/env bash

# =============================================================================
# NFTBan Update Module - Safe Update/Upgrade System
# Version: 1.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Features:
# - Version detection and comparison
# - Staging directory workflow
# - SHA256 validation
# - Atomic apply with rollback
# - Email notifications
# - Dry-run validation
# =============================================================================

set -euo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_UPDATE_LOADED:-}" ]] && return 0
readonly NFTBAN_UPDATE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly NFTBAN_UPDATE_GITHUB_RAW="https://raw.githubusercontent.com/itcmsgr/nftban/main"
readonly NFTBAN_UPDATE_GITHUB_API="https://api.github.com/repos/itcmsgr/nftban"
readonly NFTBAN_UPDATE_STAGING_DIR="${NFTBAN_BASE_DIR}/.update_tmp"
readonly NFTBAN_UPDATE_BACKUP_DIR="${NFTBAN_DATA_DIR}/backups"
readonly NFTBAN_VERSION_FILE="${NFTBAN_BASE_DIR}/.version"
readonly NFTBAN_CHANGELOG_FILE="${NFTBAN_BASE_DIR}/CHANGELOG.md"
readonly NFTBAN_UPDATE_LOG="${NFTBAN_LOG_DIR}/update.log"

# =============================================================================
# VERSION MANAGEMENT
# =============================================================================

# Get current installed version
nftban_update_get_local_version() {
    if [[ -f "$NFTBAN_VERSION_FILE" ]]; then
        cat "$NFTBAN_VERSION_FILE" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

# Get remote version from GitHub
nftban_update_get_remote_version() {
    local remote_version=""

    # Try method 1: Direct fetch from GitHub raw
    if command -v curl &>/dev/null; then
        remote_version=$(curl -s --connect-timeout 5 \
            "${NFTBAN_UPDATE_GITHUB_RAW}/.version" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        remote_version=$(wget -q -O - --timeout=5 \
            "${NFTBAN_UPDATE_GITHUB_RAW}/.version" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "$remote_version" ]]; then
        nftban_log_error "Failed to fetch remote version"
        return 1
    fi

    echo "$remote_version"
}

# Compare two semantic versions (format: X.Y.Z-suffix)
# Returns: 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
nftban_update_compare_versions() {
    local v1="$1"
    local v2="$2"

    # Remove leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"

    # Extract version numbers (ignore -beta, -alpha suffixes for now)
    local v1_clean="${v1%%-*}"
    local v2_clean="${v2%%-*}"

    # Split into major.minor.patch
    IFS='.' read -ra V1_PARTS <<< "$v1_clean"
    IFS='.' read -ra V2_PARTS <<< "$v2_clean"

    # Compare major
    local v1_major="${V1_PARTS[0]:-0}"
    local v2_major="${V2_PARTS[0]:-0}"

    if [[ $v1_major -gt $v2_major ]]; then
        return 1  # v1 > v2
    elif [[ $v1_major -lt $v2_major ]]; then
        return 2  # v1 < v2
    fi

    # Compare minor
    local v1_minor="${V1_PARTS[1]:-0}"
    local v2_minor="${V2_PARTS[1]:-0}"

    if [[ $v1_minor -gt $v2_minor ]]; then
        return 1
    elif [[ $v1_minor -lt $v2_minor ]]; then
        return 2
    fi

    # Compare patch
    local v1_patch="${V1_PARTS[2]:-0}"
    local v2_patch="${V2_PARTS[2]:-0}"

    if [[ $v1_patch -gt $v2_patch ]]; then
        return 1
    elif [[ $v1_patch -lt $v2_patch ]]; then
        return 2
    fi

    return 0  # Equal
}

# Check if update is available
nftban_update_check() {
    local show_output="${1:-true}"

    [[ "$show_output" == "true" ]] && nftban_log_info "Checking for updates..."

    local local_version
    local_version=$(nftban_update_get_local_version)

    local remote_version
    if ! remote_version=$(nftban_update_get_remote_version); then
        [[ "$show_output" == "true" ]] && nftban_log_error "Cannot check for updates (network issue)"
        return 1
    fi

    [[ "$show_output" == "true" ]] && echo ""
    [[ "$show_output" == "true" ]] && echo "Current version:  $local_version"
    [[ "$show_output" == "true" ]] && echo "Available version: $remote_version"
    [[ "$show_output" == "true" ]] && echo ""

    nftban_update_compare_versions "$local_version" "$remote_version"
    local result=$?

    case $result in
        0)
            [[ "$show_output" == "true" ]] && nftban_log_success "You are running the latest version"
            return 0
            ;;
        1)
            [[ "$show_output" == "true" ]] && nftban_log_warning "Local version is NEWER than remote (development mode?)"
            return 1
            ;;
        2)
            [[ "$show_output" == "true" ]] && nftban_log_success "Update available: $local_version → $remote_version"
            return 2
            ;;
    esac
}

# =============================================================================
# STAGING DIRECTORY WORKFLOW
# =============================================================================

# Initialize staging directory
nftban_update_staging_init() {
    nftban_log_info "Initializing staging directory..."

    # Clean old staging if exists
    if [[ -d "$NFTBAN_UPDATE_STAGING_DIR" ]]; then
        nftban_log_debug "Removing old staging directory"
        rm -rf "$NFTBAN_UPDATE_STAGING_DIR"
    fi

    # Create fresh staging
    mkdir -p "$NFTBAN_UPDATE_STAGING_DIR"
    chmod 700 "$NFTBAN_UPDATE_STAGING_DIR"

    nftban_log_success "Staging directory ready: $NFTBAN_UPDATE_STAGING_DIR"
}

# Clean staging directory
nftban_update_staging_clean() {
    if [[ -d "$NFTBAN_UPDATE_STAGING_DIR" ]]; then
        nftban_log_debug "Cleaning staging directory"
        rm -rf "$NFTBAN_UPDATE_STAGING_DIR"
    fi
}

# =============================================================================
# DOWNLOAD FUNCTIONS
# =============================================================================

# Download file from GitHub
nftban_update_download_file() {
    local remote_path="$1"  # Relative path in repo (e.g., "lib/nftban_core.sh")
    local local_path="$2"   # Where to save locally

    local url="${NFTBAN_UPDATE_GITHUB_RAW}/${remote_path}"

    mkdir -p "$(dirname "$local_path")"

    if command -v curl &>/dev/null; then
        if curl -sf --connect-timeout 10 -o "$local_path" "$url" 2>/dev/null; then
            return 0
        fi
    elif command -v wget &>/dev/null; then
        if wget -q -O "$local_path" --timeout=10 "$url" 2>/dev/null; then
            return 0
        fi
    fi

    nftban_log_error "Failed to download: $remote_path"
    return 1
}

# Download all core files to staging
nftban_update_download_to_staging() {
    nftban_log_info "Downloading update files to staging..."

    local files_to_download=(
        ".version"
        "CHANGELOG.md"
        "lib/nftban_core.sh"
        "lib/nftban_update_module.sh"
        "lib/nftban_maintenance_module.sh"
        "lib/nftban_nftables_module.sh"
        "lib/nftban_whitelist_module.sh"
        "lib/nftban_blacklist_module.sh"
        "lib/nftban_safety_module.sh"
        "lib/nftban_fail2ban_module.sh"
        "lib/nftban_port_module.sh"
        "lib/nftban_template_module.sh"
        "lib/nftban_search_module.sh"
        "lib/nftban_stats_module.sh"
        "lib/nftban_feeds_module.sh"
        "lib/nftban_feeds_lib.sh"
        "lib/nftban_cloudflare_module.sh"
        "lib/nftban_geo_module.sh"
        "lib/nftban_geoip_module.sh"
        "lib/nftban_ipprotect_module.sh"
        "lib/nftban_ratelimit_module.sh"
        "lib/nftban_login_monitor_module.sh"
        "lib/nftban_autorebuild_module.sh"
        "lib/nftban_main_cli.sh"
    )

    local downloaded=0
    local failed=0

    for file in "${files_to_download[@]}"; do
        local staging_file="${NFTBAN_UPDATE_STAGING_DIR}/${file}"

        if nftban_update_download_file "$file" "$staging_file"; then
            ((downloaded++))
            echo -n "."
        else
            ((failed++))
            nftban_log_warning "Failed to download: $file"
        fi
    done

    echo ""

    if [[ $failed -eq 0 ]]; then
        nftban_log_success "Downloaded $downloaded files successfully"
        return 0
    else
        nftban_log_error "Download incomplete: $downloaded succeeded, $failed failed"
        return 1
    fi
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate SHA256 checksums (if available)
nftban_update_validate_checksums() {
    local staging_dir="$1"

    nftban_log_info "Validating file integrity..."

    # Try to download SHA256SUMS from GitHub
    local checksums_file="${staging_dir}/SHA256SUMS.txt"

    if ! nftban_update_download_file "SHA256SUMS.txt" "$checksums_file" 2>/dev/null; then
        nftban_log_warning "SHA256SUMS.txt not available (skipping checksum validation)"
        return 0  # Not critical, continue
    fi

    if [[ ! -f "$checksums_file" ]]; then
        nftban_log_warning "Checksums file not found (skipping validation)"
        return 0
    fi

    # Validate checksums
    local validated=0
    local failed=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        local checksum="${line%% *}"
        local filepath="${line#* }"
        filepath="${filepath#*/}"  # Remove leading path

        local staging_file="${staging_dir}/${filepath}"

        if [[ ! -f "$staging_file" ]]; then
            continue  # File not downloaded, skip
        fi

        if command -v sha256sum &>/dev/null; then
            local actual_checksum
            actual_checksum=$(sha256sum "$staging_file" | awk '{print $1}')

            if [[ "$actual_checksum" == "$checksum" ]]; then
                ((validated++))
            else
                nftban_log_error "Checksum mismatch: $filepath"
                ((failed++))
            fi
        fi
    done < "$checksums_file"

    if [[ $failed -eq 0 ]]; then
        nftban_log_success "File integrity validated ($validated files)"
        return 0
    else
        nftban_log_error "Integrity check failed: $failed files corrupted"
        return 1
    fi
}

# Validate syntax of shell scripts
nftban_update_validate_syntax() {
    local staging_dir="$1"

    nftban_log_info "Validating script syntax..."

    local validated=0
    local failed=0

    while IFS= read -r -d '' script_file; do
        if bash -n "$script_file" 2>/dev/null; then
            ((validated++))
        else
            nftban_log_error "Syntax error in: ${script_file#$staging_dir/}"
            ((failed++))
        fi
    done < <(find "$staging_dir" -type f -name "*.sh" -print0)

    if [[ $failed -eq 0 ]]; then
        nftban_log_success "Syntax validation passed ($validated scripts)"
        return 0
    else
        nftban_log_error "Syntax validation failed: $failed scripts have errors"
        return 1
    fi
}

# Run all validations
nftban_update_validate_staging() {
    local staging_dir="${1:-$NFTBAN_UPDATE_STAGING_DIR}"

    nftban_log_info "Running validation checks..."
    echo ""

    local validation_passed=true

    # Check 1: SHA256 checksums
    if ! nftban_update_validate_checksums "$staging_dir"; then
        validation_passed=false
    fi

    # Check 2: Syntax validation
    if ! nftban_update_validate_syntax "$staging_dir"; then
        validation_passed=false
    fi

    # Check 3: Version file exists
    if [[ ! -f "${staging_dir}/.version" ]]; then
        nftban_log_error "Version file missing in staging"
        validation_passed=false
    fi

    echo ""

    if [[ "$validation_passed" == "true" ]]; then
        nftban_log_success "All validation checks passed ✓"
        return 0
    else
        nftban_log_error "Validation failed - update aborted"
        return 1
    fi
}

# =============================================================================
# BACKUP & ROLLBACK
# =============================================================================

# Create full backup before update
nftban_update_create_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    local backup_dir="${NFTBAN_UPDATE_BACKUP_DIR}/pre_update_${timestamp}"

    nftban_log_info "Creating backup: $backup_dir"

    mkdir -p "$backup_dir"

    # Backup lib directory
    if [[ -d "${NFTBAN_BASE_DIR}/lib" ]]; then
        cp -a "${NFTBAN_BASE_DIR}/lib" "$backup_dir/"
    fi

    # Backup version and changelog
    [[ -f "$NFTBAN_VERSION_FILE" ]] && cp "$NFTBAN_VERSION_FILE" "$backup_dir/"
    [[ -f "$NFTBAN_CHANGELOG_FILE" ]] && cp "$NFTBAN_CHANGELOG_FILE" "$backup_dir/"

    # Backup config files (but not .local files - those are user managed)
    if [[ -d "${NFTBAN_CONFIG_DIR}" ]]; then
        mkdir -p "${backup_dir}/config"
        find "${NFTBAN_CONFIG_DIR}" -maxdepth 1 -type f -name "*.conf" ! -name "*.local" \
            -exec cp {} "${backup_dir}/config/" \; 2>/dev/null || true
    fi

    # Store backup metadata
    cat > "${backup_dir}/backup_info.txt" << EOF
Backup Created: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname -f)
Version: $(nftban_update_get_local_version)
Purpose: Pre-update backup
EOF

    # Store backup path for potential rollback
    echo "$backup_dir" > "${NFTBAN_DATA_DIR}/.last_backup"

    nftban_log_success "Backup created successfully"
    echo "$backup_dir"
}

# Rollback to previous backup
nftban_update_rollback() {
    local backup_dir="${1:-}"

    # If no backup specified, use last backup
    if [[ -z "$backup_dir" ]]; then
        if [[ -f "${NFTBAN_DATA_DIR}/.last_backup" ]]; then
            backup_dir=$(cat "${NFTBAN_DATA_DIR}/.last_backup")
        else
            nftban_log_error "No backup specified and no last backup found"
            return 1
        fi
    fi

    if [[ ! -d "$backup_dir" ]]; then
        nftban_log_error "Backup directory not found: $backup_dir"
        return 1
    fi

    nftban_log_warning "Rolling back to backup: $backup_dir"

    # Restore lib directory
    if [[ -d "${backup_dir}/lib" ]]; then
        rm -rf "${NFTBAN_BASE_DIR}/lib"
        cp -a "${backup_dir}/lib" "${NFTBAN_BASE_DIR}/"
        nftban_log_info "Restored lib directory"
    fi

    # Restore version and changelog
    [[ -f "${backup_dir}/.version" ]] && cp "${backup_dir}/.version" "$NFTBAN_VERSION_FILE"
    [[ -f "${backup_dir}/CHANGELOG.md" ]] && cp "${backup_dir}/CHANGELOG.md" "$NFTBAN_CHANGELOG_FILE"

    nftban_log_success "Rollback completed"
    return 0
}

# =============================================================================
# ATOMIC APPLY
# =============================================================================

# Apply update atomically
nftban_update_apply() {
    local staging_dir="${1:-$NFTBAN_UPDATE_STAGING_DIR}"

    nftban_log_info "Applying update..."

    # Verify staging directory
    if [[ ! -d "$staging_dir" ]]; then
        nftban_log_error "Staging directory not found: $staging_dir"
        return 1
    fi

    # Create backup first
    local backup_dir
    if ! backup_dir=$(nftban_update_create_backup); then
        nftban_log_error "Failed to create backup - aborting update"
        return 1
    fi

    # Apply files atomically
    nftban_log_info "Copying files from staging to production..."

    # Update lib directory
    if [[ -d "${staging_dir}/lib" ]]; then
        # Use rsync if available (atomic), otherwise cp
        if command -v rsync &>/dev/null; then
            rsync -a --delete "${staging_dir}/lib/" "${NFTBAN_BASE_DIR}/lib/"
        else
            rm -rf "${NFTBAN_BASE_DIR}/lib"
            cp -a "${staging_dir}/lib" "${NFTBAN_BASE_DIR}/"
        fi
        nftban_log_success "Updated lib directory"
    fi

    # Update version file
    if [[ -f "${staging_dir}/.version" ]]; then
        cp "${staging_dir}/.version" "$NFTBAN_VERSION_FILE"
        nftban_log_success "Updated version file"
    fi

    # Update changelog
    if [[ -f "${staging_dir}/CHANGELOG.md" ]]; then
        cp "${staging_dir}/CHANGELOG.md" "$NFTBAN_CHANGELOG_FILE"
        nftban_log_success "Updated changelog"
    fi

    # Set proper permissions
    chmod -R 755 "${NFTBAN_BASE_DIR}/lib"
    find "${NFTBAN_BASE_DIR}/lib" -type f -name "*.sh" -exec chmod +x {} \;

    sync  # Ensure all writes are flushed

    nftban_log_success "Update applied successfully"

    # Log to update log
    local new_version
    new_version=$(nftban_update_get_local_version)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated to version: $new_version" >> "$NFTBAN_UPDATE_LOG"

    return 0
}

# =============================================================================
# FULL UPDATE WORKFLOW
# =============================================================================

# Perform full update (check, download, validate, apply)
nftban_update_perform() {
    local skip_confirmation="${1:-false}"

    nftban_log_info "Starting nftban update process..."
    echo ""

    # Step 1: Check for updates
    if ! nftban_update_check "true"; then
        return 1
    fi

    nftban_update_compare_versions "$(nftban_update_get_local_version)" "$(nftban_update_get_remote_version)"
    if [[ $? -ne 2 ]]; then
        nftban_log_info "No update needed"
        return 0
    fi

    # Step 2: User confirmation
    if [[ "$skip_confirmation" != "true" ]]; then
        echo ""
        read -p "Do you want to proceed with the update? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            nftban_log_info "Update cancelled by user"
            return 0
        fi
    fi

    # Step 3: Initialize staging
    if ! nftban_update_staging_init; then
        return 1
    fi

    # Step 4: Download files
    if ! nftban_update_download_to_staging; then
        nftban_update_staging_clean
        return 1
    fi

    # Step 5: Validate
    if ! nftban_update_validate_staging; then
        nftban_update_staging_clean
        return 1
    fi

    # Step 6: Apply update
    if ! nftban_update_apply; then
        nftban_log_error "Update failed - attempting rollback..."
        nftban_update_rollback
        nftban_update_staging_clean
        return 1
    fi

    # Step 7: Clean staging
    nftban_update_staging_clean

    # Step 8: Success
    echo ""
    nftban_log_success "════════════════════════════════════════════════"
    nftban_log_success "  Update completed successfully!"
    nftban_log_success "  Version: $(nftban_update_get_local_version)"
    nftban_log_success "════════════════════════════════════════════════"
    echo ""

    # Step 9: Send email notification (if configured)
    nftban_update_send_notification

    return 0
}

# =============================================================================
# EMAIL NOTIFICATIONS
# =============================================================================

# Send update notification email
nftban_update_send_notification() {
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")

    [[ -z "$recipient" ]] && return 0

    local new_version
    new_version=$(nftban_update_get_local_version)

    local subject="[nftban] Successfully upgraded to v${new_version}"

    local changelog_excerpt=""
    if [[ -f "$NFTBAN_CHANGELOG_FILE" ]]; then
        changelog_excerpt=$(head -20 "$NFTBAN_CHANGELOG_FILE" | grep -v "^#" | head -10)
    fi

    local body="nftban Update Notification

Hostname: $(hostname -f)
Timestamp: $(date +'%Y-%m-%d %H:%M:%S')
New Version: ${new_version}

Update completed successfully.

Recent Changelog:
${changelog_excerpt}

---
This is an automated message from nftban"

    nftban_send_email "$recipient" "$subject" "$body" "normal"
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================
nftban_log_debug "NFTBan Update Module loaded successfully (v1.0.0)"
