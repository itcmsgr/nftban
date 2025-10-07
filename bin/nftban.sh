#!/bin/bash
###############################################################################
# Script: nftban.sh
# A comprehensive nftables and fail2ban management tool with IP allowlist
# Version: 3.1.1
# Author: ITCMS Team (Antonios Voulvoulis) — consolidated fixes & enhanced help
#
# Description:
#   One-stop helper to manage nftables & Fail2Ban and to handle allow/deny IPs.
#   Compatible with the single-table layout created by your init script:
#       table inet nftban_global
#       sets  temp_ban_v4 (ipv4_addr, timeout) / temp_ban_v6 (ipv6_addr, timeout)
#
# Notes:
#   • Temporary bans are applied via those timeout sets (immediate effect).
#   • Permanent bans are written to system blacklist files consumed by your
#     nftables init rules the next time rules are (re)applied.
###############################################################################

# ------------------------------ Configuration ------------------------------ #
BASE_DIR="/etc/nftban/config"
CONF_FILE="/etc/nftables.conf"
ALLOW_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_FILE="/var/log/nftban.log"

TEMP_BAN_TABLE="nftban_global"
# Names of the sets used for temporary bans (IPv4 & IPv6)
TEMP_BAN_SET_V4="temp_ban_v4"
TEMP_BAN_SET_V6="temp_ban_v6"

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

# Minimal IP sanity checks (accepts raw IP or CIDR)
is_ipv4_or_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; }
is_ipv6_or_cidr() { [[ "$1" == *:* ]] && [[ "$1" =~ ^[0-9A-Fa-f:./]+$ ]]; }
is_ip_like()      { is_ipv4_or_cidr "$1" || is_ipv6_or_cidr "$1"; }

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

# ------------------------------ User Help --------------------------------- #
show_help() {
  cat << 'EOF'
NFTBan — nftables & Fail2Ban helper
===================================

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
     This must create: table `inet nftban_global` and sets `temp_ban_v4` / `temp_ban_v6`.
  2) (Optional) Run your Fail2Ban init helper so jails use the `nftban-global` action.

HOW THINGS WORK
----------------
  • Temporary ban  → Added to `inet nftban_global {temp_ban_v4/temp_ban_v6}` with a timeout (default 1h).
                     Takes effect immediately at packet filter level.
  • Permanent ban  → IP is appended to the *system* blacklist files under /etc/nftban/config/:
                       - nftban-configuration-ipv4-blacklist_ips.conf.local
                       - nftban-configuration-ipv6-blacklist_ips.conf.local
                     Your nftables init script loads these files into blacklist sets.
  • Allow IP       → Appends to `/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local`.
                     Whitelist takes priority in your rules.

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

  Show currently temp-banned IPs
    nftban --list-temp

ENVIRONMENT TOGGLES
-------------------
  REQUIRE_F2B=true    When set, `--check/--start/--enable/--restart` will fail if Fail2Ban
                      is missing or misconfigured. Default: not required.
  ENABLE_LOGGING=false  Disable file logging without changing CLI flags.

FILES USED
----------
  /etc/nftables.conf                                  (main nftables conf this script validates)
  /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
  /etc/nftban/config/nftban-configuration-ipv4-blacklist_ips.conf.local
  /etc/nftban/config/nftban-configuration-ipv6-blacklist_ips.conf.local
  /var/log/nftban.log                                  (script log)

EXIT CODES (high-level)
-----------------------
  0  Success
  1  Generic failure (invalid input, failed checks, etc.)
  2  No change (e.g., IP already present in allowlist)

TROUBLESHOOTING
---------------
  • "Global table not found" — run the nftables init script with `--install-final`.
  • Fail2Ban not installed — operations on nftables still work. Set REQUIRE_F2B=true
    if you want the checks to be strict.
  • Use `-l/--list` and `-lt/--list-temp` to inspect current state quickly.

EOF
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
  if [ -f "$ALLOW_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$ALLOW_FILE"; then
    return 0
  else
    return 1
  fi
}

add_ip_to_allow() {
  local ip="$1"
  local added=false
  local comment
  comment=" # Added by nftban on $(date '+%Y-%m-%d %H:%M:%S') for user $(whoami)"
  mkdir -p "$(dirname "$ALLOW_FILE")"
  if [ ! -f "$ALLOW_FILE" ]; then
    touch "$ALLOW_FILE" && chmod 644 "$ALLOW_FILE"
    echo "# User whitelist IPs - managed by nftban" > "$ALLOW_FILE"
  fi
  if ! check_ip_in_allow "$ip"; then
    echo "$ip$comment" >> "$ALLOW_FILE"
    log "Added IP $ip to allow file"
    added=true
  fi
  if [ "$added" = true ]; then return 0; else return 2; fi
}

remove_ip_from_whitelist() {
  local ip="$1"
  local removed=false
  if [ -f "$ALLOW_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$ALLOW_FILE"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$ALLOW_FILE"
    log "Removed IP $ip from whitelist file $ALLOW_FILE"
    removed=true
  fi
  [ "$removed" = true ] && return 0 || return 1
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
  [ "$removed" = true ] && return 0 || return 1
}

add_ip_to_blacklist() {
  local ip="$1"
  local comment="$2"
  local added=false
  local blacklist_file
  if [ -z "$comment" ]; then
    comment="Banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  if [[ "$ip" =~ .*:.* ]]; then
    blacklist_file="$IPV6_BLACKLIST_FILE"
  else
    blacklist_file="$IPV4_BLACKLIST_FILE"
  fi
  mkdir -p "$(dirname "$blacklist_file")"
  if [ ! -f "$blacklist_file" ]; then
    touch "$blacklist_file" && chmod 644 "$blacklist_file"
    if [[ "$ip" =~ .*:.* ]]; then
      echo "# IPv6 blacklist IPs - managed by nftban" > "$blacklist_file"
    else
      echo "# IPv4 blacklist IPs - managed by nftban" > "$blacklist_file"
    fi
  fi
  if grep -Eq "^${ip}([[:space:]]|$)" "$blacklist_file"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$blacklist_file"
  fi
  echo "$ip # $comment" >> "$blacklist_file"
  log "Ensured IP $ip present in blacklist with comment: $comment"
  added=true
  if remove_ip_from_whitelist "$ip"; then
    log "Removed IP $ip from whitelist as it's now blacklisted"
  fi
  [ "$added" = true ] && return 0 || return 1
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
  fi
  return 1
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
  if is_current_login_ip "$ip"; then
    echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
    log "Attempted to ban own login IP: $ip"
    return 1
  fi
  if ! ensure_temp_ban_table; then return 1; fi
  if [ -z "$comment" ]; then
    comment="Temporarily banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  if [[ "$ip" =~ .*:.* ]]; then
    if nft add element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" "{ $ip timeout 1h }" 2>/dev/null; then
      log "Temporarily banned IPv6 address: $ip with comment: $comment"
      echo -e "${RED}Temporarily banned IPv6 address: $ip (1 hour)${NC}"
      echo -e "${YELLOW}Comment: $comment${NC}"
      return 0
    else
      echo -e "${YELLOW}Failed to add IPv6 $ip to temporary ban set (may already exist).${NC}"
      return 1
    fi
  else
    if nft add element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" "{ $ip timeout 1h }" 2>/dev/null; then
      log "Temporarily banned IPv4 address: $ip with comment: $comment"
      echo -e "${RED}Temporarily banned IPv4 address: $ip (1 hour)${NC}"
      echo -e "${YELLOW}Comment: $comment${NC}"
      return 0
    else
      echo -e "${YELLOW}Failed to add IPv4 $ip to temporary ban set (may already exist).${NC}"
      return 1
    fi
  fi
}

perm_ban_ip() {
  local ip="$1"
  local comment="$2"
  if is_current_login_ip "$ip"; then
    echo -e "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"
    log "Attempted to ban own login IP: $ip"
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
  if nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | grep -q "elements"; then
    local v4
    v4=$(nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')
    [ -n "$v4" ] && echo "$v4" || echo "None"
  else
    echo "None"
  fi
  echo -e "${BLUE}Temporarily banned IPv6 addresses (set: ${TEMP_BAN_SET_V6} in table ${TEMP_BAN_TABLE}):${NC}"
  if nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | grep -q "elements"; then
    local v6
    v6=$(nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?')
    [ -n "$v6" ] && echo "$v6" || echo "None"
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
      find "$FAIL2BAN_JAIL_DIR" -name "nftables-*.conf" -exec basename {} .conf \; | sed 's/^nftables-//'
    fi
  else
    echo -e "${RED}Fail2Ban is not installed${NC}"
  fi
}

view_fail2ban_rules() {
  local jail="$1"
  if [ -z "$jail" ]; then
    echo -e "${RED}Please specify a jail name${NC}"
    return 1
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
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

view_fail2ban_banned() {
  local jail="$1"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -z "$jail" ]; then
      echo -e "${BLUE}Banned IPs in all Fail2Ban jails:${NC}"
      local j banned_ips
      for j in $(fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' ' '); do
        banned_ips=$(fail2ban-client status "$j" | grep "Banned IP list" | sed 's/^.*Banned IP list://')
        if [ -n "$banned_ips" ]; then
          echo -e "${YELLOW}$j:${NC} $banned_ips"
        fi
      done
    else
      echo -e "${BLUE}Banned IPs in jail '$jail':${NC}"
      fail2ban-client status "$jail" | grep "Banned IP list" | sed 's/^.*Banned IP list://'
    fi
  else
    echo -e "${RED}Fail2Ban is not installed${NC}"
  fi
}

view_all_banned() {
  echo -e "${BLUE}=== NFTables: Temporary bans (from sets) ===${NC}"
  echo -e "${BLUE}Temporary IPv4 bans (${TEMP_BAN_SET_V4}):${NC}"
  if nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | grep -q "elements"; then
    local v4
    v4=$(nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')
    [ -n "$v4" ] && echo "$v4" || echo "None"
  else
    echo "None"
  fi
  echo -e "${BLUE}Temporary IPv6 bans (${TEMP_BAN_SET_V6}):${NC}"
  if nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | grep -q "elements"; then
    local v6
    v6=$(nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?')
    [ -n "$v6" ] && echo "$v6" || echo "None"
  else
    echo "None"
  fi
  echo -e "${BLUE}=== NFTables: Permanent blacklists (from files) ===${NC}"
  if [ -f "$IPV4_BLACKLIST_FILE" ]; then
    echo -e "${YELLOW}IPv4 blacklist file ($IPV4_BLACKLIST_FILE):${NC}"
    local v4f
    v4f=$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$IPV4_BLACKLIST_FILE")
    [ -n "$v4f" ] && echo "$v4f" || echo "None"
  else
    echo "No IPv4 blacklist file"
  fi
  if [ -f "$IPV6_BLACKLIST_FILE" ]; then
    echo -e "${YELLOW}IPv6 blacklist file ($IPV6_BLACKLIST_FILE):${NC}"
    local v6f
    v6f=$(grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?' "$IPV6_BLACKLIST_FILE")
    [ -n "$v6f" ] && echo "$v6f" || echo "None"
  else
    echo "No IPv6 blacklist file"
  fi
  echo -e "${BLUE}=== Fail2Ban Banned IPs ===${NC}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    local j banned_ips
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

remove_ip_from_all() {
  local ip="$1"
  local removed=false
  if [ -z "$ip" ]; then
    echo -e "${RED}Please specify an IP address to remove${NC}"
    return 1
  fi
  echo -e "${BLUE}Removing IP $ip from all ban lists...${NC}"
  if remove_temp_ban "$ip"; then removed=true; fi
  if remove_ip_from_blacklist "$ip"; then removed=true; fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    local j
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

update_nftables_config() {
  log "Updating nftables configuration based on current settings"
  manage_ip || true
  if check_config; then
    systemctl restart nftables || true
    systemctl restart fail2ban 2>/dev/null || true
  else
    echo -e "${RED}Configuration check failed, not applying changes${NC}"
    return 1
  fi
}

check_fail2ban_jails() {
  local all_ok=true
  if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
    local jail_file jail_name
    for jail_file in "$FAIL2BAN_JAIL_DIR"/nftables-*.conf; do
      [ -f "$jail_file" ] || continue
      jail_name=$(basename "$jail_file" .conf | sed 's/^nftables-//')
      if grep -q "enabled.*=.*true" "$jail_file"; then
        echo -e "${GREEN}Jail $jail_name is enabled${NC}"
      else
        echo -e "${YELLOW}Jail $jail_name is disabled${NC}"
        all_ok=false
      fi
    done
  else
    echo -e "${YELLOW}No Fail2Ban jail directory found at $FAIL2BAN_JAIL_DIR${NC}"
    all_ok=false
  fi
  [ "$all_ok" = true ]
}

main() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
  fi
  if ! command -v nft >/dev/null 2>&1; then
    echo -e "${RED}nftables is not installed. Please install it first.${NC}"
    exit 1
  fi
  ENABLE_LOGGING=true

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -e|--enable)
        echo -e "${BLUE}Enabling nftables and Fail2Ban services...${NC}"
        if check_config; then
          backup_config
          if manage_ip; then
            enable_nftables_service; enable_fail2ban_service
            start_nftables_service;  start_fail2ban_service
          else
            echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
            enable_nftables_service; enable_fail2ban_service
            start_nftables_service;  start_fail2ban_service
          fi
        else
          echo -e "${RED}Aborting enable operation due to configuration errors${NC}"; exit 1
        fi
        shift ;;

      -d|--disable)
        echo -e "${BLUE}Disabling nftables and Fail2Ban services...${NC}"
        stop_nftables_service; stop_fail2ban_service
        disable_nftables_service; disable_fail2ban_service
        shift ;;

      -s|--start)
        echo -e "${BLUE}Starting nftables and Fail2Ban services...${NC}"
        if check_config; then
          if manage_ip; then
            start_nftables_service; start_fail2ban_service
          else
            echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
            start_nftables_service; start_fail2ban_service
          fi
        else
          echo -e "${RED}Aborting start operation due to configuration errors${NC}"; exit 1
        fi
        shift ;;

      -r|--restart)
        echo -e "${BLUE}Restarting nftables and Fail2Ban services...${NC}"
        if check_config; then
          if manage_ip; then
            systemctl restart nftables; systemctl restart fail2ban 2>/dev/null || true
          else
            echo -e "${YELLOW}Proceeding without IP added to allow file${NC}"
            systemctl restart nftables; systemctl restart fail2ban 2>/dev/null || true
          fi
        else
          echo -e "${RED}Aborting restart operation due to configuration errors${NC}"; exit 1
        fi
        shift ;;

      -x|--stop)
        echo -e "${BLUE}Stopping nftables and Fail2Ban services...${NC}"
        stop_nftables_service; stop_fail2ban_service
        shift ;;

      -l|--list)
        list_rules; shift ;;

      -c|--check)
        check_config; shift ;;

      -a|--add-ip)
        if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
          ip="$2"; shift
        else
          ip=$(get_current_login_ip)
        fi
        if [ "$ip" = "unknown" ]; then
          echo -e "${RED}Could not determine IP address${NC}"; exit 1
        fi
        if ! is_ip_like "$ip"; then
          echo -e "${RED}Invalid IP or CIDR: $ip${NC}"; exit 1
        fi
        echo -e "${BLUE}Adding IP to allow file...${NC}"
        add_ip_to_allow "$ip"; rc=$?
        if [ $rc -eq 0 ]; then
          echo -e "${GREEN}IP $ip added to allow file${NC}"
          remove_ip_from_blacklist "$ip"
          update_nftables_config
        elif [ $rc -eq 2 ]; then
          echo -e "${YELLOW}IP $ip already exists in allow file${NC}"
        else
          echo -e "${RED}Failed to update the allow file${NC}"; exit 1
        fi ;;

      -i|--info)
        echo -e "${BLUE}IP Information:${NC}"
        ip=$(get_current_login_ip)
        echo -e "Your current login IP: $ip"
        if check_ip_in_allow "$ip"; then
          echo -e "Allow file status: ${GREEN}IP is in allow file${NC}"
        else
          echo -e "Allow file status: ${YELLOW}IP is not in allow file${NC}"
        fi
        # Enhanced with service status
        echo -e "nftables service: $(get_nftables_status)"
        echo -e "Fail2Ban service: $(get_fail2ban_status)"
        shift ;;

      -tb|--temp-ban)
        if [ -z "$2" ] || [ "${2:0:1}" = "-" ] || ! is_ip_like "$2"; then
          echo -e "${RED}Please specify a valid IP address to temporarily ban${NC}"; exit 1
        fi
        ip="$2"; shift
        if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then comment="$2"; shift; else comment=""; fi
        temp_ban_ip "$ip" "$comment"; shift ;;

      -pb|--perm-ban)
        if [ -z "$2" ] || [ "${2:0:1}" = "-" ] || ! is_ip_like "$2"; then
          echo -e "${RED}Please specify a valid IP address to permanently ban${NC}"; exit 1
        fi
        ip="$2"; shift
        if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then comment="$2"; shift; else comment=""; fi
        perm_ban_ip "$ip" "$comment"; shift ;;

      -rb|--remove-ban)
        if [ -z "$2" ] || [ "${2:0:1}" = "-" ] || ! is_ip_like "$2"; then
          echo -e "${RED}Please specify a valid IP address to remove from ban${NC}"; exit 1
        fi
        ip="$2"; shift
        remove_ip_from_all "$ip"; shift ;;

      -lt|--list-temp)
        list_temp_bans; shift ;;

      -fj|--fail2ban-jails)
        view_fail2ban_jails; shift ;;

      -fr|--fail2ban-rules)
        view_fail2ban_rules "$2"; shift; shift ;;

      -fb|--fail2ban-banned)
        view_fail2ban_banned "$2"; shift; shift ;;

      -fc|--fail2ban-check)
        check_fail2ban_config; shift ;;

      -vb|--view-banned)
        view_all_banned; shift ;;

      -ri|--remove-ip)
        if [ -z "$2" ] || [ "${2:0:1}" = "-" ] || ! is_ip_like "$2"; then
          echo -e "${RED}Please specify a valid IP address to remove${NC}"; exit 1
        fi
        ip="$2"; shift
        remove_ip_from_all "$ip"; shift ;;

      --enable-logging)
        ENABLE_LOGGING=true; echo -e "${GREEN}Logging enabled${NC}"; shift ;;

      --disable-logging)
        ENABLE_LOGGING=false; echo -e "${YELLOW}Logging disabled${NC}"; shift ;;

      -h|--help)
        show_help; exit 0 ;;

      *)
        echo -e "${RED}Invalid option: $1${NC}"; show_help; exit 1 ;;
    esac
  done
}

if [ $# -eq 0 ]; then
  show_help
  exit 0
fi

main "$@"
