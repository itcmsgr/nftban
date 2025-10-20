#!/usr/bin/env bash

# =============================================================================
# NFTBan Auto-Rebuild Module
# Version: 0.9.0
# Location: lib/nftban_autorebuild_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Automatic rebuild of consolidated search file when source files change
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_AUTOREBUILD_LOADED:-}" ]] && return 0
readonly NFTBAN_AUTOREBUILD_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_AUTOREBUILD_STATE_DIR="${NFTBAN_CACHE_DIR}/autorebuild"
readonly NFTBAN_AUTOREBUILD_LOG="${NFTBAN_LOG_DIR}/autorebuild.log"
readonly NFTBAN_AUTOREBUILD_CRON_SCRIPT="${NFTBAN_BASE_DIR}/scripts/autorebuild-cron.sh"
readonly NFTBAN_AUTOREBUILD_LOCK_FILE="${NFTBAN_AUTOREBUILD_STATE_DIR}/.rebuild.lock"

# Files to watch for changes
readonly NFTBAN_WATCHED_FILES=(
    "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
    "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
    "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
    "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
    "${NFTBAN_CONFIG_DIR}/blacklist-user.conf"
)

# =============================================================================
# AUTO-REBUILD LOGGING
# =============================================================================

nftban_autorebuild_log() {
    local message="$*"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_AUTOREBUILD_LOG")"
    echo "[${timestamp}] ${message}" | tee -a "$NFTBAN_AUTOREBUILD_LOG"
}

# =============================================================================
# FILE CHANGE DETECTION
# =============================================================================

nftban_autorebuild_init() {
    mkdir -p "$NFTBAN_AUTOREBUILD_STATE_DIR"
    nftban_log_debug "Auto-rebuild module initialized"
}

# Get modification time of file
nftban_autorebuild_get_mtime() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo "0"
        return 0
    fi
    
    stat -c %Y "$file" 2>/dev/null || echo "0"
}

# Save current state of watched files
nftban_autorebuild_save_state() {
    local state_file="${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state"
    local temp_file="${state_file}.tmp"
    
    > "$temp_file"
    
    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        local mtime
        mtime=$(nftban_autorebuild_get_mtime "$file")
        echo "${file}|${mtime}" >> "$temp_file"
    done
    
    mv "$temp_file" "$state_file"
}

# Check if any watched files have changed
nftban_autorebuild_check_changes() {
    local state_file="${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state"
    
    # If no state file, files have "changed"
    if [[ ! -f "$state_file" ]]; then
        return 0
    fi
    
    # Check each watched file
    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        local current_mtime
        current_mtime=$(nftban_autorebuild_get_mtime "$file")
        
        local saved_mtime
        saved_mtime=$(grep "^${file}|" "$state_file" 2>/dev/null | cut -d'|' -f2)
        
        if [[ "$current_mtime" != "$saved_mtime" ]]; then
            nftban_log_debug "File changed: $file"
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# AUTO-REBUILD EXECUTION
# =============================================================================

# Run rebuild if needed
# SECURITY: Uses flock to prevent race conditions from concurrent executions
nftban_autorebuild_run() {
    local force="${1:-false}"

    # SECURITY: Acquire exclusive lock to prevent race conditions
    # Multiple cron jobs or manual triggers could run simultaneously
    # Use flock with non-blocking mode (-n) and timeout (-w 300 = 5 minutes max)
    local lock_fd

    # Open lock file for exclusive access
    exec {lock_fd}>"$NFTBAN_AUTOREBUILD_LOCK_FILE" 2>/dev/null || {
        nftban_autorebuild_log "ERROR: Cannot create lock file"
        return 1
    }

    # Try to acquire lock (non-blocking with timeout)
    if ! flock -n -w 300 "$lock_fd" 2>/dev/null; then
        nftban_autorebuild_log "Another rebuild is already running (lock held), skipping"
        exec {lock_fd}>&-  # Close lock fd
        return 0
    fi

    # CRITICAL SECTION BEGINS (lock acquired)
    nftban_autorebuild_log "Auto-rebuild check started (PID: $$, lock acquired)"

    # Check if auto-rebuild is enabled
    local enabled
    enabled=$(nftban_get_config "NFTBAN_AUTOREBUILD_ENABLED" "true")

    if [[ "$enabled" != "true" && "$force" != "true" ]]; then
        nftban_autorebuild_log "Auto-rebuild disabled, skipping"
        flock -u "$lock_fd"  # Release lock
        exec {lock_fd}>&-    # Close lock fd
        return 0
    fi

    # Check for changes (unless forced)
    if [[ "$force" != "true" ]]; then
        if ! nftban_autorebuild_check_changes; then
            nftban_autorebuild_log "No changes detected, skipping rebuild"
            flock -u "$lock_fd"  # Release lock
            exec {lock_fd}>&-    # Close lock fd
            return 0
        fi
    fi

    nftban_autorebuild_log "Changes detected, rebuilding consolidated search file..."

    # Rebuild consolidated search file
    local rebuild_result=0
    if declare -f nftban_search_build_index &>/dev/null; then
        if nftban_search_build_index; then
            nftban_autorebuild_log "Rebuild completed successfully"

            # Save new state (atomic operation)
            nftban_autorebuild_save_state

            rebuild_result=0
        else
            nftban_autorebuild_log "ERROR: Rebuild failed"
            rebuild_result=1
        fi
    else
        nftban_autorebuild_log "ERROR: Search module not loaded"
        rebuild_result=1
    fi

    # CRITICAL SECTION ENDS
    # Release lock explicitly before exit
    flock -u "$lock_fd"
    exec {lock_fd}>&-

    return $rebuild_result
}

# =============================================================================
# CRON INSTALLATION
# =============================================================================

# Create cron script
nftban_autorebuild_create_cron_script() {
    mkdir -p "$(dirname "$NFTBAN_AUTOREBUILD_CRON_SCRIPT")"
    
    cat > "$NFTBAN_AUTOREBUILD_CRON_SCRIPT" << 'CRONSCRIPT'
#!/usr/bin/env bash
# nftban Auto-Rebuild Cron Script
# Auto-generated - DO NOT EDIT MANUALLY

set -euo pipefail

# Load nftban environment
NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
LIB_DIR="${NFTBAN_BASE_DIR}/lib"

# Source core module
if [[ -f "${LIB_DIR}/nftban_core.sh" ]]; then
    source "${LIB_DIR}/nftban_core.sh"

    # Run auto-rebuild
    if declare -f nftban_autorebuild_run &>/dev/null; then
        nftban_autorebuild_run
    else
        echo "ERROR: Auto-rebuild function not available" >&2
        exit 1
    fi
else
    echo "ERROR: Core module not found at ${LIB_DIR}/nftban_core.sh" >&2
    exit 1
fi
CRONSCRIPT
    
    chmod +x "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"
    nftban_log_success "Created cron script: $NFTBAN_AUTOREBUILD_CRON_SCRIPT"
}

# Install cron job
nftban_autorebuild_install_cron() {
    nftban_log_info "Installing auto-rebuild cron job..."
    
    # Create script
    nftban_autorebuild_create_cron_script
    
    # Get cron interval from config (default: 5 minutes)
    local interval
    interval=$(nftban_get_config "NFTBAN_AUTOREBUILD_INTERVAL" "5")
    
    local cron_entry="*/${interval} * * * * $NFTBAN_AUTOREBUILD_CRON_SCRIPT >/dev/null 2>&1"
    
    # Check if already exists
    if crontab -l 2>/dev/null | grep -qF "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"; then
        nftban_log_info "Cron job already installed, updating..."
        # Remove old entry
        crontab -l 2>/dev/null | grep -vF "$NFTBAN_AUTOREBUILD_CRON_SCRIPT" | crontab - || true
    fi
    
    # Add new entry
    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
    
    nftban_log_success "Cron job installed: runs every $interval minutes"
    
    echo ""
    echo "Auto-rebuild cron job installed:"
    echo "  Interval: Every $interval minutes"
    echo "  Script: $NFTBAN_AUTOREBUILD_CRON_SCRIPT"
    echo "  View: crontab -l | grep nftban"
}

# Uninstall cron job
nftban_autorebuild_uninstall_cron() {
    nftban_log_info "Uninstalling auto-rebuild cron job..."
    
    # Remove from crontab
    crontab -l 2>/dev/null | grep -vF "$NFTBAN_AUTOREBUILD_CRON_SCRIPT" | crontab - || true
    
    # Remove script
    rm -f "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"
    
    nftban_log_success "Cron job uninstalled"
}

# =============================================================================
# STATUS AND MANAGEMENT
# =============================================================================

# Show auto-rebuild status
nftban_autorebuild_status() {
    echo ""
    echo "======================================================="
    echo "  Auto-Rebuild Status"
    echo "======================================================="
    echo ""
    
    # Configuration
    local enabled interval
    enabled=$(nftban_get_config "NFTBAN_AUTOREBUILD_ENABLED" "true")
    interval=$(nftban_get_config "NFTBAN_AUTOREBUILD_INTERVAL" "5")
    
    echo "Configuration:"
    echo "  Enabled: $enabled"
    echo "  Interval: $interval minutes"
    echo ""
    
    # Check cron installation
    echo "Installation:"
    if crontab -l 2>/dev/null | grep -qF "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"; then
        echo "  Cron: INSTALLED"
    else
        echo "  Cron: Not installed"
    fi
    echo ""
    
    # Watched files
    echo "Watched Files:"
    for file in "${NFTBAN_WATCHED_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            local mtime
            mtime=$(date -r "$file" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
            echo "  * $(basename "$file") (modified: $mtime)"
        else
            echo "  - $(basename "$file") (missing)"
        fi
    done
    echo ""
    
    # Recent activity
    if [[ -f "$NFTBAN_AUTOREBUILD_LOG" ]]; then
        echo "Recent Activity (last 10):"
        tail -10 "$NFTBAN_AUTOREBUILD_LOG" | sed 's/^/  /'
        echo ""
    fi
    
    # State file info
    if [[ -f "${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state" ]]; then
        local state_mtime
        state_mtime=$(date -r "${NFTBAN_AUTOREBUILD_STATE_DIR}/last_check.state" +'%Y-%m-%d %H:%M:%S' 2>/dev/null)
        echo "Last Check: $state_mtime"
        
        # Check if rebuild needed
        if nftban_autorebuild_check_changes; then
            echo "Status: REBUILD NEEDED"
        else
            echo "Status: UP TO DATE"
        fi
    else
        echo "Status: NEVER RUN"
    fi
    
    echo ""
    echo "======================================================="
}

# Enable auto-rebuild
nftban_autorebuild_enable() {
    nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "true"
    nftban_log_success "Auto-rebuild enabled"
}

# Disable auto-rebuild
nftban_autorebuild_disable() {
    nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "false"
    nftban_log_success "Auto-rebuild disabled"
}

# Set rebuild interval
nftban_autorebuild_set_interval() {
    local interval="$1"
    
    if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ $interval -lt 1 ]]; then
        nftban_log_error "Invalid interval: $interval (must be >= 1 minute)"
        return 1
    fi
    
    nftban_set_config "NFTBAN_AUTOREBUILD_INTERVAL" "$interval"
    nftban_log_success "Auto-rebuild interval set to: $interval minutes"
    
    # Reinstall cron if active
    if crontab -l 2>/dev/null | grep -qF "$NFTBAN_AUTOREBUILD_CRON_SCRIPT"; then
        nftban_log_info "Updating cron job..."
        nftban_autorebuild_install_cron
    fi
}

# Manual trigger
nftban_autorebuild_trigger() {
    nftban_log_info "Manually triggering auto-rebuild..."
    nftban_autorebuild_run "true"
}

# =============================================================================
# SETUP AND INSTALLATION
# =============================================================================

# Complete setup
nftban_autorebuild_setup() {
    nftban_log_info "Setting up auto-rebuild system..."
    
    # Initialize
    nftban_autorebuild_init
    
    # Enable by default
    nftban_set_config "NFTBAN_AUTOREBUILD_ENABLED" "true"
    nftban_set_config "NFTBAN_AUTOREBUILD_INTERVAL" "5"
    
    # Install cron
    nftban_autorebuild_install_cron
    
    # Initial run
    nftban_autorebuild_run "true"
    
    nftban_log_success "Auto-rebuild setup complete"
    
    echo ""
    echo "Auto-Rebuild Configuration:"
    echo "  Status: ENABLED"
    echo "  Interval: Every 5 minutes"
    echo "  Method: Cron"
    echo ""
    echo "Commands:"
    echo "  Check status: nftban autorebuild status"
    echo "  Trigger now: nftban autorebuild trigger"
    echo "  Disable: nftban autorebuild disable"
}

# Complete uninstall
nftban_autorebuild_uninstall() {
    nftban_log_info "Uninstalling auto-rebuild system..."
    
    # Remove cron
    nftban_autorebuild_uninstall_cron
    
    # Clean state
    rm -rf "$NFTBAN_AUTOREBUILD_STATE_DIR"
    
    nftban_log_success "Auto-rebuild uninstalled"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
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

# Auto-initialize
nftban_autorebuild_init

nftban_log_debug "NFTBan Auto-Rebuild Module loaded"
