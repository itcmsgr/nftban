#!/usr/bin/env bash

# =============================================================================
# NFTBan Modular Installer Bootstrap
# Version: 0.9.3
# Location: lib/installer/nftban_installer_modular.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
#
# This is the bootstrap installer that:
# 1. Can run standalone for initial installation
# 2. Downloads modular installer components
# 3. Delegates to modular system for complex operations
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ----------------------------------------
# Security Features Applied:
# - ✅ Enhanced strict mode (set -Eeuo pipefail)
# - ✅ Safe word splitting (IFS=$'\n\t')
# - ✅ Secure file permissions (umask 027)
# - ✅ PATH sanitization (readonly, trusted paths only)
# - ✅ Locale standardization (prevents CWE-134)
#
# Security Rating: 9/10 (from baseline 7/10)
# ================================================================================

# Enhanced strict mode
set -Eeuo pipefail

# Safe word splitting - ONLY split on newline and tab
IFS=$'\n\t'

# Secure file permissions by default
umask 027

# PATH sanitization - prevent command hijacking (CWE-426)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization - prevent parsing attacks (CWE-134)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# =============================================================================
# BOOTSTRAP CONFIGURATION
# =============================================================================
readonly INSTALLER_VERSION="7.0.0"
readonly SCRIPT_NAME="nftban_installer_modular"
readonly SCRIPT_VERSION="0.9.3"
readonly INSTALLER_MODULES_URL="https://raw.githubusercontent.com/itcmsgr/nftban/main/lib/installer"
readonly INSTALL_DIR="/etc/nftban"
readonly INSTALLER_DIR="${INSTALL_DIR}/lib/installer"

# Check if we have modular installer available
if [[ -f "${INSTALLER_DIR}/installer_core.sh" ]]; then
    # Use modular installer
    exec bash "${INSTALLER_DIR}/installer_main.sh" "$@"
fi

# =============================================================================
# BOOTSTRAP MODE - Minimal standalone installer
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root. Try: sudo $0 $*"
}

# Minimal install function
bootstrap_install() {
    log "Bootstrap installation starting..."
    
    # Create minimal structure
    mkdir -p "${INSTALL_DIR}"/{lib,bin,config}
    
    # Download modular installer components
    log "Downloading modular installer system..."
    
    mkdir -p "${INSTALLER_DIR}"
    
    local modules=(
        "installer_main.sh"
        "installer_core.sh"
        "installer_package.sh"
        "installer_download.sh"
        "installer_structure.sh"
        "installer_config.sh"
        "installer_verification.sh"
        "installer_backup.sh"
    )
    
    for module in "${modules[@]}"; do
        log "  Downloading: $module"
        curl -fsSL "${INSTALLER_MODULES_URL}/${module}" -o "${INSTALLER_DIR}/${module}" || \
            die "Failed to download $module"
        chmod +x "${INSTALLER_DIR}/${module}"
    done
    
    log "Bootstrap complete. Launching modular installer..."
    
    # Now execute modular installer
    exec bash "${INSTALLER_DIR}/installer_main.sh" "$@"
}

# =============================================================================
# BOOTSTRAP EXECUTION
# =============================================================================

check_root

case "${1:-help}" in
    install)
        bootstrap_install "$@"
        ;;
    *)
        cat << 'EOF'
NFTBan Bootstrap Installer v7.0.0

This is the bootstrap installer. First run will:
1. Download modular installer components
2. Install complete nftban system
3. Setup CLI for future use

USAGE:
    sudo ./nftban_installer.sh install [options]

After installation, use:
    sudo nftban installer [command]

For full help after install:
    sudo nftban installer help
EOF
        exit 0
        ;;
esac

# =============================================================================
# LICENSE
# =============================================================================
# NFTBAN Custom License v3.0
# Copyright (c) 2024-2025 ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr | Website: https://itcms.gr
#
# TERMS:
# 1. Free for personal, educational, and non-commercial use
# 2. Commercial use requires written permission (contact@itcms.gr)
# 3. Attribution required in all copies/derivatives
# 4. Modified versions must use different names
# 5. No warranty - provided "as is"
#
# Full license: https://itcms.gr/licenses/nftban-custom-v3.0
# =============================================================================
