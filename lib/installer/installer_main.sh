#!/usr/bin/env bash

# =============================================================================
# NFTBan Modular Installer - Main Entry Point
# Version: 7.0.0
# PATCHED: Correct module sourcing per architecture
# =============================================================================

set -euo pipefail

# =============================================================================
# CHECK AND INSTALL BOOTSTRAP DEPENDENCIES
# =============================================================================
check_and_install_dependencies() {
    local missing_deps=()
    local is_unattended=false

    # Check if running in unattended mode
    [[ "${1:-}" == "--unattended" ]] && is_unattended=true

    # Check all required bootstrap tools
    local required_tools=(
        "tar"           # Extract archives
        "gzip"          # Decompress archives
        "unzip"         # Unzip files
        "curl"          # Download files
        "git"           # Version control (optional but recommended)
        "ipcalc"        # IP validation (required for nftban)
    )

    for cmd in "${required_tools[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        echo "[✓] All bootstrap dependencies found" >&2
        return 0
    fi

    echo "" >&2
    echo "WARNING: Missing required dependencies: ${missing_deps[*]}" >&2
    echo "" >&2

    # Detect OS
    if [[ ! -f /etc/os-release ]]; then
        echo "ERROR: Cannot detect OS (/etc/os-release not found)" >&2
        echo "Please install manually: ${missing_deps[*]}" >&2
        return 1
    fi

    . /etc/os-release

    # Ask for permission (unless unattended)
    if [[ "$is_unattended" == "false" ]]; then
        echo "Do you want to install missing dependencies automatically? [Y/n]" >&2
        read -r response
        response=${response:-Y}

        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Installation cancelled. Please install manually: ${missing_deps[*]}" >&2
            return 1
        fi
    fi

    echo "Installing dependencies..." >&2

    case "$ID" in
        ubuntu|debian)
            apt-get update -qq || true
            apt-get install -y "${missing_deps[@]}" || {
                echo "ERROR: Failed to install dependencies" >&2
                return 1
            }
            ;;
        centos|rhel|rocky|almalinux|fedora)
            # Map package names for RHEL-based systems
            local rhel_deps=()
            for dep in "${missing_deps[@]}"; do
                case "$dep" in
                    ipcalc) rhel_deps+=("ipcalc") ;;
                    *) rhel_deps+=("$dep") ;;
                esac
            done

            if command -v dnf &>/dev/null; then
                dnf install -y "${rhel_deps[@]}" || {
                    echo "ERROR: Failed to install dependencies" >&2
                    return 1
                }
            else
                yum install -y "${rhel_deps[@]}" || {
                    echo "ERROR: Failed to install dependencies" >&2
                    return 1
                }
            fi
            ;;
        *)
            echo "ERROR: Unsupported OS: $ID" >&2
            echo "Please install manually: ${missing_deps[*]}" >&2
            return 1
            ;;
    esac

    echo "[✓] Dependencies installed successfully" >&2
    return 0
}

# =============================================================================
# SET DIRECTORIES BEFORE LOADING MODULES
# =============================================================================
readonly INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always install to /etc/nftban, not where script is running from
readonly INSTALL_DIR="/etc/nftban"

# Run bootstrap check (pass --unattended if present in args)
if [[ " $* " =~ " --unattended " ]] || [[ " $* " =~ " -y " ]] || [[ " $* " =~ " --yes " ]]; then
    check_and_install_dependencies --unattended || exit 1
else
    check_and_install_dependencies || exit 1
fi

# =============================================================================
# MODULE LOADING (STRICT ORDER PER ARCHITECTURE)
# =============================================================================

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
