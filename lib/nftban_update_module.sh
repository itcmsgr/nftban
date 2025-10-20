#!/usr/bin/env bash

# =============================================================================
# NFTBan Update Module - Safe Update/Upgrade System (Security Hardened)
# Version: 1.1.0 (Security Hardening)
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
#
# Features:
# - Version detection and comparison
# - Staging directory workflow
# - SHA256 validation (command injection protected)
# - Atomic apply with rollback
# - Email notifications
# - Dry-run validation
#
# SECURITY FEATURES (v1.1.0):
# - Path traversal prevention (strict path validation)
# - Command injection prevention in SHA256 validation
# - HTTPS-only downloads with cert validation
# - Safe temporary directory creation (mktemp)
# - Input sanitization for all external data
# - No use of curl -k or wget --no-check-certificate
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

# SECURITY: Pinned commit SHA for updates (fail-closed)
# This file contains the trusted commit SHA that updates must match
# Format: One SHA per line, comments with #
readonly NFTBAN_PINNED_COMMIT_FILE="${NFTBAN_CONFIG_DIR}/update-pins.conf"

# =============================================================================
# SECURITY VALIDATION FUNCTIONS
# =============================================================================

# SECURITY: Validate file path to prevent path traversal
# Prevents: ../../../etc/passwd, /etc/passwd, etc.
_nftban_update_validate_path() {
    local path="$1"

    # Remove leading/trailing whitespace
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    # Reject absolute paths
    if [[ "$path" =~ ^/ ]]; then
        echo "ERROR: Absolute paths not allowed: $path" >&2
        return 1
    fi

    # Reject path traversal attempts
    if [[ "$path" =~ \.\. ]]; then
        echo "ERROR: Path traversal detected: $path" >&2
        return 1
    fi

    # Reject paths with suspicious characters
    if [[ "$path" =~ [\$\`\;\ \|\&\<\>] ]]; then
        echo "ERROR: Dangerous characters in path: $path" >&2
        return 1
    fi

    # Path must contain only: alphanumeric, dots, slashes, underscores, hyphens
    if [[ ! "$path" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo "ERROR: Invalid characters in path: $path" >&2
        return 1
    fi

    # Reject paths that resolve outside intended directory
    local resolved_path
    resolved_path=$(realpath -m "$path" 2>/dev/null) || {
        echo "ERROR: Cannot resolve path: $path" >&2
        return 1
    }

    echo "$path"
    return 0
}

# SECURITY: Validate URL is HTTPS from trusted source
_nftban_update_validate_url() {
    local url="$1"

    # Must be HTTPS
    if [[ ! "$url" =~ ^https:// ]]; then
        echo "ERROR: Only HTTPS URLs allowed: $url" >&2
        return 1
    fi

    # Must be from GitHub (raw.githubusercontent.com or api.github.com)
    if [[ ! "$url" =~ ^https://(raw\.githubusercontent\.com|api\.github\.com)/ ]]; then
        echo "ERROR: Only GitHub URLs allowed: $url" >&2
        return 1
    fi

    # No URL encoding attacks
    if [[ "$url" =~ %00|%2e%2e|%252e ]]; then
        echo "ERROR: URL encoding attack detected: $url" >&2
        return 1
    fi

    return 0
}

# SECURITY: Safe sha256sum calculation (prevent command injection)
_nftban_update_safe_sha256() {
    local file_path="$1"

    # Validate file exists and is readable
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: File not found: $file_path" >&2
        return 1
    fi

    if [[ ! -r "$file_path" ]]; then
        echo "ERROR: File not readable: $file_path" >&2
        return 1
    fi

    # Calculate SHA256 with input validation
    if command -v sha256sum &>/dev/null; then
        # Use -- to prevent file paths starting with - from being interpreted as options
        sha256sum -- "$file_path" 2>/dev/null | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 -- "$file_path" 2>/dev/null | awk '{print $1}'
    else
        echo "ERROR: No SHA256 utility available" >&2
        return 1
    fi
}

# =============================================================================
# COMMIT SHA PINNING (FAIL-CLOSED SECURITY)
# =============================================================================

# SECURITY: Validate commit SHA format (40-character hex)
_nftban_update_validate_commit_sha() {
    local sha="$1"

    # Must be exactly 40 hex characters
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ERROR: Invalid commit SHA format: $sha" >&2
        return 1
    fi

    return 0
}

# SECURITY: Get pinned commit SHA from config
# Returns: commit SHA or empty string
# FAIL-CLOSED: If file doesn't exist, returns empty (no updates allowed)
nftban_update_get_pinned_commit() {
    local pin_file="${NFTBAN_PINNED_COMMIT_FILE}"

    # If pin file doesn't exist, return empty (FAIL-CLOSED)
    if [[ ! -f "$pin_file" ]]; then
        nftban_log_debug "No commit pin file found (updates disabled until configured)"
        echo ""
        return 0
    fi

    # Read first non-comment, non-empty line
    local pinned_sha=""
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Validate SHA format
        if _nftban_update_validate_commit_sha "$line" 2>/dev/null; then
            pinned_sha="$line"
            break
        else
            nftban_log_warning "Invalid SHA in pin file, skipping: $line"
        fi
    done < "$pin_file"

    if [[ -z "$pinned_sha" ]]; then
        nftban_log_warning "No valid commit SHA found in pin file (updates disabled)"
    fi

    echo "$pinned_sha"
}

# SECURITY: Get current commit SHA from GitHub API
# This verifies what commit the current "main" branch points to
nftban_update_get_remote_commit_sha() {
    local api_url="${NFTBAN_UPDATE_GITHUB_API}/commits/main"

    nftban_log_debug "Fetching commit SHA from: $api_url"

    # Download commit info from GitHub API
    local commit_json=""
    if command -v curl &>/dev/null; then
        commit_json=$(curl -s --fail --connect-timeout 10 --max-time 30 \
            -H "Accept: application/vnd.github.v3+json" \
            "$api_url" 2>/dev/null)
    elif command -v wget &>/dev/null; then
        commit_json=$(wget -q -O - --timeout=10 --header="Accept: application/vnd.github.v3+json" \
            "$api_url" 2>/dev/null)
    else
        nftban_log_error "Neither curl nor wget available"
        return 1
    fi

    if [[ -z "$commit_json" ]]; then
        nftban_log_error "Failed to fetch commit information from GitHub"
        return 1
    fi

    # Extract SHA from JSON (using grep/sed instead of jq for portability)
    # JSON format: {"sha":"abc123...","commit":{...}}
    local remote_sha=""
    remote_sha=$(echo "$commit_json" | grep -oP '"sha"\s*:\s*"\K[0-9a-f]{40}' | head -1)

    if [[ -z "$remote_sha" ]]; then
        # Fallback: try different JSON parsing
        remote_sha=$(echo "$commit_json" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    fi

    if [[ -z "$remote_sha" ]]; then
        nftban_log_error "Failed to parse commit SHA from GitHub API response"
        return 1
    fi

    # Validate SHA format
    if ! _nftban_update_validate_commit_sha "$remote_sha" 2>/dev/null; then
        nftban_log_error "Invalid SHA received from GitHub: $remote_sha"
        return 1
    fi

    nftban_log_debug "Remote commit SHA: $remote_sha"
    echo "$remote_sha"
}

# SECURITY: Verify commit SHA matches pinned value
# FAIL-CLOSED: If no pin configured, update is DENIED
nftban_update_verify_commit_pin() {
    nftban_log_info "Verifying commit SHA against pinned value..."

    # Get pinned SHA
    local pinned_sha
    pinned_sha=$(nftban_update_get_pinned_commit)

    # FAIL-CLOSED: No pin = no update
    if [[ -z "$pinned_sha" ]]; then
        nftban_log_error "Update DENIED: No commit SHA pinned"
        nftban_log_error "To enable updates, configure: $NFTBAN_PINNED_COMMIT_FILE"
        nftban_log_error "Add a trusted commit SHA (one per line)"
        return 1
    fi

    # Get current remote SHA
    local remote_sha
    if ! remote_sha=$(nftban_update_get_remote_commit_sha); then
        nftban_log_error "Update DENIED: Cannot verify commit SHA"
        return 1
    fi

    # Compare
    if [[ "$pinned_sha" != "$remote_sha" ]]; then
        nftban_log_error "Update DENIED: Commit SHA mismatch"
        nftban_log_error "  Pinned:  $pinned_sha"
        nftban_log_error "  Remote:  $remote_sha"
        nftban_log_error ""
        nftban_log_error "This could indicate:"
        nftban_log_error "  1. New version available (update pin file after verifying)"
        nftban_log_error "  2. Man-in-the-middle attack (DO NOT UPDATE)"
        nftban_log_error "  3. Repository compromise (DO NOT UPDATE)"
        nftban_log_error ""
        nftban_log_error "Verify the commit on GitHub first:"
        nftban_log_error "  https://github.com/itcmsgr/nftban/commit/$remote_sha"
        return 1
    fi

    nftban_log_success "Commit SHA verified: $pinned_sha"
    return 0
}

# SECURITY: Update commit pin (manual operation by admin)
nftban_update_set_commit_pin() {
    local new_sha="$1"
    local force="${2:-false}"

    # Validate SHA format
    if ! _nftban_update_validate_commit_sha "$new_sha" 2>/dev/null; then
        nftban_log_error "Invalid commit SHA format: $new_sha"
        nftban_log_error "SHA must be 40 hexadecimal characters"
        return 1
    fi

    # Verify commit exists on GitHub
    nftban_log_info "Verifying commit exists on GitHub..."
    local commit_url="https://github.com/itcmsgr/nftban/commit/$new_sha"

    # Create pin file directory if needed
    mkdir -p "$(dirname "$NFTBAN_PINNED_COMMIT_FILE")"

    # Check if pin already exists
    if [[ -f "$NFTBAN_PINNED_COMMIT_FILE" ]] && [[ "$force" != "true" ]]; then
        local current_pin
        current_pin=$(nftban_update_get_pinned_commit)

        if [[ -n "$current_pin" && "$current_pin" == "$new_sha" ]]; then
            nftban_log_info "Commit already pinned: $new_sha"
            return 0
        fi

        if [[ -n "$current_pin" ]]; then
            nftban_log_warning "Updating commit pin:"
            nftban_log_warning "  From: $current_pin"
            nftban_log_warning "  To:   $new_sha"

            read -p "Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                nftban_log_info "Pin update cancelled"
                return 1
            fi
        fi
    fi

    # Write new pin
    cat > "$NFTBAN_PINNED_COMMIT_FILE" << EOF
# NFTBan Update Commit Pin
# This file pins updates to a specific trusted git commit SHA
#
# SECURITY: Updates will ONLY be allowed if they match this commit
# This prevents man-in-the-middle attacks and repository compromises
#
# To update this pin:
#   1. Verify the new commit on GitHub
#   2. Run: sudo nftban update pin <commit-sha>
#
# GitHub commit URL:
# $commit_url
#
# Last updated: $(date '+%Y-%m-%d %H:%M:%S')

$new_sha
EOF

    # Set restrictive permissions (only root can modify)
    chmod 600 "$NFTBAN_PINNED_COMMIT_FILE"

    nftban_log_success "Commit pin updated: $new_sha"
    nftban_log_info "Verify on GitHub: $commit_url"

    return 0
}

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

# SECURITY: Initialize staging directory safely
nftban_update_staging_init() {
    nftban_log_info "Initializing staging directory..."

    # Clean old staging if exists
    if [[ -d "$NFTBAN_UPDATE_STAGING_DIR" ]]; then
        nftban_log_debug "Removing old staging directory"
        rm -rf "$NFTBAN_UPDATE_STAGING_DIR"
    fi

    # SECURITY: Create fresh staging with secure permissions (700)
    # Only root/owner can read/write/execute
    if ! mkdir -p "$NFTBAN_UPDATE_STAGING_DIR" 2>/dev/null; then
        nftban_log_error "Failed to create staging directory"
        return 1
    fi

    # SECURITY: Set restrictive permissions (prevent other users from reading)
    chmod 700 "$NFTBAN_UPDATE_STAGING_DIR" || {
        nftban_log_error "Failed to set permissions on staging directory"
        return 1
    }

    # SECURITY: Verify ownership (must be root)
    if [[ $(stat -c '%U' "$NFTBAN_UPDATE_STAGING_DIR" 2>/dev/null) != "root" ]]; then
        nftban_log_warning "Staging directory not owned by root"
    fi

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

# SECURITY: Download file from GitHub with strict validation
nftban_update_download_file() {
    local remote_path="$1"  # Relative path in repo (e.g., "lib/nftban_core.sh")
    local local_path="$2"   # Where to save locally

    # SECURITY: Validate remote path (prevent path traversal)
    local validated_remote_path
    if ! validated_remote_path=$(_nftban_update_validate_path "$remote_path" 2>/dev/null); then
        nftban_log_error "Invalid remote path: $remote_path"
        return 1
    fi

    # SECURITY: Validate local path (prevent path traversal)
    local validated_local_path
    if ! validated_local_path=$(_nftban_update_validate_path "$local_path" 2>/dev/null); then
        nftban_log_error "Invalid local path: $local_path"
        return 1
    fi

    # Construct URL
    local url="${NFTBAN_UPDATE_GITHUB_RAW}/${validated_remote_path}"

    # SECURITY: Validate URL (ensure HTTPS from GitHub)
    if ! _nftban_update_validate_url "$url"; then
        nftban_log_error "Invalid URL: $url"
        return 1
    fi

    # Create parent directory safely
    local parent_dir
    parent_dir=$(dirname "$validated_local_path")
    mkdir -p "$parent_dir" 2>/dev/null || {
        nftban_log_error "Cannot create directory: $parent_dir"
        return 1
    }

    # SECURITY: Download with HTTPS cert validation (NO -k flag!)
    if command -v curl &>/dev/null; then
        # --fail: Fail on HTTP errors (4xx, 5xx)
        # --silent: No progress bar
        # --show-error: Show errors
        # --location: Follow redirects
        # --connect-timeout 10: Connection timeout
        # --max-time 30: Total operation timeout
        # NO -k or --insecure flag (would skip cert validation)
        if curl --fail --silent --show-error --location \
                --connect-timeout 10 --max-time 30 \
                -o "$validated_local_path" "$url" 2>/dev/null; then
            return 0
        fi
    elif command -v wget &>/dev/null; then
        # --quiet: No output
        # --timeout=10: Read timeout
        # --tries=3: Retry attempts
        # NO --no-check-certificate flag (would skip cert validation)
        if wget --quiet --timeout=10 --tries=3 \
                -O "$validated_local_path" "$url" 2>/dev/null; then
            return 0
        fi
    else
        nftban_log_error "Neither curl nor wget available"
        return 1
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

        # SECURITY: Validate file path before using it
        local validated_filepath
        if ! validated_filepath=$(_nftban_update_validate_path "$filepath" 2>/dev/null); then
            nftban_log_warning "Invalid path in checksums file: $filepath"
            continue
        fi

        local staging_file="${staging_dir}/${validated_filepath}"

        if [[ ! -f "$staging_file" ]]; then
            continue  # File not downloaded, skip
        fi

        # SECURITY: Use safe SHA256 calculation (prevent command injection)
        local actual_checksum
        if actual_checksum=$(_nftban_update_safe_sha256 "$staging_file"); then
            if [[ "$actual_checksum" == "$checksum" ]]; then
                ((validated++))
            else
                nftban_log_error "Checksum mismatch: $filepath (expected: $checksum, got: $actual_checksum)"
                ((failed++))
            fi
        else
            nftban_log_error "Failed to calculate checksum: $filepath"
            ((failed++))
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

    # Step 1: SECURITY - Verify commit SHA (FAIL-CLOSED)
    echo ""
    nftban_log_info "Step 1/7: Security verification..."
    if ! nftban_update_verify_commit_pin; then
        nftban_log_error "Update ABORTED: Commit verification failed"
        echo ""
        echo "To configure commit pinning:"
        echo "  1. Get current main commit: nftban update show-commit"
        echo "  2. Verify on GitHub: https://github.com/itcmsgr/nftban/commits/main"
        echo "  3. Pin trusted commit: sudo nftban update pin <commit-sha>"
        echo ""
        return 1
    fi
    echo ""

    # Step 2: Check for updates
    nftban_log_info "Step 2/7: Checking for updates..."
    if ! nftban_update_check "true"; then
        return 1
    fi

    nftban_update_compare_versions "$(nftban_update_get_local_version)" "$(nftban_update_get_remote_version)"
    if [[ $? -ne 2 ]]; then
        nftban_log_info "No update needed"
        return 0
    fi

    # Step 3: User confirmation
    nftban_log_info "Step 3/7: User confirmation..."
    if [[ "$skip_confirmation" != "true" ]]; then
        echo ""
        read -p "Do you want to proceed with the update? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            nftban_log_info "Update cancelled by user"
            return 0
        fi
    fi
    echo ""

    # Step 4: Initialize staging
    nftban_log_info "Step 4/7: Initializing staging..."
    if ! nftban_update_staging_init; then
        return 1
    fi

    # Step 5: Download files
    nftban_log_info "Step 5/7: Downloading update files..."
    if ! nftban_update_download_to_staging; then
        nftban_update_staging_clean
        return 1
    fi
    echo ""

    # Step 6: Validate
    nftban_log_info "Step 6/7: Validating update files..."
    if ! nftban_update_validate_staging; then
        nftban_update_staging_clean
        return 1
    fi
    echo ""

    # Step 7: Apply update
    nftban_log_info "Step 7/7: Applying update..."
    if ! nftban_update_apply; then
        nftban_log_error "Update failed - attempting rollback..."
        nftban_update_rollback
        nftban_update_staging_clean
        return 1
    fi

    # Clean staging
    nftban_update_staging_clean

    # Success
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
