#!/usr/bin/env bash
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
# meta:description="Automated updates with auto-detection of install type"
# meta:inventory.files="/etc/nftban/update.conf"
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_UPDATE_SOURCE"
# meta:inventory.config_files="/etc/nftban/update.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="github.com"
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-16"
# meta:updated_date="2026-01-19"
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
readonly GITHUB_REPO="itcmsgr/nftban"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases/download"

# Defaults (can be overridden by update.conf)
NFTBAN_UPDATE_SOURCE="${NFTBAN_UPDATE_SOURCE:-auto}"
NFTBAN_GIT_REPO="${NFTBAN_GIT_REPO:-/opt/nftban}"
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
        INFO)  echo "  $msg" ;;
        OK)    echo "  ✓ $msg" ;;
        WARN)  echo "  ⚠ $msg" ;;
        ERROR) echo "  ✗ $msg" >&2 ;;
    esac
}

_update_banner() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Update"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_load_config() {
    if [[ -f "$UPDATE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$UPDATE_CONFIG_FILE"
    fi
}

# =============================================================================
# INSTALL TYPE DETECTION
# =============================================================================

_detect_install_type() {
    # Detect how NFTBan was installed
    # Returns: rpm, deb, git, unknown

    # Check RPM first (RHEL/CentOS/Rocky/Alma/Fedora)
    if command -v rpm &>/dev/null && rpm -q nftban &>/dev/null; then
        echo "rpm"
        return 0
    fi

    # Check DEB (Debian/Ubuntu)
    if command -v dpkg &>/dev/null && dpkg -l nftban 2>/dev/null | grep -q "^ii"; then
        echo "deb"
        return 0
    fi

    # Check Git install
    if [[ -d "${NFTBAN_GIT_REPO}/.git" ]]; then
        echo "git"
        return 0
    fi

    # Unknown install type
    echo "unknown"
    return 0
}

_detect_distro() {
    # Detect Linux distribution for package selection
    # Returns: el9, el10, debian12, debian13, ubuntu22.04, ubuntu24.04, unknown

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release

        case "${ID:-}" in
            rhel|centos|rocky|almalinux|ol)
                local major="${VERSION_ID%%.*}"
                echo "el${major}"
                ;;
            fedora)
                echo "el10"  # Fedora uses el10 compatible packages
                ;;
            debian)
                local major="${VERSION_ID%%.*}"
                echo "debian${major}"
                ;;
            ubuntu)
                echo "ubuntu${VERSION_ID}"
                ;;
            *)
                # Try ID_LIKE
                case "${ID_LIKE:-}" in
                    *rhel*|*centos*|*fedora*)
                        echo "el9"
                        ;;
                    *debian*)
                        echo "debian12"
                        ;;
                    *ubuntu*)
                        echo "ubuntu22.04"
                        ;;
                    *)
                        echo "unknown"
                        ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

_get_current_version() {
    # Get currently installed version
    local install_type
    install_type=$(_detect_install_type)

    case "$install_type" in
        rpm)
            rpm -q --qf '%{VERSION}' nftban 2>/dev/null || echo "unknown"
            ;;
        deb)
            dpkg-query -W -f='${Version}' nftban 2>/dev/null | cut -d'-' -f1 || echo "unknown"
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
            if [[ -f "/usr/lib/nftban/VERSION" ]]; then
                cat "/usr/lib/nftban/VERSION"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# =============================================================================
# GITHUB RELEASES
# =============================================================================

_get_latest_release() {
    # Get latest release version from GitHub
    # Returns: version string (e.g., "1.3.0")

    local response
    response=$(curl -sL --connect-timeout 10 "$GITHUB_API" 2>/dev/null) || {
        echo "unknown"
        return 1
    }

    # Extract tag_name and remove 'v' prefix
    echo "$response" | grep -o '"tag_name":\s*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
}

_get_package_url() {
    # Get download URL for current distro
    # Args: $1 = version
    # Returns: URL

    local version="$1"
    local distro
    distro=$(_detect_distro)
    local install_type
    install_type=$(_detect_install_type)

    local pkg_name=""
    case "$install_type" in
        rpm)
            pkg_name="nftban-${distro}-x86_64.rpm"
            ;;
        deb)
            pkg_name="nftban-${distro}-amd64.deb"
            ;;
        *)
            # Default to RPM for unknown on RHEL-like, DEB otherwise
            if [[ -f /etc/redhat-release ]]; then
                pkg_name="nftban-el9-x86_64.rpm"
            else
                pkg_name="nftban-debian12-amd64.deb"
            fi
            ;;
    esac

    echo "${GITHUB_RELEASES}/v${version}/${pkg_name}"
}

_download_package() {
    # Download package from GitHub
    # Args: $1 = URL, $2 = output path
    # Returns: 0 on success

    local url="$1"
    local output="$2"

    _update_log INFO "Downloading from GitHub..."
    _update_log INFO "URL: $url"

    if curl -sL --connect-timeout 30 --max-time 300 -o "$output" "$url" 2>/dev/null; then
        if [[ -f "$output" ]] && [[ -s "$output" ]]; then
            local size
            size=$(du -h "$output" | cut -f1)
            _update_log OK "Downloaded ($size)"
            return 0
        fi
    fi

    _update_log ERROR "Download failed"
    return 1
}

# =============================================================================
# UPDATE METHODS
# =============================================================================

_update_via_rpm() {
    # Update using RPM package from GitHub
    # Args: $1 = version (optional, defaults to latest)

    local version="${1:-}"

    if [[ -z "$version" ]]; then
        version=$(_get_latest_release)
        if [[ "$version" == "unknown" ]]; then
            _update_log ERROR "Failed to get latest version from GitHub"
            return 1
        fi
    fi

    local url
    url=$(_get_package_url "$version")
    local tmp_file="/tmp/nftban-${version}.rpm"

    # Download
    if ! _download_package "$url" "$tmp_file"; then
        return 1
    fi

    # Verify it's a valid RPM
    if ! rpm -qp "$tmp_file" &>/dev/null; then
        _update_log ERROR "Invalid RPM package"
        rm -f "$tmp_file"
        return 1
    fi

    # Install
    _update_log INFO "Installing RPM package..."
    if rpm -Uvh --force "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "RPM installed successfully"
        rm -f "$tmp_file"
        return 0
    else
        _update_log ERROR "RPM installation failed"
        rm -f "$tmp_file"
        return 1
    fi
}

_update_via_deb() {
    # Update using DEB package from GitHub
    # Args: $1 = version (optional, defaults to latest)

    local version="${1:-}"

    if [[ -z "$version" ]]; then
        version=$(_get_latest_release)
        if [[ "$version" == "unknown" ]]; then
            _update_log ERROR "Failed to get latest version from GitHub"
            return 1
        fi
    fi

    local url
    url=$(_get_package_url "$version")
    local tmp_file="/tmp/nftban-${version}.deb"

    # Download
    if ! _download_package "$url" "$tmp_file"; then
        return 1
    fi

    # Verify it's a valid DEB
    if ! dpkg-deb --info "$tmp_file" &>/dev/null; then
        _update_log ERROR "Invalid DEB package"
        rm -f "$tmp_file"
        return 1
    fi

    # Install
    _update_log INFO "Installing DEB package..."
    if dpkg -i "$tmp_file" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "DEB installed successfully"
        rm -f "$tmp_file"
        return 0
    else
        _update_log ERROR "DEB installation failed"
        rm -f "$tmp_file"
        return 1
    fi
}

_update_via_git() {
    # Update using git pull
    # Args: $1 = branch (optional, defaults to main)

    local branch="${1:-$NFTBAN_GIT_BRANCH}"

    if [[ ! -d "${NFTBAN_GIT_REPO}/.git" ]]; then
        _update_log ERROR "Git repository not found at: $NFTBAN_GIT_REPO"
        _update_log INFO "Set NFTBAN_GIT_REPO in $UPDATE_CONFIG_FILE"
        return 1
    fi

    _update_log INFO "Repository: $NFTBAN_GIT_REPO"
    _update_log INFO "Branch: $branch"

    # Stash local changes
    git -C "$NFTBAN_GIT_REPO" stash --quiet 2>/dev/null || true

    # Fetch and pull
    _update_log INFO "Pulling latest changes..."
    if git -C "$NFTBAN_GIT_REPO" pull origin "$branch" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "Git pull successful"
    else
        _update_log ERROR "Git pull failed"
        return 1
    fi

    # Run install.sh
    local install_script="${NFTBAN_GIT_REPO}/install.sh"
    if [[ -f "$install_script" ]]; then
        _update_log INFO "Running installer..."
        if bash "$install_script" 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "Installation successful"
            return 0
        else
            _update_log ERROR "Installation failed"
            return 1
        fi
    else
        _update_log WARN "No install.sh found, git pull only"
        return 0
    fi
}

_update_via_local() {
    # Update from local path
    # Args: $1 = path to nftban source directory

    local source_path="$1"

    if [[ ! -d "$source_path" ]]; then
        _update_log ERROR "Local path not found: $source_path"
        return 1
    fi

    local install_script="${source_path}/install.sh"
    if [[ ! -f "$install_script" ]]; then
        _update_log ERROR "install.sh not found in: $source_path"
        return 1
    fi

    _update_log INFO "Source: $source_path"
    _update_log INFO "Running installer..."

    if bash "$install_script" 2>&1 | while read -r line; do echo "    $line"; done; then
        _update_log OK "Installation successful"
        return 0
    else
        _update_log ERROR "Installation failed"
        return 1
    fi
}

# =============================================================================
# BACKUP & ROLLBACK
# =============================================================================

_create_backup() {
    local current_version
    current_version=$(_get_current_version)
    local backup_name="nftban-${current_version}-$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${UPDATE_BACKUP_DIR}/${backup_name}.tar.gz"

    mkdir -p "$UPDATE_BACKUP_DIR"

    _update_log INFO "Creating backup..."

    if tar -czf "$backup_path" \
        -C / \
        usr/lib/nftban \
        usr/sbin/nftban \
        etc/nftban \
        2>/dev/null; then
        _update_log OK "Backup: $backup_name"

        # Cleanup old backups
        local count=0
        while IFS= read -r -d '' old_backup; do
            count=$((count + 1))
            if [[ $count -gt $NFTBAN_UPDATE_BACKUP_COUNT ]]; then
                rm -f "$old_backup"
            fi
        done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

        return 0
    else
        _update_log WARN "Backup failed (continuing anyway)"
        return 0
    fi
}

_do_rollback() {
    _update_log INFO "Looking for backups..."

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        _update_log ERROR "No backup directory found"
        return 1
    fi

    # Find latest backup
    local latest_backup=""
    while IFS= read -r -d '' f; do
        latest_backup="$f"
        break
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ -z "$latest_backup" ]]; then
        _update_log ERROR "No backups found"
        return 1
    fi

    _update_log INFO "Rolling back to: $(basename "$latest_backup" .tar.gz)"

    if tar -xzf "$latest_backup" -C / 2>/dev/null; then
        _update_log OK "Rollback successful"
        return 0
    else
        _update_log ERROR "Rollback failed"
        return 1
    fi
}

_list_backups() {
    echo ""
    echo "Available backups:"
    echo ""

    if [[ ! -d "$UPDATE_BACKUP_DIR" ]]; then
        echo "  No backups found"
        return 1
    fi

    local count=0
    while IFS= read -r -d '' backup; do
        count=$((count + 1))
        local name size
        name=$(basename "$backup" .tar.gz)
        size=$(du -h "$backup" | cut -f1)
        echo "  [$count] $name ($size)"
    done < <(find "$UPDATE_BACKUP_DIR" -maxdepth 1 -name "nftban-*.tar.gz" -print0 2>/dev/null | sort -rzV)

    if [[ $count -eq 0 ]]; then
        echo "  No backups found"
        return 1
    fi

    echo ""
    return 0
}

# =============================================================================
# MAIN COMMANDS
# =============================================================================

_cmd_update_status() {
    # Show current installation status
    _update_banner
    echo ""

    local install_type distro current_version
    install_type=$(_detect_install_type)
    distro=$(_detect_distro)
    current_version=$(_get_current_version)

    echo "  Install type:  $install_type"
    echo "  Distribution:  $distro"
    echo "  Current:       v$current_version"
    echo ""

    case "$install_type" in
        rpm)
            echo "  Package:       $(rpm -q nftban 2>/dev/null || echo 'unknown')"
            ;;
        deb)
            echo "  Package:       $(dpkg-query -W -f='${Package} ${Version}' nftban 2>/dev/null || echo 'unknown')"
            ;;
        git)
            echo "  Repository:    $NFTBAN_GIT_REPO"
            echo "  Branch:        $NFTBAN_GIT_BRANCH"
            echo "  Commit:        $(git -C "$NFTBAN_GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
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
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        return $result
    fi

    # Run health check
    echo ""
    _update_log INFO "Running health check..."
    if nftban health check --auto-heal --quiet 2>/dev/null; then
        _update_log OK "Health check passed"
    else
        _update_log WARN "Health check reported issues"
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
    rollback            Restore previous version from backup
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

    # Rollback to previous version
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
        rollback|--rollback|-r)
            _update_banner
            echo ""
            _do_rollback
            ;;
        list|--list|-l)
            _update_banner
            _list_backups
            ;;
        help|--help|-h)
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
