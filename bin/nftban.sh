#!/bin/bash
###############################################################################
# Script: nftban.sh
# A comprehensive nftables and fail2ban management tool with IP allowlist
# Version: 3.6.0 (Enhanced with sync validation and active set checking)
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   One-stop helper to manage nftables & Fail2Ban and to handle allow/deny IPs.
#   Compatible with the single-table layout created by your init script:
#       table inet nftban_global
#       sets  temp_ban_v4/v6, whitelist_v4/v6, user_blacklist_v4/v6, system_blacklist_v4/v6
#
# NEW in v3.6.0:
#   • Validates file contents against active nftables sets
#   • Checks both user AND system whitelist files
#   • Shows sync status between files and active rules
#   • Can verify IP presence across all sources (files + active sets)
#   • Improved remove operations (handles permanent sets too)
###############################################################################

# ------------------------------ Configuration ------------------------------ #
BASE_DIR="/etc/nftban/config"
CONF_FILE="/etc/nftables.conf"
USER_WHITELIST_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_FILE="/var/log/nftban/nftban.log"

TEMP_BAN_TABLE="nftban_global"
# Set names in the global table
TEMP_BAN_SET_V4="temp_ban_v4"
TEMP_BAN_SET_V6="temp_ban_v6"
WHITELIST_SET_V4="whitelist_v4"
WHITELIST_SET_V6="whitelist_v6"
USER_BLACKLIST_SET_V4="user_blacklist_v4"
USER_BLACKLIST_SET_V6="user_blacklist_v6"
SYSTEM_BLACKLIST_SET_V4="system_blacklist_v4"
SYSTEM_BLACKLIST_SET_V6="system_blacklist_v6"

FAIL2BAN_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_DIR="$FAIL2BAN_DIR/jail.d"

IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
USER_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-user-blacklist_ips.conf.local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Version information
VERSION="3.6.0"
VERSION_FILE="/etc/nftban/.version"

# ------------------------------- Utilities -------------------------------- #
log() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [ "${ENABLE_LOGGING:-true}" = true ]; then
    echo "$timestamp - $message" | tee -a "$LOG_FILE"
  else
    echo "$timestamp - $message"
  fi
}

# IMPROVED IP VALIDATION 
# --------------------------------------------------
is_ipv4_or_cidr() {
    local ip="$1"
    # Extract IP part (before /)
    local ip_part="${ip%/*}"
    local cidr_part="${ip#*/}"
    
    # Validate CIDR if present
    if [[ "$ip" == *"/"* ]]; then
        [[ "$cidr_part" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
    fi
    
    # Validate each octet
    IFS='.' read -ra OCTETS <<< "$ip_part"
    [[ ${#OCTETS[@]} -eq 4 ]] || return 1
    
    for octet in "${OCTETS[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

is_ipv6_or_cidr() {
    local ip="$1"
    # Basic IPv6 validation
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:./]+$ ]] || return 1
    
    # If CIDR present, validate
    if [[ "$ip" == *"/"* ]]; then
        local cidr="${ip#*/}"
        [[ "$cidr" =~ ^([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$ ]] || return 1
    fi
    return 0
}

is_ip_like() { is_ipv4_or_cidr "$1" || is_ipv6_or_cidr "$1"; }

# Service status functions
get_nftables_status() {
    if systemctl is-active nftables >/dev/null 2>&1; then
        echo "active"
    else
        echo "inactive"
    fi
}

get_fail2ban_status() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            echo "active"
        else
            echo "inactive"
        fi
    else
        echo "not installed"
    fi
}

# NEW: Functions to read active nftables sets
# --------------------------------------------------
get_set_elements() {
    local table="$1"
    local set_name="$2"
    
    if ! nft list set inet "$table" "$set_name" >/dev/null 2>&1; then
        return 1
    fi
    
    # Extract just the IP addresses from the set
    nft list set inet "$table" "$set_name" 2>/dev/null | \
        grep -v "^table\|^[[:space:]]*set\|^[[:space:]]*type\|^[[:space:]]*flags\|^[[:space:]]*}\|^}" | \
        grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?' | \
        sort -u
}

get_ips_from_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    # Extract IPs from file (first column, ignore comments)
    grep -v '^\s*#' "$file" 2>/dev/null | \
        awk '{print $1}' | \
        grep -E '^[0-9]|^[0-9a-fA-F]*:' | \
        sort -u
}

# NEW: Check if IP exists in any whitelist (file or set)
# --------------------------------------------------
is_ip_whitelisted() {
    local ip="$1"
    local found=false
    
    # Check user whitelist file
    if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
        found=true
    fi
    
    # Check system whitelist file
    if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
        found=true
    fi
    
    # Check active nftables sets
    if [[ "$ip" =~ .*:.* ]]; then
        if get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" | grep -Fxq "$ip"; then
            found=true
        fi
    else
        if get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" | grep -Fxq "$ip"; then
            found=true
        fi
    fi
    
    [ "$found" = true ] && return 0 || return 1
}

# NEW: Comprehensive IP verification across all sources
# --------------------------------------------------
verify_ip_location() {
    local ip="$1"
    local found_anywhere=false
    
    echo -e "${CYAN}=== IP Location Report: $ip ===${NC}"
    echo ""
    
    # Check whitelist files
    echo -e "${BLUE}Whitelist Files:${NC}"
    if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
        echo -e "  ${GREEN}✓${NC} Found in user whitelist: $USER_WHITELIST_FILE"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in user whitelist"
    fi
    
    if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
        echo -e "  ${GREEN}✓${NC} Found in system whitelist: $SYSTEM_WHITELIST_FILE"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in system whitelist"
    fi
    
    # Check blacklist files
    echo ""
    echo -e "${BLUE}Blacklist Files:${NC}"
    if [ -f "$USER_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_BLACKLIST_FILE"; then
        echo -e "  ${RED}✓${NC} Found in user blacklist: $USER_BLACKLIST_FILE"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in user blacklist"
    fi
    
    if [[ "$ip" =~ .*:.* ]]; then
        if [ -f "$IPV6_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$IPV6_BLACKLIST_FILE"; then
            echo -e "  ${RED}✓${NC} Found in IPv6 blacklist: $IPV6_BLACKLIST_FILE"
            found_anywhere=true
        else
            echo -e "  ${YELLOW}✗${NC} Not in IPv6 blacklist"
        fi
    else
        if [ -f "$IPV4_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$IPV4_BLACKLIST_FILE"; then
            echo -e "  ${RED}✓${NC} Found in IPv4 blacklist: $IPV4_BLACKLIST_FILE"
            found_anywhere=true
        else
            echo -e "  ${YELLOW}✗${NC} Not in IPv4 blacklist"
        fi
    fi
    
    # Check active nftables sets
    echo ""
    echo -e "${BLUE}Active nftables Sets:${NC}"
    
    local set_v4_or_v6
    if [[ "$ip" =~ .*:.* ]]; then
        set_v4_or_v6="v6"
    else
        set_v4_or_v6="v4"
    fi
    
    # Whitelist sets
    local whitelist_set="WHITELIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!whitelist_set}" 2>/dev/null | grep -Fxq "$ip"; then
        echo -e "  ${GREEN}✓${NC} Found in ${!whitelist_set}"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in ${!whitelist_set}"
    fi
    
    # User blacklist sets
    local user_bl_set="USER_BLACKLIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!user_bl_set}" 2>/dev/null | grep -Fxq "$ip"; then
        echo -e "  ${RED}✓${NC} Found in ${!user_bl_set}"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in ${!user_bl_set}"
    fi
    
    # System blacklist sets
    local sys_bl_set="SYSTEM_BLACKLIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!sys_bl_set}" 2>/dev/null | grep -Fxq "$ip"; then
        echo -e "  ${RED}✓${NC} Found in ${!sys_bl_set}"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in ${!sys_bl_set}"
    fi
    
    # Temp ban sets
    local temp_ban_set="TEMP_BAN_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!temp_ban_set}" 2>/dev/null | grep -Fxq "$ip"; then
        echo -e "  ${RED}✓${NC} Found in ${!temp_ban_set} (temporary)"
        found_anywhere=true
    else
        echo -e "  ${YELLOW}✗${NC} Not in ${!temp_ban_set}"
    fi
    
    # Check fail2ban
    echo ""
    echo -e "${BLUE}Fail2Ban Status:${NC}"
    if command -v fail2ban-client >/dev/null 2>&1; then
        local found_in_jail=false
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
            if fail2ban-client status "$jail" 2>/dev/null | grep -q "$ip"; then
                echo -e "  ${RED}✓${NC} Banned in fail2ban jail: $jail"
                found_in_jail=true
                found_anywhere=true
            fi
        done
        if [ "$found_in_jail" = false ]; then
            echo -e "  ${YELLOW}✗${NC} Not banned in any fail2ban jail"
        fi
    else
        echo -e "  ${YELLOW}Fail2ban not installed${NC}"
    fi
    
    echo ""
    if [ "$found_anywhere" = true ]; then
        echo -e "${GREEN}IP found in at least one location${NC}"
        return 0
    else
        echo -e "${YELLOW}IP not found in any location${NC}"
        return 1
    fi
}

# NEW: Validate sync between files and active sets
# --------------------------------------------------
validate_sync_status() {
    echo -e "${CYAN}=== Sync Status: Files vs Active nftables Sets ===${NC}"
    echo ""
    
    local issues_found=0
    
    # Check whitelist sync (both user and system)
    echo -e "${BLUE}Whitelist Synchronization:${NC}"
    
    # Combine user and system whitelist IPs
    local file_whitelist_v4=$(mktemp)
    local file_whitelist_v6=$(mktemp)
    
    get_ips_from_file "$USER_WHITELIST_FILE" | grep -v ':' > "$file_whitelist_v4" 2>/dev/null || true
    get_ips_from_file "$SYSTEM_WHITELIST_FILE" | grep -v ':' >> "$file_whitelist_v4" 2>/dev/null || true
    get_ips_from_file "$USER_WHITELIST_FILE" | grep ':' > "$file_whitelist_v6" 2>/dev/null || true
    get_ips_from_file "$SYSTEM_WHITELIST_FILE" | grep ':' >> "$file_whitelist_v6" 2>/dev/null || true
    
    sort -u "$file_whitelist_v4" -o "$file_whitelist_v4"
    sort -u "$file_whitelist_v6" -o "$file_whitelist_v6"
    
    local active_whitelist_v4=$(mktemp)
    local active_whitelist_v6=$(mktemp)
    
    get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" > "$active_whitelist_v4" 2>/dev/null || true
    get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" > "$active_whitelist_v6" 2>/dev/null || true
    
    # Compare IPv4 whitelist
    local file_count=$(wc -l < "$file_whitelist_v4")
    local active_count=$(wc -l < "$active_whitelist_v4")
    
    echo -e "  IPv4 Whitelist: ${file_count} in files, ${active_count} in ${WHITELIST_SET_V4}"
    
    local in_file_not_active=$(comm -23 "$file_whitelist_v4" "$active_whitelist_v4" | wc -l)
    local in_active_not_file=$(comm -13 "$file_whitelist_v4" "$active_whitelist_v4" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        echo -e "    ${GREEN}✓${NC} IPv4 whitelist in sync"
    fi
    
    # Compare IPv6 whitelist
    file_count=$(wc -l < "$file_whitelist_v6")
    active_count=$(wc -l < "$active_whitelist_v6")
    
    echo -e "  IPv6 Whitelist: ${file_count} in files, ${active_count} in ${WHITELIST_SET_V6}"
    
    in_file_not_active=$(comm -23 "$file_whitelist_v6" "$active_whitelist_v6" | wc -l)
    in_active_not_file=$(comm -13 "$file_whitelist_v6" "$active_whitelist_v6" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        echo -e "    ${GREEN}✓${NC} IPv6 whitelist in sync"
    fi
    
    # Check blacklist sync
    echo ""
    echo -e "${BLUE}Blacklist Synchronization:${NC}"
    
    # User blacklist IPv4
    local file_bl_v4=$(mktemp)
    local active_bl_v4=$(mktemp)
    
    get_ips_from_file "$USER_BLACKLIST_FILE" | grep -v ':' > "$file_bl_v4" 2>/dev/null || true
    get_ips_from_file "$IPV4_BLACKLIST_FILE" >> "$file_bl_v4" 2>/dev/null || true
    sort -u "$file_bl_v4" -o "$file_bl_v4"
    
    get_set_elements "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V4" > "$active_bl_v4" 2>/dev/null || true
    
    file_count=$(wc -l < "$file_bl_v4")
    active_count=$(wc -l < "$active_bl_v4")
    
    echo -e "  IPv4 User Blacklist: ${file_count} in files, ${active_count} in ${USER_BLACKLIST_SET_V4}"
    
    in_file_not_active=$(comm -23 "$file_bl_v4" "$active_bl_v4" | wc -l)
    in_active_not_file=$(comm -13 "$file_bl_v4" "$active_bl_v4" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        echo -e "    ${YELLOW}⚠${NC}  ${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        echo -e "    ${GREEN}✓${NC} IPv4 user blacklist in sync"
    fi
    
    # Cleanup temp files
    rm -f "$file_whitelist_v4" "$file_whitelist_v6" "$active_whitelist_v4" "$active_whitelist_v6"
    rm -f "$file_bl_v4" "$active_bl_v4"
    
    echo ""
    if [ "$issues_found" -eq 0 ]; then
        echo -e "${GREEN}✓ All sets are in sync with configuration files${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Found $issues_found sync issue(s)${NC}"
        echo -e "${CYAN}Run 'nftban --sync' to reload nftables configuration${NC}"
        return 1
    fi
}

# NEW: Show all nftables sets contents
# --------------------------------------------------
show_all_sets() {
    echo -e "${CYAN}=== All nftables Sets in ${TEMP_BAN_TABLE} ===${NC}"
    echo ""
    
    local sets=(
        "$WHITELIST_SET_V4:Whitelist IPv4"
        "$WHITELIST_SET_V6:Whitelist IPv6"
        "$USER_BLACKLIST_SET_V4:User Blacklist IPv4"
        "$USER_BLACKLIST_SET_V6:User Blacklist IPv6"
        "$SYSTEM_BLACKLIST_SET_V4:System Blacklist IPv4"
        "$SYSTEM_BLACKLIST_SET_V6:System Blacklist IPv6"
        "$TEMP_BAN_SET_V4:Temp Ban IPv4"
        "$TEMP_BAN_SET_V6:Temp Ban IPv6"
    )
    
    for set_info in "${sets[@]}"; do
        local set_name="${set_info%%:*}"
        local set_label="${set_info#*:}"
        
        echo -e "${BLUE}${set_label} (${set_name}):${NC}"
        
        if ! nft list set inet "$TEMP_BAN_TABLE" "$set_name" >/dev/null 2>&1; then
            echo -e "  ${RED}Set not found${NC}"
            continue
        fi
        
        local elements
        elements=$(get_set_elements "$TEMP_BAN_TABLE" "$set_name")
        
        if [ -z "$elements" ]; then
            echo -e "  ${YELLOW}(empty)${NC}"
        else
            local count=$(echo "$elements" | wc -l)
            echo -e "  ${GREEN}${count} element(s)${NC}"
            echo "$elements" | sed 's/^/    /'
        fi
        echo ""
    done
}

# NEW: Trigger nftables reload from configuration
# --------------------------------------------------
sync_nftables() {
    echo -e "${BLUE}Synchronizing nftables with configuration files...${NC}"
    
    # Check if init script exists
    local init_script
    init_script="$(dirname "$BASE_DIR")/scripts/nftban_init_nftables_conf.sh"
    
    if [ ! -f "$init_script" ]; then
        echo -e "${RED}Init script not found: $init_script${NC}"
        echo -e "${YELLOW}Cannot reload configuration automatically${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Running nftables initialization script...${NC}"
    
    if [ -x "$init_script" ]; then
        if "$init_script" --install-final; then
            echo -e "${GREEN}✓ nftables configuration reloaded successfully${NC}"
            log "Synchronized nftables configuration from files"
            return 0
        else
            echo -e "${RED}Failed to reload nftables configuration${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}Making script executable and running...${NC}"
        chmod +x "$init_script"
        if "$init_script" --install-final; then
            echo -e "${GREEN}✓ nftables configuration reloaded successfully${NC}"
            log "Synchronized nftables configuration from files"
            return 0
        else
            echo -e "${RED}Failed to reload nftables configuration${NC}"
            return 1
        fi
    fi
}

# ------------------------------ Enhanced Help ------------------------------ #
show_help() {
  cat << 'EOF'
NFTBan – nftables & Fail2Ban helper (v3.6.0)
===========================================

USAGE
-----
  nftban [OPTION]

CORE OPTIONS
------------
  -e, --enable                 Enable and start nftables and Fail2Ban services after config check
  -d, --disable                Disable and stop nftables and Fail2Ban services
  -s, --start                  Start nftables and Fail2Ban services after config check
  -r, --restart                Restart nftables and Fail2Ban services after config check
  -x, --stop                   Stop nftables and Fail2Ban services
  -l, --list                   List current nftables rules
  -c, --check                  Check nftables and Fail2Ban configuration syntax
  -a, --add-ip [IP]            Add the given IP (or your current login IP if omitted) to the allow file
  -i, --info                   Show information about current IP and allow file status
  -tb, --temp-ban [IP] [COMMENT]  Temporarily ban an IP for 1 hour (immediate effect) with optional comment
  -pb, --perm-ban [IP] [COMMENT]  Permanently ban an IP with optional comment (writes to *system* blacklists)
  -rb, --remove-ban [IP]       Remove an IP from temporary ban sets and Fail2Ban (best effort)
  -lt, --list-temp             List temporarily banned IPs (both IPv4 & IPv6 sets)
      --enable-logging         Enable logging to file (default)
      --disable-logging        Disable logging to file
  -h, --help                   Display this help message

NEW MANAGEMENT OPTIONS (v3.3.0)
-------------------------------
  help, --help, -h            Show this help message
  version, --version          Show version information  
  status                      Show nftables and service status
  list                        List current nftables rules
  flush                       Flush all nftables rules (WARNING: Use with caution!)
  init                        Initialize nftables configuration
  reload                      Reload nftables configuration
  config                      Show configuration directory

NEW VALIDATION & SYNC OPTIONS (v3.3.0)
--------------------------------------
  --validate-sync             Check if files are in sync with active nftables sets
  --show-sets                 Show contents of all nftables sets
  --verify-ip [IP]            Comprehensive check: where does this IP exist?
  --sync                      Reload nftables from configuration files (sync files → active sets)

FAIL2BAN OPTIONS
----------------
  -fj, --fail2ban-jails            View available Fail2Ban jails
  -fr, --fail2ban-rules [JAIL]     View Fail2Ban jail rules
  -fb, --fail2ban-banned [JAIL]    View banned IPs in Fail2Ban (all jails if JAIL omitted)
  -fc, --fail2ban-check            Check Fail2Ban configuration only

ADVANCED OPTIONS
----------------
  -vb, --view-banned          View all banned IPs (nftables temp sets + permanent blacklist files + Fail2Ban)
  -ri, --remove-ip [IP]       Remove IP from all lists/sets (temp sets, blacklist files, and Fail2Ban)

PREREQUISITES
-------------
  1) You must run the nftables init script to create the global table/sets first:
       nftban_init_nftables_conf.sh --install-final
     This must create: table `inet nftban_global` with all required sets.
  2) (Optional) Run your Fail2Ban init helper so jails use the `nftban-global` action.

HOW THINGS WORK
----------------
  • Temporary ban  → Added to `inet nftban_global {temp_ban_v4/temp_ban_v6}` with a timeout (default 1h).
                     Takes effect immediately at packet filter level.
  • Permanent ban  → IP is appended to the *system* blacklist files under /etc/nftban/config/:
                       - nftban-configuration-ipv4-blacklist_ips.conf.local
                       - nftban-configuration-ipv6-blacklist_ips.conf.local
                       - nftban-configuration-user-blacklist_ips.conf.local
                     Your nftables init script loads these files into permanent blacklist sets.
  • Allow IP       → Appends to user whitelist file.
                     System whitelist is auto-managed (server IPs, etc.).
                     Whitelist takes priority in your rules.
  • Sync Check     → Validates that file contents match active nftables sets.
                     Alerts you if configuration has changed but not been applied.

COMMON EXAMPLES
----------------
  Add your current login IP to the allowlist
    nftban --add-ip

  Temporarily ban an IPv4 for 1h with a note
    nftban --temp-ban 203.0.113.9 "SSH brute-force"

  Permanently ban an IPv6 (and also seed a 1h temp-ban for immediate effect)
    nftban --perm-ban 2001:db8::dead:beef "Abusive client"

  Remove the IP from everywhere (temp sets, blacklists, Fail2Ban)
    nftban --remove-ip 203.0.113.9

  Check where an IP exists (files + active sets + fail2ban)
    nftban --verify-ip 203.0.113.9

  Validate that files match active nftables rules
    nftban --validate-sync

  Show all nftables set contents
    nftban --show-sets

  Reload nftables from config files (apply any changes)
    nftban --sync

  Show version information
    nftban --version

ENVIRONMENT TOGGLES
-------------------
  REQUIRE_F2B=true    When set, `--check/--start/--enable/--restart` will fail if Fail2Ban
                      is missing or misconfigured. Default: not required.
  ENABLE_LOGGING=false  Disable file logging without changing CLI flags.

FILES USED
----------
  /etc/nftables.conf                                              (main nftables conf)
  /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local    (user whitelist)
  /etc/nftban/config/nftban-configuration-system_whitelist_ips.conf.local  (system whitelist)
  /etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local    (user blacklist)
  /etc/nftban/config/nftban-configuration-ipv4-blacklist_ips.conf.local    (system IPv4 blacklist)
  /etc/nftban/config/nftban-configuration-ipv6-blacklist_ips.conf.local    (system IPv6 blacklist)
  /var/log/nftban/nftban.log                                               (script log)

EXIT CODES
----------
  0  Success
  1  Generic failure (invalid input, failed checks, etc.)
  2  No change (e.g., IP already present in allowlist)

TROUBLESHOOTING
---------------
  • "Global table not found" – run the nftables init script with `--install-final`.
  • Fail2Ban not installed – operations on nftables still work. Set REQUIRE_F2B=true
    if you want the checks to be strict.
  • Sync issues – Use `--validate-sync` to check, then `--sync` to reload from files.
  • Use `--verify-ip <IP>` to see exactly where an IP exists in the system.

EOF
}

# ---------------------------- New Feature Functions ------------------------- #
show_version() {
    echo "nftban version $VERSION"
    echo "Configuration directory: $BASE_DIR"
    if [ -f "$VERSION_FILE" ]; then
        local installed_version
        installed_version=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
        echo "Installed version: $installed_version"
    fi
}

show_status() {
    echo -e "${BLUE}=== nftban Status ===${NC}"
    echo -e "nftban path: $(dirname "$BASE_DIR")"
    
    if command -v nft >/dev/null 2>&1; then
        echo -e "nftables: $(nft --version 2>/dev/null | head -1)"
    else
        echo -e "nft: ${RED}not found${NC}"
    fi
    
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "fail2ban: $(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')"
    else
        echo -e "fail2ban: ${YELLOW}not installed${NC}"
    fi
    
    if [ -f "/etc/systemd/system/nftban.service" ]; then
        echo -e "systemd unit: ${GREEN}present${NC}"
    else
        echo -e "systemd unit: ${YELLOW}not found (optional)${NC}"
    fi
    
    # Show nftables service status
    echo -e "nftables service: $(get_nftables_status)"
    echo -e "Fail2Ban service: $(get_fail2ban_status)"
    
    # Show table existence
    if nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
        echo -e "Global table: ${GREEN}exists${NC}"
        
        # Quick set counts
        local temp_v4_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | wc -l)
        local temp_v6_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | wc -l)
        
        echo -e "  Temp bans: ${temp_v4_count} IPv4, ${temp_v6_count} IPv6"
    else
        echo -e "Global table: ${RED}missing${NC}"
    fi
}

flush_rules() {
    echo -e "${RED}WARNING: This will remove ALL nftables rules!${NC}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if nft flush ruleset; then
            log "nftables rules flushed"
            echo -e "${GREEN}nftables rules flushed${NC}"
        else
            log "Failed to flush nftables rules"
            echo -e "${RED}Failed to flush rules${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}Operation cancelled${NC}"
    fi
}

init_config() {
    echo -e "${BLUE}Initializing nftables configuration...${NC}"
    
    # Check if init script exists
    local init_script
    init_script="$(dirname "$BASE_DIR")/scripts/nftban_init_nftables_conf.sh"
    
    if [ -f "$init_script" ]; then
        echo -e "${GREEN}Found initialization script: $init_script${NC}"
        if [ -x "$init_script" ]; then
            "$init_script"
        else
            echo -e "${YELLOW}Making script executable and running...${NC}"
            chmod +x "$init_script"
            "$init_script"
        fi
    else
        echo -e "${RED}Initialization script not found at: $init_script${NC}"
        echo -e "${YELLOW}Please ensure nftban is properly installed${NC}"
        return 1
    fi
}

reload_config() {
    echo -e "${BLUE}Reloading nftables configuration...${NC}"
    
    if [ -f "$CONF_FILE" ]; then
        if nft -f "$CONF_FILE"; then
            log "nftables configuration reloaded from $CONF_FILE"
            echo -e "${GREEN}nftables configuration reloaded${NC}"
        else
            log "Failed to reload nftables configuration from $CONF_FILE"
            echo -e "${RED}Failed to reload nftables configuration${NC}"
            return 1
        fi
    else
        echo -e "${RED}Configuration file not found: $CONF_FILE${NC}"
        echo -e "${YELLOW}Run 'nftban init' to initialize configuration${NC}"
        return 1
    fi
}

show_config_dir() {
    echo -e "${BLUE}Configuration directory: $BASE_DIR${NC}"
    echo -e "${BLUE}Available configuration files:${NC}"
    
    if [ -d "$BASE_DIR" ]; then
        local count=0
        for file in "$BASE_DIR"/*.conf.local; do
            if [ -f "$file" ]; then
                local filename
                filename=$(basename "$file")
                local size
                size=$(wc -l < "$file" 2>/dev/null)
                echo -e "  - $filename ($size lines)"
                count=$((count + 1))
            fi
        done
        
        if [ $count -eq 0 ]; then
            echo -e "  ${YELLOW}No configuration files found${NC}"
        fi
    else
        echo -e "  ${RED}Configuration directory does not exist${NC}"
        echo -e "  ${YELLOW}Run 'nftban init' to initialize configuration${NC}"
    fi
    
    # Show templates if available
    local templates_dir
    templates_dir="$(dirname "$BASE_DIR")/templates"
    if [ -d "$templates_dir" ]; then
        echo -e "${BLUE}Available templates:${NC}"
        for template in "$templates_dir"/control-panels/*.conf; do
            if [ -f "$template" ]; then
                echo -e "  - $(basename "$template")"
            fi
        done
    fi
}

# ---------------------------- Core Functionality --------------------------- #
get_current_login_ip() {
  local login_ip
  if [ -n "$SSH_CLIENT" ]; then
    login_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    echo "$login_ip"; return
  fi
  login_ip=$(who -u | awk '{print $NF}' | sed 's/[()]//g' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
  if [ -n "$login_ip" ]; then echo "$login_ip"; return; fi
  login_ip=$(last -i | grep "still logged in" | awk '{print $3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
  if [ -n "$login_ip" ]; then echo "$login_ip"; return; fi
  if command -v ss >/dev/null 2>&1; then
    login_ip=$(ss -tpn | grep -E "sshd.*ESTAB" | awk '{print $5}' | cut -d: -f1 | head -n 1)
  elif command -v netstat >/dev/null 2>&1; then
    login_ip=$(netstat -tpn | grep -E "sshd.*ESTABLISHED" | awk '{print $5}' | cut -d: -f1 | head -n 1)
  fi
  [ -n "$login_ip" ] && echo "$login_ip" || echo "unknown"
}

check_ip_in_allow() {
  local ip="$1"
  if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
    return 0
  fi
  # Also check system whitelist
  if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
    return 0
  fi
  return 1
}

add_ip_to_allow() {
    local ip="$1"
    local added=false
    local comment
    comment=" # Added by nftban on $(date '+%Y-%m-%d %H:%M:%S') for user $(whoami)"
    
    # Ensure directory structure exists
    if [ ! -d "$BASE_DIR" ]; then
        if ! mkdir -p "$BASE_DIR"; then
            log "ERROR: Failed to create directory $BASE_DIR"
            echo -e "${RED}Failed to create configuration directory${NC}"
            return 1
        fi
        chmod 755 "$BASE_DIR"
    fi
    
    # Initialize allow file if needed
    if [ ! -f "$USER_WHITELIST_FILE" ]; then
        if ! touch "$USER_WHITELIST_FILE"; then
            log "ERROR: Failed to create $USER_WHITELIST_FILE"
            echo -e "${RED}Failed to create allow file${NC}"
            return 1
        fi
        chmod 644 "$USER_WHITELIST_FILE"
        echo "# User whitelist IPs - managed by nftban" > "$USER_WHITELIST_FILE"
        echo "# Format: IP_ADDRESS [optional comment]" >> "$USER_WHITELIST_FILE"
        echo "" >> "$USER_WHITELIST_FILE"
    fi
    
    # Check if IP already exists (check both files)
    if check_ip_in_allow "$ip"; then
        log "IP $ip already in allow file"
        return 2  # No change needed
    fi
    
    # Add IP
    if echo "$ip$comment" >> "$USER_WHITELIST_FILE"; then
        log "Added IP $ip to user allow file"
        added=true
    else
        log "ERROR: Failed to write to $USER_WHITELIST_FILE"
        echo -e "${RED}Failed to add IP to allow file${NC}"
        return 1
    fi
    
    [ "$added" = true ] && return 0 || return 1

# NEW IN v3.6.0: Add IP to active whitelist set
if [[ "$ip" =~ .*:.* ]]; then
  if ! nft add element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" "{ $ip }" 2>/dev/null; then
    echo -e "${RED}Failed to add IP to active whitelist set (v6)${NC}"
    log "ERROR: Failed to add $ip to whitelist_v6 set"
  else
    log "Added $ip to whitelist_v6 set"
  fi
else
  if ! nft add element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" "{ $ip }" 2>/dev/null; then
    echo -e "${RED}Failed to add IP to active whitelist set (v4)${NC}"
    log "ERROR: Failed to add $ip to whitelist_v4 set"
  else
    log "Added $ip to whitelist_v4 set"
  fi
fi
}

remove_ip_from_whitelist() {
  local ip="$1"
  local removed=false
  
  # Remove from user whitelist
  if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$USER_WHITELIST_FILE"
    log "Removed IP $ip from user whitelist file"
    removed=true
  fi
  
  # Note: Don't remove from system whitelist (it's auto-managed)
  
  [ "$removed" = true ] && return 0 || return 1

# NEW IN v3.6.0: Remove IP from active whitelist set
if [[ "$ip" =~ .*:.* ]]; then
  if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" "{ $ip }" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to remove IP from whitelist_v6 set${NC}"
    log "WARNING: Failed to remove $ip from whitelist_v6 set"
  else
    log "Removed $ip from whitelist_v6 set"
  fi
else
  if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" "{ $ip }" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to remove IP from whitelist_v4 set${NC}"
    log "WARNING: Failed to remove $ip from whitelist_v4 set"
  else
    log "Removed $ip from whitelist_v4 set"
  fi
fi
}

remove_ip_from_blacklist() {
  local ip="$1"
  local removed=false
  local blacklist_file
  if [[ "$ip" =~ .*:.* ]]; then
    blacklist_file="$IPV6_BLACKLIST_FILE"
  else
    blacklist_file="$IPV4_BLACKLIST_FILE"
  fi
  if [ -f "$blacklist_file" ] && grep -Eq "^${ip}([[:space:]]|$)" "$blacklist_file"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$blacklist_file"
    log "Removed IP $ip from blacklist file $blacklist_file"
    removed=true
  fi
  
  # Also check user blacklist
  if [ -f "$USER_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_BLACKLIST_FILE"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$USER_BLACKLIST_FILE"
    log "Removed IP $ip from user blacklist file"
    removed=true
  fi
  
  [ "$removed" = true ] && return 0 || return 1

# NEW IN v3.6.0: Remove IP from active whitelist set
if [[ "$ip" =~ .*:.* ]]; then
  if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" "{ $ip }" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to remove IP from whitelist_v6 set${NC}"
    log "WARNING: Failed to remove $ip from whitelist_v6 set"
  else
    log "Removed $ip from whitelist_v6 set"
  fi
else
  if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" "{ $ip }" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to remove IP from whitelist_v4 set${NC}"
    log "WARNING: Failed to remove $ip from whitelist_v4 set"
  else
    log "Removed $ip from whitelist_v4 set"
  fi
fi
}

add_ip_to_blacklist() {
    local ip="$1"
    local comment="$2"
    local blacklist_file
    local temp_file
    
    # Determine file
    [[ "$ip" =~ .*:.* ]] && blacklist_file="$IPV6_BLACKLIST_FILE" || blacklist_file="$IPV4_BLACKLIST_FILE"
    temp_file="${blacklist_file}.tmp"
    
    # Set default comment
    [ -z "$comment" ] && comment="Banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Sanitize comment
    comment=$(echo "$comment" | tr -d '\n\r' | sed 's/[;&|`$]//g' | cut -c1-200)
    
    # Ensure directory exists
    mkdir -p "$(dirname "$blacklist_file")"
    
    # Initialize if needed
    if [ ! -f "$blacklist_file" ]; then
        local filename
        filename=$(basename "$blacklist_file")
        {
            echo "# $filename - managed by nftban"
            echo "# Format: IP_ADDRESS # comment"
            echo ""
        } > "$blacklist_file"
        chmod 644 "$blacklist_file"
    fi
    
    # Atomic operation: copy to temp, modify, move back
    if ! cp "$blacklist_file" "$temp_file"; then
        log "ERROR: Failed to create temporary file"
        return 1
    fi
    
    # Remove existing entry if present
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$temp_file"
    
    # Add new entry
    echo "$ip # $comment" >> "$temp_file"
    
    # Atomic move
    if mv "$temp_file" "$blacklist_file"; then
        log "Added IP $ip to blacklist with comment: $comment"
        
        # Also remove from whitelist if present
        remove_ip_from_whitelist "$ip" 2>/dev/null
        
        return 0
    else
        log "ERROR: Failed to update blacklist file"
        rm -f "$temp_file"
        return 1
    fi
}

sanitize_comment() {
    local comment="$1"
    # Remove potentially dangerous characters
    echo "$comment" | tr -d '\n\r' | sed 's/[;&|`$]//g' | cut -c1-200
}

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

check_config() {
  local nft_ok=true
  local f2b_ok=true
  local REQUIRE_F2B="${REQUIRE_F2B:-false}"
  echo -e "${BLUE}Checking nftables configuration...${NC}"
  if ! check_nftables_config; then nft_ok=false; fi
  echo -e "${BLUE}Checking Fail2Ban configuration...${NC}"
  if ! check_fail2ban_config; then f2b_ok=false; fi
  if [ "$nft_ok" = true ] && { [ "$f2b_ok" = true ] || [ "$REQUIRE_F2B" = false ]; }; then
    return 0
  else
    return 1
  fi
}

backup_config() {
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  mkdir -p "$BACKUP_DIR"
  if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "$BACKUP_DIR/nftables.conf.$timestamp"
    log "Backed up configuration to $BACKUP_DIR/nftables.conf.$timestamp"
  fi
}

list_rules() {
  echo -e "${BLUE}Current nftables rules:${NC}"
  nft list ruleset
}

enable_nftables_service()  { systemctl enable nftables 2>/dev/null; log "Enabled nftables service"; }
disable_nftables_service() { systemctl disable nftables 2>/dev/null; log "Disabled nftables service"; }
start_nftables_service() {
  if systemctl start nftables 2>/dev/null; then
    log "Started nftables service"; echo -e "${GREEN}nftables service started${NC}"; return 0
  else
    log "Failed to start nftables service"; echo -e "${RED}Failed to start nftables service${NC}"; return 1
  fi
}
stop_nftables_service() {
  if systemctl stop nftables 2>/dev/null; then
    log "Stopped nftables service"; echo -e "${YELLOW}nftables service stopped${NC}"; return 0
  else
    log "Failed to stop nftables service"; echo -e "${RED}Failed to stop nftables service${NC}"; return 1
  fi
}

enable_fail2ban_service()  { systemctl enable fail2ban 2>/dev/null; log "Enabled Fail2Ban service"; }
disable_fail2ban_service() { systemctl disable fail2ban 2>/dev/null; log "Disabled Fail2Ban service"; }
start_fail2ban_service() {
  if systemctl start fail2ban 2>/dev/null; then
    log "Started Fail2Ban service"; echo -e "${GREEN}Fail2Ban service started${NC}"; return 0
  else
    log "Failed to start Fail2Ban service"; echo -e "${RED}Failed to start Fail2Ban service${NC}"; return 1
  fi
}
stop_fail2ban_service() {
  if systemctl stop fail2ban 2>/dev/null; then
    log "Stopped Fail2Ban service"; echo -e "${YELLOW}Fail2Ban service stopped${NC}"; return 0
  else
    log "Failed to stop Fail2Ban service"; echo -e "${RED}Failed to stop Fail2Ban service${NC}"; return 1
  fi
}
restart_fail2ban_service() {
  if systemctl restart fail2ban 2>/dev/null; then
    log "Restarted Fail2Ban service"; echo -e "${GREEN}Fail2Ban service restarted${NC}"; return 0
  else
    log "Failed to restart Fail2Ban service"; echo -e "${RED}Failed to restart Fail2Ban service${NC}"; return 1
  fi
}

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
    add_ip_to_allow "$current_ip"; rc=$?
    case $rc in
      0) echo -e "${GREEN}Added your IP ($current_ip) to the allow file${NC}" ;;
      2) echo -e "${GREEN}Your IP is already in the allow file${NC}" ;;
      *) echo -e "${RED}Failed to add your IP to the allow file${NC}"; return 1 ;;
    esac
    if remove_ip_from_blacklist "$current_ip"; then
      echo -e "${GREEN}Removed your IP from blacklist files${NC}"
    fi
    return 0
  fi
}

ensure_temp_ban_table() {
  if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    log "ERROR: Table inet $TEMP_BAN_TABLE not found!"
    echo -e "${RED}ERROR: Global table 'inet $TEMP_BAN_TABLE' not found.${NC}"
    echo -e "${YELLOW}Run the nftables init script to create the structure.${NC}"
    return 1
  fi
  if ! nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" >/dev/null 2>&1; then
    log "ERROR: Set $TEMP_BAN_SET_V4 not found in table $TEMP_BAN_TABLE"
    echo -e "${RED}ERROR: Set '$TEMP_BAN_SET_V4' not found. Run init script first.${NC}"
    return 1
  fi
  if ! nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" >/dev/null 2>&1; then
    log "ERROR: Set $TEMP_BAN_SET_V6 not found in table $TEMP_BAN_TABLE"
    echo -e "${RED}ERROR: Set '$TEMP_BAN_SET_V6' not found. Run init script first.${NC}"
    return 1
  fi
  log "Verified: Global table structure exists (inet $TEMP_BAN_TABLE)"
  return 0
}

is_current_login_ip() {
  local ip="$1"
  local current_ip
  current_ip=$(get_current_login_ip)
  [ "$ip" = "$current_ip" ]
}

temp_ban_ip() {
    local ip="$1"
    local comment="$2"
    
    # Sanitize comment input
    comment=$(sanitize_comment "$comment")
	
    # Safety check - use improved whitelisting check
    if is_current_login_ip "$ip"; then
        echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
        log "Attempted to ban own login IP: $ip"
        return 1
    fi
    
    # Also check if IP is whitelisted (both files and active sets)
    if is_ip_whitelisted "$ip"; then
        echo -e "${RED}ERROR: Cannot ban whitelisted IP ($ip)${NC}"
        log "Attempted to ban whitelisted IP: $ip"
        return 1
    fi
    
    # Ensure infrastructure exists
    if ! ensure_temp_ban_table; then 
        echo -e "${YELLOW}Hint: Run 'nftban init' to set up the required tables${NC}"
        return 1
    fi
    
    # Set default comment
    [ -z "$comment" ] && comment="Temporarily banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Determine set and ban
    local set_name
    local ip_version
    if [[ "$ip" =~ .*:.* ]]; then
        set_name="$TEMP_BAN_SET_V6"
        ip_version="IPv6"
    else
        set_name="$TEMP_BAN_SET_V4"
        ip_version="IPv4"
    fi
    
    # Attempt to add
    local nft_output
    nft_output=$(nft add element inet "$TEMP_BAN_TABLE" "$set_name" "{ $ip timeout 1h }" 2>&1)
    local nft_rc=$?
    
    if [ $nft_rc -eq 0 ]; then
        log "Temporarily banned $ip_version address: $ip with comment: $comment"
        echo -e "${RED}[OK] Temporarily banned $ip_version address: $ip (1 hour)${NC}"
        echo -e "${YELLOW}Comment: $comment${NC}"
        return 0
    else
        # Check if already exists
        if nft list set inet "$TEMP_BAN_TABLE" "$set_name" 2>/dev/null | grep -q "$ip"; then
            echo -e "${YELLOW}[WARNING] IP $ip is already temporarily banned${NC}"
            log "IP $ip already in temporary ban set"
            return 2
        else
            echo -e "${RED}[ERROR] Failed to add $ip_version $ip to temporary ban set${NC}"
            echo -e "${YELLOW}Error: $nft_output${NC}"
            log "ERROR: Failed to ban $ip: $nft_output"
            return 1
        fi
    fi
}

perm_ban_ip() {
  local ip="$1"
  local comment="$2"
  
  # Sanitize comment input
  comment=$(sanitize_comment "$comment")
  
  if is_current_login_ip "$ip"; then
    echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
    log "Attempted to ban own login IP: $ip"
    return 1
  fi
  
  if is_ip_whitelisted "$ip"; then
    echo -e "${RED}ERROR: Cannot ban whitelisted IP ($ip)${NC}"
    log "Attempted to ban whitelisted IP: $ip"
    return 1
  fi
  
  if [ -z "$comment" ]; then
    comment="Permanently banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  if add_ip_to_blacklist "$ip" "$comment"; then
    log "Permanently banned IP: $ip with comment: $comment"
    echo -e "${RED}Permanently banned IP: $ip${NC}"
    echo -e "${YELLOW}Comment: $comment${NC}"
    temp_ban_ip "$ip" "$comment (also permanently banned)" >/dev/null 2>&1 || true
    return 0
  else
    echo -e "${YELLOW}IP $ip is already banned${NC}"
    return 1
  fi
}

remove_temp_ban() {
  local ip="$1"
  local removed=false
  if [[ "$ip" =~ .*:.* ]]; then
    if nft delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" "{ $ip }" 2>/dev/null; then
      log "Removed temporary ban for IPv6 address: $ip"
      echo -e "${GREEN}Removed temporary ban for IPv6 address: $ip${NC}"
      removed=true
    fi
  else
    if nft delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" "{ $ip }" 2>/dev/null; then
      log "Removed temporary ban for IPv4 address: $ip"
      echo -e "${GREEN}Removed temporary ban for IPv4 address: $ip${NC}"
      removed=true
    fi
  fi
  if [ "$removed" = true ]; then return 0; fi
  log "IP $ip was not found in temporary ban sets"
  echo -e "${YELLOW}IP $ip was not found in temporary ban sets${NC}"
  return 1
}

list_temp_bans() {
  echo -e "${BLUE}Temporarily banned IPv4 addresses (set: ${TEMP_BAN_SET_V4} in table ${TEMP_BAN_TABLE}):${NC}"
  local v4
  v4=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null)
  if [ -n "$v4" ]; then
    echo "$v4"
  else
    echo "None"
  fi
  
  echo -e "${BLUE}Temporarily banned IPv6 addresses (set: ${TEMP_BAN_SET_V6} in table ${TEMP_BAN_TABLE}):${NC}"
  local v6
  v6=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null)
  if [ -n "$v6" ]; then
    echo "$v6"
  else
    echo "None"
  fi
}

view_fail2ban_jails() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${BLUE}Available Fail2Ban jails:${NC}"
    fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'
    if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
      echo -e "${BLUE}NFTables-specific jails:${NC}"
      find "$FAIL2BAN_JAIL_DIR" -name "nftables-*.conf" -exec basename {} .conf \; | sed 's/^/  /'
    fi
  else
    echo -e "${RED}Fail2Ban is not installed${NC}"
    return 1
  fi
}

view_fail2ban_rules() {
  local jail="$1"
  if [ -z "$jail" ]; then
    echo -e "${YELLOW}Usage: nftban --fail2ban-rules <jail>${NC}"
    echo -e "${YELLOW}Available jails:${NC}"
    view_fail2ban_jails
    return 1
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${BLUE}Fail2Ban rules for jail '$jail':${NC}"
    fail2ban-client get "$jail" banip
  else
    echo -e "${RED}Fail2Ban is not installed${NC}"
    return 1
  fi
}

view_fail2ban_banned() {
  local jail="$1"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -n "$jail" ]; then
      echo -e "${BLUE}Banned IPs in Fail2Ban jail '$jail':${NC}"
      fail2ban-client status "$jail" | grep "Banned IP list:" | sed 's/^.*Banned IP list://'
    else
      echo -e "${BLUE}Banned IPs in all Fail2Ban jails:${NC}"
      for j in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
        echo -e "${YELLOW}Jail: $j${NC}"
        fail2ban-client status "$j" | grep "Banned IP list:" | sed 's/^.*Banned IP list://'
        echo
      done
    fi
  else
    echo -e "${RED}Fail2Ban is not installed${NC}"
    return 1
  fi
}

view_all_banned() {
  echo -e "${BLUE}=== All Banned IPs (Combined View) ===${NC}"
  echo -e "${YELLOW}1. nftables temporary bans (IPv4):${NC}"
  local v4
  v4=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null)
  if [ -n "$v4" ]; then
    echo "$v4" | sed 's/^/  /'
  else
    echo "  None"
  fi
  
  echo -e "${YELLOW}2. nftables temporary bans (IPv6):${NC}"
  local v6
  v6=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null)
  if [ -n "$v6" ]; then
    echo "$v6" | sed 's/^/  /'
  else
    echo "  None"
  fi
  
  echo -e "${YELLOW}3. Permanent blacklist (IPv4):${NC}"
  if [ -f "$IPV4_BLACKLIST_FILE" ]; then
    grep -v '^#' "$IPV4_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $IPV4_BLACKLIST_FILE"
  fi
  
  echo -e "${YELLOW}4. Permanent blacklist (IPv6):${NC}"
  if [ -f "$IPV6_BLACKLIST_FILE" ]; then
    grep -v '^#' "$IPV6_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $IPV6_BLACKLIST_FILE"
  fi
  
  echo -e "${YELLOW}5. User blacklist:${NC}"
  if [ -f "$USER_BLACKLIST_FILE" ]; then
    grep -v '^#' "$USER_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $USER_BLACKLIST_FILE"
  fi
  
  echo -e "${YELLOW}6. Fail2Ban bans:${NC}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    for jail in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
      banned_ips=$(fail2ban-client status "$jail" | grep "Banned IP list:" | sed 's/^.*Banned IP list://')
      if [ -n "$banned_ips" ] && [ "$banned_ips" != " " ]; then
        echo -e "  Jail: $jail"
        echo "$banned_ips" | tr ' ' '\n' | sed 's/^/    /'
      fi
    done
  else
    echo "  Fail2Ban not installed"
  fi
}

remove_ip_from_fail2ban() {
  local ip="$1"
  local unjailed=false
  if command -v fail2ban-client >/dev/null 2>&1; then
    for jail in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
      if fail2ban-client status "$jail" | grep -q "$ip"; then
        if fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1; then
          log "Unbanned IP $ip from Fail2Ban jail: $jail"
          echo -e "${GREEN}Unbanned IP $ip from Fail2Ban jail: $jail${NC}"
          unjailed=true
        fi
      fi
    done
  fi
  [ "$unjailed" = true ] && return 0 || return 1
}

remove_ip_from_all() {
  local ip="$1"
  local removed_any=false
  echo -e "${BLUE}Removing IP $ip from all ban lists...${NC}"
  if remove_temp_ban "$ip"; then removed_any=true; fi
  if remove_ip_from_blacklist "$ip"; then removed_any=true; fi
  if remove_ip_from_whitelist "$ip"; then removed_any=true; fi
  if remove_ip_from_fail2ban "$ip"; then removed_any=true; fi
  if [ "$removed_any" = true ]; then
    log "Removed IP $ip from all ban lists and whitelist"
    echo -e "${GREEN}Removed IP $ip from all ban lists and whitelist${NC}"
    echo -e "${CYAN}Note: Permanent sets in nftables need reload. Run: nftban --sync${NC}"
    return 0
  else
    log "IP $ip was not found in any ban lists or whitelist"
    echo -e "${YELLOW}IP $ip was not found in any ban lists or whitelist${NC}"
    return 1
  fi
}

show_info() {
  local current_ip
  current_ip=$(get_current_login_ip)
  echo -e "${BLUE}=== nftban Information ===${NC}"
  echo -e "Current login IP: $current_ip"
  
  if is_ip_whitelisted "$current_ip"; then
    echo -e "Allow status: ${GREEN}WHITELISTED${NC}"
  else
    echo -e "Allow status: ${RED}NOT WHITELISTED${NC}"
  fi
  
  echo -e "nftables service: $(get_nftables_status)"
  echo -e "Fail2Ban service: $(get_fail2ban_status)"
  if nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    echo -e "Global table: ${GREEN}exists${NC}"
  else
    echo -e "Global table: ${RED}missing${NC}"
  fi
  
  echo -e ""
  echo -e "${BLUE}Configuration Files:${NC}"
  echo -e "User whitelist: $USER_WHITELIST_FILE"
  if [ -f "$USER_WHITELIST_FILE" ]; then
    echo -e "  Lines: $(grep -v '^#' "$USER_WHITELIST_FILE" | grep -c .) (excluding comments)"
  else
    echo -e "  ${YELLOW}File not found${NC}"
  fi
  
  echo -e "System whitelist: $SYSTEM_WHITELIST_FILE"
  if [ -f "$SYSTEM_WHITELIST_FILE" ]; then
    echo -e "  Lines: $(grep -v '^#' "$SYSTEM_WHITELIST_FILE" | grep -c .) (excluding comments)"
  else
    echo -e "  ${YELLOW}File not found${NC}"
  fi
  
  echo -e ""
  echo -e "Blacklist files:"
  for file in "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "$USER_BLACKLIST_FILE"; do
    if [ -f "$file" ]; then
      echo -e "  $(basename "$file"): $(grep -v '^#' "$file" | grep -c .) IPs"
    else
      echo -e "  $(basename "$file"): ${YELLOW}not found${NC}"
    fi
  done
  
  echo -e ""
  echo -e "${CYAN}Run 'nftban --validate-sync' to check if files match active sets${NC}"
}

# ------------------------------ Main Logic -------------------------------- #
main() {
  local arg1="$1"
  local arg2="$2"
  local arg3="$3"

  case "$arg1" in
    -e|--enable)
      backup_config
      if check_config; then
        enable_nftables_service
        enable_fail2ban_service
        start_nftables_service
        start_fail2ban_service
      else
        echo -e "${RED}Configuration check failed, not enabling services${NC}"
        return 1
      fi
      ;;
    -d|--disable)
      disable_nftables_service
      disable_fail2ban_service
      stop_nftables_service
      stop_fail2ban_service
      ;;
    -s|--start)
      backup_config
      if check_config; then
        start_nftables_service
        start_fail2ban_service
      else
        echo -e "${RED}Configuration check failed, not starting services${NC}"
        return 1
      fi
      ;;
    -r|--restart)
      backup_config
      if check_config; then
        stop_nftables_service
        start_nftables_service
        restart_fail2ban_service
      else
        echo -e "${RED}Configuration check failed, not restarting services${NC}"
        return 1
      fi
      ;;
    -x|--stop)
      stop_nftables_service
      stop_fail2ban_service
      ;;
    -l|--list)
      list_rules
      ;;
    -c|--check)
      check_config
      ;;
    -a|--add-ip)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        add_ip_to_allow "$arg2"
      else
        manage_ip
      fi
      ;;
    -i|--info)
      show_info
      ;;
    -tb|--temp-ban)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        temp_ban_ip "$arg2" "$arg3"
      else
        echo -e "${RED}Usage: nftban --temp-ban <IP> [COMMENT]${NC}"
        return 1
      fi
      ;;
    -pb|--perm-ban)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        perm_ban_ip "$arg2" "$arg3"
      else
        echo -e "${RED}Usage: nftban --perm-ban <IP> [COMMENT]${NC}"
        return 1
      fi
      ;;
    -rb|--remove-ban)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        remove_ip_from_all "$arg2"
      else
        echo -e "${RED}Usage: nftban --remove-ban <IP>${NC}"
        return 1
      fi
      ;;
    -lt|--list-temp)
      list_temp_bans
      ;;
    --enable-logging)
      ENABLE_LOGGING=true
      echo -e "${GREEN}Logging enabled${NC}"
      ;;
    --disable-logging)
      ENABLE_LOGGING=false
      echo -e "${YELLOW}Logging disabled${NC}"
      ;;
    -h|--help|help)
      show_help
      ;;
    version|--version)
      show_version
      ;;
    status)
      show_status
      ;;
    list)
      list_rules
      ;;
    flush)
      flush_rules
      ;;
    init)
      init_config
      ;;
    reload)
      reload_config
      ;;
    config)
      show_config_dir
      ;;
    --validate-sync)
      validate_sync_status
      ;;
    --show-sets)
      show_all_sets
      ;;
    --verify-ip)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        verify_ip_location "$arg2"
      else
        echo -e "${RED}Usage: nftban --verify-ip <IP>${NC}"
        return 1
      fi
      ;;
    --sync)
      sync_nftables
      ;;
    -fj|--fail2ban-jails)
      view_fail2ban_jails
      ;;
    -fr|--fail2ban-rules)
      view_fail2ban_rules "$arg2"
      ;;
    -fb|--fail2ban-banned)
      view_fail2ban_banned "$arg2"
      ;;
    -fc|--fail2ban-check)
      check_fail2ban_config
      ;;
    -vb|--view-banned)
      view_all_banned
      ;;
    -ri|--remove-ip)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        remove_ip_from_all "$arg2"
      else
        echo -e "${RED}Usage: nftban --remove-ip <IP>${NC}"
        return 1
      fi
      ;;
    *)
      echo -e "${RED}Unknown option: $arg1${NC}"
      echo -e "${YELLOW}Use 'nftban --help' for usage information${NC}"
      return 1
      ;;
  esac
}

# ------------------------------ Script Start ------------------------------- #
if [ $# -eq 0 ]; then
  show_help
  exit 0
fi

main "$@"
exit $?
