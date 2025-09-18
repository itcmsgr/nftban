#!/bin/bash

################################################################################
# Script: nftban-maintenance.sh
#
# Version: 1.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Description:
# Comprehensive maintenance script for NFTBAN system
# - Configuration validation and repair
# - Log rotation and cleanup
# - Persistent offender management
# - System health checks
# - Backup and restore functionality
################################################################################

BASE_DIR="/etc/nftban"
LOG_DIR="/var/log/nftban"
CONFIG_FILE="$BASE_DIR/config/nftban.conf"
CONFIG_FILE_USER="$BASE_DIR/config/nftban.conf.local"
WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
BLACKLIST_FILE="$BASE_DIR/config/nftban-configuration-user-blacklist_ips.conf.local"
BANS_LOG="$LOG_DIR/nftban-bans.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "ERROR") color="$RED" ;;
        "WARN") color="$YELLOW" ;;
        "INFO") color="$GREEN" ;;
        "DEBUG") color="$BLUE" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level]${NC} $message"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/maintenance.log"
}

# Configuration validation
validate_config() {
    log_message "INFO" "Validating NFTBAN configuration..."
    local errors=0
    
    # Check if user config exists
    if [[ ! -f "$CONFIG_FILE_USER" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            log_message "WARN" "User config missing, creating from default"
            cp "$CONFIG_FILE" "$CONFIG_FILE_USER"
            chmod 600 "$CONFIG_FILE_USER"
        else
            log_message "ERROR" "No configuration files found"
            errors=$((errors + 1))
        fi
    fi
    
    # Validate configuration syntax
    if [[ -f "$CONFIG_FILE_USER" ]]; then
        if ! source "$CONFIG_FILE_USER" 2>/dev/null; then
            log_message "ERROR" "Invalid syntax in user configuration"
            errors=$((errors + 1))
        else
            log_message "INFO" "User configuration syntax valid"
        fi
    fi
    
    # Check essential files
    local essential_files=(
        "$WHITELIST_FILE"
        "$BLACKLIST_FILE"
        "$BASE_DIR/bin/nftban"
    )
    
    for file in "${essential_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_message "ERROR" "Missing essential file: $file"
            errors=$((errors + 1))
        fi
    done
    
    # Validate NFTables configuration
    if [[ -f "$BASE_DIR/config/nft_rules.conf.local" ]]; then
        if ! nft -c -f "$BASE_DIR/config/nft_rules.conf.local" 2>/dev/null; then
            log_message "ERROR" "Invalid NFTables configuration"
            errors=$((errors + 1))
        else
            log_message "INFO" "NFTables configuration valid"
        fi
    fi
    
    # Validate Fail2ban configuration
    if command -v fail2ban-client &>/dev/null; then
        if ! fail2ban-client --test 2>/dev/null; then
            log_message "ERROR" "Invalid Fail2ban configuration"
            errors=$((errors + 1))
        else
            log_message "INFO" "Fail2ban configuration valid"
        fi
    fi
    
    if [[ $errors -eq 0 ]]; then
        log_message "INFO" "All configuration validation checks passed"
        return 0
    else
        log_message "ERROR" "Configuration validation failed with $errors errors"
        return 1
    fi
}

# Repair configuration
repair_config() {
    log_message "INFO" "Repairing NFTBAN configuration..."
    
    # Recreate missing directories
    local required_dirs=(
        "$BASE_DIR/config"
        "$BASE_DIR/scripts"
        "$BASE_DIR/templates"
        "$BASE_DIR/backups"
        "$LOG_DIR"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_message "INFO" "Recreated directory: $dir"
        fi
    done
    
    # Recreate whitelist if missing
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        cat > "$WHITELIST_FILE" << 'EOF'
# NFTBAN IP Whitelist
127.0.0.1
::1
EOF
        chmod 644 "$WHITELIST_FILE"
        log_message "INFO" "Recreated whitelist file"
    fi
    
    # Recreate blacklist if missing
    if [[ ! -f "$BLACKLIST_FILE" ]]; then
        touch "$BLACKLIST_FILE"
        chmod 644 "$BLACKLIST_FILE"
        log_message "INFO" "Recreated blacklist file"
    fi
    
    # Fix permissions
    find "$BASE_DIR" -type d -exec chmod 755 {} \;
    find "$BASE_DIR/config" -name "*.conf*" -exec chmod 644 {} \;
    find "$BASE_DIR/scripts" -name "*.sh" -exec chmod +x {} \;
    
    log_message "INFO" "Configuration repair completed"
}

# Backup configuration
backup_config() {
    local backup_dir="$BASE_DIR/backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/nftban_config_backup_$timestamp.tar.gz"
    
    mkdir -p "$backup_dir"
    
    log_message "INFO" "Creating configuration backup..."
    
    # Create comprehensive backup
    tar -czf "$backup_file" \
        -C "$BASE_DIR" config/ \
        -C /etc fail2ban/jail.d/nftban-*.conf \
        -C /etc fail2ban/filter.d/nftban-*.conf \
        -C /etc fail2ban/action.d/nftban-*.conf 2>/dev/null
    
    # Include nftables.conf if it exists
    if [[ -f /etc/nftables.conf ]]; then
        tar -rf "$backup_file" -C / etc/nftables.conf 2>/dev/null
    fi
    
    # Compress the final archive
    gzip "$backup_file" 2>/dev/null
    
    log_message "INFO" "Backup created: $backup_file"
    
    # Clean old backups (keep last 10)
    ls -t "$backup_dir"/nftban_config_backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    
    echo "$backup_file"
}

# Analyze persistent offenders
analyze_persistent_offenders() {
    log_message "INFO" "Analyzing persistent offenders..."
    
    if [[ ! -f "$BANS_LOG" ]]; then
        log_message "WARN" "Bans log file not found: $BANS_LOG"
        return 1
    fi
    
    # Load configuration for thresholds
    if [[ -f "$CONFIG_FILE_USER" ]]; then
        source "$CONFIG_FILE_USER"
    fi
    
    local threshold=${NFTBAN_F2B_PERSISTENT_THRESHOLD:-3}
    local timeframe=${NFTBAN_F2B_PERSISTENT_TIMEFRAME:-86400}
    local cutoff_time=$(date -d "-${timeframe} seconds" '+%Y-%m-%d %H:%M:%S')
    
    log_message "INFO" "Analyzing bans since: $cutoff_time (threshold: $threshold)"
    
    # Analyze and count IP occurrences
    awk -v cutoff="$cutoff_time" -v threshold="$threshold" '
    $1 " " $2 >= cutoff && /Banned IP:/ {
        match($0, /Banned IP: ([0-9.]+|[0-9a-fA-F:]+)/, ip)
        if (ip[1]) {
            ips[ip[1]]++
        }
    }
    END {
        for (ip in ips) {
            if (ips[ip] >= threshold) {
                print ips[ip], ip
            }
        }
    }' "$BANS_LOG" | sort -rn > /tmp/persistent_offenders.tmp
    
    local count=$(wc -l < /tmp/persistent_offenders.tmp)
    
    if [[ $count -gt 0 ]]; then
        log_message "WARN" "Found $count persistent offenders:"
        
        while read -r violations ip; do
            log_message "WARN" "IP $ip: $violations violations"
            
            # Add to blacklist if not already there
            if ! grep -q "^$ip" "$BLACKLIST_FILE" 2>/dev/null; then
                echo "$ip # Persistent offender - $violations violations on $(date)" >> "$BLACKLIST_FILE"
                log_message "INFO" "Added $ip to blacklist"
                
                # Add to NFTables persistent ban if enabled
                if [[ "${NFTBAN_F2B_PERSISTENT_JAIL:-false}" == "true" ]]; then
                    add_to_persistent_ban "$ip"
                fi
            fi
        done < /tmp/persistent_offenders.tmp
        
        rm -f /tmp/persistent_offenders.tmp
    else
        log_message "INFO" "No persistent offenders found"
    fi
}

# Add IP to persistent NFTables ban
add_to_persistent_ban() {
    local ip="$1"
    
    # Create persistent blacklist table if it doesn't exist
    nft add table inet NFTBAN_F2B_PERSISTENT 2>/dev/null || true
    nft add set inet NFTBAN_F2B_PERSISTENT persistent_v4 '{ type ipv4_addr; }' 2>/dev/null || true
    nft add set inet NFTBAN_F2B_PERSISTENT persistent_v6 '{ type ipv6_addr; }' 2>/dev/null || true
    nft add chain inet NFTBAN_F2B_PERSISTENT persistent_input '{ type filter hook input priority -10; policy accept; }' 2>/dev/null || true
    nft add rule inet NFTBAN_F2B_PERSISTENT persistent_input ip saddr @persistent_v4 counter drop 2>/dev/null || true
    nft add rule inet NFTBAN_F2B_PERSISTENT persistent_input ip6 saddr @persistent_v6 counter drop 2>/dev/null || true
    
    # Add IP to appropriate set
    if echo "$ip" | grep -q ':'; then
        nft add element inet NFTBAN_F2B_PERSISTENT persistent_v6 "{ $ip }" 2>/dev/null && \
        log_message "INFO" "Added $ip to persistent NFTables IPv6 blacklist"
    else
        nft add element inet NFTBAN_F2B_PERSISTENT persistent_v4 "{ $ip }" 2>/dev/null && \
        log_message "INFO" "Added $ip to persistent NFTables IPv4 blacklist"
    fi
}

# Clean old logs
clean_logs() {
    log_message "INFO" "Cleaning old log files..."
    
    # Clean logs older than 30 days
    find "$LOG_DIR" -name "*.log" -type f -mtime +30 -delete 2>/dev/null
    
    # Truncate large ban logs (keep last 10000 lines)
    if [[ -f "$BANS_LOG" ]] && [[ $(wc -l < "$BANS_LOG") -gt 10000 ]]; then
        tail -10000 "$BANS_LOG" > "${BANS_LOG}.tmp"
        mv "${BANS_LOG}.tmp" "$BANS_LOG"
        log_message "INFO" "Truncated large bans log file"
    fi
    
    # Clean old backups (keep 20 most recent)
    if [[ -d "$BASE_DIR/backups" ]]; then
        find "$BASE_DIR/backups" -name "*.tar.gz" -type f | sort -r | tail -n +21 | xargs rm -f 2>/dev/null
        log_message "INFO" "Cleaned old backup files"
    fi
}

# System health check
health_check() {
    log_message "INFO" "Performing system health check..."
    
    local issues=0
    
    # Check services
    local services=("fail2ban" "nftables")
    for service in "${services[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
            log_message "WARN" "Service $service is not active"
            issues=$((issues + 1))
        else
            log_message "INFO" "Service $service is active"
        fi
    done
    
    # Check NFTables rules
    if ! nft list ruleset >/dev/null 2>&1; then
        log_message "ERROR" "NFTables ruleset cannot be read"
        issues=$((issues + 1))
    else
        local nftban_tables=$(nft list tables 2>/dev/null | grep -c -E "(nftban|NFTBAN)")
        log_message "INFO" "Found $nftban_tables NFTBAN NFTables tables"
    fi
    
    # Check fail2ban jails
    if command -v fail2ban-client &>/dev/null; then
        local active_jails=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $4}')
        log_message "INFO" "Fail2ban has $active_jails active jails"
        
        # List NFTBAN jails specifically
        local nftban_jails=$(fail2ban-client status 2>/dev/null | grep -o "nftban-[^,]*" | wc -l)
        log_message "INFO" "Found $nftban_jails active NFTBAN jails"
    fi
    
    # Check disk space
    local disk_usage=$(df "$BASE_DIR" | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        log_message "WARN" "High disk usage: ${disk_usage}%"
        issues=$((issues + 1))
    fi
    
    # Check log file sizes
    if [[ -f "$BANS_LOG" ]]; then
        local bans_log_size=$(stat -f%z "$BANS_LOG" 2>/dev/null || stat -c%s "$BANS_LOG" 2>/dev/null || echo 0)
        if [[ $bans_log_size -gt 104857600 ]]; then  # 100MB
            log_message "WARN" "Bans log file is large: $(($bans_log_size / 1048576))MB"
            issues=$((issues + 1))
        fi
    fi
    
    if [[ $issues -eq 0 ]]; then
        log_message "INFO" "System health check passed"
        return 0
    else
        log_message "WARN" "System health check found $issues issues"
        return 1
    fi
}

# Show statistics
show_stats() {
    echo -e "${BLUE}=== NFTBAN STATISTICS ===${NC}"
    
    # Configuration stats
    if [[ -f "$CONFIG_FILE_USER" ]]; then
        source "$CONFIG_FILE_USER" 2>/dev/null
        local enabled_jails=$(grep -c "=.*true" "$CONFIG_FILE_USER" 2>/dev/null || echo 0)
        echo "Enabled jails: $enabled_jails"
    fi
    
    # Whitelist/Blacklist stats
    local whitelist_count=$(grep -v "^#" "$WHITELIST_FILE" 2>/dev/null | grep -c "." || echo 0)
    local blacklist_count=$(grep -v "^#" "$BLACKLIST_FILE" 2>/dev/null | grep -c "." || echo 0)
    echo "Whitelisted IPs: $whitelist_count"
    echo "Blacklisted IPs: $blacklist_count"
    
    # Ban statistics from log file
    if [[ -f "$BANS_LOG" ]]; then
        local total_bans=$(grep -c "Banned IP:" "$BANS_LOG" 2>/dev/null || echo 0)
        local today_bans=$(grep "$(date '+%Y-%m-%d')" "$BANS_LOG" 2>/dev/null | grep -c "Banned IP:" || echo 0)
        echo "Total bans recorded: $total_bans"
        echo "Bans today: $today_bans"
        
        # Top banned IPs
        echo -e "\nTop 5 banned IPs:"
        awk '/Banned IP:/ {match($0, /Banned IP: ([0-9.]+|[0-9a-fA-F:]+)/, ip); if(ip[1]) print ip[1]}' "$BANS_LOG" | \
        sort | uniq -c | sort -rn | head -5 | while read count ip; do
            echo "  $ip: $count times"
        done
    fi
    
    # Service status
    echo -e "\nService Status:"
    for service in fail2ban nftables; do
        if systemctl is-active --quiet "$service"; then
            echo -e "  $service: ${GREEN}Active${NC}"
        else
            echo -e "  $service: ${RED}Inactive${NC}"
        fi
    done
    
    # NFTables tables
    local nftban_tables=$(nft list tables 2>/dev/null | grep -E "(nftban|NFTBAN)" | wc -l)
    echo "NFTBAN NFTables tables: $nftban_tables"
}

# Usage information
show_usage() {
    cat << 'EOF'
NFTBAN Maintenance Script

Usage: nftban-maintenance.sh [OPTIONS]

Options:
  validate       Validate all configurations
  repair         Repair missing or broken configurations  
  backup         Create configuration backup
  analyze        Analyze logs for persistent offenders
  cleanup        Clean old logs and temporary files
  health         Perform system health check
  stats          Show system statistics
  full           Run full maintenance (all of the above)
  
Examples:
  nftban-maintenance.sh validate
  nftban-maintenance.sh full
  nftban-maintenance.sh backup
EOF
}

# Full maintenance routine
full_maintenance() {
    log_message "INFO" "Starting full maintenance routine..."
    
    echo -e "${BLUE}=== NFTBAN FULL MAINTENANCE ===${NC}"
    
    # Step 1: Validate configuration
    echo -e "\n${YELLOW}Step 1: Configuration Validation${NC}"
    if validate_config; then
        echo -e "${GREEN}✓ Configuration validation passed${NC}"
    else
        echo -e "${RED}✗ Configuration validation failed${NC}"
        echo "Running repair..."
        repair_config
    fi
    
    # Step 2: Health check
    echo -e "\n${YELLOW}Step 2: System Health Check${NC}"
    if health_check; then
        echo -e "${GREEN}✓ System health check passed${NC}"
    else
        echo -e "${YELLOW}⚠ System health check found issues${NC}"
    fi
    
    # Step 3: Backup
    echo -e "\n${YELLOW}Step 3: Configuration Backup${NC}"
    local backup_file=$(backup_config)
    echo -e "${GREEN}✓ Backup created: $(basename "$backup_file")${NC}"
    
    # Step 4: Analyze persistent offenders
    echo -e "\n${YELLOW}Step 4: Persistent Offender Analysis${NC}"
    analyze_persistent_offenders
    echo -e "${GREEN}✓ Persistent offender analysis completed${NC}"
    
    # Step 5: Cleanup
    echo -e "\n${YELLOW}Step 5: Log and File Cleanup${NC}"
    clean_logs
    echo -e "${GREEN}✓ Cleanup completed${NC}"
    
    # Step 6: Show statistics
    echo -e "\n${YELLOW}Step 6: System Statistics${NC}"
    show_stats
    
    log_message "INFO" "Full maintenance routine completed"
    echo -e "\n${GREEN}=== MAINTENANCE COMPLETED ===${NC}"
}

# Main function
main() {
    local action="${1:-help}"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
    
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    case "$action" in
        validate)
            validate_config
            ;;
        repair)
            repair_config
            ;;
        backup)
            backup_config
            ;;
        analyze)
            analyze_persistent_offenders
            ;;
        cleanup)
            clean_logs
            ;;
        health)
            health_check
            ;;
        stats)
            show_stats
            ;;
        full)
            full_maintenance
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            echo -e "${RED}Unknown action: $action${NC}"
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
