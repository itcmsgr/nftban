#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_distro_config" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Load and parse distribution-specific configuration"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_DISTRO_CONF_DIR"
# meta:inventory.config_files="/etc/nftban/distros/*.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_DISTRO_CONFIG_LOADED:-}" ]] && return 0
NFTBAN_DISTRO_CONFIG_LOADED="true"

# Configuration paths (allow override for testing)
: "${NFTBAN_DISTRO_CONF_DIR:=/etc/nftban/distros}"
: "${NFTBAN_DISTRO_CONF_LINK:=/etc/nftban/conf.d/distro.conf}"
: "${NFTBAN_DISTRO_CUSTOM_CONF:=/etc/nftban/conf.d/distro-custom.conf}"

# Global associative arrays for configuration
declare -gA DISTRO_INFO
declare -gA DISTRO_PKGMGR
declare -gA DISTRO_PACKAGES
declare -gA DISTRO_SERVICES
declare -gA DISTRO_PATHS
declare -gA DISTRO_REPOSITORY
declare -gA DISTRO_FEATURES

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# Detect current distribution and version
nftban_distro_detect() {
    local os_id=""
    local os_version=""
    local os_version_id=""

    # Primary: /etc/os-release (systemd standard)
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release || true
        os_id="${ID:-unknown}"
        os_version="${VERSION_ID:-unknown}"
        os_version_id="${VERSION_ID:-unknown}"
    # Fallback: /etc/redhat-release
    elif [[ -f /etc/redhat-release ]]; then
        os_id="rhel"
        os_version=$(grep -oP '\d+' /etc/redhat-release | head -1)
        os_version_id="$os_version"
    # Fallback: /etc/debian_version
    elif [[ -f /etc/debian_version ]]; then
        os_id="debian"
        os_version=$(cat /etc/debian_version)
        os_version_id="$os_version"
    else
        echo "ERROR: Cannot detect distribution" >&2
        return 1
    fi

    # Normalize OS ID
    case "$os_id" in
        centos|centos-stream) os_id="centos" ;;
        rhel|redhat) os_id="rhel" ;;
        rocky) os_id="rocky" ;;
        almalinux|alma) os_id="almalinux" ;;
        debian) os_id="debian" ;;
        ubuntu) os_id="ubuntu" ;;
        fedora) os_id="fedora" ;;
    esac

    echo "${os_id}:${os_version_id}"
}

# Find appropriate configuration file
nftban_distro_find_config() {
    local detection="$1"
    local os_id="${detection%%:*}"
    local os_version="${detection##*:}"

    # Try exact match first: ubuntu-24.04.conf or centos-stream-9.conf
    local config_file="${NFTBAN_DISTRO_CONF_DIR}/${os_id}-${os_version}.conf"
    if [[ -f "$config_file" ]]; then
        echo "$config_file"
        return 0
    fi

    # Try major version: centos-9.conf, ubuntu-24.conf
    local major_version="${os_version%%.*}"
    config_file="${NFTBAN_DISTRO_CONF_DIR}/${os_id}-${major_version}.conf"
    if [[ -f "$config_file" ]]; then
        echo "$config_file"
        return 0
    fi

    # Try generic: centos.conf, ubuntu.conf
    config_file="${NFTBAN_DISTRO_CONF_DIR}/${os_id}.conf"
    if [[ -f "$config_file" ]]; then
        echo "$config_file"
        return 0
    fi

    # Helpful error with what was tried
    echo "ERROR: No configuration file found for ${os_id} ${os_version}" >&2
    echo "       Tried: ${NFTBAN_DISTRO_CONF_DIR}/${os_id}-${os_version}.conf" >&2
    echo "              ${NFTBAN_DISTRO_CONF_DIR}/${os_id}-${major_version}.conf" >&2
    echo "              ${NFTBAN_DISTRO_CONF_DIR}/${os_id}.conf" >&2
    echo "       Config dir: ${NFTBAN_DISTRO_CONF_DIR}" >&2
    return 1
}

# =============================================================================
# CONFIGURATION PARSING
# =============================================================================

# Parse INI configuration file
nftban_distro_parse_config() {
    local config_file="$1"
    local current_section=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Section headers: [section]
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Key-value pairs: key = value
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Trim whitespace
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            # Remove quotes
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            # Store in appropriate associative array
            case "$current_section" in
                distro)
                    DISTRO_INFO["$key"]="$value"
                    ;;
                package_manager)
                    DISTRO_PKGMGR["$key"]="$value"
                    ;;
                packages)
                    DISTRO_PACKAGES["$key"]="$value"
                    ;;
                services)
                    DISTRO_SERVICES["$key"]="$value"
                    ;;
                paths)
                    DISTRO_PATHS["$key"]="$value"
                    ;;
                repository)
                    DISTRO_REPOSITORY["$key"]="$value"
                    ;;
                features)
                    DISTRO_FEATURES["$key"]="$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize distribution configuration
nftban_distro_init() {
    # Detect distribution
    local detection
    detection=$(nftban_distro_detect) || return 1

    # Find configuration file
    local config_file
    config_file=$(nftban_distro_find_config "$detection") || return 1

    # Parse main configuration
    nftban_distro_parse_config "$config_file"

    # Parse custom overrides if exists
    if [[ -f "$NFTBAN_DISTRO_CUSTOM_CONF" ]]; then
        nftban_distro_parse_config "$NFTBAN_DISTRO_CUSTOM_CONF"
    fi

    return 0
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get package name for current distribution
nftban_distro_get_package() {
    local package_name="$1"
    echo "${DISTRO_PACKAGES[$package_name]:-}"
}

# Get service name for current distribution
nftban_distro_get_service() {
    local service_name="$1"
    echo "${DISTRO_SERVICES[$service_name]:-}"
}

# Get binary path for current distribution
nftban_distro_get_path() {
    local path_name="$1"
    echo "${DISTRO_PATHS[$path_name]:-}"
}

# Get package manager command
nftban_distro_get_pkgmgr_cmd() {
    local cmd_type="$1"  # install_cmd, update_cmd, etc.
    echo "${DISTRO_PKGMGR[$cmd_type]:-}"
}

# Install packages using distribution's package manager
nftban_distro_install_packages() {
    local packages=("$@")
    local install_cmd
    install_cmd=$(nftban_distro_get_pkgmgr_cmd "install_cmd")

    if [[ -z "$install_cmd" ]]; then
        echo "ERROR: Package manager install command not configured" >&2
        return 1
    fi

    # Execute installation
    $install_cmd "${packages[@]}"
}

# Restart service using correct service name
nftban_distro_restart_service() {
    local service_key="$1"
    local service_name
    service_name=$(nftban_distro_get_service "$service_key")

    if [[ -z "$service_name" ]]; then
        echo "ERROR: Service '$service_key' not found in configuration" >&2
        return 1
    fi

    systemctl restart "$service_name"
}

# Check if a package is installed
nftban_distro_is_package_installed() {
    local package="$1"

    # Get query command from config
    local query_cmd="${DISTRO_PKGMGR[query_cmd]:-}"

    if [[ -z "$query_cmd" ]]; then
        echo "ERROR: No query_cmd configured" >&2
        return 1
    fi

    # Execute query based on package manager type
    case "$query_cmd" in
        *dpkg*)
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
        *rpm*)
            rpm -qa | grep -q "^${package}"
            ;;
        *)
            echo "ERROR: Unsupported query command: $query_cmd" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# POLKIT PATH RESOLUTION
# =============================================================================
# Get canonical polkit rules directory for current distribution.
# This is the SINGLE SOURCE OF TRUTH for polkit path resolution.
#
# Resolution order:
#   1. Distro config [paths].polkit_rules_dir (preferred)
#   2. Fallback by distro family (debian vs rhel)
#   3. Final fallback: /etc/polkit-1/rules.d
#
# Usage:
#   polkit_dir=$(nftban_distro_get_polkit_dir)
#   install -m 644 "$rule_file" "$polkit_dir/"
# =============================================================================
nftban_distro_get_polkit_dir() {
    # 1. Try distro config first (source of truth)
    local path="${DISTRO_PATHS[polkit_rules_dir]:-}"
    if [[ -n "$path" ]]; then
        echo "$path"
        return 0
    fi

    # 2. Fallback: detect by distro family
    local family="${DISTRO_INFO[family]:-unknown}"
    case "$family" in
        debian|ubuntu)
            echo "/usr/share/polkit-1/rules.d"
            ;;
        rhel|fedora|centos|rocky|almalinux)
            echo "/etc/polkit-1/rules.d"
            ;;
        *)
            # 3. Final fallback: /etc is most common
            echo "/etc/polkit-1/rules.d"
            ;;
    esac
}

# Show current configuration (diagnostic)
nftban_distro_show_config() {
    echo "=== Distribution Configuration ==="
    echo ""
    echo "[Distribution Info]"
    for key in "${!DISTRO_INFO[@]}"; do
        echo "  $key = ${DISTRO_INFO[$key]}"
    done | sort
    echo ""
    echo "[Package Manager]"
    for key in "${!DISTRO_PKGMGR[@]}"; do
        echo "  $key = ${DISTRO_PKGMGR[$key]}"
    done | sort
    echo ""
    echo "[Packages]"
    for key in "${!DISTRO_PACKAGES[@]}"; do
        echo "  $key = ${DISTRO_PACKAGES[$key]}"
    done | sort
    echo ""
    echo "[Services]"
    for key in "${!DISTRO_SERVICES[@]}"; do
        echo "  $key = ${DISTRO_SERVICES[$key]}"
    done | sort
    echo ""
    echo "[Paths]"
    for key in "${!DISTRO_PATHS[@]}"; do
        echo "  $key = ${DISTRO_PATHS[$key]}"
    done | sort
    echo ""
    echo "[Repository]"
    for key in "${!DISTRO_REPOSITORY[@]}"; do
        echo "  $key = ${DISTRO_REPOSITORY[$key]}"
    done | sort
    echo ""
    echo "[Features]"
    for key in "${!DISTRO_FEATURES[@]}"; do
        echo "  $key = ${DISTRO_FEATURES[$key]}"
    done | sort
}

# =============================================================================
# AUTO-INITIALIZE ON SOURCE
# =============================================================================

# Auto-initialize when module is loaded (unless disabled)
if [[ "${NFTBAN_DISTRO_AUTO_INIT:-true}" == "true" ]]; then
    nftban_distro_init || {
        echo "WARNING: Failed to initialize distribution configuration" >&2
    }
fi

return 0 2>/dev/null || :
