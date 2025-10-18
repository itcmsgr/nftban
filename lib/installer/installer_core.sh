#!/usr/bin/env bash

# =============================================================================
# NFTBan Installer - Core Module
# Provides: Logging, utilities, argument parsing, initialization
# =============================================================================

[[ -n "${INSTALLER_CORE_LOADED:-}" ]] && return 0
readonly INSTALLER_CORE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly INSTALLER_VERSION="7.0.0"
# INSTALL_DIR set by installer_main.sh
readonly LOG_DIR="${LOG_DIR:-/var/log/nftban}"
readonly BACKUP_DIR="${BACKUP_DIR:-/var/backups/nftban}"

# State files
readonly VERSION_FILE="${INSTALL_DIR}/.version"
readonly INSTALL_STATE="${INSTALL_DIR}/.install_state"
readonly INSTALL_LOG="${LOG_DIR}/installer_$(date +%Y%m%d_%H%M%S).log"

# Colors
if [[ -t 1 ]]; then
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[1;33m'
    readonly C_BLUE='\033[0;34m'
    readonly C_CYAN='\033[0;36m'
    readonly C_BOLD='\033[1m'
    readonly C_RESET='\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_RESET=''
fi

# =============================================================================
# GLOBAL STATE
# =============================================================================
INSTALLER_COMMAND=""
INSTALLER_METHOD="github"  # github, zip
INSTALLER_ASSUME_YES=false
INSTALLER_DRY_RUN=false
INSTALLER_QUIET=false
INSTALLER_VERBOSE=false
INSTALLER_FORCE=false
INSTALLER_SKIP_DEPS=false
INSTALLER_SKIP_CP=false
INSTALLER_AUTO_UPDATE=false
INSTALLER_PURGE=false
INSTALLER_NO_BACKUP=false

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

installer_log() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
    echo "[${timestamp}] [${level}] ${message}" >> "$INSTALL_LOG" 2>/dev/null || true
    
    # Console output
    if [[ "$INSTALLER_QUIET" == "false" ]]; then
        case "$level" in
            ERROR)   echo -e "${C_RED}[ERROR]${C_RESET} ${message}" >&2 ;;
            WARN)    echo -e "${C_YELLOW}[WARN]${C_RESET} ${message}" >&2 ;;
            SUCCESS) echo -e "${C_GREEN}[✓]${C_RESET} ${message}" ;;
            INFO)    echo -e "${C_BLUE}[INFO]${C_RESET} ${message}" ;;
            DEBUG)   [[ "$INSTALLER_VERBOSE" == "true" ]] && echo -e "${C_CYAN}[DEBUG]${C_RESET} ${message}" ;;
            *)       echo "[${level}] ${message}" ;;
        esac
    fi
}

installer_log_error() { installer_log "ERROR" "$@"; }
installer_log_warn() { installer_log "WARN" "$@"; }
installer_log_success() { installer_log "SUCCESS" "$@"; }
installer_log_info() { installer_log "INFO" "$@"; }
installer_log_debug() { installer_log "DEBUG" "$@"; }

die() {
    installer_log_error "$@"
    exit 1
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

installer_check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This command must be run as root. Try: sudo nftban installer $*"
    fi
}

installer_confirm() {
    local prompt="${1:-Continue?}"
    
    if [[ "$INSTALLER_ASSUME_YES" == "true" ]]; then
        return 0
    fi
    
    local response
    read -r -p "${prompt} [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

installer_run_cmd() {
    if [[ "$INSTALLER_DRY_RUN" == "true" ]]; then
        installer_log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    "$@"
}

installer_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

installer_save_state() {
    local state_data="INSTALLER_VERSION=${INSTALLER_VERSION}
INSTALLER_METHOD=${INSTALLER_METHOD}
INSTALL_DATE=$(date +%Y-%m-%d_%H:%M:%S)
AUTO_UPDATE=${INSTALLER_AUTO_UPDATE}
LAST_UPDATE=$(date +%Y-%m-%d_%H:%M:%S)
"
    
    echo "$state_data" > "$INSTALL_STATE"
    installer_log_debug "Installation state saved"
}

installer_load_state() {
    if [[ -f "$INSTALL_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_STATE" 2>/dev/null || true
        installer_log_debug "Installation state loaded"
    fi
}

installer_save_version() {
    echo "$INSTALLER_VERSION" > "$VERSION_FILE"
}

installer_get_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

installer_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --github)
                INSTALLER_METHOD="github"
                shift
                ;;
            --zip)
                INSTALLER_METHOD="zip"
                shift
                ;;
            --auto-update)
                INSTALLER_AUTO_UPDATE=true
                shift
                ;;
            --skip-deps)
                INSTALLER_SKIP_DEPS=true
                shift
                ;;
            --skip-cp-detect)
                INSTALLER_SKIP_CP=true
                shift
                ;;
            --force)
                INSTALLER_FORCE=true
                shift
                ;;
            --purge)
                INSTALLER_PURGE=true
                shift
                ;;
            --no-backup)
                INSTALLER_NO_BACKUP=true
                shift
                ;;
            -y|--yes)
                INSTALLER_ASSUME_YES=true
                shift
                ;;
            --dry-run)
                INSTALLER_DRY_RUN=true
                shift
                ;;
            --quiet)
                INSTALLER_QUIET=true
                shift
                ;;
            --verbose)
                INSTALLER_VERBOSE=true
                shift
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

# =============================================================================
# INITIALIZATION
# =============================================================================

installer_core_init() {
    # Create log directory
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Log startup
    installer_log_info "NFTBan Installer v${INSTALLER_VERSION}"
    installer_log_debug "Install directory: $INSTALL_DIR"
    installer_log_debug "Log file: $INSTALL_LOG"
    
    # Load existing state if available
    installer_load_state
}

# =============================================================================
# HELP SYSTEM
# =============================================================================

installer_show_help() {
    cat << 'EOF'
=================================================================
  NFTBan Installer - Modular Installation System
  Version: 7.0.0
=================================================================

USAGE:
    nftban installer <command> [options]

COMMANDS:
    install         Install nftban system
    update          Update existing installation
    upgrade         Alias for update
    uninstall       Remove nftban system
    verify          Verify installation integrity
    status          Show installation status
    repair          Repair broken installation
    backup          Create backup
    restore         Restore from backup
    self-update     Update installer itself
    help            Show this help

INSTALL OPTIONS:
    --github            Use GitHub repository (default)
    --zip               Use ZIP archive download
    --auto-update       Enable automatic updates
    --skip-deps         Skip dependency installation
    --skip-cp-detect    Skip control panel detection
    --force             Force reinstallation
    -y, --yes           Assume yes to prompts
    --dry-run           Show what would be done
    --quiet             Minimal output
    --verbose           Verbose output

UNINSTALL OPTIONS:
    --purge             Remove all data and logs
    --no-backup         Skip backup creation
    -y, --yes           Assume yes to prompts

EXAMPLES:
    # Install from GitHub
    sudo nftban installer install --github

    # Install with auto-update
    sudo nftban installer install --auto-update

    # Update existing installation
    sudo nftban installer update

    # Verify installation
    sudo nftban installer verify

    # Repair installation
    sudo nftban installer repair

    # Create backup
    sudo nftban installer backup

    # Complete uninstall
    sudo nftban installer uninstall --purge -y

PATHS:
    Install:    /etc/nftban
    Logs:       /var/log/nftban
    Backups:    /var/backups/nftban
    CLI:        /usr/local/bin/nftban

=================================================================
EOF
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f installer_log
export -f installer_log_error
export -f installer_log_warn
export -f installer_log_success
export -f installer_log_info
export -f installer_log_debug
export -f installer_check_root
export -f installer_confirm
export -f installer_run_cmd
export -f installer_command_exists
export -f installer_save_state
export -f installer_load_state
export -f installer_save_version
export -f installer_get_version

installer_log_debug "Installer core module loaded"
