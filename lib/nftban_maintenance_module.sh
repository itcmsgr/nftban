#!/usr/bin/env bash

# =============================================================================
# NFTBan Maintenance Module
# Version: 1.0.0
# System maintenance, cleanup, and health checks
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_MAINTENANCE_LOADED:-}" ]] && return 0
readonly NFTBAN_MAINTENANCE_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_MAINTENANCE_LOG="${NFTBAN_LOG_DIR}/maintenance.log"
readonly NFTBAN_MAINTENANCE_SCRIPT="${NFTBAN_BASE_DIR}/scripts/nftban-maintenance-cron.sh"

# =============================================================================
# MAINTENANCE OPERATIONS
# =============================================================================

# Run all maintenance tasks
nftban_maintenance_run() {
    nftban_log_info "Running maintenance tasks..."
    
    local start_time
    start_time=$(date +%s)
    
    # Clean rate limit tracker
    nftban_maintenance_clean_rate_limit
    
    # Clean old logs
    nftban_maintenance_cleanup_logs 30
    
    # Verify system health
    nftban_maintenance_health_check
    
    # Rebuild search index if needed
    if declare -f nftban_search_needs_rebuild &>/dev/null; then
        if nftban_search_needs_rebuild; then
            nftban_log_info "Rebuilding search index..."
            nftban_search_build_index
        fi
    fi
    
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    nftban_log_success "Maintenance completed in ${duration}s"
    
    # Log to maintenance log
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] Maintenance completed (${duration}s)" >> "$NFTBAN_MAINTENANCE_LOG"
}

# Clean rate limit tracker
nftban_maintenance_clean_rate_limit() {
    if [[ -f "$NFTBAN_RATE_LIMIT_FILE" ]]; then
        local current_time one_hour_ago
        current_time=$(date +%s)
        one_hour_ago=$((current_time - 3600))
        
        awk -v cutoff="$one_hour_ago" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_FILE" > "${NFTBAN_RATE_LIMIT_FILE}.tmp" 2>/dev/null || true
        mv "${NFTBAN_RATE_LIMIT_FILE}.tmp" "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null || true
        
        nftban_log_debug "Cleaned rate limit tracker"
    fi
}

# Clean old logs
nftban_maintenance_cleanup_logs() {
    local days="${1:-30}"
    
    nftban_log_info "Cleaning logs older than $days days..."
    
    local cleaned=0
    
    # Rotate large log files
    for log_file in "$NFTBAN_BAN_LOG" "$NFTBAN_MAIN_LOG" "$NFTBAN_SYNC_LOG"; do
        if [[ -f "$log_file" ]]; then
            local size
            size=$(stat -c %s "$log_file" 2>/dev/null || echo "0")
            
            # If file is larger than 10MB, rotate it
            if [[ $size -gt 10485760 ]]; then
                local timestamp
                timestamp=$(date +%Y%m%d-%H%M%S)
                local backup="${log_file}.${timestamp}"
                
                mv "$log_file" "$backup"
                touch "$log_file"
                
                # Compress old log
                gzip "$backup" 2>/dev/null || true
                
                nftban_log_info "Rotated: $(basename "$log_file")"
                ((cleaned++))
            fi
        fi
    done
    
    # Delete very old compressed logs
    find "$NFTBAN_LOG_DIR" -name "*.log.gz" -type f -mtime +$days -delete 2>/dev/null
    
    # Delete old backups
    if [[ -d "${NFTBAN_DATA_DIR}/backups" ]]; then
        find "${NFTBAN_DATA_DIR}/backups" -type f -mtime +$days -delete 2>/dev/null
    fi
    
    nftban_log_success "Log cleanup completed: $cleaned files rotated"
}

# Health check
nftban_maintenance_health_check() {
    nftban_log_info "Running health check..."
    
    local issues=0
    
    # Check nftables table
    if ! nftban_nftables_check_table; then
        nftban_log_error "Health check: nftables table missing"
        ((issues++))
    fi
    
    # Check required directories
    local required_dirs=(
        "$NFTBAN_BASE_DIR"
        "$NFTBAN_CONFIG_DIR"
        "$NFTBAN_DATA_DIR"
        "$NFTBAN_CACHE_DIR"
        "$NFTBAN_LOG_DIR"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            nftban_log_error "Health check: Missing directory: $dir"
            ((issues++))
        fi
    done
    
    # Check whitelist for localhost
    if ! nftban_whitelist_check_ip "127.0.0.1"; then
        nftban_log_error "Health check: Localhost not whitelisted!"
        ((issues++))
    fi
    
    if [[ $issues -eq 0 ]]; then
        nftban_log_success "Health check passed"
    else
        nftban_log_warning "Health check found $issues issue(s)"
    fi
    
    return $issues
}

# Database optimization
nftban_maintenance_optimize_database() {
    nftban_log_info "Optimizing databases..."
    
    # Compact search index
    if [[ -f "$NFTBAN_SEARCH_DB" ]]; then
        local temp_file="${NFTBAN_SEARCH_DB}.tmp"
        
        # Remove duplicate entries
        sort -u "$NFTBAN_SEARCH_DB" > "$temp_file"
        mv "$temp_file" "$NFTBAN_SEARCH_DB"
        
        nftban_log_debug "Optimized search database"
    fi
    
    # Clean stats database (remove entries older than 90 days)
    if [[ -f "$NFTBAN_STATS_DB" ]]; then
        local cutoff_date
        cutoff_date=$(date -d '90 days ago' +'%Y-%m-%d' 2>/dev/null || \
                      date -v-90d +'%Y-%m-%d' 2>/dev/null)
        
        if [[ -n "$cutoff_date" ]]; then
            awk -F',' -v cutoff="$cutoff_date" '$1 >= cutoff' "$NFTBAN_STATS_DB" > "${NFTBAN_STATS_DB}.tmp" 2>/dev/null || true
            mv "${NFTBAN_STATS_DB}.tmp" "$NFTBAN_STATS_DB" 2>/dev/null || true
            
            nftban_log_debug "Optimized stats database"
        fi
    fi
    
    nftban_log_success "Database optimization completed"
}

# =============================================================================
# CRON JOB MANAGEMENT
# =============================================================================

# Install cron job
nftban_maintenance_install_cron() {
    nftban_log_info "Installing maintenance cron job..."
    
    # Create maintenance script
    mkdir -p "$(dirname "$NFTBAN_MAINTENANCE_SCRIPT")"
    
    cat > "$NFTBAN_MAINTENANCE_SCRIPT" << 'CRONSCRIPT'
#!/usr/bin/env bash
# nftban maintenance cron script (auto-generated)
set -euo pipefail

# Load nftban environment
if [[ -f /usr/local/bin/nftban ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# Source core module
NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
LIB_DIR="${NFTBAN_BASE_DIR}/lib"

if [[ -f "${LIB_DIR}/nftban_core.sh" ]]; then
    source "${LIB_DIR}/nftban_core.sh"

    # Run maintenance
    nftban_maintenance_run
else
    echo "ERROR: Core module not found" >&2
    exit 1
fi
CRONSCRIPT
    
    chmod +x "$NFTBAN_MAINTENANCE_SCRIPT"
    
    # Install cron job (runs every 6 hours)
    local cron_entry="0 */6 * * * $NFTBAN_MAINTENANCE_SCRIPT >/dev/null 2>&1"
    
    # Check if already exists
    if crontab -l 2>/dev/null | grep -qF "$NFTBAN_MAINTENANCE_SCRIPT"; then
        nftban_log_info "Cron job already installed"
    else
        (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
        nftban_log_success "Cron job installed (runs every 6 hours)"
    fi
    
    echo ""
    echo "Maintenance cron job installed:"
    echo "  Script: $NFTBAN_MAINTENANCE_SCRIPT"
    echo "  Schedule: Every 6 hours"
    echo "  View: crontab -l | grep nftban"
}

# Uninstall cron job
nftban_maintenance_uninstall_cron() {
    nftban_log_info "Uninstalling maintenance cron job..."
    
    # Remove from crontab
    crontab -l 2>/dev/null | grep -vF "$NFTBAN_MAINTENANCE_SCRIPT" | crontab - || true
    
    # Remove script
    rm -f "$NFTBAN_MAINTENANCE_SCRIPT"
    
    nftban_log_success "Cron job uninstalled"
}

# Show cron status
nftban_maintenance_cron_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Maintenance Cron Status"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if crontab -l 2>/dev/null | grep -qF "$NFTBAN_MAINTENANCE_SCRIPT"; then
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} Cron job installed"
        echo ""
        echo "Schedule:"
        crontab -l 2>/dev/null | grep "$NFTBAN_MAINTENANCE_SCRIPT" | sed 's/^/  /'
        
        if [[ -f "$NFTBAN_MAINTENANCE_SCRIPT" ]]; then
            echo ""
            echo "Script: $NFTBAN_MAINTENANCE_SCRIPT"
        fi
        
        # Show last maintenance run
        if [[ -f "$NFTBAN_MAINTENANCE_LOG" ]]; then
            echo ""
            echo "Last run:"
            tail -1 "$NFTBAN_MAINTENANCE_LOG" 2>/dev/null | sed 's/^/  /' || echo "  No maintenance log yet"
        fi
    else
        echo -e "${NFTBAN_YELLOW}!${NFTBAN_NC} Cron job not installed"
        echo ""
        echo "Install with: nftban maintenance cron-install"
    fi
    
    echo ""
}

# =============================================================================
# BACKUP AND RESTORE
# =============================================================================

# Create backup
nftban_maintenance_create_backup() {
    local backup_name="${1:-nftban-backup-$(date +%Y%m%d-%H%M%S)}"
    local backup_dir="${NFTBAN_DATA_DIR}/backups"
    local backup_path="${backup_dir}/${backup_name}.tar.gz"
    
    nftban_log_info "Creating backup: $backup_name"
    
    mkdir -p "$backup_dir"
    
    # Create temporary directory for backup
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Copy configuration files
    cp -r "$NFTBAN_CONFIG_DIR" "${temp_dir}/"
    
    # Copy important data files
    if [[ -d "${NFTBAN_DATA_DIR}/geoip" ]]; then
        cp -r "${NFTBAN_DATA_DIR}/geoip" "${temp_dir}/"
    fi
    
    # Export nftables rules
    if nftban_nftables_check_table; then
        nft list table "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" > "${temp_dir}/nftables-backup.nft"
    fi
    
    # Create tarball
    tar -czf "$backup_path" -C "$temp_dir" . 2>/dev/null
    
    # Cleanup
    rm -rf "$temp_dir"
    
    nftban_log_success "Backup created: $backup_path"
    
    echo "$backup_path"
}

# List backups
nftban_maintenance_list_backups() {
    local backup_dir="${NFTBAN_DATA_DIR}/backups"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Available Backups"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if [[ -d "$backup_dir" ]]; then
        local count=0
        
        while IFS= read -r backup; do
            ((count++))
            local size
            size=$(du -h "$backup" | cut -f1)
            local date
            date=$(stat -c %y "$backup" 2>/dev/null | cut -d' ' -f1)
            
            printf "%3d. %-50s %10s  %s\n" "$count" "$(basename "$backup")" "$size" "$date"
        done < <(find "$backup_dir" -name "*.tar.gz" -type f | sort -r)
        
        if [[ $count -eq 0 ]]; then
            echo "No backups found"
        fi
    else
        echo "Backup directory not found"
    fi
    
    echo ""
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

# Control services
nftban_service_control() {
    local action="$1"
    local service="${2:-all}"
    
    case "$service" in
        nftables|nft)
            case "$action" in
                start|stop|restart|reload|enable|disable|status)
                    systemctl "$action" nftables
                    ;;
            esac
            ;;
        fail2ban|f2b)
            case "$action" in
                start|stop|restart|reload|enable|disable|status)
                    systemctl "$action" fail2ban
                    ;;
            esac
            ;;
        all)
            nftban_service_control "$action" nftables
            nftban_service_control "$action" fail2ban
            ;;
        *)
            nftban_log_error "Unknown service: $service"
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_maintenance_run
export -f nftban_maintenance_clean_rate_limit
export -f nftban_maintenance_cleanup_logs
export -f nftban_maintenance_health_check
export -f nftban_maintenance_optimize_database
export -f nftban_maintenance_install_cron
export -f nftban_maintenance_uninstall_cron
export -f nftban_maintenance_cron_status
export -f nftban_maintenance_create_backup
export -f nftban_maintenance_list_backups
export -f nftban_service_control

nftban_log_debug "NFTBan Maintenance Module loaded"