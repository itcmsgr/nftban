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
# meta:version="1.39.0"
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

# -----------------------------------------------------------------------------
# Read the oldest (first install) entry's "type" field from update-history.json.
# History is prepended newest-first (see internal/installer/history/history.go:81)
# so the FIRST install chronologically is at array index [-1].
#
# Returns the type string ("rpm" / "deb" / "source") or empty if unavailable.
# Test-overrides:
#   NFTBAN_TEST_HISTORY_FILE     - override path to history JSON (for fixtures)
# -----------------------------------------------------------------------------
_read_history_first_type() {
    local f="${NFTBAN_TEST_HISTORY_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-history.json}"
    [[ -r "$f" ]] || { echo ""; return 0; }

    # Prefer jq if available
    if command -v jq &>/dev/null; then
        jq -r '.[-1].type // empty' "$f" 2>/dev/null
        return 0
    fi

    # Bash fallback: walk JSON to find LAST occurrence of "type" field.
    # Newest-first → oldest is the last "type" line.
    local last_type
    last_type=$(grep -oE '"type"[[:space:]]*:[[:space:]]*"[a-zA-Z0-9_-]+"' "$f" 2>/dev/null \
                | tail -1 \
                | sed -E 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    echo "$last_type"
}

# -----------------------------------------------------------------------------
# Override-aware probes for test fixtures.
# Real production paths use rpm/dpkg/etc; fixtures inject mocked outputs via
# the NFTBAN_TEST_* env vars without polluting the rpm/dpkg databases.
# -----------------------------------------------------------------------------
_probe_rpm_owns_nftban() {
    # Returns 0 if rpm db reports ownership, non-zero otherwise.
    if [[ -n "${NFTBAN_TEST_RPM_OWNS:-}" ]]; then
        [[ "$NFTBAN_TEST_RPM_OWNS" == "yes" ]] && return 0 || return 1
    fi
    command -v rpm &>/dev/null || return 1
    rpm -q nftban &>/dev/null || rpm -q nftban-core &>/dev/null
}

_probe_dpkg_owns_nftban() {
    # Returns 0 if dpkg db reports ownership (installed ^ii), non-zero otherwise.
    if [[ -n "${NFTBAN_TEST_DPKG_OWNS:-}" ]]; then
        [[ "$NFTBAN_TEST_DPKG_OWNS" == "yes" ]] && return 0 || return 1
    fi
    command -v dpkg &>/dev/null || return 1
    dpkg -l nftban 2>/dev/null | grep -q "^ii" || \
    dpkg -l nftban-core 2>/dev/null | grep -q "^ii"
}

_probe_git_repo_present() {
    if [[ -n "${NFTBAN_TEST_GIT_REPO_PRESENT:-}" ]]; then
        [[ "$NFTBAN_TEST_GIT_REPO_PRESENT" == "yes" ]] && return 0 || return 1
    fi
    [[ -d "${NFTBAN_GIT_REPO:-}/.git" ]]
}

_detect_install_type() {
    # Detect how NFTBan was installed.
    # Returns one of: rpm, deb, source, mixed, unknown
    #
    # V108 Item 6 (dns2-derived): adds history.json probe + mixed/source classes.
    # Probe order (deterministic, first-match):
    #   1. RPM db ownership (with drift check vs history "rpm")
    #   2. DEB db ownership (with drift check vs history "deb")
    #   3. History first-entry "type":"source"          → source
    #   4. History first-entry "type":"rpm" no rpm db   → mixed
    #   5. History first-entry "type":"deb" no dpkg db  → mixed
    #   6. ${NFTBAN_GIT_REPO}/.git directory present    → source
    #   7. Fallthrough                                  → unknown
    # Legacy callers that handle "git" as a class can treat "source" identically.

    local history_type
    history_type=$(_read_history_first_type)

    # 1. RPM db check
    if _probe_rpm_owns_nftban; then
        # Drift check: rpm db says yes but history says non-rpm
        if [[ -n "$history_type" && "$history_type" != "rpm" ]]; then
            echo "mixed"
            return 0
        fi
        echo "rpm"
        return 0
    fi

    # 2. DEB db check
    if _probe_dpkg_owns_nftban; then
        # Drift check: dpkg db says yes but history says non-deb
        if [[ -n "$history_type" && "$history_type" != "deb" ]]; then
            echo "mixed"
            return 0
        fi
        echo "deb"
        return 0
    fi

    # 3. History first-entry "source" — the dns2 case
    if [[ "$history_type" == "source" ]]; then
        echo "source"
        return 0
    fi

    # 4. History "rpm" but no rpm-db → drifted (rpm package removed but history retained)
    if [[ "$history_type" == "rpm" ]]; then
        echo "mixed"
        return 0
    fi

    # 5. History "deb" but no dpkg-db → drifted
    if [[ "$history_type" == "deb" ]]; then
        echo "mixed"
        return 0
    fi

    # 6. Git source checkout (legacy "git" class) — return canonical "source"
    if _probe_git_repo_present; then
        echo "source"
        return 0
    fi

    # 7. Fallthrough
    echo "unknown"
    return 0
}

# -----------------------------------------------------------------------------
# Gate-framework classifier: maps install_type → exit code for direct
# package-manager update paths.
#
# Args:
#   $1 - target package family ("rpm" or "deb")
#
# Exit codes (per V108_ITEM6_SOURCE_INSTALL_DETECTION_SCOPE.md §6.3):
#   0   PROCEED (host method matches target family)
#   10  NOT_APPLICABLE_SOURCE_INSTALL
#   11  NOT_APPLICABLE_UNKNOWN_INSTALL_METHOD
#   12  PRECONDITION_MISMATCH_PACKAGER_FAMILY (rpm host + deb target etc.)
#   13  PRECONDITION_MISMATCH_REQUIRES_OPERATOR (mixed)
# -----------------------------------------------------------------------------
_classify_for_pkg_mgr_update() {
    local target_family="${1:-}"
    if [[ -z "$target_family" ]]; then
        return 11
    fi

    local install_type
    install_type=$(_detect_install_type)

    case "$install_type" in
        rpm)
            [[ "$target_family" == "rpm" ]] && return 0 || return 12
            ;;
        deb)
            [[ "$target_family" == "deb" ]] && return 0 || return 12
            ;;
        source)
            return 10
            ;;
        mixed)
            return 13
            ;;
        unknown|*)
            return 11
            ;;
    esac
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
        source /etc/os-release || true

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

            # Version mismatch detection (both directions)
            if [[ "$pkg_version" != "$sys_version" ]]; then
                local expected_pkg
                expected_pkg=$(_get_distro_package_name)
                if [[ "$pkg_version" -gt "$sys_version" ]]; then
                    _update_log ERROR "Package incompatibility detected"
                    _update_log ERROR "Package built for: EL${pkg_version}"
                    _update_log ERROR "System version: EL${sys_version}"
                    _update_log INFO "Packages built for newer OS may have library incompatibilities"
                    _update_log INFO "Use: nftban update github  (auto-selects correct package)"
                    _update_log INFO "Expected package: $expected_pkg"
                    return 1
                else
                    _update_log WARN "Package version mismatch detected"
                    _update_log WARN "Package built for: EL${pkg_version}"
                    _update_log WARN "System version: EL${sys_version}"
                    _update_log INFO "Expected package: $expected_pkg"
                    _update_log INFO "Use: nftban update github  (auto-selects correct package)"
                fi
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
                if [[ "$pkg_deb_ver" != "$version" ]]; then
                    local expected_pkg
                    expected_pkg=$(_get_distro_package_name)
                    if [[ "$pkg_deb_ver" -gt "$version" ]]; then
                        _update_log ERROR "Package incompatibility detected"
                        _update_log ERROR "Package built for: Debian ${pkg_deb_ver}"
                        _update_log ERROR "System version: Debian ${version}"
                    else
                        _update_log ERROR "Wrong distro package detected"
                        _update_log ERROR "Package built for: Debian ${pkg_deb_ver}"
                        _update_log ERROR "System version: Debian ${version}"
                    fi
                    _update_log INFO "Expected package: $expected_pkg"
                    _update_log INFO "Use: nftban update github  (auto-selects correct package)"
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

                if [[ "$pkg_major" != "$sys_major" ]]; then
                    local expected_pkg
                    expected_pkg=$(_get_distro_package_name)
                    if [[ "$pkg_major" -gt "$sys_major" ]]; then
                        _update_log ERROR "Package incompatibility detected"
                        _update_log ERROR "Package built for: Ubuntu ${pkg_ubuntu_ver}"
                        _update_log ERROR "System version: Ubuntu ${version}"
                        _update_log INFO "Expected package: $expected_pkg"
                        return 1
                    else
                        _update_log ERROR "Wrong distro package detected"
                        _update_log ERROR "Package built for: Ubuntu ${pkg_ubuntu_ver}"
                        _update_log ERROR "System version: Ubuntu ${version}"
                        _update_log INFO "Expected package: $expected_pkg"
                        _update_log INFO "Use: nftban update github  (auto-selects correct package)"
                        return 1
                    fi
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

