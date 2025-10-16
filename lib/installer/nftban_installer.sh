#!/usr/bin/env bash

# =============================================================================
# NFTBan Installation & Management Script
# Version: 7.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   Complete installation, update, maintenance, and removal tool for nftban
#   Compatible with modular architecture v6.0.0+
#
# Features:
#   - GitHub repository sync with fallback ZIP download
#   - Complete modular architecture installation
#   - Automatic dependency installation
#   - IP validation tools setup (ipcalc, sipcalc)
#   - Control panel detection and configuration
#   - Auto-update functionality
#   - Safe uninstallation with backup options
#   - System verification and health checks
#
# Usage:
#   sudo ./nftban_installer.sh [command] [options]
#
# Commands:
#   install     - Install nftban system
#   update      - Update to latest version
#   upgrade     - Upgrade existing installation
#   uninstall   - Remove nftban system
#   verify      - Verify installation integrity
#   status      - Show installation status
#   repair      - Repair broken installation
#
# Examples:
#   sudo ./nftban_installer.sh install --github
#   sudo ./nftban_installer.sh install --zip --auto-update
#   sudo ./nftban_installer.sh update
#   sudo ./nftban_installer.sh uninstall --purge
#   sudo ./nftban_installer.sh verify
# =============================================================================

set -euo pipefail

# =============================================================================
# VERSION & CONFIGURATION
# =============================================================================
readonly INSTALLER_VERSION="7.0.0"
readonly NFTBAN_MIN_VERSION="6.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repository configuration
readonly REPO_URL="https://github.com/itcmsgr/nftban"
readonly REPO_BRANCH="main"
readonly ZIP_URL="https://github.com/itcmsgr/nftban/archive/refs/heads/main.zip"

# Installation paths
readonly INSTALL_DIR="/etc/nftban"
readonly LIB_DIR="${INSTALL_DIR}/lib"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly CACHE_DIR="${INSTALL_DIR}/cache"
readonly LOG_DIR="/var/log/nftban"
readonly BACKUP_DIR="/var/backups/nftban"
readonly BIN_DIR="${INSTALL_DIR}/bin"
readonly TEMPLATE_DIR="${INSTALL_DIR}/templates"

# System paths
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly BIN_LINK="/usr/local/bin/nftban"

# Log file
readonly INSTALL_LOG="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

# State files
readonly VERSION_FILE="${INSTALL_DIR}/.version"
readonly INSTALL_STATE="${INSTALL_DIR}/.install_state"

# =============================================================================
# GLOBALS
# =============================================================================
COMMAND=""
INSTALL_METHOD=""  # github, zip, local
FORCE_REINSTALL=false
AUTO_UPDATE=false
SKIP_DEPS=false
SKIP_CP_DETECT=false
ASSUME_YES=false
DRY_RUN=false
QUIET=false
VERBOSE=false
DO_PURGE=false
DO_BACKUP=true

# Package manager
PKG_MANAGER=""
PKG_UPDATE_CMD=""
PKG_INSTALL_CMD=""

# Temporary directory
WORK_DIR=""

# Colors
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' RESET=''
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
    echo "[${timestamp}] [${level}] ${message}" >> "$INSTALL_LOG" 2>/dev/null || true
    
    if [[ "$QUIET" == "false" ]]; then
        case "$level" in
            ERROR)   echo -e "${RED}[ERROR]${RESET} ${message}" >&2 ;;
            WARN)    echo -e "${YELLOW}[WARN]${RESET} ${message}" >&2 ;;
            SUCCESS) echo -e "${GREEN}[SUCCESS]${RESET} ${message}" ;;
            INFO)    echo -e "${BLUE}[INFO]${RESET} ${message}" ;;
            DEBUG)   [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${RESET} ${message}" ;;
            *)       echo "[${level}] ${message}" ;;
        esac
    fi
}

log_error() { log "ERROR" "$@"; }
log_warn() { log "WARN" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_info() { log "INFO" "$@"; }
log_debug() { log "DEBUG" "$@"; }

die() {
    log_error "$@"
    cleanup
    exit 1
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Try: sudo $0 $*"
    fi
}

confirm() {
    local prompt="${1:-Continue?}"
    
    if [[ "$ASSUME_YES" == "true" ]]; then
        return 0
    fi
    
    local response
    read -r -p "${prompt} [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        log_debug "Cleaning up temporary directory: $WORK_DIR"
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# =============================================================================
# PACKAGE MANAGER DETECTION
# =============================================================================

detect_package_manager() {
    log_info "Detecting package manager..."
    
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_UPDATE_CMD="apt-get update -qq"
        PKG_INSTALL_CMD="apt-get install -y -qq"
        log_debug "Detected: apt (Debian/Ubuntu)"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_UPDATE_CMD="dnf check-update -q"
        PKG_INSTALL_CMD="dnf install -y -q"
        log_debug "Detected: dnf (Fedora/RHEL 8+)"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_UPDATE_CMD="yum check-update -q"
        PKG_INSTALL_CMD="yum install -y -q"
        log_debug "Detected: yum (RHEL/CentOS)"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_UPDATE_CMD="zypper refresh -q"
        PKG_INSTALL_CMD="zypper install -y"
        log_debug "Detected: zypper (openSUSE)"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_UPDATE_CMD="apk update -q"
        PKG_INSTALL_CMD="apk add --no-cache"
        log_debug "Detected: apk (Alpine)"
    else
        die "No supported package manager found (apt/dnf/yum/zypper/apk)"
    fi
    
    log_success "Package manager: $PKG_MANAGER"
}

install_package() {
    local package="$1"
    
    if command -v "$package" >/dev/null 2>&1; then
        log_debug "$package already installed"
        return 0
    fi
    
    log_info "Installing $package..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would install: $package"
        return 0
    fi
    
    eval "$PKG_INSTALL_CMD $package" >/dev/null 2>&1 || {
        log_warn "Failed to install $package"
        return 1
    }
    
    log_success "$package installed"
}

update_package_cache() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update package cache"
        return 0
    fi
    
    log_info "Updating package cache..."
    eval "$PKG_UPDATE_CMD" >/dev/null 2>&1 || true
}

# =============================================================================
# DEPENDENCY INSTALLATION
# =============================================================================

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation"
        return 0
    fi
    
    log_info "Installing dependencies..."
    
    detect_package_manager
    update_package_cache
    
    # Core dependencies
    local core_deps=(
        "nftables"
        "fail2ban"
        "curl"
        "wget"
        "git"
    )
    
    # Utility dependencies
    local util_deps=(
        "whois"
        "ipcalc"
        "sipcalc"
    )
    
    # DNS utilities (package name varies by distro)
    case "$PKG_MANAGER" in
        apt)
            util_deps+=("dnsutils")
            ;;
        dnf|yum|zypper)
            util_deps+=("bind-utils")
            ;;
        apk)
            util_deps+=("bind-tools")
            ;;
    esac
    
    # Install core dependencies (critical)
    for pkg in "${core_deps[@]}"; do
        install_package "$pkg" || die "Failed to install critical package: $pkg"
    done
    
    # Install utility dependencies (non-critical)
    for pkg in "${util_deps[@]}"; do
        install_package "$pkg" || log_warn "Optional package not available: $pkg"
    done
    
    # Verify critical tools
    local missing_critical=()
    for cmd in nft fail2ban-client git curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_critical+=("$cmd")
        fi
    done
    
    if [[ ${#missing_critical[@]} -gt 0 ]]; then
        die "Critical tools missing: ${missing_critical[*]}"
    fi
    
    log_success "All dependencies installed"
}

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================

create_directory_structure() {
    log_info "Creating directory structure..."
    
    local directories=(
        "$INSTALL_DIR"
        "$LIB_DIR"
        "$CONFIG_DIR"
        "$DATA_DIR"
        "$CACHE_DIR"
        "$LOG_DIR"
        "$BACKUP_DIR"
        "$BIN_DIR"
        "$TEMPLATE_DIR"
        "$TEMPLATE_DIR/fail2ban/DEBIAN/jail.d"
        "$TEMPLATE_DIR/fail2ban/DEBIAN/filter.d"
        "$TEMPLATE_DIR/fail2ban/DEBIAN/action.d"
        "$TEMPLATE_DIR/fail2ban/REDHAT/jail.d"
        "$TEMPLATE_DIR/fail2ban/REDHAT/filter.d"
        "$TEMPLATE_DIR/fail2ban/REDHAT/action.d"
        "$TEMPLATE_DIR/control-panels"
        "$CONFIG_DIR/ports"
        "$DATA_DIR/geoip"
        "$DATA_DIR/backups"
        "$CACHE_DIR/geoip"
        "$CACHE_DIR/autorebuild"
    )
    
    for dir in "${directories[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_debug "[DRY-RUN] Would create: $dir"
        else
            mkdir -p "$dir" || die "Failed to create directory: $dir"
            chmod 755 "$dir"
        fi
    done
    
    # Create logs symlink
    if [[ ! -L "$INSTALL_DIR/logs" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            ln -sf "$LOG_DIR" "$INSTALL_DIR/logs"
        fi
    fi
    
    log_success "Directory structure created"
}

# =============================================================================
# INSTALLATION METHODS
# =============================================================================

install_from_github() {
    log_info "Installing from GitHub repository..."
    
    if ! command -v git >/dev/null 2>&1; then
        die "git is required for GitHub installation"
    fi
    
    WORK_DIR=$(mktemp -d /tmp/nftban_install.XXXXXX)
    
    log_info "Cloning repository: $REPO_URL"
    log_debug "Branch: $REPO_BRANCH"
    log_debug "Work directory: $WORK_DIR"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would clone from: $REPO_URL"
        return 0
    fi
    
    if ! git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR/nftban" 2>&1 | tee -a "$INSTALL_LOG"; then
        die "Failed to clone repository"
    fi
    
    log_success "Repository cloned successfully"
    
    # Copy files to installation directory
    copy_installation_files "$WORK_DIR/nftban"
}

install_from_zip() {
    log_info "Installing from ZIP archive..."
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "curl or wget is required for ZIP installation"
    fi
    
    WORK_DIR=$(mktemp -d /tmp/nftban_install.XXXXXX)
    
    log_info "Downloading: $ZIP_URL"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would download from: $ZIP_URL"
        return 0
    fi
    
    local zip_file="$WORK_DIR/nftban.zip"
    
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$ZIP_URL" -o "$zip_file" || die "Failed to download ZIP"
    else
        wget -q "$ZIP_URL" -O "$zip_file" || die "Failed to download ZIP"
    fi
    
    log_info "Extracting archive..."
    unzip -q "$zip_file" -d "$WORK_DIR" || die "Failed to extract ZIP"
    
    local extracted_dir
    extracted_dir=$(find "$WORK_DIR" -maxdepth 1 -type d -name "nftban-*" | head -1)
    
    if [[ -z "$extracted_dir" ]]; then
        die "Failed to find extracted directory"
    fi
    
    log_success "Archive extracted successfully"
    
    # Copy files to installation directory
    copy_installation_files "$extracted_dir"
}

copy_installation_files() {
    local source_dir="$1"
    
    log_info "Copying installation files..."
    
    if [[ ! -d "$source_dir" ]]; then
        die "Source directory not found: $source_dir"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would copy files from: $source_dir"
        return 0
    fi
    
    # Copy lib modules
    if [[ -d "$source_dir/lib" ]]; then
        cp -r "$source_dir/lib/"* "$LIB_DIR/" || die "Failed to copy lib files"
        log_debug "Copied lib modules"
    fi
    
    # Copy bin files
    if [[ -d "$source_dir/bin" ]]; then
        cp -r "$source_dir/bin/"* "$BIN_DIR/" || die "Failed to copy bin files"
        chmod +x "$BIN_DIR"/* 2>/dev/null || true
        log_debug "Copied bin files"
    fi
    
    # Copy templates
    if [[ -d "$source_dir/templates" ]]; then
        cp -r "$source_dir/templates/"* "$TEMPLATE_DIR/" || die "Failed to copy templates"
        log_debug "Copied templates"
    fi
    
    # Copy config examples (don't overwrite existing)
    if [[ -d "$source_dir/config" ]]; then
        for file in "$source_dir/config"/*; do
            local basename
            basename=$(basename "$file")
            if [[ ! -f "$CONFIG_DIR/$basename" ]]; then
                cp "$file" "$CONFIG_DIR/" || true
            fi
        done
        log_debug "Copied config examples"
    fi
    
    # Copy documentation
    if [[ -d "$source_dir/docs" ]]; then
        cp -r "$source_dir/docs" "$INSTALL_DIR/" 2>/dev/null || true
    fi
    
    log_success "Installation files copied"
}

# =============================================================================
# NFTBAN CLI SETUP
# =============================================================================

setup_nftban_cli() {
    log_info "Setting up nftban CLI..."
    
    local cli_script="$BIN_DIR/nftban"
    
    if [[ ! -f "$cli_script" ]]; then
        log_warn "CLI script not found, creating minimal version"
        create_minimal_cli
    fi
    
    if [[ "$DRY_RUN" == "false" ]]; then
        chmod +x "$cli_script"
        
        # Create global symlink
        ln -sf "$cli_script" "$BIN_LINK"
        
        log_success "CLI installed: $BIN_LINK"
    else
        log_info "[DRY-RUN] Would create CLI at: $BIN_LINK"
    fi
}

create_minimal_cli() {
    cat > "$BIN_DIR/nftban" << 'NFTBAN_CLI'
#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="/etc/nftban/lib"

if [[ ! -f "$LIB_DIR/nftban_core.sh" ]]; then
    echo "ERROR: nftban not properly installed" >&2
    echo "Core module not found at: $LIB_DIR/nftban_core.sh" >&2
    exit 1
fi

# Check if main CLI exists
if [[ -f "$LIB_DIR/nftban_main_cli.sh" ]]; then
    exec bash "$LIB_DIR/nftban_main_cli.sh" "$@"
elif [[ -f "/etc/nftban/nftban_main_cli.sh" ]]; then
    exec bash "/etc/nftban/nftban_main_cli.sh" "$@"
else
    echo "ERROR: Main CLI script not found" >&2
    echo "Run installer again to restore: sudo nftban_installer.sh update" >&2
    exit 1
fi
NFTBAN_CLI
    
    chmod +x "$BIN_DIR/nftban"
}

# =============================================================================
# CONTROL PANEL DETECTION
# =============================================================================

detect_control_panel() {
    if [[ "$SKIP_CP_DETECT" == "true" ]]; then
        log_info "Skipping control panel detection"
        return 0
    fi
    
    log_info "Detecting control panel..."
    
    local panel=""
    
    if [[ -d "/usr/local/directadmin" ]]; then
        panel="DirectAdmin"
        log_info "Detected: DirectAdmin"
    elif [[ -d "/var/cpanel" ]]; then
        panel="cPanel"
        log_info "Detected: cPanel"
    elif [[ -d "/usr/local/psa" ]]; then
        panel="Plesk"
        log_info "Detected: Plesk"
    else
        log_info "No control panel detected"
        panel="generic"
    fi
    
    # Create appropriate config template
    create_config_template "$panel"
}

create_config_template() {
    local panel="$1"
    
    log_info "Creating configuration template for: $panel"
    
    # This would call appropriate template creation functions
    # For now, just create empty configs
    
    local config_files=(
        "nftban.conf"
        "whitelist-system.conf"
        "whitelist-user.conf"
        "blacklist-persistent.conf"
        "blacklist-user.conf"
    )
    
    for file in "${config_files[@]}"; do
        if [[ ! -f "$CONFIG_DIR/$file" ]]; then
            touch "$CONFIG_DIR/$file"
            chmod 644 "$CONFIG_DIR/$file"
        fi
    done
    
    log_success "Configuration templates created"
}

# =============================================================================
# SYSTEM INITIALIZATION
# =============================================================================

initialize_system() {
    log_info "Initializing nftban system..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize system"
        return 0
    fi
    
    # Source core module
    if [[ -f "$LIB_DIR/nftban_core.sh" ]]; then
        source "$LIB_DIR/nftban_core.sh" || die "Failed to source core module"
        log_debug "Core module loaded"
    else
        log_warn "Core module not found, skipping initialization"
        return 0
    fi
    
    # Initialize directories (core module function)
    if command -v nftban_init_directories >/dev/null 2>&1; then
        nftban_init_directories
    fi
    
    # Initialize modules
    if command -v nftban_whitelist_init >/dev/null 2>&1; then
        nftban_whitelist_init
    fi
    
    if command -v nftban_blacklist_init >/dev/null 2>&1; then
        nftban_blacklist_init
    fi
    
    if command -v nftban_search_init >/dev/null 2>&1; then
        nftban_search_init
    fi
    
    log_success "System initialized"
}

# =============================================================================
# AUTO-UPDATE SETUP
# =============================================================================

setup_auto_update() {
    if [[ "$AUTO_UPDATE" == "false" ]]; then
        return 0
    fi
    
    log_info "Setting up auto-update..."
    
    local update_script="/etc/cron.daily/nftban-update"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create auto-update cron"
        return 0
    fi
    
    cat > "$update_script" << 'UPDATE_SCRIPT'
#!/bin/bash
# nftban auto-update script

LOG_FILE="/var/log/nftban/auto-update.log"
INSTALL_DIR="/etc/nftban"

echo "[$(date)] Starting auto-update" >> "$LOG_FILE"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    git fetch --all --quiet
    git reset --hard origin/main --quiet
    git pull --quiet
    echo "[$(date)] Update completed via git" >> "$LOG_FILE"
else
    echo "[$(date)] Not a git repository, skipping" >> "$LOG_FILE"
fi
UPDATE_SCRIPT
    
    chmod +x "$update_script"
    log_success "Auto-update configured"
}

# =============================================================================
# BACKUP & RESTORE
# =============================================================================

create_backup() {
    if [[ "$DO_BACKUP" == "false" ]]; then
        return 0
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_debug "Nothing to backup"
        return 0
    fi
    
    local backup_file="$BACKUP_DIR/nftban_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    log_info "Creating backup: $backup_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create backup"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    tar -czf "$backup_file" -C / "${INSTALL_DIR#/}" 2>/dev/null || {
        log_warn "Backup failed"
        return 1
    }
    
    log_success "Backup created: $backup_file"
}

# =============================================================================
# UNINSTALLATION
# =============================================================================

uninstall_nftban() {
    log_info "Uninstalling nftban..."
    
    if ! confirm "Are you sure you want to uninstall nftban?"; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    # Create backup before uninstall
    if [[ "$DO_PURGE" == "false" ]]; then
        create_backup
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would uninstall nftban"
        return 0
    fi
    
    # Stop services
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nftban 2>/dev/null || true
        systemctl disable nftban 2>/dev/null || true
    fi
    
    # Remove symlink
    rm -f "$BIN_LINK"
    
    # Remove installation directory
    rm -rf "$INSTALL_DIR"
    
    # Handle purge
    if [[ "$DO_PURGE" == "true" ]]; then
        log_info "Purging all data..."
        rm -rf "$LOG_DIR"
        rm -rf "$BACKUP_DIR"
        rm -rf /etc/fail2ban/jail.d/nftban-*.conf
        rm -rf /etc/fail2ban/filter.d/nftban-*.conf
        rm -rf /etc/fail2ban/action.d/nftban-*.conf
    else
        log_info "Logs preserved in: $LOG_DIR"
        log_info "Backups preserved in: $BACKUP_DIR"
    fi
    
    log_success "Uninstall complete"
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    
    # Check directories
    local required_dirs=(
        "$INSTALL_DIR"
        "$LIB_DIR"
        "$CONFIG_DIR"
        "$BIN_DIR"
        "$LOG_DIR"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Missing directory: $dir"
            ((errors++))
        fi
    done
    
    # Check core module
    if [[ ! -f "$LIB_DIR/nftban_core.sh" ]]; then
        log_error "Core module not found"
        ((errors++))
    fi
    
    # Check CLI
    if [[ ! -x "$BIN_LINK" ]]; then
        log_error "CLI not executable or missing"
        ((errors++))
    fi
    
    # Check required commands
    local required_commands=(
        "nft"
        "fail2ban-client"
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            ((errors++))
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        log_success "Verification passed"
        return 0
    else
        log_error "Verification failed: $errors error(s)"
        return 1
    fi
}

# =============================================================================
# STATUS REPORTING
# =============================================================================

show_status() {
    echo ""
    echo "==================================================================="
    echo "  NFTBan Installation Status"
    echo "==================================================================="
    echo ""
    
    # Installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${GREEN}✓${RESET} Installation directory: $INSTALL_DIR"
    else
        echo -e "${RED}✗${RESET} Installation directory: NOT FOUND"
        return 1
    fi
    
    # Version
    if [[ -f "$VERSION_FILE" ]]; then
        local version
        version=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
        echo "  Version: $version"
    fi
    
    echo ""
    
    # Modules
    echo "Modules:"
    local modules=(
        "nftban_core.sh:Core"
        "nftban_nftables_module.sh:nftables"
        "nftban_whitelist_module.sh:Whitelist"
        "nftban_blacklist_module.sh:Blacklist"
        "nftban_fail2ban_module.sh:Fail2ban"
        "nftban_search_module.sh:Search"
        "nftban_cloudflare_module.sh:Cloudflare"
        "nftban_geo_module.sh:GEO"
        "nftban_stats_module.sh:Stats"
    )
    
    for module in "${modules[@]}"; do
        IFS=':' read -r file name <<< "$module"
        if [[ -f "$LIB_DIR/$file" ]]; then
            echo -e "  ${GREEN}✓${RESET} $name"
        else
            echo -e "  ${RED}✗${RESET} $name"
        fi
    done
    
    echo ""
    
    # CLI
    if [[ -x "$BIN_LINK" ]]; then
        echo -e "${GREEN}✓${RESET} CLI: $BIN_LINK"
    else
        echo -e "${RED}✗${RESET} CLI: NOT FOUND"
    fi
    
    echo ""
    
    # Dependencies
    echo "Dependencies:"
    local deps=(
        "nft:nftables"
        "fail2ban-client:fail2ban"
        "whois:whois"
        "ipcalc:IP validation"
        "git:Git"
    )
    
    for dep in "${deps[@]}"; do
        IFS=':' read -r cmd name <<< "$dep"
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $name"
        else
            echo -e "  ${YELLOW}!${RESET} $name (optional)"
        fi
    done
    
    echo ""
    echo "==================================================================="
}

# =============================================================================
# REPAIR INSTALLATION
# =============================================================================

repair_installation() {
    log_info "Repairing installation..."
    
    if ! confirm "This will attempt to repair the installation. Continue?"; then
        log_info "Repair cancelled"
        return 0
    fi
    
    # Recreate directory structure
    create_directory_structure
    
    # Fix permissions
    log_info "Fixing permissions..."
    chmod -R 755 "$LIB_DIR" "$BIN_DIR" 2>/dev/null || true
    chmod -R 644 "$CONFIG_DIR"/* 2>/dev/null || true
    
    # Recreate CLI
    setup_nftban_cli
    
    # Rebuild search index if module exists
    if [[ -f "$LIB_DIR/nftban_core.sh" ]]; then
        source "$LIB_DIR/nftban_core.sh" 2>/dev/null || true
        if command -v nftban_search_build_index >/dev/null 2>&1; then
            log_info "Rebuilding search index..."
            nftban_search_build_index 2>/dev/null || log_warn "Failed to rebuild search index"
        fi
    fi
    
    log_success "Repair complete"
    
    # Verify
    verify_installation
}

# =============================================================================
# UPDATE INSTALLATION
# =============================================================================

update_installation() {
    log_info "Updating nftban installation..."
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        die "nftban is not installed. Use 'install' command first."
    fi
    
    # Create backup
    create_backup
    
    # Detect current installation method
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log_info "Detected git installation, updating via git..."
        update_via_git
    else
        log_warn "Not a git installation, updating via ZIP..."
        install_from_zip
    fi
    
    # Reinitialize
    initialize_system
    
    # Update version file
    echo "$INSTALLER_VERSION" > "$VERSION_FILE"
    
    log_success "Update complete"
}

update_via_git() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update via git"
        return 0
    fi
    
    cd "$INSTALL_DIR" || die "Failed to change to install directory"
    
    log_info "Fetching latest changes..."
    git fetch --all --quiet || die "Failed to fetch"
    
    log_info "Updating to latest version..."
    git reset --hard "origin/$REPO_BRANCH" --quiet || die "Failed to reset"
    git pull --quiet --rebase || die "Failed to pull"
    
    log_success "Git update complete"
}

# =============================================================================
# INSTALLATION STATE MANAGEMENT
# =============================================================================

save_install_state() {
    local state_data="INSTALLER_VERSION=$INSTALLER_VERSION
INSTALL_METHOD=$INSTALL_METHOD
INSTALL_DATE=$(date +%Y-%m-%d_%H:%M:%S)
AUTO_UPDATE=$AUTO_UPDATE
"
    
    echo "$state_data" > "$INSTALL_STATE"
    log_debug "Installation state saved"
}

load_install_state() {
    if [[ -f "$INSTALL_STATE" ]]; then
        source "$INSTALL_STATE"
        log_debug "Installation state loaded"
    fi
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

do_install() {
    log_info "Starting nftban installation..."
    log_info "Installation method: $INSTALL_METHOD"
    
    # Check if already installed
    if [[ -d "$INSTALL_DIR" && "$FORCE_REINSTALL" == "false" ]]; then
        log_warn "nftban appears to be already installed at: $INSTALL_DIR"
        if ! confirm "Reinstall anyway?"; then
            log_info "Installation cancelled"
            exit 0
        fi
        create_backup
    fi
    
    # Create directory structure
    create_directory_structure
    
    # Install dependencies
    install_dependencies
    
    # Install based on method
    case "$INSTALL_METHOD" in
        github)
            install_from_github
            ;;
        zip)
            install_from_zip
            ;;
        *)
            die "Unknown installation method: $INSTALL_METHOD"
            ;;
    esac
    
    # Setup CLI
    setup_nftban_cli
    
    # Detect control panel
    detect_control_panel
    
    # Initialize system
    initialize_system
    
    # Setup auto-update if requested
    setup_auto_update
    
    # Save installation state
    echo "$INSTALLER_VERSION" > "$VERSION_FILE"
    save_install_state
    
    # Verify installation
    if verify_installation; then
        log_success "Installation completed successfully"
        show_completion_message
    else
        log_error "Installation completed with errors"
        exit 1
    fi
}

# =============================================================================
# COMPLETION MESSAGE
# =============================================================================

show_completion_message() {
    echo ""
    echo "==================================================================="
    echo "  NFTBan Installation Complete!"
    echo "==================================================================="
    echo ""
    echo "Installation directory: $INSTALL_DIR"
    echo "CLI command: nftban"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Initialize nftables:"
    echo "   sudo nftban nftables init"
    echo ""
    echo "2. Configure ports and whitelist:"
    echo "   sudo nftban port add 22 T input 4"
    echo "   sudo nftban whitelist add YOUR_IP"
    echo ""
    echo "3. Setup fail2ban integration:"
    echo "   sudo nftban fail2ban setup"
    echo ""
    echo "4. Check status:"
    echo "   sudo nftban status"
    echo ""
    echo "5. View all commands:"
    echo "   nftban help"
    echo ""
    
    if [[ "$AUTO_UPDATE" == "true" ]]; then
        echo "Auto-update: ENABLED (daily)"
    else
        echo "Auto-update: DISABLED"
        echo "  Enable with: sudo $SCRIPT_NAME install --auto-update"
    fi
    
    echo ""
    echo "Documentation: $INSTALL_DIR/docs/"
    echo "Logs: $LOG_DIR/"
    echo ""
    echo "==================================================================="
}

# =============================================================================
# USAGE / HELP
# =============================================================================

show_usage() {
    cat << 'EOF'
=================================================================
  NFTBan Installation & Management Script
  Version: 7.0.0
=================================================================

USAGE:
    nftban_installer.sh <command> [options]

COMMANDS:
    install     Install nftban system
    update      Update existing installation
    upgrade     Alias for update
    uninstall   Remove nftban system
    verify      Verify installation integrity
    status      Show installation status
    repair      Repair broken installation
    help        Show this help message

INSTALL OPTIONS:
    --github            Install from GitHub repository (default)
    --zip               Install from ZIP archive
    --auto-update       Enable automatic daily updates
    --skip-deps         Skip dependency installation
    --skip-cp-detect    Skip control panel detection
    --force             Force reinstallation
    -y, --yes           Assume yes to all prompts
    --dry-run           Show what would be done
    --quiet             Minimal output
    --verbose           Verbose output

UNINSTALL OPTIONS:
    --purge             Remove all data and logs
    --no-backup         Skip backup creation
    -y, --yes           Assume yes to prompts

EXAMPLES:
    # Install from GitHub (recommended)
    sudo ./nftban_installer.sh install --github

    # Install from ZIP with auto-update
    sudo ./nftban_installer.sh install --zip --auto-update

    # Force reinstall
    sudo ./nftban_installer.sh install --force -y

    # Update existing installation
    sudo ./nftban_installer.sh update

    # Verify installation
    sudo ./nftban_installer.sh verify

    # Show status
    sudo ./nftban_installer.sh status

    # Repair installation
    sudo ./nftban_installer.sh repair

    # Uninstall completely
    sudo ./nftban_installer.sh uninstall --purge -y

INSTALLATION PATHS:
    Install directory:  /etc/nftban
    CLI command:        /usr/local/bin/nftban
    Logs:               /var/log/nftban
    Backups:            /var/backups/nftban

SYSTEM REQUIREMENTS:
    - Root access (sudo)
    - Supported OS: Debian, Ubuntu, RHEL, CentOS, Fedora, Rocky, AlmaLinux
    - Package manager: apt, dnf, yum, zypper, or apk
    - Minimum 100MB disk space

DEPENDENCIES (auto-installed):
    Required:
    - nftables
    - fail2ban
    - curl or wget
    - git (for GitHub method)

    Optional:
    - whois
    - ipcalc
    - sipcalc
    - dnsutils/bind-utils

ARCHITECTURE:
    This installer sets up the complete modular nftban system:
    
    Core Module:         Foundation and utilities
    nftables Module:     Firewall management
    Whitelist Module:    IP whitelist management
    Blacklist Module:    IP blacklist and ban operations
    Fail2ban Module:     Fail2ban integration
    Search Module:       Consolidated IP search
    Cloudflare Module:   Cloudflare IP management
    GEO Module:          Country-level blocking
    Stats Module:        Statistics and reporting
    Port Module:         Port management
    Template Module:     Configuration templates
    IPProtect Module:    IP protection
    RateLimit Module:    Rate limiting
    AutoRebuild Module:  Auto-rebuild functionality
    Login Monitor:       Login event monitoring
    Maintenance Module:  System maintenance

DOCUMENTATION:
    After installation, see: /etc/nftban/docs/
    GitHub: https://github.com/itcmsgr/nftban

SUPPORT:
    Report issues: https://github.com/itcmsgr/nftban/issues

=================================================================
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    # Default values
    INSTALL_METHOD="github"
    
    # Parse command
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi
    
    COMMAND="$1"
    shift
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --github)
                INSTALL_METHOD="github"
                shift
                ;;
            --zip)
                INSTALL_METHOD="zip"
                shift
                ;;
            --auto-update)
                AUTO_UPDATE=true
                shift
                ;;
            --skip-deps)
                SKIP_DEPS=true
                shift
                ;;
            --skip-cp-detect)
                SKIP_CP_DETECT=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --purge)
                DO_PURGE=true
                shift
                ;;
            --no-backup)
                DO_BACKUP=false
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Check root
    check_root
    
    # Create log directory
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Log start
    log_info "NFTBan Installer v$INSTALLER_VERSION"
    log_info "Command: $COMMAND"
    
    # Execute command
    case "$COMMAND" in
        install)
            do_install
            ;;
        update|upgrade)
            update_installation
            ;;
        uninstall|remove)
            uninstall_nftban
            ;;
        verify)
            verify_installation
            ;;
        status)
            show_status
            ;;
        repair)
            repair_installation
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            echo ""
            echo "Use '$SCRIPT_NAME help' for usage information"
            exit 1
            ;;
    esac
    
    exit 0
}

# Execute main
main "$@"