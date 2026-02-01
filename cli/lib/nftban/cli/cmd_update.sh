#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command (Multi-Source Support)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated updates supporting RPM, DEB, Git, and Local installs
#
# meta:name="cmd_update"
# meta:type="cli"
# meta:header="Update Command"
# meta:version="1.3.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Automated updates with auto-detection of install type"
# meta:inventory.files="/etc/nftban/update.conf"
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_UPDATE_SOURCE"
# meta:inventory.config_files="/etc/nftban/update.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="github.com"
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-16"
# meta:updated_date="2026-01-27"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
[[ -n "${NFTBAN_CLI_UPDATE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_UPDATE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly UPDATE_CONFIG_FILE="${NFTBAN_CONFIG_DIR:-/etc/nftban}/update.conf"
readonly UPDATE_LOG_FILE="${NFTBAN_LOG_DIR:-/var/log/nftban}/update.log"
readonly UPDATE_BACKUP_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-backups"
readonly GITHUB_REPO="itcmsgr/nftban"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases/download"

# Defaults (can be overridden by update.conf)
NFTBAN_UPDATE_SOURCE="${NFTBAN_UPDATE_SOURCE:-auto}"
NFTBAN_GIT_REPO="${NFTBAN_GIT_REPO:-/opt/nftban}"
NFTBAN_GIT_BRANCH="${NFTBAN_GIT_BRANCH:-main}"
NFTBAN_UPDATE_BACKUP_COUNT="${NFTBAN_UPDATE_BACKUP_COUNT:-3}"

# Internal flags
_NFTBAN_UPDATE_FORCE=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_update_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file
    mkdir -p "$(dirname "$UPDATE_LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$UPDATE_LOG_FILE" 2>/dev/null || true

    # Output to terminal
    case "$level" in
        INFO)  echo "  $msg" ;;
        OK)    echo "  ✓ $msg" ;;
        WARN)  echo "  ⚠ $msg" ;;
        ERROR) echo "  ✗ $msg" >&2 ;;
    esac
}

_update_banner() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Update"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_fix_broken_dpkg() {
    # Fix broken dpkg state left by interrupted installs
    # Safe to call even when dpkg is healthy - it will be a no-op
    # Returns: 0 on success or no dpkg, 1 on failure to repair

    if ! command -v dpkg &>/dev/null; then
        return 0
    fi

    # Check if dpkg has interrupted/broken packages
    local dpkg_audit
    dpkg_audit=$(dpkg --audit 2>&1) || true

    local needs_configure=0

    # dpkg --audit outputs nothing when everything is clean
    if [[ -n "$dpkg_audit" ]]; then
        needs_configure=1
        _update_log WARN "Broken dpkg state detected"
        _update_log INFO "dpkg audit: $(echo "$dpkg_audit" | head -3)"
    fi

    # Also check for packages in an inconsistent state
    if dpkg -l nftban 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan package in inconsistent dpkg state"
    fi
    if dpkg -l nftban-core 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan-core package in inconsistent dpkg state"
    fi

    # Also check /var/lib/dpkg/updates for pending triggers
    if [[ -d /var/lib/dpkg/updates ]] && compgen -G "/var/lib/dpkg/updates/*" >/dev/null 2>&1; then
        needs_configure=1
        _update_log WARN "Pending dpkg updates found"
    fi

    if [[ "$needs_configure" -eq 1 ]]; then
        _update_log INFO "Running dpkg --configure -a to fix broken state..."
        if dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "dpkg state repaired"
            return 0
        else
            _update_log ERROR "dpkg --configure -a failed"
            _update_log INFO "Manual intervention may be needed: sudo dpkg --configure -a"
            return 1
        fi
    fi

    return 0
}

_remove_immutable_flags() {
    # Remove immutable (chattr +i) flags from ALL nftban files
    # This is needed before any install/update/rollback can modify files
    # Safe to call even if no immutable flags are set

    _update_log INFO "Removing immutable flags from nftban files..."

    # Locate chattr binary (may not be in minimal PATH during package operations)
    local chattr_bin
    chattr_bin=$(command -v chattr 2>/dev/null || echo "")
    if [[ -z "$chattr_bin" ]]; then
        for p in /usr/bin/chattr /bin/chattr /sbin/chattr /usr/sbin/chattr; do
            [[ -x "$p" ]] && chattr_bin="$p" && break
        done
    fi

    if [[ -z "$chattr_bin" ]]; then
        _update_log WARN "chattr not found - cannot remove immutable flags"
        return 0
    fi

    # Locate lsattr binary
    local lsattr_bin
    lsattr_bin=$(command -v lsattr 2>/dev/null || echo "")
    [[ -z "$lsattr_bin" ]] && for p in /usr/bin/lsattr /bin/lsattr; do
        [[ -x "$p" ]] && lsattr_bin="$p" && break
    done

    # Critical file that is known to be immutable
    local schema="/usr/lib/nftban/lib/nft_schema.sh"

    # Helper to check if file has immutable flag
    _has_immutable() {
        local file="$1"
        [[ -z "$lsattr_bin" ]] && return 1
        [[ ! -f "$file" ]] && return 1
        # lsattr output: "----i--------e-- /path/to/file"
        # The 'i' at position 5 indicates immutable
        local attrs
        attrs=$("$lsattr_bin" "$file" 2>/dev/null | awk '{print $1}') || return 1
        [[ "${attrs:4:1}" == "i" ]]
    }

    # Remove immutable flag from the critical file first (most common failure point)
    if [[ -f "$schema" ]] && _has_immutable "$schema"; then
        local err
        if ! err=$("$chattr_bin" -i "$schema" 2>&1); then
            _update_log WARN "chattr -i failed on $schema: $err"
        fi
    fi

    local dirs_to_check=(
        "/usr/lib/nftban"
        "/usr/sbin/nftban"
        "/etc/nftban"
    )

    for path in "${dirs_to_check[@]}"; do
        if [[ -e "$path" ]]; then
            if [[ -d "$path" ]]; then
                # Use find to locate immutable files and remove flag individually
                # This is more reliable than -R which can fail silently
                if [[ -n "$lsattr_bin" ]]; then
                    while IFS= read -r -d '' file; do
                        "$chattr_bin" -i "$file" 2>/dev/null || true
                    done < <(find "$path" -type f -print0 2>/dev/null)
                else
                    # Fallback: brute-force recursive removal
                    "$chattr_bin" -i -R "$path" 2>/dev/null || true
                fi
            else
                "$chattr_bin" -i "$path" 2>/dev/null || true
            fi
        fi
    done

    # Verify the critical file is no longer immutable
    if [[ -f "$schema" ]]; then
        if _has_immutable "$schema"; then
            _update_log WARN "Immutable flag on nft_schema.sh persists, retrying with verbose..."
            # Final attempt - show actual error
            local err
            err=$("$chattr_bin" -i "$schema" 2>&1) || true
            [[ -n "$err" ]] && _update_log WARN "chattr output: $err"

            if _has_immutable "$schema"; then
                _update_log ERROR "Cannot remove immutable flag from $schema"
                _update_log ERROR "Possible causes:"
                _update_log ERROR "  - Filesystem doesn't support extended attributes"
                _update_log ERROR "  - File is on a read-only mount"
                _update_log ERROR "  - SELinux/AppArmor policy blocking"
                _update_log ERROR "Run manually: chattr -i $schema"
                # Don't fail - let dpkg try anyway, it might work
                return 0
            fi
        fi
        _update_log OK "Immutable flags cleared"
    else
        _update_log INFO "No immutable files found"
    fi
}

_load_config() {
    if [[ -f "$UPDATE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$UPDATE_CONFIG_FILE"
    fi
}

# =============================================================================
# INSTALL TYPE DETECTION
# =============================================================================

_detect_install_type() {
    # Detect how NFTBan was installed
    # Returns: rpm, deb, git, unknown

    # Check RPM first (RHEL/CentOS/Rocky/Alma/Fedora)
    # Try both nftban and nftban-core package names
    if command -v rpm &>/dev/null; then
        if rpm -q nftban &>/dev/null || rpm -q nftban-core &>/dev/null; then
            echo "rpm"
            return 0
        fi
    fi

    # Check DEB (Debian/Ubuntu)
    # Try both nftban and nftban-core package names
    if command -v dpkg &>/dev/null; then
        if dpkg -l nftban 2>/dev/null | grep -q "^ii" || \
           dpkg -l nftban-core 2>/dev/null | grep -q "^ii"; then
            echo "deb"
            return 0
        fi
    fi

    # Check Git install
    if [[ -d "${NFTBAN_GIT_REPO}/.git" ]]; then
        echo "git"
        return 0
    fi

    # Unknown install type
    echo "unknown"
    return 0
}

_detect_system_pkg_manager() {
    # Detect what package manager the SYSTEM uses (not what's installed)
    # This is critical for validation - prevents .deb on RPM systems
    # Returns: rpm, deb, unknown

    # Check for RPM-based systems
    if [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || \
       [[ -f /etc/fedora-release ]] || [[ -f /etc/rocky-release ]] || \
       [[ -f /etc/almalinux-release ]]; then
        echo "rpm"
        return 0
    fi

    # Check for DEB-based systems
    if [[ -f /etc/debian_version ]]; then
        echo "deb"
        return 0
    fi

    # Fallback: check available package managers
    if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        echo "rpm"
        return 0
    fi

    if command -v apt-get &>/dev/null || command -v apt &>/dev/null; then
        echo "deb"
        return 0
    fi

    echo "unknown"
    return 0
}

_detect_distro() {
    # Detect Linux distribution for package selection
    # Returns structured info: family:distro:version
    # Examples: rpm:el:9, deb:debian:12, deb:ubuntu:22.04

    local family distro version

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release

        case "${ID:-}" in
            rhel|centos|rocky|almalinux|ol)
                family="rpm"
                distro="el"
                version="${VERSION_ID%%.*}"
                ;;
            fedora)
                family="rpm"
                distro="fedora"
                version="${VERSION_ID}"
                ;;
            debian)
                family="deb"
                distro="debian"
                version="${VERSION_ID%%.*}"
                ;;
            ubuntu)
                family="deb"
                distro="ubuntu"
                version="${VERSION_ID}"
                ;;
            *)
                # Try ID_LIKE for derivatives
                case "${ID_LIKE:-}" in
                    *rhel*|*centos*|*fedora*)
                        family="rpm"
                        distro="el"
                        version="9"  # Safe default
                        ;;
                    *debian*)
                        family="deb"
                        distro="debian"
                        version="12"  # Safe default
                        ;;
                    *ubuntu*)
                        family="deb"
                        distro="ubuntu"
                        version="22.04"  # Safe LTS default
                        ;;
                    *)
                        family="unknown"
                        distro="unknown"
                        version="0"
                        ;;
                esac
                ;;
        esac
    else
        family="unknown"
        distro="unknown"
        version="0"
    fi

    echo "${family}:${distro}:${version}"
}

_get_distro_package_name() {
    # Get the package filename for this distro
    # Returns: package name like "nftban-el9-x86_64.rpm" or "nftban-debian12-amd64.deb"

    local distro_info
    distro_info=$(_detect_distro)

    local family distro version
    IFS=':' read -r family distro version <<< "$distro_info"

    case "$family" in
        rpm)
            # RPM naming: nftban-el9-x86_64.rpm, nftban-el10-x86_64.rpm
            case "$distro" in
                el)
                    echo "nftban-el${version}-x86_64.rpm"
                    ;;
                fedora)
                    # Fedora 39+ uses el10 compatible packages
                    if [[ "$version" -ge 39 ]]; then
                        echo "nftban-el10-x86_64.rpm"
                    else
                        echo "nftban-el9-x86_64.rpm"
                    fi
                    ;;
                *)
                    echo "nftban-el9-x86_64.rpm"  # Safe fallback
                    ;;
            esac
            ;;
        deb)
            # DEB naming: nftban-debian12-amd64.deb, nftban-ubuntu22.04-amd64.deb
            case "$distro" in
                debian)
                    echo "nftban-debian${version}-amd64.deb"
                    ;;
                ubuntu)
                    echo "nftban-ubuntu${version}-amd64.deb"
                    ;;
                *)
                    echo "nftban-debian12-amd64.deb"  # Safe fallback
                    ;;
            esac
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

_validate_package_for_system() {
    # Validate that a package file is compatible with this system
    # Args: $1 = package file path
    # Returns: 0 if compatible, 1 if not (with error message)

    local pkg_file="$1"
    local sys_pkg_manager
    sys_pkg_manager=$(_detect_system_pkg_manager)

    # Check file extension matches system
    if [[ "$pkg_file" == *.rpm ]]; then
        if [[ "$sys_pkg_manager" != "rpm" ]]; then
            _update_log ERROR "Cannot install RPM package on non-RPM system"
            _update_log INFO "This system uses: $sys_pkg_manager"
            return 1
        fi
    elif [[ "$pkg_file" == *.deb ]]; then
        if [[ "$sys_pkg_manager" != "deb" ]]; then
            _update_log ERROR "Cannot install DEB package on non-DEB system"
            _update_log INFO "This system uses: $sys_pkg_manager"
            return 1
        fi
    fi

    # Validate RPM package details
    if [[ "$pkg_file" == *.rpm ]] && [[ -f "$pkg_file" ]]; then
        local distro_info
        distro_info=$(_detect_distro)
        local family distro version
        IFS=':' read -r family distro version <<< "$distro_info"

        # Extract target OS from package name (e.g., nftban-el10-x86_64.rpm -> el10)
        local pkg_target
        pkg_target=$(basename "$pkg_file" | grep -oP 'el\d+' || echo "")

        if [[ -n "$pkg_target" ]]; then
            local pkg_version="${pkg_target#el}"
            local sys_version="$version"

            # el10 package on el9 system - may have glibc incompatibility
            if [[ "$pkg_version" -gt "$sys_version" ]]; then
                _update_log ERROR "Package incompatibility detected"
                _update_log ERROR "Package built for: EL${pkg_version}"
                _update_log ERROR "System version: EL${sys_version}"
                _update_log INFO "Packages built for newer OS may have library incompatibilities"
                _update_log INFO "Use: nftban update github  (auto-selects correct package)"
                return 1
            fi
        fi
    fi

    # Validate DEB package details
    if [[ "$pkg_file" == *.deb ]] && [[ -f "$pkg_file" ]]; then
        local distro_info
        distro_info=$(_detect_distro)
        local family distro version
        IFS=':' read -r family distro version <<< "$distro_info"

        # Extract target from package name
        local pkg_name
        pkg_name=$(basename "$pkg_file")

        # Check Debian version mismatch
        if [[ "$pkg_name" == *debian* ]]; then
            local pkg_deb_ver
            pkg_deb_ver=$(echo "$pkg_name" | grep -oP 'debian\K\d+' || echo "")

            if [[ -n "$pkg_deb_ver" ]] && [[ "$distro" == "debian" ]]; then
                if [[ "$pkg_deb_ver" -gt "$version" ]]; then
                    _update_log ERROR "Package incompatibility detected"
                    _update_log ERROR "Package built for: Debian ${pkg_deb_ver}"
                    _update_log ERROR "System version: Debian ${version}"
                    return 1
                fi
            fi

            # Debian package on Ubuntu - may work but warn
            if [[ "$distro" == "ubuntu" ]]; then
                _update_log WARN "Installing Debian package on Ubuntu"
                _update_log INFO "Consider using Ubuntu-specific package"
            fi
        fi

        # Check Ubuntu version mismatch
        if [[ "$pkg_name" == *ubuntu* ]]; then
            local pkg_ubuntu_ver
            pkg_ubuntu_ver=$(echo "$pkg_name" | grep -oP 'ubuntu\K[0-9.]+' || echo "")

            if [[ -n "$pkg_ubuntu_ver" ]] && [[ "$distro" == "ubuntu" ]]; then
                # Compare major versions (22.04 -> 22, 24.04 -> 24)
                local pkg_major="${pkg_ubuntu_ver%%.*}"
                local sys_major="${version%%.*}"

                if [[ "$pkg_major" -gt "$sys_major" ]]; then
                    _update_log ERROR "Package incompatibility detected"
                    _update_log ERROR "Package built for: Ubuntu ${pkg_ubuntu_ver}"
                    _update_log ERROR "System version: Ubuntu ${version}"
                    return 1
                fi
            fi

            # Ubuntu package on Debian - usually won't work
            if [[ "$distro" == "debian" ]]; then
                _update_log ERROR "Cannot install Ubuntu package on Debian"
                _update_log INFO "Use Debian-specific package instead"
                return 1
            fi
        fi
    fi

    return 0
}

_show_system_info() {
    # Display system information for debugging
    local distro_info sys_pkg
    distro_info=$(_detect_distro)
    sys_pkg=$(_detect_system_pkg_manager)

    local family distro version
    IFS=':' read -r family distro version <<< "$distro_info"

    echo ""
    echo "  System Info:"
    echo "    Package Manager: $sys_pkg"
    echo "    Distribution:    $distro $version"
    echo "    Family:          $family"

    local expected_pkg
    expected_pkg=$(_get_distro_package_name)
    echo "    Expected Pkg:    $expected_pkg"
    echo ""
}

_get_current_version() {
    # Get currently installed version
    local install_type
    install_type=$(_detect_install_type)

    case "$install_type" in
        rpm)
            # Try both package names
            # Note: rpm -q writes "package X is not installed" to stdout, not stderr,
            # so we must capture and filter the output to avoid corrupted version strings
            local ver
            ver=$(rpm -q --qf '%{VERSION}' nftban-core 2>/dev/null | grep -v 'not installed' | head -1)
            if [[ -z "$ver" ]]; then
                ver=$(rpm -q --qf '%{VERSION}' nftban 2>/dev/null | grep -v 'not installed' | head -1)
            fi
            echo "${ver:-unknown}"
            ;;
        deb)
            # Try both package names
            local ver
            ver=$(dpkg-query -W -f='${Version}' nftban 2>/dev/null | cut -d'-' -f1)
            if [[ -z "$ver" ]] || [[ "$ver" == "unknown" ]]; then
                ver=$(dpkg-query -W -f='${Version}' nftban-core 2>/dev/null | cut -d'-' -f1)
            fi
            echo "${ver:-unknown}"
            ;;
        git)
            if [[ -f "${NFTBAN_GIT_REPO}/VERSION" ]]; then
                cat "${NFTBAN_GIT_REPO}/VERSION"
            else
                git -C "$NFTBAN_GIT_REPO" describe --tags 2>/dev/null | sed 's/^v//' || echo "unknown"
            fi
            ;;
        *)
            # Try reading from installed version file
            if [[ -f "/usr/lib/nftban/VERSION" ]]; then
                cat "/usr/lib/nftban/VERSION"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# =============================================================================
# GITHUB RELEASES
# =============================================================================

_get_latest_release() {
    # Get latest release version from GitHub
    # Returns: version string (e.g., "1.3.0")

    local response
    response=$(curl -sLf --connect-timeout 10 "$GITHUB_API" 2>/dev/null) || {
        echo "unknown"
        return 1
    }

    # Extract tag_name and remove 'v' prefix
    echo "$response" | grep -o '"tag_name":\s*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
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

    if curl -sLf --connect-timeout 30 --max-time 300 -o "$output" "$url" 2>/dev/null; then
        if [[ -f "$output" ]] && [[ -s "$output" ]]; then
            local size
            size=$(du -h "$output" | cut -f1)
            _update_log OK "Downloaded ($size)"
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

    # Install
    _update_log INFO "Installing RPM package..."
    if rpm -Uvh --force "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "RPM installed successfully"
        rm -f "$tmp_file"
        return 0
    else
        _update_log ERROR "RPM installation failed"
        rm -f "$tmp_file"
        return 1
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

    # Install
    # Use subshell with reset IFS to avoid word-splitting issues
    _update_log INFO "Installing DEB package..."
    local dpkg_result
    if [[ "$_NFTBAN_UPDATE_FORCE" -eq 1 ]]; then
        _update_log INFO "Force mode: using dpkg --force-overwrite --force-confnew"
        dpkg_result=$(dpkg -i --force-overwrite --force-confnew "$tmp_file" 2>&1) && {
            echo "$dpkg_result" | while IFS= read -r line; do echo "    $line"; done
            _update_log OK "DEB installed successfully"
            rm -f "$tmp_file"
            return 0
        }
    else
        dpkg_result=$(dpkg -i "$tmp_file" 2>&1) && {
            echo "$dpkg_result" | while IFS= read -r line; do echo "    $line"; done
            _update_log OK "DEB installed successfully"
            rm -f "$tmp_file"
            return 0
        }
    fi
    # Installation failed
    echo "$dpkg_result" | while IFS= read -r line; do echo "    $line"; done
    _update_log ERROR "DEB installation failed"
    # In force mode, attempt dpkg configure to clean up
    if [[ "$_NFTBAN_UPDATE_FORCE" -eq 1 ]]; then
        _update_log INFO "Force mode: running dpkg --configure -a after failed install..."
        dpkg --configure -a 2>&1 | while IFS= read -r line; do echo "    $line"; done || true
    fi
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

    # Run install.sh
    local install_script="${NFTBAN_GIT_REPO}/install.sh"
    if [[ -f "$install_script" ]]; then
        _update_log INFO "Running installer..."
        if bash "$install_script" 2>&1 | while read -r line; do echo "    $line"; done; then
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

    if bash "$install_script" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "Installation successful"
        return 0
    else
        _update_log ERROR "Installation failed"
        return 1
    fi
}

# =============================================================================
# BACKUP & ROLLBACK
# =============================================================================

_create_backup() {
    local current_version
    current_version=$(_get_current_version)
    local backup_name
    backup_name="nftban-${current_version}-$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${UPDATE_BACKUP_DIR}/${backup_name}.tar.gz"

    mkdir -p "$UPDATE_BACKUP_DIR" 2>/dev/null || {
        _update_log WARN "Backup failed: Cannot create backup directory $UPDATE_BACKUP_DIR"
        return 0
    }

    _update_log INFO "Creating backup..."

    # Check what directories exist to backup
    local backup_dirs=()
    [[ -d /usr/lib/nftban ]] && backup_dirs+=("usr/lib/nftban")
    [[ -f /usr/sbin/nftban ]] && backup_dirs+=("usr/sbin/nftban")
    [[ -d /etc/nftban ]] && backup_dirs+=("etc/nftban")

    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        _update_log WARN "Backup failed: No NFTBan directories found to backup"
        return 0
    fi

    local tar_output
    if tar_output=$(tar -czf "$backup_path" -C / "${backup_dirs[@]}" 2>&1); then
        _update_log OK "Backup: $backup_name"

        # Cleanup old backups
        local count=0
        while IFS= read -r -d '' old_backup; do
            count=$((count + 1))
            if [[ $count -gt $NFTBAN_UPDATE_BACKUP_COUNT ]]; then
                rm -f "$old_backup"
            fi
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

        return 0
    else
        _update_log WARN "Backup failed: ${tar_output:-tar command failed}"
        return 0
    fi
}

_do_rollback() {
    _update_log INFO "Looking for backups..."

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        _update_log ERROR "No backup directory found"
        return 1
    fi

    # Find latest backup
    local latest_backup=""
    while IFS= read -r -d '' f; do
        latest_backup="$f"
        break
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ -z "$latest_backup" ]]; then
        _update_log ERROR "No backups found"
        return 1
    fi

    _update_log INFO "Rolling back to: $(basename "$latest_backup" .tar.gz)"

    # Fix broken dpkg state before rollback (interrupted installs leave dpkg broken)
    _fix_broken_dpkg || {
        _update_log WARN "Could not fully repair dpkg state, attempting rollback anyway"
    }

    # Remove immutable flags from ALL nftban files that would block rollback extraction
    _remove_immutable_flags

    if tar -xzf "$latest_backup" -C / 2>&1; then
        _update_log OK "Rollback successful"

        # After file rollback, fix dpkg database if this was a deb install
        if command -v dpkg &>/dev/null; then
            local pkg_status
            pkg_status=$(dpkg -l nftban 2>/dev/null | tail -1 | awk '{print $1}') || true
            if [[ -n "$pkg_status" ]] && [[ "$pkg_status" != "ii" ]]; then
                _update_log INFO "Repairing dpkg package database after rollback..."
                dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done || true
            fi
        fi

        return 0
    else
        _update_log ERROR "Rollback failed"
        return 1
    fi
}

_list_backups() {
    echo ""
    echo "Available backups:"
    echo ""

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        echo "  No backups found"
        return 1
    fi

    local count=0
    while IFS= read -r -d '' backup; do
        count=$((count + 1))
        local name size
        name=$(basename "$backup" .tar.gz)
        size=$(du -h "$backup" | cut -f1)
        echo "  [$count] $name ($size)"
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ $count -eq 0 ]]; then
        echo "  No backups found"
        return 1
    fi

    echo ""
    return 0
}

# =============================================================================
# MAIN COMMANDS
# =============================================================================

_cmd_update_status() {
    # Show current installation status
    _update_banner
    echo ""

    local install_type current_version
    install_type=$(_detect_install_type)
    current_version=$(_get_current_version)

    # Get detailed distro info
    local distro_info sys_pkg
    distro_info=$(_detect_distro)
    sys_pkg=$(_detect_system_pkg_manager)

    local family distro version
    IFS=':' read -r family distro version <<< "$distro_info"

    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │ SYSTEM INFORMATION                                      │"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf "  │ Package Manager:  %-38s │\n" "$sys_pkg"
    printf "  │ Distribution:     %-38s │\n" "${distro} ${version}"
    printf "  │ Package Family:   %-38s │\n" "$family"

    local expected_pkg
    expected_pkg=$(_get_distro_package_name)
    printf "  │ Expected Package: %-38s │\n" "$expected_pkg"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │ NFTBAN INSTALLATION                                     │"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf "  │ Install Type:     %-38s │\n" "$install_type"
    printf "  │ Current Version:  %-38s │\n" "v$current_version"

    case "$install_type" in
        rpm)
            local rpm_pkg
            rpm_pkg=$(rpm -q nftban 2>/dev/null || echo 'not installed')
            printf "  │ RPM Package:      %-38s │\n" "$rpm_pkg"
            ;;
        deb)
            local deb_pkg
            deb_pkg=$(dpkg-query -W -f='${Package} ${Version}' nftban 2>/dev/null || echo 'not installed')
            printf "  │ DEB Package:      %-38s │\n" "$deb_pkg"
            ;;
        git)
            printf "  │ Repository:       %-38s │\n" "$NFTBAN_GIT_REPO"
            printf "  │ Branch:           %-38s │\n" "$NFTBAN_GIT_BRANCH"
            local git_commit
            git_commit=$(git -C "$NFTBAN_GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo 'unknown')
            printf "  │ Commit:           %-38s │\n" "$git_commit"
            ;;
        *)
            printf "  │ Note:             %-38s │\n" "Unknown install method"
            ;;
    esac

    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    # Show compatibility notes
    echo "  Package Compatibility:"
    case "$family" in
        rpm)
            echo "    • el9 packages work on: RHEL 9, Rocky 9, Alma 9, CentOS Stream 9"
            echo "    • el10 packages work on: RHEL 10, Fedora 39+, CentOS Stream 10"
            echo "    • Installing el10 on el9 will FAIL (glibc incompatibility)"
            ;;
        deb)
            echo "    • Debian packages: debian11, debian12, debian13"
            echo "    • Ubuntu packages: ubuntu20.04, ubuntu22.04, ubuntu24.04"
            echo "    • Debian packages MAY work on Ubuntu (with warnings)"
            echo "    • Ubuntu packages will NOT work on Debian"
            ;;
    esac
    echo ""
}

_cmd_update_check() {
    # Check for available updates
    _update_banner
    echo ""

    local install_type current_version latest_version
    install_type=$(_detect_install_type)
    current_version=$(_get_current_version)

    echo "  Install type:  $install_type"
    echo "  Current:       v$current_version"
    echo ""
    echo "  Checking GitHub for updates..."

    latest_version=$(_get_latest_release)

    if [[ "$latest_version" == "unknown" ]]; then
        _update_log ERROR "Failed to check GitHub releases"
        return 1
    fi

    echo "  Latest:        v$latest_version"
    echo ""

    if [[ "$current_version" == "$latest_version" ]]; then
        _update_log OK "Already up to date"
        return 0
    else
        _update_log INFO "Update available: v$current_version → v$latest_version"
        echo ""
        echo "  Run 'nftban update' to install"
        return 0
    fi
}

_cmd_update_main() {
    # Main update command
    # Args: $1 = source (auto/github/git/local), $2 = version/path (optional)

    local source="${1:-auto}"
    local arg="${2:-}"

    _update_banner
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Update requires root privileges"
        _update_log INFO "Run: sudo nftban update"
        return 1
    fi

    _load_config

    local install_type current_version
    install_type=$(_detect_install_type)
    current_version=$(_get_current_version)

    # Auto-detect source if needed
    if [[ "$source" == "auto" ]]; then
        case "$install_type" in
            rpm|deb)
                source="github"
                ;;
            git)
                source="git"
                ;;
            *)
                source="github"
                ;;
        esac
    fi

    echo "  Install type:  $install_type"
    echo "  Current:       v$current_version"
    echo "  Source:        $source"
    echo ""

    # Create backup
    _create_backup

    # Execute update based on source
    local result=0
    case "$source" in
        github)
            case "$install_type" in
                rpm)
                    _update_via_rpm "$arg" || result=$?
                    ;;
                deb)
                    _update_via_deb "$arg" || result=$?
                    ;;
                *)
                    # Try to detect and use appropriate method
                    if command -v rpm &>/dev/null; then
                        _update_via_rpm "$arg" || result=$?
                    elif command -v dpkg &>/dev/null; then
                        _update_via_deb "$arg" || result=$?
                    else
                        _update_log ERROR "No package manager found (rpm/dpkg)"
                        result=1
                    fi
                    ;;
            esac
            ;;
        git)
            _update_via_git "$arg" || result=$?
            ;;
        local)
            if [[ -z "$arg" ]]; then
                _update_log ERROR "Local path required: nftban update local /path/to/nftban"
                result=1
            else
                _update_via_local "$arg" || result=$?
            fi
            ;;
        *)
            _update_log ERROR "Unknown source: $source"
            _update_log INFO "Valid sources: auto, github, git, local"
            result=1
            ;;
    esac

    if [[ $result -ne 0 ]]; then
        echo ""
        _update_log ERROR "Update failed"
        _update_log INFO "Run 'nftban update repair' to fix broken install state"
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        _update_log INFO "Run 'nftban update force' to force reinstall"
        return $result
    fi

    # Restart services to load new binaries
    echo ""
    _update_log INFO "Restarting NFTBan services..."
    local _svc_restart_failed=0
    for _svc in nftband.service nftban-core.service; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then
            if systemctl restart "$_svc" 2>/dev/null; then
                _update_log OK "Restarted $_svc"
            else
                _update_log WARN "Failed to restart $_svc"
                _svc_restart_failed=1
            fi
        fi
    done
    if [[ $_svc_restart_failed -eq 0 ]]; then
        _update_log OK "Services restarted"
    fi

    # Run health check
    echo ""
    _update_log INFO "Running health check..."
    local health_output health_status
    health_output=$(nftban health check --auto-heal 2>&1) || health_status=$?
    health_status="${health_status:-0}"

    if [[ $health_status -eq 0 ]]; then
        _update_log OK "Health check passed"
    else
        _update_log WARN "Health check reported issues"
        # Show warning details (filter to show only warnings/errors)
        echo "$health_output" | grep -E "(WARN|WARNING|ERROR|FAIL|\[!\])" | head -5 | while read -r line; do
            echo "    $line"
        done
    fi

    # Show result
    local new_version
    new_version=$(_get_current_version)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Updated: v$current_version → v$new_version"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

_cmd_update_repair() {
    # Repair a broken nftban installation
    # This is the nuclear option - fixes dpkg, removes immutable flags,
    # and optionally restores from backup
    #
    # Designed to work even when nftban itself is partially broken,
    # e.g., after a dpkg failure mid-install

    _update_banner
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Repair requires root privileges"
        _update_log INFO "Run: sudo nftban update repair"
        return 1
    fi

    _update_log INFO "Starting nftban repair..."
    echo ""

    local repair_status=0

    # Step 1: Remove immutable flags from all nftban files
    echo "  [1/4] Removing immutable flags..."
    _remove_immutable_flags

    # Step 2: Fix broken dpkg state (first pass)
    echo ""
    echo "  [2/4] Checking dpkg state..."
    if command -v dpkg &>/dev/null; then
        if ! _fix_broken_dpkg; then
            _update_log WARN "First dpkg repair pass had issues"
            repair_status=1
        fi
    else
        _update_log INFO "Not a dpkg-based system, skipping dpkg repair"
    fi

    # Step 3: Re-run dpkg configure to ensure clean state
    echo ""
    echo "  [3/4] Running dpkg configure (ensure clean state)..."
    if command -v dpkg &>/dev/null; then
        # Force remove any lock files that might be stale
        if [[ -f /var/lib/dpkg/lock-frontend ]]; then
            # Check if dpkg is actually running
            if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
                rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
                rm -f /var/lib/dpkg/lock 2>/dev/null || true
                _update_log INFO "Removed stale dpkg lock files"
            fi
        fi

        # Run dpkg configure to finalize any pending configurations
        if dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "dpkg configure completed"
        else
            _update_log WARN "dpkg configure had issues"
            repair_status=1
        fi

        # Verify nftban package state
        local pkg_line
        pkg_line=$(dpkg -l nftban 2>/dev/null | tail -1) || true
        if [[ -n "$pkg_line" ]]; then
            local pkg_status
            pkg_status=$(echo "$pkg_line" | awk '{print $1}')
            local pkg_version
            pkg_version=$(echo "$pkg_line" | awk '{print $3}')
            case "$pkg_status" in
                ii)
                    _update_log OK "nftban package status: installed ($pkg_version)"
                    ;;
                iF|iU|iW|iH)
                    _update_log WARN "nftban package status: $pkg_status ($pkg_version) - still needs attention"
                    repair_status=1
                    ;;
                rc)
                    _update_log WARN "nftban package status: removed but config remains"
                    ;;
                *)
                    _update_log WARN "nftban package status: $pkg_status"
                    ;;
            esac
        fi
    else
        _update_log INFO "Not a dpkg-based system, skipping dpkg configure"
    fi

    # Step 4: Offer backup restore if repair couldn't fully fix things
    echo ""
    echo "  [4/4] Checking backup availability..."
    if [[ -d "$UPDATE_BACKUP_DIR" ]]; then
        local latest_backup=""
        while IFS= read -r -d '' f; do
            latest_backup="$f"
            break
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

        if [[ -n "$latest_backup" ]]; then
            local backup_name
            backup_name=$(basename "$latest_backup" .tar.gz)
            if [[ $repair_status -ne 0 ]]; then
                _update_log INFO "Backup available: $backup_name"
                _update_log INFO "Restoring from backup to complete repair..."
                if tar -xzf "$latest_backup" -C / 2>&1; then
                    _update_log OK "Backup restored: $backup_name"
                    # Final dpkg configure after restore
                    if command -v dpkg &>/dev/null; then
                        dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done || true
                    fi
                    repair_status=0
                else
                    _update_log ERROR "Backup restore failed"
                fi
            else
                _update_log OK "Backup available: $backup_name (not needed, repair succeeded)"
            fi
        else
            _update_log INFO "No backups found"
            if [[ $repair_status -ne 0 ]]; then
                _update_log WARN "No backup to restore from"
                _update_log INFO "Try: sudo nftban update force"
            fi
        fi
    else
        _update_log INFO "No backup directory found"
    fi

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $repair_status -eq 0 ]]; then
        echo "  Repair completed successfully"
    else
        echo "  Repair completed with warnings"
        echo "  If issues persist, try: sudo nftban update force"
        echo "  Or reinstall: sudo dpkg -i --force-all <package.deb>"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return $repair_status
}

_cmd_update_help() {
    cat << 'EOF'
NFTBan Update - Multi-source update system

USAGE:
    nftban update [COMMAND] [OPTIONS]

COMMANDS:
    (none)              Auto-detect install type and update from appropriate source
    check               Check if updates are available (no changes)
    status              Show current installation information
    github [VERSION]    Update from GitHub releases (RPM/DEB packages)
    git [BRANCH]        Update from git repository (requires git install)
    local PATH          Install from local directory path
    force               Force reinstall/update (fixes dpkg, removes immutable flags)
    rollback            Restore previous version from backup (fixes dpkg first)
    repair              Fix broken install (dpkg state, immutable flags, restore backup)
    list                List available backups
    help                Show this help message

AUTO-DETECTION:
    The update command automatically detects your install type:
    - RPM package  → Downloads from GitHub releases (dnf/yum compatible)
    - DEB package  → Downloads from GitHub releases (apt compatible)
    - Git install  → Runs git pull + install.sh
    - Unknown      → Attempts GitHub release download

EXAMPLES:
    # Standard update (auto-detect)
    nftban update

    # Check for updates only
    nftban update check

    # Show current install info
    nftban update status

    # Force GitHub release update
    nftban update github

    # Update to specific version
    nftban update github 1.3.0

    # Update from git repository
    nftban update git
    nftban update git develop

    # Install from local path
    nftban update local /home/user/nftban-dev

    # Force reinstall (fixes dpkg state, removes immutable flags, forces overwrite)
    nftban update force

    # Repair broken install (fixes dpkg, removes immutable flags, restores backup)
    nftban update repair

    # Rollback to previous version (fixes dpkg state first)
    nftban update rollback

    # List available backups
    nftban update list

CONFIGURATION:
    File: /etc/nftban/update.conf

    NFTBAN_UPDATE_SOURCE="auto"        # auto, github, git
    NFTBAN_GIT_REPO="/opt/nftban"      # Git repository path
    NFTBAN_GIT_BRANCH="main"           # Git branch to track
    NFTBAN_UPDATE_BACKUP_COUNT=3       # Number of backups to keep

EXIT CODES:
    0  Success
    1  Update/install failed
    2  Configuration error

EOF
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_update() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        check|--check|-c)
            _cmd_update_check
            ;;
        status|--status|-s)
            _cmd_update_status
            ;;
        github)
            _cmd_update_main "github" "${1:-}"
            ;;
        git)
            _cmd_update_main "git" "${1:-}"
            ;;
        local)
            _cmd_update_main "local" "${1:-}"
            ;;
        force|--force|reinstall)
            _NFTBAN_UPDATE_FORCE=1
            _cmd_update_main "auto" ""
            ;;
        repair|--repair|fix)
            _cmd_update_repair
            ;;
        rollback|--rollback|-r)
            _update_banner
            echo ""
            _do_rollback
            ;;
        list|--list|-l)
            _update_banner
            _list_backups
            ;;
        help|--help|-h)
            _cmd_update_help
            ;;
        "")
            _cmd_update_main "auto" ""
            ;;
        *)
            # Check if it's a version number (e.g., 1.3.0)
            if [[ "$cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                _cmd_update_main "github" "$cmd"
            else
                echo "ERROR: Unknown command: $cmd" >&2
                echo "Run 'nftban update help' for usage" >&2
                return 1
            fi
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_update

# If executed directly, run
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_update "$@"
fi
