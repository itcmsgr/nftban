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
# meta:updated_date="2026-01-19"
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
    if command -v rpm &>/dev/null && rpm -q nftban &>/dev/null; then
        echo "rpm"
        return 0
    fi

    # Check DEB (Debian/Ubuntu)
    if command -v dpkg &>/dev/null && dpkg -l nftban 2>/dev/null | grep -q "^ii"; then
        echo "deb"
        return 0
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
            rpm -q --qf '%{VERSION}' nftban 2>/dev/null || echo "unknown"
            ;;
        deb)
            dpkg-query -W -f='${Version}' nftban 2>/dev/null | cut -d'-' -f1 || echo "unknown"
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
    response=$(curl -sL --connect-timeout 10 "$GITHUB_API" 2>/dev/null) || {
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

    if curl -sL --connect-timeout 30 --max-time 300 -o "$output" "$url" 2>/dev/null; then
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

    # Install
    _update_log INFO "Installing DEB package..."
    if dpkg -i "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "DEB installed successfully"
        rm -f "$tmp_file"
        return 0
    else
        _update_log ERROR "DEB installation failed"
        rm -f "$tmp_file"
        return 1
    fi
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

    mkdir -p "$UPDATE_BACKUP_DIR"

    _update_log INFO "Creating backup..."

    if tar -czf "$backup_path" \
        -C / \
        usr/lib/nftban \
        usr/sbin/nftban \
        etc/nftban \
        2>/dev/null; then
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
        _update_log WARN "Backup failed (continuing anyway)"
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

    if tar -xzf "$latest_backup" -C / 2>/dev/null; then
        _update_log OK "Rollback successful"
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
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        return $result
    fi

    # Run health check
    echo ""
    _update_log INFO "Running health check..."
    if nftban health check --auto-heal --quiet 2>/dev/null; then
        _update_log OK "Health check passed"
    else
        _update_log WARN "Health check reported issues"
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
    rollback            Restore previous version from backup
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

    # Rollback to previous version
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
