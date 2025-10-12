#!/usr/bin/env bash

# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
# Comprehensive fail2ban integration with nftables (nftban system)
# Version: 0.6.0 (Enhanced with consolidated search, updated paths)
# Author:  ITCMS Team (Antonios Voulvoulis) + Enhancements
#
# Description:
#   Comprehensive automation for Fail2Ban using the nftables backend.
#   Enhanced with consolidated IP search, updated configuration paths,
#   security features, validation, dry-run mode, improved mail testing,
#   backup rotation, and comprehensive status reporting.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - Updated Paths
# =============================================================================
BASE_DIR="/etc/nftban"
CONFIG_DIR="${BASE_DIR}/config"
TEMPLATE_DIR="${BASE_DIR}/templates/fail2ban"
BACKUP_DIR="${BASE_DIR}/backups"
DATA_DIR="${BASE_DIR}/data"
FAIL2BAN_DIR="/etc/fail2ban"

# Updated IP configuration files
IPV4_BLACKLIST_FILE="$CONFIG_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$CONFIG_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$CONFIG_DIR/nftban-configuration-system_whitelist_ips.conf.local"
USER_WHITELIST_FILE="$CONFIG_DIR/nftban-configuration-user-whitelist_ips.conf.local"
USER_BLACKLIST_FILE="$CONFIG_DIR/nftban-configuration-user-blacklist_ips.conf.local"
FAIL2BAN_WHITELIST="$CONFIG_DIR/nftban-fail2ban-ip-whitelist.conf.local"
FAIL2BAN_TEMP_IPS="$CONFIG_DIR/nftban-configuration-f2b-ips_temp-blacklists_conf.local"

# Consolidated search file for performance
FAIL2BAN_SEARCH_IPS="$CONFIG_DIR/nftban-f2b-ips_for-search.local"

# Other configurations
NFTBAN_CONFIG="${CONFIG_DIR}/nftban.conf"
NFTBAN_CONFIG_LOCAL="${CONFIG_DIR}/nftban.conf.local"
NFT_TABLE="nftban_global"
LOG_FILE="/var/log/nftban-manager.log"
BAN_LOG="/var/log/nftban/nftban-fail2ban.log"
STATS_DB="${DATA_DIR}/nftban-stats.db"
RATE_LIMIT_TRACKER="${DATA_DIR}/rate-limit-tracker.tmp"

# Default ban timeout (in seconds)
DEFAULT_BAN_TIME=3600

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

# Ban statistics logging
log_ban_attempt() {
    local ip="$1"
    local jail_name="$2"
    local action="$3"  # BANNED, WHITELISTED, ALREADY_EXISTS, ERROR, PERMANENT_BAN
    local reason="$4"
    local geoip_info="${5:-N/A}"
    local whois_info="${6:-N/A}"
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local log_entry="${timestamp}|${ip}|${jail_name}|${action}|${reason}|${geoip_info}|${whois_info}"
    
    echo "$log_entry" >> "$BAN_LOG"
    
    # Also log to stats database
    log_to_stats_db "$ip" "$jail_name" "$action" "$reason" "$geoip_info" "$whois_info"
}

log_to_stats_db() {
    local ip="$1"
    local jail_name="$2"
    local action="$3"
    local reason="$4"
    local geoip="${5:-N/A}"
    local whois="${6:-N/A}"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Simple CSV-based stats database
    echo "${timestamp},${ip},${jail_name},${action},${reason},${geoip},${whois}" >> "$STATS_DB"
}

# =============================================================================
# CONFIGURATION MANAGEMENT
# =============================================================================
get_config_value() {
    local var_name="$1"
    local default_value="${2:-}"
    
    # Check .local first (highest priority)
    if [ -f "$NFTBAN_CONFIG_LOCAL" ]; then
        local value
        value=$(grep "^${var_name}=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    # Check base .conf file
    if [ -f "$NFTBAN_CONFIG" ]; then
        local value
        value=$(grep "^${var_name}=" "$NFTBAN_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    # Return default if nothing found
    echo "$default_value"
}

set_config_value() {
    local var_name="$1"
    local value="$2"
    local file="${3:-$NFTBAN_CONFIG_LOCAL}"
    
    # Create file if doesn't exist
    if [ ! -f "$file" ]; then
        touch "$file"
    fi
    
    # Check if variable exists
    if grep -q "^${var_name}=" "$file"; then
        # Update existing value
        sed -i "s|^${var_name}=.*|${var_name}=\"${value}\"|" "$file"
    else
        # Add new entry
        echo "${var_name}=\"${value}\"" >> "$file"
    fi
}

get_jail_config() {
    local jail_name="$1"
    local param="$2"  # JAIL, BAN_TIME, MAX_RETRY, FIND_TIME
    local default_value="${3:-}"
    
    local var_name="NFTBAN_F2B_${jail_name}_${param}"
    get_config_value "$var_name" "$default_value"
}

set_jail_config() {
    local jail_name="$1"
    local param="$2"  # JAIL, BAN_TIME, MAX_RETRY, FIND_TIME
    local value="$3"
    
    local var_name="NFTBAN_F2B_${jail_name}_${param}"
    set_config_value "$var_name" "$value" "$NFTBAN_CONFIG_LOCAL"
}

ensure_jail_config_exists() {
    local jail_name="$1"
    
    # Check if jail config exists, if not create with defaults
    local jail_enabled
    jail_enabled=$(get_jail_config "$jail_name" "JAIL" "")
    
    if [ -z "$jail_enabled" ]; then
        log_info "Creating default config for jail: $jail_name"
        
        # Get global defaults
        local def_ban_time
        local def_find_time
        local def_max_retry
        def_ban_time=$(get_config_value "NFTBAN_F2B_DEF_BAN_TIME" "3600")
        def_find_time=$(get_config_value "NFTBAN_F2B_DEF_FIND_TIME" "600")
        def_max_retry=$(get_config_value "NFTBAN_F2B_DEF_MAX_RETRY" "5")
        
        # Add comment section
        echo "" >> "$NFTBAN_CONFIG_LOCAL"
        echo "# ${jail_name} Jail Configuration" >> "$NFTBAN_CONFIG_LOCAL"
        
        set_jail_config "$jail_name" "JAIL" "false"
        set_jail_config "$jail_name" "BAN_TIME" "$def_ban_time"
        set_jail_config "$jail_name" "MAX_RETRY" "$def_max_retry"
        set_jail_config "$jail_name" "FIND_TIME" "$def_find_time"
    fi
}

remove_jail_config() {
    local jail_name="$1"
    
    if [ -f "$NFTBAN_CONFIG_LOCAL" ]; then
        # Remove all lines related to this jail
        sed -i "/^# ${jail_name} Jail Configuration/d" "$NFTBAN_CONFIG_LOCAL"
        sed -i "/^NFTBAN_F2B_${jail_name}_/d" "$NFTBAN_CONFIG_LOCAL"
        log_info "Removed config for jail: $jail_name"
    fi
}

# =============================================================================
# SYSTEM DETECTION
# =============================================================================
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint)
                echo "DEBIAN"
                ;;
            rhel|centos|fedora|rocky|almalinux)
                echo "REDHAT"
                ;;
            *)
                log_error "Unsupported OS: $ID"
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect OS - /etc/os-release not found"
        exit 1
    fi
}

# =============================================================================
# IP VALIDATION AND DETECTION
# =============================================================================
is_ipv4() {
    local ip="$1"
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

is_ipv6() {
    local ip="$1"
    # Simplified IPv6 validation
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || \
       [[ $ip =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
       [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}:$ ]]; then
        return 0
    fi
    return 1
}

detect_ip_version() {
    local ip="$1"
    if is_ipv4 "$ip"; then
        echo "4"
    elif is_ipv6 "$ip"; then
        echo "6"
    else
        echo "invalid"
    fi
}

# =============================================================================
# CONSOLIDATED IP SEARCH FILE MANAGEMENT
# =============================================================================

# Build consolidated search file from all IP configuration files
build_consolidated_search_file() {
    log_info "Building consolidated IP search file..."
    
    local temp_file="${FAIL2BAN_SEARCH_IPS}.tmp"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Create header
    cat > "$temp_file" <<HEADER
# =============================================================================
# nftban Consolidated IP Search File
# Auto-generated on: $timestamp
# DO NOT EDIT MANUALLY - This file is automatically updated
# =============================================================================
# This file combines all IP addresses from:
#   - IPv4 Blacklist
#   - IPv6 Blacklist  
#   - System Whitelist
#   - User Whitelist
#   - User Blacklist
#   - Fail2ban Whitelist
#   - Fail2ban Temporary IPs
# Format: IP_ADDRESS|SOURCE_FILE|TYPE (WHITELIST/BLACKLIST)
# =============================================================================

HEADER
    
    local total_ips=0
    
    # Process each configuration file
    local files=(
        "$IPV4_BLACKLIST_FILE:IPV4_BLACKLIST:BLACKLIST"
        "$IPV6_BLACKLIST_FILE:IPV6_BLACKLIST:BLACKLIST"
        "$SYSTEM_WHITELIST_FILE:SYSTEM_WHITELIST:WHITELIST"
        "$USER_WHITELIST_FILE:USER_WHITELIST:WHITELIST"
        "$USER_BLACKLIST_FILE:USER_BLACKLIST:BLACKLIST"
        "$FAIL2BAN_WHITELIST:FAIL2BAN_WHITELIST:WHITELIST"
        "$FAIL2BAN_TEMP_IPS:FAIL2BAN_TEMP:BLACKLIST"
    )
    
    for file_info in "${files[@]}"; do
        IFS=':' read -r file source type <<< "$file_info"
        
        if [[ ! -f "$file" ]]; then
            log_info "  File not found, skipping: $(basename "$file")"
            continue
        fi
        
        local count=0
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue
            
            # Clean and validate IP
            local ip
            ip=$(echo "$line" | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//')
            [[ -z "$ip" ]] && continue
            
            # Add to consolidated file
            echo "${ip}|${source}|${type}" >> "$temp_file"
            ((count++))
            ((total_ips++))
        done < "$file"
        
        if [[ $count -gt 0 ]]; then
            log_info "  Added $count IPs from $source"
        fi
    done
    
    # Add summary footer
    cat >> "$temp_file" <<FOOTER

# =============================================================================
# Summary: Total $total_ips IP addresses indexed
# Last updated: $timestamp
# =============================================================================
FOOTER
    
    # Atomic move
    mv "$temp_file" "$FAIL2BAN_SEARCH_IPS"
    chmod 0644 "$FAIL2BAN_SEARCH_IPS"
    
    log_success "Consolidated search file created: $total_ips total IPs"
    return 0
}

# Check if consolidated file needs rebuild
check_consolidated_file_freshness() {
    local rebuild_needed=false
    
    # Check if consolidated file exists
    if [[ ! -f "$FAIL2BAN_SEARCH_IPS" ]]; then
        log_info "Consolidated search file missing, rebuild needed"
        return 0  # needs rebuild
    fi
    
    # Get modification time of consolidated file
    local consolidated_mtime
    consolidated_mtime=$(stat -c %Y "$FAIL2BAN_SEARCH_IPS" 2>/dev/null || echo 0)
    
    # Check if any source file is newer
    local source_files=(
        "$IPV4_BLACKLIST_FILE"
        "$IPV6_BLACKLIST_FILE"
        "$SYSTEM_WHITELIST_FILE"
        "$USER_WHITELIST_FILE"
        "$USER_BLACKLIST_FILE"
        "$FAIL2BAN_WHITELIST"
        "$FAIL2BAN_TEMP_IPS"
    )
    
    for file in "${source_files[@]}"; do
        if [[ -f "$file" ]]; then
            local file_mtime
            file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
            if [[ $file_mtime -gt $consolidated_mtime ]]; then
                log_info "Source file newer than consolidated: $(basename "$file")"
                return 0  # needs rebuild
            fi
        fi
    done
    
    return 1  # no rebuild needed
}

# Auto-rebuild consolidated file if needed
ensure_consolidated_file() {
    if check_consolidated_file_freshness; then
        log_info "Rebuilding consolidated search file..."
        build_consolidated_search_file
    fi
}

# Search IP in consolidated file (fast)
search_ip_in_consolidated() {
    local ip="$1"
    
    ensure_consolidated_file
    
    if [[ ! -f "$FAIL2BAN_SEARCH_IPS" ]]; then
        log_warning "Consolidated search file not available"
        return 1
    fi
    
    # Search for IP in consolidated file
    local results
    results=$(grep -E "^${ip}\|" "$FAIL2BAN_SEARCH_IPS" 2>/dev/null || true)
    
    if [[ -n "$results" ]]; then
        echo "$results"
        return 0
    fi
    
    return 1
}

# =============================================================================
# GEOIP AND WHOIS LOOKUP
# =============================================================================
geoip_lookup() {
    local ip="$1"
    local geoip_enabled
    geoip_enabled=$(get_config_value "NFTBAN_F2B_GEOIP_ENABLE" "false")
    
    if [ "$geoip_enabled" != "true" ]; then
        echo "GeoIP_Disabled"
        return 0
    fi
    
    # Try multiple methods
    local result=""
    
    # Method 1: geoiplookup command (if installed)
    if command -v geoiplookup &> /dev/null; then
        result=$(geoiplookup "$ip" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_')
    fi
    
    # Method 2: ip-api.com (free, no key needed)
    if [ -z "$result" ] && command -v curl &> /dev/null; then
        result=$(curl -s "http://ip-api.com/json/${ip}?fields=status,country,regionName,city,isp" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}_{d.get('isp','Unknown').replace(' ','_')}\" if d.get('status')=='success' else 'Unknown')" 2>/dev/null)
    fi
    
    # Method 3: ipinfo.io (fallback)
    if [ -z "$result" ] && command -v curl &> /dev/null; then
        result=$(curl -s "https://ipinfo.io/${ip}/json" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}_{d.get('org','Unknown').replace(' ','_')}\")" 2>/dev/null)
    fi
    
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "GeoIP_Unavailable"
    fi
}

whois_lookup() {
    local ip="$1"
    local whois_enabled
    whois_enabled=$(get_config_value "NFTBAN_F2B_WHOIS_ENABLE" "false")
    
    if [ "$whois_enabled" != "true" ]; then
        echo "WHOIS_Disabled"
        return 0
    fi
    
    if ! command -v whois &> /dev/null; then
        echo "WHOIS_NotInstalled"
        return 0
    fi
    
    # Get organization/netname from whois
    local result
    result=$(whois "$ip" 2>/dev/null | grep -iE "^(OrgName|netname|owner):" | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_' | cut -c1-50)
    
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "WHOIS_Unavailable"
    fi
}

get_ip_info() {
    local ip="$1"
    local geoip_info
    local whois_info
    geoip_info=$(geoip_lookup "$ip")
    whois_info=$(whois_lookup "$ip")
    
    echo "GeoIP: $geoip_info | WHOIS: $whois_info"
}

# =============================================================================
# EMAIL NOTIFICATION
# =============================================================================
send_email_notification() {
    local ip="$1"
    local jail_name="$2"
    local action="$3"
    local reason="$4"
    local geoip_info="${5:-N/A}"
    local whois_info="${6:-N/A}"
    
    local alert_enabled
    alert_enabled=$(get_config_value "NFTBAN_F2B_ALERT_ENABLED" "false")
    
    if [ "$alert_enabled" != "true" ]; then
        return 0
    fi
    
    local recipient
    local sender
    recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
    if [ -z "$recipient" ]; then
        log_warning "Email recipient not configured, skipping notification"
        return 0
    fi
    
    # Check if mail command is available
    if ! command -v mail &> /dev/null && ! command -v sendmail &> /dev/null; then
        log_warning "No mail command found (install mailutils or sendmail)"
        return 0
    fi
    
    local subject="[nftban] IP $action - $ip ($jail_name jail)"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    local body
    body="nftban Fail2ban Alert
    
Timestamp: $timestamp
Jail: $jail_name
IP Address: $ip
Action: $action
Reason: $reason

IP Information:
GeoIP: $geoip_info
WHOIS: $whois_info

Server: $(hostname -f)
---
This is an automated message from nftban
"
    
    # Try to send email
    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" -r "$sender" "$recipient" 2>/dev/null || \
            log_warning "Failed to send email notification"
    elif command -v sendmail &> /dev/null; then
        {
            echo "To: $recipient"
            echo "From: $sender"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null || log_warning "Failed to send email notification"
    fi
    
    log_info "Email notification sent to $recipient"
}

send_rate_limit_alert() {
    local ban_count="$1"
    local time_window="$2"
    local rate_limit="$3"
    
    # Check if email is configured (required even if alerts are disabled)
    local recipient
    local sender
    recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
    if [ -z "$recipient" ]; then
        log_error "RATE LIMIT EXCEEDED but email recipient not configured!"
        log_error "Configure NFTBAN_F2B_RECIPIENT in nftban.conf.local"
        return 1
    fi
    
    # Check if mail command is available
    if ! command -v mail &> /dev/null && ! command -v sendmail &> /dev/null; then
        log_error "RATE LIMIT EXCEEDED but no mail command found!"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local subject="[nftban] CRITICAL: Ban Rate Limit Exceeded on $(hostname -f)"
    
    # Get recent ban details
    local recent_bans=""
    if [ -f "$BAN_LOG" ]; then
        recent_bans=$(tail -20 "$BAN_LOG" | awk -F'|' '{printf "  %s | %s | %s | %s\n", $1, $2, $3, $4}')
    fi
    
    local body
    body="nftban CRITICAL ALERT - Rate Limit Exceeded
    
⚠️  WARNING: Abnormal ban activity detected!

Timestamp: $timestamp
Server: $(hostname -f)
Time Window: Last ${time_window} seconds
Ban Attempts: ${ban_count}
Rate Limit: ${rate_limit} per minute
Status: THRESHOLD EXCEEDED

This could indicate:
- A distributed attack (DDoS)
- Misconfigured whitelist
- Legitimate traffic being blocked
- Port scanning activity
- Brute force attack

Recent Ban Attempts (last 20):
$recent_bans

Action Required:
1. Review ban logs: /var/log/nftban/nftban-fail2ban.log
2. Check for patterns in source IPs
3. Verify whitelist configuration
4. Review jail configurations
5. Check for false positives

Commands to investigate:
  tail -50 /var/log/nftban/nftban-fail2ban.log
  $(basename "$0") --stats
  $(basename "$0") --test-config

---
This is an automated CRITICAL alert from nftban
Alert sent regardless of NFTBAN_F2B_ALERT_ENABLED setting
"
    
    # Send email
    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" -r "$sender" "$recipient" 2>/dev/null || \
            log_error "Failed to send rate limit alert email"
    elif command -v sendmail &> /dev/null; then
        {
            echo "To: $recipient"
            echo "From: $sender"
            echo "Subject: $subject"
            echo "Priority: urgent"
            echo "X-Priority: 1"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null || log_error "Failed to send rate limit alert email"
    fi
    
    log_warning "CRITICAL: Rate limit alert sent to $recipient"
}

test_email() {
    log_info "Testing email configuration..."
    
    local recipient
    local sender
    recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
    if [ -z "$recipient" ]; then
        log_error "NFTBAN_F2B_RECIPIENT not configured in nftban.conf.local"
        return 1
    fi
    
    echo ""
    echo "Email Configuration:"
    echo "  Recipient: $recipient"
    echo "  Sender: $sender"
    echo "  Alert Enabled: $(get_config_value "NFTBAN_F2B_ALERT_ENABLED" "false")"
    echo "  Rate Limit: $(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "not set") per minute"
    echo ""
    
    read -rp "Send test email to $recipient? (y/N): " -n 1 REPLY
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        send_email_notification "192.0.2.1" "TEST" "TEST_BAN" "This is a test notification" "Test_Country_Test_City" "Test_Organization"
        log_success "Test email sent (check your inbox)"
    else
        log_info "Test email cancelled"
    fi
}

# =============================================================================
# RATE LIMITING
# =============================================================================
check_ban_rate_limit() {
    local rate_limit
    rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "0")
    
    # If rate limit is 0 or not set, skip check
    if [ "$rate_limit" == "0" ] || [ -z "$rate_limit" ]; then
        return 0
    fi
    
    # Create tracker file if it doesn't exist
    touch "$RATE_LIMIT_TRACKER"
    
    # Current timestamp
    local current_time
    current_time=$(date +%s)
    local one_minute_ago=$((current_time - 60))
    
    # Add current attempt to tracker
    echo "$current_time" >> "$RATE_LIMIT_TRACKER"
    
    # Clean up old entries (older than 1 minute) and count recent attempts
    local temp_file="${RATE_LIMIT_TRACKER}.clean"
    awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" > "$temp_file"
    mv "$temp_file" "$RATE_LIMIT_TRACKER"
    
    # Count attempts in last minute
    local recent_count
    recent_count=$(wc -l < "$RATE_LIMIT_TRACKER")
    
    # Check if rate limit exceeded
    if [ "$recent_count" -gt "$rate_limit" ]; then
        log_error "RATE LIMIT EXCEEDED: $recent_count bans in last 60 seconds (limit: $rate_limit)"
        
        # Send alert (this bypasses NFTBAN_F2B_ALERT_ENABLED check)
        send_rate_limit_alert "$recent_count" "60" "$rate_limit"
        
        # Log to stats
        log_ban_attempt "RATE_LIMIT" "SYSTEM" "RATE_EXCEEDED" "Rate limit exceeded: ${recent_count} bans/min" "N/A" "N/A"
        
        return 1
    fi
    
    # Log current rate for monitoring
    if [ "$recent_count" -gt $((rate_limit / 2)) ]; then
        log_warning "Ban rate approaching limit: $recent_count/$rate_limit per minute"
    fi
    
    return 0
}

reset_rate_limit_tracker() {
    rm -f "$RATE_LIMIT_TRACKER"
    touch "$RATE_LIMIT_TRACKER"
    log_info "Rate limit tracker reset"
}

# =============================================================================
# IP RANGE CHECKING
# =============================================================================
ip_in_range() {
    local ip="$1"
    local range="$2"
    
    # Check if it's a CIDR range
    if [[ $range =~ / ]]; then
        # Use grepcidr if available
        if command -v grepcidr &> /dev/null; then
            echo "$ip" | grepcidr "$range" &> /dev/null && return 0
        else
            # Fallback: check using nft (create temporary set and test)
            local ver
            ver=$(detect_ip_version "$ip")
            local test_set="test_range_${ver}_$$"
            nft add set inet "$NFT_TABLE" "$test_set" "{ type ipv${ver}_addr; flags interval; }" 2>/dev/null || return 1
            nft add element inet "$NFT_TABLE" "$test_set" "{ $range }" 2>/dev/null || {
                nft delete set inet "$NFT_TABLE" "$test_set" 2>/dev/null
                return 1
            }
            
            # Check if IP matches
            if nft get element inet "$NFT_TABLE" "$test_set" "{ $ip }" &>/dev/null; then
                nft delete set inet "$NFT_TABLE" "$test_set" 2>/dev/null
                return 0
            fi
            nft delete set inet "$NFT_TABLE" "$test_set" 2>/dev/null
        fi
    else
        # Direct IP comparison
        [[ "$ip" == "$range" ]] && return 0
    fi
    return 1
}

# =============================================================================
# WHITELIST MANAGEMENT - Updated to use new files
# =============================================================================

create_consolidated_whitelist() {
    log_info "Creating consolidated whitelist from configuration files..."
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        log_error "Config directory not found: $CONFIG_DIR"
        return 1
    fi
    
    local temp_file="${FAIL2BAN_WHITELIST}.tmp"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    cat > "$temp_file" <<HEADER
# =============================================================================
# nftban Consolidated Fail2ban Whitelist
# Auto-generated on: $timestamp
# =============================================================================
# This file combines whitelisted IPs from:
#   - System Whitelist: $SYSTEM_WHITELIST_FILE
#   - User Whitelist: $USER_WHITELIST_FILE
# =============================================================================

HEADER
    
    local total_ips=0
    
    # Combine system and user whitelists
    for whitelist_file in "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE"; do
        if [[ -f "$whitelist_file" ]]; then
            echo "# From: $(basename "$whitelist_file")" >> "$temp_file"
            
            local count=0
            while IFS= read -r line; do
                # Skip comments and empty lines
                [[ "$line" =~ ^#.*$ ]] && continue
                [[ -z "$line" ]] && continue
                
                # Clean IP
                local ip
                ip=$(echo "$line" | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//')
                [[ -z "$ip" ]] && continue
                
                echo "$ip" >> "$temp_file"
                ((count++))
                ((total_ips++))
            done < "$whitelist_file"
            
            log_info "  Added $count IPs from $(basename "$whitelist_file")"
            echo "" >> "$temp_file"
        fi
    done
    
    # Add summary
    echo "# Total whitelisted IPs: $total_ips" >> "$temp_file"
    
    # Sort and deduplicate
    {
        grep '^#' "$temp_file"
        grep -v '^#' "$temp_file" | grep -v '^[[:space:]]*$' | sort -u
    } > "${temp_file}.sorted"
    
    mv "${temp_file}.sorted" "$FAIL2BAN_WHITELIST"
    rm -f "$temp_file"
    
    log_success "Consolidated whitelist created: $total_ips unique IPs"
    
    # Trigger consolidated search file rebuild
    build_consolidated_search_file
    
    return 0
}

check_ip_in_whitelist_files() {
    local ip="$1"
    
    # Fast path: check consolidated search file first
    if [[ -f "$FAIL2BAN_SEARCH_IPS" ]]; then
        local result
        result=$(search_ip_in_consolidated "$ip" 2>/dev/null || true)
        
        if [[ -n "$result" ]]; then
            # Check if it's a whitelist entry
            if echo "$result" | grep -q "|WHITELIST$"; then
                local source
                source=$(echo "$result" | cut -d'|' -f2)
                log_info "IP $ip found in whitelist (source: $source)"
                return 0
            fi
        fi
    fi
    
    # Fallback: direct file search
    local whitelist_files=(
        "$SYSTEM_WHITELIST_FILE"
        "$USER_WHITELIST_FILE"
        "$FAIL2BAN_WHITELIST"
    )
    
    for file in "${whitelist_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            continue
        fi
        
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue
            
            local range
            range=$(echo "$line" | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//')
            [[ -z "$range" ]] && continue
            
            if ip_in_range "$ip" "$range"; then
                log_info "IP $ip found in whitelist: $file (matches: $range)"
                return 0
            fi
        done < "$file"
    done
    
    return 1
}

# =============================================================================
# PERSISTENT BLACKLIST MANAGEMENT - Updated path
# =============================================================================

check_persistent_offender() {
    local ip="$1"
    local threshold
    threshold=$(get_config_value "PERSISTENT_BAN_THRESHOLD" "3")
    
    # If threshold is 0, disable persistent banning
    if [ "$threshold" == "0" ]; then
        return 1
    fi
    
    # Count how many times this IP has been banned
    if [ -f "$BAN_LOG" ]; then
        local ban_count
        ban_count=$(grep -c "|${ip}|.*|BANNED|" "$BAN_LOG" 2>/dev/null || echo "0")
        
        if [ "$ban_count" -ge "$threshold" ]; then
            log_warning "IP $ip is a persistent offender ($ban_count bans, threshold: $threshold)"
            return 0
        fi
    fi
    
    return 1
}

add_to_persistent_blacklist() {
    local ip="$1"
    local reason="${2:-Persistent offender}"
    
    # Create file if doesn't exist
    if [ ! -f "$FAIL2BAN_TEMP_IPS" ]; then
        cat > "$FAIL2BAN_TEMP_IPS" << 'EOF'
# =============================================================================
# nftban Persistent Blacklist (Repeat Offenders)
# =============================================================================
# This file contains IPs that have been banned multiple times
# These IPs are automatically added when they exceed PERSISTENT_BAN_THRESHOLD
# Format: IP_ADDRESS  # Comment (date, reason)
# =============================================================================

EOF
    fi
    
    # Check if IP already in persistent blacklist
    if grep -qE "^${ip}[[:space:]]" "$FAIL2BAN_TEMP_IPS" 2>/dev/null; then
        log_info "IP $ip already in persistent blacklist"
        return 0
    fi
    
    # Add IP with timestamp and reason
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${ip}  # Added: ${timestamp} - ${reason}" >> "$FAIL2BAN_TEMP_IPS"
    
    log_success "Added IP $ip to persistent blacklist"
    
    # Add to nftables user_blacklist (permanent)
    local ver
    ver=$(detect_ip_version "$ip")
    if [ "$ver" != "invalid" ]; then
        nft add element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null || \
            log_warning "Failed to add $ip to nftables user_blacklist"
    fi
    
    # Log the action
    log_ban_attempt "$ip" "PERSISTENT" "PERMANENT_BAN" "Added to persistent blacklist: ${reason}" "N/A" "N/A"
    
    # Trigger consolidated search file rebuild
    build_consolidated_search_file
    
    return 0
}

remove_from_persistent_blacklist() {
    local ip="$1"
    
    if [ ! -f "$FAIL2BAN_TEMP_IPS" ]; then
        log_error "Persistent blacklist file not found"
        return 1
    fi
    
    # Check if IP exists
    if ! grep -qE "^${ip}[[:space:]]" "$FAIL2BAN_TEMP_IPS" 2>/dev/null; then
        log_error "IP $ip not found in persistent blacklist"
        return 1
    fi
    
    # Remove IP from file
    sed -i "/^${ip}[[:space:]]/d" "$FAIL2BAN_TEMP_IPS"
    
    log_success "Removed IP $ip from persistent blacklist"
    
    # Remove from nftables user_blacklist
    local ver
    ver=$(detect_ip_version "$ip")
    if [ "$ver" != "invalid" ]; then
        nft delete element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null || \
            log_warning "Failed to remove $ip from nftables user_blacklist"
    fi
    
    # Trigger consolidated search file rebuild
    build_consolidated_search_file
    
    return 0
}

list_persistent_blacklist() {
    if [ ! -f "$FAIL2BAN_TEMP_IPS" ]; then
        echo "Persistent blacklist is empty"
        return 0
    fi
    
    echo ""
    echo "==============================================="
    echo "  Persistent Blacklist (Permanent Bans)"
    echo "==============================================="
    echo ""
    
    local count=0
    while IFS= read -r line; do
        # Skip comments and empty lines at start
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        ((count++))
        printf "%3d. %s\n" "$count" "$line"
    done < "$FAIL2BAN_TEMP_IPS"
    
    if [ "$count" -eq 0 ]; then
        echo "No IPs in persistent blacklist"
    else
        echo ""
        echo "Total: $count permanently banned IPs"
    fi
    echo ""
    echo "File: $FAIL2BAN_TEMP_IPS"
    echo "==============================================="
}

check_ip_in_persistent_blacklist() {
    local ip="$1"
    
    # Fast path: consolidated search
    if [[ -f "$FAIL2BAN_SEARCH_IPS" ]]; then
        local result
        result=$(search_ip_in_consolidated "$ip" 2>/dev/null || true)
        
        if [[ -n "$result" ]]; then
            if echo "$result" | grep -q "FAIL2BAN_TEMP|BLACKLIST$"; then
                return 0
            fi
        fi
    fi
    
    # Fallback: direct file check
    if [[ ! -f "$FAIL2BAN_TEMP_IPS" ]]; then
        return 1
    fi
    
    grep -qE "^${ip}[[:space:]]" "$FAIL2BAN_TEMP_IPS" 2>/dev/null
}

sync_persistent_blacklist_to_nftables() {
    log_info "Syncing persistent blacklist to nftables..."
    
    if [ ! -f "$FAIL2BAN_TEMP_IPS" ]; then
        log_warning "Persistent blacklist file not found"
        return 0
    fi
    
    local synced=0
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract IP (first field)
        local ip
        ip=$(echo "$line" | awk '{print $1}')
        
        if [ -n "$ip" ]; then
            local ver
            ver=$(detect_ip_version "$ip")
            if [ "$ver" != "invalid" ]; then
                if nft add element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null; then
                    ((synced++))
                fi
            fi
        fi
    done < "$FAIL2BAN_TEMP_IPS"
    
    log_success "Synced $synced IPs to nftables user_blacklist"
}

# =============================================================================
# NFTABLES OPERATIONS
# =============================================================================
check_nftables_table_exists() {
    nft list table inet "$NFT_TABLE" &>/dev/null
}

check_ip_in_nftables() {
    local ip="$1"
    local ver
    ver=$(detect_ip_version "$ip")
    
    if [ "$ver" == "invalid" ]; then
        log_error "Invalid IP address: $ip"
        return 2
    fi
    
    if ! check_nftables_table_exists; then
        log_error "nftables table 'inet $NFT_TABLE' does not exist"
        return 2
    fi
    
    # Check all relevant sets
    local sets=(
        "whitelist_v${ver}"
        "temp_ban_v${ver}"
        "user_blacklist_v${ver}"
        "system_blacklist_v${ver}"
    )
    
    for set in "${sets[@]}"; do
        if nft list set inet "$NFT_TABLE" "$set" 2>/dev/null | grep -q "$ip"; then
            log_info "IP $ip found in nftables set: $set"
            return 0
        fi
    done
    
    return 1
}

ban_ip_nftables() {
    local ip="$1"
    local jail_name="${2:-unknown}"
    local ban_time="${3:-$DEFAULT_BAN_TIME}"
    
    local ver
    ver=$(detect_ip_version "$ip")
    
    if [ "$ver" == "invalid" ]; then
        log_error "Invalid IP address: $ip"
        return 1
    fi
    
    if ! check_nftables_table_exists; then
        log_error "nftables table 'inet $NFT_TABLE' does not exist"
        return 1
    fi
    
    local target_set="temp_ban_v${ver}"
    
    # Add IP with timeout and comment
    if nft add element inet "$NFT_TABLE" "$target_set" \
        "{ $ip timeout ${ban_time}s comment \"fail2ban_${jail_name}\" }"; then
        log_success "Banned IP $ip in set $target_set (timeout: ${ban_time}s, jail: $jail_name)"
        return 0
    else
        log_error "Failed to ban IP $ip"
        return 1
    fi
}

# =============================================================================
# IP BANNING WORKFLOW
# =============================================================================
process_ban() {
    local ip="$1"
    local jail_name="${2:-unknown}"
    local ban_time="${3:-$DEFAULT_BAN_TIME}"
    
    log_info "Processing ban request for IP: $ip (jail: $jail_name)"
    
    # Check rate limit before processing
    check_ban_rate_limit
    
    # Get IP information (even if not banning)
    local geoip_info
    local whois_info
    geoip_info=$(geoip_lookup "$ip")
    whois_info=$(whois_lookup "$ip")
    
    # Step 1: Check in whitelist files
    if check_ip_in_whitelist_files "$ip"; then
        log_warning "IP $ip is whitelisted - BAN DENIED"
        log_ban_attempt "$ip" "$jail_name" "WHITELISTED" "IP found in whitelist files" "$geoip_info" "$whois_info"
        send_email_notification "$ip" "$jail_name" "DENIED (Whitelisted)" "IP found in whitelist" "$geoip_info" "$whois_info"
        return 1
    fi
    
    # Step 2: Check if already in persistent blacklist
    if check_ip_in_persistent_blacklist "$ip"; then
        log_info "IP $ip already in persistent blacklist"
        log_ban_attempt "$ip" "$jail_name" "ALREADY_BLACKLISTED" "IP in persistent blacklist" "$geoip_info" "$whois_info"
        return 0
    fi
    
    # Step 3: Check in nftables
    if check_ip_in_nftables "$ip"; then
        log_warning "IP $ip already exists in nftables - skipping"
        log_ban_attempt "$ip" "$jail_name" "ALREADY_EXISTS" "IP already in nftables" "$geoip_info" "$whois_info"
        return 1
    fi
    
    # Step 4: Ban the IP
    if ban_ip_nftables "$ip" "$jail_name" "$ban_time"; then
        log_ban_attempt "$ip" "$jail_name" "BANNED" "Ban successful (${ban_time}s)" "$geoip_info" "$whois_info"
        send_email_notification "$ip" "$jail_name" "BANNED" "Failed authentication attempts detected" "$geoip_info" "$whois_info"
        
        # Step 5: Check if persistent offender and add to permanent blacklist
        if check_persistent_offender "$ip"; then
            local ban_count
            ban_count=$(grep -c "|${ip}|.*|BANNED|" "$BAN_LOG" 2>/dev/null || echo "0")
            add_to_persistent_blacklist "$ip" "Repeat offender (${ban_count} bans) - ${jail_name} jail"
            
            # Send notification about permanent ban
            send_email_notification "$ip" "$jail_name" "PERMANENTLY BANNED" \
                "IP banned ${ban_count} times - added to persistent blacklist" "$geoip_info" "$whois_info"
        fi
        
        return 0
    else
        log_ban_attempt "$ip" "$jail_name" "ERROR" "Failed to add to nftables" "$geoip_info" "$whois_info"
        return 1
    fi
}

# =============================================================================
# JAIL TEMPLATE PROCESSING
# =============================================================================
process_jail_template() {
    local template_file="$1"
    local jail_name="$2"
    local output_file="$3"
    
    # Get configuration values
    local ban_time
    local max_retry
    local find_time
    local ignoreip_file
    ban_time=$(get_jail_config "$jail_name" "BAN_TIME" "3600")
    max_retry=$(get_jail_config "$jail_name" "MAX_RETRY" "5")
    find_time=$(get_jail_config "$jail_name" "FIND_TIME" "600")
    ignoreip_file="$FAIL2BAN_WHITELIST"
    
    log_info "Processing template with values: BAN_TIME=$ban_time, MAX_RETRY=$max_retry, FIND_TIME=$find_time"
    
    # Copy template and substitute values
    sed -e "s|{{BANTIME}}|${ban_time}|g" \
        -e "s|{{MAXRETRY}}|${max_retry}|g" \
        -e "s|{{FINDTIME}}|${find_time}|g" \
        -e "s|{{IGNOREIP}}|file:${ignoreip_file}|g" \
        -e "s|{{JAIL_NAME}}|${jail_name}|g" \
        "$template_file" > "$output_file"
}

# =============================================================================
# JAIL MANAGEMENT
# =============================================================================
get_available_jails() {
    local os="$1"
    local jail_dir="${TEMPLATE_DIR}/${os}/jail.d"
    
    if [ ! -d "$jail_dir" ]; then
        log_error "Jail directory not found: $jail_dir"
        return 1
    fi
    
    # Extract jail names from nftban-*.conf files
    find "$jail_dir" -name "nftban-*.conf" -type f | while read -r file; do
        basename "$file" | sed 's/nftban-\(.*\)\.conf/\1/' | tr '[:lower:]' '[:upper:]'
    done | sort -u
}

get_jail_status() {
    local jail_name="$1"
    get_jail_config "$jail_name" "JAIL" "false"
}

deploy_jail() {
    local jail_name="$1"
    local os="$2"
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    log_info "Deploying jail: $jail_name"
    
    # Ensure config exists
    ensure_jail_config_exists "$jail_name"
    
    # Copy and process jail.d files
    if [ -d "${TEMPLATE_DIR}/${os}/jail.d" ]; then
        local jail_file="${TEMPLATE_DIR}/${os}/jail.d/nftban-${jail_lower}.conf"
        if [ -f "$jail_file" ]; then
            process_jail_template "$jail_file" "$jail_name" "${FAIL2BAN_DIR}/jail.d/nftban-${jail_lower}.conf"
            log_success "Deployed jail config: nftban-${jail_lower}.conf"
        fi
    fi
    
    # Copy filter.d files (usually don't need variable substitution)
    if [ -d "${TEMPLATE_DIR}/${os}/filter.d" ]; then
        local filter_file="${TEMPLATE_DIR}/${os}/filter.d/nftban-${jail_lower}.conf"
        if [ -f "$filter_file" ]; then
            cp "$filter_file" "${FAIL2BAN_DIR}/filter.d/"
            log_success "Deployed filter config: nftban-${jail_lower}.conf"
        fi
    fi
    
    # Copy action.d files if they exist
    if [ -d "${TEMPLATE_DIR}/${os}/action.d" ]; then
        local action_file="${TEMPLATE_DIR}/${os}/action.d/nftban-${jail_lower}.conf"
        if [ -f "$action_file" ]; then
            cp "$action_file" "${FAIL2BAN_DIR}/action.d/"
            log_success "Deployed action config: nftban-${jail_lower}.conf"
        fi
    fi
    
    # Update jail status to enabled
    set_jail_config "$jail_name" "JAIL" "true"
}

remove_jail() {
    local jail_name="$1"
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
    log_info "Removing jail: $jail_name"
    
    # Remove files from fail2ban directories
    rm -f "${FAIL2BAN_DIR}/jail.d/nftban-${jail_lower}.conf"
    rm -f "${FAIL2BAN_DIR}/filter.d/nftban-${jail_lower}.conf"
    rm -f "${FAIL2BAN_DIR}/action.d/nftban-${jail_lower}.conf"
    
    # Update jail status to disabled
    set_jail_config "$jail_name" "JAIL" "false"
    
    log_success "Removed jail: $jail_name"
}

# =============================================================================
# CRON JOB FOR AUTO-REBUILD
# =============================================================================

install_consolidated_file_cron() {
    log_info "Installing cron job for consolidated file updates..."
    
    local cron_script="$BASE_DIR/scripts/rebuild_consolidated_ips.sh"
    
    # Create rebuild script
    cat > "$cron_script" <<'CRON_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/nftban"
CONFIG_DIR="${BASE_DIR}/config"
FAIL2BAN_SEARCH_IPS="$CONFIG_DIR/nftban-f2b-ips_for-search.local"

# Source the main script functions
if [ -f "$BASE_DIR/scripts/nftban_init_fail2ban_conf.sh" ]; then
    source "$BASE_DIR/scripts/nftban_init_fail2ban_conf.sh"
    build_consolidated_search_file
else
    echo "Error: Main script not found" >&2
    exit 1
fi
CRON_SCRIPT
    
    chmod +x "$cron_script"
    
    # Add to cron (every 5 minutes)
    local cron_entry="*/5 * * * * $cron_script >/dev/null 2>&1"
    
    # Check if entry already exists
    if crontab -l 2>/dev/null | grep -qF "$cron_script"; then
        log_info "Cron job already installed"
        return 0
    fi
    
    # Add to crontab
    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
    
    log_success "Cron job installed: updates every 5 minutes"
}

remove_consolidated_file_cron() {
    local cron_script="$BASE_DIR/scripts/rebuild_consolidated_ips.sh"
    
    # Remove from crontab
    crontab -l 2>/dev/null | grep -vF "$cron_script" | crontab - || true
    
    # Remove script
    rm -f "$cron_script"
    
    log_info "Removed consolidated file cron job"
}

# =============================================================================
# INSTALLATION / UNINSTALLATION - Fixed and Enhanced
# =============================================================================

install_nftban_fail2ban() {
    log_info "Installing nftban fail2ban templates and configurations..."
    
    local os
    os=$(detect_os)
    log_info "Detected OS: $os"
    
    # Verify template directory exists
    local template_os_dir="${TEMPLATE_DIR}/${os}"
    if [[ ! -d "$template_os_dir" ]]; then
        log_error "Template directory not found: $template_os_dir"
        log_error "Expected structure:"
        log_error "  ${template_os_dir}/action.d/"
        log_error "  ${template_os_dir}/filter.d/"
        log_error "  ${template_os_dir}/jail.d/"
        return 1
    fi
    
    # Verify all required subdirectories exist
    for subdir in action.d filter.d jail.d; do
        if [[ ! -d "${template_os_dir}/${subdir}" ]]; then
            log_error "Required directory missing: ${template_os_dir}/${subdir}"
            return 1
        fi
    done
    
    # Create backup
    local backup_timestamp
    backup_timestamp=$(date +'%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/pre_install_${backup_timestamp}"
    mkdir -p "$backup_path"
    
    log_info "Creating backup at: $backup_path"
    
    # Backup existing fail2ban configs
    local backed_up=0
    for dir in jail.d filter.d action.d; do
        if [[ -d "${FAIL2BAN_DIR}/${dir}" ]]; then
            find "${FAIL2BAN_DIR}/${dir}" -name "nftban*.conf" -type f 2>/dev/null | while IFS= read -r file; do
                cp "$file" "$backup_path/" 2>/dev/null && ((backed_up++)) || true
            done
        fi
    done
    
    log_info "Backed up $backed_up existing configuration files"
    
    # Install action.d templates
    if [[ -d "${template_os_dir}/action.d" ]]; then
        log_info "Installing action.d templates..."
        local action_count=0
        
        find "${template_os_dir}/action.d" -name "*.conf" -type f | while IFS= read -r template; do
            local filename
            filename=$(basename "$template")
            
            if cp "$template" "${FAIL2BAN_DIR}/action.d/${filename}"; then
                chmod 0644 "${FAIL2BAN_DIR}/action.d/${filename}"
                log_success "  Installed: action.d/${filename}"
                ((action_count++))
            else
                log_error "  Failed: action.d/${filename}"
            fi
        done
        
        log_info "Installed action.d templates"
    else
        log_warning "No action.d directory found in templates"
    fi
    
    # Install filter.d templates
    if [[ -d "${template_os_dir}/filter.d" ]]; then
        log_info "Installing filter.d templates..."
        local filter_count=0
        
        find "${template_os_dir}/filter.d" -name "*.conf" -type f | while IFS= read -r template; do
            local filename
            filename=$(basename "$template")
            
            if cp "$template" "${FAIL2BAN_DIR}/filter.d/${filename}"; then
                chmod 0644 "${FAIL2BAN_DIR}/filter.d/${filename}"
                log_success "  Installed: filter.d/${filename}"
                ((filter_count++))
            else
                log_error "  Failed: filter.d/${filename}"
            fi
        done
        
        log_info "Installed filter.d templates"
    else
        log_warning "No filter.d directory found in templates"
    fi
    
    # Process and install jail.d templates
    if [[ -d "${template_os_dir}/jail.d" ]]; then
        log_info "Installing jail.d templates..."
        local jail_count=0
        
        find "${template_os_dir}/jail.d" -name "nftban-*.conf" -type f | while IFS= read -r template_file; do
            local jail_filename
            jail_filename=$(basename "$template_file")
            local jail_name
            jail_name=$(echo "$jail_filename" | sed 's/nftban-\(.*\)\.conf/\1/' | tr '[:lower:]' '[:upper:]')
            
            # Ensure jail config exists
            ensure_jail_config_exists "$jail_name"
            
            # Process template with current config values
            if process_jail_template "$template_file" "$jail_name" "${FAIL2BAN_DIR}/jail.d/${jail_filename}"; then
                chmod 0644 "${FAIL2BAN_DIR}/jail.d/${jail_filename}"
                log_success "  Installed: jail.d/${jail_filename}"
                ((jail_count++))
            else
                log_error "  Failed: jail.d/${jail_filename}"
            fi
        done
        
        log_info "Installed jail templates"
    else
        log_error "No jail.d directory found in templates"
        return 1
    fi
    
    # Create main nftban action if doesn't exist
    local main_action="${FAIL2BAN_DIR}/action.d/nftban.conf"
    if [[ ! -f "$main_action" ]]; then
        log_info "Creating main nftban action..."
        cat > "$main_action" << 'EOF'
# nftban main action for fail2ban
[Definition]
actionstart = 
actionstop = 
actioncheck = 
actionban = /etc/nftban/scripts/nftban_init_fail2ban_conf.sh --ban <ip> <name> <bantime>
actionunban = 

[Init]
EOF
        chmod 0644 "$main_action"
        log_success "Created: $main_action"
    fi
    
    # Create/update whitelist files with proper structure
    local whitelist_files=(
        "$SYSTEM_WHITELIST_FILE"
        "$USER_WHITELIST_FILE"
        "$FAIL2BAN_WHITELIST"
    )
    
    for whitelist in "${whitelist_files[@]}"; do
        if [[ ! -f "$whitelist" ]]; then
            log_info "Creating whitelist: $(basename "$whitelist")"
            cat > "$whitelist" << 'EOF'
# =============================================================================
# nftban Whitelist Configuration
# =============================================================================
# Add IPs or CIDR ranges that should NEVER be banned
# Format: One IP/range per line
# Example:
#   192.168.1.1
#   10.0.0.0/8
#   2001:db8::/32
# =============================================================================

127.0.0.1
::1
EOF
            chmod 0644 "$whitelist"
        fi
    done
    
    # Create blacklist files if they don't exist
    local blacklist_files=(
        "$IPV4_BLACKLIST_FILE"
        "$IPV6_BLACKLIST_FILE"
        "$USER_BLACKLIST_FILE"
        "$FAIL2BAN_TEMP_IPS"
    )
    
    for blacklist in "${blacklist_files[@]}"; do
        if [[ ! -f "$blacklist" ]]; then
            log_info "Creating blacklist: $(basename "$blacklist")"
            cat > "$blacklist" << 'EOF'
# =============================================================================
# nftban Blacklist Configuration
# =============================================================================
# Add IPs or CIDR ranges to block
# Format: One IP/range per line
# =============================================================================

EOF
            chmod 0644 "$blacklist"
        fi
    done
    
    # Build initial consolidated search file
    build_consolidated_search_file
    
    # Install cron job for auto-rebuild
    install_consolidated_file_cron
    
    # Set proper permissions on all configs
    chmod 0644 "${FAIL2BAN_DIR}/jail.d/nftban-"*.conf 2>/dev/null || true
    chmod 0644 "${FAIL2BAN_DIR}/filter.d/nftban"*.conf 2>/dev/null || true
    chmod 0644 "${FAIL2BAN_DIR}/action.d/nftban"*.conf 2>/dev/null || true
    
    log_success "Installation complete!"
    echo ""
    echo "=== Installation Summary ==="
    echo "Templates installed from: $template_os_dir"
    echo "Backup created at: $backup_path"
    echo ""
    echo "Configuration files:"
    for file in "${whitelist_files[@]}" "${blacklist_files[@]}"; do
        if [[ -f "$file" ]]; then
            echo "  ✓ $(basename "$file")"
        fi
    done
    echo ""
    echo "Next steps:"
    echo "  1. Review configuration: $NFTBAN_CONFIG_LOCAL"
    echo "  2. Update whitelists/blacklists in: $CONFIG_DIR"
    echo "  3. Enable jails: $(basename "$0") --update-jails"
    echo "  4. Test configuration: $(basename "$0") --test-config"
    echo "  5. Reload fail2ban: systemctl reload fail2ban"
    echo ""
    echo "Consolidated IP search: ENABLED (auto-updates every 5 minutes)"
    echo "============================="
}

uninstall_nftban_fail2ban() {
    log_warning "Uninstalling nftban fail2ban templates and configurations..."
    
    echo ""
    echo "This will remove all nftban-related templates and configurations from fail2ban."
    echo "A backup will be created before removal."
    echo ""
    read -rp "Are you sure you want to uninstall? (yes/NO): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Uninstall cancelled"
        return 0
    fi
    
    # Create backup
    local backup_timestamp
    backup_timestamp=$(date +'%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/pre_uninstall_${backup_timestamp}"
    mkdir -p "$backup_path"
    
    log_info "Creating backup at: $backup_path"
    
    local removed_count=0
    
    # Backup and remove jail.d files
    if [[ -d "${FAIL2BAN_DIR}/jail.d" ]]; then
        find "${FAIL2BAN_DIR}/jail.d" -name "nftban-*.conf" -type f 2>/dev/null | while IFS= read -r file; do
            cp "$file" "$backup_path/" 2>/dev/null || true
            rm -f "$file"
            log_info "  Removed: $(basename "$file")"
            ((removed_count++))
        done
    fi
    
    # Backup and remove filter.d files
    if [[ -d "${FAIL2BAN_DIR}/filter.d" ]]; then
        find "${FAIL2BAN_DIR}/filter.d" -name "nftban*.conf" -type f 2>/dev/null | while IFS= read -r file; do
            cp "$file" "$backup_path/" 2>/dev/null || true
            rm -f "$file"
            log_info "  Removed: $(basename "$file")"
            ((removed_count++))
        done
    fi
    
    # Backup and remove action.d files
    if [[ -d "${FAIL2BAN_DIR}/action.d" ]]; then
        find "${FAIL2BAN_DIR}/action.d" -name "nftban*.conf" -type f 2>/dev/null | while IFS= read -r file; do
            cp "$file" "$backup_path/" 2>/dev/null || true
            rm -f "$file"
            log_info "  Removed: $(basename "$file")"
            ((removed_count++))
        done
    fi
    
    # Remove consolidated file cron job
    remove_consolidated_file_cron
    
    log_success "Uninstallation complete!"
    echo ""
    echo "=== Uninstallation Summary ==="
    echo "Removed configuration files from fail2ban"
    echo "Backup created at: $backup_path"
    echo ""
    echo "Note: Configuration files in ${CONFIG_DIR} were NOT removed."
    echo "To remove configuration files:"
    echo "  rm -f ${CONFIG_DIR}/nftban-*.conf.local"
    echo ""
    echo "To remove consolidated search file:"
    echo "  rm -f ${FAIL2BAN_SEARCH_IPS}"
    echo ""
    echo "Reload fail2ban to apply changes: systemctl reload fail2ban"
    echo "=============================="
}

update_templates() {
    log_info "Updating nftban fail2ban templates..."
    
    local os
    os=$(detect_os)
    local template_os_dir="${TEMPLATE_DIR}/${os}"
    
    # Verify template directory
    if [[ ! -d "$template_os_dir" ]]; then
        log_error "Template directory not found: $template_os_dir"
        log_error "Run --install first to set up the directory structure"
        return 1
    fi
    
    # Verify required subdirectories
    for subdir in action.d filter.d jail.d; do
        if [[ ! -d "${template_os_dir}/${subdir}" ]]; then
            log_error "Required template directory missing: ${template_os_dir}/${subdir}"
            return 1
        fi
    done
    
    # Create backup
    local backup_timestamp
    backup_timestamp=$(date +'%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/pre_update_${backup_timestamp}"
    mkdir -p "$backup_path"
    
    log_info "Creating backup at: $backup_path"
    
    # Backup current fail2ban configs
    for dir in jail.d filter.d action.d; do
        find "${FAIL2BAN_DIR}/${dir}" -name "nftban*.conf" -type f 2>/dev/null | while IFS= read -r file; do
            cp "$file" "$backup_path/" 2>/dev/null || true
        done
    done
    
    echo ""
    echo "Template Update Options:"
    echo "  1. Update from local templates (${template_os_dir})"
    echo "  2. Update from Git repository"
    echo "  3. Cancel"
    echo ""
    read -rp "Select option [1-3]: " update_option
    
    case "$update_option" in
        1)
            log_info "Updating from local templates..."
            
            local updated_count=0
            
            # Update action.d
            if [[ -d "${template_os_dir}/action.d" ]]; then
                log_info "Updating action.d templates..."
                find "${template_os_dir}/action.d" -name "*.conf" -type f | while IFS= read -r template; do
                    local filename
                    filename=$(basename "$template")
                    if cp "$template" "${FAIL2BAN_DIR}/action.d/${filename}"; then
                        chmod 0644 "${FAIL2BAN_DIR}/action.d/${filename}"
                        log_success "  Updated: action.d/${filename}"
                        ((updated_count++))
                    fi
                done
            fi
            
            # Update filter.d
            if [[ -d "${template_os_dir}/filter.d" ]]; then
                log_info "Updating filter.d templates..."
                find "${template_os_dir}/filter.d" -name "*.conf" -type f | while IFS= read -r template; do
                    local filename
                    filename=$(basename "$template")
                    if cp "$template" "${FAIL2BAN_DIR}/filter.d/${filename}"; then
                        chmod 0644 "${FAIL2BAN_DIR}/filter.d/${filename}"
                        log_success "  Updated: filter.d/${filename}"
                        ((updated_count++))
                    fi
                done
            fi
            
            # Update jail.d (process templates for enabled jails only)
            if [[ -d "${template_os_dir}/jail.d" ]]; then
                log_info "Updating jail.d templates..."
                
                find "${template_os_dir}/jail.d" -name "nftban-*.conf" -type f | while IFS= read -r template_file; do
                    local jail_filename
                    jail_filename=$(basename "$template_file")
                    local jail_name
                    jail_name=$(echo "$jail_filename" | sed 's/nftban-\(.*\)\.conf/\1/' | tr '[:lower:]' '[:upper:]')
                    
                    # Check if jail is enabled
                    local jail_status
                    jail_status=$(get_jail_status "$jail_name")
                    
                    if [[ "$jail_status" == "true" ]]; then
                        if process_jail_template "$template_file" "$jail_name" "${FAIL2BAN_DIR}/jail.d/${jail_filename}"; then
                            chmod 0644 "${FAIL2BAN_DIR}/jail.d/${jail_filename}"
                            log_success "  Updated: jail.d/${jail_filename}"
                            ((updated_count++))
                        fi
                    else
                        log_info "  Skipped (disabled): jail.d/${jail_filename}"
                    fi
                done
            fi
            
            # Rebuild consolidated search file
            build_consolidated_search_file
            
            log_success "Templates updated from local source"
            ;;
            
        2)
            log_info "Updating from Git repository..."
            
            local git_repo
            git_repo=$(get_config_value "NFTBAN_GIT_REPO" "")
            local git_branch
            git_branch=$(get_config_value "NFTBAN_GIT_BRANCH" "main")
            
            if [[ -z "$git_repo" ]]; then
                echo ""
                read -rp "Enter Git repository URL: " git_repo
                
                if [[ -z "$git_repo" ]]; then
                    log_error "Git repository URL required"
                    return 1
                fi
                
                # Save for future use
                set_config_value "NFTBAN_GIT_REPO" "$git_repo"
            fi
            
            if ! command -v git &> /dev/null; then
                log_error "Git is not installed. Please install git first."
                return 1
            fi
            
            # Clone to temporary directory
            local temp_dir
            temp_dir=$(mktemp -d)
            log_info "Cloning repository to temporary directory..."
            
            if git clone --depth 1 --branch "$git_branch" "$git_repo" "$temp_dir" 2>/dev/null; then
                # Find templates directory in repo
                local repo_template_dir=""
                
                for possible_path in \
                    "${temp_dir}/templates/fail2ban/${os}" \
                    "${temp_dir}/fail2ban/${os}" \
                    "${temp_dir}/${os}"; do
                    
                    if [[ -d "$possible_path" ]]; then
                        repo_template_dir="$possible_path"
                        break
                    fi
                done
                
                if [[ -z "$repo_template_dir" ]]; then
                    log_error "Could not find templates for ${os} in repository"
                    log_error "Expected structure: templates/fail2ban/${os}/"
                    rm -rf "$temp_dir"
                    return 1
                fi
                
                log_info "Found templates at: $repo_template_dir"
                log_info "Updating templates from repository..."
                
                local updated_count=0
                
                # Copy templates to local template directory first
                for subdir in action.d filter.d jail.d; do
                    if [[ -d "${repo_template_dir}/${subdir}" ]]; then
                        mkdir -p "${template_os_dir}/${subdir}"
                        
                        find "${repo_template_dir}/${subdir}" -name "*.conf" -type f | while IFS= read -r template; do
                            local filename
                            filename=$(basename "$template")
                            
                            # Copy to local templates
                            cp "$template" "${template_os_dir}/${subdir}/${filename}"
                            log_info "  Downloaded: ${subdir}/${filename}"
                            
                            # Install to fail2ban
                            if [[ "$subdir" == "jail.d" ]]; then
                                # Process jail templates
                                local jail_name
                                jail_name=$(echo "$filename" | sed 's/nftban-\(.*\)\.conf/\1/' | tr '[:lower:]' '[:upper:]')
                                
                                local jail_status
                                jail_status=$(get_jail_status "$jail_name")
                                
                                if [[ "$jail_status" == "true" ]]; then
                                    if process_jail_template "${template_os_dir}/${subdir}/${filename}" \
                                       "$jail_name" "${FAIL2BAN_DIR}/${subdir}/${filename}"; then
                                        chmod 0644 "${FAIL2BAN_DIR}/${subdir}/${filename}"
                                        log_success "  Updated: ${subdir}/${filename}"
                                        ((updated_count++))
                                    fi
                                fi
                            else
                                # Direct copy for action/filter
                                if cp "${template_os_dir}/${subdir}/${filename}" \
                                   "${FAIL2BAN_DIR}/${subdir}/${filename}"; then
                                    chmod 0644 "${FAIL2BAN_DIR}/${subdir}/${filename}"
                                    log_success "  Updated: ${subdir}/${filename}"
                                    ((updated_count++))
                                fi
                            fi
                        done
                    fi
                done
                
                rm -rf "$temp_dir"
                
                # Rebuild consolidated search file
                build_consolidated_search_file
                
                log_success "Templates updated from Git repository"
            else
                log_error "Failed to clone repository: $git_repo"
                rm -rf "$temp_dir"
                return 1
            fi
            ;;
            
        3|*)
            log_info "Update cancelled"
            return 0
            ;;
    esac
    
    echo ""
    echo "Backup created at: $backup_path"
    echo ""
    echo "Reload fail2ban to apply changes: systemctl reload fail2ban"
}

# =============================================================================
# TESTING FUNCTIONS
# =============================================================================
test_configuration() {
    log_info "Testing nftban configuration..."
    echo ""
    echo "=========================================="
    echo "  Configuration Test"
    echo "=========================================="
    echo ""
    
    # Check directories
    echo "Directory Structure:"
    for dir in "$BASE_DIR" "$CONFIG_DIR" "$TEMPLATE_DIR" "$BACKUP_DIR" "$DATA_DIR"; do
        if [ -d "$dir" ]; then
            echo -e "  ${GREEN}✓${NC} $dir"
        else
            echo -e "  ${RED}✗${NC} $dir (missing)"
        fi
    done
    echo ""
    
    # Check configuration files
    echo "Configuration Files:"
    local config_files=(
        "$NFTBAN_CONFIG"
        "$NFTBAN_CONFIG_LOCAL"
        "$FAIL2BAN_TEMP_IPS"
        "$FAIL2BAN_SEARCH_IPS"
    )
    for file in "${config_files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "  ${GREEN}✓${NC} $file"
        else
            echo -e "  ${YELLOW}!${NC} $file (not found)"
        fi
    done
    echo ""
    
    # Check nftables
    echo "nftables Status:"
    if check_nftables_table_exists; then
        echo -e "  ${GREEN}✓${NC} Table 'nftban_global' exists"
        
        # Check sets
        local ver_list=("4" "6")
        local set_types=("whitelist" "temp_ban" "user_blacklist" "system_blacklist")
        for ver in "${ver_list[@]}"; do
            for set_type in "${set_types[@]}"; do
                if nft list set inet "$NFT_TABLE" "${set_type}_v${ver}" &>/dev/null; then
                    echo -e "    ${GREEN}✓${NC} ${set_type}_v${ver}"
                else
                    echo -e "    ${RED}✗${NC} ${set_type}_v${ver} (missing)"
                fi
            done
        done
    else
        echo -e "  ${RED}✗${NC} Table 'nftban_global' not found"
    fi
    echo ""
    
    # Check fail2ban
    echo "Fail2ban Status:"
    if systemctl is-active --quiet fail2ban; then
        echo -e "  ${GREEN}✓${NC} fail2ban service is running"
    else
        echo -e "  ${RED}✗${NC} fail2ban service is not running"
    fi
    echo ""
    
    # Check consolidated search file
    echo "Consolidated Search File:"
    if [ -f "$FAIL2BAN_SEARCH_IPS" ]; then
        local total_ips
        total_ips=$(grep -cE "^[0-9]" "$FAIL2BAN_SEARCH_IPS" 2>/dev/null || echo "0")
        echo -e "  ${GREEN}✓${NC} File exists: $FAIL2BAN_SEARCH_IPS"
        echo "  Total indexed IPs: $total_ips"
        
        # Check freshness
        if check_consolidated_file_freshness; then
            echo -e "  ${YELLOW}!${NC} File needs rebuild (source files are newer)"
        else
            echo -e "  ${GREEN}✓${NC} File is up to date"
        fi
    else
        echo -e "  ${RED}✗${NC} Consolidated search file not found"
    fi
    echo ""
    
    # Check configuration values
    echo "Configuration Values:"
    echo "  Alert Enabled: $(get_config_value "NFTBAN_F2B_ALERT_ENABLED" "not set")"
    echo "  GeoIP Enabled: $(get_config_value "NFTBAN_F2B_GEOIP_ENABLE" "not set")"
    echo "  WHOIS Enabled: $(get_config_value "NFTBAN_F2B_WHOIS_ENABLE" "not set")"
    echo "  Email Recipient: $(get_config_value "NFTBAN_F2B_RECIPIENT" "not set")"
    echo "  Default Ban Time: $(get_config_value "NFTBAN_F2B_DEF_BAN_TIME" "not set")s"
    echo "  Rate Limit: $(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "not set") per minute"
    echo "  Persistent Ban Threshold: $(get_config_value "PERSISTENT_BAN_THRESHOLD" "3") bans"
    echo ""
    
    log_success "Configuration test complete"
}

test_jail() {
    local jail_name="$1"
    
    if [ -z "$jail_name" ]; then
        log_error "Please specify a jail name to test"
        return 1
    fi
    
    log_info "Testing jail: $jail_name"
    echo ""
    echo "=========================================="
    echo "  Jail Test: $jail_name"
    echo "=========================================="
    echo ""
    
    # Check if jail is configured
    local jail_enabled
    jail_enabled=$(get_jail_status "$jail_name")
    echo "Jail Status: $jail_enabled"
    
    if [ "$jail_enabled" != "true" ]; then
        echo -e "${YELLOW}Warning: Jail is not enabled${NC}"
    fi
    
    echo ""
    echo "Jail Configuration:"
    echo "  Ban Time: $(get_jail_config "$jail_name" "BAN_TIME" "not set")s"
    echo "  Max Retry: $(get_jail_config "$jail_name" "MAX_RETRY" "not set")"
    echo "  Find Time: $(get_jail_config "$jail_name" "FIND_TIME" "not set")s"
    echo ""
    
    # Check if jail files exist in fail2ban
    local jail_lower
    jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    echo "Deployed Files:"
    
    local jail_file="${FAIL2BAN_DIR}/jail.d/nftban-${jail_lower}.conf"
    if [ -f "$jail_file" ]; then
        echo -e "  ${GREEN}✓${NC} $jail_file"
    else
        echo -e "  ${RED}✗${NC} $jail_file (not deployed)"
    fi
    
    local filter_file="${FAIL2BAN_DIR}/filter.d/nftban-${jail_lower}.conf"
    if [ -f "$filter_file" ]; then
        echo -e "  ${GREEN}✓${NC} $filter_file"
    else
        echo -e "  ${RED}✗${NC} $filter_file (not deployed)"
    fi
    echo ""
    
    # Check fail2ban status
    if command -v fail2ban-client &> /dev/null; then
        echo "Fail2ban Jail Status:"
        fail2ban-client status 2>/dev/null | grep -i "${jail_lower}\|${jail_name}" || echo "  Jail not found in fail2ban"
    fi
    echo ""
    
    log_success "Jail test complete"
}

# =============================================================================
# STATISTICS AND DASHBOARD
# =============================================================================
show_statistics() {
    echo ""
    echo "==============================================="
    echo "  nftban Statistics Dashboard"
    echo "==============================================="
    echo ""
    
    if [ ! -f "$BAN_LOG" ] || [ ! -s "$BAN_LOG" ]; then
        log_warning "No ban log data available yet"
        return 0
    fi
    
    # Total attempts
    local total_attempts
    total_attempts=$(wc -l < "$BAN_LOG")
    echo -e "${CYAN}Total Ban Attempts:${NC} $total_attempts"
    echo ""
    
    # Current ban rate
    local rate_limit
    rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "0")
    if [ "$rate_limit" != "0" ] && [ -n "$rate_limit" ] && [ -f "$RATE_LIMIT_TRACKER" ]; then
        local current_time
        current_time=$(date +%s)
        local one_minute_ago=$((current_time - 60))
        local current_rate
        current_rate=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
        
        echo -e "${CYAN}Current Ban Rate:${NC}"
        if [ "$current_rate" -gt "$rate_limit" ]; then
            echo -e "  ${RED}■${NC} ${current_rate} bans/min ${RED}(EXCEEDS LIMIT: ${rate_limit})${NC}"
        elif [ "$current_rate" -gt $((rate_limit / 2)) ]; then
            echo -e "  ${YELLOW}■${NC} ${current_rate} bans/min ${YELLOW}(limit: ${rate_limit})${NC}"
        else
            echo -e "  ${GREEN}■${NC} ${current_rate} bans/min (limit: ${rate_limit})"
        fi
        echo ""
    fi
    
    # Actions breakdown
    echo -e "${CYAN}Actions Breakdown:${NC}"
    awk -F'|' '{print $4}' "$BAN_LOG" | sort | uniq -c | sort -rn | while read -r count action; do
        case "$action" in
            BANNED)
                echo -e "  ${GREEN}■${NC} BANNED: $count"
                ;;
            WHITELISTED)
                echo -e "  ${YELLOW}■${NC} WHITELISTED: $count"
                ;;
            ALREADY_EXISTS)
                echo -e "  ${BLUE}■${NC} ALREADY_EXISTS: $count"
                ;;
            ERROR)
                echo -e "  ${RED}■${NC} ERROR: $count"
                ;;
            RATE_EXCEEDED)
                echo -e "  ${MAGENTA}■${NC} RATE_EXCEEDED: $count"
                ;;
            PERMANENT_BAN)
                echo -e "  ${MAGENTA}■${NC} PERMANENT_BAN: $count"
                ;;
            *)
                echo "  ■   $action: $count"
                ;;
        esac
    done
    echo ""
    
    # Top 10 banned IPs
    echo -e "${CYAN}Top 10 Most Targeted IPs:${NC}"
    awk -F'|' '{print $2}' "$BAN_LOG" | sort | uniq -c | sort -rn | head -10 | while read -r count ip; do
        printf "  %-18s %s\n" "$ip" "$count attempts"
    done
    echo ""
    
    # Jails statistics
    echo -e "${CYAN}Jails Activity:${NC}"
    awk -F'|' '{print $3}' "$BAN_LOG" | sort | uniq -c | sort -rn | while read -r count jail; do
        printf "  %-20s %s\n" "$jail" "$count attempts"
    done
    echo ""
    
    # Top countries (if GeoIP enabled)
    if grep -q "GeoIP_Disabled\|GeoIP_Unavailable" "$BAN_LOG"; then
        echo -e "${YELLOW}GeoIP data not available (enable with NFTBAN_F2B_GEOIP_ENABLE=true)${NC}"
    else
        echo -e "${CYAN}Top 10 Countries:${NC}"
        awk -F'|' '{print $6}' "$BAN_LOG" | awk -F'_' '{print $1}' | grep -v "^$" | sort | uniq -c | sort -rn | head -10 | while read -r count country; do
            printf "  %-20s %s\n" "$country" "$count"
        done
    fi
    echo ""
    
    # Consolidated search file stats
    if [ -f "$FAIL2BAN_SEARCH_IPS" ]; then
        echo -e "${CYAN}Consolidated Search File:${NC}"
        local total_indexed
        total_indexed=$(grep -cE "^[0-9]" "$FAIL2BAN_SEARCH_IPS" 2>/dev/null || echo "0")
        echo "  Total indexed IPs: $total_indexed"
        echo "  File: $FAIL2BAN_SEARCH_IPS"
        
        local last_update
        last_update=$(stat -c '%y' "$FAIL2BAN_SEARCH_IPS" 2>/dev/null | cut -d'.' -f1)
        echo "  Last updated: $last_update"
        echo ""
    fi
    
    # Recent activity (last 10)
    echo -e "${CYAN}Recent Activity (last 10):${NC}"
    tail -10 "$BAN_LOG" | while IFS='|' read -r timestamp ip jail action reason geoip whois; do
        local action_color=""
        case "$action" in
            BANNED) action_color="${GREEN}" ;;
            WHITELISTED) action_color="${YELLOW}" ;;
            ALREADY_EXISTS) action_color="${BLUE}" ;;
            ERROR) action_color="${RED}" ;;
            RATE_EXCEEDED) action_color="${MAGENTA}" ;;
            PERMANENT_BAN) action_color="${MAGENTA}" ;;
            *) action_color="${NC}" ;;
        esac
        
        printf "  %s | %-15s | %-15s | " "$timestamp" "$ip" "$jail"
        echo -e "${action_color}${action}${NC}"
    done
    echo ""
    
    # Current bans in nftables
    echo -e "${CYAN}Current Active Bans (nftables):${NC}"
    if check_nftables_table_exists; then
        local total_v4 total_v6 perm_v4 perm_v6
        total_v4=$(nft list set inet "$NFT_TABLE" temp_ban_v4 2>/dev/null | grep -c "elements" || echo "0")
        total_v6=$(nft list set inet "$NFT_TABLE" temp_ban_v6 2>/dev/null | grep -c "elements" || echo "0")
        perm_v4=$(nft list set inet "$NFT_TABLE" user_blacklist_v4 2>/dev/null | grep -c "elements" || echo "0")
        perm_v6=$(nft list set inet "$NFT_TABLE" user_blacklist_v6 2>/dev/null | grep -c "elements" || echo "0")
        
        echo "  Temporary Bans:"
        echo "    IPv4: $total_v4 banned IPs"
        echo "    IPv6: $total_v6 banned IPs"
        echo "  Permanent Bans:"
        echo "    IPv4: $perm_v4 banned IPs"
        echo "    IPv6: $perm_v6 banned IPs"
    else
        echo "  nftables table not found"
    fi
    echo ""
    
    # Persistent blacklist info
    if [ -f "$FAIL2BAN_TEMP_IPS" ]; then
        local perm_count
        perm_count=$(grep -cE "^[0-9a-fA-F.:]+[[:space:]]" "$FAIL2BAN_TEMP_IPS" 2>/dev/null || echo "0")
        if [ "$perm_count" -gt 0 ]; then
            echo -e "${CYAN}Persistent Blacklist:${NC}"
            echo "  Total permanently banned: $perm_count IPs"
            echo "  File: $FAIL2BAN_TEMP_IPS"
            echo "  View with: --list-permanent"
            echo ""
        fi
    fi
    
    # Top repeat offenders
    echo -e "${CYAN}Top 10 Repeat Offenders:${NC}"
    local threshold
    threshold=$(get_config_value "PERSISTENT_BAN_THRESHOLD" "3")
    awk -F'|' '$4 == "BANNED" {print $2}' "$BAN_LOG" | sort | uniq -c | sort -rn | head -10 | while read -r count ip; do
        if [ "$count" -ge "$threshold" ]; then
            printf "  ${RED}%-18s %s (>= threshold: %s)${NC}\n" "$ip" "$count bans" "$threshold"
        else
            printf "  %-18s %s\n" "$ip" "$count bans"
        fi
    done
    echo ""
    
    echo "==============================================="
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================
show_jail_menu() {
    local os
    os=$(detect_os)
    log_info "Detected OS: $os"
    
    echo ""
    echo "==============================================="
    echo "  nftban Fail2ban Jail Manager"
    echo "==============================================="
    echo ""
    
    local -a jails
    mapfile -t jails < <(get_available_jails "$os")
    
    if [ ${#jails[@]} -eq 0 ]; then
        log_error "No jails found for OS: $os"
        return 1
    fi
    
    echo "Available Jails:"
    echo ""
    printf "%-5s %-20s %-10s %-15s %-10s %-10s\n" "No." "Jail Name" "Status" "Ban Time" "Max Retry" "Find Time"
    echo "--------------------------------------------------------------------------------"
    
    local i=1
    for jail in "${jails[@]}"; do
        local status ban_time max_retry find_time
        status=$(get_jail_status "$jail")
        ban_time=$(get_jail_config "$jail" "BAN_TIME" "N/A")
        max_retry=$(get_jail_config "$jail" "MAX_RETRY" "N/A")
        find_time=$(get_jail_config "$jail" "FIND_TIME" "N/A")
        
        local status_color=""
        if [ "$status" == "true" ]; then
            status_color="${GREEN}ENABLED${NC}"
        else
            status_color="${RED}DISABLED${NC}"
        fi
        
        printf "%-5s %-20s " "$i" "$jail"
        echo -en "$status_color"
        printf " %-15s %-10s %-10s\n" "${ban_time}s" "$max_retry" "${find_time}s"
        ((i++))
    done
    
    echo ""
    echo "Options:"
    echo "  [number]     - Toggle jail on/off"
    echo "  a            - Enable all jails"
    echo "  d            - Disable all jails"
    echo "  c            - Configure jail settings"
    echo "  r            - Reload fail2ban"
    echo "  q            - Quit"
    echo ""
    
    read -rp "Select option: " choice
    
    case "$choice" in
        q|Q)
            return 0
            ;;
        a|A)
            for jail in "${jails[@]}"; do
                deploy_jail "$jail" "$os"
            done
            systemctl reload fail2ban
            log_success "All jails enabled and fail2ban reloaded"
            ;;
        d|D)
            for jail in "${jails[@]}"; do
                remove_jail "$jail"
            done
            systemctl reload fail2ban
            log_success "All jails disabled and fail2ban reloaded"
            ;;
        c|C)
            configure_jail_interactive "${jails[@]}"
            ;;
        r|R)
            systemctl reload fail2ban
            log_success "fail2ban reloaded"
            ;;
        [0-9]*)
            if [ "$choice" -ge 1 ] && [ "$choice" -le ${#jails[@]} ]; then
                local jail="${jails[$((choice-1))]}"
                local status
                status=$(get_jail_status "$jail")
                
                if [ "$status" == "true" ]; then
                    remove_jail "$jail"
                else
                    deploy_jail "$jail" "$os"
                fi
                systemctl reload fail2ban
            else
                log_error "Invalid selection"
            fi
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
    
    read -rp "Press Enter to continue..." _dummy
    show_jail_menu
}

configure_jail_interactive() {
    local jails=("$@")
    
    echo ""
    echo "Select jail to configure:"
    local i=1
    for jail in "${jails[@]}"; do
        echo "  $i) $jail"
        ((i++))
    done
    echo "  q) Back"
    echo ""
    
    read -rp "Select jail: " choice
    
    if [[ "$choice" =~ ^[qQ]$ ]]; then
        return 0
    fi
    
    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#jails[@]} ]; then
        local jail="${jails[$((choice-1))]}"
        
        echo ""
        echo "Configuring: $jail"
        echo "Current values:"
        echo "  Ban Time: $(get_jail_config "$jail" "BAN_TIME" "3600")s"
        echo "  Max Retry: $(get_jail_config "$jail" "MAX_RETRY" "5")"
        echo "  Find Time: $(get_jail_config "$jail" "FIND_TIME" "600")s"
        echo ""
        
        read -rp "Enter new Ban Time (seconds) [press Enter to skip]: " ban_time
        read -rp "Enter new Max Retry [press Enter to skip]: " max_retry
        read -rp "Enter new Find Time (seconds) [press Enter to skip]: " find_time
        
        [ -n "$ban_time" ] && set_jail_config "$jail" "BAN_TIME" "$ban_time"
        [ -n "$max_retry" ] && set_jail_config "$jail" "MAX_RETRY" "$max_retry"
        [ -n "$find_time" ] && set_jail_config "$jail" "FIND_TIME" "$find_time"
        
        log_success "Configuration updated for $jail"
        
        # If jail is enabled, redeploy it
        local jail_status
        jail_status=$(get_jail_status "$jail")
        if [ "$jail_status" == "true" ]; then
            local os
            os=$(detect_os)
            deploy_jail "$jail" "$os"
            systemctl reload fail2ban
            log_success "Jail redeployed with new settings"
        fi
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

INSTALLATION & TEMPLATES:
    --install               Install nftban fail2ban templates and configs
    --uninstall             Uninstall nftban fail2ban templates and configs  
    --update-templates      Update templates from local or Git repository

BAN OPERATIONS:
    --ban IP JAIL [TIME]        Ban an IP address
    --check-ip IP               Check if IP is whitelisted or banned
    --create-whitelist          Create consolidated whitelist

CONSOLIDATED SEARCH:
    --rebuild-search            Rebuild consolidated IP search file
    --search-ip IP              Search IP in consolidated file

PERSISTENT BLACKLIST:
    --list-permanent            List permanently banned IPs
    --add-permanent IP REASON   Add IP to persistent blacklist
    --remove-permanent IP       Remove IP from persistent blacklist
    --sync-permanent            Sync persistent blacklist to nftables

JAIL MANAGEMENT:
    --update-jails              Interactive jail management menu
    --enable-jail JAIL          Enable specific jail
    --disable-jail JAIL         Disable specific jail
    --list-jails                List all available jails
    --config-jail JAIL          Show configuration for jail

TESTING:
    --test-config               Test system configuration
    --test-jail JAIL            Test specific jail
    --test-email                Send test email

STATISTICS:
    --stats                     Show statistics dashboard
    --show-rate                 Show current ban rate
    --reset-rate                Reset rate limit tracker

MISC:
    --help                      Show this help

CONFIGURATION (in nftban.conf.local):
    NFTBAN_F2B_ALERT_ENABLED="true"
    NFTBAN_F2B_GEOIP_ENABLE="true"
    NFTBAN_F2B_WHOIS_ENABLE="true"
    NFTBAN_F2B_RECIPIENT="admin@example.com"
    BAN_RATE_LIMIT_PER_MINUTE="10"
    PERSISTENT_BAN_THRESHOLD="3"
    NFTBAN_GIT_REPO="https://github.com/user/nftban-templates.git"
    NFTBAN_GIT_BRANCH="main"

EXAMPLES:
    # Install templates and configurations
    $(basename "$0") --install
    
    # Update templates from Git repository
    $(basename "$0") --update-templates
    
    # Enable a specific jail
    $(basename "$0") --enable-jail SSHD
    
    # Ban an IP address
    $(basename "$0") --ban 192.0.2.1 sshd 3600
    
    # Rebuild consolidated search file
    $(basename "$0") --rebuild-search
    
    # Show statistics
    $(basename "$0") --stats

EOF
}

# Main script
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Create necessary directories
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$DATA_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$BAN_LOG")"
    touch "$LOG_FILE" "$BAN_LOG" "$STATS_DB"
    
    # Parse arguments
    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    case "$1" in
        --install)
            install_nftban_fail2ban
            ;;
        
        --uninstall)
            uninstall_nftban_fail2ban
            ;;
        
        --update-templates)
            update_templates
            ;;
        
        --ban)
            if [ $# -lt 3 ]; then
                log_error "Missing arguments for --ban"
                show_usage
                exit 1
            fi
            
            local ip="$2"
            local jail_name="$3"
            local ban_time="${4:-}"
            
            # Get ban time from config if not specified
            if [ -z "$ban_time" ]; then
                ban_time=$(get_jail_config "$jail_name" "BAN_TIME" "$DEFAULT_BAN_TIME")
            fi
            
            process_ban "$ip" "$jail_name" "$ban_time"
            ;;
        
        --create-whitelist|--create-wl)
            create_consolidated_whitelist
            ;;
        
        --rebuild-search)
            build_consolidated_search_file
            ;;
        
        --search-ip)
            if [ $# -lt 2 ]; then
                log_error "Missing IP address"
                exit 1
            fi
            
            local ip="$2"
            log_info "Searching for IP: $ip"
            
            local result
            result=$(search_ip_in_consolidated "$ip" 2>/dev/null || true)
            
            if [ -n "$result" ]; then
                echo ""
                echo "IP Found in Consolidated Search:"
                echo "$result" | while IFS='|' read -r found_ip source type; do
                    echo "  IP: $found_ip"
                    echo "  Source: $source"
                    echo "  Type: $type"
                done
                echo ""
            else
                echo ""
                echo "IP not found in consolidated search file"
                echo ""
            fi
            ;;
        
        --list-permanent|--list-blacklist)
            list_persistent_blacklist
            ;;
        
        --add-permanent|--add-blacklist)
            if [ $# -lt 3 ]; then
                log_error "Missing arguments for --add-permanent"
                echo "Usage: --add-permanent <IP> <REASON>"
                exit 1
            fi
            add_to_persistent_blacklist "$2" "$3"
            log_success "Added $2 to persistent blacklist"
            ;;
        
        --remove-permanent|--remove-blacklist)
            if [ $# -lt 2 ]; then
                log_error "Missing IP address"
                exit 1
            fi
            remove_from_persistent_blacklist "$2"
            ;;
        
        --sync-permanent|--sync-blacklist)
            sync_persistent_blacklist_to_nftables
            ;;
        
        --check-ip)
            if [ $# -lt 2 ]; then
                log_error "Missing IP address"
                exit 1
            fi
            log_info "Checking IP: $2"
            echo ""
            echo "IP: $2"
            get_ip_info "$2"
            echo ""
            
            # Check in consolidated search
            echo "Consolidated Search:"
            local search_result
            search_result=$(search_ip_in_consolidated "$2" 2>/dev/null || true)
            if [ -n "$search_result" ]; then
                echo "$search_result" | while IFS='|' read -r found_ip source type; do
                    echo "  Found in: $source ($type)"
                done
            else
                echo "  Not found in consolidated search"
            fi
            echo ""
            
            if check_ip_in_whitelist_files "$2"; then
                echo -e "${YELLOW}Status: WHITELISTED${NC}"
            elif check_ip_in_persistent_blacklist "$2"; then
                echo -e "${MAGENTA}Status: PERMANENTLY BANNED (Persistent Blacklist)${NC}"
            elif check_ip_in_nftables "$2"; then
                echo -e "${RED}Status: EXISTS IN NFTABLES${NC}"
            else
                echo -e "${GREEN}Status: NOT FOUND (can be banned)${NC}"
            fi
            
            # Show ban history
            if [ -f "$BAN_LOG" ]; then
                local ban_count
                ban_count=$(grep -c "|$2|" "$BAN_LOG" 2>/dev/null || echo "0")
                echo ""
                echo "Ban History: $ban_count attempts"
                if [ "$ban_count" -gt 0 ]; then
                    echo "Recent attempts:"
                    grep "|$2|" "$BAN_LOG" | tail -5 | while IFS='|' read -r timestamp ip jail action rest; do
                        echo "  $timestamp | $jail | $action"
                    done
                fi
            fi
            ;;
        
        --update-jails|--manage-jails)
            show_jail_menu
            ;;
        
        --enable-jail)
            if [ $# -lt 2 ]; then
                log_error "Missing jail name"
                exit 1
            fi
            local os
            os=$(detect_os)
            deploy_jail "$2" "$os"
            systemctl reload fail2ban
            ;;
        
        --disable-jail)
            if [ $# -lt 2 ]; then
                log_error "Missing jail name"
                exit 1
            fi
            remove_jail "$2"
            systemctl reload fail2ban
            ;;
        
        --list-jails)
            local os
            os=$(detect_os)
            log_info "Available jails for $os:"
            echo ""
            printf "%-20s %-10s %-15s %-10s %-10s\n" "Jail Name" "Status" "Ban Time" "Max Retry" "Find Time"
            echo "------------------------------------------------------------------------"
            
            while IFS= read -r jail; do
                local status ban_time max_retry find_time
                status=$(get_jail_status "$jail")
                ban_time=$(get_jail_config "$jail" "BAN_TIME" "N/A")
                max_retry=$(get_jail_config "$jail" "MAX_RETRY" "N/A")
                find_time=$(get_jail_config "$jail" "FIND_TIME" "N/A")
                printf "%-20s %-10s %-15s %-10s %-10s\n" "$jail" "$status" "${ban_time}s" "$max_retry" "${find_time}s"
            done < <(get_available_jails "$os")
            ;;
        
        --config-jail)
            if [ $# -lt 2 ]; then
                log_error "Missing jail name"
                exit 1
            fi
            local jail="$2"
            
            echo "Configuration for $jail:"
            echo "  Enabled: $(get_jail_config "$jail" "JAIL" "false")"
            echo "  Ban Time: $(get_jail_config "$jail" "BAN_TIME" "N/A")s"
            echo "  Max Retry: $(get_jail_config "$jail" "MAX_RETRY" "N/A")"
            echo "  Find Time: $(get_jail_config "$jail" "FIND_TIME" "N/A")s"
            ;;
        
        --test-config)
            test_configuration
            ;;
        
        --test-jail)
            if [ $# -lt 2 ]; then
                log_error "Missing jail name"
                exit 1
            fi
            test_jail "$2"
            ;;
        
        --test-email)
            test_email
            ;;
        
        --stats|--statistics|--dashboard)
            show_statistics
            ;;
        
        --show-rate)
            log_info "Current ban rate:"
            local current_time one_minute_ago five_minutes_ago
            current_time=$(date +%s)
            one_minute_ago=$((current_time - 60))
            five_minutes_ago=$((current_time - 300))
            
            if [ -f "$RATE_LIMIT_TRACKER" ]; then
                local rate_1min rate_5min rate_limit
                rate_1min=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
                rate_5min=$(awk -v cutoff="$five_minutes_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
                rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "not set")
                
                echo ""
                echo "Ban Rate Statistics:"
                echo "  Last 1 minute:  $rate_1min bans"
                echo "  Last 5 minutes: $rate_5min bans (avg: $((rate_5min / 5))/min)"
                echo "  Rate Limit:     $rate_limit per minute"
                echo ""
                
                if [ "$rate_limit" != "not set" ] && [ "$rate_limit" != "0" ]; then
                    if [ "$rate_1min" -gt "$rate_limit" ]; then
                        echo -e "${RED}Status: RATE LIMIT EXCEEDED${NC}"
                    elif [ "$rate_1min" -gt $((rate_limit / 2)) ]; then
                        echo -e "${YELLOW}Status: Approaching limit${NC}"
                    else
                        echo -e "${GREEN}Status: Normal${NC}"
                    fi
                fi
            else
                echo "No rate tracking data available"
            fi
            ;;
        
        --reset-rate)
            reset_rate_limit_tracker
            log_success "Rate limit tracker has been reset"
            ;;
        
        --help|-h)
            show_usage
            ;;
        
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
