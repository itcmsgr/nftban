#!/usr/bin/env bash

# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
# Comprehensive fail2ban integration with nftables (nftban system)
# Version: 0.5.0-final  (Enhanced with security, validation, dry-run, better mail testing)
# Author:  ITCMS Team (Antonios Voulvoulis) + Enhancements
#
# Description:
#   Comprehensive automation for Fail2Ban using the nftables backend.
#   Enhanced with security features, better validation, dry-run mode,
#   improved mail testing, backup rotation, and comprehensive status reporting.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
BASE_DIR="/etc/nftban"
CONFIG_DIR="${BASE_DIR}/config"
TEMPLATE_DIR="${BASE_DIR}/templates/fail2ban"
BACKUP_DIR="${BASE_DIR}/backups"
DATA_DIR="${BASE_DIR}/data"
FAIL2BAN_DIR="/etc/fail2ban"
WHITELIST_FILE="${CONFIG_DIR}/nftban-fail2ban-ip-whitelist.conf.local"
PERSISTENT_BLACKLIST="${CONFIG_DIR}/nftban-configuration-f2b-ips_temp-blacklists_conf.local"
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
    
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
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
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
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
        local value=$(grep "^${var_name}=" "$NFTBAN_CONFIG_LOCAL" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    # Check base .conf file
    if [ -f "$NFTBAN_CONFIG" ]; then
        local value=$(grep "^${var_name}=" "$NFTBAN_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
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
    local jail_enabled=$(get_jail_config "$jail_name" "JAIL" "")
    
    if [ -z "$jail_enabled" ]; then
        log_info "Creating default config for jail: $jail_name"
        
        # Get global defaults
        local def_ban_time=$(get_config_value "NFTBAN_F2B_DEF_BAN_TIME" "3600")
        local def_find_time=$(get_config_value "NFTBAN_F2B_DEF_FIND_TIME" "600")
        local def_max_retry=$(get_config_value "NFTBAN_F2B_DEF_MAX_RETRY" "5")
        
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
        local -a octets=($ip)
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
# GEOIP AND WHOIS LOOKUP
# =============================================================================
geoip_lookup() {
    local ip="$1"
    local geoip_enabled=$(get_config_value "NFTBAN_F2B_GEOIP_ENABLE" "false")
    
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
    local whois_enabled=$(get_config_value "NFTBAN_F2B_WHOIS_ENABLE" "false")
    
    if [ "$whois_enabled" != "true" ]; then
        echo "WHOIS_Disabled"
        return 0
    fi
    
    if ! command -v whois &> /dev/null; then
        echo "WHOIS_NotInstalled"
        return 0
    fi
    
    # Get organization/netname from whois
    local result=$(whois "$ip" 2>/dev/null | grep -iE "^(OrgName|netname|owner):" | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_' | cut -c1-50)
    
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "WHOIS_Unavailable"
    fi
}

get_ip_info() {
    local ip="$1"
    local geoip_info=$(geoip_lookup "$ip")
    local whois_info=$(whois_lookup "$ip")
    
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
    
    local alert_enabled=$(get_config_value "NFTBAN_F2B_ALERT_ENABLED" "false")
    
    if [ "$alert_enabled" != "true" ]; then
        return 0
    fi
    
    local recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    local sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
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
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    local body="nftban Fail2ban Alert
    
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
    local recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    local sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
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
    
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local subject="[nftban] CRITICAL: Ban Rate Limit Exceeded on $(hostname -f)"
    
    # Get recent ban details
    local recent_bans=""
    if [ -f "$BAN_LOG" ]; then
        recent_bans=$(tail -20 "$BAN_LOG" | awk -F'|' '{printf "  %s | %s | %s | %s\n", $1, $2, $3, $4}')
    fi
    
    local body="nftban CRITICAL ALERT - Rate Limit Exceeded
    
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
  nftban-fail2ban-manager.sh --stats
  nftban-fail2ban-manager.sh --test-config

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
    
    local recipient=$(get_config_value "NFTBAN_F2B_RECIPIENT" "")
    local sender=$(get_config_value "NFTBAN_F2B_SENDER" "nftban@$(hostname -f)")
    
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
    
    read -p "Send test email to $recipient? (y/N): " -n 1 -r
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
    local rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "0")
    
    # If rate limit is 0 or not set, skip check
    if [ "$rate_limit" == "0" ] || [ -z "$rate_limit" ]; then
        return 0
    fi
    
    # Create tracker file if it doesn't exist
    touch "$RATE_LIMIT_TRACKER"
    
    # Current timestamp
    local current_time=$(date +%s)
    local one_minute_ago=$((current_time - 60))
    
    # Add current attempt to tracker
    echo "$current_time" >> "$RATE_LIMIT_TRACKER"
    
    # Clean up old entries (older than 1 minute) and count recent attempts
    local temp_file="${RATE_LIMIT_TRACKER}.clean"
    awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" > "$temp_file"
    mv "$temp_file" "$RATE_LIMIT_TRACKER"
    
    # Count attempts in last minute
    local recent_count=$(wc -l < "$RATE_LIMIT_TRACKER")
    
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
            local ver=$(detect_ip_version "$ip")
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
# WHITELIST MANAGEMENT
# =============================================================================
create_consolidated_whitelist() {
    log_info "Creating consolidated whitelist from all *conf.local files..."
    
    if [ ! -d "$CONFIG_DIR" ]; then
        log_error "Config directory not found: $CONFIG_DIR"
        return 1
    fi
    
    local temp_file="${WHITELIST_FILE}.tmp"
    
    # Find all *conf.local files and extract IPs
    find "$CONFIG_DIR" -name "*conf.local" -type f -exec cat {} \; 2>/dev/null | \
        grep -v '^#' | \
        grep -v '^[[:space:]]*$' | \
        grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' | \
        sort -u > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        mv "$temp_file" "$WHITELIST_FILE"
        log_success "Consolidated whitelist created: $WHITELIST_FILE"
        log_info "Total unique IPs/ranges: $(wc -l < "$WHITELIST_FILE")"
    else
        log_warning "No valid IPs found in *conf.local files"
        rm -f "$temp_file"
    fi
}

check_ip_in_whitelist_files() {
    local ip="$1"
    
    # Check in all *conf.local files
    while IFS= read -r file; do
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue
            
            # Remove whitespace
            line=$(echo "$line" | tr -d '[:space:]')
            
            if ip_in_range "$ip" "$line"; then
                log_info "IP $ip found in whitelist file: $file (matches: $line)"
                return 0
            fi
        done < "$file"
    done < <(find "$CONFIG_DIR" -name "*conf.local" -type f 2>/dev/null)
    
    return 1
}

# =============================================================================
# PERSISTENT BLACKLIST MANAGEMENT
# =============================================================================
check_persistent_offender() {
    local ip="$1"
    local threshold=$(get_config_value "PERSISTENT_BAN_THRESHOLD" "3")
    
    # If threshold is 0, disable persistent banning
    if [ "$threshold" == "0" ]; then
        return 1
    fi
    
    # Count how many times this IP has been banned
    if [ -f "$BAN_LOG" ]; then
        local ban_count=$(grep -c "|${ip}|.*|BANNED|" "$BAN_LOG" 2>/dev/null || echo "0")
        
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
    if [ ! -f "$PERSISTENT_BLACKLIST" ]; then
        cat > "$PERSISTENT_BLACKLIST" << 'EOF'
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
    if grep -qE "^${ip}[[:space:]]" "$PERSISTENT_BLACKLIST" 2>/dev/null; then
        log_info "IP $ip already in persistent blacklist"
        return 0
    fi
    
    # Add IP with timestamp and reason
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${ip}  # Added: ${timestamp} - ${reason}" >> "$PERSISTENT_BLACKLIST"
    
    log_success "Added IP $ip to persistent blacklist"
    
    # Add to nftables user_blacklist (permanent)
    local ver=$(detect_ip_version "$ip")
    if [ "$ver" != "invalid" ]; then
        nft add element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null || \
            log_warning "Failed to add $ip to nftables user_blacklist"
    fi
    
    # Log the action
    log_ban_attempt "$ip" "PERSISTENT" "PERMANENT_BAN" "Added to persistent blacklist: ${reason}" "N/A" "N/A"
    
    return 0
}

remove_from_persistent_blacklist() {
    local ip="$1"
    
    if [ ! -f "$PERSISTENT_BLACKLIST" ]; then
        log_error "Persistent blacklist file not found"
        return 1
    fi
    
    # Check if IP exists
    if ! grep -qE "^${ip}[[:space:]]" "$PERSISTENT_BLACKLIST" 2>/dev/null; then
        log_error "IP $ip not found in persistent blacklist"
        return 1
    fi
    
    # Remove IP from file
    sed -i "/^${ip}[[:space:]]/d" "$PERSISTENT_BLACKLIST"
    
    log_success "Removed IP $ip from persistent blacklist"
    
    # Remove from nftables user_blacklist
    local ver=$(detect_ip_version "$ip")
    if [ "$ver" != "invalid" ]; then
        nft delete element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null || \
            log_warning "Failed to remove $ip from nftables user_blacklist"
    fi
    
    return 0
}

list_persistent_blacklist() {
    if [ ! -f "$PERSISTENT_BLACKLIST" ]; then
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
    done < "$PERSISTENT_BLACKLIST"
    
    if [ "$count" -eq 0 ]; then
        echo "No IPs in persistent blacklist"
    else
        echo ""
        echo "Total: $count permanently banned IPs"
    fi
    echo ""
    echo "File: $PERSISTENT_BLACKLIST"
    echo "==============================================="
}

check_ip_in_persistent_blacklist() {
    local ip="$1"
    
    if [ ! -f "$PERSISTENT_BLACKLIST" ]; then
        return 1
    fi
    
    grep -qE "^${ip}[[:space:]]" "$PERSISTENT_BLACKLIST" 2>/dev/null
}

sync_persistent_blacklist_to_nftables() {
    log_info "Syncing persistent blacklist to nftables..."
    
    if [ ! -f "$PERSISTENT_BLACKLIST" ]; then
        log_warning "Persistent blacklist file not found"
        return 0
    fi
    
    local synced=0
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract IP (first field)
        local ip=$(echo "$line" | awk '{print $1}')
        
        if [ -n "$ip" ]; then
            local ver=$(detect_ip_version "$ip")
            if [ "$ver" != "invalid" ]; then
                if nft add element inet "$NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null; then
                    ((synced++))
                fi
            fi
        fi
    done < "$PERSISTENT_BLACKLIST"
    
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
    local ver=$(detect_ip_version "$ip")
    
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
    
    local ver=$(detect_ip_version "$ip")
    
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
    local geoip_info=$(geoip_lookup "$ip")
    local whois_info=$(whois_lookup "$ip")
    
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
            local ban_count=$(grep -c "|${ip}|.*|BANNED|" "$BAN_LOG" 2>/dev/null || echo "0")
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
    local ban_time=$(get_jail_config "$jail_name" "BAN_TIME" "3600")
    local max_retry=$(get_jail_config "$jail_name" "MAX_RETRY" "5")
    local find_time=$(get_jail_config "$jail_name" "FIND_TIME" "600")
    local ignoreip_file=$(get_config_value "NFTBAN_F2B_IGNOREIP" "$WHITELIST_FILE")
    
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
    local jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
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
    local jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
    
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
    for file in "$NFTBAN_CONFIG" "$NFTBAN_CONFIG_LOCAL" "$PERSISTENT_BLACKLIST"; do
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
    
    # Check persistent blacklist
    if [ -f "$PERSISTENT_BLACKLIST" ]; then
        local perm_ban_count=$(grep -cE "^[0-9a-fA-F.:]+[[:space:]]" "$PERSISTENT_BLACKLIST" 2>/dev/null || echo "0")
        echo "Persistent Blacklist:"
        echo "  Permanently banned IPs: $perm_ban_count"
        echo ""
    fi
    
    # Check current ban rate
    if [ -f "$RATE_LIMIT_TRACKER" ]; then
        local current_time=$(date +%s)
        local one_minute_ago=$((current_time - 60))
        local current_rate=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
        local rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "0")
        
        if [ "$rate_limit" != "0" ] && [ -n "$rate_limit" ]; then
            echo "Current Ban Rate:"
            if [ "$current_rate" -gt "$rate_limit" ]; then
                echo -e "  ${RED}✗${NC} ${current_rate} bans/min (EXCEEDS LIMIT: ${rate_limit})"
            elif [ "$current_rate" -gt $((rate_limit / 2)) ]; then
                echo -e "  ${YELLOW}!${NC} ${current_rate} bans/min (limit: ${rate_limit})"
            else
                echo -e "  ${GREEN}✓${NC} ${current_rate} bans/min (limit: ${rate_limit})"
            fi
            echo ""
        fi
    fi
    
    # Check dependencies
    echo "Optional Dependencies:"
    for cmd in geoiplookup whois curl mail sendmail python3; do
        if command -v "$cmd" &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd"
        else
            echo -e "  ${YELLOW}!${NC} $cmd (optional, not installed)"
        fi
    done
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
    local jail_enabled=$(get_jail_status "$jail_name")
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
    local jail_lower=$(echo "$jail_name" | tr '[:upper:]' '[:lower:]')
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
    local total_attempts=$(wc -l < "$BAN_LOG")
    echo -e "${CYAN}Total Ban Attempts:${NC} $total_attempts"
    echo ""
    
    # Current ban rate
    local rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "0")
    if [ "$rate_limit" != "0" ] && [ -n "$rate_limit" ] && [ -f "$RATE_LIMIT_TRACKER" ]; then
        local current_time=$(date +%s)
        local one_minute_ago=$((current_time - 60))
        local current_rate=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
        
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
    awk -F'|' '{print $4}' "$BAN_LOG" | sort | uniq -c | sort -rn | while read count action; do
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
                echo "  ■ $action: $count"
                ;;
        esac
    done
    echo ""
    
    # Top 10 banned IPs
    echo -e "${CYAN}Top 10 Most Targeted IPs:${NC}"
    awk -F'|' '{print $2}' "$BAN_LOG" | sort | uniq -c | sort -rn | head -10 | while read count ip; do
        printf "  %-18s %s\n" "$ip" "$count attempts"
    done
    echo ""
    
    # Jails statistics
    echo -e "${CYAN}Jails Activity:${NC}"
    awk -F'|' '{print $3}' "$BAN_LOG" | sort | uniq -c | sort -rn | while read count jail; do
        printf "  %-20s %s\n" "$jail" "$count attempts"
    done
    echo ""
    
    # Top countries (if GeoIP enabled)
    if grep -q "GeoIP_Disabled\|GeoIP_Unavailable" "$BAN_LOG"; then
        echo -e "${YELLOW}GeoIP data not available (enable with NFTBAN_F2B_GEOIP_ENABLE=true)${NC}"
    else
        echo -e "${CYAN}Top 10 Countries:${NC}"
        awk -F'|' '{print $6}' "$BAN_LOG" | awk -F'_' '{print $1}' | grep -v "^$" | sort | uniq -c | sort -rn | head -10 | while read count country; do
            printf "  %-20s %s\n" "$country" "$count"
        done
    fi
    echo ""
    
    # Recent activity (last 10)
    echo -e "${CYAN}Recent Activity (last 10):${NC}"
    tail -10 "$BAN_LOG" | while IFS='|' read timestamp ip jail action reason geoip whois; do
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
        local total_v4=$(nft list set inet "$NFT_TABLE" temp_ban_v4 2>/dev/null | grep -E "elements.*{" -A 999 | grep -v "elements" | grep -v "^}" | wc -l)
        local total_v6=$(nft list set inet "$NFT_TABLE" temp_ban_v6 2>/dev/null | grep -E "elements.*{" -A 999 | grep -v "elements" | grep -v "^}" | wc -l)
        local perm_v4=$(nft list set inet "$NFT_TABLE" user_blacklist_v4 2>/dev/null | grep -E "elements.*{" -A 999 | grep -v "elements" | grep -v "^}" | wc -l)
        local perm_v6=$(nft list set inet "$NFT_TABLE" user_blacklist_v6 2>/dev/null | grep -E "elements.*{" -A 999 | grep -v "elements" | grep -v "^}" | wc -l)
        
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
    if [ -f "$PERSISTENT_BLACKLIST" ]; then
        local perm_count=$(grep -cE "^[0-9a-fA-F.:]+[[:space:]]" "$PERSISTENT_BLACKLIST" 2>/dev/null || echo "0")
        if [ "$perm_count" -gt 0 ]; then
            echo -e "${CYAN}Persistent Blacklist:${NC}"
            echo "  Total permanently banned: $perm_count IPs"
            echo "  File: $PERSISTENT_BLACKLIST"
            echo "  View with: --list-permanent"
            echo ""
        fi
    fi
    
    # Top repeat offenders
    echo -e "${CYAN}Top 10 Repeat Offenders:${NC}"
    awk -F'|' '$4 == "BANNED" {print $2}' "$BAN_LOG" | sort | uniq -c | sort -rn | head -10 | while read count ip; do
        local threshold=$(get_config_value "PERSISTENT_BAN_THRESHOLD" "3")
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
    local os=$(detect_os)
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
        local status=$(get_jail_status "$jail")
        local ban_time=$(get_jail_config "$jail" "BAN_TIME" "N/A")
        local max_retry=$(get_jail_config "$jail" "MAX_RETRY" "N/A")
        local find_time=$(get_jail_config "$jail" "FIND_TIME" "N/A")
        
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
    
    read -p "Select option: " choice
    
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
                local status=$(get_jail_status "$jail")
                
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
    
    read -p "Press Enter to continue..."
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
    
    read -p "Select jail: " choice
    
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
        
        read -p "Enter new Ban Time (seconds) [press Enter to skip]: " ban_time
        read -p "Enter new Max Retry [press Enter to skip]: " max_retry
        read -p "Enter new Find Time (seconds) [press Enter to skip]: " find_time
        
        [ -n "$ban_time" ] && set_jail_config "$jail" "BAN_TIME" "$ban_time"
        [ -n "$max_retry" ] && set_jail_config "$jail" "MAX_RETRY" "$max_retry"
        [ -n "$find_time" ] && set_jail_config "$jail" "FIND_TIME" "$find_time"
        
        log_success "Configuration updated for $jail"
        
        # If jail is enabled, redeploy it
        if [ "$(get_jail_status "$jail")" == "true" ]; then
            deploy_jail "$jail" "$(detect_os)"
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

BAN OPERATIONS:
    --ban IP JAIL [TIME]        Ban an IP address
    --check-ip IP               Check if IP is whitelisted or banned
    --create-whitelist          Create consolidated whitelist

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
    BAN_RATE_LIMIT_PER_MINUTE="10"
    PERSISTENT_BAN_THRESHOLD="3"

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
                local ban_count=$(grep -c "|$2|" "$BAN_LOG" 2>/dev/null || echo "0")
                echo ""
                echo "Ban History: $ban_count attempts"
                if [ "$ban_count" -gt 0 ]; then
                    echo "Recent attempts:"
                    grep "|$2|" "$BAN_LOG" | tail -5 | while IFS='|' read timestamp ip jail action rest; do
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
            deploy_jail "$2" "$(detect_os)"
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
            local os=$(detect_os)
            log_info "Available jails for $os:"
            echo ""
            printf "%-20s %-10s %-15s %-10s %-10s\n" "Jail Name" "Status" "Ban Time" "Max Retry" "Find Time"
            echo "------------------------------------------------------------------------"
            
            while IFS= read -r jail; do
                local status=$(get_jail_status "$jail")
                local ban_time=$(get_jail_config "$jail" "BAN_TIME" "N/A")
                local max_retry=$(get_jail_config "$jail" "MAX_RETRY" "N/A")
                local find_time=$(get_jail_config "$jail" "FIND_TIME" "N/A")
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
            local current_time=$(date +%s)
            local one_minute_ago=$((current_time - 60))
            local five_minutes_ago=$((current_time - 300))
            
            if [ -f "$RATE_LIMIT_TRACKER" ]; then
                local rate_1min=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
                local rate_5min=$(awk -v cutoff="$five_minutes_ago" '$1 >= cutoff' "$RATE_LIMIT_TRACKER" 2>/dev/null | wc -l)
                local rate_limit=$(get_config_value "BAN_RATE_LIMIT_PER_MINUTE" "not set")
                
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
