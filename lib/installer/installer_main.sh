#!/usr/bin/env bash

# =============================================================================
# NFTBan Modular Installer - Main Entry Point
# Version: 7.0.0
# PATCHED: Correct module sourcing per architecture
# =============================================================================

set -euo pipefail

# =============================================================================
# MODULE LOADING (STRICT ORDER PER ARCHITECTURE)
# =============================================================================
readonly INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${INSTALLER_DIR%/lib/installer}"

# Load all installer modules in correct order
# Order matters: core must be first, others follow dependencies

readonly INSTALLER_MODULES=(
    "installer_core.sh"              # Core functions, logging, utils
    "installer_package.sh"           # Package manager & dependencies
    "installer_download.sh"          # GitHub/ZIP download (WAS: installer_repository.sh)
    "installer_structure.sh"         # Directory creation, permissions
    "installer_config_full.sh"       # Control panel detection (WAS: installer_controlpanel.sh)
    "installer_verification.sh"      # Verify/repair (WAS: installer_validation.sh)
    "installer_backup.sh"            # Backup/restore operations
)

# Load each module
for module in "${INSTALLER_MODULES[@]}"; do
    module_path="${INSTALLER_DIR}/${module}"
    
    if [[ -f "$module_path" ]]; then
        # shellcheck disable=SC1090
        source "$module_path" || {
            echo "FATAL: Failed to load installer module: $module" >&2
            exit 1
        }
        echo "[DEBUG] Loaded: $module" >&2
    else
        echo "FATAL: Installer module not found: $module_path" >&2
        exit 1
    fi
done

# =============================================================================
# VERIFY ALL MODULES LOADED
# =============================================================================
verify_installer_modules() {
    local missing=0
    
    # Check if each module set its LOADED flag
    local required_flags=(
        "INSTALLER_CORE_LOADED"
        "INSTALLER_PACKAGE_LOADED"
        "INSTALLER_DOWNLOAD_LOADED"
        "INSTALLER_STRUCTURE_LOADED"
        "INSTALLER_CONFIG_LOADED"
        "INSTALLER_VERIFICATION_LOADED"
        "INSTALLER_BACKUP_LOADED"
    )
    
    for flag in "${required_flags[@]}"; do
        if [[ -z "${!flag:-}" ]]; then
            echo "ERROR: Module not loaded: $flag" >&2
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        echo "FATAL: $missing installer module(s) failed to load" >&2
        exit 1
    fi
    
    echo "[INFO] All installer modules loaded successfully" >&2
    return 0
}

# Verify modules before proceeding
verify_installer_modules

# =============================================================================
# COMMAND ROUTING
# =============================================================================

main() {
    # Initialize installer core
    installer_core_init
    
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        install)
            installer_cmd_install "$@"
            ;;
        update|upgrade)
            installer_cmd_update "$@"
            ;;
        uninstall|remove)
            installer_cmd_uninstall "$@"
            ;;
        verify)
            installer_cmd_verify "$@"
            ;;
        status)
            installer_cmd_status "$@"
            ;;
        repair)
            installer_cmd_repair "$@"
            ;;
        backup)
            installer_cmd_backup "$@"
            ;;
        restore)
            installer_cmd_restore "$@"
            ;;
        self-update)
            installer_cmd_self_update "$@"
            ;;
        help|--help|-h)
            installer_show_help
            ;;
        *)
            installer_log_error "Unknown command: $command"
            echo "Use 'nftban installer help' for usage"
            exit 1
            ;;
    esac
}

# Execute main
main "$@"
