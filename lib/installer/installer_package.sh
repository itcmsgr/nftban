#!/usr/bin/env bash

# =============================================================================
# NFTBan Installer - Package Management Module
# Version: 0.9.0
# Location: lib/installer/installer_package.sh
# Provides: Package manager detection, dependency installation
# =============================================================================

[[ -n "${INSTALLER_PACKAGE_LOADED:-}" ]] && return 0
readonly INSTALLER_PACKAGE_LOADED=1

# =============================================================================
# PACKAGE CONFIGURATION
# =============================================================================
export PKG_MANAGER=""
export PKG_UPDATE_CMD=""
export PKG_INSTALL_CMD=""

# Package names (may vary by distro)
readonly FAIL2BAN_PKG="fail2ban"
readonly WHOIS_PKG="whois"
readonly IPCALC_PKG="ipcalc"
readonly SIPCALC_PKG="sipcalc"
readonly GIT_PKG="git"
readonly CURL_PKG="curl"
readonly WGET_PKG="wget"
readonly NFTABLES_PKG="nftables"

# DNS utils package (varies by distro)
DNSUTILS_PKG=""

# =============================================================================
# PACKAGE MANAGER DETECTION
# =============================================================================

installer_detect_package_manager() {
    installer_log_info "Detecting package manager..."
    
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_UPDATE_CMD="apt-get update -qq"
        PKG_INSTALL_CMD="apt-get install -y -qq"
        DNSUTILS_PKG="dnsutils"
        installer_log_debug "Detected: apt (Debian/Ubuntu)"
        
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_UPDATE_CMD="dnf check-update -q"
        PKG_INSTALL_CMD="dnf install -y -q"
        DNSUTILS_PKG="bind-utils"
        installer_log_debug "Detected: dnf (Fedora/RHEL 8+)"
        
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_UPDATE_CMD="yum check-update -q"
        PKG_INSTALL_CMD="yum install -y -q"
        DNSUTILS_PKG="bind-utils"
        installer_log_debug "Detected: yum (RHEL/CentOS)"
        
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_UPDATE_CMD="zypper refresh -q"
        PKG_INSTALL_CMD="zypper install -y"
        DNSUTILS_PKG="bind-utils"
        installer_log_debug "Detected: zypper (openSUSE)"
        
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_UPDATE_CMD="apk update -q"
        PKG_INSTALL_CMD="apk add --no-cache"
        DNSUTILS_PKG="bind-tools"
        installer_log_debug "Detected: apk (Alpine)"
        
    else
        installer_log_error "No supported package manager found"
        installer_log_error "Supported: apt, dnf, yum, zypper, apk"
        return 1
    fi
    
    installer_log_success "Package manager: $PKG_MANAGER"
    return 0
}

# =============================================================================
# PACKAGE OPERATIONS
# =============================================================================

installer_update_package_cache() {
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would update package cache"
        return 0
    fi
    
    installer_log_info "Updating package cache..."
    
    case "$PKG_MANAGER" in
        apt)
            eval "$PKG_UPDATE_CMD" >/dev/null 2>&1 || {
                installer_log_warn "Package cache update failed (continuing anyway)"
                return 0
            }
            ;;
        *)
            eval "$PKG_UPDATE_CMD" >/dev/null 2>&1 || true
            ;;
    esac
    
    installer_log_success "Package cache updated"
    return 0
}

installer_package_exists() {
    local package="$1"
    command -v "$package" >/dev/null 2>&1
}

installer_install_package() {
    local package="$1"
    
    if installer_package_exists "$package"; then
        installer_log_debug "$package already installed"
        return 0
    fi
    
    installer_log_info "Installing $package..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would install: $package"
        return 0
    fi
    
    case "$PKG_MANAGER" in
        apt|dnf|yum|zypper|apk)
            if eval "$PKG_INSTALL_CMD $package" >/dev/null 2>&1; then
                installer_log_success "$package installed"
                return 0
            else
                installer_log_warn "Failed to install $package"
                return 1
            fi
            ;;
        *)
            installer_log_error "Unsupported package manager: $PKG_MANAGER"
            return 1
            ;;
    esac
}

# =============================================================================
# OS DETECTION
# =============================================================================

installer_get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "ID=$ID"
        echo "VERSION_ID=$VERSION_ID"
        echo "ID_LIKE=$ID_LIKE"
    fi
}

installer_is_rhel_like() {
    [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "yum" ]] && return 0
    
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        [[ "$ID_LIKE" == *rhel* || "$ID_LIKE" == *fedora* || "$ID_LIKE" == *centos* ]] && return 0
    fi
    
    return 1
}

# =============================================================================
# EPEL REPOSITORY (RHEL-like systems)
# =============================================================================

installer_install_epel() {
    if ! installer_is_rhel_like; then
        return 0
    fi
    
    installer_log_info "RHEL-like system detected - checking EPEL repository"
    
    # Check if EPEL is already installed
    if rpm -q epel-release >/dev/null 2>&1; then
        installer_log_info "EPEL repository already installed"
        return 0
    fi
    
    if [[ "$INSTALLER_ASSUME_YES" == "false" ]] && ! installer_confirm "Install EPEL repository? (required for fail2ban)"; then
        installer_log_error "EPEL repository is required for fail2ban"
        return 1
    fi
    
    installer_log_info "Installing EPEL repository..."
    
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would install EPEL repository"
        return 0
    fi
    
    # Try package manager first
    if eval "$PKG_INSTALL_CMD epel-release" >/dev/null 2>&1; then
        installer_log_success "EPEL repository installed"
        return 0
    fi
    
    # Fallback to direct RPM installation
    installer_log_info "Trying direct EPEL RPM installation..."
    
    local version major_version epel_url
    version=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release 2>/dev/null || echo "9")
    major_version="${version%%.*}"
    epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major_version}.noarch.rpm"
    
    if command -v dnf >/dev/null 2>&1; then
        dnf -y install "$epel_url" >/dev/null 2>&1 || {
            installer_log_error "Failed to install EPEL from $epel_url"
            return 1
        }
    elif command -v yum >/dev/null 2>&1; then
        yum -y install "$epel_url" >/dev/null 2>&1 || {
            installer_log_error "Failed to install EPEL from $epel_url"
            return 1
        }
    else
        installer_log_error "Cannot install EPEL: no suitable package manager"
        return 1
    fi
    
    installer_log_success "EPEL repository installed"
    return 0
}

# =============================================================================
# DEPENDENCY INSTALLATION
# =============================================================================

installer_install_dependencies() {
    if [[ "$INSTALLER_SKIP_DEPS" == "true" ]]; then
        installer_log_info "Skipping dependency installation (--skip-deps)"
        return 0
    fi
    
    installer_log_info "Installing dependencies..."
    
    # Detect package manager
    installer_detect_package_manager || return 1
    
    # Update package cache
    installer_update_package_cache
    
    # Install EPEL if needed
    installer_install_epel || return 1
    
    # Core dependencies (critical)
    local core_deps=(
        "$NFTABLES_PKG"
        "$FAIL2BAN_PKG"
        "$CURL_PKG"
        "$WGET_PKG"
    )
    
    # Optional dependencies (non-critical)
    local optional_deps=(
        "$WHOIS_PKG"
        "$IPCALC_PKG"
        "$SIPCALC_PKG"
        "$DNSUTILS_PKG"
    )
    
    # Add git if using GitHub method
    if [[ "$INSTALLER_METHOD" == "github" ]]; then
        core_deps+=("$GIT_PKG")
    fi
    
    local failed_critical=()
    local failed_optional=()
    
    # Install core dependencies
    for pkg in "${core_deps[@]}"; do
        if ! installer_install_package "$pkg"; then
            failed_critical+=("$pkg")
        fi
    done
    
    # Install optional dependencies
    for pkg in "${optional_deps[@]}"; do
        if ! installer_install_package "$pkg"; then
            failed_optional+=("$pkg")
        fi
    done
    
    # Check for critical failures
    if (( ${#failed_critical[@]} > 0 )); then
        installer_log_error "Critical packages failed to install: ${failed_critical[*]}"
        return 1
    fi
    
    # Warn about optional failures
    if (( ${#failed_optional[@]} > 0 )); then
        installer_log_warn "Optional packages not available: ${failed_optional[*]}"
        installer_log_warn "Some features may be limited"
    fi
    
    # Verify critical commands
    local missing_commands=()
    for cmd in nft fail2ban-client; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if (( ${#missing_commands[@]} > 0 )); then
        installer_log_error "Critical commands not found: ${missing_commands[*]}"
        return 1
    fi
    
    installer_log_success "All dependencies installed"
    
    # Show installation summary
    echo ""
    echo "Installed packages:"
    for cmd in nft fail2ban-client git curl wget whois ipcalc sipcalc; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version
            case "$cmd" in
                nft)
                    version=$(nft --version 2>/dev/null | head -1)
                    ;;
                fail2ban-client)
                    version=$(fail2ban-client --version 2>/dev/null | head -1)
                    ;;
                git)
                    version=$(git --version 2>/dev/null | head -1)
                    ;;
                *)
                    version="installed"
                    ;;
            esac
            echo "  ✓ $cmd: $version"
        fi
    done
    
    return 0
}

# =============================================================================
# DEPENDENCY VERIFICATION
# =============================================================================

installer_verify_dependencies() {
    installer_log_info "Verifying dependencies..."
    
    local missing=()
    local critical_commands=(
        "nft:nftables"
        "fail2ban-client:fail2ban"
    )
    
    for entry in "${critical_commands[@]}"; do
        local cmd="${entry%%:*}"
        local pkg="${entry##*:}"
        
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$pkg")
            installer_log_error "Missing: $pkg"
        fi
    done
    
    if (( ${#missing[@]} > 0 )); then
        installer_log_error "Verification failed: ${missing[*]} not found"
        return 1
    fi
    
    installer_log_success "All critical dependencies verified"
    return 0
}

# =============================================================================
# MODULE LOADED
# =============================================================================
# NOTE: Functions are available via sourcing in installer_main.sh
# No export needed - all operations happen in same shell process
# (Per NFTBan Avoid Export Functions Guide 2025-10-20)

installer_log_debug "Package management module loaded"
