#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command Detection Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Install type and distribution detection for updates
#
# meta:name="cmd_update_detection"
# meta:type="cli"
# meta:header="Update Command Detection"
# meta:version="1.3.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Install type/distro detection for update command"
# meta:depends="cmd_update.sh,cmd_update_helpers.sh"
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
[[ -n "${_NFTBAN_CLI_UPDATE_DETECTION_LOADED:-}" ]] && return 0
_NFTBAN_CLI_UPDATE_DETECTION_LOADED=1

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
            if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/VERSION" ]]; then
                cat "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/VERSION"
            else
                echo "unknown"
            fi
            ;;
    esac
}

