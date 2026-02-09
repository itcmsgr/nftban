#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic paths, cannot follow
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
# **Description & Purpose**
# meta:description="Automated updates with auto-detection of install type (loader)"
# meta:input="Update subcommand and options"
# meta:output="Update status and results"
#
# **Inventory & Requirements**
# meta:inventory.files="/etc/nftban/update.conf"
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_UPDATE_SOURCE"
# meta:inventory.config_files="/etc/nftban/update.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="github.com"
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-16"
# meta:updated_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
[[ -n "${NFTBAN_CLI_UPDATE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_UPDATE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Exported for submodules (cmd_update_helpers.sh, cmd_update_methods.sh)
export UPDATE_CONFIG_FILE="${NFTBAN_CONFIG_DIR:-/etc/nftban}/update.conf"
export UPDATE_LOG_FILE="${NFTBAN_LOG_DIR:-/var/log/nftban}/update.log"
export UPDATE_BACKUP_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-backups"
export GITHUB_REPO="itcmsgr/nftban"
export GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
export GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases/download"

# Defaults (can be overridden by update.conf)
NFTBAN_UPDATE_SOURCE="${NFTBAN_UPDATE_SOURCE:-auto}"
NFTBAN_GIT_REPO="${NFTBAN_GIT_REPO:-/opt/nftban}"
NFTBAN_GIT_BRANCH="${NFTBAN_GIT_BRANCH:-main}"
NFTBAN_UPDATE_BACKUP_COUNT="${NFTBAN_UPDATE_BACKUP_COUNT:-3}"

# Lock file for preventing concurrent updates
readonly UPDATE_LOCK_FILE="/run/nftban/update.lock"

# Internal flags (exported for submodules)
export _NFTBAN_UPDATE_FORCE=0

# =============================================================================
# MODULE LOADER
# =============================================================================
# Update command functions are split into separate files for maintainability:
#
# cmd_update_helpers.sh    - Logging, dpkg repair, immutable flags, config
# cmd_update_detection.sh  - Install type/distro detection, version queries
# cmd_update_methods.sh    - Update via rpm/deb/git/local, GitHub functions
# cmd_update_backup.sh     - Backup creation, rollback, backup listing
# =============================================================================

# Determine CLI directory
_UPDATE_CLI_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli"

# Load all update command modules
_update_modules=(
    "cmd_update_helpers.sh"
    "cmd_update_detection.sh"
    "cmd_update_methods.sh"
    "cmd_update_backup.sh"
)

for _module in "${_update_modules[@]}"; do
    _module_path="${_UPDATE_CLI_DIR}/${_module}"
    if [[ -f "$_module_path" ]]; then
        source "$_module_path" || {
            echo "ERROR: Failed to load update module: $_module" >&2
            return 1
        }
    else
        echo "WARNING: Update module not found: $_module_path" >&2
    fi
done

# Cleanup temporary variables
unset _UPDATE_CLI_DIR _update_modules _module _module_path

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

    # Acquire exclusive lock to prevent concurrent updates
    _update_log INFO "Acquiring update lock..."
    mkdir -p /run/nftban 2>/dev/null || true
    exec 9>"$UPDATE_LOCK_FILE"
    if ! flock -n 9; then
        _update_log ERROR "Another update is in progress"
        _update_log INFO "If no update is running, use 'nftban update force' to clear stale lock"
        return 1
    fi
    _update_log INFO "Lock acquired"

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
        _update_log INFO "Run 'nftban update repair' to fix broken install state"
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        _update_log INFO "Run 'nftban update force' to force reinstall"
        return $result
    fi

    # Restart services to load new binaries
    echo ""
    _update_log INFO "Restarting NFTBan services..."
    local _svc_restart_failed=0
    for _svc in nftband.service nftban-core.service; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then
            if systemctl restart "$_svc" 2>/dev/null; then
                _update_log OK "Restarted $_svc"
            else
                _update_log WARN "Failed to restart $_svc"
                _svc_restart_failed=1
            fi
        fi
    done
    if [[ $_svc_restart_failed -eq 0 ]]; then
        _update_log OK "Services restarted"
    fi

    # Run health check
    echo ""
    _update_log INFO "Running health check..."
    local health_output health_status
    health_output=$(nftban health check --auto-heal 2>&1) || health_status=$?
    health_status="${health_status:-0}"

    if [[ $health_status -eq 0 ]]; then
        _update_log OK "Health check passed"
    else
        _update_log WARN "Health check reported issues"
        # Show warning details (filter to show only warnings/errors)
        echo "$health_output" | grep -E "(WARN|WARNING|ERROR|FAIL|\[!\])" | head -5 | while read -r line; do
            echo "    $line"
        done
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

_cmd_update_repair() {
    # Repair a broken nftban installation
    # This is the nuclear option - fixes dpkg, removes immutable flags,
    # and optionally restores from backup
    #
    # Designed to work even when nftban itself is partially broken,
    # e.g., after a dpkg failure mid-install

    _update_banner
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Repair requires root privileges"
        _update_log INFO "Run: sudo nftban update repair"
        return 1
    fi

    _update_log INFO "Starting nftban repair..."
    echo ""

    local repair_status=0

    # Step 1: Remove immutable flags from all nftban files
    echo "  [1/4] Removing immutable flags..."
    _remove_immutable_flags

    # Step 2: Fix broken dpkg state (first pass)
    echo ""
    echo "  [2/4] Checking dpkg state..."
    if command -v dpkg &>/dev/null; then
        if ! _fix_broken_dpkg; then
            _update_log WARN "First dpkg repair pass had issues"
            repair_status=1
        fi
    else
        _update_log INFO "Not a dpkg-based system, skipping dpkg repair"
    fi

    # Step 3: Re-run dpkg configure to ensure clean state
    echo ""
    echo "  [3/4] Running dpkg configure (ensure clean state)..."
    if command -v dpkg &>/dev/null; then
        # Force remove any lock files that might be stale
        if [[ -f /var/lib/dpkg/lock-frontend ]]; then
            # Check if dpkg is actually running
            if ! fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
                rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
                rm -f /var/lib/dpkg/lock 2>/dev/null || true
                _update_log INFO "Removed stale dpkg lock files"
            fi
        fi

        # Clean stale nftban update lock if exists and no process holds it
        if [[ -f "$UPDATE_LOCK_FILE" ]]; then
            if ! fuser "$UPDATE_LOCK_FILE" &>/dev/null 2>&1; then
                rm -f "$UPDATE_LOCK_FILE" 2>/dev/null || true
                _update_log INFO "Removed stale nftban update lock"
            fi
        fi

        # Run dpkg configure to finalize any pending configurations
        if dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "dpkg configure completed"
        else
            _update_log WARN "dpkg configure had issues"
            repair_status=1
        fi

        # Verify nftban package state
        local pkg_line
        pkg_line=$(dpkg -l nftban 2>/dev/null | tail -1) || true
        if [[ -n "$pkg_line" ]]; then
            local pkg_status
            pkg_status=$(echo "$pkg_line" | awk '{print $1}')
            local pkg_version
            pkg_version=$(echo "$pkg_line" | awk '{print $3}')
            case "$pkg_status" in
                ii)
                    _update_log OK "nftban package status: installed ($pkg_version)"
                    ;;
                iF|iU|iW|iH)
                    _update_log WARN "nftban package status: $pkg_status ($pkg_version) - still needs attention"
                    repair_status=1
                    ;;
                rc)
                    _update_log WARN "nftban package status: removed but config remains"
                    ;;
                *)
                    _update_log WARN "nftban package status: $pkg_status"
                    ;;
            esac
        fi
    else
        _update_log INFO "Not a dpkg-based system, skipping dpkg configure"
        # Still clean stale nftban update lock on non-dpkg systems
        if [[ -f "$UPDATE_LOCK_FILE" ]]; then
            if ! fuser "$UPDATE_LOCK_FILE" &>/dev/null 2>&1; then
                rm -f "$UPDATE_LOCK_FILE" 2>/dev/null || true
                _update_log INFO "Removed stale nftban update lock"
            fi
        fi
    fi

    # Step 4: Offer backup restore if repair couldn't fully fix things
    echo ""
    echo "  [4/4] Checking backup availability..."
    if [[ -d "$UPDATE_BACKUP_DIR" ]]; then
        local latest_backup=""
        while IFS= read -r -d '' f; do
            latest_backup="$f"
            break
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

        if [[ -n "$latest_backup" ]]; then
            local backup_name
            backup_name=$(basename "$latest_backup" .tar.gz)
            if [[ $repair_status -ne 0 ]]; then
                _update_log INFO "Backup available: $backup_name"
                _update_log INFO "Restoring from backup to complete repair..."
                if tar -xzf "$latest_backup" -C / 2>&1; then
                    _update_log OK "Backup restored: $backup_name"
                    # Final dpkg configure after restore
                    if command -v dpkg &>/dev/null; then
                        dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done || true
                    fi
                    repair_status=0
                else
                    _update_log ERROR "Backup restore failed"
                fi
            else
                _update_log OK "Backup available: $backup_name (not needed, repair succeeded)"
            fi
        else
            _update_log INFO "No backups found"
            if [[ $repair_status -ne 0 ]]; then
                _update_log WARN "No backup to restore from"
                _update_log INFO "Try: sudo nftban update force"
            fi
        fi
    else
        _update_log INFO "No backup directory found"
    fi

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $repair_status -eq 0 ]]; then
        echo "  Repair completed successfully"
    else
        echo "  Repair completed with warnings"
        echo "  If issues persist, try: sudo nftban update force"
        echo "  Or reinstall: sudo dpkg -i --force-all <package.deb>"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return $repair_status
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
    force               Force reinstall/update (fixes dpkg, removes immutable flags)
    rollback            Restore previous version from backup (fixes dpkg first)
    repair              Fix broken install (dpkg state, immutable flags, restore backup)
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

    # Force reinstall (fixes dpkg state, removes immutable flags, forces overwrite)
    nftban update force

    # Repair broken install (fixes dpkg, removes immutable flags, restores backup)
    nftban update repair

    # Rollback to previous version (fixes dpkg state first)
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
        force|--force|reinstall)
            _NFTBAN_UPDATE_FORCE=1
            # Clean stale lock file if exists and no process holds it
            if [[ -f "$UPDATE_LOCK_FILE" ]]; then
                if ! fuser "$UPDATE_LOCK_FILE" &>/dev/null 2>&1; then
                    rm -f "$UPDATE_LOCK_FILE" 2>/dev/null || true
                    _update_log INFO "Force mode: cleaned stale lock"
                fi
            fi
            _cmd_update_main "auto" ""
            ;;
        repair|--repair|fix)
            _cmd_update_repair
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
        help|-h|--help)
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
