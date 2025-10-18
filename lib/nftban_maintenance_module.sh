#!/usr/bin/env bash

# =============================================================================
# NFTBan Maintenance Module
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# System maintenance, cleanup, and health checks
# With comprehensive maintenance panel UI
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
# COMPREHENSIVE MAINTENANCE PANEL UI
# =============================================================================

nftban_maintenance_show_panel() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                    NFTBan Maintenance Panel                            ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Version Information
    echo -e "${NFTBAN_CYAN}═══ Version Information ═══${NFTBAN_NC}"
    echo ""

    local local_version="unknown"
    if declare -f nftban_update_get_local_version &>/dev/null; then
        local_version=$(nftban_update_get_local_version 2>/dev/null || echo "unknown")
    elif [[ -f "$NFTBAN_VERSION_FILE" ]]; then
        local_version=$(cat "$NFTBAN_VERSION_FILE" | tr -d '[:space:]')
    fi

    local remote_version="unknown"
    local remote_status="✗ Unable to check"
    local update_available=false

    if declare -f nftban_update_get_remote_version &>/dev/null; then
        if remote_version=$(nftban_update_get_remote_version 2>/dev/null); then
            if declare -f nftban_update_compare_versions &>/dev/null; then
                nftban_update_compare_versions "$local_version" "$remote_version" 2>/dev/null || true
                local version_compare=$?

                case $version_compare in
                    0) remote_status="✓ Up to date" ;;
                    1) remote_status="⚠ Local version newer" ;;
                    2) remote_status="⚠ UPDATE AVAILABLE"; update_available=true ;;
                esac
            fi
        fi
    fi

    echo "  Current Version:    $local_version"
    echo "  Remote Version:     $remote_version"
    echo "  Status:             $remote_status"
    echo ""

    # File Integrity Status
    echo -e "${NFTBAN_CYAN}═══ File Integrity Status ═══${NFTBAN_NC}"
    echo ""

    local total_files=0
    local valid_files=0
    local missing_files=0

    if [[ -d "${NFTBAN_BASE_DIR}/lib" ]]; then
        total_files=$(find "${NFTBAN_BASE_DIR}/lib" -type f -name "*.sh" 2>/dev/null | wc -l)

        local expected_modules=(
            "nftban_core.sh" "nftban_update_module.sh" "nftban_maintenance_module.sh"
            "nftban_nftables_module.sh" "nftban_whitelist_module.sh" "nftban_blacklist_module.sh"
            "nftban_safety_module.sh" "nftban_main_cli.sh"
        )

        for module in "${expected_modules[@]}"; do
            [[ -f "${NFTBAN_BASE_DIR}/lib/${module}" ]] && ((valid_files++)) || ((missing_files++))
        done
    fi

    echo "  Total Files:        $total_files"
    echo "  Core Modules:       $valid_files / ${#expected_modules[@]}"
    [[ $missing_files -gt 0 ]] && echo -e "  Missing Files:      ${NFTBAN_RED}$missing_files ✗${NFTBAN_NC}" || echo -e "  Missing Files:      ${NFTBAN_GREEN}0 ✓${NFTBAN_NC}"
    echo "  Full validation:    Run 'nftban validate status'"
    echo ""

    # System Health
    echo -e "${NFTBAN_CYAN}═══ System Health ═══${NFTBAN_NC}"
    echo ""

    local nft_status="✗ Inactive"
    nftban_check_nftables_table 2>/dev/null && nft_status="✓ Active"
    echo "  nftables:           $nft_status"

    local f2b_status="✗ Not running"
    (systemctl is-active fail2ban &>/dev/null || service fail2ban status &>/dev/null) && f2b_status="✓ Running"
    echo "  Fail2Ban:           $f2b_status"

    local disk_usage
    disk_usage=$(df -h "${NFTBAN_BASE_DIR}" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    local disk_status="✓ OK"
    [[ $disk_usage -gt 90 ]] && disk_status="⚠ Low space (${disk_usage}%)"
    echo "  Disk Space:         $disk_status"

    local log_size="0"
    [[ -d "$NFTBAN_LOG_DIR" ]] && log_size=$(du -sh "$NFTBAN_LOG_DIR" 2>/dev/null | awk '{print $1}')
    echo "  Log Directory Size: $log_size"
    echo ""

    # Backup Information
    echo -e "${NFTBAN_CYAN}═══ Backup Information ═══${NFTBAN_NC}"
    echo ""

    local last_backup="None"
    local backup_count=0

    if [[ -d "$NFTBAN_UPDATE_BACKUP_DIR" ]]; then
        backup_count=$(find "$NFTBAN_UPDATE_BACKUP_DIR" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | wc -l)
        if [[ $backup_count -gt 0 ]]; then
            last_backup=$(find "$NFTBAN_UPDATE_BACKUP_DIR" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -1)
            last_backup=$(basename "$last_backup" | sed 's/pre_update_//' | sed 's/_/ /')
        fi
    fi

    echo "  Total Backups:      $backup_count"
    echo "  Last Backup:        $last_backup"
    echo ""

    # Current Statistics
    echo -e "${NFTBAN_CYAN}═══ Current Statistics ═══${NFTBAN_NC}"
    echo ""

    local temp_bans=0 perm_bans=0 whitelisted=0
    if command -v nft &>/dev/null && nftban_check_nftables_table 2>/dev/null; then
        # v0.9.0: Count from both IPv4 and IPv6 tables
        local temp_v4 temp_v6 perm_v4 perm_v6 white_v4 white_v6
        temp_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" temp_ban 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l || echo "0")
        temp_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" temp_ban 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l || echo "0")
        perm_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" user_blacklist 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l || echo "0")
        perm_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" user_blacklist 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l || echo "0")
        white_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l || echo "0")
        white_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" whitelist 2>/dev/null | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l || echo "0")
        temp_bans=$((temp_v4 + temp_v6))
        perm_bans=$((perm_v4 + perm_v6))
        whitelisted=$((white_v4 + white_v6))
    fi

    echo "  Temporary Bans:     $temp_bans"
    echo "  Permanent Bans:     $perm_bans"
    echo "  Whitelisted IPs:    $whitelisted"
    echo ""

    # Quick Actions
    echo -e "${NFTBAN_CYAN}═══ Quick Actions ═══${NFTBAN_NC}"
    echo ""

    if [[ "$update_available" == "true" ]]; then
        echo -e "  ${NFTBAN_YELLOW}⚠ Update available: $local_version → $remote_version${NFTBAN_NC}"
        echo "    Run: sudo nftban update perform"
        echo ""
    fi

    echo "  Commands:"
    echo "    nftban update check         - Check for updates"
    echo "    nftban validate status      - Full integrity check"
    echo "    nftban maintenance health   - Detailed health check"
    echo "    nftban maintenance backup   - Create backup"
    echo "    nftban status               - System status"
    echo ""

    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

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
    
    # Export nftables rules (v0.9.0: backup both tables)
    if nftban_nftables_check_table; then
        nft list table "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" > "${temp_dir}/nftables-backup-v4.nft" 2>/dev/null || true
        nft list table "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" > "${temp_dir}/nftables-backup-v6.nft" 2>/dev/null || true
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
export -f nftban_maintenance_show_panel
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

nftban_log_debug "NFTBan Maintenance Module loaded (v2.0.0 with panel UI)"