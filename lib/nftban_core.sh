#!/usr/bin/env bash

# =============================================================================
# NFTBan Core Module - Enhanced with Security Safeguards
# Version: 2.2.0
# Author: ITCMS Team (Antonios Voulvoulis)
# =============================================================================

set -euo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CORE_LOADED:-}" ]] && return 0
readonly NFTBAN_CORE_LOADED=1

# =============================================================================
# PATHS & CONFIGURATION
# =============================================================================
readonly NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"
readonly NFTBAN_LIB_DIR="${NFTBAN_BASE_DIR}/lib"
readonly NFTBAN_CONFIG_DIR="${NFTBAN_BASE_DIR}/config"
readonly NFTBAN_DATA_DIR="${NFTBAN_BASE_DIR}/data"
readonly NFTBAN_CACHE_DIR="${NFTBAN_BASE_DIR}/cache"
readonly NFTBAN_LOG_DIR="/var/log/nftban"
readonly NFTBAN_TEMPLATE_DIR="${NFTBAN_BASE_DIR}/templates"

# Configuration files
readonly NFTBAN_MAIN_CONFIG="${NFTBAN_CONFIG_DIR}/nftban.conf"
readonly NFTBAN_LOCAL_CONFIG="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

# Logs
readonly NFTBAN_MAIN_LOG="${NFTBAN_LOG_DIR}/nftban.log"
readonly NFTBAN_BAN_LOG="${NFTBAN_LOG_DIR}/ban-history.log"
readonly NFTBAN_SYNC_LOG="${NFTBAN_LOG_DIR}/sync.log"
readonly NFTBAN_EMAIL_LOG="${NFTBAN_LOG_DIR}/email-notifications.log"

# Data files
readonly NFTBAN_RATE_LIMIT_TRACKER="${NFTBAN_DATA_DIR}/rate-limit-tracker.tmp"

# nftables
readonly NFTBAN_NFT_TABLE="${NFTBAN_NFT_TABLE:-nftban_global}"
readonly NFTBAN_NFT_FAMILY="${NFTBAN_NFT_FAMILY:-inet}"

# =============================================================================
# COLORS
# =============================================================================
readonly NFTBAN_RED='\033[0;31m'
readonly NFTBAN_GREEN='\033[0;32m'
readonly NFTBAN_YELLOW='\033[1;33m'
readonly NFTBAN_BLUE='\033[0;34m'
readonly NFTBAN_MAGENTA='\033[0;35m'
readonly NFTBAN_CYAN='\033[0;36m'
readonly NFTBAN_NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
nftban_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_MAIN_LOG")"
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$NFTBAN_MAIN_LOG"
}

nftban_log_error() {
    echo -e "${NFTBAN_RED}[ERROR]${NFTBAN_NC} $*" | tee -a "$NFTBAN_MAIN_LOG" >&2
}

nftban_log_success() {
    echo -e "${NFTBAN_GREEN}[SUCCESS]${NFTBAN_NC} $*" | tee -a "$NFTBAN_MAIN_LOG"
}

nftban_log_warning() {
    echo -e "${NFTBAN_YELLOW}[WARNING]${NFTBAN_NC} $*" | tee -a "$NFTBAN_MAIN_LOG"
}

nftban_log_info() {
    echo -e "${NFTBAN_BLUE}[INFO]${NFTBAN_NC} $*" | tee -a "$NFTBAN_MAIN_LOG"
}

nftban_log_debug() {
    local debug_enabled
    debug_enabled=$(nftban_get_config "DEBUG_ENABLED" "false")
    [[ "$debug_enabled" == "true" ]] && nftban_log "DEBUG" "$*"
}

# Special log for ban events
nftban_log_ban() {
    local ip="$1"
    local jail="$2"
    local action="$3"
    local reason="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_BAN_LOG")"
    echo "${timestamp}|${ip}|${jail}|${action}|${reason}" >> "$NFTBAN_BAN_LOG"
}

# =============================================================================
# DIRECTORY INITIALIZATION
# =============================================================================
nftban_init_directories() {
    local dirs=(
        "$NFTBAN_BASE_DIR"
        "$NFTBAN_LIB_DIR"
        "$NFTBAN_CONFIG_DIR"
        "$NFTBAN_DATA_DIR"
        "$NFTBAN_CACHE_DIR"
        "$NFTBAN_LOG_DIR"
        "$NFTBAN_TEMPLATE_DIR"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 755 "$dir"
            nftban_log_debug "Created directory: $dir"
        fi
    done
}

# =============================================================================
# CONFIGURATION MANAGEMENT
# =============================================================================
nftban_get_config() {
    local key="$1"
    local default="${2:-}"
    local value=""
    
    # Check .local first (highest priority)
    if [[ -f "$NFTBAN_LOCAL_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_LOCAL_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi
    
    # Check main config if not found
    if [[ -z "$value" && -f "$NFTBAN_MAIN_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_MAIN_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi
    
    # Return value or default
    echo "${value:-$default}"
}

nftban_set_config() {
    local key="$1"
    local value="$2"
    local file="${3:-$NFTBAN_LOCAL_CONFIG}"
    
    # Create file if doesn't exist
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        touch "$file"
    fi
    
    # Check if key exists
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Update existing
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    else
        # Add new
        echo "${key}=\"${value}\"" >> "$file"
    fi
    
    nftban_log_debug "Config set: ${key}=${value}"
}

nftban_load_config() {
    [[ -f "$NFTBAN_MAIN_CONFIG" ]] && source "$NFTBAN_MAIN_CONFIG"
    [[ -f "$NFTBAN_LOCAL_CONFIG" ]] && source "$NFTBAN_LOCAL_CONFIG"
}

# =============================================================================
# IP VALIDATION (Enhanced)
# =============================================================================
nftban_is_ipv4() {
    local ip="$1"
    
    # Check format
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    
    # Check octets
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    
    for octet in "${octets[@]}"; do
        ((octet > 255)) && return 1
    done
    
    return 0
}

nftban_is_ipv6() {
    local ip="$1"
    
    # Simplified IPv6 validation
    [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || \
    [[ $ip =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
    [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}:$ ]]
}

nftban_detect_ip_version() {
    local ip="$1"
    
    if nftban_is_ipv4 "$ip"; then
        echo "4"
    elif nftban_is_ipv6 "$ip"; then
        echo "6"
    else
        echo "invalid"
    fi
}

nftban_validate_ip() {
    local ip="$1"
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    if [[ "$ver" == "invalid" ]]; then
        nftban_log_error "Invalid IP address: $ip"
        return 1
    fi
    
    return 0
}

# =============================================================================
# CIDR CALCULATIONS (NEW - Enhanced)
# =============================================================================

# Convert IPv4 to integer
nftban_ip_to_int() {
    local ip="$1"
    local IFS='.'
    local -a octets=($ip)
    
    echo $(( (octets[0] << 24) + (octets[1] << 16) + (octets[2] << 8) + octets[3] ))
}

# Check if IP is within CIDR range (proper calculation)
nftban_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"
    
    # Only support IPv4 for now
    if ! nftban_is_ipv4 "$ip"; then
        return 1
    fi
    
    local network="${cidr%/*}"
    local prefix="${cidr#*/}"
    
    # Validate prefix
    if [[ ! "$prefix" =~ ^[0-9]+$ ]] || ((prefix < 0 || prefix > 32)); then
        return 1
    fi
    
    # Convert IPs to integers for comparison
    local ip_int network_int mask
    
    ip_int=$(nftban_ip_to_int "$ip")
    network_int=$(nftban_ip_to_int "$network")
    
    # Calculate netmask (proper calculation for any prefix)
    if [[ $prefix -eq 0 ]]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    
    # Check if IP is in range
    if [[ $(( ip_int & mask )) -eq $(( network_int & mask )) ]]; then
        return 0
    fi
    
    return 1
}

# =============================================================================
# IP LOCATION FINDER (NEW - Comprehensive Search)
# =============================================================================

nftban_find_ip_locations() {
    local ip="$1"
    local locations=()
    
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # Check nftables sets
    if nftban_check_nftables_table; then
        local sets=(
            "whitelist_v${ver}"
            "temp_ban_v${ver}"
            "user_blacklist_v${ver}"
            "system_blacklist_v${ver}"
            "feeds_v${ver}"
        )
        
        for set_name in "${sets[@]}"; do
            if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$set_name" 2>/dev/null | \
               grep -qE "(${ip}[[:space:],}]|${ip}$)"; then
                locations+=("nftables:${set_name}")
            fi
        done
    fi
    
    # Check whitelist files
    local whitelist_files=(
        "${NFTBAN_CONFIG_DIR}/whitelist-system.conf:whitelist-system"
        "${NFTBAN_CONFIG_DIR}/whitelist-user.conf:whitelist-user"
        "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf:whitelist-cloudflare"
    )
    
    for entry in "${whitelist_files[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        if [[ -f "$file" ]] && grep -qE "^${ip}([[:space:]]|$)" "$file"; then
            locations+=("file:${name}")
        fi
    done
    
    # Check blacklist files
    local blacklist_files=(
        "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf:blacklist-persistent"
        "${NFTBAN_CONFIG_DIR}/blacklist-user.conf:blacklist-user"
    )
    
    for entry in "${blacklist_files[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        if [[ -f "$file" ]] && grep -qE "^${ip}([[:space:]]|$)" "$file"; then
            locations+=("file:${name}")
        fi
    done
    
    # Check if it's a server IP
    if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
        locations+=("server:interface")
    fi
    
    # Check if it's current user IP
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_ip" && "$current_ip" == "$ip" ]]; then
        locations+=("server:current-user")
    fi
    
    # Return locations
    if [[ ${#locations[@]} -gt 0 ]]; then
        printf '%s\n' "${locations[@]}"
        return 0
    fi
    
    return 1
}

# =============================================================================
# IP INFORMATION GATHERING (GeoIP & WHOIS)
# =============================================================================
nftban_geoip_lookup() {
    local ip="$1"
    local geoip_enabled
    geoip_enabled=$(nftban_get_config "NFTBAN_GEOIP_ENABLE" "false")
    
    if [[ "$geoip_enabled" != "true" ]]; then
        echo "GeoIP_Disabled"
        return 0
    fi
    
    local result=""
    
    # Method 1: geoiplookup command
    if command -v geoiplookup &> /dev/null; then
        result=$(geoiplookup "$ip" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_')
    fi
    
    # Method 2: ip-api.com
    if [[ -z "$result" ]] && command -v curl &> /dev/null; then
        result=$(curl -s "http://ip-api.com/json/${ip}?fields=status,country,city,isp" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}\" if d.get('status')=='success' else 'Unknown')" 2>/dev/null)
    fi
    
    # Method 3: ipinfo.io fallback
    if [[ -z "$result" ]] && command -v curl &> /dev/null; then
        result=$(curl -s "https://ipinfo.io/${ip}/json" 2>/dev/null | \
                 python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('country','Unknown')}_{d.get('city','Unknown')}\")" 2>/dev/null)
    fi
    
    echo "${result:-GeoIP_Unavailable}"
}

nftban_whois_lookup() {
    local ip="$1"
    local whois_enabled
    whois_enabled=$(nftban_get_config "NFTBAN_WHOIS_ENABLE" "false")
    
    if [[ "$whois_enabled" != "true" ]]; then
        echo "WHOIS_Disabled"
        return 0
    fi
    
    if ! command -v whois &> /dev/null; then
        echo "WHOIS_NotInstalled"
        return 0
    fi
    
    local result
    result=$(whois "$ip" 2>/dev/null | grep -iE "^(OrgName|netname|owner):" | head -1 | cut -d: -f2- | tr -d ' ' | tr ',' '_' | cut -c1-50)
    
    echo "${result:-WHOIS_Unavailable}"
}

nftban_get_ip_info() {
    local ip="$1"
    local geoip whois
    geoip=$(nftban_geoip_lookup "$ip")
    whois=$(nftban_whois_lookup "$ip")
    
    echo "GeoIP: $geoip | WHOIS: $whois"
}

# =============================================================================
# EMAIL NOTIFICATION SYSTEM
# =============================================================================
nftban_send_email() {
    local recipient="$1"
    local subject="$2"
    local body="$3"
    local priority="${4:-normal}"
    
    local alert_enabled
    alert_enabled=$(nftban_get_config "NFTBAN_EMAIL_ENABLED" "false")
    
    if [[ "$alert_enabled" != "true" ]] && [[ "$priority" != "critical" ]]; then
        nftban_log_debug "Email notifications disabled, skipping"
        return 0
    fi
    
    local sender
    sender=$(nftban_get_config "NFTBAN_EMAIL_SENDER" "nftban@$(hostname -f)")
    
    if [[ -z "$recipient" ]]; then
        nftban_log_warning "Email recipient not configured"
        return 1
    fi
    
    if ! command -v mail &> /dev/null && ! command -v sendmail &> /dev/null; then
        nftban_log_warning "No mail command available"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Log email attempt
    echo "[${timestamp}] TO: ${recipient} | SUBJECT: ${subject}" >> "$NFTBAN_EMAIL_LOG"
    
    # Send email
    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" -r "$sender" "$recipient" 2>/dev/null || {
            nftban_log_warning "Failed to send email via mail command"
            return 1
        }
    elif command -v sendmail &> /dev/null; then
        {
            echo "To: $recipient"
            echo "From: $sender"
            echo "Subject: $subject"
            [[ "$priority" == "critical" ]] && echo "Priority: urgent"
            [[ "$priority" == "critical" ]] && echo "X-Priority: 1"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null || {
            nftban_log_warning "Failed to send email via sendmail"
            return 1
        }
    fi
    
    nftban_log_debug "Email sent to $recipient: $subject"
    return 0
}

nftban_send_ban_notification() {
    local ip="$1"
    local jail="$2"
    local action="$3"
    local reason="$4"
    local geoip="${5:-N/A}"
    local whois="${6:-N/A}"
    
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
    
    [[ -z "$recipient" ]] && return 0
    
    local subject="[nftban] IP $action - $ip ($jail jail)"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    local body="nftban Fail2ban Alert

Timestamp: $timestamp
Jail: $jail
IP Address: $ip
Action: $action
Reason: $reason

IP Information:
GeoIP: $geoip
WHOIS: $whois

Server: $(hostname -f)
---
This is an automated message from nftban"
    
    nftban_send_email "$recipient" "$subject" "$body" "normal"
}

nftban_send_rate_limit_alert() {
    local ban_count="$1"
    local time_window="$2"
    local rate_limit="$3"
    
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
    
    if [[ -z "$recipient" ]]; then
        nftban_log_error "CRITICAL: Rate limit exceeded but no email recipient configured!"
        return 1
    fi
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local subject="[nftban] CRITICAL: Ban Rate Limit Exceeded on $(hostname -f)"
    
    local recent_bans=""
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        recent_bans=$(tail -20 "$NFTBAN_BAN_LOG" | awk -F'|' '{printf "  %s | %s | %s | %s\n", $1, $2, $3, $4}')
    fi
    
    local body="nftban CRITICAL ALERT - Rate Limit Exceeded

⚠️ WARNING: Abnormal ban activity detected!

Timestamp: $timestamp
Server: $(hostname -f)
Time Window: Last ${time_window} seconds
Ban Attempts: ${ban_count}
Rate Limit: ${rate_limit} per minute
Status: THRESHOLD EXCEEDED

This could indicate:
- Distributed attack (DDoS)
- Misconfigured whitelist
- Port scanning activity
- Brute force attack

Recent Ban Attempts (last 20):
$recent_bans

Action Required:
1. Review ban logs: $NFTBAN_BAN_LOG
2. Check for patterns in source IPs
3. Verify whitelist configuration
4. Review jail configurations

---
This is an automated CRITICAL alert from nftban"
    
    nftban_send_email "$recipient" "$subject" "$body" "critical"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
nftban_check_root() {
    if [[ $EUID -ne 0 ]]; then
        nftban_log_error "This operation must be run as root"
        return 1
    fi
    return 0
}

nftban_check_nftables_table() {
    nft list table "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" &>/dev/null
}

nftban_atomic_write() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp.$$"
    
    echo "$content" > "$temp_file"
    sync
    mv -f "$temp_file" "$target_file"
    
    nftban_log_debug "Atomic write: $target_file"
}

nftban_backup_file() {
    local file="$1"
    local backup_dir="${NFTBAN_DATA_DIR}/backups"
    
    if [[ -f "$file" ]]; then
        mkdir -p "$backup_dir"
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_path="${backup_dir}/$(basename "$file").${timestamp}"
        cp "$file" "$backup_path"
        nftban_log_debug "Backup created: $backup_path"
    fi
}

nftban_get_public_ip() {
    local ip_type="$1"  # ipv4 or ipv6
    local ip=""
    
    local services=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ident.me"
        "https://ifconfig.me/ip"
    )
    
    for service in "${services[@]}"; do
        if command -v curl &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
            else
                ip=$(curl -6 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
            fi
            [[ -n "$ip" ]] && break
        elif command -v wget &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(wget -4 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
            else
                ip=$(wget -6 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
            fi
            [[ -n "$ip" ]] && break
        fi
    done
    
    echo "$ip"
}

nftban_get_current_user_ip() {
    # Try SSH_CLIENT first (most reliable for SSH connections)
    local ssh_client="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_client" ]]; then
        echo "$ssh_client"
        return 0
    fi
    
    # Try SSH_CONNECTION
    if [[ -n "${SSH_CONNECTION}" ]]; then
        echo "${SSH_CONNECTION%% *}"
        return 0
    fi
    
    # Try who command
    local who_output
    who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" && "$who_output" != "0.0.0.0" ]]; then
        echo "$who_output"
        return 0
    fi
    
    # Try last command
    local last_ip
    last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
        echo "$last_ip"
        return 0
    fi
    
    return 1
}

# =============================================================================
# MODULE AUTO-LOADER (ENFORCED DEPENDENCY ORDER)
# =============================================================================
nftban_load_modules() {
    nftban_log_debug "Loading NFTBan modules in dependency order..."
    
    # CRITICAL: Load modules in strict dependency order per architecture
    
    local modules=(
        # INFRASTRUCTURE LAYER (no dependencies)
        "nftban_nftables_module.sh"
        "nftban_port_module.sh"
        "nftban_template_module.sh"
        
        # CORE OPERATIONS LAYER (depend on infrastructure)
        "nftban_whitelist_module.sh"
        "nftban_blacklist_module.sh"
        "nftban_search_module.sh"
        "nftban_safety_module.sh" 
        "nftban_ipprotect_module.sh"
        "nftban_fail2ban_module.sh"
        
        # ADVANCED FEATURES LAYER (depend on core operations)
        "nftban_cloudflare_module.sh"
        "nftban_geo_module.sh"
        "nftban_geoip_module.sh"
        "nftban_stats_module.sh"
        "nftban_ratelimit_module.sh"
        "nftban_ddos_module.sh"
        "nftban_portscan_module.sh"
        "nftban_autorebuild_module.sh"
        "nftban_login_monitor_module.sh"
        "nftban_update_module.sh"
        "nftban_maintenance_module.sh"
        "nftban_feeds_module.sh"
    )
    
    local loaded=0
    local failed=0
    local skipped=0
    
    for module in "${modules[@]}"; do
        local module_path="${NFTBAN_LIB_DIR}/${module}"
        
        if [[ ! -f "$module_path" ]]; then
            nftban_log_warning "Module not found: $module"
            ((skipped++))
            continue
        fi
        
        if source "$module_path" 2>/dev/null; then
            nftban_log_debug "✓ Loaded: $module"
            ((loaded++))
        else
            nftban_log_warning "✗ Failed to load: $module"
            ((failed++))
        fi
    done
    
    nftban_log_debug "Module loading complete: $loaded loaded, $failed failed, $skipped skipped"
    
    # Validate critical modules
    local critical_missing=0
    
    if [[ -z "${NFTBAN_NFTABLES_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: nftables module not loaded"
        ((critical_missing++))
    fi
    
    if [[ -z "${NFTBAN_WHITELIST_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: whitelist module not loaded"
        ((critical_missing++))
    fi
    
    if [[ -z "${NFTBAN_BLACKLIST_LOADED:-}" ]]; then
        nftban_log_error "CRITICAL: blacklist module not loaded"
        ((critical_missing++))
    fi
    
    if [[ $critical_missing -gt 0 ]]; then
        nftban_log_error "System may not function correctly: $critical_missing critical module(s) missing"
    fi
    
    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================
nftban_core_init() {
    nftban_init_directories
    nftban_load_config
    nftban_load_modules
    nftban_log_debug "Core module initialized (v2.2.0 - Enhanced Security)"
}

# =============================================================================
# AUTO-INITIALIZE ON SOURCE
# =============================================================================
nftban_core_init

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_log
export -f nftban_log_error
export -f nftban_log_success
export -f nftban_log_warning
export -f nftban_log_info
export -f nftban_log_debug
export -f nftban_log_ban
export -f nftban_get_config
export -f nftban_set_config
export -f nftban_is_ipv4
export -f nftban_is_ipv6
export -f nftban_detect_ip_version
export -f nftban_validate_ip
export -f nftban_ip_to_int
export -f nftban_ip_in_cidr
export -f nftban_find_ip_locations
export -f nftban_check_root
export -f nftban_check_nftables_table
export -f nftban_geoip_lookup
export -f nftban_whois_lookup
export -f nftban_get_ip_info
export -f nftban_send_email
export -f nftban_send_ban_notification
export -f nftban_send_rate_limit_alert
export -f nftban_get_public_ip
export -f nftban_get_current_user_ip
export -f nftban_load_modules

nftban_log_debug "NFTBan Core Module loaded successfully (Enhanced v2.2.0)"
