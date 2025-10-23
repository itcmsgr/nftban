#!/usr/bin/env bash
# =============================================================================
# MODULE: NFTBan Auto-Rebuild Module
# Version: 0.9.3
# Status: Production
# Architecture: amd64/arm64/multi-platform
# SPDX-License-Identifier: NFTBAN-Custom-License
# Author: Antonios Voulvoulis – ITCMS
# License: NFTBAN Custom License v3.0
# Description: Watch a small set of config files and rebuild a consolidated
#              search/index file when sources change. Safe for cron execution.
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ------------------------------------
# Security Features Applied:
# - Enhanced strict mode (set -Eeuo pipefail)
# - Safe word splitting (IFS=$'\n\t')
# - Secure file permissions (umask 027)
# - PATH sanitization (readonly, trusted paths only)
# - Locale standardization
# - Error traps (catch all failures)
# - Required command checks and portable stat fallback
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Sanitize PATH (always set to safe value)
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
readonly PATH
export PATH

# Locale
export LC_ALL='C.UTF-8' LANG='C.UTF-8' || true

# Module guard - prevent multiple sourcing
if [[ -n "${NFTBAN_AUTOREBUILD_LOADED:-}" ]]; then
    return 0
fi
readonly NFTBAN_AUTOREBUILD_LOADED=1

# -------- required commands --------------------------------------------------
_required_cmds=(mktemp stat date flock grep cut sed tail mkdir mv crontab awk)
for _c in "${_required_cmds[@]}"; do
    if ! command -v "${_c}" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "${_c}" >&2
        # Do not exit on sourcing; fail-fast when run
        : # allow later calls to fail if needed
    fi
done

# -------- logging helpers ----------------------------------------------------
nftban_autorebuild_log() {
    # Primary logging function (append to module log)
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date +'%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
    if [[ -n "${NFTBAN_AUTOREBUILD_LOG:-}" ]]; then
        mkdir -p "$(dirname -- "$NFTBAN_AUTOREBUILD_LOG")" 2>/dev/null || true
        printf '[%s] %s: %s\n' "$ts" "$level" "$msg" >>"$NFTBAN_AUTOREBUILD_LOG" 2>/dev/null || true
    fi
    # Also attempt to call global logger if present
    if declare -f nftban_log_info >/dev/null 2>&1; then
        nftban_log_info "AUTOREBUILD: ${msg}"
    else
        printf '%s %s: %s\n' "$ts" "$level" "$msg" >&2
    fi
}

nftban_autorebuild_log_debug() { nftban_autorebuild_log "DEBUG" "$*"; }
nftban_autorebuild_log_info()  { nftban_autorebuild_log "INFO"  "$*"; }
nftban_autorebuild_log_warn()  { nftban_autorebuild_log "WARN"  "$*"; }
nftban_autorebuild_log_error() { nftban_autorebuild_log "ERROR" "$*"; }
nftban_autorebuild_log_success(){ nftban_autorebuild_log "OK"    "$*"; }

# -------- error trap --------------------------------------------------------
_nftban_autorebuild_on_err() {
    local rc=${1:-$?}
    local line=${2:-unknown}
    local func=${3:-main}
    nftban_autorebuild_log_error "AUTOREBUILD MODULE ERROR in ${func} at line ${line}; exit status ${rc}"
    return "${rc}"
}
trap ' _nftban_autorebuild_on_err $? ${LINENO} ${FUNCNAME[0]:-main} ' ERR

# =============================================================================
# MODULE CONSTANTS (set sensible defaults if core doesn't provide them)
# =============================================================================
MODULE_NAME="nftban_autorebuild_module"
MODULE_VERSION="0.9.3"

NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-${NFTBAN_BASE_DIR}/config}"
NFTBAN_CACHE_DIR="${NFTBAN_CACHE_DIR:-${NFTBAN_BASE_DIR}/cache}"
NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"

NFTBAN_AUTOREBUILD_STATE_DIR="${NFTBAN_AUTOREBUILD_STATE_DIR:-${NFTBAN_CACHE_DIR}/autorebuild}"
NFTBAN_AUTOREBUILD_LOG="${NFTBAN_AUTOREBUILD_LOG:-${NFTBAN_LOG_DIR}/autorebuild.log}"
NFTBAN_AUTOREBUILD_CRON_SCRIPT="${NFTBAN_AUTOREBUILD_CRON_SCRIPT:-${NFTBAN_BASE_DIR}/scripts/autorebuild-cron.sh}"
NFTBAN_AUTOREBUILD_LOCK_FILE="${NFTBAN_AUTOREBUILD_LOCK_FILE:-${NFTBAN_AUTOREBUILD_STATE_DIR}/.rebuild.lock}"

# Files to watch for changes (override by consumer if needed)
NFTBAN_WATCHED_FILES=(
    "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
    "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
    "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
    "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
    "${NFTBAN_CONFIG_DIR}/blacklist-user.conf"
    "${NFTBAN_CONFIG_DIR}/ports/ipv4-input.conf"
    "${NFTBAN_CONFIG_DIR}/ports/ipv4-output.conf"
    "${NFTBAN_CONFIG_DIR}/ports/ipv6-input.conf"
    "${NFTBAN_CONFIG_DIR}/ports/ipv6-output.conf"
)

# =============================================================================
# PORTABLE: stat mtime helper (works on Linux and macOS)
# =============================================================================
nftban_autorebuild_get_mtime() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf '0'
        return 0
    fi

    # Linux stat
    if stat --version >/dev/null 2>&1; then
        stat -c %Y -- "$file" 2>/dev/null || printf '0'
        return
    fi

    # BSD / macOS stat fallback
    if stat -f %m "$file" >/dev/null 2>&1; then
        stat -f %m -- "$file" 2>/dev/null || printf '0'
        return
    fi

    # As a last resort, use perl/python to get epoch mtime (if available)
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$file" 2>/dev/null || printf '0'
        return
    fi

    # Unable to determine mtime
    printf '0'
}

# =============================================================================
# INIT / STATE
# =============================================================================
nftban_autorebuild_init() {
    mkdir -p -- "${NFTBAN_AUTOREBUILD_STATE_DIR}" 2>/dev/null || true
    mkdir -p -- "$(dirname -- "${NFTBAN_AUTOREBUILD_LOG}")" 2>/dev/null || true
    nftban_autorebuild_log_debug "Auto-rebuild module initialized (state: ${NFTBAN_AUTOREBUILD_STATE_DIR})"
}

nftban_autorebuild_save_state() {
    local state_file="${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state"
    local temp_file
    temp_file="$(mktemp "${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state.XXXXXX")" || { nftban_autorebuild_log_error "mktemp failed"; return 1; }
    : > "$temp_file"

    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        local mtime
        mtime=$(nftban_autorebuild_get_mtime "$file")
        printf '%s|%s\n' "$file" "$mtime" >>"$temp_file"
    done

    mv -- "$temp_file" "$state_file"
}

nftban_autorebuild_check_changes() {
    local state_file="${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state"

    # If no state file, treat as changed
    if [[ ! -f "$state_file" ]]; then
        return 0
    fi

    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        local current_mtime saved_mtime
        current_mtime=$(nftban_autorebuild_get_mtime "$file")
        saved_mtime=$(grep -F -- "${file}|" "$state_file" 2>/dev/null | cut -d'|' -f2 || printf '')

        if [[ "$current_mtime" != "$saved_mtime" ]]; then
            nftban_autorebuild_log_debug "File changed: ${file} (old=${saved_mtime:-none}, new=${current_mtime})"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# REBUILD (uses consumer-provided nftban_search_build_index function)
# =============================================================================
nftban_autorebuild_run() {
    local force="${1:-false}"

    # Ensure state dir exists
    mkdir -p -- "${NFTBAN_AUTOREBUILD_STATE_DIR}" 2>/dev/null || true

    # Open lock file descriptor
    exec {lock_fd}>"${NFTBAN_AUTOREBUILD_LOCK_FILE}" 2>/dev/null || {
        nftban_autorebuild_log_error "Cannot open lock file: ${NFTBAN_AUTOREBUILD_LOCK_FILE}"
        return 1
    }

    # Acquire lock (non-blocking, wait up to 300s)
    if ! flock -n "$lock_fd" 2>/dev/null; then
        # If we couldn't get it immediately, wait (block) but with timeout
        # fallback to a simple retry loop with timeout to avoid needing flock -w portability
        local waited=0
        local wait_max=300
        while ! flock -n "$lock_fd" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
            if (( waited >= wait_max )); then
                nftban_autorebuild_log_info "Another rebuild is running (lock held) — skipping after ${waited}s"
                exec {lock_fd}>&- || true
                return 0
            fi
        done
    fi

    nftban_autorebuild_log_info "Auto-rebuild check started (PID: $$, lock acquired)"

    # Check enabled flag from core; default to "true"
    local enabled
    if declare -f nftban_get_config >/dev/null 2>&1; then
        enabled=$(nftban_get_config "NFTBAN_AUTOREBUILD_ENABLED" "true")
    else
        enabled="true"
    fi

    if [[ "$enabled" != "true" && "$force" != "true" ]]; then
        nftban_autorebuild_log_info "Auto-rebuild disabled, skipping"
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&- || true
        return 0
    fi

    if [[ "$force" != "true" ]]; then
        if ! nftban_autorebuild_check_changes; then
            nftban_autorebuild_log_info "No changes detected, skipping rebuild"
            flock -u "$lock_fd" 2>/dev/null || true
            exec {lock_fd}>&- || true
            return 0
        fi
    fi

    nftban_autorebuild_log_info "Changes detected — rebuilding consolidated search file..."

    local rebuild_result=1
    if declare -f nftban_search_build_index >/dev/null 2>&1; then
        if nftban_search_build_index; then
            nftban_autorebuild_log_success "Rebuild completed successfully"
            nftban_autorebuild_save_state || nftban_autorebuild_log_warn "Failed to save state"
            rebuild_result=0
        else
            nftban_autorebuild_log_error "Rebuild failed"
            rebuild_result=1
        fi
    else
        nftban_autorebuild_log_error "Search build function (nftban_search_build_index) not available"
        rebuild_result=1
    fi

    # Release lock and close fd
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&- || true

    return $rebuild_result
}

# =============================================================================
# CRON SCRIPT MANAGEMENT
# =============================================================================
nftban_autorebuild_create_cron_script() {
    mkdir -p -- "$(dirname -- "$NFTBAN_AUTOREBUILD_CRON_SCRIPT")" 2>/dev/null || true

    cat > "$NFTBAN_AUTOREBUILD_CRON_SCRIPT" <<'CRONSCRIPT'
#!/usr/bin/env bash
# nftban Auto-Rebuild Cron Script (auto-generated)

set -euo pipefail

NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
LIB_DIR="${NFTBAN_BASE_DIR}/lib"

if [[ -f "${LIB_DIR}/nftban_core.sh" ]]; then
    source "${LIB_DIR}/nftban_core.sh"
    if declare -f nftban_autorebuild_run &>/dev/null; then
        nftban_autorebuild_run
    else
        printf 'ERROR: Auto-rebuild function not available\n' >&2
        exit 1
    fi
else
    printf 'ERROR: Core module not found at %s\n' "${LIB_DIR}/nftban_core.sh" >&2
    exit 1
fi
CRONSCRIPT

    chmod 0755 -- "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"
    nftban_autorebuild_log_success "Created cron script: ${NFTBAN_AUTOREBUILD_CRON_SCRIPT}"
}

nftban_autorebuild_install_cron() {
    nftban_autorebuild_log_info "Installing auto-rebuild cron job..."
    nftban_autorebuild_create_cron_script

    local interval
    if declare -f nftban_get_config >/dev/null 2>&1; then
        interval=$(nftban_get_config "NFTBAN_AUTOREBUILD_INTERVAL" "5")
    else
        interval="5"
    fi

    if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        nftban_autorebuild_log_warn "Invalid interval value: ${interval}; using 5"
        interval=5
    fi

    local cron_entry="*/${interval} * * * * ${NFTBAN_AUTOREBUILD_CRON_SCRIPT} >/dev/null 2>&1"

    # Safely update crontab for the current user
    (crontab -l 2>/dev/null | grep -vF -- "${NFTBAN_AUTOREBUILD_CRON_SCRIPT}" || true; printf '%s\n' "${cron_entry}") | crontab -
    nftban_autorebuild_log_success "Cron job installed: runs every ${interval} minutes"
}

nftban_autorebuild_uninstall_cron() {
    nftban_autorebuild_log_info "Uninstalling auto-rebuild cron job..."
    crontab -l 2>/dev/null | grep -vF -- "${NFTBAN_AUTOREBUILD_CRON_SCRIPT}" | crontab - || true
    rm -f -- "${NFTBAN_AUTOREBUILD_CRON_SCRIPT}" || true
    nftban_autorebuild_log_success "Cron job uninstalled"
}

# =============================================================================
# STATUS / MANAGEMENT / CLI-FRIENDLY FUNCTIONS
# =============================================================================
nftban_autorebuild_status() {
    printf '\n'
    printf '=======================================================\n'
    printf '  Auto-Rebuild Status\n'
    printf '=======================================================\n\n'

    local enabled interval
    if declare -f nftban_get_config &>/dev/null; then
        enabled=$(nftban_get_config "NFTBAN_AUTOREBUILD_ENABLED" "true")
        interval=$(nftban_get_config "NFTBAN_AUTOREBUILD_INTERVAL" "5")
    else
        enabled="true"
        interval="5"
    fi

    printf 'Configuration:\n'
    printf '  Enabled: %s\n' "$enabled"
    printf '  Interval: %s minutes\n\n' "$interval"

    printf 'Installation:\n'
    if crontab -l 2>/dev/null | grep -qF -- "${NFTBAN_AUTOREBUILD_CRON_SCRIPT}"; then
        printf '  Cron: INSTALLED\n'
    else
        printf '  Cron: Not installed\n'
    fi
    printf '\nWatched Files:\n'
    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            local mtime
            mtime=$(date -r -- "$file" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')
            printf '  * %s (modified: %s)\n' "$(basename -- "$file")" "$mtime"
        else
            printf '  - %s (missing)\n' "$(basename -- "$file")"
        fi
    done

    printf '\n'
    if [[ -f "${NFTBAN_AUTOREBUILD_LOG}" ]]; then
        printf 'Recent Activity (last 10):\n'
        tail -n 10 -- "${NFTBAN_AUTOREBUILD_LOG}" | sed 's/^/  /'
        printf '\n'
    fi

    if [[ -f "${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state" ]]; then
        local state_mtime
        state_mtime=$(date -r -- "${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "unknown")
        printf 'Last Check: %s\n' "$state_mtime"
        if nftban_autorebuild_check_changes; then
            printf 'Status: REBUILD NEEDED\n'
        else
            printf 'Status: UP TO DATE\n'
        fi
    else
        printf 'Status: NEVER RUN\n'
    fi

    printf '\n=======================================================\n'
}

nftban_autorebuild_enable()  { nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "true";  nftban_autorebuild_log_success "Auto-rebuild enabled"; }
nftban_autorebuild_disable() { nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "false"; nftban_autorebuild_log_success "Auto-rebuild disabled"; }

nftban_autorebuild_set_interval() {
    local interval="$1"
    if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 )); then
        nftban_autorebuild_log_error "Invalid interval: $interval (must be integer >=1)"
        return 1
    fi
    nftban_set_config "NFTBAN_AUTOREBUILD_INTERVAL" "$interval"
    nftban_autorebuild_log_success "Auto-rebuild interval set to: $interval minutes"
    # Reinstall cron if active
    if crontab -l 2>/dev/null | grep -qF -- "${NFTBAN_AUTOREBUILD_CRON_SCRIPT}"; then
        nftban_autorebuild_install_cron
    fi
}

nftban_autorebuild_trigger() { nftban_autorebuild_log_info "Manual trigger"; nftban_autorebuild_run "true"; }

nftban_autorebuild_setup() {
    nftban_autorebuild_log_info "Setting up auto-rebuild system..."
    nftban_autorebuild_init
    nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "true" || true
    nftban_set_config "NFTBAN_AUTOREBUILD_INTERVAL" "5" || true
    nftban_autorebuild_install_cron
    nftban_autorebuild_run "true"
    nftban_autorebuild_log_success "Auto-rebuild setup complete"
}

nftban_autorebuild_uninstall() {
    nftban_autorebuild_log_info "Uninstalling auto-rebuild system..."
    nftban_autorebuild_uninstall_cron
    rm -rf -- "${NFTBAN_AUTOREBUILD_STATE_DIR}" || true
    nftban_autorebuild_log_success "Auto-rebuild uninstalled"
}

# Export functions (allow consumer to call)
export -f nftban_autorebuild_init
export -f nftban_autorebuild_check_changes
export -f nftban_autorebuild_run
export -f nftban_autorebuild_install_cron
export -f nftban_autorebuild_uninstall_cron
export -f nftban_autorebuild_status
export -f nftban_autorebuild_enable
export -f nftban_autorebuild_disable
export -f nftban_autorebuild_set_interval
export -f nftban_autorebuild_trigger
export -f nftban_autorebuild_setup
export -f nftban_autorebuild_uninstall

# Auto-initialize on source
nftban_autorebuild_init
nftban_autorebuild_log_debug "NFTBan Auto-Rebuild Module loaded (v${MODULE_VERSION})"

# =============================================================================
# FOOTER / LICENSE (short)
# =============================================================================
# NFTBAN Custom License v3.0
# SPDX-License-Identifier: NFTBAN-Custom-License
# © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.
# Use internally (including commercial use) is permitted. Redistribution/public
# sharing of source or binaries is prohibited.
# Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md
# =============================================================================
