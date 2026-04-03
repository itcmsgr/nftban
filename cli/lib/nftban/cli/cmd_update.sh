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
# meta:version="1.68.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Automated updates with auto-detection of install type (loader)"
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
export _NFTBAN_UPDATE_SKIP_CHECKSUM=0

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
# HELPERS
# =============================================================================

_update_detect_ssh_port() {
    # Detect active SSH port using canonical 3-tier fallback:
    #   1. State file (most reliable, written by nftban)
    #   2. sshd_config Port directive
    #   3. Default 22
    local ssh_port=22
    local ssh_port_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
    if [[ -f "$ssh_port_file" ]]; then
        local _sp
        _sp=$(cat "$ssh_port_file" 2>/dev/null) || true
        [[ "$_sp" =~ ^[0-9]+$ ]] && ssh_port="$_sp"
    elif [[ -f /etc/ssh/sshd_config ]]; then
        local _sp
        _sp=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1) || true
        [[ "$_sp" =~ ^[0-9]+$ ]] && ssh_port="$_sp"
    fi
    echo "$ssh_port"
}

# =============================================================================
# MAIN COMMANDS
# =============================================================================

_cmd_update_status() {
    # Show current installation status
    local install_type current_version
    install_type=$(_detect_install_type)
    current_version=$(_get_current_version)

    # Get detailed distro info
    local distro_info sys_pkg
    distro_info=$(_detect_distro)
    sys_pkg=$(_detect_system_pkg_manager)

    local family distro version
    IFS=':' read -r family distro version <<< "$distro_info"

    local expected_pkg
    expected_pkg=$(_get_distro_package_name)

    # JSON output mode (v1.19.13)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        local pkg_info=""
        case "$install_type" in
            rpm) pkg_info=$(rpm -q nftban-core 2>&1 | grep -v 'is not installed' || rpm -q nftban 2>&1 | grep -v 'is not installed' || echo 'not installed') ;;
            deb) pkg_info=$(dpkg-query -W -f='${Package} ${Version}' nftban-core 2>/dev/null || dpkg-query -W -f='${Package} ${Version}' nftban 2>/dev/null || echo 'not installed') ;;
            git) pkg_info="$NFTBAN_GIT_REPO@$NFTBAN_GIT_BRANCH" ;;
            *) pkg_info="unknown" ;;
        esac
        cat <<EOF
{"install_type":"$install_type","current_version":"$current_version","package_manager":"$sys_pkg","distribution":"$distro","distribution_version":"$version","package_family":"$family","expected_package":"$expected_pkg","package_info":"$pkg_info"}
EOF
        return 0
    fi

    # Human-readable output
    _update_banner
    echo ""

    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │ SYSTEM INFORMATION                                      │"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf "  │ Package Manager:  %-38s │\n" "$sys_pkg"
    printf "  │ Distribution:     %-38s │\n" "${distro} ${version}"
    printf "  │ Package Family:   %-38s │\n" "$family"
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
            rpm_pkg=$(rpm -q nftban-core 2>&1 | grep -v 'is not installed' || rpm -q nftban 2>&1 | grep -v 'is not installed' || echo 'not installed')
            printf "  │ RPM Package:      %-38s │\n" "$rpm_pkg"
            ;;
        deb)
            local deb_pkg
            deb_pkg=$(dpkg-query -W -f='${Package} ${Version}' nftban-core 2>/dev/null || dpkg-query -W -f='${Package} ${Version}' nftban 2>/dev/null || echo 'not installed')
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
    # Supports: --cache flag to write /var/cache/nftban/update_available.json

    _load_config

    local write_cache=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cache) write_cache=1; shift ;;
            --json|-j) export NFTBAN_JSON="true"; shift ;;
            *) shift ;;
        esac
    done

    local install_type current_version latest_version
    install_type=$(_detect_install_type)
    current_version=$(_get_current_version)
    latest_version=$(_get_latest_release)

    local update_available="false"
    if [[ "$latest_version" != "unknown" && "$current_version" != "$latest_version" ]]; then
        update_available="true"
    fi

    # Determine channel eligibility
    local channel="${NFTBAN_UPDATE_CHANNEL:-stable}"
    local eligible="false"
    local reason="blocked_check_failed"

    if [[ "$latest_version" == "unknown" ]]; then
        reason="blocked_check_failed"
    elif [[ "$current_version" == "$latest_version" ]]; then
        reason="blocked_same_version"
    else
        local cur_major cur_minor cur_patch lat_major lat_minor lat_patch
        IFS='.' read -r cur_major cur_minor cur_patch <<< "$current_version"
        IFS='.' read -r lat_major lat_minor lat_patch <<< "$latest_version"

        if [[ "$channel" == "latest" ]]; then
            eligible="true"
            reason="eligible_any"
        elif [[ "$channel" == "stable" ]]; then
            if [[ "$cur_major" != "$lat_major" ]]; then
                reason="blocked_major_on_stable"
            elif [[ "$cur_minor" != "$lat_minor" ]]; then
                reason="blocked_minor_on_stable"
            else
                eligible="true"
                reason="eligible_patch"
            fi
        fi
    fi

    # Write cache if requested (atomic write)
    if [[ $write_cache -eq 1 ]]; then
        local cache_dir="${NFTBAN_CACHE_DIR:-/var/cache/nftban}"
        local cache_file="${cache_dir}/update_available.json"
        mkdir -p "$cache_dir" 2>/dev/null || true
        local _ts
        _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        local _tmp
        _tmp=$(mktemp "${cache_file}.XXXXXX") || {
            _update_log ERROR "Failed to create temp file for cache"
            return 1
        }
        printf '{"timestamp":"%s","current":"%s","latest":"%s","available":%s,"channel":"%s","eligible":%s,"reason":"%s"}\n' \
            "$_ts" "$current_version" "$latest_version" "$update_available" "$channel" "$eligible" "$reason" > "$_tmp"
        mv -f "$_tmp" "$cache_file"
        chmod 0644 "$cache_file" 2>/dev/null || true
    fi

    # JSON output mode (v1.19.13)
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        printf '{"install_type":"%s","current_version":"%s","latest_version":"%s","update_available":%s,"channel":"%s","eligible":%s,"reason":"%s"}\n' \
            "$install_type" "$current_version" "$latest_version" "$update_available" "$channel" "$eligible" "$reason"
        return 0
    fi

    # Human-readable output
    _update_banner
    echo ""

    echo "  Install type:  $install_type"
    echo "  Current:       v$current_version"
    echo ""
    echo "  Checking GitHub for updates..."

    if [[ "$latest_version" == "unknown" ]]; then
        _update_log ERROR "Failed to check GitHub releases"
        return 1
    fi

    echo "  Latest:        v$latest_version"
    echo "  Channel:       $channel"
    echo "  Eligible:      $eligible ($reason)"
    echo ""

    if [[ "$current_version" == "$latest_version" ]]; then
        _update_log OK "Already up to date"
    elif [[ "$eligible" == "true" ]]; then
        _update_log INFO "Update available: v$current_version → v$latest_version"
        echo ""
        echo "  Run 'nftban update' to install"
    else
        _update_log INFO "Update v$latest_version available but not eligible on '$channel' channel"
        echo ""
        echo "  Run 'nftban update' for manual update"
    fi

    [[ $write_cache -eq 1 ]] && _update_log OK "Cache written: ${NFTBAN_CACHE_DIR:-/var/cache/nftban}/update_available.json"

    return 0
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

    # Log context for audit trail
    local _update_hostname
    _update_hostname=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    _update_log INFO "=== Update started on ${_update_hostname} ==="
    _update_log INFO "From: v${current_version} | Type: ${install_type} | Source: ${source}"
    local _update_start_seconds=$SECONDS

    echo "  Install type:  $install_type"
    echo "  Current:       v$current_version"
    echo "  Source:        $source"
    echo ""

    # Create backup (H14 fix: abort if backup fails unless --force)
    if ! _create_backup; then
        if [[ "$_NFTBAN_UPDATE_FORCE" -eq 1 ]]; then
            _update_log WARN "Backup failed but continuing (--force mode)"
        else
            _update_log ERROR "Backup failed - aborting update (use --force to override)"
            return 1
        fi
    fi

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
        local _update_duration=$(( SECONDS - _update_start_seconds ))
        _update_log ERROR "=== Update failed: v${current_version} (${_update_duration}s) ==="
        _update_write_history "$current_version" "$current_version" "install_fail" "$install_type" "$_update_duration"
        # Write failure marker for circuit breaker
        local _fail_marker="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed"
        mkdir -p "$(dirname "$_fail_marker")" 2>/dev/null || true
        date -u '+%Y-%m-%dT%H:%M:%SZ' > "$_fail_marker" 2>/dev/null || true
        echo ""
        _update_log ERROR "Update failed"
        _update_log INFO "Run 'nftban update repair' to fix broken install state"
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        _update_log INFO "Run 'nftban update force' to force reinstall"
        echo ""
        echo "  Log: $UPDATE_LOG_FILE"
        echo ""
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
    # Invalidate stale health cache from previous version
    rm -f "${NFTBAN_CACHE_DIR:-/var/cache/nftban}/health/health_status.cache" 2>/dev/null || true
    _update_log INFO "Running health check..."
    local health_output health_status
    health_output=$(nftban health check --auto-heal --cache-status 2>&1) || health_status=$?
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

    # Post-update verification (UPD-P1-1)
    local new_version
    new_version=$(_get_current_version)
    echo ""
    _update_log INFO "Running post-update verification..."
    local _verify_fail=0

    # V1: nftables authority — nftban table must exist
    if command -v nft &>/dev/null; then
        if nft list tables 2>/dev/null | grep >/dev/null 2>&1 nftban; then
            _update_log OK "nftables authority: nftban table present"
        else
            _update_log ERROR "nftables authority: nftban table not found"
            _verify_fail=1
        fi
    else
        _update_log WARN "nft command not available, skipping authority check"
    fi

    # V2: SSH port reachable in whitelist
    if command -v nft &>/dev/null; then
        local _ssh_port
        _ssh_port=$(_update_detect_ssh_port)
        local _ssh_in_set=0
        # Check IPv4 tcp_ports_in
        if nft list set inet nftban tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b"; then
            _ssh_in_set=1
        fi
        # Check IPv6 tcp_ports_in
        if nft list set inet nftban6 tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b"; then
            _ssh_in_set=1
        fi
        if [[ $_ssh_in_set -eq 1 ]]; then
            _update_log OK "SSH port ${_ssh_port}: present in service ports"
        else
            _update_log ERROR "SSH port ${_ssh_port}: NOT in service ports — lockout risk"
            _verify_fail=1
        fi
    fi

    # V3: Health check severity — exit 2 = critical failure
    if [[ $health_status -ge 2 ]]; then
        _update_log ERROR "Health check returned critical errors (exit $health_status)"
        _verify_fail=1
    fi

    # V4: Daemon active (if installed)
    if systemctl list-unit-files nftband.service &>/dev/null 2>&1; then
        if systemctl is-active --quiet nftband.service 2>/dev/null; then
            _update_log OK "Daemon nftband.service: active"
        else
            _update_log ERROR "Daemon nftband.service: not active"
            _verify_fail=1
        fi
    fi

    # V5: VERSION matches expected target
    if [[ -n "${arg:-}" && "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Explicit version was requested — verify exact match
        if [[ "$new_version" == "$arg" ]]; then
            _update_log OK "VERSION: $new_version matches target $arg"
        else
            _update_log ERROR "VERSION: $new_version does not match target $arg"
            _verify_fail=1
        fi
    elif [[ "$new_version" != "unknown" && "$new_version" != "$current_version" ]]; then
        _update_log OK "VERSION: updated to $new_version"
    else
        _update_log WARN "VERSION: still at $new_version (expected change from $current_version)"
    fi

    # Handle verification failure
    local _update_duration=$(( SECONDS - _update_start_seconds ))
    if [[ $_verify_fail -ne 0 ]]; then
        _update_log ERROR "=== Post-update verification FAILED: v${current_version} → v${new_version} (${_update_duration}s) ==="
        _update_write_history "$current_version" "$new_version" "verify_fail" "$install_type" "$_update_duration"
        # Write failure marker for circuit breaker
        local _fail_marker="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed"
        mkdir -p "$(dirname "$_fail_marker")" 2>/dev/null || true
        date -u '+%Y-%m-%dT%H:%M:%SZ' > "$_fail_marker" 2>/dev/null || true
        echo ""
        _update_log ERROR "Post-update verification failed"
        _update_log INFO "Run 'nftban update verify' to re-check"
        _update_log INFO "Run 'nftban update rollback' to restore previous version"
        echo ""
        echo "  Log: $UPDATE_LOG_FILE"
        echo ""
        return 1
    fi

    # Show result
    _update_log INFO "=== Update completed: v${current_version} → v${new_version} (${_update_duration}s) ==="

    # Write history entry
    _update_write_history "$current_version" "$new_version" "success" "$install_type" "$_update_duration"

    # Clear failure marker on success
    rm -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed" 2>/dev/null || true

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Updated: v$current_version → v$new_version (${_update_duration}s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Log: $UPDATE_LOG_FILE"
    echo "  History: nftban update history"
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

_cmd_update_history() {
    # Show update history from JSON state file
    local history_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-history.json"

    if [[ ! -f "$history_file" ]]; then
        echo "  No update history found."
        echo "  History is recorded after the first update using v1.60.1+."
        return 0
    fi

    # JSON output mode
    if [[ "${NFTBAN_JSON:-}" == "true" ]]; then
        cat "$history_file"
        return 0
    fi

    # Human-readable output
    _update_banner
    echo ""
    echo "  UPDATE HISTORY (last 9)"
    echo "  ────────────────────────────────────────────────────"

    if ! command -v jq &>/dev/null; then
        echo "  (jq not available — showing raw JSON)"
        echo ""
        cat "$history_file"
        return 0
    fi

    local count
    count=$(jq 'length' "$history_file" 2>/dev/null || echo 0)

    if [[ "$count" -eq 0 ]]; then
        echo "  (empty)"
        return 0
    fi

    jq -r '.[] | "  \(.timestamp)  \(.from) → \(.to)  \(.status)  \(.type)  \(.duration_s)s"' "$history_file" 2>/dev/null
    echo ""
    echo "  Entries: $count"
    echo "  File: $history_file"
    echo "  JSON: nftban update history --json"
    echo ""
}

_cmd_update_preflight() {
    # Pre-flight checks for auto-update — ALL hard gates
    # Returns: 0=all pass, 1=blocked (with reason)
    local _pf_fail=0 _pf_count=0 _pf_pass=0

    _pf_check() {
        _pf_count=$(( _pf_count + 1 ))
        local label="$1" result="$2"
        if [[ "$result" == "PASS" ]]; then
            _pf_pass=$(( _pf_pass + 1 ))
            echo "  [PASS] PF${_pf_count}: $label"
        elif [[ "$result" == "WARN" ]]; then
            _pf_pass=$(( _pf_pass + 1 ))
            echo "  [WARN] PF${_pf_count}: $label"
        else
            _pf_fail=1
            echo "  [FAIL] PF${_pf_count}: $label"
        fi
    }

    echo ""
    echo "  UPDATE PREFLIGHT (9 checks)"
    echo "  ────────────────────────────────────────────────────"

    # Load config (grep-based, not source)
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/update.conf"
    local config_local="${config_file}.local"
    local _auto_enabled="false"
    if [[ -f "$config_local" ]]; then
        local _val
        _val=$(grep -E '^\s*NFTBAN_UPDATE_AUTO_ENABLED=' "$config_local" 2>/dev/null | tail -1 | sed 's/.*="\?\([^"]*\)"\?.*/\1/') || true
        [[ -n "$_val" ]] && _auto_enabled="$_val"
    fi
    if [[ "$_auto_enabled" != "true" && -f "$config_file" ]]; then
        local _val
        _val=$(grep -E '^\s*NFTBAN_UPDATE_AUTO_ENABLED=' "$config_file" 2>/dev/null | tail -1 | sed 's/.*="\?\([^"]*\)"\?.*/\1/') || true
        [[ -n "$_val" ]] && _auto_enabled="$_val"
    fi

    # PF1: Auto-update enabled
    if [[ "$_auto_enabled" == "true" ]]; then
        _pf_check "Auto-update enabled" "PASS"
    else
        _pf_check "Auto-update enabled (current: $_auto_enabled)" "FAIL"
    fi

    # PF2: Cache fresh (<48h)
    local cache_file="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/update_available.json"
    local _cache_fresh="FAIL"
    if [[ -f "$cache_file" ]]; then
        local _cache_mtime _now _cache_age
        _now=$(date +%s)
        _cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
        _cache_age=$(( _now - _cache_mtime ))
        if [[ $_cache_age -lt 172800 ]]; then
            _cache_fresh="PASS"
        fi
    fi
    if [[ "$_cache_fresh" == "PASS" ]]; then
        _pf_check "Cache fresh ($(( _cache_age / 3600 ))h old)" "PASS"
    else
        _pf_check "Cache missing or stale (run: nftban update check --cache)" "FAIL"
    fi

    # PF3: Eligible in cache
    local _eligible="false"
    if [[ -f "$cache_file" ]]; then
        if command -v jq &>/dev/null; then
            _eligible=$(jq -r '.eligible // false' "$cache_file" 2>/dev/null || echo "false")
        else
            _eligible=$(grep -o '"eligible":[a-z]*' "$cache_file" 2>/dev/null | head -1 | sed 's/.*://') || true
        fi
    fi
    if [[ "$_eligible" == "true" ]]; then
        _pf_check "Cache shows eligible update" "PASS"
    else
        _pf_check "Cache shows not eligible (eligible=$_eligible)" "FAIL"
    fi

    # PF4: nftables authority
    if command -v nft &>/dev/null; then
        if nft list tables 2>/dev/null | grep >/dev/null 2>&1 nftban; then
            _pf_check "nftables authority: nftban table present" "PASS"
        else
            _pf_check "nftables authority: nftban table not found" "FAIL"
        fi
    else
        _pf_check "nftables authority: nft command not available" "FAIL"
    fi

    # PF5: SSH port in service ports
    if command -v nft &>/dev/null; then
        local _ssh_port
        _ssh_port=$(_update_detect_ssh_port)
        local _ssh_ok=0
        nft list set inet nftban tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b" && _ssh_ok=1
        nft list set inet nftban6 tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b" && _ssh_ok=1
        if [[ $_ssh_ok -eq 1 ]]; then
            _pf_check "SSH port ${_ssh_port} in service ports" "PASS"
        else
            _pf_check "SSH port ${_ssh_port} NOT in service ports" "FAIL"
        fi
    else
        _pf_check "SSH port check: nft not available" "FAIL"
    fi

    # PF6: Config validation
    if command -v nftban &>/dev/null; then
        if nftban config validate --quiet 2>/dev/null; then
            _pf_check "Config validation passed" "PASS"
        else
            _pf_check "Config validation failed" "FAIL"
        fi
    else
        _pf_check "Config validation: nftban command not available" "FAIL"
    fi

    # PF7: No active lock
    if [[ -f "$UPDATE_LOCK_FILE" ]]; then
        if command -v fuser &>/dev/null; then
            if fuser "$UPDATE_LOCK_FILE" &>/dev/null 2>&1; then
                _pf_check "Update lock: active (another update running)" "FAIL"
            else
                _pf_check "Update lock: stale file (will be overridden)" "WARN"
            fi
        else
            _pf_check "Update lock: file exists, cannot verify holder (fuser unavailable)" "FAIL"
        fi
    else
        _pf_check "No active update lock" "PASS"
    fi

    # PF8: Load average acceptable
    local _load_thresh="${NFTBAN_UPDATE_SKIP_HIGH_LOAD:-4.0}"
    if [[ "$_load_thresh" != "0" ]]; then
        local _load_avg
        _load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
        local _is_high=0
        if command -v bc &>/dev/null; then
            _is_high=$(echo "$_load_avg > $_load_thresh" | bc -l 2>/dev/null || echo "0")
        else
            _is_high=$(awk -v load="$_load_avg" -v thresh="$_load_thresh" 'BEGIN { print (load > thresh) ? 1 : 0 }')
        fi
        if [[ "$_is_high" == "1" ]]; then
            _pf_check "Load average ${_load_avg} > threshold ${_load_thresh}" "FAIL"
        else
            _pf_check "Load average ${_load_avg} <= ${_load_thresh}" "PASS"
        fi
    else
        _pf_check "Load check disabled" "PASS"
    fi

    # PF9: Circuit breaker clear
    local _fail_marker="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed"
    local _cooldown="${NFTBAN_UPDATE_FAILURE_COOLDOWN:-604800}"
    if [[ -f "$_fail_marker" && "$_cooldown" != "0" ]]; then
        local _now _marker_mtime _marker_age
        _now=$(date +%s)
        _marker_mtime=$(stat -c %Y "$_fail_marker" 2>/dev/null || echo "0")
        _marker_age=$(( _now - _marker_mtime ))
        if [[ $_marker_age -lt $_cooldown ]]; then
            _pf_check "Circuit breaker active (failure ${_marker_age}s ago, cooldown ${_cooldown}s)" "FAIL"
        else
            _pf_check "Circuit breaker: marker expired" "PASS"
        fi
    else
        _pf_check "Circuit breaker clear" "PASS"
    fi

    # Summary
    echo ""
    echo "  Result: ${_pf_pass}/${_pf_count} checks passed"
    if [[ $_pf_fail -ne 0 ]]; then
        echo "  Status: BLOCKED — resolve failures before auto-apply"
        echo ""
        return 1
    else
        echo "  Status: READY for auto-apply"
        echo ""
        return 0
    fi
}

_cmd_update_verify() {
    # Post-update verification (standalone)
    # 6 checks: nft auth, SSH, health, daemon, VERSION, invariants
    # Supports: --expected VERSION for exact match

    local expected_version=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expected) expected_version="${2:-}"; shift 2 || { echo "ERROR: --expected requires a version" >&2; return 1; } ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "  POST-UPDATE VERIFICATION (6 checks)"
    echo "  ────────────────────────────────────────────────────"

    local _vf_fail=0 _vf_count=0 _vf_pass=0

    _vf_check() {
        _vf_count=$(( _vf_count + 1 ))
        local label="$1" result="$2"
        if [[ "$result" == "PASS" ]]; then
            _vf_pass=$(( _vf_pass + 1 ))
            echo "  [PASS] VF${_vf_count}: $label"
        elif [[ "$result" == "WARN" ]]; then
            _vf_pass=$(( _vf_pass + 1 ))
            echo "  [WARN] VF${_vf_count}: $label"
        else
            _vf_fail=1
            echo "  [FAIL] VF${_vf_count}: $label"
        fi
    }

    # VF1: nftables authority
    if command -v nft &>/dev/null; then
        if nft list tables 2>/dev/null | grep >/dev/null 2>&1 nftban; then
            _vf_check "nftables authority: nftban table present" "PASS"
        else
            _vf_check "nftables authority: nftban table not found" "FAIL"
        fi
    else
        _vf_check "nftables authority: nft command not available" "FAIL"
    fi

    # VF2: SSH port in service ports
    if command -v nft &>/dev/null; then
        local _ssh_port
        _ssh_port=$(_update_detect_ssh_port)
        local _ssh_ok=0
        nft list set inet nftban tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b" && _ssh_ok=1
        nft list set inet nftban6 tcp_ports_in 2>/dev/null | grep >/dev/null 2>&1 "\\b${_ssh_port}\\b" && _ssh_ok=1
        if [[ $_ssh_ok -eq 1 ]]; then
            _vf_check "SSH port ${_ssh_port} in service ports" "PASS"
        else
            _vf_check "SSH port ${_ssh_port} NOT in service ports — lockout risk" "FAIL"
        fi
    else
        _vf_check "SSH port check: nft not available" "FAIL"
    fi

    # VF3: Health check
    local _health_exit=0
    nftban health check --auto-heal --cache-status &>/dev/null || _health_exit=$?
    if [[ $_health_exit -eq 0 ]]; then
        _vf_check "Health check passed" "PASS"
    elif [[ $_health_exit -eq 1 ]]; then
        _vf_check "Health check: warnings (non-critical)" "WARN"
    else
        _vf_check "Health check: critical errors (exit $_health_exit)" "FAIL"
    fi

    # VF4: Daemon responsive
    if systemctl list-unit-files nftband.service &>/dev/null 2>&1; then
        if systemctl is-active --quiet nftband.service 2>/dev/null; then
            _vf_check "Daemon nftband.service: active" "PASS"
        else
            _vf_check "Daemon nftband.service: not active" "FAIL"
        fi
    else
        _vf_check "Daemon nftband.service: not installed (optional)" "PASS"
    fi

    # VF5: VERSION present + valid
    local _cur_ver
    _cur_ver=$(_get_current_version)
    if [[ -z "$_cur_ver" || "$_cur_ver" == "unknown" ]]; then
        _vf_check "VERSION: not found or unknown" "FAIL"
    elif ! [[ "$_cur_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _vf_check "VERSION: invalid format '$_cur_ver'" "FAIL"
    elif [[ -n "$expected_version" ]]; then
        if [[ "$_cur_ver" == "$expected_version" ]]; then
            _vf_check "VERSION: $_cur_ver matches expected $expected_version" "PASS"
        else
            _vf_check "VERSION: $_cur_ver does not match expected $expected_version" "FAIL"
        fi
    else
        _vf_check "VERSION: $_cur_ver (valid)" "PASS"
    fi

    # VF6: Invariant validator
    if command -v nftban &>/dev/null; then
        local _inv_exit=0
        nftban firewall validate &>/dev/null || _inv_exit=$?
        if [[ $_inv_exit -eq 0 ]]; then
            _vf_check "Invariant validator passed" "PASS"
        else
            _vf_check "Invariant validator: errors (exit $_inv_exit)" "FAIL"
        fi
    else
        _vf_check "Invariant validator: nftban command not available" "FAIL"
    fi

    # Summary
    echo ""
    echo "  Result: ${_vf_pass}/${_vf_count} checks passed"
    if [[ $_vf_fail -ne 0 ]]; then
        echo "  Status: VERIFICATION FAILED"
        echo ""
        return 1
    else
        echo "  Status: VERIFIED"
        echo ""
        return 0
    fi
}

_cmd_update_auto_apply() {
    # Self-validates cache then applies update
    # Does NOT assume preflight was run — self-sufficient safety

    local cache_file="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/update_available.json"

    echo ""
    _update_log INFO "Auto-apply: validating cache..."

    # 1. Cache file exists
    if [[ ! -f "$cache_file" ]]; then
        _update_log ERROR "No cache file found. Run: nftban update check --cache"
        return 1
    fi

    # 2. Cache fresh (<48h)
    local _now _cache_mtime _cache_age
    _now=$(date +%s)
    _cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
    _cache_age=$(( _now - _cache_mtime ))
    if [[ $_cache_age -ge 172800 ]]; then
        _update_log ERROR "Cache stale ($(( _cache_age / 3600 ))h old). Run: nftban update check --cache"
        return 1
    fi

    # 3. Parse cache
    local _eligible="" _target="" _current="" _reason=""
    if command -v jq &>/dev/null; then
        _eligible=$(jq -r '.eligible // false' "$cache_file" 2>/dev/null || echo "false")
        _target=$(jq -r '.latest // ""' "$cache_file" 2>/dev/null || echo "")
        _current=$(jq -r '.current // ""' "$cache_file" 2>/dev/null || echo "")
        _reason=$(jq -r '.reason // ""' "$cache_file" 2>/dev/null || echo "")
    else
        _eligible=$(grep -o '"eligible":[a-z]*' "$cache_file" 2>/dev/null | head -1 | sed 's/.*://') || true
        _target=$(grep -o '"latest":"[^"]*"' "$cache_file" 2>/dev/null | head -1 | sed 's/.*:"//;s/"//') || true
        _current=$(grep -o '"current":"[^"]*"' "$cache_file" 2>/dev/null | head -1 | sed 's/.*:"//;s/"//') || true
        _reason=$(grep -o '"reason":"[^"]*"' "$cache_file" 2>/dev/null | head -1 | sed 's/.*:"//;s/"//') || true
    fi

    # 3. Eligible
    if [[ "$_eligible" != "true" ]]; then
        _update_log ERROR "Not eligible for auto-update (reason: ${_reason:-unknown})"
        return 1
    fi

    # 4. Target version present and valid
    if [[ -z "$_target" ]] || ! [[ "$_target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _update_log ERROR "Invalid target version in cache: '$_target'"
        return 1
    fi

    # 5. Current version < target version
    local _live_current
    _live_current=$(_get_current_version)
    if [[ "$_live_current" == "$_target" ]]; then
        _update_log INFO "Already up to date: v${_live_current}"
        return 0
    fi

    _update_log INFO "Auto-apply: v${_live_current} → v${_target}"

    # 6. Call main update
    _cmd_update_main "github" "$_target"
    return $?
}

_cmd_update_help() {
    cat << 'EOF'
NFTBan Update - Multi-source update system

USAGE:
    nftban update [COMMAND] [OPTIONS]

COMMANDS:
    (none)              Auto-detect install type and update from appropriate source
    check               Check if updates are available (no changes)
    check --cache       Check + write eligibility cache for auto-apply
    status              Show current installation information
    github [VERSION]    Update from GitHub releases (RPM/DEB packages)
    git [BRANCH]        Update from git repository (requires git install)
    local PATH          Install from local directory path
    force               Force reinstall/update (fixes dpkg, removes immutable flags)
    rollback            Restore previous version from backup (fixes dpkg first)
    repair              Fix broken install (dpkg state, immutable flags, restore backup)
    list                List available backups
    history             Show update history (last 9 updates, --json supported)
    auto [ACTION]       Manage auto-update timer (enable|disable|status)
                        Requires --email for enable (mandatory notification)
    preflight           Validate system readiness for auto-update (9 checks)
    verify              Post-update health verification (6 checks)
    verify --expected V Verify and confirm VERSION matches V exactly
    auto-apply          Install from cached eligibility (self-validates)
    help                Show this help message

AUTOMATED UPDATE WORKFLOW:
    1. check --cache     Discover updates, write eligibility cache
    2. preflight         Validate system readiness (9 checks)
    3. auto-apply        Install from cached eligibility
    4. verify            Confirm post-update health

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

    # Show update history
    nftban update history
    nftban update history --json

    # Enable weekly auto-updates (uses global NFTBAN_MAIL_RECIPIENT if set)
    nftban update auto enable

    # Enable with specific email
    nftban update auto enable --email admin@example.com

    # Enable using panel admin email (auto-detect)
    nftban update auto enable --email panel

    # Check auto-update status
    nftban update auto status

    # Disable auto-updates
    nftban update auto disable

AUTO-UPDATE:
    The auto-update feature runs weekly (Sunday 4:00 AM) via systemd timer.
    Email notification is MANDATORY - you cannot enable auto-updates without
    configuring a notification email to ensure you're informed of results.

    Email is resolved in order:
      1. --email argument (explicit)
      2. NFTBAN_UPDATE_NOTIFY_EMAIL in update.conf
      3. NFTBAN_MAIL_RECIPIENT in mail.conf (global email)
      4. Panel admin email (if --email panel)

    Configuration: /etc/nftban/conf.d/update.conf
    Logs: ${NFTBAN_LOG_DIR}/update.log, journalctl -u nftban-update.service

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
# AUTO-UPDATE MANAGEMENT
# =============================================================================

_cmd_update_auto() {
    # Manage auto-update timer
    # Usage: nftban update auto [enable|disable|status] [--email EMAIL]

    local action="${1:-status}"
    local email_arg=""

    # Parse arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            enable|disable|status)
                action="$1"
                shift
                ;;
            --email|-e)
                email_arg="${2:-}"
                shift 2 || { echo "ERROR: --email requires an argument" >&2; return 1; }
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$action" in
        enable)
            _update_auto_enable "$email_arg"
            ;;
        disable)
            _update_auto_disable
            ;;
        status)
            _update_auto_status
            ;;
        *)
            echo "Usage: nftban update auto [enable|disable|status] [--email EMAIL]" >&2
            echo "" >&2
            echo "  enable                            Enable (uses global NFTBAN_MAIL_RECIPIENT)" >&2
            echo "  enable --email user@example.com   Enable with specific email" >&2
            echo "  enable --email panel              Enable using panel admin email" >&2
            echo "  disable                           Disable auto-updates" >&2
            echo "  status                            Show current status" >&2
            echo "" >&2
            echo "Email is resolved in order: --email arg > update.conf > mail.conf (global)" >&2
            return 1
            ;;
    esac
}

_update_auto_enable() {
    # Enable auto-update timer
    # REQUIRES: Valid notification email configured
    # Args: $1 = email (optional, overrides config)
    #
    # Email resolution order:
    #   1. --email argument (explicit override)
    #   2. NFTBAN_UPDATE_NOTIFY_EMAIL from update.conf
    #   3. NFTBAN_MAIL_RECIPIENT from mail.conf (global email)
    #   4. Panel admin email detection (if --email panel)

    local email_override="$1"
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/update.conf"
    local config_local="${config_file}.local"
    local mail_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"
    local mail_config_local="${mail_config}.local"

    _update_banner
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Enabling auto-update requires root privileges"
        _update_log INFO "Run: sudo nftban update auto enable --email EMAIL"
        return 1
    fi

    # Load update config
    source "$config_file" 2>/dev/null || true
    source "$config_local" 2>/dev/null || true

    # Load mail config for global recipient
    source "$mail_config" 2>/dev/null || true
    source "$mail_config_local" 2>/dev/null || true

    # Email resolution: override -> update config -> global mail recipient
    local notify_email="${email_override:-${NFTBAN_UPDATE_NOTIFY_EMAIL:-${NFTBAN_MAIL_RECIPIENT:-}}}"
    local resolved_email=""
    local email_source=""

    if [[ -z "$notify_email" ]]; then
        _update_log ERROR "Cannot enable auto-update: No notification email configured"
        echo ""
        echo "  Configure email using one of these methods:" >&2
        echo "    nftban update auto enable --email user@example.com" >&2
        echo "    nftban update auto enable --email panel   # Use panel admin email" >&2
        echo "" >&2
        echo "  Or set a global email in /etc/nftban/conf.d/mail.conf:" >&2
        echo "    NFTBAN_MAIL_RECIPIENT=\"admin@example.com\"" >&2
        return 1
    elif [[ "$notify_email" == "panel" ]]; then
        email_source="panel detection"
        # Load panel common module for email detection
        local panel_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_panel_common.sh"
        if [[ -f "$panel_lib" ]]; then
            # shellcheck source=/dev/null
            source "$panel_lib" || return 1
        fi

        # Use panel admin email detection
        if declare -f nftban_panel_get_admin_email &>/dev/null; then
            resolved_email=$(nftban_panel_get_admin_email 2>/dev/null || echo "")
        fi

        if [[ -z "$resolved_email" ]]; then
            _update_log ERROR "Cannot detect panel admin email"
            _update_log INFO "No hosting panel detected or panel has no admin email configured"
            echo "  Please specify email manually: nftban update auto enable --email user@example.com" >&2
            return 1
        fi
        _update_log INFO "Using panel admin email: $resolved_email"
    else
        resolved_email="$notify_email"
        # Determine email source for logging
        if [[ -n "$email_override" ]]; then
            email_source="--email argument"
        elif [[ -n "${NFTBAN_UPDATE_NOTIFY_EMAIL:-}" ]]; then
            email_source="update.conf"
        elif [[ -n "${NFTBAN_MAIL_RECIPIENT:-}" ]]; then
            email_source="mail.conf (global)"
            _update_log INFO "Using global mail recipient: $resolved_email"
        else
            email_source="config"
        fi
    fi

    # Validate email format
    if ! [[ "$resolved_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        _update_log ERROR "Invalid email format: $resolved_email"
        return 1
    fi

    # Update local config with resolved email and enable flag
    mkdir -p "$(dirname "$config_local")" 2>/dev/null || true

    cat > "$config_local" << EOF
# NFTBan Auto-Update Local Configuration
# Generated by: nftban update auto enable
# Date: $(date '+%Y-%m-%d %H:%M:%S')

# Auto-update enabled
NFTBAN_UPDATE_AUTO_ENABLED="true"

# Notification email (source: ${email_source})
NFTBAN_UPDATE_NOTIFY_EMAIL="$resolved_email"
EOF

    _update_log OK "Configuration saved to: $config_local"

    # Enable and start timer
    _update_log INFO "Enabling systemd timer..."
    if systemctl enable --now nftban-update.timer 2>/dev/null; then
        _update_log OK "Timer enabled"
    else
        _update_log WARN "Could not enable timer (systemd may not be available)"
        _update_log INFO "Timer will be enabled on next system reboot"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Auto-update enabled"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Schedule:          Weekly, Sunday 4:00 AM (with 30min jitter)"
    echo "  Notification:      $resolved_email"
    echo "  Config:            $config_local"

    # Show next run time if timer is active
    local next_run=""
    if systemctl is-active nftban-update.timer &>/dev/null; then
        next_run=$(systemctl show nftban-update.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")
        [[ -n "$next_run" ]] && echo "  Next run:          $next_run" || true
    fi

    echo ""
    echo "  Check status:      nftban update auto status"
    echo "  View logs:         journalctl -u nftban-update.service"
    echo ""
}

_update_auto_disable() {
    # Disable auto-update timer

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/update.conf"
    local config_local="${config_file}.local"

    _update_banner
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        _update_log ERROR "Disabling auto-update requires root privileges"
        _update_log INFO "Run: sudo nftban update auto disable"
        return 1
    fi

    # Update local config
    if [[ -f "$config_local" ]]; then
        # Update the enabled flag in local config
        sed -i 's/NFTBAN_UPDATE_AUTO_ENABLED="true"/NFTBAN_UPDATE_AUTO_ENABLED="false"/' "$config_local"
        _update_log OK "Configuration updated: $config_local"
    fi

    # Disable timer
    if systemctl disable --now nftban-update.timer 2>/dev/null; then
        _update_log OK "Timer disabled"
    else
        _update_log INFO "Timer was not active"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Auto-update disabled"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Re-enable with: nftban update auto enable --email EMAIL"
    echo ""
}

_update_auto_status() {
    # Show auto-update status

    _update_banner
    echo ""
    echo "AUTO-UPDATE STATUS"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Load config
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/update.conf"
    local config_local="${config_file}.local"
    local mail_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"
    local mail_config_local="${mail_config}.local"
    local enabled="false"
    local channel="stable"
    local notify_email=""
    local notify_success="true"
    local notify_failure="true"
    local log_file="${NFTBAN_LOG_DIR}/update.log"
    local email_source=""

    # Load update config
    if [[ -f "$config_file" ]]; then
        source "$config_file" || true
    fi
    if [[ -f "$config_local" ]]; then
        source "$config_local" || true
    fi

    # Load mail config for global recipient fallback
    local global_mail_recipient=""
    if [[ -f "$mail_config" ]]; then
        source "$mail_config" || true
        global_mail_recipient="${NFTBAN_MAIL_RECIPIENT:-}"
    fi
    if [[ -f "$mail_config_local" ]]; then
        source "$mail_config_local" || true
        global_mail_recipient="${NFTBAN_MAIL_RECIPIENT:-$global_mail_recipient}"
    fi

    enabled="${NFTBAN_UPDATE_AUTO_ENABLED:-false}"
    channel="${NFTBAN_UPDATE_CHANNEL:-stable}"
    notify_email="${NFTBAN_UPDATE_NOTIFY_EMAIL:-}"
    notify_success="${NFTBAN_UPDATE_NOTIFY_SUCCESS:-true}"
    notify_failure="${NFTBAN_UPDATE_NOTIFY_FAILURE:-true}"
    log_file="${NFTBAN_UPDATE_LOG_FILE:-$log_file}"

    # Determine effective email and source
    if [[ -n "$notify_email" ]]; then
        email_source="update.conf"
    elif [[ -n "$global_mail_recipient" ]]; then
        notify_email="$global_mail_recipient"
        email_source="mail.conf (global)"
    fi

    # Timer status
    local timer_active timer_enabled next_run last_run exit_code
    timer_active=$(systemctl is-active nftban-update.timer 2>/dev/null || echo "inactive")
    timer_enabled=$(systemctl is-enabled nftban-update.timer 2>/dev/null || echo "disabled")

    # Configuration
    echo "  Configuration"
    echo "  ─────────────────────────────────────"
    if [[ "$enabled" == "true" ]]; then
        echo "  Config enabled:    YES"
    else
        echo "  Config enabled:    NO"
    fi
    echo "  Update channel:    $channel"
    if [[ -n "$notify_email" ]]; then
        echo "  Notify email:      $notify_email"
        [[ -n "$email_source" ]] && echo "  Email source:      $email_source"
    else
        echo "  Notify email:      (not configured)"
        echo "                     Set NFTBAN_MAIL_RECIPIENT in mail.conf or use --email"
    fi
    echo "  Notify success:    $notify_success"
    echo "  Notify failure:    $notify_failure"
    echo ""

    # Timer status
    echo "  Systemd Timer"
    echo "  ─────────────────────────────────────"
    if [[ "$timer_active" == "active" ]]; then
        echo "  Timer status:      ACTIVE (running)"
    else
        echo "  Timer status:      INACTIVE"
    fi
    echo "  Timer enabled:     $timer_enabled"

    if [[ "$timer_active" == "active" ]]; then
        next_run=$(systemctl show nftban-update.timer --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")
        [[ -n "$next_run" ]] && echo "  Next run:          $next_run" || true
    fi

    # Last run info from service
    if systemctl show nftban-update.service &>/dev/null 2>&1; then
        last_run=$(systemctl show nftban-update.service --property=ExecMainExitTimestamp --value 2>/dev/null || echo "")
        exit_code=$(systemctl show nftban-update.service --property=ExecMainStatus --value 2>/dev/null || echo "")

        if [[ -n "$last_run" && "$last_run" != "n/a" ]]; then
            echo "  Last run:          $last_run"
            case "$exit_code" in
                0) echo "  Last result:       SUCCESS (updated)" ;;
                1) echo "  Last result:       OK (no update needed)" ;;
                2) echo "  Last result:       FAILED" ;;
                *) [[ -n "$exit_code" ]] && echo "  Last exit code:    $exit_code" ;;
            esac
        fi
    fi
    echo ""

    # Config files
    echo "  Files"
    echo "  ─────────────────────────────────────"
    echo "  Config:            $config_file"
    [[ -f "$config_local" ]] && echo "  Local override:    $config_local"
    echo "  Log file:          $log_file"
    echo ""

    # Show recent log entries
    if [[ -f "$log_file" ]]; then
        echo "  Recent Log Entries"
        echo "  ─────────────────────────────────────"
        tail -5 "$log_file" 2>/dev/null | sed 's/^/  /' || echo "  (no entries)"
        echo ""
    fi

    # Show help if not enabled
    if [[ "$enabled" != "true" ]] || [[ "$timer_enabled" == "disabled" ]]; then
        echo "────────────────────────────────────────────────────────────────"
        echo "  To enable auto-updates:"
        echo "    nftban update auto enable --email admin@example.com"
        echo "    nftban update auto enable --email panel  # Use panel email"
        echo ""
    fi
}

_cmd_update_auto_run() {
    # Called by systemd timer - non-interactive update
    # Returns: 0=updated, 1=no update needed, 2=failed

    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/update.conf"
    local config_local="${config_file}.local"
    local mail_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"
    local mail_config_local="${mail_config}.local"
    local log_file="${NFTBAN_LOG_DIR}/update.log"

    # Load update config
    source "$config_file" 2>/dev/null || true
    source "$config_local" 2>/dev/null || true

    # Load mail config for global email fallback
    source "$mail_config" 2>/dev/null || true
    source "$mail_config_local" 2>/dev/null || true

    log_file="${NFTBAN_UPDATE_LOG_FILE:-$log_file}"

    # Check if enabled
    if [[ "${NFTBAN_UPDATE_AUTO_ENABLED:-false}" != "true" ]]; then
        _update_log INFO "Auto-update disabled in config, skipping"
        return 1
    fi

    # Circuit breaker: skip if recent failure within cooldown period
    local _fail_marker="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed"
    local _cooldown="${NFTBAN_UPDATE_FAILURE_COOLDOWN:-604800}"
    if [[ -f "$_fail_marker" && "$_cooldown" != "0" ]]; then
        local _marker_age _marker_mtime _now
        _now=$(date +%s)
        _marker_mtime=$(stat -c %Y "$_fail_marker" 2>/dev/null || echo "0")
        _marker_age=$(( _now - _marker_mtime ))
        if [[ $_marker_age -lt $_cooldown ]]; then
            local _remaining=$(( _cooldown - _marker_age ))
            local _days=$(( _remaining / 86400 ))
            _update_log WARN "Circuit breaker active: previous update failed ${_marker_age}s ago (cooldown: ${_cooldown}s, ${_days}d remaining)"
            _update_log INFO "Clear manually: rm $_fail_marker"
            return 1
        else
            _update_log INFO "Circuit breaker: failure marker expired (${_marker_age}s > ${_cooldown}s), clearing"
            rm -f "$_fail_marker" 2>/dev/null || true
        fi
    fi

    # Resolve notification email (same chain as _update_auto_enable)
    # Priority: NFTBAN_UPDATE_NOTIFY_EMAIL -> NFTBAN_MAIL_RECIPIENT -> panel detection
    local resolved_email="${NFTBAN_UPDATE_NOTIFY_EMAIL:-${NFTBAN_MAIL_RECIPIENT:-}}"

    # Try panel detection as last resort
    if [[ -z "$resolved_email" ]]; then
        if declare -f nftban_panel_get_admin_email &>/dev/null; then
            resolved_email=$(nftban_panel_get_admin_email 2>/dev/null || echo "")
        fi
    fi

    # Check for notification email (mandatory)
    if [[ -z "$resolved_email" ]]; then
        _update_log ERROR "Auto-update requires notification email but none configured"
        _update_log INFO "Run: nftban update auto enable --email admin@example.com"
        return 2
    fi

    # Set the resolved email for use by _update_notify_email
    NFTBAN_UPDATE_NOTIFY_EMAIL="$resolved_email"

    # Check load average
    if [[ -n "${NFTBAN_UPDATE_SKIP_HIGH_LOAD:-}" && "${NFTBAN_UPDATE_SKIP_HIGH_LOAD}" != "0" ]]; then
        local load_avg
        load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
        # Use bc for floating point comparison, fallback to awk if bc not available
        local is_high_load=0
        if command -v bc &>/dev/null; then
            is_high_load=$(echo "$load_avg > ${NFTBAN_UPDATE_SKIP_HIGH_LOAD}" | bc -l 2>/dev/null || echo "0")
        else
            is_high_load=$(awk -v load="$load_avg" -v thresh="${NFTBAN_UPDATE_SKIP_HIGH_LOAD}" 'BEGIN { print (load > thresh) ? 1 : 0 }')
        fi
        if [[ "$is_high_load" == "1" ]]; then
            _update_log WARN "Skipping update: load average $load_avg > ${NFTBAN_UPDATE_SKIP_HIGH_LOAD}"
            return 1
        fi
    fi

    _update_log INFO "=== Auto-update started ==="

    # Check for updates
    local current_version latest_version
    current_version=$(_get_current_version)
    latest_version=$(_get_latest_release)

    if [[ "$latest_version" == "unknown" ]]; then
        _update_log ERROR "Failed to check GitHub releases"
        _update_notify_email "failure" "$current_version" "unknown" "Failed to check GitHub for updates"
        return 2
    fi

    _update_log INFO "Current version: $current_version"
    _update_log INFO "Latest version:  $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        _update_log INFO "Already on latest version: $current_version"
        return 1
    fi

    # Channel check (stable = only patch versions)
    if [[ "${NFTBAN_UPDATE_CHANNEL:-stable}" == "stable" ]]; then
        local cur_major cur_minor lat_major lat_minor
        IFS='.' read -r cur_major cur_minor _ <<< "$current_version"
        IFS='.' read -r lat_major lat_minor _ <<< "$latest_version"

        if [[ "$cur_major" != "$lat_major" || "$cur_minor" != "$lat_minor" ]]; then
            _update_log INFO "New major/minor version available ($latest_version) but channel=stable, skipping"
            _update_log INFO "To update, run manually: nftban update"
            return 1
        fi
    fi

    _update_log INFO "Updating: $current_version -> $latest_version"

    # Store current version for rollback notification
    local pre_update_version="$current_version"

    # Perform update
    local update_result=0
    if _cmd_update_main "auto" "" 2>&1 | while IFS= read -r line; do
        _update_log INFO "$line"
    done; then
        update_result=0
    else
        update_result=$?
    fi

    if [[ $update_result -eq 0 ]]; then
        local new_version
        new_version=$(_get_current_version)
        _update_log OK "Update successful: $pre_update_version -> $new_version"

        # Send success notification if enabled
        if [[ "${NFTBAN_UPDATE_NOTIFY_SUCCESS:-true}" == "true" ]]; then
            _update_notify_email "success" "$pre_update_version" "$new_version"
        fi

        return 0
    else
        _update_log ERROR "Update failed"

        # Auto-rollback if enabled
        if [[ "${NFTBAN_UPDATE_AUTO_ROLLBACK:-true}" == "true" ]]; then
            _update_log WARN "Attempting auto-rollback..."
            if _do_rollback 2>&1 | while IFS= read -r line; do
                _update_log INFO "  $line"
            done; then
                _update_log OK "Rollback successful"
                _update_notify_email "failure" "$pre_update_version" "$latest_version" "Update failed, rolled back successfully"
            else
                _update_log ERROR "Rollback failed!"
                _update_notify_email "failure" "$pre_update_version" "$latest_version" "Update failed and rollback also failed - manual intervention required"
            fi
        else
            _update_notify_email "failure" "$pre_update_version" "$latest_version" "Update failed"
        fi

        return 2
    fi
}

_update_notify_email() {
    # Send email notification about update status
    # Args: $1 = status (success|failure)
    #       $2 = old_version
    #       $3 = new_version
    #       $4 = additional message (optional)

    local status="$1"
    local old_version="$2"
    local new_version="$3"
    local extra_msg="${4:-}"

    local recipient="${NFTBAN_UPDATE_NOTIFY_EMAIL:-}"
    [[ -z "$recipient" ]] && return 0

    local hostname_val
    hostname_val=$(hostname -f 2>/dev/null || hostname)

    local subject body

    if [[ "$status" == "success" ]]; then
        subject="[NFTBan] Update successful on $hostname_val"
        body="NFTBan auto-update completed successfully.

Server:   $hostname_val
Previous: v$old_version
Current:  v$new_version
Time:     $(date '+%Y-%m-%d %H:%M:%S %Z')

The update was applied automatically and all health checks passed.

View update log: ${NFTBAN_LOG_DIR}/update.log
View service log: journalctl -u nftban-update.service"
    else
        subject="[NFTBan] Update FAILED on $hostname_val"
        body="NFTBan auto-update failed!

Server:    $hostname_val
Attempted: v$old_version -> v$new_version
Time:      $(date '+%Y-%m-%d %H:%M:%S %Z')
${extra_msg:+
Details: $extra_msg}

Please check the server and review the logs:
  ${NFTBAN_LOG_DIR}/update.log
  journalctl -u nftban-update.service

To manually update:
  sudo nftban update

To rollback:
  sudo nftban update rollback"
    fi

    # Load mail module if available
    local mail_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh"
    if [[ -f "$mail_lib" ]]; then
        # shellcheck source=/dev/null
        source "$mail_lib" 2>/dev/null || true
    fi

    # Try to send email using nftban mail module
    if declare -f nftban_mail_send &>/dev/null; then
        # Use plain text for update notifications
        local old_html="${NFTBAN_MAIL_USE_HTML:-}"
        NFTBAN_MAIL_USE_HTML="NO"

        echo "$body" | nftban_mail_send "$body" "$recipient" 2>/dev/null && {
            _update_log INFO "Notification sent to: $recipient"
            NFTBAN_MAIL_USE_HTML="$old_html"
            return 0
        }
        NFTBAN_MAIL_USE_HTML="$old_html"
    fi

    # Fallback: try sendmail directly
    if command -v sendmail &>/dev/null; then
        {
            echo "From: nftban@$hostname_val"
            echo "To: $recipient"
            echo "Subject: $subject"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null && {
            _update_log INFO "Notification sent to: $recipient (via sendmail)"
            return 0
        }
    fi

    # Fallback: try mail command
    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$recipient" 2>/dev/null && {
            _update_log INFO "Notification sent to: $recipient (via mail)"
            return 0
        }
    fi

    _update_log WARN "Could not send email notification (no mail system available)"
    return 1
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_update() {
    local cmd="${1:-}"
    shift || true

    # Check for --json flag in remaining args (v1.19.13)
    for arg in "$@"; do
        if [[ "$arg" == "--json" || "$arg" == "-j" ]]; then
            export NFTBAN_JSON="true"
        fi
    done

    case "$cmd" in
        check|--check|-c)
            _cmd_update_check "$@"
            ;;
        status|--status|-s)
            _cmd_update_status
            ;;
        github)
            # Parse flags and version argument
            # v1.19.28 fix: intercept subcommand words so they are not used as version
            local version_arg=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --force|-f) _NFTBAN_UPDATE_FORCE=1; shift ;;
                    --skip-checksum) _NFTBAN_UPDATE_SKIP_CHECKSUM=1; shift ;;
                    force|reinstall)
                        _NFTBAN_UPDATE_FORCE=1
                        _NFTBAN_UPDATE_SKIP_CHECKSUM=1
                        shift ;;
                    repair|--repair|fix)
                        _cmd_update_repair; return $? ;;
                    rollback|--rollback)
                        _update_banner; echo ""; _do_rollback; return $? ;;
                    list|--list)
                        _update_banner; _list_backups; return $? ;;
                    -*) shift ;;  # Skip unknown flags
                    *) version_arg="$1"; shift ;;
                esac
            done
            _cmd_update_main "github" "$version_arg"
            ;;
        git)
            # Parse flags and branch argument
            # v1.19.28 fix: intercept subcommand words so they are not used as branch
            local branch_arg=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --force|-f) _NFTBAN_UPDATE_FORCE=1; shift ;;
                    force|reinstall)
                        _NFTBAN_UPDATE_FORCE=1; shift ;;
                    repair|--repair|fix)
                        _cmd_update_repair; return $? ;;
                    rollback|--rollback)
                        _update_banner; echo ""; _do_rollback; return $? ;;
                    list|--list)
                        _update_banner; _list_backups; return $? ;;
                    -*) shift ;;
                    *) branch_arg="$1"; shift ;;
                esac
            done
            _cmd_update_main "git" "$branch_arg"
            ;;
        local)
            # Parse flags and path argument
            # v1.19.28 fix: intercept subcommand words so they are not used as path
            local path_arg=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --force|-f) _NFTBAN_UPDATE_FORCE=1; shift ;;
                    force|reinstall)
                        _NFTBAN_UPDATE_FORCE=1; shift ;;
                    repair|--repair|fix)
                        _cmd_update_repair; return $? ;;
                    rollback|--rollback)
                        _update_banner; echo ""; _do_rollback; return $? ;;
                    list|--list)
                        _update_banner; _list_backups; return $? ;;
                    -*) shift ;;
                    *) path_arg="$1"; shift ;;
                esac
            done
            _cmd_update_main "local" "$path_arg"
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
        history|--history)
            _cmd_update_history
            ;;
        auto)
            _cmd_update_auto "$@"
            ;;
        auto-run)
            # Called by systemd timer - non-interactive
            _cmd_update_auto_run
            ;;
        preflight|pre-flight)
            _cmd_update_preflight
            ;;
        verify)
            _cmd_update_verify "$@"
            ;;
        auto-apply)
            _cmd_update_auto_apply
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
