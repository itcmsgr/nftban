#!/usr/bin/env bash
#
# Script: nftban.sh
# A comprehensive nftables + Fail2Ban helper with allow/deny management
# Version: 3.3.1 (hardened + systemd-ready)
# Author: ITCMS Team (Antonios Voulvoulis) + M365 Copilot refinements
#
# Key features
# - Absolute PATH hardening and safe command resolution
# - Atomic writes for ALL list files (allow + blacklists)
# - Optional file locking via flock (prevents concurrent edits)
# - Permanent ban: writes to blacklist files (persist) + immediate runtime temp-ban
# - Remove: cleans from nft temp sets, Fail2Ban jails, and list files
# - Optional auto-apply of nftables.conf after file changes (APPLY_ON_CHANGE)
# - Optional Fail2Ban mass-ban on perm-ban (F2B_FORCE_BAN)
# - 'reconcile' subcommand for systemd timers: safe reload of nftables.conf

set -Eeuo pipefail

# ---- PATH hardening ---------------------------------------------------------
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
resolve_cmd() { command -v "$1" 2>/dev/null || echo "$2"; }
NFT=$(resolve_cmd nft /usr/sbin/nft)
SYSTEMCTL=$(resolve_cmd systemctl /bin/systemctl)
F2B=$(resolve_cmd fail2ban-client /usr/bin/fail2ban-client)
SS=$(resolve_cmd ss /usr/sbin/ss)
NETSTAT=$(resolve_cmd netstat /bin/netstat)
WHO=$(resolve_cmd who /usr/bin/who)
LAST=$(resolve_cmd last /usr/bin/last)
GREP=$(resolve_cmd grep /bin/grep)
SED=$(resolve_cmd sed /bin/sed)
AWK=$(resolve_cmd awk /usr/bin/awk)
TR=$(resolve_cmd tr /usr/bin/tr)
TEE=$(resolve_cmd tee /usr/bin/tee)
CUT=$(resolve_cmd cut /usr/bin/cut)
DATE=$(resolve_cmd date /bin/date)
WC=$(resolve_cmd wc /usr/bin/wc)
HEAD=$(resolve_cmd head /usr/bin/head)
BASENAME=$(resolve_cmd basename /usr/bin/basename)
FIND=$(resolve_cmd find /usr/bin/find)
CHMOD=$(resolve_cmd chmod /bin/chmod)
MKDIR=$(resolve_cmd mkdir /bin/mkdir)
CP=$(resolve_cmd cp /bin/cp)
MV=$(resolve_cmd mv /bin/mv)
TOUCH=$(resolve_cmd touch /bin/touch)
CAT=$(resolve_cmd cat /bin/cat)
RM=$(resolve_cmd rm /bin/rm)
PRINTF=$(resolve_cmd printf /usr/bin/printf)
ID=$(resolve_cmd id /usr/bin/id)

# ---- Configuration ----------------------------------------------------------
BASE_DIR="/etc/nftban/config"
CONF_FILE="/etc/nftables.conf"
ALLOW_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_DIR="/var/log/nftban"
LOG_FILE="$LOG_DIR/nftban.log"
TEMP_BAN_TABLE="nftban_global"
TEMP_BAN_SET_V4="temp_ban_v4"
TEMP_BAN_SET_V6="temp_ban_v6"
FAIL2BAN_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_DIR="$FAIL2BAN_DIR/jail.d"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
# Behaviour toggles
: "${ENABLE_LOGGING:=true}"
: "${REQUIRE_F2B:=false}"
: "${APPLY_ON_CHANGE:=true}"     # default: apply nftables.conf on file change
: "${F2B_FORCE_BAN:=true}"       # default: also ban via Fail2Ban across all jails on perm-ban
: "${LOCK_FILE:=/var/lock/nftban.lock}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

VERSION="3.3.1"
VERSION_FILE="/etc/nftban/.version"

# Ensure directories
$MKDIR -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null || true
$CHMOD 755 "$BASE_DIR" 2>/dev/null || true
$CHMOD 750 "$BACKUP_DIR" 2>/dev/null || true
$CHMOD 755 "$LOG_DIR" 2>/dev/null || true

# Optional single-instance lock
if command -v flock >/dev/null 2>&1; then
  exec {LOCKFD}>"$LOCK_FILE"
  if ! flock -n "$LOCKFD"; then
    $PRINTF "%s\n" "${RED}Another nftban instance is running. Exiting.${NC}"
    exit 1
  fi
fi

# ---- Utilities --------------------------------------------------------------
log() {
  local message="$1"
  local timestamp
  timestamp=$($DATE '+%Y-%m-%d %H:%M:%S')
  if [ "$ENABLE_LOGGING" = true ]; then
    $PRINTF "%s - %s\n" "$timestamp" "$message" | $TEE -a "$LOG_FILE" >/dev/null
  else
    $PRINTF "%s - %s\n" "$timestamp" "$message"
  fi
}

# ---- IP validation ----------------------------------------------------------
_is_ipv4() { local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local IFS='.'; read -r o1 o2 o3 o4 <<< "$ip"; for o in $o1 $o2 $o3 $o4; do [[ $o -ge 0 && $o -le 255 ]] || return 1; done; }
_is_ipv4_cidr() { local s="$1"; [[ "$s" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1; local ip="${BASH_REMATCH[1]}"; local p="${BASH_REMATCH[2]}"; _is_ipv4 "$ip" || return 1; [[ $p -ge 0 && $p -le 32 ]]; }
_is_ipv6_like() { local s="$1"; [[ "$s" == *:* ]] || return 1; [[ "$s" =~ ^[0-9A-Fa-f:]+(/([0-9]{1,3}))?$ ]] || return 1; if [[ "$s" == */* ]]; then local p="${s#*/}"; [[ $p -ge 0 && $p -le 128 ]] || return 1; fi; }
_is_ip_like() { _is_ipv4 "$1" || _is_ipv4_cidr "$1" || _is_ipv6_like "$1"; }

# ---- Helpers ---------------------------------------------------------------
sanitize_comment() { echo "$1" | $TR -d '\n\r' | $SED 's/[;&`$]//g' | $CUT -c1-200; }
get_current_login_ip() {
  local login_ip=""
  if [ -n "${SSH_CLIENT:-}" ]; then login_ip=$(echo "$SSH_CLIENT" | $AWK '{print $1}'); fi
  if [ -z "$login_ip" ] || [ "$login_ip" = "unknown" ]; then login_ip=$($WHO -u | $AWK '{print $NF}' | $SED 's/[\(\)]//g' | $GREP -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | $HEAD -n 1 || true); fi
  if [ -z "$login_ip" ]; then if command -v ss >/dev/null 2>&1; then login_ip=$($SS -tpn | $GREP -E 'sshd.*ESTAB' | $AWK '{print $5}' | $CUT -d: -f1 | $HEAD -n 1 || true); elif command -v netstat >/dev/null 2>&1; then login_ip=$($NETSTAT -tpn | $GREP -E 'sshd.*ESTABLISHED' | $AWK '{print $5}' | $CUT -d: -f1 | $HEAD -n 1 || true); fi; fi
  echo "${login_ip:-unknown}"
}
check_ip_in_allow() { local ip="$1"; [ -f "$ALLOW_FILE" ] && $GREP -Eq "^${ip}([[:space:]]|$)" "$ALLOW_FILE"; }

ensure_temp_ban_table() {
  if ! $NFT list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then log "ERROR: Table inet $TEMP_BAN_TABLE not found"; $PRINTF "%b\n" "${RED}ERROR: Global table 'inet $TEMP_BAN_TABLE' not found.${NC}"; $PRINTF "%b\n" "${YELLOW}Run the nftables init script to create the structure.${NC}"; return 1; fi
  if ! $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" >/dev/null 2>&1; then log "ERROR: Set $TEMP_BAN_SET_V4 missing in $TEMP_BAN_TABLE"; $PRINTF "%b\n" "${RED}ERROR: Set '$TEMP_BAN_SET_V4' missing. Run init first.${NC}"; return 1; fi
  if ! $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" >/dev/null 2>&1; then log "ERROR: Set $TEMP_BAN_SET_V6 missing in $TEMP_BAN_TABLE"; $PRINTF "%b\n" "${RED}ERROR: Set '$TEMP_BAN_SET_V6' missing. Run init first.${NC}"; return 1; fi
}

is_current_login_ip() { local ip="$1"; local cip; cip=$(get_current_login_ip); [ "$ip" = "$cip" ]; }

# ---- Fail2Ban helpers -------------------------------------------------------
fail2ban_installed() { command -v "$F2B" >/dev/null 2>&1; }
get_f2b_jails() { "$F2B" status 2>/dev/null | $GREP "Jail list" | $SED 's/^.*Jail list:\s*//' | $TR ',' '\n' | $SED 's/^ *//;s/ *$//' | $GREP -v '^$' || true; }
ban_in_fail2ban_all_jails() { local ip="$1"; fail2ban_installed || return 0; local jail; for jail in $(get_f2b_jails); do "$F2B" set "$jail" banip "$ip" >/dev/null 2>&1 || true; done; }
unban_in_fail2ban_all_jails() { local ip="$1"; fail2ban_installed || return 0; local jail; for jail in $(get_f2b_jails); do if "$F2B" status "$jail" 2>/dev/null | $GREP -q "$ip"; then "$F2B" set "$jail" unbanip "$ip" >/dev/null 2>&1 || true; fi; done; }

# ---- File operations (atomic) ----------------------------------------------
init_list_file_if_missing() { local file="$1"; local header="$2"; if [ ! -f "$file" ]; then $TOUCH "$file" && $CHMOD 644 "$file"; { echo "# $($BASENAME "$file") - managed by nftban"; [ -n "$header" ] && echo "$header"; echo ""; } >"$file"; fi }
atomic_append_unique() { local file="$1" line="$2" tmp="${file}.tmp"; $CP "$file" "$tmp"; local ip_only; ip_only=$(echo "$line" | $AWK '{print $1}'); $SED -i "/^${ip_only}\([[:space:]].*\)\?$/d" "$tmp"; echo "$line" >>"$tmp"; $MV "$tmp" "$file"; }
atomic_delete_ip_line() { local file="$1" ip="$2" tmp="${file}.tmp"; [ -f "$file" ] || return 1; $CP "$file" "$tmp" || return 1; $SED -i "/^${ip}\([[:space:]].*\)\?$/d" "$tmp"; $MV "$tmp" "$file" || { $RM -f "$tmp"; return 1; }; }

# ---- Apply nftables.conf if safe -------------------------------------------
apply_blacklists_if_possible() {
  if [ "$APPLY_ON_CHANGE" != true ]; then return 0; fi
  if [ -f "$CONF_FILE" ]; then
    if $NFT -c -f "$CONF_FILE" >/dev/null 2>&1; then
      if $NFT -f "$CONF_FILE" >/dev/null 2>&1; then log "Applied nftables.conf after list change"; $PRINTF "%b\n" "${GREEN}nftables configuration reloaded (blacklists applied)${NC}"; return 0; else log "WARN: Failed to apply nftables.conf (runtime)."; $PRINTF "%b\n" "${YELLOW}Warning: Failed to reload nftables configuration${NC}"; fi
    else
      log "WARN: nftables.conf failed syntax check; NOT applying."; $PRINTF "%b\n" "${YELLOW}Warning: nftables.conf failed check; changes kept on disk only${NC}"
    fi
  fi
}

# ---- Core ban/unban ---------------------------------------------------------
temp_ban_ip() {
  local ip="$1"; local comment="${2:-}"; comment=$(sanitize_comment "$comment");
  is_current_login_ip "$ip" && { $PRINTF "%b\n" "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"; log "Attempted to ban own IP $ip"; return 1; }
  ensure_temp_ban_table || return 1
  [ -z "$comment" ] && comment="Temporarily banned by nftban on $($DATE '+%Y-%m-%d %H:%M:%S')"
  local set_name ip_version; if [[ "$ip" == *:* ]]; then set_name="$TEMP_BAN_SET_V6"; ip_version="IPv6"; else set_name="$TEMP_BAN_SET_V4"; ip_version="IPv4"; fi
  if $NFT add element inet "$TEMP_BAN_TABLE" "$set_name" "{ $ip timeout 1h }" 2>/dev/null; then log "Temp-banned $ip_version $ip (1h) comment: $comment"; $PRINTF "%b\n" "${RED}[OK] Temporarily banned $ip_version: $ip (1h)${NC}"; [ -n "$comment" ] && $PRINTF "%b\n" "${YELLOW}Comment: $comment${NC}"; return 0; fi
  if $NFT list set inet "$TEMP_BAN_TABLE" "$set_name" 2>/dev/null | $GREP -q "$ip"; then $PRINTF "%b\n" "${YELLOW}[WARN] $ip is already temporarily banned${NC}"; log "$ip already in temp set"; return 2; fi
  $PRINTF "%b\n" "${RED}[ERROR] Failed to add $ip_version $ip to temp-ban set${NC}"; return 1
}

perm_ban_ip() {
  local ip="$1"; local comment="${2:-}"; comment=$(sanitize_comment "$comment")
  is_current_login_ip "$ip" && { $PRINTF "%b\n" "${RED}ERROR: Cannot ban your own login IP ($ip)${NC}"; log "Attempted to ban own IP $ip"; return 1; }
  [ -z "$comment" ] && comment="Permanently banned by nftban on $($DATE '+%Y-%m-%d %H:%M:%S')"
  local blacklist_file; [[ "$ip" == *:* ]] && blacklist_file="$IPV6_BLACKLIST_FILE" || blacklist_file="$IPV4_BLACKLIST_FILE"
  init_list_file_if_missing "$blacklist_file" "# Format: IP_ADDRESS # comment"
  atomic_append_unique "$blacklist_file" "$ip # $comment"
  log "Added $ip to blacklist file $(basename "$blacklist_file")"; $PRINTF "%b\n" "${RED}Permanently banned IP: $ip${NC}"; $PRINTF "%b\n" "${YELLOW}Comment: $comment${NC}"
  temp_ban_ip "$ip" "$comment (perm-ban runtime)" >/dev/null 2>&1 || true
  if [ "$F2B_FORCE_BAN" = true ] && fail2ban_installed; then ban_in_fail2ban_all_jails "$ip"; fi
  apply_blacklists_if_possible
}

remove_temp_ban() {
  local ip="$1"; local removed=false
  if [[ "$ip" == *:* ]]; then if $NFT delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" "{ $ip }" 2>/dev/null; then log "Removed temp ban IPv6: $ip"; $PRINTF "%b\n" "${GREEN}Removed temporary ban (IPv6): $ip${NC}"; removed=true; fi
  else if $NFT delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" "{ $ip }" 2>/dev/null; then log "Removed temp ban IPv4: $ip"; $PRINTF "%b\n" "${GREEN}Removed temporary ban (IPv4): $ip${NC}"; removed=true; fi; fi
  [ "$removed" = true ] && return 0 || { log "$ip not found in temp sets"; $PRINTF "%b\n" "${YELLOW}$ip not found in temp-ban sets${NC}"; return 1; }
}

remove_ip_from_blacklist() { local ip="$1"; local file; [[ "$ip" == *:* ]] && file="$IPV6_BLACKLIST_FILE" || file="$IPV4_BLACKLIST_FILE"; if [ -f "$file" ]; then if atomic_delete_ip_line "$file" "$ip"; then log "Removed $ip from blacklist file $(basename "$file")"; $PRINTF "%b\n" "${GREEN}Removed $ip from blacklist file${NC}"; return 0; fi; fi; return 1; }
remove_ip_from_whitelist() { local ip="$1"; [ -f "$ALLOW_FILE" ] || return 1; if atomic_delete_ip_line "$ALLOW_FILE" "$ip"; then log "Removed $ip from whitelist"; $PRINTF "%b\n" "${GREEN}Removed $ip from whitelist file${NC}"; return 0; fi; return 1; }
remove_ip_from_fail2ban() { local ip="$1"; fail2ban_installed || return 1; local changed=false jail; for jail in $(get_f2b_jails); do if "$F2B" status "$jail" 2>/dev/null | $GREP -q "$ip"; then if "$F2B" set "$jail" unbanip "$ip" >/dev/null 2>&1; then log "Unbanned $ip from Fail2Ban jail $jail"; $PRINTF "%b\n" "${GREEN}Unbanned $ip from Fail2Ban jail: $jail${NC}"; changed=true; fi; fi; done; [ "$changed" = true ] && return 0 || return 1; }

remove_ip_from_all() {
  local ip="$1"; local any=false
  $PRINTF "%b\n" "${BLUE}Removing $ip from runtime + persistent bans...${NC}"
  remove_temp_ban "$ip" && any=true || true
  remove_ip_from_blacklist "$ip" && any=true || true
  remove_ip_from_whitelist "$ip" && any=true || true
  remove_ip_from_fail2ban "$ip" && any=true || true
  if [ "$any" = true ]; then apply_blacklists_if_possible; log "Removed $ip from all places"; $PRINTF "%b\n" "${GREEN}Removed $ip from all places (nft temp sets, F2B, files)${NC}"; return 0; else log "$ip not found anywhere"; $PRINTF "%b\n" "${YELLOW}$ip not found in any set/file/jail${NC}"; return 1; fi
}

# ---- Allowlist --------------------------------------------------------------
add_ip_to_allow() { local ip="$1"; local ts; ts=$($DATE '+%Y-%m-%d %H:%M:%S'); init_list_file_if_missing "$ALLOW_FILE" "# Format: IP_ADDRESS [optional comment]"; if check_ip_in_allow "$ip"; then log "IP $ip already allowed"; return 2; fi; local user; user=$($ID -un 2>/dev/null || echo user); atomic_append_unique "$ALLOW_FILE" "$ip # Added by nftban on $ts for user $user"; log "Allowed IP $ip"; }

# ---- Status/Info ------------------------------------------------------------
get_nftables_status() { if "$SYSTEMCTL" is-active nftables >/dev/null 2>&1; then echo "active"; else echo "inactive"; fi; }
get_fail2ban_status() { if fail2ban_installed; then if "$SYSTEMCTL" is-active fail2ban >/dev/null 2>&1; then echo "active"; else echo "inactive"; fi; else echo "not installed"; fi; }
show_version() { echo "nftban version $VERSION"; echo "Configuration directory: $BASE_DIR"; if [ -f "$VERSION_FILE" ]; then local installed_version; installed_version=$($CAT "$VERSION_FILE" 2>/dev/null || echo "unknown"); echo "Installed version: $installed_version"; fi; }
show_status() { $PRINTF "%b\n" "${BLUE}=== nftban Status ===${NC}"; echo "nftban path: $(dirname "$BASE_DIR")"; if command -v "$NFT" >/dev/null 2>&1; then echo "nftables: $($NFT --version 2>/dev/null | $HEAD -1)"; else echo "nft: ${RED}not found${NC}"; fi; if fail2ban_installed; then echo "fail2ban: $($F2B --version 2>/dev/null | $HEAD -1 | $TR -s ' ')"; else echo "fail2ban: ${YELLOW}not installed${NC}"; fi; if [ -f "/etc/systemd/system/nftban.service" ]; then echo "systemd unit: ${GREEN}present${NC}"; else echo "systemd unit: ${YELLOW}not found (optional)${NC}"; fi; echo "nftables service: $(get_nftables_status)"; echo "Fail2Ban service: $(get_fail2ban_status)"; if $NFT list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then echo "Global table: ${GREEN}exists${NC}"; else echo "Global table: ${RED}missing${NC}"; fi; }
backup_config() { local ts; ts=$($DATE '+%Y%m%d_%H%M%S'); $MKDIR -p "$BACKUP_DIR"; [ -f "$CONF_FILE" ] && $CP "$CONF_FILE" "$BACKUP_DIR/nftables.conf.$ts" && log "Backed up to $BACKUP_DIR/nftables.conf.$ts"; }
list_rules() { $PRINTF "%b\n" "${BLUE}Current nftables rules:${NC}"; "$NFT" list ruleset; }
check_nftables_config() { "$NFT" -c -f "$CONF_FILE" >/dev/null 2>&1 || { log "nftables config check failed"; $PRINTF "%b\n" "${RED}nftables configuration check failed!${NC}"; return 1; }; log "nftables config check passed"; $PRINTF "%b\n" "${GREEN}nftables configuration check passed${NC}"; }
check_fail2ban_config() { if fail2ban_installed; then "$F2B" --test >/dev/null 2>&1 || { log "Fail2Ban config check failed"; $PRINTF "%b\n" "${RED}Fail2Ban configuration check failed!${NC}"; return 1; }; log "Fail2Ban config check passed"; $PRINTF "%b\n" "${GREEN}Fail2Ban configuration check passed${NC}"; else log "Fail2Ban not installed"; $PRINTF "%b\n" "${YELLOW}Fail2Ban is not installed${NC}"; return 1; fi }
check_config() { local nft_ok=true f2b_ok=true; $PRINTF "%b\n" "${BLUE}Checking nftables configuration...${NC}"; check_nftables_config || nft_ok=false; $PRINTF "%b\n" "${BLUE}Checking Fail2Ban configuration...${NC}"; check_fail2ban_config || f2b_ok=false; if [ "$nft_ok" = true ] && { [ "$f2b_ok" = true ] || [ "$REQUIRE_F2B" = false ]; }; then return 0; else return 1; fi }
start_nftables_service() { if "$SYSTEMCTL" start nftables 2>/dev/null; then log "Started nftables"; $PRINTF "%b\n" "${GREEN}nftables service started${NC}"; else log "Failed to start nftables"; $PRINTF "%b\n" "${RED}Failed to start nftables${NC}"; return 1; fi }
stop_nftables_service() { if "$SYSTEMCTL" stop nftables 2>/dev/null; then log "Stopped nftables"; $PRINTF "%b\n" "${YELLOW}nftables service stopped${NC}"; else log "Failed to stop nftables"; $PRINTF "%b\n" "${RED}Failed to stop nftables${NC}"; return 1; fi }
start_fail2ban_service() { if "$SYSTEMCTL" start fail2ban 2>/dev/null; then log "Started Fail2Ban"; $PRINTF "%b\n" "${GREEN}Fail2Ban service started${NC}"; else log "Failed to start Fail2Ban"; $PRINTF "%b\n" "${RED}Failed to start Fail2Ban${NC}"; return 1; fi }
stop_fail2ban_service() { if "$SYSTEMCTL" stop fail2ban 2>/dev/null; then log "Stopped Fail2Ban"; $PRINTF "%b\n" "${YELLOW}Fail2Ban service stopped${NC}"; else log "Failed to stop Fail2Ban"; $PRINTF "%b\n" "${RED}Failed to stop Fail2Ban${NC}"; return 1; fi }

show_info() { local current_ip; current_ip=$(get_current_login_ip); $PRINTF "%b\n" "${BLUE}=== nftban Information ===${NC}"; echo "Current login IP: $current_ip"; if check_ip_in_allow "$current_ip"; then echo "Allow status: ${GREEN}ALLOWED${NC}"; else echo "Allow status: ${RED}NOT ALLOWED${NC}"; fi; echo "nftables service: $(get_nftables_status)"; echo "Fail2Ban service: $(get_fail2ban_status)"; if $NFT list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then echo "Global table: ${GREEN}exists${NC}"; else echo "Global table: ${RED}missing${NC}"; fi; echo "Allow file: $ALLOW_FILE"; if [ -f "$ALLOW_FILE" ]; then echo " Lines: $($GREP -v '^#' "$ALLOW_FILE" | $GREP -c .) (excluding comments)"; else echo " ${YELLOW}File not found${NC}"; fi; echo "Blacklist files:"; local f; for f in "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"; do if [ -f "$f" ]; then echo " $($BASENAME "$f"): $($GREP -v '^#' "$f" | $GREP -c .) IPs"; else echo " $($BASENAME "$f"): ${YELLOW}not found${NC}"; fi; done; }

list_temp_bans() { $PRINTF "%b\n" "${BLUE}Temporarily banned IPv4 (set: ${TEMP_BAN_SET_V4} in table ${TEMP_BAN_TABLE}):${NC}"; if $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | $GREP -q "elements"; then $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | $GREP -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]{1,2}))?'; else echo "None"; fi; $PRINTF "%b\n" "${BLUE}Temporarily banned IPv6 (set: ${TEMP_BAN_SET_V6} in table ${TEMP_BAN_TABLE}):${NC}"; if $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | $GREP -q "elements"; then $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | $GREP -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/([0-9]{1,3}))?'; else echo "None"; fi; }

view_all_banned() { $PRINTF "%b\n" "${BLUE}=== All Banned IPs (Combined View) ===${NC}"; $PRINTF "%b\n" "${YELLOW}1. nftables temporary bans (IPv4):${NC}"; if $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | $GREP -q "elements"; then $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | $GREP -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]{1,2}))?' | $SED 's/^/ /'; else echo " None"; fi; $PRINTF "%b\n" "${YELLOW}2. nftables temporary bans (IPv6):${NC}"; if $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | $GREP -q "elements"; then $NFT list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | $GREP -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/([0-9]{1,3}))?' | $SED 's/^/ /'; else echo " None"; fi; $PRINTF "%b\n" "${YELLOW}3. Permanent blacklist (IPv4):${NC}"; if [ -f "$IPV4_BLACKLIST_FILE" ]; then $GREP -v '^#' "$IPV4_BLACKLIST_FILE" | $SED 's/^/ /'; else echo " File not found: $IPV4_BLACKLIST_FILE"; fi; $PRINTF "%b\n" "${YELLOW}4. Permanent blacklist (IPv6):${NC}"; if [ -f "$IPV6_BLACKLIST_FILE" ]; then $GREP -v '^#' "$IPV6_BLACKLIST_FILE" | $SED 's/^/ /'; else echo " File not found: $IPV6_BLACKLIST_FILE"; fi; $PRINTF "%b\n" "${YELLOW}5. Fail2Ban bans:${NC}"; if fail2ban_installed; then local jail banned; for jail in $(get_f2b_jails); do banned=$("$F2B" status "$jail" 2>/dev/null | $GREP "Banned IP list:" | $SED 's/^.*Banned IP list:\s*//'); if [ -n "${banned:-}" ] && [ "$banned" != " " ]; then echo " Jail: $jail"; echo "$banned" | $TR ' ' '\n' | $SED 's/^/ /'; fi; done; else echo " Fail2Ban not installed"; fi; }

# ---- Init/Reload/Flush/Reconcile -------------------------------------------
init_config() { $PRINTF "%b\n" "${BLUE}Initializing nftables configuration...${NC}"; local init_script; init_script="$(dirname "$BASE_DIR")/scripts/nftban_init_nftables_conf.sh"; if [ -f "$init_script" ]; then $PRINTF "%b\n" "${GREEN}Found initialization script: $init_script${NC}"; if [ -x "$init_script" ]; then "$init_script"; else $CHMOD +x "$init_script"; "$init_script"; fi; else $PRINTF "%b\n" "${RED}Initialization script not found at: $init_script${NC}"; $PRINTF "%b\n" "${YELLOW}Please ensure nftban is properly installed${NC}"; return 1; fi }
reload_config() { $PRINTF "%b\n" "${BLUE}Reloading nftables configuration...${NC}"; if [ -f "$CONF_FILE" ]; then if "$NFT" -f "$CONF_FILE"; then log "nftables configuration reloaded"; $PRINTF "%b\n" "${GREEN}nftables configuration reloaded${NC}"; else log "Failed to reload nftables"; $PRINTF "%b\n" "${RED}Failed to reload nftables configuration${NC}"; return 1; fi; else $PRINTF "%b\n" "${RED}Configuration file not found: $CONF_FILE${NC}"; $PRINTF "%b\n" "${YELLOW}Run 'nftban init' to initialize configuration${NC}"; return 1; fi }
reconcile_runtime() { $PRINTF "%b\n" "${BLUE}Reconciling runtime with persistent lists...${NC}"; ensure_temp_ban_table || true; reload_config; }
flush_rules() { $PRINTF "%b\n" "${RED}WARNING: This will remove ALL nftables rules!${NC}"; read -r -p "Are you sure? (y/N): " -n 1 REPLY; echo; if [[ "$REPLY" =~ ^[Yy]$ ]]; then if "$NFT" flush ruleset; then log "nftables rules flushed"; $PRINTF "%b\n" "${GREEN}nftables rules flushed${NC}"; else log "Failed to flush rules"; $PRINTF "%b\n" "${RED}Failed to flush rules${NC}"; return 1; fi; else $PRINTF "%b\n" "${YELLOW}Operation cancelled${NC}"; fi }

# ---- CLI / Help -------------------------------------------------------------
show_help() {
  cat <<'EOF'
NFTBan – nftables & Fail2Ban helper (hardened)
==============================================
USAGE
  nftban [OPTION]

CORE OPTIONS
  -e, --enable           Enable+start nftables & Fail2Ban (after config check)
  -d, --disable          Disable+stop nftables & Fail2Ban
  -s, --start            Start nftables & Fail2Ban (after config check)
  -r, --restart          Restart nftables & Fail2Ban (after config check)
  -x, --stop             Stop nftables & Fail2Ban
  -l, --list             List current nftables rules
  -c, --check            Check nftables & Fail2Ban configuration syntax
  -a, --add-ip [IP]      Add the given IP (or current login IP if omitted) to allowlist
  -i, --info             Show info about current IP and files
  -tb, --temp-ban IP [COMMENT]   Temporarily ban an IP (1h)
  -pb, --perm-ban IP [COMMENT]   Permanently ban an IP (writes file + runtime ban, Fail2Ban ban if enabled)
  -rb, --remove-ban IP   Remove IP from ALL places (nft temp sets, Fail2Ban, files)
  -lt, --list-temp       List temporarily banned IPs
      --enable-logging   Enable logging to file (default)
      --disable-logging  Disable logging to file

MANAGEMENT OPTIONS
  help, --help, -h       Show this help
  version, --version     Show version information
  status                 Show status
  list                   List current nftables rules
  flush                  Flush ALL nftables rules (danger!)
  init                   Initialize nftables configuration
  reload                 Reload nftables configuration
  reconcile              Reconcile runtime with persistent lists (for systemd timers)
  config                 Show configuration directory summary

FAIL2BAN OPTIONS
  -fj, --fail2ban-jails          View Fail2Ban jails
  -fr, --fail2ban-rules <JAIL>   View jail rules
  -fb, --fail2ban-banned [JAIL]  View banned IPs
  -fc, --fail2ban-check          Check Fail2Ban configuration only

ADVANCED
  -vb, --view-banned     Combined view: nft temp sets + blacklists + Fail2Ban
  -ri, --remove-ip IP    Alias of --remove-ban (full cleanup)

ENVIRONMENT TOGGLES
  REQUIRE_F2B=true       Make checks fail if Fail2Ban missing/misconfigured
  ENABLE_LOGGING=false   Disable file logging without changing flags
  APPLY_ON_CHANGE=false  Do NOT auto-apply nftables.conf after list edits
  F2B_FORCE_BAN=false    Disable Fail2Ban ban on perm-ban

EOF
}

show_config_dir() {
  $PRINTF "%b\n" "${BLUE}Configuration directory: $BASE_DIR${NC}"; $PRINTF "%b\n" "${BLUE}Available configuration files:${NC}"; if [ -d "$BASE_DIR" ]; then local count=0 file filename size; for file in "$BASE_DIR"/*.conf.local; do [ -f "$file" ] || continue; filename=$($BASENAME "$file"); size=$($WC -l <"$file" 2>/dev/null || echo 0); echo " - $filename ($size lines)"; count=$((count+1)); done; [ $count -eq 0 ] && echo " ${YELLOW}No configuration files found${NC}"; else echo " ${RED}Configuration directory does not exist${NC}"; echo " ${YELLOW}Run 'nftban init' to initialize configuration${NC}"; fi; local templates_dir; templates_dir="$(dirname "$BASE_DIR")/templates"; if [ -d "$templates_dir" ]; then $PRINTF "%b\n" "${BLUE}Available templates:${NC}"; for template in "$templates_dir"/control-panels/*.conf; do [ -f "$template" ] && echo " - $($BASENAME "$template")"; done; fi
}

# ---- Main -------------------------------------------------------------------
main() {
  local arg1="${1:-}" arg2="${2:-}" arg3="${3:-}"
  case "$arg1" in
    -e|--enable) backup_config; if check_config; then "$SYSTEMCTL" enable nftables 2>/dev/null || true; "$SYSTEMCTL" enable fail2ban 2>/dev/null || true; start_nftables_service; start_fail2ban_service; else $PRINTF "%b\n" "${RED}Configuration check failed, not enabling services${NC}"; return 1; fi ;;
    -d|--disable) "$SYSTEMCTL" disable nftables 2>/dev/null || true; "$SYSTEMCTL" disable fail2ban 2>/dev/null || true; stop_nftables_service; stop_fail2ban_service ;;
    -s|--start) backup_config; if check_config; then start_nftables_service; start_fail2ban_service; else $PRINTF "%b\n" "${RED}Configuration check failed, not starting services${NC}"; return 1; fi ;;
    -r|--restart) backup_config; if check_config; then stop_nftables_service || true; start_nftables_service; "$SYSTEMCTL" restart fail2ban 2>/dev/null || start_fail2ban_service; else $PRINTF "%b\n" "${RED}Configuration check failed, not restarting${NC}"; return 1; fi ;;
    -x|--stop) stop_nftables_service; stop_fail2ban_service ;;
    -l|--list) list_rules ;;
    -c|--check) check_config ;;
    -a|--add-ip) if [ -n "${arg2:-}" ] && _is_ip_like "$arg2"; then add_ip_to_allow "$arg2"; else local cip; cip=$(get_current_login_ip); [ "$cip" != "unknown" ] || { $PRINTF "%b\n" "${YELLOW}Could not determine your login IP${NC}"; return 1; }; add_ip_to_allow "$cip"; fi ;;
    -i|--info) show_info ;;
    -tb|--temp-ban) [ -n "${arg2:-}" ] && _is_ip_like "$arg2" && temp_ban_ip "$arg2" "${arg3:-}" || { $PRINTF "%b\n" "${RED}Usage: nftban --temp-ban <IP> [COMMENT]${NC}"; return 1; } ;;
    -pb|--perm-ban) [ -n "${arg2:-}" ] && _is_ip_like "$arg2" && perm_ban_ip "$arg2" "${arg3:-}" || { $PRINTF "%b\n" "${RED}Usage: nftban --perm-ban <IP> [COMMENT]${NC}"; return 1; } ;;
    -rb|--remove-ban) [ -n "${arg2:-}" ] && _is_ip_like "$arg2" && remove_ip_from_all "$arg2" || { $PRINTF "%b\n" "${RED}Usage: nftban --remove-ban <IP>${NC}"; return 1; } ;;
    -lt|--list-temp) list_temp_bans ;;
    --enable-logging) ENABLE_LOGGING=true; echo "${GREEN}Logging enabled${NC}" ;;
    --disable-logging) ENABLE_LOGGING=false; echo "${YELLOW}Logging disabled${NC}" ;;
    -h|--help|help) show_help ;;
    version|--version) show_version ;;
    status) show_status ;;
    list) list_rules ;;
    flush) flush_rules ;;
    init) init_config ;;
    reload) reload_config ;;
    reconcile) reconcile_runtime ;;
    config) show_config_dir ;;
    -fj|--fail2ban-jails) view_fail2ban_jails ;;
    -fr|--fail2ban-rules) view_fail2ban_rules "${arg2:-}" ;;
    -fb|--fail2ban-banned) view_fail2ban_banned "${arg2:-}" ;;
    -fc|--fail2ban-check) check_fail2ban_config ;;
    -vb|--view-banned) view_all_banned ;;
    -ri|--remove-ip) [ -n "${arg2:-}" ] && _is_ip_like "$arg2" && remove_ip_from_all "$arg2" || { $PRINTF "%b\n" "${RED}Usage: nftban --remove-ip <IP>${NC}"; return 1; } ;;
    *) $PRINTF "%b\n" "${RED}Unknown option: ${arg1:-<none>}${NC}"; $PRINTF "%b\n" "${YELLOW}Use 'nftban --help' for usage information${NC}"; return 1 ;;
  esac
}

if [ $# -eq 0 ]; then show_help; exit 0; fi
main "$@"; exit $?