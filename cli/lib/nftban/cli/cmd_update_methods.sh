#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command Methods
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Update methods (RPM, DEB, Git, Local) and GitHub release functions
#
# meta:name="cmd_update_methods"
# meta:type="cli"
# meta:header="Update Command Methods"
# meta:version="1.14.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Update methods for RPM, DEB, Git, and Local installs"
# meta:depends="cmd_update.sh,cmd_update_helpers.sh,cmd_update_detection.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_CLI_UPDATE_METHODS_LOADED:-}" ]] && return 0
_NFTBAN_CLI_UPDATE_METHODS_LOADED=1

# =============================================================================
# GITHUB RELEASES
# =============================================================================

_get_latest_release() {
    # Get latest release version from GitHub
    # Returns: version string (e.g., "1.3.0")

    local response
    response=$(curl -sLf --connect-timeout "${NFTBAN_TIMEOUT_MEDIUM:-30}" "$GITHUB_API" 2>/dev/null) || {
        echo "unknown"
        return 1
    }

    # Extract tag_name and remove 'v' prefix
    local latest_version
    if command -v jq &>/dev/null; then
        latest_version=$(echo "$response" | jq -r '.tag_name // empty')
    else
        latest_version=$(echo "$response" | grep -oP '"tag_name":\s*"\K[^"]+')
    fi
    echo "${latest_version}" | sed 's/^v//'
}

_get_package_url() {
    # Get download URL for current distro
    # Args: $1 = version
    # Returns: URL

    local version="$1"

    # Use the validated package name function
    local pkg_name
    pkg_name=$(_get_distro_package_name)

    if [[ "$pkg_name" == "unknown" ]]; then
        _update_log ERROR "Cannot determine package for this system"
        _show_system_info
        return 1
    fi

    echo "${GITHUB_RELEASES}/v${version}/${pkg_name}"
}

_download_package() {
    # Download package from GitHub
    # Args: $1 = URL, $2 = output path
    # Returns: 0 on success

    local url="$1"
    local output="$2"

    _update_log INFO "Downloading from GitHub..."
    _update_log INFO "URL: $url"

    if curl -sLf --connect-timeout "${NFTBAN_TIMEOUT_MEDIUM:-30}" --max-time "${NFTBAN_TIMEOUT_HTTP_LONG:-300}" -o "$output" "$url" 2>/dev/null; then
        if [[ -f "$output" ]] && [[ -s "$output" ]]; then
            local size
            size=$(du -h "$output" | cut -f1)
            _update_log OK "Downloaded ($size)"

            # SHA256 verification
            local release_url pkg_filename tmp_dir
            release_url="${url%/*}"
            pkg_filename=$(basename "$url")
            tmp_dir=$(dirname "$output")

            if curl -fsSL "${release_url}/SHA256SUMS" -o "${tmp_dir}/SHA256SUMS" 2>/dev/null; then
                local expected_hash actual_hash
                expected_hash=$(grep "${pkg_filename}" "${tmp_dir}/SHA256SUMS" | awk '{print $1}')
                actual_hash=$(sha256sum "${output}" | awk '{print $1}')
                if [[ -n "$expected_hash" && "$expected_hash" != "$actual_hash" ]]; then
                    _update_log ERROR "Package checksum verification FAILED!"
                    rm -f "$output" "${tmp_dir}/SHA256SUMS"
                    return 1
                fi
                _update_log INFO "Package checksum verified: OK"
                rm -f "${tmp_dir}/SHA256SUMS"
            else
                _update_log WARN "SHA256SUMS not available - skipping verification"
            fi

            return 0
        fi
    fi

    _update_log ERROR "Download failed"
    return 1
}

# =============================================================================
# UPDATE METHODS
# =============================================================================

_update_via_rpm() {
    # Update using RPM package from GitHub
    # Args: $1 = version (optional, defaults to latest)

    local version="${1:-}"

    # VALIDATION: Ensure this is an RPM-based system
    local sys_pkg
    sys_pkg=$(_detect_system_pkg_manager)
    if [[ "$sys_pkg" != "rpm" ]]; then
        _update_log ERROR "Cannot install RPM package on this system"
        _update_log INFO "System package manager: $sys_pkg"
        _update_log INFO "Use 'nftban update' for auto-detection"
        return 1
    fi

    if [[ -z "$version" ]]; then
        version=$(_get_latest_release)
        if [[ "$version" == "unknown" ]]; then
            _update_log ERROR "Failed to get latest version from GitHub"
            return 1
        fi
    fi

    local url
    url=$(_get_package_url "$version")
    if [[ $? -ne 0 ]] || [[ -z "$url" ]]; then
        return 1
    fi

    local pkg_name
    pkg_name=$(_get_distro_package_name)
    local tmp_file="/tmp/${pkg_name}"

    # Download
    if ! _download_package "$url" "$tmp_file"; then
        return 1
    fi

    # Verify it's a valid RPM
    if ! rpm -qp "$tmp_file" &>/dev/null; then
        _update_log ERROR "Invalid RPM package (corrupted download?)"
        rm -f "$tmp_file"
        return 1
    fi

    # VALIDATION: Check package compatibility with system
    if ! _validate_package_for_system "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    # Remove immutable flags before rpm (nft_schema.sh is chattr +i for security)
    _remove_immutable_flags

    # Install using dnf/yum to automatically resolve dependencies
    # v1.14.0: Changed from rpm -Uvh to dnf/yum install for dependency resolution
    _update_log INFO "Installing RPM package..."

    # Detect package manager (dnf preferred, fallback to yum, then rpm)
    local pkg_manager=""
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
    fi

    if [[ -n "$pkg_manager" ]]; then
        # Use dnf/yum for automatic dependency resolution
        # Note: Use PIPESTATUS[0] to capture the actual package manager exit code
        # instead of relying on pipeline exit status (fixes Fedora false-negative)
        $pkg_manager install -y "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done
        local pkg_exit="${PIPESTATUS[0]}"
        if [[ "$pkg_exit" -eq 0 ]]; then
            _update_log OK "RPM installed successfully"
            rm -f "$tmp_file"
            return 0
        else
            _update_log ERROR "RPM installation failed (exit code: $pkg_exit)"
            rm -f "$tmp_file"
            return 1
        fi
    else
        # Fallback to rpm (no automatic dependency resolution)
        _update_log WARN "dnf/yum not found, using rpm (dependencies may need manual install)"
        rpm -Uvh --force "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done
        local rpm_exit="${PIPESTATUS[0]}"
        if [[ "$rpm_exit" -eq 0 ]]; then
            _update_log OK "RPM installed successfully"
            rm -f "$tmp_file"
            return 0
        else
            _update_log ERROR "RPM installation failed (exit code: $rpm_exit)"
            rm -f "$tmp_file"
            return 1
        fi
    fi
}

_update_via_deb() {
    # Update using DEB package from GitHub
    # Args: $1 = version (optional, defaults to latest)

    local version="${1:-}"

    # VALIDATION: Ensure this is a DEB-based system
    local sys_pkg
    sys_pkg=$(_detect_system_pkg_manager)
    if [[ "$sys_pkg" != "deb" ]]; then
        _update_log ERROR "Cannot install DEB package on this system"
        _update_log INFO "System package manager: $sys_pkg"
        _update_log INFO "Use 'nftban update' for auto-detection"
        return 1
    fi

    if [[ -z "$version" ]]; then
        version=$(_get_latest_release)
        if [[ "$version" == "unknown" ]]; then
            _update_log ERROR "Failed to get latest version from GitHub"
            return 1
        fi
    fi

    local url
    url=$(_get_package_url "$version")
    if [[ $? -ne 0 ]] || [[ -z "$url" ]]; then
        return 1
    fi

    local pkg_name
    pkg_name=$(_get_distro_package_name)
    local tmp_file="/tmp/${pkg_name}"

    # Download
    if ! _download_package "$url" "$tmp_file"; then
        return 1
    fi

    # Verify it's a valid DEB
    if ! dpkg-deb --info "$tmp_file" &>/dev/null; then
        _update_log ERROR "Invalid DEB package (corrupted download?)"
        rm -f "$tmp_file"
        return 1
    fi

    # VALIDATION: Check package compatibility with system
    if ! _validate_package_for_system "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    # Remove immutable flags before dpkg (nft_schema.sh is chattr +i for security)
    # This MUST succeed or dpkg will fail with "unable to make backup link"
    _remove_immutable_flags

    # Cleanup old/retired paths from pre-1.8.13 versions
    # Old DEB packages incorrectly installed CLI to /usr/bin instead of /usr/sbin
    if [[ -f "/usr/bin/nftban" ]] && [[ ! -L "/usr/bin/nftban" ]]; then
        rm -f "/usr/bin/nftban"
        _update_log INFO "Removed old CLI from /usr/bin/nftban (migrated to /usr/sbin)"
    fi

    # Force mode: also fix broken dpkg state
    if [[ "$_NFTBAN_UPDATE_FORCE" -eq 1 ]]; then
        _update_log INFO "Force mode: repairing system state before install..."
        _fix_broken_dpkg || {
            _update_log WARN "Could not fully repair dpkg state, attempting install anyway"
        }
    fi

    # Install using apt to automatically resolve dependencies
    # v1.14.0: Changed from dpkg -i to apt install for dependency resolution
    _update_log INFO "Installing DEB package..."
    local apt_result
    export DEBIAN_FRONTEND=noninteractive

    # apt install ./file.deb automatically resolves dependencies
    if [[ "$_NFTBAN_UPDATE_FORCE" -eq 1 ]]; then
        _update_log INFO "Force mode: using apt install with --allow-downgrades"
        apt_result=$(apt-get install -y --allow-downgrades -o Dpkg::Options::="--force-confnew" "$tmp_file" 2>&1) && {
            echo "$apt_result" | while IFS= read -r line; do echo "    $line"; done
            _update_log OK "DEB installed successfully"
            rm -f "$tmp_file"
            return 0
        }
    else
        apt_result=$(apt-get install -y -o Dpkg::Options::="--force-confnew" "$tmp_file" 2>&1) && {
            echo "$apt_result" | while IFS= read -r line; do echo "    $line"; done
            _update_log OK "DEB installed successfully"
            rm -f "$tmp_file"
            return 0
        }
    fi

    # Installation failed - try to fix broken packages
    echo "$apt_result" | while IFS= read -r line; do echo "    $line"; done
    _update_log WARN "apt install failed, attempting to fix dependencies..."
    apt-get --fix-broken install -y 2>&1 | while IFS= read -r line; do echo "    $line"; done

    # Retry after fixing
    if apt-get install -y -o Dpkg::Options::="--force-confnew" "$tmp_file" 2>&1; then
        _update_log OK "DEB installed successfully (after dependency fix)"
        rm -f "$tmp_file"
        return 0
    fi

    _update_log ERROR "DEB installation failed"
    rm -f "$tmp_file"
    return 1
}

_update_via_git() {
    # Update using git pull
    # Args: $1 = branch (optional, defaults to main)

    local branch="${1:-$NFTBAN_GIT_BRANCH}"

    if [[ ! -d "${NFTBAN_GIT_REPO}/.git" ]]; then
        _update_log ERROR "Git repository not found at: $NFTBAN_GIT_REPO"
        _update_log INFO "Set NFTBAN_GIT_REPO in $UPDATE_CONFIG_FILE"
        return 1
    fi

    _update_log INFO "Repository: $NFTBAN_GIT_REPO"
    _update_log INFO "Branch: $branch"

    # Stash local changes
    git -C "$NFTBAN_GIT_REPO" stash --quiet 2>/dev/null || true

    # Fetch and pull
    _update_log INFO "Pulling latest changes..."
    if git -C "$NFTBAN_GIT_REPO" pull origin "$branch" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "Git pull successful"
    else
        _update_log ERROR "Git pull failed"
        return 1
    fi

    # Remove immutable flags before install (nft_schema.sh is chattr +i for security)
    _remove_immutable_flags

    # Run install.sh with --yes for non-interactive update
    local install_script="${NFTBAN_GIT_REPO}/install.sh"
    if [[ -f "$install_script" ]]; then
        _update_log INFO "Running installer..."
        if bash "$install_script" --yes 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "Installation successful"
            return 0
        else
            _update_log ERROR "Installation failed"
            return 1
        fi
    else
        _update_log WARN "No install.sh found, git pull only"
        return 0
    fi
}

_update_via_local() {
    # Update from local path
    # Args: $1 = path to nftban source directory

    local source_path="$1"

    if [[ ! -d "$source_path" ]]; then
        _update_log ERROR "Local path not found: $source_path"
        return 1
    fi

    local install_script="${source_path}/install.sh"
    if [[ ! -f "$install_script" ]]; then
        _update_log ERROR "install.sh not found in: $source_path"
        return 1
    fi

    _update_log INFO "Source: $source_path"

    # Remove immutable flags before install (nft_schema.sh is chattr +i for security)
    _remove_immutable_flags

    _update_log INFO "Running installer..."

    # Use --yes for non-interactive update mode
    if bash "$install_script" --yes 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "Installation successful"
        return 0
    else
        _update_log ERROR "Installation failed"
        return 1
    fi
}

