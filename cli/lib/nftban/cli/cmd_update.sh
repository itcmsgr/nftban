#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.2.0 - Update Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated updates from git repository
#
# meta:name="cmd_update"
# meta:type="cli"
# meta:header="Update Command"
# meta:version="1.2.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Automated updates from git repository with health checks"
# meta:inventory.files="/etc/nftban/update.conf"
# meta:inventory.binaries="git,install"
# meta:inventory.env_vars="NFTBAN_GIT_REPO,NFTBAN_GIT_BRANCH"
# meta:inventory.config_files="/etc/nftban/update.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-16"
# meta:updated_date="2026-01-16"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
[[ -n "${NFTBAN_CLI_UPDATE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_UPDATE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly UPDATE_CONFIG_FILE="${NFTBAN_CONFIG_DIR:-/etc/nftban}/update.conf"
readonly UPDATE_LOG_FILE="${NFTBAN_LOG_DIR:-/var/log/nftban}/update.log"
readonly UPDATE_BACKUP_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-backups"

# Defaults (can be overridden by update.conf)
NFTBAN_GIT_REPO="${NFTBAN_GIT_REPO:-/opt/nftban}"
NFTBAN_GIT_REMOTE="${NFTBAN_GIT_REMOTE:-origin}"
NFTBAN_GIT_BRANCH="${NFTBAN_GIT_BRANCH:-main}"
NFTBAN_UPDATE_BACKUP_COUNT="${NFTBAN_UPDATE_BACKUP_COUNT:-3}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_update_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file
    mkdir -p "$(dirname "$UPDATE_LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$UPDATE_LOG_FILE" 2>/dev/null || true

    # Output to terminal
    case "$level" in
        INFO)  echo -e "  $msg" ;;
        OK)    echo -e "  \033[0;32m✓\033[0m $msg" ;;
        WARN)  echo -e "  \033[1;33m⚠\033[0m $msg" ;;
        ERROR) echo -e "  \033[0;31m✖\033[0m $msg" >&2 ;;
    esac
}

_update_banner() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Update"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_load_config() {
    # Load update configuration
    if [[ -f "$UPDATE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$UPDATE_CONFIG_FILE"
        _update_log INFO "Loaded config from $UPDATE_CONFIG_FILE"
    else
        _update_log WARN "No config file found, using defaults"
        _update_log INFO "Create $UPDATE_CONFIG_FILE to customize"
    fi
}

_check_prerequisites() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Update requires root privileges"
        _update_log INFO "Run: sudo nftban update"
        return 1
    fi

    # Check if git is installed
    if ! command -v git &>/dev/null; then
        _update_log ERROR "git is not installed"
        return 1
    fi

    # Check if repo exists
    if [[ ! -d "$NFTBAN_GIT_REPO/.git" ]]; then
        _update_log ERROR "Git repository not found at: $NFTBAN_GIT_REPO"
        _update_log INFO "Set NFTBAN_GIT_REPO in $UPDATE_CONFIG_FILE"
        return 1
    fi

    return 0
}

_get_current_version() {
    # Get current installed version
    local version_file="$NFTBAN_GIT_REPO/VERSION"
    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo "unknown"
    fi
}

_get_current_commit() {
    # Get current git commit
    git -C "$NFTBAN_GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

_get_remote_commit() {
    # Get remote commit without pulling
    git -C "$NFTBAN_GIT_REPO" fetch "$NFTBAN_GIT_REMOTE" "$NFTBAN_GIT_BRANCH" --quiet 2>/dev/null
    git -C "$NFTBAN_GIT_REPO" rev-parse --short "$NFTBAN_GIT_REMOTE/$NFTBAN_GIT_BRANCH" 2>/dev/null || echo "unknown"
}

_check_for_updates() {
    local current_commit remote_commit
    current_commit=$(_get_current_commit)
    remote_commit=$(_get_remote_commit)

    if [[ "$current_commit" == "$remote_commit" ]]; then
        return 1  # No updates
    else
        return 0  # Updates available
    fi
}

_create_backup() {
    # Create backup before update
    local backup_name
    backup_name="backup-$(date '+%Y%m%d-%H%M%S')-$(_get_current_commit)"
    local backup_path="$UPDATE_BACKUP_DIR/$backup_name"

    mkdir -p "$UPDATE_BACKUP_DIR"

    # Create tarball of installed files
    if tar -czf "$backup_path.tar.gz" \
        -C / \
        usr/lib/nftban \
        usr/sbin/nftban \
        etc/nftban \
        2>/dev/null; then
        _update_log OK "Backup created: $backup_name"

        # Cleanup old backups (keep last N) - use glob instead of ls
        local count=0
        local -a backups=()
        # shellcheck disable=SC2312
        while IFS= read -r -d '' f; do
            backups+=("$f")
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "backup-*.tar.gz" -print0 2>/dev/null | sort -rz)

        for old_backup in "${backups[@]}"; do
            count=$((count + 1))
            if [[ $count -gt $NFTBAN_UPDATE_BACKUP_COUNT ]]; then
                rm -f "$old_backup"
                _update_log INFO "Removed old backup: $(basename "$old_backup")"
            fi
        done

        return 0
    else
        _update_log WARN "Backup failed (continuing anyway)"
        return 0
    fi
}

_do_git_pull() {
    local dry_run="${1:-false}"

    _update_log INFO "Repository: $NFTBAN_GIT_REPO"
    _update_log INFO "Branch: $NFTBAN_GIT_BRANCH"

    if [[ "$dry_run" == "true" ]]; then
        _update_log INFO "[DRY-RUN] Would run: git pull $NFTBAN_GIT_REMOTE $NFTBAN_GIT_BRANCH"
        return 0
    fi

    # Stash any local changes
    git -C "$NFTBAN_GIT_REPO" stash --quiet 2>/dev/null || true

    # Pull latest
    if git -C "$NFTBAN_GIT_REPO" pull "$NFTBAN_GIT_REMOTE" "$NFTBAN_GIT_BRANCH" --quiet 2>/dev/null; then
        _update_log OK "Git pull successful"
        return 0
    else
        _update_log ERROR "Git pull failed"
        return 1
    fi
}

_do_install() {
    local dry_run="${1:-false}"
    local install_script="$NFTBAN_GIT_REPO/install.sh"

    if [[ ! -f "$install_script" ]]; then
        _update_log ERROR "install.sh not found at: $install_script"
        return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        _update_log INFO "[DRY-RUN] Would run: $install_script"
        return 0
    fi

    _update_log INFO "Running installer..."

    # Run install.sh with quiet mode if available
    if bash "$install_script" --quiet 2>&1 | while read -r line; do
        echo "    $line"
    done; then
        _update_log OK "Installation successful"
        return 0
    else
        _update_log ERROR "Installation failed"
        return 1
    fi
}

_do_health_check() {
    local dry_run="${1:-false}"

    if [[ "$dry_run" == "true" ]]; then
        _update_log INFO "[DRY-RUN] Would run: nftban health check --auto-heal"
        return 0
    fi

    _update_log INFO "Running health check..."

    if nftban health check --auto-heal --quiet 2>/dev/null; then
        _update_log OK "Health check passed"
        return 0
    else
        _update_log WARN "Health check reported issues (update still applied)"
        return 0  # Don't fail update for health check warnings
    fi
}

_list_backups() {
    echo ""
    echo "Available backups:"
    echo ""

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]] || [[ -z "$(ls -A "$UPDATE_BACKUP_DIR" 2>/dev/null)" ]]; then
        echo "  No backups found"
        return 1
    fi

    local idx=0
    local -a backups=()
    # shellcheck disable=SC2312
    while IFS= read -r -d '' backup; do
        backups+=("$backup")
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "backup-*.tar.gz" -print0 2>/dev/null | sort -rz)

    for backup in "${backups[@]}"; do
        idx=$((idx + 1))
        local name
        name=$(basename "$backup" .tar.gz)
        local size
        size=$(du -h "$backup" | cut -f1)
        echo "  [$idx] $name ($size)"
    done
    echo ""
    return 0
}

_do_rollback() {
    _update_log INFO "Starting rollback..."

    if ! _list_backups; then
        _update_log ERROR "No backups available for rollback"
        return 1
    fi

    # Get most recent backup
    local latest_backup=""
    # shellcheck disable=SC2312
    while IFS= read -r -d '' f; do
        latest_backup="$f"
        break
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "backup-*.tar.gz" -print0 2>/dev/null | sort -rz)

    if [[ -z "$latest_backup" ]]; then
        _update_log ERROR "No backup found"
        return 1
    fi

    _update_log INFO "Rolling back to: $(basename "$latest_backup" .tar.gz)"

    # Extract backup
    if tar -xzf "$latest_backup" -C / 2>/dev/null; then
        _update_log OK "Rollback successful"
        _update_log INFO "Run 'nftban health check --auto-heal' to verify"
        return 0
    else
        _update_log ERROR "Rollback failed"
        return 1
    fi
}

# =============================================================================
# MAIN COMMAND HANDLERS
# =============================================================================

_cmd_update_check() {
    # Check if updates are available
    _update_banner
    echo ""

    _load_config

    if ! _check_prerequisites; then
        return 3
    fi

    local current_version current_commit remote_commit
    current_version=$(_get_current_version)
    current_commit=$(_get_current_commit)

    echo "  Current version: v$current_version ($current_commit)"
    echo ""
    echo "  Checking for updates..."

    remote_commit=$(_get_remote_commit)

    if [[ "$current_commit" == "$remote_commit" ]]; then
        echo ""
        _update_log OK "Already up to date"
        return 0
    else
        echo ""
        _update_log INFO "Update available!"
        echo "  Local:  $current_commit"
        echo "  Remote: $remote_commit"
        echo ""
        echo "  Run 'nftban update' to apply"
        return 0
    fi
}

_cmd_update_main() {
    local force="${1:-false}"
    local dry_run="${2:-false}"

    _update_banner
    echo ""

    _load_config

    if ! _check_prerequisites; then
        return 3
    fi

    local start_time version_before commit_before
    start_time=$(date +%s)
    version_before=$(_get_current_version)
    commit_before=$(_get_current_commit)

    echo "  Repository:  $NFTBAN_GIT_REPO"
    echo "  Branch:      $NFTBAN_GIT_BRANCH"
    echo "  Before:      v$version_before ($commit_before)"
    echo ""

    # Check if updates available (unless --force)
    if [[ "$force" != "true" ]]; then
        if ! _check_for_updates; then
            _update_log OK "Already up to date"
            echo ""
            echo "  Use --force to reinstall anyway"
            return 0
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "  [DRY-RUN MODE]"
        echo ""
    fi

    # Create backup
    _create_backup

    # Git pull
    if ! _do_git_pull "$dry_run"; then
        return 1
    fi

    # Run install
    if ! _do_install "$dry_run"; then
        _update_log ERROR "Update failed - consider 'nftban update --rollback'"
        return 1
    fi

    # Health check
    _do_health_check "$dry_run"

    # Summary
    local version_after commit_after end_time duration
    version_after=$(_get_current_version)
    commit_after=$(_get_current_commit)
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Before:      v$version_before ($commit_before)"
    echo "  After:       v$version_after ($commit_after)"
    echo "  Duration:    ${duration}s"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        _update_log OK "Dry run completed (no changes made)"
    else
        _update_log OK "Update completed successfully"
    fi

    _update_log INFO "Logged to: $UPDATE_LOG_FILE"

    return 0
}

_cmd_update_rollback() {
    _update_banner
    echo ""

    _load_config

    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Rollback requires root privileges"
        return 1
    fi

    _do_rollback
}

_cmd_update_help() {
    cat << 'EOF'
NFTBan Update - Automated updates from git repository

USAGE:
  nftban update [OPTIONS]

OPTIONS:
  (none)       Pull latest code, install, and run health check
  --check      Check if update is available (no changes)
  --force      Force reinstall even if already current
  --dry-run    Preview what would happen (no changes)
  --rollback   Revert to previous backup
  --list       List available backups
  --help       Show this help

CONFIGURATION:
  File: /etc/nftban/update.conf

  NFTBAN_GIT_REPO="/opt/nftban"       # Git repository path
  NFTBAN_GIT_REMOTE="origin"          # Git remote name
  NFTBAN_GIT_BRANCH="main"            # Git branch to track
  NFTBAN_UPDATE_BACKUP_COUNT=3        # Backups to keep

EXIT CODES:
  0  Success
  1  Update/install failed
  2  Health check failed (update applied)
  3  Configuration or prerequisites error

EXAMPLES:
  nftban update              # Standard update
  nftban update --check      # Check for updates
  nftban update --force      # Force reinstall
  nftban update --dry-run    # Preview changes
  nftban update --rollback   # Revert last update

EOF
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_update() {
    local cmd="${1:-}"

    case "$cmd" in
        --check|-c)
            _cmd_update_check
            ;;
        --force|-f)
            _cmd_update_main "true" "false"
            ;;
        --dry-run|-n)
            _cmd_update_main "false" "true"
            ;;
        --rollback|-r)
            _cmd_update_rollback
            ;;
        --list|-l)
            _list_backups
            ;;
        --help|-h|help)
            _cmd_update_help
            ;;
        "")
            _cmd_update_main "false" "false"
            ;;
        *)
            echo "ERROR: Unknown option: $cmd" >&2
            echo "Run 'nftban update --help' for usage" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_update

# If executed directly, run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_update "$@"
fi
