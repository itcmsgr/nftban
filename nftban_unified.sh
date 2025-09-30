#!/bin/bash

################################################################################
# Script: nftban.sh
# A comprehensive nftables and fail2ban management tool with IP allowlist functionality
# Version: 3.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Description:
# This script automates the management for both nftables and fail2ban from one interface
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
################################################################################


# Configuration paths
BASE_DIR="/etc/nftban/config"
CONF_FILE="/etc/nftables.conf"
ALLOW_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_FILE="/var/log/nftban.log"
TEMP_BAN_TABLE="nftban_temp_ban"
FAIL2BAN_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_DIR="$FAIL2BAN_DIR/jail.d"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "$timestamp - $message" | tee -a "$LOG_FILE"
    else
        echo "$timestamp - $message"
    fi
}

# Function to display help
show_help() {
    cat << EOF
NFTBan Script - nftables and Fail2Ban management tool

Usage: nftban [OPTION]

Options:
  -e, --enable           Enable and start nftables and Fail2Ban services after config check
  -d, --disable          Disable and stop nftables and Fail2Ban services
  -s, --start            Start nftables and Fail2Ban services after config check
  -r, --restart          Restart nftables and Fail2Ban services after config check
  -x, --stop             Stop nftables and Fail2Ban services
  -l, --list             List current nftables rules
  -c, --check            Check nftables and Fail2Ban configuration syntax
  -a, --add-ip [IP]      Add your current IP to the allow file
  -i, --info             Show information about current IP and allow file status
  -tb, --temp-ban [IP] [COMMENT]  Temporarily ban an IP for 1 hour with comment
  -pb, --perm-ban [IP] [COMMENT]  Permanently ban an IP with comment
  -rb, --remove-ban [IP] Remove IP from temporary ban and Fail2Ban
  -lt, --list-temp       List temporarily banned IPs
  --enable-logging       Enable logging to file
  --disable-logging      Disable logging to file
  -h, --help             Display this help message

Fail2Ban Specific Options:
  -fj, --fail2ban-jails          View available Fail2Ban jails
  -fr, --fail2ban-rules [JAIL]   View Fail2Ban jail rules
  -fb, --fail2ban-banned [JAIL]  View banned IPs in Fail2Ban
  -fc, --fail2ban-check          Check Fail2Ban configuration

Advanced Options:
  -vb, --view-banned             View all banned IPs (nftables and Fail2Ban)
  -ri, --remove-ip [IP]          Remove IP from all ban lists (nftables and Fail2Ban)

Features:
  - Always checks configuration before enabling, starting, or restarting
  - Automatically adds your IP to the allow file if missing when using enable/start/restart
  - Maintains a backup of previous configurations before changes
  - Comprehensive logging of all operations
  - Temporary and permanent ban functionality with comments
  - Integrated with nftban-configuration-user-whitelist_ips.conf.local
  - Protects your current login IP from being banned
  - Full Fail2Ban integration

Examples:
  nftban --enable        # Enable and start nftables and Fail2Ban, add IP if needed
  nftban --list          # Show current nftables rules
  nftban --check         # Verify configuration syntax for both services
  nftban --add-ip        # Add your current IP to the allow file
  nftban --temp-ban 192.168.1.100 "SSH brute force attack"  # Temporarily ban an IP with comment
  nftban --perm-ban 192.168.1.101 "Known malicious IP"  # Permanently ban an IP with comment
  nftban --remove-ban 192.168.1.100  # Remove temporary ban
  nftban --fail2ban-jails          # View available Fail2Ban jails
  nftban --fail2ban-banned sshd    # View banned IPs in sshd jail
  nftban --view-banned             # View all banned IPs
  nftban --remove-ip 192.168.1.100 # Remove IP from all ban lists
EOF
}

# Function to get current login IP (the IP you're connecting from)
get_current_login_ip() {
    local login_ip
    
    # Try to get the IP from SSH connection (most common case)
    if [ -n "$SSH_CLIENT" ]; then
        login_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
        echo "$login_ip"
        return
    fi
    
    # Try to get the IP from who command
    login_ip=$(who -u | awk '{print $NF}' | sed 's/[()]//g' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    if [ -n "$login_ip" ]; then
        echo "$login_ip"
        return
    fi
    
    # Try to get the IP from last command
    login_ip=$(last -i | grep "still logged in" | awk '{print $3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    if [ -n "$login_ip" ]; then
        echo "$login_ip"
        return
    fi
    
    # Fallback: try to get IP from netstat or ss
    if command -v ss >/dev/null 2>&1; then
        login_ip=$(ss -tpn | grep -E "sshd.*ESTAB" | awk '{print $5}' | cut -d: -f1 | head -n 1)
    elif command -v netstat >/dev/null 2>&1; then
        login_ip=$(netstat -tpn | grep -E "sshd.*ESTABLISHED" | awk '{print $5}' | cut -d: -f1 | head -n 1)
    fi
    
    if [ -n "$login_ip" ]; then
        echo "$login_ip"
        return
    fi
    
    echo "unknown"
}

# Function to check if IP is in allow file
check_ip_in_allow() {
    local ip="$1"
    if [ -f "$ALLOW_FILE" ] && grep -q "^$ip" "$ALLOW_FILE"; then
        return 0 # IP exists
    else
        return 1 # IP does not exist
    fi
}

# Function to add IP to allow file with comment
add_ip_to_allow() {
    local ip="$1"
    local added=false
    local comment=" # Added by nftban on $(date '+%Y-%m-%d %H:%M:%S') for user $(whoami)"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$ALLOW_FILE")"
    
    # Create file if it doesn't exist
    if [ ! -f "$ALLOW_FILE" ]; then
        touch "$ALLOW_FILE"
        chmod 644 "$ALLOW_FILE"
        echo "# User whitelist IPs - managed by nftban" > "$ALLOW_FILE"
    fi
    
    # Check if IP already exists
    if ! check_ip_in_allow "$ip"; then
        echo "$ip$comment" >> "$ALLOW_FILE"
        log "Added IP $ip to allow file"
        added=true
    fi
    
    echo "$added"
}

# Function to remove IP from whitelist
remove_ip_from_whitelist() {
    local ip="$1"
    local removed=false
    
    # Remove from whitelist file if exists
    if [ -f "$ALLOW_FILE" ] && grep -q "^$ip" "$ALLOW_FILE"; then
        sed -i "/^$ip/d" "$ALLOW_FILE"
        log "Removed IP $ip from whitelist file $ALLOW_FILE"
        removed=true
    fi
    
    echo "$removed"
}

# Function to remove IP from blacklist files
remove_ip_from_blacklist() {
    local ip="$1"
    local removed=false
    
    # Check if it's IPv4 or IPv6
    if [[ "$ip" =~ .*:.* ]]; then
        # IPv6
        blacklist_file="$IPV6_BLACKLIST_FILE"
    else
        # IPv4
        blacklist_file="$IPV4_BLACKLIST_FILE"
    fi
    
    # Remove from blacklist file if exists
    if [ -f "$blacklist_file" ] && grep -q "^$ip" "$blacklist_file"; then
        sed -i "/^$ip/d" "$blacklist_file"
        log "Removed IP $ip from blacklist file $blacklist_file"
        removed=true
    fi
    
    echo "$removed"
}

# Function to add IP to blacklist with comment
add_ip_to_blacklist() {
    local ip="$1"
    local comment="$2"
    local added=false
    
    # Default comment if none provided
    if [ -z "$comment" ]; then
        comment="Banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Check if it's IPv4 or IPv6
    if [[ "$ip" =~ .*:.* ]]; then
        # IPv6
        blacklist_file="$IPV6_BLACKLIST_FILE"
    else
        # IPv4
        blacklist_file="$IPV4_BLACKLIST_FILE"
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$blacklist_file")"
    
    # Create file if it doesn't exist
    if [ ! -f "$blacklist_file" ]; then
        touch "$blacklist_file"
        chmod 644 "$blacklist_file"
        if [[ "$ip" =~ .*:.* ]]; then
            echo "# IPv6 blacklist IPs - managed by nftban" > "$blacklist_file"
        else
            echo "# IPv4 blacklist IPs - managed by nftban" > "$blacklist_file"
        fi
    fi
    
    # Check if IP already exists in blacklist
    if grep -q "^$ip" "$blacklist_file"; then
        # Update the comment if IP already exists
        sed -i "s/^$ip.*$/$ip # $comment/" "$blacklist_file"
        log "Updated IP $ip in blacklist file with new comment: $comment"
        added=true
    else
        # Add IP with comment
        echo "$ip # $comment" >> "$blacklist_file"
        log "Added IP $ip to blacklist file with comment: $comment"
        added=true
    fi
    
    # Remove from whitelist if exists
    if remove_ip_from_whitelist "$ip"; then
        log "Removed IP $ip from whitelist as it's now blacklisted"
    fi
    
    echo "$added"
}

# Function to check nftables configuration
check_nftables_config() {
    if ! nft -c -f "$CONF_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        log "nftables configuration check failed for $CONF_FILE"
        echo -e "${RED}nftables configuration check failed!${NC}"
        return 1
    fi
    log "nftables configuration check passed for $CONF_FILE"
    echo -e "${GREEN}nftables configuration check passed${NC}"
    return 0
}

# Function to check Fail2Ban configuration
check_fail2ban_config() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        if fail2ban-client --test 2>&1 | tee -a "$LOG_FILE"; then
            log "Fail2Ban configuration check passed"
            echo -e "${GREEN}Fail2Ban configuration check passed${NC}"
            return 0
        else
            log "Fail2Ban configuration check failed"
            echo -e "${RED}Fail2Ban configuration check failed!${NC}"
            return 1
        fi
    else
        log "Fail2Ban is not installed"
        echo -e "${YELLOW}Fail2Ban is not installed${NC}"
        return 1
    fi
}

# Function to check both configurations
check_config() {
    local nft_ok=true
    local f2b_ok=true
    
    echo -e "${BLUE}Checking nftables configuration...${NC}"
    if ! check_nftables_config; then
        nft_ok=false
    fi
    
    echo -e "${BLUE}Checking Fail2Ban configuration...${NC}"
    if ! check_fail2ban_config; then
        f2b_ok=false
    fi
    
    if [ "$nft_ok" = true ] && [ "$f2b_ok" = true ]; then
        return 0
    else
        return 1
    fi
}

# Function to backup current configuration
backup_config() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    mkdir -p "$BACKUP_DIR"
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "$BACKUP_DIR/nftables.conf.$timestamp"
        log "Backed up configuration to $BACKUP_DIR/nftables.conf.$timestamp"
    fi
}

# Function to list nftables rules
list_rules() {
    echo -e "${BLUE}Current nftables rules:${NC}"
    nft list ruleset
}

# Function to enable nftables service
enable_nftables_service() {
    systemctl enable nftables 2>/dev/null
    log "Enabled nftables service"
}

# Function to disable nftables service
disable_nftables_service() {
    systemctl disable nftables 2>/dev/null
    log "Disabled nftables service"
}

# Function to start nftables service
start_nftables_service() {
    if systemctl start nftables 2>/dev/null; then
        log "Started nftables service"
        echo -e "${GREEN}nftables service started${NC}"
        return 0
    else
        log "Failed to start nftables service"
        echo -e "${RED}Failed to start nftables service${NC}"
        return 1
    fi
}

# Function to stop nftables service
stop_nftables_service() {
    if systemctl stop nftables 2>/dev/null; then
        log "Stopped nftables service"
        echo -e "${YELLOW}nftables service stopped${NC}"
        return 0
    else
        log "Failed to stop nftables service"
        echo -e "${RED}Failed to stop nftables service${NC}"
        return 1
    fi
}

# Function to enable Fail2Ban service
enable_fail2ban_service() {
    systemctl enable fail2ban 2>/dev/null
    log "Enabled Fail2Ban service"
}

# Function to disable Fail2Ban service
disable_fail2ban_service() {
    systemctl disable fail2ban 2>/dev/null
    log "Disabled Fail2Ban service"
}

# Function to start Fail2Ban service
start_fail2ban_service() {
    if systemctl start fail2ban 2>/dev/null; then
        log "Started Fail2Ban service"
        echo -e "${GREEN}Fail2Ban service started${NC}"
        return 0
    else
        log "Failed to start Fail2Ban service"
        echo -e "${RED}Failed to start Fail2Ban service${NC}"
        return 1
    fi
}

# Function to stop Fail2Ban service
stop_fail2ban_service() {
    if systemctl stop fail2ban 2>/dev/null; then
        log "Stopped Fail2Ban service"
        echo -e "${YELLOW}Fail2Ban service stopped${NC}"
        return 0
    else
        log "Failed to stop Fail2Ban service"
        echo -e "${RED}Failed to stop Fail2Ban service${NC}"
        return 1
    fi
}

# Function to restart Fail2Ban service
restart_fail2ban_service() {
    if systemctl restart fail2ban 2>/dev/null; then
        log "Restarted Fail2Ban service"
        echo -e "${GREEN}Fail2Ban service restarted${NC}"
        return 0
    else
        log "Failed to restart Fail2Ban service"
        echo -e "${RED}Failed to restart Fail2Ban service${NC}"
        return 1
    fi
}

# Function to handle IP management for operations that require it
manage_ip() {
    local current_ip
    current_ip=$(get_current_login_ip)
    
    if [ "$current_ip" = "unknown" ]; then
        echo -e "${YELLOW}Warning: Could not determine your login IP address${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Your current login IP is: $current_ip${NC}"
    
    if check_ip_in_allow "$current_ip"; then
        echo -e "${GREEN}Your IP is already in the allow file${NC}"
        return 0
    else
        echo -e "${YELLOW}Your IP is not in the allow file${NC}"
        if add_ip_to_allow "$current_ip"; then
            echo -e "${GREEN}Added your IP ($current_ip) to the allow file${NC}"
            
            # Also remove from any blacklist files
            if remove_ip_from_blacklist "$current_ip"; then
                echo -e "${GREEN}Removed your IP from blacklist files${NC}"
            fi
            
            return 0
        else
            echo -e "${RED}Failed to add your IP to the allow file${NC}"
            return 1
        fi
    fi
}

# Function to create temporary ban table if it doesn't exist
ensure_temp_ban_table() {
    if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
        nft add table inet "$TEMP_BAN_TABLE"
        nft add set inet "$TEMP_BAN_TABLE" temp_ban_v4 '{ type ipv4_addr; timeout 1h; }'
        nft add set inet "$TEMP_BAN_TABLE" temp_ban_v6 '{ type ipv6_addr; timeout 1h; }'
        nft add chain inet "$TEMP_BAN_TABLE" input '{ type filter hook input priority -150; policy accept; }'
        nft add rule inet "$TEMP_BAN_TABLE" input ip saddr @temp_ban_v4 drop
        nft add rule inet "$TEMP_BAN_TABLE" input ip6 saddr @temp_ban_v6 drop
        log "Created temporary ban table"
    fi
}

# Function to check if IP is the current login IP
is_current_login_ip() {
    local ip="$1"
    local current_ip=$(get_current_login_ip)
    
    if [ "$ip" = "$current_ip" ]; then
        return 0
    else
        return 1
    fi
}

# Function to temporarily ban an IP with comment
temp_ban_ip() {
    local ip="$1"
    local comment="$2"
    
    # Prevent banning your own login IP
    if is_current_login_ip "$ip"; then
        echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
        log "Attempted to ban own login IP: $ip"
        return 1
    fi
    
    ensure_temp_ban_table
    
    # Default comment if none provided
    if [ -z "$comment" ]; then
        comment="Temporarily banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Check if it's IPv4 or IPv6
    if [[ "$ip" =~ .*:.* ]]; then
        # IPv6
        nft add element inet "$TEMP_BAN_TABLE" temp_ban_v6 { "$ip" }
        log "Temporarily banned IPv6 address: $ip with comment: $comment"
        echo -e "${RED}Temporarily banned IPv6 address: $ip (1 hour)${NC}"
        echo -e "${YELLOW}Comment: $comment${NC}"
    else
        # IPv4
        nft add element inet "$TEMP_BAN_TABLE" temp_ban_v4 { "$ip" }
        log "Temporarily banned IPv4 address: $ip with comment: $comment"
        echo -e "${RED}Temporarily banned IPv4 address: $ip (1 hour)${NC}"
        echo -e "${YELLOW}Comment: $comment${NC}"
    fi
}

# Function to permanently ban an IP with comment
perm_ban_ip() {
    local ip="$1"
    local comment="$2"
    
    # Prevent banning your own login IP
    if is_current_login_ip "$ip"; then
        echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
        log "Attempted to ban own login IP: $ip"
        return 1
    fi
    
    # Default comment if none provided
    if [ -z "$comment" ]; then
        comment="Permanently banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Add to blacklist file with comment
    if add_ip_to_blacklist "$ip" "$comment"; then
        log "Permanently banned IP: $ip with comment: $comment"
        echo -e "${RED}Permanently banned IP: $ip${NC}"
        echo -e "${YELLOW}Comment: $comment${NC}"
        
        # Also add to temporary ban for immediate effect
        temp_ban_ip "$ip" "$comment (also permanently banned)"
        
        return 0
    else
        echo -e "${YELLOW}IP $ip is already banned${NC}"
        return 1
    fi
}

# Function to remove temporary ban
remove_temp_ban() {
    local ip="$1"
    
    # Check if it's IPv4 or IPv6
    if [[ "$ip" =~ .*:.* ]]; then
        # IPv6
        nft delete element inet "$TEMP_BAN_TABLE" temp_ban_v6 { "$ip" } 2>/dev/null && \
            log "Removed temporary ban for IPv6 address: $ip" && \
            echo -e "${GREEN}Removed temporary ban for IPv6 address: $ip${NC}" && \
            return 0
    else
        # IPv4
        nft delete element inet "$TEMP_BAN_TABLE" temp_ban_v4 { "$ip" } 2>/dev/null && \
            log "Removed temporary ban for IPv4 address: $ip" && \
            echo -e "${GREEN}Removed temporary ban for IPv4 address: $ip${NC}" && \
            return 0
    fi
    
    log "IP $ip was not found in temporary ban list"
    echo -e "${YELLOW}IP $ip was not found in temporary ban list${NC}"
    return 1
}

# Function to list temporarily banned IPs
list_temp_bans() {
    echo -e "${BLUE}Temporarily banned IPv4 addresses:${NC}"
    nft list set inet "$TEMP_BAN_TABLE" temp_ban_v4 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}' || echo "None"
    
    echo -e "${BLUE}Temporarily banned IPv6 addresses:${NC}"
    nft list set inet "$TEMP_BAN_TABLE" temp_ban_v6 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' || echo "None"
}

# Function to view available Fail2Ban jails
view_fail2ban_jails() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${BLUE}Available Fail2Ban jails:${NC}"
        fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'
        
        # Also check for nftables-specific jails
        if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
            echo -e "${BLUE}NFTables-specific jails:${NC}"
            find "$FAIL2BAN_JAIL_DIR" -name "nftables-*.conf" -exec basename {} .conf \; | sed 's/^nftables-//'
        fi
    else
        echo -e "${RED}Fail2Ban is not installed${NC}"
    fi
}

# Function to view Fail2Ban jail rules
view_fail2ban_rules() {
    local jail="$1"
    
    if [ -z "$jail" ]; then
        echo -e "${RED}Please specify a jail name${NC}"
        return 1
    fi
    
    if command -v fail2ban-client >/dev/null 2>&1; then
        # Check if this is an nftables jail
        if [ -f "$FAIL2BAN_JAIL_DIR/nftables-$jail.conf" ]; then
            echo -e "${BLUE}Rules for nftables jail '$jail':${NC}"
            cat "$FAIL2BAN_JAIL_DIR/nftables-$jail.conf"
        else
            echo -e "${BLUE}Rules for jail '$jail':${NC}"
            fail2ban-client get "$jail" action | grep -E "(actionstart|actionstop|actioncheck|actionban|actionunban)"
        fi
    else
        echo -e "${RED}Fail2Ban is not installed${NC}"
    fi
}

# Function to view banned IPs in Fail2Ban
view_fail2ban_banned() {
    local jail="$1"
    
    if command -v fail2ban-client >/dev/null 2>&1; then
        if [ -z "$jail" ]; then
            # Show banned IPs for all jails
            echo -e "${BLUE}Banned IPs in all Fail2Ban jails:${NC}"
            for j in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' ' '); do
                banned_ips=$(fail2ban-client status "$j" | grep "Banned IP list" | sed 's/^.*Banned IP list://')
                if [ -n "$banned_ips" ]; then
                    echo -e "${YELLOW}$j:${NC} $banned_ips"
                fi
            done
        else
            # Show banned IPs for specific jail
            echo -e "${BLUE}Banned IPs in jail '$jail':${NC}"
            fail2ban-client status "$jail" | grep "Banned IP list" | sed 's/^.*Banned IP list://'
        fi
    else
        echo -e "${RED}Fail2Ban is not installed${NC}"
    fi
}

# Function to view all banned IPs (nftables and Fail2Ban)
view_all_banned() {
    echo -e "${BLUE}=== NFTables Banned IPs ===${NC}"
    # Get banned IPs from nftables
    nft list ruleset | grep -E "elements = {.*}" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | sort -u
    
    echo -e "${BLUE}=== Fail2Ban Banned IPs ===${NC}"
    # Get banned IPs from Fail2Ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        for j in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' ' '); do
            banned_ips=$(fail2ban-client status "$j" | grep "Banned IP list" | sed 's/^.*Banned IP list://')
            if [ -n "$banned_ips" ]; then
                echo "$banned_ips" | tr ' ' '\n'
            fi
        done | sort -u
    else
        echo "Fail2Ban is not installed"
    fi
}

# Function to remove IP from all ban lists
remove_ip_from_all() {
    local ip="$1"
    local removed=false
    
    if [ -z "$ip" ]; then
        echo -e "${RED}Please specify an IP address to remove${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Removing IP $ip from all ban lists...${NC}"
    
    # Remove from nftables temporary ban
    if remove_temp_ban "$ip"; then
        removed=true
    fi
    
    # Remove from nftables blacklist files
    if remove_ip_from_blacklist "$ip"; then
        removed=true
    fi
    
    # Remove from Fail2Ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        for j in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' ' '); do
            if fail2ban-client set "$j" unbanip "$ip" >/dev/null 2>&1; then
                log "Removed IP $ip from Fail2Ban jail $j"
                echo -e "${GREEN}Removed IP $ip from Fail2Ban jail $j${NC}"
                removed=true
            fi
        done
    fi
    
    if [ "$removed" = true ]; then
        echo -e "${GREEN}IP $ip removed from all ban lists${NC}"
    else
        echo -e "${YELLOW}IP $ip was not found in any ban lists${NC}"
    fi
}

# Function to update nftables configuration
update_nftables_config() {
    log "Updating nftables configuration based on current settings"
    
    # Ensure the current user IP is in the allow list
    manage_ip
    
    # Check configuration
    if check_config; then
        # Restart service to apply changes
        systemctl restart nftables
        systemctl restart fail2ban
    else
        echo -e "${RED}Configuration check failed, not applying changes${NC}"
        return 1
    fi
}

# Function to check if Fail2Ban jails are enabled
check_fail2ban_jails() {
    local all_ok=true
    
    if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
        for jail_file in "$FAIL2BAN_JAIL_DIR"/nftables-*.conf; do
            if [ -f "$jail_file" ]; then
                jail_name=$(basename "$jail_file" .conf | sed 's/^nftables-//')
                if grep -q "enabled.*=.*true" "$jail_file"; then
                    echo -e "${GREEN}Jail $jail_name is enabled${NC}"
                else
                    echo -e "${YELLOW}Jail $jail_name is disabled${NC}"
                    all_ok=false
                fi
            fi
        done
    else
        echo -e "${YELLOW}No Fail2Ban jail directory found at $FAIL2BAN_JAIL_DIR${NC}"
        all_ok=false
    fi
    
    if [ "$all_ok" = true ]; then
        return 0
    else
        return 1
    fi
}

# Main script logic
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
    
    # Check if nft is installed
    if ! command -v nft >/dev/null 2>&1; then
        echo -e "${RED}nftables is not installed. Please install it first.${NC}"
        exit 1
    fi
    
    # Default logging setting
    ENABLE_LOGGING=true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -e|--enable)
                echo -e "${BLUE}Enabling nftables and Fail2Ban services...${NC}"
                if check_config; then
                    backup_config
                    if manage_ip; then
                        enable_nftables_service
                        enable_fail2ban_service
                        start_nftables_service
                        start_fail2ban_service
                    else
                        echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
                        enable_nftables_service
                        enable_fail2ban_service
                        start_nftables_service
                        start_fail2ban_service
                    fi
                else
                    echo -e "${RED}Aborting enable operation due to configuration errors${NC}"
                    exit 1
                fi
                shift
                ;;
            -d|--disable)
                echo -e "${BLUE}Disabling nftables and Fail2Ban services...${NC}"
                stop_nftables_service
                stop_fail2ban_service
                disable_nftables_service
                disable_fail2ban_service
                shift
                ;;
            -s|--start)
                echo -e "${BLUE}Starting nftables and Fail2Ban services...${NC}"
                if check_config; then
                    if manage_ip; then
                        start_nftables_service
                        start_fail2ban_service
                    else
                        echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
                        start_nftables_service
                        start_fail2ban_service
                    fi
                else
                    echo -e "${RED}Aborting start operation due to configuration errors${NC}"
                    exit 1
                fi
                shift
                ;;
            -r|--restart)
                echo -e "${BLUE}Restarting nftables and Fail2Ban services...${NC}"
                if check_config; then
                    if manage_ip; then
                        systemctl restart nftables
                        systemctl restart fail2ban
                    else
                        echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
                        systemctl restart nftables
                        systemctl restart fail2ban
                    fi
                else
                    echo -e "${RED}Aborting restart operation due to configuration errors${NC}"
                    exit 1
                fi
                shift
                ;;
            -x|--stop)
                echo -e "${BLUE}Stopping nftables and Fail2Ban services...${NC}"
                stop_nftables_service
                stop_fail2ban_service
                shift
                ;;
            -l|--list)
                list_rules
                shift
                ;;
            -c|--check)
                check_config
                shift
                ;;
            -a|--add-ip)
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    # Use provided IP
                    ip="$2"
                    shift
                else
                    # Get current IP
                    ip=$(get_current_login_ip)
                fi
                
                if [ "$ip" = "unknown" ]; then
                    echo -e "${RED}Could not determine IP address${NC}"
                    exit 1
                fi
                
                echo -e "${BLUE}Adding IP to allow file...${NC}"
                if add_ip_to_allow "$ip"; then
                    echo -e "${GREEN}IP $ip added to allow file${NC}"
                    remove_ip_from_blacklist "$ip"
                    update_nftables_config
                else
                    echo -e "${YELLOW}IP $ip already exists in allow file${NC}"
                fi
                shift
                ;;
            -i|--info)
                echo -e "${BLUE}IP Information:${NC}"
                ip=$(get_current_login_ip)
                echo -e "Your current login IP: $ip"
                if check_ip_in_allow "$ip"; then
                    echo -e "Allow file status: ${GREEN}IP is in allow file${NC}"
                else
                    echo -e "Allow file status: ${YELLOW}IP is not in allow file${NC}"
                fi
                shift
                ;;
            -tb|--temp-ban)
                if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                    echo -e "${RED}Please specify an IP address to temporarily ban${NC}"
                    exit 1
                fi
                ip="$2"
                # Check if there's a comment
                if [ -n "$3" ] && [ "${3:0:1}" != "-" ]; then
                    comment="$3"
                    shift
                else
                    comment=""
                fi
                temp_ban_ip "$ip" "$comment"
                shift
                shift
                ;;
            -pb|--perm-ban)
                if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                    echo -e "${RED}Please specify an IP address to permanently ban${NC}"
                    exit 1
                fi
                ip="$2"
                # Check if there's a comment
                if [ -n "$3" ] && [ "${3:0:1}" != "-" ]; then
                    comment="$3"
                    shift
                else
                    comment=""
                fi
                perm_ban_ip "$ip" "$comment"
                shift
                shift
                ;;
            -rb|--remove-ban)
                if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                    echo -e "${RED}Please specify an IP address to remove from ban${NC}"
                    exit 1
                fi
                ip="$2"
                remove_ip_from_all "$ip"
                shift
                shift
                ;;
            -lt|--list-temp)
                list_temp_bans
                shift
                ;;
            -fj|--fail2ban-jails)
                view_fail2ban_jails
                shift
                ;;
            -fr|--fail2ban-rules)
                view_fail2ban_rules "$2"
                shift
                shift
                ;;
            -fb|--fail2ban-banned)
                view_fail2ban_banned "$2"
                shift
                shift
                ;;
            -fc|--fail2ban-check)
                check_fail2ban_config
                shift
                ;;
            -vb|--view-banned)
                view_all_banned
                shift
                ;;
            -ri|--remove-ip)
                if [ -z "$2" ] || [ "${2:0:1}" = "-" ]; then
                    echo -e "${RED}Please specify an IP address to remove${NC}"
                    exit 1
                fi
                ip="$2"
                remove_ip_from_all "$ip"
                shift
                shift
                ;;
            --enable-logging)
                ENABLE_LOGGING=true
                echo -e "${GREEN}Logging enabled${NC}"
                shift
                ;;
            --disable-logging)
                ENABLE_LOGGING=false
                echo -e "${YELLOW}Logging disabled${NC}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# Handle the case where no arguments are provided
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# Execute main function with all arguments
main "$@"


# === Begin merged content from: nftban_init_nftables_conf (1).sh ===
#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh (Rewritten two separate streams this for simple user and advance for future use )
#
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis) 
# Description:
# Single-table nftables configuration with simplified architecture
# - One global table: inet nftban_global
# - Separate sets for user/system blacklists and temp bans
# - Compatible with unified nftban management script
# - Whitelist always takes priority
# Architect nftables table: inet nftban_global
#├── Sets:
#│   ├── whitelist_v4 / whitelist_v6
#│   ├── user_blacklist_v4 / user_blacklist_v6  (from USER_BLACKLIST_FILE)
#│   ├── system_blacklist_v4 / system_blacklist_v6  (from IPV4/IPV6_BLACKLIST_FILE)
#│   └── temp_ban_v4 / temp_ban_v6
#└── Chains:
#    ├── input (priority -150, runs before other rules)
#    │   ├── Check whitelist → ACCEPT
#    │   ├── Check blacklists → DROP
#    │   └── Check temp_ban → DROP
#    └── forward (same logic for forwarded traffic)
################################################################################

set -euo pipefail

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"
BACKUP_DIR="/etc/nftban/backups"

# --- Logging ---
LOG_DIR="/etc/nftban/logs"
LOG_FILE="${LOG_DIR}/validation_$(date +%F).log"

# Ensure required directories exist
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# Migrate legacy backup directories to $BACKUP_DIR
migrate_legacy_backups() {
  for LEGACY in "/var/lib/nftban" "/var/backups"; do
    if [ -d "$LEGACY" ]; then
      # Move files without overwriting existing backups
      find "$LEGACY" -maxdepth 1 -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        bn="$(basename "$f")"
        dest="$BACKUP_DIR/$bn"
        if [ -e "$dest" ]; then
          ts="$(date +%F_%H%M%S)"
          dest="$BACKUP_DIR/${bn}.${ts}.migrated"
        fi
        mv "$f" "$dest" 2>/dev/null || cp -a "$f" "$dest"
      done
    fi
  done
}

migrate_legacy_backups

log_msg() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== NFTBAN nftables Configuration Initialization (v2.0) ==="
echo "Log file: $LOG_FILE"

# Config files
IPV4_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf.local"
IPV4_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf.local"
IPV6_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf.local"
IPV6_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf.local"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf.local"
USER_WHITELIST_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
USER_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-user-blacklist_ips.conf.local"
USER_CT_FILE_IPv4="$BASE_DIR/nftban-nfttables-ct-ipv4.conf.local"
USER_CT_FILE_IPv6="$BASE_DIR/nftban-nfttables-ct-ipv6.conf.local"
OUTPUT_FILE="${BASE_DIR}/nft_rules.conf.local"
FAIL2BAN_WHITELIST="$BASE_DIR/nftban-fail2ban-ip-whitelist.conf.local"
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
# --- Validation mode switch ---
if [[ "$1" == "--validate-only" ]]; then
  echo "--- Validating all rule sources ---"
  VALIDATION_LOG="${VALIDATION_LOG:-/var/log/nftban/validate_all_$(date +%Y-%m-%d-%H%M%S).log}"
  mkdir -p "$(dirname "$VALIDATION_LOG")"

  validate_nft_fragment() {
    local f="$1"
    if [[ -f "$f" ]]; then
      if nft -c -f "$f" 2>>"$VALIDATION_LOG"; then
        echo "✅ Valid nft fragment: $f"
      else
        echo "❌ Invalid nft fragment: $f"
        echo "  ↳ See: $VALIDATION_LOG"
      fi
    else
      echo "ℹ️ Missing file (skip): $f"
    fi
  }

  validate_ip_port_list() {
    local f="$1"
    local kind="$2" # ipv_mixed | ports
    [[ -f "$f" ]] || { echo "ℹ️ Missing file (skip): $f"; return; }
    local total=0 ok=0 bad=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[$'\t\r ']/}"
      [[ -z "$line" ]] && continue
      ((total++))
      case "$kind" in        ports)
          if [[ "$line" =~ ^[0-9]+$ ]]; then
            local a="$line"
            if (( a>=1 && a<=65535 )); then
              ((ok++))
            else
              echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          elif [[ "$line" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
            if (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )); then
              ((ok++))
            else
              echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          else
            echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
          fi
          ;;        ipv_mixed)
          if [[ "$line" == *:* ]]; then
            # IPv6
            if [[ "$line" =~ /([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ ]] || [[ "$line" == *"-"* ]] || [[ "$line" == *:* ]]; then
              ((ok++))
            else
              echo "[INVALID ipv6] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          else
            # IPv4
            if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
              # range bounds loosely checked here
              ((ok++))
            else
              echo "[INVALID ipv4] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          fi
          ;;
      esac
    done < "$f"
    echo "• $f  -> $ok valid / $bad invalid / $total total"
    [[ $bad -gt 0 ]] && echo "  ↳ See: $VALIDATION_LOG"
  }

  # Validate CT nft fragments
  validate_nft_fragment "$USER_CT_FILE_IPv4"
  validate_nft_fragment "$USER_CT_FILE_IPv6"

  # Validate port lists
  validate_ip_port_list "$IPV4_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV4_OUT_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_OUT_PORTS_FILE" ports

  # Validate IP lists (mixed v4/v6 allowed)
  for f in "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" "$USER_BLACKLIST_FILE" "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "$FAIL2BAN_WHITELIST"; do
    validate_ip_port_list "$f" ipv_mixed
  done

  echo "Validation complete. Log saved to: $VALIDATION_LOG"
  exit 0
fi


# --- Helper functions ---
append_if_set() {
  local __arr_name="$1"
  local __val=\"${2//[$'\t\r\n ']/}\"

  # Skip empty or comment
  [[ -z "$__val" ]] && return 0
  [[ "$__val" =~ ^[[:space:]]*# ]] && return 0

  # Determine expected type from array name
  local __type="generic"
  if [[ "$__arr_name" == *"port"* || "$__arr_name" == *"ports"* ]]; then
    __type="port"
  elif [[ "$__arr_name" == *"ipv6"* ]]; then
    __type="ipv6"
  elif [[ "$__arr_name" == *"ipv4"* ]]; then
    __type="ipv4"
  fi

  # Validation helpers (lightweight, no external deps)
  _is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
      (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
  }
  _is_ipv4_cidr() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    _is_ipv4 "${s%/*}"
  }
  _is_ipv4_interval() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    _is_ipv4 "${s%-*}" && _is_ipv4 "${s#*-}"
  }
  _is_ipv6() {
    # very permissive ipv6 matcher (covers :: and hex groups)
    local ip="$1"
    [[ "$ip" =~ ^(([0-9A-Fa-f]{1,4}:){1,7}:|:?:([0-9A-Fa-f]{1,4}:){1,7}[0-9A-Fa-f]{0,4}|::1|::)$ ]] && return 0
    # Fallback simple check (colon present)
    [[ "$ip" == *:* ]]
  }
  _is_ipv6_cidr() {
    local s="$1"
    [[ "$s" =~ /([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ ]] || return 1
    _is_ipv6 "${s%/*}"
  }
  _is_ipv6_interval() {
    local s="$1"
    [[ "$s" == *"-"* ]] || return 1
    _is_ipv6 "${s%-*}" && _is_ipv6 "${s#*-}"
  }
  _is_port_token() {
    local t="$1"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      (( t>=1 && t<=65535 )) && return 0 || return 1
    elif [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) && return 0 || return 1
    else
      return 1
    fi
  }

  local VALIDATION_LOG="${VALIDATION_LOG:-/var/log/nftban/validation_$(date +%Y-%m-%d).log}"
  mkdir -p "$(dirname "$VALIDATION_LOG")"

  local ok=0
  case "$__type" in
    port)
      _is_port_token "$__val" && ok=1
      ;;
    ipv4)
      { _is_ipv4 "$__val" || _is_ipv4_cidr "$__val" || _is_ipv4_interval "$__val"; } && ok=1
      ;;
    ipv6)
      { _is_ipv6 "$__val" || _is_ipv6_cidr "$__val" || _is_ipv6_interval "$__val"; } && ok=1
      ;;
    *)
      ok=1
      ;;
  esac

  if (( ok )); then
    eval "$__arr_name+=(\"$__val\")"
  else
    echo "[IGNORED] Invalid entry for $__arr_name: $__val" >> "$VALIDATION_LOG"
  fi
}

dedup() {
  awk -v RS=' ' '!a[$0]++' <<<"${*}"
}

print_elements_from_array() {
  local -n __arr_ref="$1"
  if [ "${#__arr_ref[@]}" -gt 0 ]; then
    local joined
    joined=$(IFS=' '; dedup "${__arr_ref[@]}")
    set -f
    local -a __tokens=()
    read -r -a __tokens <<< "$joined"
    printf '        elements = { %s }\n' "$(IFS=,; echo "${__tokens[*]}")"
    set +f
  fi
}

get_public_ip() {
    local ip_type=$1
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

get_current_user_ip() {
    # shellcheck disable=SC2153
    local ssh_client="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_client" ]]; then
        echo "$ssh_client"
        return 0
    fi
    
    local who_output
    who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" && "$who_output" != "0.0.0.0" ]]; then
        echo "$who_output"
        return 0
    fi
    
    local last_ip
    last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
        echo "$last_ip"
        return 0
    fi
    
    return 1
}

backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup_file
        backup_file="$BACKUP_DIR/$(basename "$file").backup.$(date +%Y%m%d%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$backup_file"
        echo "Backup created: $backup_file"
    fi
}

initialize_config_from_template() {
    local config_file=$1
    local template_file
    template_file="$BASE_DIR_INIT/$(basename "$config_file" .local)"
    
    if [[ ! -f "$config_file" ]]; then
        if [[ -f "$template_file" ]]; then
            backup_config "$config_file" 2>/dev/null
            cp "$template_file" "$config_file"
            echo "Initialized: $config_file (from template)"
        else
            echo "Warning: No template found for $config_file, creating empty file"
            touch "$config_file"
        fi
    fi
}

fetch_cloudflare_ips() {
    local url=$1
    local comment=$2
    local tmpfile
    tmpfile=$(mktemp)
    
    if command -v wget &>/dev/null; then
        wget -q -O "$tmpfile" "$url" || return 1
    elif command -v curl &>/dev/null; then
        curl -s -o "$tmpfile" "$url" || return 1
    else
        echo "Error: Neither wget nor curl available" >&2
        return 1
    fi
    
    while read -r ip; do
        [[ -n "$ip" ]] || continue
        if ! grep -q "^$ip" "$SYSTEM_WHITELIST_FILE"; then
            echo "$ip $comment" >> "$SYSTEM_WHITELIST_FILE"
        fi
    done < "$tmpfile"
    
    rm -f "$tmpfile"
}

generate_port_rules() {
    local file=$1
    local _direction=$2  # "input" or "output"
    [[ -f "$file" ]] || return
    
    while read -r line; do
        line=$(echo "$line" | sed 's/^ *//;s/ *$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        if [[ "$line" =~ ^([0-9]+(-[0-9]+)?)([TUB])$ ]]; then
            port_range=${BASH_REMATCH[1]}
            proto=${BASH_REMATCH[3]}
            
            if [[ "$port_range" == *-* ]]; then
                start=$(echo "$port_range" | cut -d'-' -f1)
                end=$(echo "$port_range" | cut -d'-' -f2)
                for ((port=start; port<=end; port++)); do
                    case "$proto" in
                        T) echo "        tcp dport $port accept" ;;
                        U) echo "        udp dport $port accept" ;;
                        B)
                            echo "        tcp dport $port accept"
                            echo "        udp dport $port accept"
                            ;;
                    esac
                done
            else
                port=$port_range
                case "$proto" in
                    T) echo "        tcp dport $port accept" ;;
                    U) echo "        udp dport $port accept" ;;
                    B)
                        echo "        tcp dport $port accept"
                        echo "        udp dport $port accept"
                        ;;
                esac
            fi
        else
            echo "Warning: Invalid line format '$line' in $file" >&2
        fi
    done < "$file"
}

# --- Cloudflare option ---
USE_CLOUDFLARE="${NFTBAN_USE_CLOUDFLARE:-auto}"
ASSUME_Y="${ASSUME_Y:-false}"

usage() {
  cat <<'USAGE'
Usage: $0 [options]

Options:
  --cloudflare [yes|no|auto]   Include Cloudflare IP ranges in whitelist.
                               Default: "auto" (ask if interactive, else no).
  --yes-cloudflare             Shortcut for --cloudflare yes
  --no-cloudflare              Shortcut for --cloudflare no
  -y                           Assume "yes" for prompts (non-interactive friendly)
  
  --install-final               Run install_final_config after generation
  --silent-auto                Run in silent mode with auto-confirmation and no prompts
  -h, --help                   Show this help
USAGE
}

ask_yes_no() {
  local prompt="$1"; local def="${2:-Y}"
  if [[ "$ASSUME_Y" == "true" ]]; then
    [[ "$def" =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  local suffix="[Y/n]"; [[ "$def" =~ ^[Nn]$ ]] && suffix="[y/N]"
  local ans
  while true; do
    read -r -p "$prompt $suffix " ans || ans=""
    ans="${ans:-$def}"
    case "$ans" in
      Y|y|yes|YES) return 0;;
      N|n|no|NO)   return 1;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Parse CLI args
INSTALL_FINAL=false
SILENT_AUTO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-final) INSTALL_FINAL=true ;;
    --silent-auto) ASSUME_Y="true"; SILENT_AUTO=true ;;
    *) break ;;
  esac
  shift
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloudflare)
      shift
      case "${1:-}" in
        yes|no|auto) USE_CLOUDFLARE="$1";;
        *) echo "Invalid value for --cloudflare: ${1:-<missing>}"; usage; exit 1;;
      esac
      ;;
    --yes-cloudflare) USE_CLOUDFLARE="yes";;
    --no-cloudflare)  USE_CLOUDFLARE="no";;
    -y) ASSUME_Y="true";;
    -h|--help) usage; exit 0;;
    *) break;;
  esac
  shift
done

# Decide final Cloudflare setting
if [[ "$USE_CLOUDFLARE" == "auto" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    if ask_yes_no "Include Cloudflare IP ranges in the whitelist?" "N"; then
      USE_CLOUDFLARE="yes"
    else
      USE_CLOUDFLARE="no"
    fi
  else
    USE_CLOUDFLARE="no"
  fi
fi

# --- Main execution ---
mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BASE_DIR_INIT"

# Initialize config files
echo "--- Initializing configuration files ---"
CONFIG_FILES=(
    "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE"
    "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"
    "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
    "$USER_CT_FILE_IPv4" "$USER_CT_FILE_IPv6"
    "$USER_WHITELIST_FILE"
    "$USER_BLACKLIST_FILE"
)

for file in "${CONFIG_FILES[@]}"; do
    initialize_config_from_template "$file"
done

# Seed USER_BLACKLIST_FILE with comments if empty
if [[ ! -s "$USER_BLACKLIST_FILE" ]]; then
    cat > "$USER_BLACKLIST_FILE" <<'EOF'
# User blacklist for nftban (manual bans)
# One entry per line; comments allowed with '#'
# Supports IPv4 / IPv6 and CIDR, e.g.:
# 203.0.113.45
# 198.51.100.0/24
# 2001:db8::dead:beef
# 2001:db8:abcd::/48
EOF
fi

echo "--- Starting nftables configuration generation ---"
echo "flush ruleset" > "$OUTPUT_FILE"

# Detect SSH port
SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"
echo "Detected SSH Port: $SSH_PORT"

# Detect server IPs
echo "--- Detecting server IP addresses ---"
SERVER_IPV4=$(ip -4 addr show 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | tr '\n' ' ')
SERVER_IPV6=$(ip -6 addr show 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/[0-9]+' | tr '\n' ' ')
SERVER_PUBLIC_IPV4=$(get_public_ip "ipv4")
SERVER_PUBLIC_IPV6=$(get_public_ip "ipv6")
CURRENT_USER_IP=$(get_current_user_ip)

# Create system whitelist
echo "# Auto-generated system whitelist - DO NOT EDIT MANUALLY" > "$SYSTEM_WHITELIST_FILE"
echo "# Generated on: $(date)" >> "$SYSTEM_WHITELIST_FILE"
echo "# Server interface IPv4 addresses" >> "$SYSTEM_WHITELIST_FILE"
for ip in $SERVER_IPV4; do echo "$ip" >> "$SYSTEM_WHITELIST_FILE"; done
echo "# Server interface IPv6 addresses" >> "$SYSTEM_WHITELIST_FILE"
for ip in $SERVER_IPV6; do echo "$ip" >> "$SYSTEM_WHITELIST_FILE"; done

if [[ -n "$SERVER_PUBLIC_IPV4" ]]; then
    echo "# Server public IPv4 address" >> "$SYSTEM_WHITELIST_FILE"
    echo "$SERVER_PUBLIC_IPV4" >> "$SYSTEM_WHITELIST_FILE"
fi

if [[ -n "$SERVER_PUBLIC_IPV6" ]]; then
    echo "# Server public IPv6 address" >> "$SYSTEM_WHITELIST_FILE"
    echo "$SERVER_PUBLIC_IPV6" >> "$SYSTEM_WHITELIST_FILE"
fi

if [[ -n "$CURRENT_USER_IP" ]]; then
    echo "# Current user IP address" >> "$SYSTEM_WHITELIST_FILE"
    echo "$CURRENT_USER_IP" >> "$SYSTEM_WHITELIST_FILE"
fi

echo "Server IPv4 addresses: $SERVER_IPV4"
echo "Server IPv6 addresses: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

# Fetch Cloudflare IPs if requested
if [[ "$USE_CLOUDFLARE" == "yes" ]]; then
    echo "Fetching Cloudflare IP ranges..."
    fetch_cloudflare_ips "$CLOUDFLARE_IPV4_URL" "#ipv4 from cloudflare"
    fetch_cloudflare_ips "$CLOUDFLARE_IPV6_URL" "#ipv6 from cloudflare"
else
    echo "Skipping Cloudflare IP ranges"
fi

# Collect all whitelist IPs
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | grep -v '^#' | sort -u | grep -v '^$')

# Remove whitelisted IPs from blacklists
if [[ -f "$IPV4_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}") "$IPV4_BLACKLIST_FILE" > "${IPV4_BLACKLIST_FILE}.tmp" || true
    mv "${IPV4_BLACKLIST_FILE}.tmp" "$IPV4_BLACKLIST_FILE"
fi

if [[ -f "$IPV6_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}") "$IPV6_BLACKLIST_FILE" > "${IPV6_BLACKLIST_FILE}.tmp" || true
    mv "${IPV6_BLACKLIST_FILE}.tmp" "$IPV6_BLACKLIST_FILE"
fi

# Save Fail2Ban whitelist
echo "$ALL_WHITELIST_IPS" | sort -u > "$FAIL2BAN_WHITELIST"
echo "Fail2Ban whitelist saved to: $FAIL2BAN_WHITELIST"

# Build arrays
ipv4_whitelist=()
ipv6_whitelist=()
ipv4_system_blacklist=()
ipv6_system_blacklist=()
ipv4_user_blacklist=()
ipv6_user_blacklist=()

# Parse whitelist
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    if [[ "$ip" == *:* ]]; then
        append_if_set ipv6_whitelist "$ip"
    else
        append_if_set ipv4_whitelist "$ip"
    fi
done < <(echo "$ALL_WHITELIST_IPS")

# Parse system blacklists
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv4_system_blacklist "$ip"
done < "$IPV4_BLACKLIST_FILE"

while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv6_system_blacklist "$ip"
done < "$IPV6_BLACKLIST_FILE"

# Parse user blacklist
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    if [[ "$ip" == *:* ]]; then
        append_if_set ipv6_user_blacklist "$ip"
    else
        append_if_set ipv4_user_blacklist "$ip"
    fi
done < "$USER_BLACKLIST_FILE"

# Generate single global table
{
cat <<'EOF'
# ============================================================================
# NFTBAN Global Firewall Table
# Single table architecture for simplified management
# ============================================================================

table inet nftban_global {
    # Whitelist sets (always take priority)
    set whitelist_v4 {
        type ipv4_addr;
        flags interval;
EOF

print_elements_from_array ipv4_whitelist

cat <<'EOF'
    }
    
    set whitelist_v6 {
        type ipv6_addr;
        flags interval;
EOF

print_elements_from_array ipv6_whitelist

cat <<'EOF'
    }
    
    # User blacklist (manual bans)
    set user_blacklist_v4 {
        type ipv4_addr;
        flags interval;
        comment "Manual bans from USER_BLACKLIST_FILE";
EOF

print_elements_from_array ipv4_user_blacklist

cat <<'EOF'
    }
    
    set user_blacklist_v6 {
        type ipv6_addr;
        flags interval;
        comment "Manual bans from USER_BLACKLIST_FILE";
EOF

print_elements_from_array ipv6_user_blacklist

cat <<'EOF'
    }
    
    # System blacklist (country blocks, bulk bans)
    set system_blacklist_v4 {
        type ipv4_addr;
        flags interval;
        comment "System-managed bulk bans (countries, ranges)";
EOF

print_elements_from_array ipv4_system_blacklist

cat <<'EOF'
    }
    
    set system_blacklist_v6 {
        type ipv6_addr;
        flags interval;
        comment "System-managed bulk bans (countries, ranges)";
EOF

print_elements_from_array ipv6_system_blacklist

cat <<'EOF'
    }
    
    # Temporary bans (with timeout)
    set temp_ban_v4 {
        type ipv4_addr;
        flags timeout;
        comment "Temporary bans set by nftban script";
    }
    
    set temp_ban_v6 {
        type ipv6_addr;
        flags timeout;
        comment "Temporary bans set by nftban script";
    }
    
    # Input chain (processes incoming traffic)
    chain input {
        type filter hook input priority -150;
        policy accept;
        
        # Allow loopback
        iif "lo" accept
        
        # PRIORITY 1: Whitelist always wins
        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept
        
        # PRIORITY 2: Drop banned IPs
        ip saddr @user_blacklist_v4 drop
        ip6 saddr @user_blacklist_v6 drop
        ip saddr @system_blacklist_v4 drop
        ip6 saddr @system_blacklist_v6 drop
        ip saddr @temp_ban_v4 drop
        ip6 saddr @temp_ban_v6 drop
        
        # PRIORITY 3: Allow established/related connections
        ct state established,related accept
        
        # PRIORITY 4: Allow SSH
EOF

echo "        tcp dport $SSH_PORT accept" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 5: User-defined port rules (IPv4)
EOF

generate_port_rules "$IPV4_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 6: User-defined port rules (IPv6)
EOF

generate_port_rules "$IPV6_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 7: Connection tracking rules (IPv4)
EOF

if [[ -f "$USER_CT_FILE_IPv4" ]]; then
    cat "$USER_CT_FILE_IPv4" >> "$OUTPUT_FILE"
fi

cat <<'EOF'
        
        # PRIORITY 8: Connection tracking rules (IPv6)
EOF

if [[ -f "$USER_CT_FILE_IPv6" ]]; then
    cat "$USER_CT_FILE_IPv6" >> "$OUTPUT_FILE"
fi

cat <<'EOF'
    }
    
    # Output chain (for outgoing traffic filtering if needed)
    chain output {
        type filter hook output priority 0;
        policy accept;
        
        # User-defined output port rules (IPv4)
EOF

generate_port_rules "$IPV4_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # User-defined output port rules (IPv6)
EOF

generate_port_rules "$IPV6_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"

cat <<'EOF'
    }
}

# ============================================================================
# Fail2Ban Integration Tables
# Each jail gets its own table for isolation and easier management
# ============================================================================
# 
# NOTE: These tables are created and managed by Fail2Ban actions.
# They follow the naming convention: inet nftban_f2b_<JAIL_NAME>
#
# Example structure for each jail:
#
# table inet nftban_f2b_sshd {
#     set banned_v4 { type ipv4_addr; flags timeout; }
#     set banned_v6 { type ipv6_addr; flags timeout; }
#     
#     chain input {
#         type filter hook input priority -100;
#         policy accept;
#         ip saddr @banned_v4 drop
#         ip6 saddr @banned_v6 drop
#     }
# }
#
# The Fail2Ban action adds IPs with:
#   nft add element inet nftban_f2b_sshd banned_v4 { <IP> timeout <TIME> }
#
# This keeps Fail2Ban bans separate from manual bans for clearer management.
#Example Fail2Ban Action for SSHD:
#File: /etc/fail2ban/action.d/nftban-sshd.conf
#ini[Definition]

#actionstart = nft add table inet nftban_f2b_sshd
#              nft add set inet nftban_f2b_sshd banned_v4 '{ type ipv4_addr; flags timeout; }'
#              nft add set inet nftban_f2b_sshd banned_v6 '{ type ipv6_addr; flags timeout; }'
#              nft add chain inet nftban_f2b_sshd input '{ type filter hook input priority -100; policy accept; }'
#              nft add rule inet nftban_f2b_sshd input ip saddr @banned_v4 drop
#              nft add rule inet nftban_f2b_sshd input ip6 saddr @banned_v6 drop
#
#actionstop = nft delete table inet nftban_f2b_sshd
#
#actioncheck = nft list table inet nftban_f2b_sshd
#
#actionban = nft add element inet nftban_f2b_sshd banned_v4 { <ip> timeout <bantime> }
#
#actionunban = nft delete element inet nftban_f2b_sshd banned_v4 { <ip> }

#[Init]
#bantime = 3600

# ============================================================================
EOF
} >> "$OUTPUT_FILE"

# Configuration will be validated and applied by install_final_config function

# Summary
echo ""
echo "=== Configuration Summary ==="
echo "Architecture: Single global table (inet nftban_global)"
echo "SSH Port: $SSH_PORT"
echo "Whitelisted IPs: ${#ipv4_whitelist[@]} IPv4, ${#ipv6_whitelist[@]} IPv6"
echo "User Blacklist: ${#ipv4_user_blacklist[@]} IPv4, ${#ipv6_user_blacklist[@]} IPv6"
echo "System Blacklist: ${#ipv4_system_blacklist[@]} IPv4, ${#ipv6_system_blacklist[@]} IPv6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

echo ""
echo "=== Fail2Ban Table Convention ==="
echo "Fail2Ban jails should use tables named: inet nftban_f2b_<JAIL_NAME>"
echo "Examples:"
echo "  - inet nftban_f2b_sshd"
echo "  - inet nftban_f2b_nginx"
echo "  - inet nftban_f2b_wordpress"
echo ""
echo "Each jail table should have:"
echo "  - Sets: banned_v4, banned_v6 (with timeout flags)"
echo "  - Chain: input hook at priority -100"
echo ""

FINAL_SNAPSHOT="$LOG_DIR/nftables_final_$(date +%Y%m%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_SNAPSHOT"
echo "Configuration snapshot: $FINAL_SNAPSHOT"

# --- Function to install and activate the configuration ---
install_final_config() {
  echo "--- Installing final nftables configuration ---"
  FINAL_CONFIG="/etc/nftables.conf"

  if [[ -f "$OUTPUT_FILE" ]]; then
    cp "$OUTPUT_FILE" "$FINAL_CONFIG"
    echo "Configuration copied to: $FINAL_CONFIG"

    if nft -c -f "$FINAL_CONFIG"; then
      echo "✅ Syntax check passed."
    else
      echo "❌ Syntax error in final config. Aborting."
      return 1
    fi

    if systemctl is-active --quiet nftables; then
      echo "Reloading nftables service..."
      systemctl reload nftables && echo "✅ Reload successful." || echo "❌ Reload failed."
    else
      echo "nftables service not active. You may need to start it manually."
    fi
  else
    echo "ERROR: Output file not found: $OUTPUT_FILE"
    return 1
  fi
}

# --- Finalize: validate and install the generated config ---
echo "=== Finalizing configuration ==="

if [ -f "$OUTPUT_FILE" ]; then
  # Validate syntax first
  if nft -c -f "$OUTPUT_FILE"; then
    echo "✅ Final ruleset syntax OK."
  else
    echo "❌ Final ruleset has syntax errors. See $LOG_FILE for details."
    exit 1
  fi
  
  # Install if requested or in silent mode
  if [[ "$INSTALL_FINAL" == "true" ]] || [[ "$SILENT_AUTO" == "true" ]]; then
    install_final_config || exit 1
  else
    echo ""
    echo "Configuration generated successfully but not applied."
    echo "To apply: nft -f $OUTPUT_FILE"
    echo "Or run: $0 --install-final"
  fi
else
  log_msg "ERROR: Expected OUTPUT_FILE not found: $OUTPUT_FILE"
  exit 1
fi

echo "=== Initialization complete ==="

# === End merged content from: nftban_init_nftables_conf (1).sh ===


# === Begin merged content from: nftban_init_fail2ban_conf (2).sh ===
#!/usr/bin/env bash

# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 3.4  (Adds config validation, status, backup/restore, docs; fixes timer)
# Author:  ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   Comprehensive automation for Fail2Ban using the nftables backend.
#   - Refreshes the canonical reference config:
#       /etc/nftban/config/nftban.conf        (ALWAYS rewritten; backup if changed)
#   - Preserves your real edits in:
#       /etc/nftban/config/nftban.conf.local  (NEVER touched by this script)
#   - Compares base vs .local and reports missing/different/extra keys.
#   - Stages templates, provides a portable sendmail action, and optional
#     login monitoring (service + timer). Manual nftables helpers included.
#
# What it does:
#   • Creates the user config if missing and prints clear next steps.
#   • Updates configs with any missing settings while PRESERVING existing values.
#   • Can recreate all jails/filters/actions from templates while keeping your
#     custom values in the *.local file.
#
# New in 3.4 (your request):
#   • (1) Critical bug fix in TIMER script: removed conflicting journalctl -u filters.
#   • (2) Configuration validation (email / numeric sanity checks).
#   • (8) Better status reporting: `status` command.
#   • (9) Configuration backup/restore: `backup-config`, `list-backups`, `restore-config`.
#   • (11) CLI improvements (backup part wired into main).
#   • (12) Documentation generation: `gen-docs`.
#
# Usage Examples:
#   sudo ./nftban_init_fail2ban_conf.sh setup
#   sudo ./nftban_init_fail2ban_conf.sh status
#   sudo ./nftban_init_fail2ban_conf.sh backup-config
#   sudo ./nftban_init_fail2ban_conf.sh list-backups
#   sudo ./nftban_init_fail2ban_conf.sh restore-config /etc/nftban/backups/nftban-config-YYYYmmdd-HHMMSS.tar.gz
#   sudo ./nftban_init_fail2ban_conf.sh gen-docs
#
# Notes:
#   • Live login monitor unit: nftban_lfd.service
#   • Scan service & timer: nftban-login-scan.service / nftban-login-scan.timer
#   • Timer bug context: using -u (unit) AND (-t/--identifier) filtered out sudo lines.
#
#Example Fail2Ban Action for SSHD:
#File: /etc/fail2ban/action.d/nftban-sshd.conf
#ini[Definition]

#actionstart = nft add table inet nftban_f2b_sshd
#              nft add set inet nftban_f2b_sshd banned_v4 '{ type ipv4_addr; flags timeout; }'
#              nft add set inet nftban_f2b_sshd banned_v6 '{ type ipv6_addr; flags timeout; }'
#              nft add chain inet nftban_f2b_sshd input '{ type filter hook input priority -100; policy accept; }'
#              nft add rule inet nftban_f2b_sshd input ip saddr @banned_v4 drop
#              nft add rule inet nftban_f2b_sshd input ip6 saddr @banned_v6 drop
#
#actionstop = nft delete table inet nftban_f2b_sshd
#
#actioncheck = nft list table inet nftban_f2b_sshd
#
#actionban = nft add element inet nftban_f2b_sshd banned_v4 { <ip> timeout <bantime> }
#
#actionunban = nft delete element inet nftban_f2b_sshd banned_v4 { <ip> }

#[Init]
#bantime = 3600

# =============================================================================

set -Eeuo pipefail

# -----------------------------
# Paths & defaults
# -----------------------------
BASE_DIR="/etc/nftban"
LOGFILE="/var/log/nftban/nftban-setup.log"
LOGFILE_IP="/var/log/nftban/nftban-bans.log"
CONFIG_FILE="$BASE_DIR/config/nftban.conf"
CONFIG_FILE_USER="$BASE_DIR/config/nftban.conf.local"
TEMPLATE_DIR="$BASE_DIR/templates/fail2ban"
WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
BLACKLIST_FILE="$BASE_DIR/config/nftban-configuration-user-blacklist_ips.conf.local"

F2B_JAIL_DIR="/etc/fail2ban/jail.d"
F2B_FILTER_DIR="/etc/fail2ban/filter.d"
F2B_ACTION_DIR="/etc/fail2ban/action.d"
F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

MAIL_ACTION_NAME="NFTBAN_F2B_SENDMAIL.conf"

# Backup directory
BACKUP_DIR="$BASE_DIR/backups"

# Login monitor files
LM_LIVE_BIN="/usr/local/sbin/nftban-login-monitor"
LM_SCAN_BIN="/usr/local/sbin/nftban-login-scan"
LM_LIVE_UNIT="/etc/systemd/system/nftban_lfd.service"
LM_SCAN_UNIT="/etc/systemd/system/nftban-login-scan.service"
LM_TIMER_UNIT="/etc/systemd/system/nftban-login-scan.timer"

# -----------------------------
# Helpers
# -----------------------------
ts() { date -Is; }
log() { echo "[$(ts)] $*" | tee -a "$LOGFILE"; }
die() { echo "[$(ts)] ERROR: $*" | tee -a "$LOGFILE" >&2; exit 1; }
ensure_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }
mkdirp() { mkdir -p "$1"; }
trap 's=$?; echo "[$(ts)] Aborted (exit $s)" >>"$LOGFILE"; exit $s' ERR INT

init_dirs() {
  mkdirp "$BASE_DIR/config" "/var/log/nftban" "$F2B_JAIL_DIR" "$F2B_FILTER_DIR" "$F2B_ACTION_DIR" "$BACKUP_DIR"
  : > "$LOGFILE"
  touch "$LOGFILE_IP"
  # Ensure list files exist
  : > "$WHITELIST_FILE"
  : > "$BLACKLIST_FILE"
}

backup_jail_local() {
  if [[ -f "$F2B_JAIL_LOCAL" ]]; then
    local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
    mv -f "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}_${tsf}"
    log "Backed up $F2B_JAIL_LOCAL -> ${F2B_JAIL_LOCAL}_${tsf}"
  fi
}

# -----------------------------
# Base config (canonical reference) — ALWAYS refreshed on `setup`
# -----------------------------
canonical_base_config() {
  # Print the canonical reference config to stdout (no variable expansion).
  cat <<'EOF'
# =============================================================================
# NFTBAN Configuration File (Reference / DO NOT EDIT)
# This file is refreshed by nftban_init_fail2ban_conf.sh on every `setup` run.
# Put your real changes in: /etc/nftban/config/nftban.conf.local
# =============================================================================

# Email Settings
NFTBAN_F2B_RECIPIENT="admin@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ALERT_ENABLED="true"

# Default Settings
NFTBAN_F2B_DEF_BAN_TIME="3600"        # 1 hour
NFTBAN_F2B_DEF_FIND_TIME="600"        # 10 minutes
NFTBAN_F2B_DEF_MAX_RETRY="5"          # Max attempts
NFTBAN_F2B_BACKEND="systemd"          # Backend: systemd/polling

# Enhanced Security
NFTBAN_F2B_AGGRESSIVE_MODE="false"
NFTBAN_F2B_GEOIP_ENABLE="true"
NFTBAN_F2B_WHOIS_ENABLE="true"

# Login Monitoring Settings
NFTBAN_F2B_LOGIN_MONITOR="true"           # Enable login monitoring service
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"        # Alert on root logins (CRITICAL)
NFTBAN_F2B_SUDO_ALERT="true"              # Alert on sudo usage
NFTBAN_F2B_SSH_LOGIN_ALERT="false"        # Alert on ALL SSH logins (can be noisy)
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"     # Alert after N failed logins from same IP

# Jail Configurations - Set to "true" to enable
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_SSH_BAN_TIME="1800"
NFTBAN_F2B_SSH_MAX_RETRY="3"
NFTBAN_F2B_SSH_FIND_TIME="600"

NFTBAN_F2B_APACHE_JAIL="false"
NFTBAN_F2B_APACHE_BAN_TIME="3600"
NFTBAN_F2B_APACHE_MAX_RETRY="5"

NFTBAN_F2B_NGINX_JAIL="false"
NFTBAN_F2B_NGINX_BAN_TIME="3600"
NFTBAN_F2B_NGINX_MAX_RETRY="5"

NFTBAN_F2B_POSTFIX_JAIL="false"
NFTBAN_F2B_POSTFIX_BAN_TIME="3600"
NFTBAN_F2B_POSTFIX_MAX_RETRY="5"

NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_WORDPRESS_BAN_TIME="7200"
NFTBAN_F2B_WORDPRESS_MAX_RETRY="3"
NFTBAN_F2B_WORDPRESS_FIND_TIME="600"

NFTBAN_F2B_XMLRPC_JAIL="true"
NFTBAN_F2B_XMLRPC_BAN_TIME="10800"
NFTBAN_F2B_XMLRPC_MAX_RETRY="2"
NFTBAN_F2B_XMLRPC_FIND_TIME="300"

NFTBAN_F2B_DIRECTADMIN_JAIL="true"
NFTBAN_F2B_DIRECTADMIN_BAN_TIME="14400"
NFTBAN_F2B_DIRECTADMIN_MAX_RETRY="3"
NFTBAN_F2B_DIRECTADMIN_FIND_TIME="600"

# Whitelist file
NFTBAN_F2B_IGNOREIP="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
EOF
}

refresh_base_config() {
  ensure_root
  install -d -m 0755 "$BASE_DIR/config"
  local tmp; tmp="$(mktemp)"
  canonical_base_config >"$tmp"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    install -m 0644 -o root -g root "$tmp" "$CONFIG_FILE"
    log "Wrote reference base config: $CONFIG_FILE"
  else
    local cnew cold
    cnew="$(sha256sum "$tmp" | awk '{print $1}')"
    cold="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    if [[ "$cnew" != "$cold" ]]; then
      local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
      cp -a "$CONFIG_FILE" "${CONFIG_FILE}.${tsf}.bak"
      install -m 0644 -o root -g root "$tmp" "$CONFIG_FILE"
      log "Updated reference base config (backup saved as ${CONFIG_FILE}.${tsf}.bak)."
    else
      log "Reference base config is up to date."
    fi
  fi
  rm -f "$tmp"
}

# -----------------------------
# Config compare & load
# -----------------------------
emit_kv() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val%%#*}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      [[ "$val" =~ ^\".*\"$ ]] && val="${val:1:${#val}-2}"
      [[ "$val" =~ ^\'.*\'$ ]] && val="${val:1:${#val}-2}"
      printf '%s\0%s\0' "$key" "$val"
    fi
  done < "$file"
}

declare -A BASE_KV USER_KV
load_kv_maps() {
  BASE_KV=(); USER_KV=()
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do BASE_KV["$k"]="$v"; done < <(emit_kv "$CONFIG_FILE")
  if [[ -f "$CONFIG_FILE_USER" ]]; then
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do USER_KV["$k"]="$v"; done < <(emit_kv "$CONFIG_FILE_USER")
  fi
}

show_config_diff() {
  load_kv_maps
  echo "=== Config comparison ==="
  echo "Base:  $CONFIG_FILE"
  echo "Local: $CONFIG_FILE_USER (user-owned)"
  local missing=() diffs=() extra=()
  for k in "${!BASE_KV[@]}"; do
    if [[ -z "${USER_KV[$k]+x}" ]]; then missing+=("$k")
    elif [[ "${USER_KV[$k]}" != "${BASE_KV[$k]}" ]]; then diffs+=("$k|BASE='${BASE_KV[$k]}'|USER='${USER_KV[$k]}'"); fi
  done
  for k in "${!USER_KV[@]}"; do [[ -z "${BASE_KV[$k]+x}" ]] && extra+=("$k|USER='${USER_KV[$k]}'"); done

  if ((${#missing[@]})); then echo "MISSING in .local (consider adding):"; for k in "${missing[@]}"; do echo "  - $k"; done; else echo "No missing keys."; fi
  if ((${#diffs[@]})); then echo "DIFFERENT values (override ok):"; for row in "${diffs[@]}"; do IFS='|' read -r key b u <<<"$row"; echo "  - $key"; echo "      $b"; echo "      $u"; done; else echo "No differing values."; fi
  if ((${#extra[@]})); then echo "EXTRA in .local (not in base):"; for row in "${extra[@]}"; do IFS='|' read -r key u <<<"$row"; echo "  - $key  ($u)"; done; else echo "No extra keys."; fi
}

load_config_env() {
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  if [[ -f "$CONFIG_FILE_USER" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE_USER"
  fi
  set +a
  log "Configuration loaded (base + .local overrides)."
}

# -----------------------------
# (2) Configuration Validation
# -----------------------------
validate_config() {
  local errors=()

  # Email
  if [[ -n "${NFTBAN_F2B_RECIPIENT:-}" ]] && ! [[ "$NFTBAN_F2B_RECIPIENT" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
    errors+=("Invalid email format: NFTBAN_F2B_RECIPIENT='$NFTBAN_F2B_RECIPIENT'")
  fi
  if [[ -n "${NFTBAN_F2B_SENDER:-}" ]] && ! [[ "$NFTBAN_F2B_SENDER" =~ ^[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+$ ]]; then
    errors+=("Sender should look like an email address: NFTBAN_F2B_SENDER='$NFTBAN_F2B_SENDER'")
  fi

  # Numeric sanity
  local numeric_vars=(
    NFTBAN_F2B_DEF_BAN_TIME NFTBAN_F2B_DEF_FIND_TIME NFTBAN_F2B_DEF_MAX_RETRY
    NFTBAN_F2B_SSH_BAN_TIME NFTBAN_F2B_SSH_MAX_RETRY NFTBAN_F2B_SSH_FIND_TIME
    NFTBAN_F2B_APACHE_BAN_TIME NFTBAN_F2B_APACHE_MAX_RETRY
    NFTBAN_F2B_NGINX_BAN_TIME  NFTBAN_F2B_NGINX_MAX_RETRY
    NFTBAN_F2B_POSTFIX_BAN_TIME NFTBAN_F2B_POSTFIX_MAX_RETRY
    NFTBAN_F2B_WORDPRESS_BAN_TIME NFTBAN_F2B_WORDPRESS_MAX_RETRY NFTBAN_F2B_WORDPRESS_FIND_TIME
    NFTBAN_F2B_XMLRPC_BAN_TIME NFTBAN_F2B_XMLRPC_MAX_RETRY NFTBAN_F2B_XMLRPC_FIND_TIME
    NFTBAN_F2B_DIRECTADMIN_BAN_TIME NFTBAN_F2B_DIRECTADMIN_MAX_RETRY NFTBAN_F2B_DIRECTADMIN_FIND_TIME
    NFTBAN_F2B_FAILED_LOGIN_THRESHOLD
  )
  for var in "${numeric_vars[@]}"; do
    local val="${!var:-}"
    if [[ -n "$val" ]] && ! [[ "$val" =~ ^[0-9]+$ ]]; then
      errors+=("$var must be numeric, got: '$val'")
    fi
  done

  if ((${#errors[@]} > 0)); then
    log "Configuration validation errors:"
    printf '  - %s\n' "${errors[@]}" | tee -a "$LOGFILE"
    return 1
  fi
  log "Configuration validated OK."
  return 0
}

# -----------------------------
# Jails & templates
# -----------------------------
enabled_jails() {
  [[ "${NFTBAN_F2B_SSH_JAIL:-false}"         == "true" ]] && echo "ssh"
  [[ "${NFTBAN_F2B_APACHE_JAIL:-false}"      == "true" ]] && echo "apache"
  [[ "${NFTBAN_F2B_NGINX_JAIL:-false}"       == "true" ]] && echo "nginx"
  [[ "${NFTBAN_F2B_POSTFIX_JAIL:-false}"     == "true" ]] && echo "postfix"
  [[ "${NFTBAN_F2B_WORDPRESS_JAIL:-false}"   == "true" ]] && echo "wordpress"
  [[ "${NFTBAN_F2B_XMLRPC_JAIL:-false}"      == "true" ]] && echo "xmlrpc"
  [[ "${NFTBAN_F2B_DIRECTADMIN_JAIL:-false}" == "true" ]] && echo "directadmin"
}
varname_for_jail() { echo "NFTBAN_F2B_${1^^}_JAIL"; }
file_checksum() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
template_paths_for_jail() {
  local jail="$1" var; var="$(varname_for_jail "$jail")"
  echo "$TEMPLATE_DIR/jail.d/${var}.conf"
  echo "$TEMPLATE_DIR/filter.d/${var}.conf"
  echo "$TEMPLATE_DIR/action.d/${var}.conf"
}
dest_paths_for_jail() {
  local jail="$1" var; var="$(varname_for_jail "$jail")"
  echo "$F2B_JAIL_DIR/${var}.conf"
  echo "$F2B_FILTER_DIR/${var}.conf"
  echo "$F2B_ACTION_DIR/${var}.conf"
}
compare_and_copy() {
  local src="$1" dst="$2"
  if [[ ! -f "$src" ]]; then echo "MISSING_SRC"; return 1; fi
  if [[ ! -f "$dst" ]]; then install -m 0644 -o root -g root "$src" "$dst"; echo "CREATED"; return 0; fi
  local csrc cdst msrc mdst tsf
  csrc="$(file_checksum "$src")"; cdst="$(file_checksum "$dst")"
  msrc="$(file_mtime "$src")";   mdst="$(file_mtime "$dst")"
  if [[ "$csrc" != "$cdst" ]] || (( msrc > mdst )); then
    tsf="$(date +%Y%m%d-%H%M%S)"; cp -a "$dst" "${dst}.${tsf}.bak"
    install -m 0644 -o root -g root "$src" "$dst"; echo "UPDATED"
  else
    echo "UP-TO-DATE"
  fi
}
verify_and_stage_templates() {
  local created=() updated=() uptodate=() missing=() jail
  while read -r jail; do
    [[ -n "$jail" ]] || continue
    mapfile -t tmpls < <(template_paths_for_jail "$jail")
    mapfile -t dests < <(dest_paths_for_jail "$jail")
    local any_missing=0
    for f in "${tmpls[@]}"; do [[ -f "$f" ]] || { any_missing=1; missing+=("$jail:$f"); }; done
    if (( any_missing )); then log "Jail '$jail' templates incomplete. Skipping copy."; continue; fi
    local i status
    for i in 0 1 2; do
      status="$(compare_and_copy "${tmpls[$i]}" "${dests[$i]}")" || true
      case "$status" in
        CREATED)     created+=("${dests[$i]}");;
        UPDATED)     updated+=("${dests[$i]}");;
        UP-TO-DATE)  uptodate+=("${dests[$i]}");;
        MISSING_SRC) missing+=("$jail:${tmpls[$i]}");;
      esac
    done
  done < <(enabled_jails)
  [[ ${#created[@]}   -gt 0 ]] && { log "Created:";   printf '  - %s\n' "${created[@]}"   | tee -a "$LOGFILE"; }
  [[ ${#updated[@]}   -gt 0 ]] && { log "Updated (template newer/different):"; printf '  - %s\n' "${updated[@]}"   | tee -a "$LOGFILE"; }
  [[ ${#uptodate[@]}  -gt 0 ]] && { log "Up-to-date:"; printf '  - %s\n' "${uptodate[@]}"  | tee -a "$LOGFILE"; }
  [[ ${#missing[@]}   -gt 0 ]] && { log "Missing sources in $TEMPLATE_DIR:"; printf '  - %s\n' "${missing[@]}" | tee -a "$LOGFILE"; }
  if [[ ${#missing[@]} -eq 0 ]]; then echo "All enabled jails have complete templates staged in /etc/fail2ban. (No services started.)"; else echo "Some enabled jails are missing templates. See log."; fi
}

# -----------------------------
# Mail action
# -----------------------------
detect_sendmail() { for p in /usr/sbin/sendmail /usr/lib/sendmail /usr/bin/sendmail; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; echo ""; return 1; }
detect_mailx()    { for p in /usr/bin/mail /bin/mail; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; echo ""; return 1; }

generate_mail_action() {
  local dest="${NFTBAN_F2B_RECIPIENT:-root@localhost}"
  local sender="${NFTBAN_F2B_SENDER:-nftban@$(hostname -f)}"
  local prefix="[nftban]"
  local sendmail_path; sendmail_path="$(detect_sendmail)"
  local action_file="$F2B_ACTION_DIR/$MAIL_ACTION_NAME"
  local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
  [[ -f "$action_file" ]] && cp -a "$action_file" "${action_file}.${tsf}.bak"
  if [[ -n "$sendmail_path" ]]; then
    cat >"$action_file" <<EOF
# $MAIL_ACTION_NAME - Autogenerated by nftban_init_fail2ban_conf.sh on $(ts)
[Definition]
dest = $dest
sender = $sender
subjectprefix = $prefix
sendmail_path = $sendmail_path
actionstart =
actionstop  =
actioncheck =
actionban = printf "From: %(sender)s\nTo: %(dest)s\nSubject: %(subjectprefix)s %(name)s: banned <ip>\n\nJail: %(name)s\nIP: <ip>\nDate: \$(date -R)\n\nMatches:\n<matches>\n" | %(sendmail_path)s -t -oi
actionunban = printf "From: %(sender)s\nTo: %(dest)s\nSubject: %(subjectprefix)s %(name)s: unbanned <ip>\n\nJail: %(name)s\nIP: <ip>\nDate: \$(date -R)\n" | %(sendmail_path)s -t -oi
[Init]
EOF
    chmod 0644 "$action_file"
    log "Wrote $action_file (active via sendmail)."
  else
    cat >"$action_file" <<'EOF'
# NFTBAN_F2B_SENDMAIL.conf - NO-OP mail action (no MTA detected)
[Definition]
dest = root@localhost
sender = nftban@localhost
subjectprefix = [nftban]
actionstart =
actionstop  =
actioncheck =
actionban = logger -t fail2ban "Mail alert skipped (no MTA). Jail=<name> IP=<ip>"
actionunban = logger -t fail2ban "Mail alert skipped (no MTA). Jail=<name> IP=<ip>"
[Init]
EOF
    chmod 0644 "$action_file"
    log "Wrote $action_file (NO-OP: no MTA)."
    echo "⚠️  No sendmail-compatible MTA found. For email alerts: apt/dnf/apk install postfix (or exim/msmtp/nullmailer)."
  fi
  echo "To use in a jail: action = $MAIL_ACTION_NAME[name=%(name)s, dest=$dest, sender=$sender]"
}

check_mail() {
  local smx; smx="$(detect_sendmail)"
  if [[ -n "$smx" ]]; then echo "MTA OK: sendmail interface at $smx"
  else echo "No sendmail-compatible MTA detected. Install postfix/exim/msmtp/nullmailer for email alerts."; fi
}
test_mail() {
  load_config_env || true
  local rcpt="${1:-${NFTBAN_F2B_RECIPIENT:-root@localhost}}"
  local sender="${NFTBAN_F2B_SENDER:-nftban@$(hostname -f)}"
  local sm; sm="$(detect_sendmail)"
  if [[ -z "$sm" ]]; then
    echo "No sendmail-compatible MTA detected. Install postfix/exim/msmtp/nullmailer for email alerts."
    return 2
  fi
  local subj="[nftban-test] sendmail check on $(hostname -f)"
  local body="This is a test message from nftban_init_fail2ban_conf.sh at $(date -R).
Sender: $sender
Recipient: $rcpt
If you see this, your MTA path ($sm) accepted the message."
  printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$sender" "$rcpt" "$subj" "$body" | "$sm" -t -oi
  local ec=$?
  if [[ $ec -eq 0 ]]; then
    echo "✅ Test mail submitted to $sm for $rcpt"
  else
    echo "❌ sendmail exited with code $ec"
  fi
  return $ec
}

# -----------------------------
# nftables manual helpers (NOT run in setup)
# -----------------------------
fmt_timeout() { local t="$1"; if [[ "$t" =~ ^[0-9]+$ ]]; then echo "${t}s"; elif [[ "$t" =~ ^[0-9]+[smhd]$ ]]; then echo "$t"; else echo "${t}s"; fi; }
ensure_nft_for_jail() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  local jail="$1" table="nftban_${jail}"
  if nft list table inet "$table" >/dev/null 2>&1; then log "nft table exists: inet $table"; return 0; fi
  nft add table inet "$table"
  nft add set   inet "$table" banned4   '{ type ipv4_addr; flags timeout; }'
  nft add set   inet "$table" banned6   '{ type ipv6_addr; flags timeout; }'
  nft add set   inet "$table" blacklist4 '{ type ipv4_addr; }'
  nft add set   inet "$table" blacklist6 '{ type ipv6_addr; }'
  nft add chain inet "$table" input "{ type filter hook input priority 0; policy accept; }"
  nft add rule  inet "$table" input ip   saddr @blacklist4 drop
  nft add rule  inet "$table" input ip6  saddr @blacklist6 drop
  nft add rule  inet "$table" input ip   saddr @banned4   drop
  nft add rule  inet "$table" input ip6  saddr @banned6   drop
  log "Created inet $table with banned/blacklist sets and input hook."
}
nft_ban_ip() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  local jail="$1" ip="$2" to="${3:-${NFTBAN_F2B_DEF_BAN_TIME:-3600}}" table="nftban_${jail}"
  ensure_nft_for_jail "$jail"
  if [[ -f "$WHITELIST_FILE" ]] && grep -E -v '^\s*(#|$)' "$WHITELIST_FILE" | awk '{$1=$1};1' | grep -Fxq "$ip"; then log "SKIP ban (whitelisted): $ip (jail=$jail)"; return 0; fi
  to="$(fmt_timeout "$to")"
  if [[ "$ip" == *:* ]]; then nft add element inet "$table" banned6 "{ $ip timeout $to }" || true
  else nft add element inet "$table" banned4 "{ $ip timeout $to }" || true; fi
  echo "[$(ts)] jail=${jail} action=ban ip=${ip} timeout=${to}" >>"$LOGFILE_IP"
  log "Banned $ip in $table for $to"
}
nft_unban_ip() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  local jail="$1" ip="$2" table="nftban_${jail}"
  if [[ "$ip" == *:* ]]; then nft delete element inet "$table" banned6 "{ $ip }" 2>/dev/null || true
  else nft delete element inet "$table" banned4 "{ $ip }" 2>/dev/null || true; fi
  log "Unbanned $ip from $table"
}

# -----------------------------
# Login monitor (live + timer)
# -----------------------------

write_login_monitor_live() {
  install -d -m 0755 /usr/local/sbin /var/log/nftban
  cat >"$LM_LIVE_BIN" <<'PY'
#!/usr/bin/env python3
import os, re, sys, time, subprocess, datetime, collections

BASE_CONF="/etc/nftban/config/nftban.conf"
LOCAL_CONF="/etc/nftban/config/nftban.conf.local"
LOG_DIR="/var/log/nftban"
LOG_FILE=os.path.join(LOG_DIR,"login-monitor.log")
DEBUG_LOG=os.path.join(LOG_DIR,"login-monitor-debug.log")

os.makedirs(LOG_DIR, exist_ok=True)

def log(m):
    ts=datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
    line=f"[{ts}] {m}"
    print(line, flush=True)
    try:
        with open(LOG_FILE,"a") as f:
            f.write(line+"\n")
    except Exception:
        pass

def debug_log(m):
    ts=datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
    line=f"[{ts}] DEBUG: {m}"
    try:
        with open(DEBUG_LOG,"a") as f:
            f.write(line+"\n")
    except Exception:
        pass

def parse_conf(p):
    d={}
    try:
        with open(p) as f:
            for raw in f:
                s=raw.strip()
                if not s or s.startswith("#"):
                    continue
                m=re.match(r"([A-Z0-9_]+)\s*=\s*(.*)$", s)
                if not m:
                    continue
                k,v=m.group(1),m.group(2)
                v=v.split("#",1)[0].strip()
                if len(v)>=2 and v[0]==v[-1] and v[0] in ("'",'"'):
                    v=v[1:-1]
                d[k]=v
    except FileNotFoundError:
        pass
    return d

def truthy(s,default=False):
    return (str(s).strip().lower() in ("1","true","yes","on")) if s is not None else default

def send_mail(subj, body, sender, dest):
    debug_log(f"Attempting to send email: {subj}")
    for p in ("/usr/sbin/sendmail","/usr/lib/sendmail","/usr/bin/sendmail"):
        if os.path.exists(p) and os.access(p, os.X_OK):
            try:
                proc=subprocess.Popen([p,"-t","-oi"], stdin=subprocess.PIPE, text=True)
                msg=f"From: {sender}\nTo: {dest}\nSubject: {subj}\n\n{body}\n"
                proc.communicate(msg, timeout=10)
                success = proc.returncode==0
                debug_log(f"Email send result: {success} (returncode: {proc.returncode})")
                return success
            except Exception as e:
                debug_log(f"Email send failed: {e}")
                return False
    debug_log("No sendmail binary found")
    return False

def main():
    log("Starting login monitor...")

    cfg={}
    cfg.update(parse_conf(BASE_CONF))
    cfg.update(parse_conf(LOCAL_CONF))

    debug_log(f"Loaded config keys: {list(cfg.keys())}")

    recipient=cfg.get("NFTBAN_F2B_RECIPIENT","root@localhost")
    sender=cfg.get("NFTBAN_F2B_SENDER", f"nftban@{os.uname().nodename}")
    prefix="[nftban-login]"

    root_alert=truthy(cfg.get("NFTBAN_F2B_ROOT_LOGIN_ALERT","true"),True)
    sudo_alert=truthy(cfg.get("NFTBAN_F2B_SUDO_ALERT","true"),True)
    ssh_alert=truthy(cfg.get("NFTBAN_F2B_SSH_LOGIN_ALERT","false"),False)
    thresh=int(cfg.get("NFTBAN_F2B_FAILED_LOGIN_THRESHOLD","5") or "5")
    window=int(cfg.get("NFTBAN_F2B_DEF_FIND_TIME","600") or "600")
    aggressive=truthy(cfg.get("NFTBAN_F2B_AGGRESSIVE_MODE","false"),False)
    ban_sec=int(cfg.get("NFTBAN_F2B_DEF_BAN_TIME","3600") or "3600")

    debug_log(f"Config - recipient: {recipient}, root_alert: {root_alert}, sudo_alert: {sudo_alert}, ssh_alert: {ssh_alert}")

    fails=collections.defaultdict(list)
    last_alert={}

    rx_acc=re.compile(r"Accepted (?:password|publickey|keyboard-interactive/pam|gssapi-with-mic) for (\S+) from ([0-9A-Fa-f\.:]+)", re.IGNORECASE)
    rx_fail=re.compile(r"Failed (?:password|publickey|keyboard-interactive/pam|gssapi-with-mic) for (?:invalid user )?(\S+) from ([0-9A-Fa-f\.:]+)", re.IGNORECASE)
    rx_sudo=re.compile(r"sudo:?\s+(\S+)\s*:.*(?:COMMAND=|command:)\s*(.*)$", re.IGNORECASE)
    rx_root_session=re.compile(r"session opened for user root", re.IGNORECASE)
    rx_su_root=re.compile(r"su:.*session opened for user root", re.IGNORECASE)
    rx_su_user=re.compile(r"su:.*session opened for user (\S+)", re.IGNORECASE)

    try:
        # Fixed journalctl command - removed conflicting -u flags
        cmd = [
            "journalctl", "-f", "-n", "0", "-o", "cat",
            "-t", "sshd", "-t", "sudo", "-t", "su", "-t", "systemd-logind",
            "--identifier=sshd", "--identifier=sudo", "--identifier=su"
        ]
        debug_log(f"Starting journalctl with command: {' '.join(cmd)}")
        proc=subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    except FileNotFoundError as e:
        log(f"Error starting journalctl: {e}")
        return 1

    def prune(ip,t):
        fails[ip][:] = [x for x in fails[ip] if t-x<=window]

    log("Monitor started, waiting for log entries...")

    while True:
        line = proc.stdout.readline()
        if not line:
            time.sleep(0.2)
            if proc.poll() is not None:
                log("journalctl process ended, restarting...")
                return 1
            continue

        l = line.strip()
        if not l:
            continue

        debug_log(f"Processing line: {l}")
        t = time.time()

        m = rx_fail.search(l)
        if m:
            user, ip = m.group(1), m.group(2)
            prune(ip, t)
            fails[ip].append(t)
            log(f"Failed login detected: user={user}, ip={ip}, total_fails={len(fails[ip])}")

            if len(fails[ip]) >= thresh and (ip not in last_alert or t-last_alert[ip] > window):
                subj = f"{prefix} Failed login threshold from {ip} ({len(fails[ip])}/{thresh})"
                body = f"IP: {ip}\nAttempts (last {window}s): {len(fails[ip])}\nLast user: {user}\nTime: {datetime.datetime.now()}\n"

                if send_mail(subj, body, sender, recipient):
                    log(f"Alert sent for failed logins from {ip}")
                else:
                    log(f"Failed to send alert for {ip}")

                last_alert[ip] = t

                if aggressive:
                    try:
                        subprocess.run(["/usr/local/sbin/nftban_init_fail2ban_conf.sh","ban","ssh",ip,str(ban_sec)],
                                     check=False, timeout=8)
                        log(f"Auto-banned {ip} (aggressive mode)")
                    except Exception as e:
                        log(f"Auto-ban failed for {ip}: {e}")
            continue

        m = rx_acc.search(l)
        if m:
            user, ip = m.group(1), m.group(2)
            log(f"Successful login detected: user={user}, ip={ip}")

            if (user=="root" and root_alert) or ssh_alert:
                subj = f"{prefix} SSH login: {user} from {ip}"
                body = f"User: {user}\nIP: {ip}\nTime: {datetime.datetime.now()}\nLog: {l}\n"

                if send_mail(subj, body, sender, recipient):
                    log(f"Alert sent for SSH login: {user}@{ip}")
                else:
                    log(f"Failed to send SSH login alert for {user}@{ip}")
            continue

        if root_alert and (rx_root_session.search(l) or rx_su_root.search(l)):
            subj = f"{prefix} root session opened"
            body = f"Time: {datetime.datetime.now()}\nLog: {l}\n"
            if send_mail(subj, body, sender, recipient):
                log("Alert sent for root session")
            else:
                log("Failed to send root session alert")
            continue

        if sudo_alert:
            m = rx_sudo.search(l)
            if m:
                who, cmd = m.group(1), m.group(2)
                log(f"Sudo usage detected: user={who}, command={cmd}")
                subj = f"{prefix} sudo used by {who}"
                body = f"User: {who}\nCommand: {cmd}\nTime: {datetime.datetime.now()}\nLog: {l}\n"
                if send_mail(subj, body, sender, recipient):
                    log(f"Alert sent for sudo usage by {who}")
                else:
                    log(f"Failed to send sudo alert for {who}")
                continue

        m = rx_su_user.search(l)
        if m and m.group(1) == "root" and root_alert:
            subj = f"{prefix} su to root"
            body = f"Time: {datetime.datetime.now()}\nLog: {l}\n"
            if send_mail(subj, body, sender, recipient):
                log("Alert sent for su to root")
            else:
                log("Failed to send su to root alert")

if __name__=="__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Login monitor stopped by user")
        sys.exit(0)
    except Exception as e:
        log(f"Login monitor crashed: {e}")
        sys.exit(1)
PY
  chmod 0755 "$LM_LIVE_BIN"
  cat >"$LM_LIVE_UNIT" <<'UNIT'
[Unit]
Description=NFTBAN Login Monitor (live)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/nftban-login-monitor
Restart=always
RestartSec=3
User=root
Group=root
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/log/nftban
[Install]
WantedBy=multi-user.target
UNIT
}

write_login_monitor_timer() {
  install -d -m 0755 /usr/local/sbin /var/log/nftban /var/lib/nftban/login-monitor
  cat >"$LM_SCAN_BIN" <<'PY'
#!/usr/bin/env python3
import os, re, sys, time, subprocess, datetime, json, collections
BASE_CONF="/etc/nftban/config/nftban.conf"
LOCAL_CONF="/etc/nftban/config/nftban.conf.local"
STATE_DIR="/var/lib/nftban/login-monitor"; os.makedirs(STATE_DIR,exist_ok=True)
LOG_DIR="/var/log/nftban"; os.makedirs(LOG_DIR,exist_ok=True)
STATE=os.path.join(STATE_DIR,"state.json"); LOG_FILE=os.path.join(LOG_DIR,"login-monitor.log")
def parse_conf(p):
    d={}
    try:
        for raw in open(p):
            s=raw.strip()
            if not s or s.startswith("#"): continue
            m=re.match(r"([A-Z0-9_]+)\s*=\s*(.*)$", s)
            if not m: continue
            k,v=m.group(1),m.group(2); v=v.split("#",1)[0].strip()
            if len(v)>=2 and v[0]==v[-1] and v[0] in ("'",'"'): v=v[1:-1]
            d[k]=v
    except FileNotFoundError: pass
    return d
truthy=lambda s,default=False: (str(s).strip().lower() in ("1","true","yes","on")) if s is not None else default
def send_mail(subj, body, sender, dest):
    for p in ("/usr/sbin/sendmail","/usr/lib/sendmail","/usr/bin/sendmail"):
        if os.path.exists(p) and os.access(p, os.X_OK):
            try:
                proc=subprocess.Popen([p,"-t","-oi"], stdin=subprocess.PIPE, text=True)
                msg=f"From: {sender}\nTo: {dest}\nSubject: {subj}\n\n{body}\n"
                proc.communicate(msg, timeout=10); return proc.returncode==0
            except Exception: return False
    return False
def parse_interval(s, default_sec=600):
    if not s: return default_sec
    s=s.strip().lower()
    try:
        if s.endswith("ms"): return max(int(float(s[:-2])/1000),1)
        if s.endswith("s"):  return int(float(s[:-1]))
        if s.endswith("m"):  return int(float(s[:-1])*60)
        if s.endswith("h"):  return int(float(s[:-1])*3600)
        if s.endswith("d"):  return int(float(s[:-1])*86400)
        return int(float(s))
    except Exception: return default_sec
def load_cfg():
    d={}; d.update(parse_conf(BASE_CONF)); d.update(parse_conf(LOCAL_CONF)); return d
def load_state(path):
    try: import json; return json.load(open(path))
    except Exception: return {}
def save_state(path, st):
    import json, os
    tmp=path+".tmp"; open(tmp,"w").write(json.dumps(st)); os.replace(tmp,path)
def run():
    cfg=load_cfg()
    recipient=cfg.get("NFTBAN_F2B_RECIPIENT","root@localhost")
    sender=cfg.get("NFTBAN_F2B_SENDER", f"nftban@{os.uname().nodename}")
    prefix="[nftban-login-digest]"
    root_alert=truthy(cfg.get("NFTBAN_F2B_ROOT_LOGIN_ALERT","true"),True)
    sudo_alert=truthy(cfg.get("NFTBAN_F2B_SUDO_ALERT","true"),True)
    ssh_alert=truthy(cfg.get("NFTBAN_F2B_SSH_LOGIN_ALERT","false"),False)
    window=parse_interval(cfg.get("NFTBAN_F2B_LOGIN_TIMER_INTERVAL","10m"),600)
    state_file=os.path.join(STATE_DIR,"state.json"); st=load_state(state_file)
    since_ts=st.get("last_ts", int(time.time())-window)
    since_arg=f"@{int(since_ts)}"
    try:
        # (1) Critical Bug Fix in Timer Script:
        # Remove conflicting -u unit filters; rely on tags/identifiers only.
        out=subprocess.check_output(
            ["journalctl","-o","cat","--since",since_arg,
             "-t","sshd","-t","sudo","-t","su"],
            text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return 1
    st["last_ts"]=int(time.time()); save_state(state_file, st)
    lines=[l for l in out.splitlines() if l.strip()]
    if not lines: return 0
    rx_acc=re.compile(r"Accepted (?:password|publickey|keyboard-interactive/pam) for (\S+) from ([0-9A-Fa-f\.:]+)")
    rx_fail=re.compile(r"Failed password for (?:invalid user )?(\S+) from ([0-9A-Fa-f\.:]+)")
    rx_sudo=re.compile(r"sudo:?\s+(\S+)\s*:.*COMMAND=(.*)$")
    rx_root=re.compile(r"session opened for user root")
    import collections
    failed_by_ip=collections.Counter(); failed_by_user=collections.Counter(); sudo_by_user=collections.Counter(); ssh_logins=[]
    for l in lines:
        m=rx_fail.search(l)
        if m:
            user,ip=m.group(1),m.group(2); failed_by_ip[ip]+=1; failed_by_user[user]+=1; continue
        m=rx_acc.search(l)
        if m and (ssh_alert or root_alert):
            user,ip=m.group(1),m.group(2); ssh_logins.append((user,ip,l)); continue
        if sudo_alert:
            m=rx_sudo.search(l)
            if m: sudo_by_user[m.group(1)]+=1; continue
        if root_alert and rx_root.search(l): ssh_logins.append(("root","?",l))
    total_fails=sum(failed_by_ip.values()); total_sudo=sum(sudo_by_user.values())
    should_send= total_fails>0 or total_sudo>0 or (ssh_alert and len(ssh_logins)>0)
    if not should_send: return 0
    def topn(c,n=10):
        return "\n".join([f"  {k}: {v}" for k,v in c.most_common(n)]) or "  (none)"
    body=[]
    body.append(f"Window: last {window} seconds"); body.append("")
    body.append(f"Failed logins: {total_fails}"); body.append(topn(failed_by_ip)); body.append("")
    body.append("Top usernames (failed):"); body.append(topn(failed_by_user)); body.append("")
    body.append(f"Sudo invocations: {total_sudo}"); body.append(topn(sudo_by_user))
    if ssh_alert or root_alert:
        body.append(""); body.append("SSH logins (sample up to 10):")
        for (u,ip,line) in ssh_logins[:10]: body.append(f"  {u} from {ip} :: {line[:140]}")
    send_mail(f"{prefix} digest", "\n".join(body), sender, recipient); return 0
if __name__=="__main__": sys.exit(run())
PY
  chmod 0755 "$LM_SCAN_BIN"
  cat >"$LM_SCAN_UNIT" <<'UNIT'
[Unit]
Description=NFTBAN Login Monitor (periodic scan)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nftban-login-scan
User=root
Group=root
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/log/nftban /var/lib/nftban
UNIT
  cat >"$LM_TIMER_UNIT" <<'UNIT'
[Unit]
Description=Run nftban-login-scan periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
}

login_monitor_install() {
  write_login_monitor_live
  write_login_monitor_timer
  systemctl daemon-reload
  echo "Login monitor files installed. (Nothing enabled automatically.)"
  echo "Enable with: nftban_init_fail2ban_conf.sh login-monitor enable <service|timer|hybrid>"
}
login_monitor_enable() {
  local mode="${1:-}"; [[ -z "$mode" ]] && die "login-monitor enable requires <service|timer|hybrid>"
  case "$mode" in
    service) systemctl enable --now "$(basename "$LM_LIVE_UNIT")" ;;
    timer)   systemctl enable --now "$(basename "$LM_TIMER_UNIT")" ;;
    hybrid)  systemctl enable --now "$(basename "$LM_LIVE_UNIT")" "$(basename "$LM_TIMER_UNIT")" ;;
    *) die "Unknown mode: $mode (use service|timer|hybrid)" ;;
  esac
  echo "Enabled login monitor ($mode)."
}
login_monitor_disable() {
  local mode="${1:-all}"
  case "$mode" in
    service) systemctl disable --now "$(basename "$LM_LIVE_UNIT")" || true ;;
    timer)   systemctl disable --now "$(basename "$LM_TIMER_UNIT")" || true ;;
    hybrid|all)
      systemctl disable --now "$(basename "$LM_LIVE_UNIT")" || true
      systemctl disable --now "$(basename "$LM_TIMER_UNIT")" || true
      ;;
    *) die "Unknown mode: $mode (use service|timer|hybrid|all)" ;;
  esac
  echo "Disabled login monitor ($mode)."
}
login_monitor_status() {
  systemctl status "$(basename "$LM_LIVE_UNIT")" --no-pager || true
  echo "----"
  systemctl status "$(basename "$LM_SCAN_UNIT")" --no-pager || true
  echo "----"
  systemctl status "$(basename "$LM_TIMER_UNIT")" --no-pager || true
}
login_monitor_uninstall() {
  login_monitor_disable all || true
  echo "[*] Stopping/Disabling units…"
  systemctl stop nftban_lfd.service nftban-login-scan.service nftban-login-scan.timer 2>/dev/null || true
  systemctl disable nftban_lfd.service nftban-login-scan.timer 2>/dev/null || true
  systemctl reset-failed nftban_lfd.service nftban-login-scan.service nftban-login-scan.timer 2>/dev/null || true
  echo "[*] Killing any leftover processes…"
  pkill -f -- '/usr/local/sbin/nftban-login-monitor' 2>/dev/null || true
  pkill -f -- 'journalctl -f .*nftban' 2>/dev/null || true
  echo "[*] Removing unit files…"
  rm -f -- "${LM_LIVE_UNIT:-/etc/systemd/system/nftban_lfd.service}" \
            "${LM_SCAN_UNIT:-/etc/systemd/system/nftban-login-scan.service}" \
            "${LM_TIMER_UNIT:-/etc/systemd/system/nftban-login-scan.timer}"
  rm -f -- /etc/systemd/system/nftban_lfd.service.d/override.conf 2>/dev/null || true
  rmdir  --ignore-fail-on-non-empty /etc/systemd/system/nftban_lfd.service.d 2>/dev/null || true
  echo "[*] Removing installed binaries…"
  rm -f -- "${LM_LIVE_BIN:-/usr/local/sbin/nftban-login-monitor}" \
            "${LM_SCAN_BIN:-/usr/local/sbin/nftban-login-scan}"
  echo "[*] Reloading systemd…"
  systemctl daemon-reload
  echo "[*] Sanity check…"
  systemctl list-units --all | grep -i 'nftban' || echo "No nftban units loaded"
  command -v nftban-login-monitor >/dev/null || echo "No nftban-login-monitor in PATH"
  echo "Login monitor removed. Logs/state preserved."
}

ensure_local_config() {
  if [[ ! -f "$CONFIG_FILE_USER" ]]; then
    install -D -m 0644 -o root -g root "$CONFIG_FILE" "$CONFIG_FILE_USER"
    log "Created user config from reference: $CONFIG_FILE_USER"
    echo ""
    echo "Next step:"
    echo "  1) Edit $CONFIG_FILE_USER   (set NFTBAN_F2B_RECIPIENT, enable jails, etc.)"
    echo "  2) Run: nftban_init_fail2ban_conf.sh setup   again to apply checks and staging."
    echo ""
    exit 0
  fi
}

# -----------------------------
# (8) Better Status Reporting
# -----------------------------
show_system_status() {
  echo "=== NFTBAN System Status ==="
  echo "Base config: $CONFIG_FILE"
  echo "User config: $CONFIG_FILE_USER"
  echo
  echo "Enabled jails:"
  while read -r jail; do
    [[ -n "$jail" ]] || continue
    echo "  - $jail"
  done < <(enabled_jails)
  echo
  echo "Service status:"
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "  - fail2ban: active"
  else
    echo "  - fail2ban: inactive"
  fi
  if systemctl is-active --quiet nftban_lfd 2>/dev/null; then
    echo "  - login monitor (live): active"
  else
    echo "  - login monitor (live): inactive"
  fi
  if systemctl is-active --quiet nftban-login-scan.timer 2>/dev/null; then
    echo "  - login monitor (timer): active"
  else
    echo "  - login monitor (timer): inactive"
  fi
  echo
  echo "Recent bans (last 10):"
  tail -n 10 "$LOGFILE_IP" 2>/dev/null | sed 's/^/  /' || echo "  (no ban log found)"
}

# -----------------------------
# (9) Configuration Backup / Restore
# -----------------------------
backup_config() {
  install -d -m 0755 "$BACKUP_DIR"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local archive="$BACKUP_DIR/nftban-config-$ts.tar.gz"
  tar -czf "$archive" -C "$(dirname "$CONFIG_FILE_USER")" "$(basename "$CONFIG_FILE_USER")" \
      "$(basename "$WHITELIST_FILE")" "$(basename "$BLACKLIST_FILE")" 2>/dev/null || true
  log "Configuration backed up to: $archive"
  echo "$archive"
}
list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { echo "No backups found."; return 1; }
  ls -1 "$BACKUP_DIR"/nftban-config-*.tar.gz 2>/dev/null || echo "No backups found."
}
restore_config() {
  local src="${1:-}"
  [[ -n "$src" ]] || die "restore-config requires </path/to/archive.tar.gz>"
  [[ -f "$src" ]] || die "Archive not found: $src"
  local tmp; tmp="$(mktemp -d)"
  tar -xzf "$src" -C "$tmp"
  install -D -m 0644 -o root -g root "$tmp/$(basename "$CONFIG_FILE_USER")" "$CONFIG_FILE_USER" 2>/dev/null || true
  [[ -f "$tmp/$(basename "$WHITELIST_FILE")" ]] && install -D -m 0644 -o root -g root "$tmp/$(basename "$WHITELIST_FILE")" "$WHITELIST_FILE"
  [[ -f "$tmp/$(basename "$BLACKLIST_FILE")" ]] && install -D -m 0644 -o root -g root "$tmp/$(basename "$BLACKLIST_FILE")" "$BLACKLIST_FILE"
  rm -rf "$tmp"
  log "Configuration restored from: $src"
}

# -----------------------------
# (12) Documentation Generation
# -----------------------------
generate_config_docs() {
  install -d -m 0755 "$BASE_DIR"
  cat > "$BASE_DIR/CONFIG_REFERENCE.md" <<'DOC'
# NFTBAN Configuration Reference

> This file documents the keys available in `/etc/nftban/config/nftban.conf` and
> your override file `/etc/nftban/config/nftban.conf.local`. Edit only the `.local`.

## Email
- `NFTBAN_F2B_RECIPIENT` — recipient for alerts.
- `NFTBAN_F2B_SENDER` — From address for alerts.
- `NFTBAN_F2B_ALERT_ENABLED` — `"true"`/`"false"` to toggle email alerts.

## Defaults
- `NFTBAN_F2B_DEF_BAN_TIME` — default ban seconds.
- `NFTBAN_F2B_DEF_FIND_TIME` — fail window seconds.
- `NFTBAN_F2B_DEF_MAX_RETRY` — max retries in window.
- `NFTBAN_F2B_BACKEND` — usually `"systemd"`.

## Security & Monitor
- `NFTBAN_F2B_AGGRESSIVE_MODE` — auto-ban on login monitor threshold.
- `NFTBAN_F2B_GEOIP_ENABLE`, `NFTBAN_F2B_WHOIS_ENABLE` — reserved for future use.
- `NFTBAN_F2B_LOGIN_MONITOR` — enable login monitor.
- `NFTBAN_F2B_ROOT_LOGIN_ALERT`, `NFTBAN_F2B_SUDO_ALERT`, `NFTBAN_F2B_SSH_LOGIN_ALERT`.
- `NFTBAN_F2B_FAILED_LOGIN_THRESHOLD` — attempts before alert.

## Jails (set `..._JAIL="true"` to enable)
SSH / Apache / Nginx / Postfix / WordPress / XMLRPC / DirectAdmin,
with corresponding `..._BAN_TIME`, `..._MAX_RETRY`, `..._FIND_TIME`.

## Lists
- Whitelist file path (ignored IPs): `/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local`
- Blacklist file path: `/etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local`

> See `nftban_init_fail2ban_conf.sh diff-config` to compare base vs local.
DOC
  echo "Configuration reference written to $BASE_DIR/CONFIG_REFERENCE.md"
}

# -----------------------------
# High-level flows
# -----------------------------
setup_all() {
  ensure_root
  init_dirs
  refresh_base_config
  ensure_local_config
  show_config_diff || true
  load_config_env               # base + .local
  validate_config               # (2) validation gate
  verify_and_stage_templates
  generate_mail_action
  log "Setup complete (non-invasive). Enable services yourself if desired."
}

# -----------------------------
# CLI & help
# -----------------------------
usage() {
  cat <<USAGE
nftban_init_fail2ban_conf.sh — all-in-one helper

IMPORTANT:
  • On every 'setup', this script refreshes the reference config:
      $CONFIG_FILE
    (Backs up the old file if content changed.)
  • Your real configuration belongs in:
      $CONFIG_FILE_USER
    If it doesn't exist, the script creates it from the reference and STOPS.

Quick start:
  sudo nftban_init_fail2ban_conf.sh setup

Config & validation:
  nftban_init_fail2ban_conf.sh diff-config
  nftban_init_fail2ban_conf.sh validate-config
  nftban_init_fail2ban_conf.sh gen-docs

Status:
  nftban_init_fail2ban_conf.sh status
  nftban_init_fail2ban_conf.sh login-monitor status

Backup / Restore:
  nftban_init_fail2ban_conf.sh backup-config
  nftban_init_fail2ban_conf.sh list-backups
  nftban_init_fail2ban_conf.sh restore-config </path/to/archive.tar.gz>

Mail:
  nftban_init_fail2ban_conf.sh check-mail
  nftban_init_fail2ban_conf.sh test-mail [recipient]
  nftban_init_fail2ban_conf.sh generate-mail-action

Login monitor:
  nftban_init_fail2ban_conf.sh login-monitor install
  nftban_init_fail2ban_conf.sh login-monitor enable <service|timer|hybrid>
  nftban_init_fail2ban_conf.sh login-monitor disable [service|timer|hybrid|all]
  nftban_init_fail2ban_conf.sh login-monitor status
  nftban_init_fail2ban_conf.sh login-monitor uninstall

nftables (manual only; NOT run by 'setup'):
  nftban_init_fail2ban_conf.sh nft-init <jail>
  nftban_init_fail2ban_conf.sh ban <jail> <ip> [seconds|Ns|Nm|Nh|Nd]
  nftban_init_fail2ban_conf.sh unban <jail> <ip>
USAGE
}

main() {
  local cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    --help|-h|help|"") usage ;;
    setup) setup_all ;;
    diff-config) show_config_diff ;;
    validate-config) load_config_env; validate_config && echo "Configuration is valid" ;;
    gen-docs) generate_config_docs ;;
    status) show_system_status ;;

    # Backup / Restore (11: CLI improvements - backup part)
    backup-config) backup_config ;;
    list-backups) list_backups ;;
    restore-config) restore_config "${1:-}" ;;

    # Mail helpers
    check-mail) check_mail ;;
    test-mail|mail-test) test_mail "$@" ;;
    generate-mail-action) load_config_env; generate_mail_action ;;

    # nftables helpers
    nft-init) [[ $# -eq 1 ]] || die "nft-init requires <jail>"; ensure_nft_for_jail "$1" ;;
    ban) [[ $# -ge 2 ]] || die "ban requires <jail> <ip> [timeout]"; load_config_env; nft_ban_ip "$1" "$2" "${3:-${NFTBAN_F2B_DEF_BAN_TIME:-3600}}" ;;
    unban) [[ $# -eq 2 ]] || die "unban requires <jail> <ip>"; nft_unban_ip "$1" "$2" ;;

    # Login monitor subcommands
    login-monitor)
      local sub="${1:-}"; shift || true
      case "${sub:-}" in
        install) login_monitor_install ;;
        enable)  login_monitor_enable "${1:-}" ;;
        disable) login_monitor_disable "${1:-all}" ;;
        status)  login_monitor_status ;;
        uninstall) login_monitor_uninstall ;;
        ""|-h|--help) echo "login-monitor {install|enable <service|timer|hybrid>|disable [mode]|status|uninstall}" ;;
        *) die "Unknown login-monitor subcommand: $sub" ;;
      esac
      ;;
    *) die "Unknown command: $cmd (use --help)" ;;
  esac
}
main "$@"

# === End merged content from: nftban_init_fail2ban_conf (2).sh ===
