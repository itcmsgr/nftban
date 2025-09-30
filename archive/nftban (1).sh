#!/bin/bash
################################################################################
# Script: nftban.sh (enhanced)
# A comprehensive nftables + Fail2Ban management tool with unified logging,
# conflict resolution, validation, and a unified list/search/sync interface.
# Version: 4.0.0
# Author: ITCMS Team (Antonios Voulvoulis) + assistant improvements
# NOTE: RUN AS ROOT
################################################################################

# ========================
# Configurable paths/vars
# ========================
BASE_DIR="/etc/nftban/config"
CONF_FILE="/etc/nftables.conf"
ALLOW_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_FILE="/var/log/nftban.log"
HISTORY_FILE="/var/log/nftban_history.csv"           # NEW: persistent, unified audit log
TEMP_BAN_TABLE="nftban_temp_ban"
FAIL2BAN_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_DIR="$FAIL2BAN_DIR/jail.d"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"

# Policy knobs
WHITELIST_PRECEDENCE="true"      # if an IP is in both allow & block, whitelist wins
DEFAULT_TEMP_TIMEOUT="1h"        # temp ban timeout for nft sets
VALIDATE_REACHABILITY="true"     # ping/ndisc check before banning
ENABLE_LOGGING="true"            # stdout + LOG_FILE
CSV_QUOTE_CHAR='"'

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ========================
# Utility / Logging
# ========================

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
  local msg="$1"
  local ts=$(_ts)
  if [ "$ENABLE_LOGGING" = "true" ]; then
    echo "$ts - $msg" | tee -a "$LOG_FILE"
  else
    echo "$ts - $msg"
  fi
}

# Ensure history file with header exists
_init_history() {
  if [ ! -f "$HISTORY_FILE" ]; then
    mkdir -p "$(dirname "$HISTORY_FILE")"
    echo "timestamp,action,ip,family,scope,reason,status,actor,source,notes" > "$HISTORY_FILE"
    chmod 640 "$HISTORY_FILE"
  fi
}

_csv_escape() {
  # Escape CSV by doubling quotes and surrounding with quotes
  local s="$1"
  s="${s//${CSV_QUOTE_CHAR}/${CSV_QUOTE_CHAR}${CSV_QUOTE_CHAR}}"
  echo "${CSV_QUOTE_CHAR}${s}${CSV_QUOTE_CHAR}"
}

_log_event() {
  # action: add|remove|update|sync|check|conflict_resolved|error
  # family: IPv4|IPv6|unknown
  # scope : temp|perm|fail2ban|whitelist|ruleset|system
  # status: success|fail|info
  local action="$1" ip="$2" family="$3" scope="$4" reason="$5" status="$6" actor source notes
  actor="$(whoami 2>/dev/null || echo root)"
  source="${7:-nftban}"
  notes="${8:-}"
  _init_history
  local ts=$(_ts)
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
     "$ts" "$(_csv_escape "$action")" "$(_csv_escape "$ip")" "$(_csv_escape "$family")" \
     "$(_csv_escape "$scope")" "$(_csv_escape "$reason")" "$(_csv_escape "$status")" \
     "$(_csv_escape "$actor")" "$(_csv_escape "$source")" "$(_csv_escape "$notes")" \
     >> "$HISTORY_FILE"
}

# ========================
# Helpers
# ========================

get_current_login_ip() {
  local login_ip=""
  if [ -n "$SSH_CLIENT" ]; then login_ip=$(echo "$SSH_CLIENT" | awk '{print $1}'); fi
  if [ -z "$login_ip" ]; then login_ip=$(who -u | awk '{print $NF}' | sed 's/[()]//g' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1); fi
  if [ -z "$login_ip" ] && command -v last >/dev/null 2>&1; then
    login_ip=$(last -i | grep "still logged in" | awk '{print $3}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
  fi
  if [ -z "$login_ip" ]; then
    if command -v ss >/dev/null 2>&1; then
      login_ip=$(ss -tpn | grep -E "sshd.*ESTAB" | awk '{print $5}' | cut -d: -f1 | head -n 1)
    elif command -v netstat >/dev/null 2>&1; then
      login_ip=$(netstat -tpn | grep -E "sshd.*ESTABLISHED" | awk '{print $5}' | cut -d: -f1 | head -n 1)
    fi
  fi
  echo "${login_ip:-unknown}"
}

is_current_login_ip() {
  local ip="$1"
  local current_ip; current_ip=$(get_current_login_ip)
  [ "$ip" = "$current_ip" ]
}

# Validate IP format (v4/v6); optional reachability
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; }

validate_ip() {
  local ip="$1"
  if is_ipv4 "$ip"; then echo "IPv4"; return 0; fi
  if is_ipv6 "$ip"; then echo "IPv6"; return 0; fi
  echo "unknown"; return 1
}

reachable_ip() {
  local ip="$1" fam="$2"
  if [ "$VALIDATE_REACHABILITY" != "true" ]; then return 0; fi
  if [ "$fam" = "IPv6" ]; then
    command -v ping6 >/dev/null 2>&1 && ping6 -c1 -W1 "$ip" >/dev/null 2>&1
  else
    ping -c1 -W1 "$ip" >/dev/null 2>&1
  fi
}

# Extract comment after "#" from a file line
get_comment_from_file_line() {
  local line="$1"
  if [[ "$line" == *"#"* ]]; then echo "${line#*# }"; else echo ""; fi
}

ensure_files() {
  mkdir -p "$BASE_DIR"
  for f in "$ALLOW_FILE" "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"; do
    if [ ! -f "$f" ]; then
      echo "# managed by nftban" > "$f"
      chmod 644 "$f"
    fi
  done
}

check_ip_in_allow() { local ip="$1"; [ -f "$ALLOW_FILE" ] && grep -q "^$ip\\b" "$ALLOW_FILE"; }

add_ip_to_allow() {
  local ip="$1"
  ensure_files
  if ! check_ip_in_allow "$ip"; then
    echo "$ip # added $(date '+%F %T')" >> "$ALLOW_FILE"
    _log "Added $ip to whitelist"
    _log_event "add" "$ip" "$(validate_ip "$ip")" "whitelist" "manual add" "success"
    echo "true"; return 0
  fi
  echo "false"; return 1
}

remove_ip_from_whitelist() {
  local ip="$1"
  if [ -f "$ALLOW_FILE" ] && grep -q "^$ip\\b" "$ALLOW_FILE"; then
    sed -i "/^$ip\\b/d" "$ALLOW_FILE"
    _log "Removed $ip from whitelist"
    _log_event "remove" "$ip" "$(validate_ip "$ip")" "whitelist" "conflict/cleanup" "success"
    echo "true"; return 0
  fi
  echo "false"; return 1
}

remove_ip_from_blacklist() {
  local ip="$1" blf=""
  if [[ "$ip" == *:* ]]; then blf="$IPV6_BLACKLIST_FILE"; else blf="$IPV4_BLACKLIST_FILE"; fi
  if [ -f "$blf" ] && grep -q "^$ip\\b" "$blf"; then
    sed -i "/^$ip\\b/d" "$blf"
    _log "Removed $ip from blacklist file $blf"
    _log_event "remove" "$ip" "$(validate_ip "$ip")" "perm" "manual remove" "success"
    echo "true"; return 0
  fi
  echo "false"; return 1
}

add_ip_to_blacklist() {
  local ip="$1" comment="$2" blf=""
  [ -z "$comment" ] && comment="permanent ban $(date '+%F %T')"
  if [[ "$ip" == *:* ]]; then blf="$IPV6_BLACKLIST_FILE"; else blf="$IPV4_BLACKLIST_FILE"; fi
  ensure_files
  if grep -q "^$ip\\b" "$blf"; then
    sed -i "s/^$ip.*$/$ip # $comment/" "$blf"
    _log "Updated blacklist entry for $ip: $comment"
  else
    echo "$ip # $comment" >> "$blf"
    _log "Added $ip to blacklist: $comment"
  fi
  _log_event "add" "$ip" "$(validate_ip "$ip")" "perm" "$comment" "success"
  echo "true"
}

check_nftables_config() {
  if nft -c -f "$CONF_FILE" >>"$LOG_FILE" 2>&1; then
    _log "nftables config check passed"; echo -e "${GREEN}nftables configuration OK${NC}"; return 0
  else
    _log "nftables config check FAILED"; echo -e "${RED}nftables configuration check failed${NC}"; return 1
  fi
}

check_fail2ban_config() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client --test >>"$LOG_FILE" 2>&1; then _log "Fail2Ban config OK"; echo -e "${GREEN}Fail2Ban configuration OK${NC}"; return 0
    else _log "Fail2Ban config FAILED"; echo -e "${RED}Fail2Ban configuration failed${NC}"; return 1; fi
  else
    _log "Fail2Ban not installed"; echo -e "${YELLOW}Fail2Ban not installed${NC}"; return 1
  fi
}

check_config() {
  local ok=true
  check_nftables_config || ok=false
  check_fail2ban_config || ok=false
  $ok
}

backup_config() {
  local ts=$(date '+%Y%m%d_%H%M%S'); mkdir -p "$BACKUP_DIR"
  if [ -f "$CONF_FILE" ]; then cp "$CONF_FILE" "$BACKUP_DIR/nftables.conf.$ts"; _log "Backed up nftables.conf -> $BACKUP_DIR/nftables.conf.$ts"; fi
}

list_rules() { echo -e "${BLUE}Current nftables rules:${NC}"; nft list ruleset; }

enable_nftables_service() { systemctl enable nftables 2>/dev/null; _log "Enabled nftables service"; }
disable_nftables_service() { systemctl disable nftables 2>/dev/null; _log "Disabled nftables service"; }
start_nftables_service() { if systemctl start nftables 2>/dev/null; then _log "Started nftables"; echo -e "${GREEN}nftables started${NC}"; else echo -e "${RED}Failed to start nftables${NC}"; fi; }
stop_nftables_service() { if systemctl stop nftables 2>/dev/null; then _log "Stopped nftables"; echo -e "${YELLOW}nftables stopped${NC}"; else echo -e "${RED}Failed to stop nftables${NC}"; fi; }
enable_fail2ban_service() { systemctl enable fail2ban 2>/dev/null; _log "Enabled fail2ban"; }
disable_fail2ban_service() { systemctl disable fail2ban 2>/dev/null; _log "Disabled fail2ban"; }
start_fail2ban_service() { if systemctl start fail2ban 2>/dev/null; then _log "Started fail2ban"; echo -e "${GREEN}fail2ban started${NC}"; else echo -e "${RED}Failed to start fail2ban${NC}"; fi; }
stop_fail2ban_service() { if systemctl stop fail2ban 2>/dev/null; then _log "Stopped fail2ban"; echo -e "${YELLOW}fail2ban stopped${NC}"; else echo -e "${RED}Failed to stop fail2ban${NC}"; fi; }

ensure_temp_ban_table() {
  if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    nft add table inet "$TEMP_BAN_TABLE"
    nft add set inet "$TEMP_BAN_TABLE" temp_ban_v4 "{ type ipv4_addr; timeout $DEFAULT_TEMP_TIMEOUT; }"
    nft add set inet "$TEMP_BAN_TABLE" temp_ban_v6 "{ type ipv6_addr; timeout $DEFAULT_TEMP_TIMEOUT; }"
    nft add chain inet "$TEMP_BAN_TABLE" input "{ type filter hook input priority -150; policy accept; }"
    nft add rule inet "$TEMP_BAN_TABLE" input ip saddr @temp_ban_v4 drop
    nft add rule inet "$TEMP_BAN_TABLE" input ip6 saddr @temp_ban_v6 drop
    _log "Created temp ban table $TEMP_BAN_TABLE (timeout $DEFAULT_TEMP_TIMEOUT)"
  fi
}

is_in_set_v4() { nft get element inet "$TEMP_BAN_TABLE" temp_ban_v4 "{ $1 }" >/dev/null 2>&1; }
is_in_set_v6() { nft get element inet "$TEMP_BAN_TABLE" temp_ban_v6 "{ $1 }" >/dev/null 2>&1; }

remove_temp_ban() {
  local ip="$1"
  if [[ "$ip" == *:* ]]; then
    nft delete element inet "$TEMP_BAN_TABLE" temp_ban_v6 "{ $ip }" 2>/dev/null && \
      _log "Removed temp IPv6 ban $ip" && _log_event "remove" "$ip" "IPv6" "temp" "manual remove" "success" && return 0
  else
    nft delete element inet "$TEMP_BAN_TABLE" temp_ban_v4 "{ $ip }" 2>/dev/null && \
      _log "Removed temp IPv4 ban $ip" && _log_event "remove" "$ip" "IPv4" "temp" "manual remove" "success" && return 0
  fi
  _log_event "remove" "$ip" "$(validate_ip "$ip")" "temp" "not found" "fail" ""
  echo -e "${YELLOW}IP $ip not in temp set${NC}"
  return 1
}

# ========================
# Conflict resolution
# ========================
resolve_conflicts_for_ip() {
  local ip="$1"
  local conflict="false"
  local wl="false" bl="false" tmp="false"
  [ -f "$ALLOW_FILE" ] && grep -q "^$ip\\b" "$ALLOW_FILE" && wl="true"
  if [[ "$ip" == *:* ]]; then grep -q "^$ip\\b" "$IPV6_BLACKLIST_FILE" 2>/dev/null && bl="true"
  else grep -q "^$ip\\b" "$IPV4_BLACKLIST_FILE" 2>/dev/null && bl="true"; fi
  if [[ "$ip" == *:* ]]; then is_in_set_v6 "$ip" && tmp="true"; else is_in_set_v4 "$ip" && tmp="true"; fi

  if [ "$wl" = "true" ] && [ "$bl" = "true" ]; then
    conflict="true"
    if [ "$WHITELIST_PRECEDENCE" = "true" ]; then
      remove_ip_from_blacklist "$ip" >/dev/null
      remove_temp_ban "$ip" >/dev/null
      if command -v fail2ban-client >/dev/null 2>&1; then
        for j in $(fail2ban-client status 2>/dev/null | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' '); do
          fail2ban-client set "$j" unbanip "$ip" >/dev/null 2>&1
        done
      fi
      _log "Conflict resolved for $ip: whitelist precedence"
      _log_event "conflict_resolved" "$ip" "$(validate_ip "$ip")" "system" "whitelist precedence" "success"
    else
      remove_ip_from_whitelist "$ip" >/dev/null
      _log "Conflict resolved for $ip: blacklist precedence"
      _log_event "conflict_resolved" "$ip" "$(validate_ip "$ip")" "system" "blacklist precedence" "success"
    fi
  fi
}

# ========================
# Core actions (ban/unban)
# ========================
temp_ban_ip() {
  local ip="$1" comment="$2"
  local fam; fam=$(validate_ip "$ip") || { echo -e "${RED}Invalid IP format${NC}"; _log_event "error" "$ip" "unknown" "temp" "invalid format" "fail"; return 1; }

  # self-protect
  if is_current_login_ip "$ip"; then
    echo -e "${RED}Refusing to ban your current login IP ($ip)${NC}"; _log_event "error" "$ip" "$fam" "temp" "self-protect" "fail"; return 1
  fi

  # reachability (optional)
  if ! reachable_ip "$ip" "$fam"; then
    echo -e "${YELLOW}Warning: $ip not reachable; proceed anyway (validation enabled). Use --no-validate to skip reachability checks.${NC}"
  fi

  ensure_temp_ban_table
  if [ "$fam" = "IPv6" ]; then
    nft add element inet "$TEMP_BAN_TABLE" temp_ban_v6 "{ $ip }"
  else
    nft add element inet "$TEMP_BAN_TABLE" temp_ban_v4 "{ $ip }"
  fi
  [ -z "$comment" ] && comment="temp ban $(date '+%F %T')"
  _log "Temp-banned $fam $ip: $comment"
  _log_event "add" "$ip" "$fam" "temp" "$comment" "success"
  echo -e "${RED}Temporarily banned $fam: $ip ($DEFAULT_TEMP_TIMEOUT)${NC}\n${YELLOW}Comment:${NC} $comment"
}

perm_ban_ip() {
  local ip="$1" comment="$2" force="$3" fam; fam=$(validate_ip "$ip") || { echo -e "${RED}Invalid IP format${NC}"; _log_event "error" "$ip" "unknown" "perm" "invalid format" "fail"; return 1; }

  if is_current_login_ip "$ip"; then echo -e "${RED}Refusing to ban your current login IP ($ip)${NC}"; _log_event "error" "$ip" "$fam" "perm" "self-protect" "fail"; return 1; fi

  # conflict: in whitelist
  if check_ip_in_allow "$ip"; then
    if [ "$WHITELIST_PRECEDENCE" = "true" ] && [ "$force" != "force" ]; then
      echo -e "${RED}IP $ip is in whitelist. With whitelist precedence enabled, use --force to override or remove it from whitelist first.${NC}"
      _log_event "error" "$ip" "$fam" "perm" "blocked by whitelist precedence" "fail"
      return 1
    fi
    remove_ip_from_whitelist "$ip" >/dev/null
  fi

  [ -z "$comment" ] && comment="permanent ban $(date '+%F %T')"
  add_ip_to_blacklist "$ip" "$comment" >/dev/null
  # immediate effect
  temp_ban_ip "$ip" "$comment (perm mirror)"
  echo -e "${RED}Permanently banned $fam: $ip${NC}\n${YELLOW}Comment:${NC} $comment"
}

remove_ip_from_all() {
  local ip="$1" fam; fam=$(validate_ip "$ip") || { echo -e "${RED}Invalid IP format${NC}"; return 1; }
  echo -e "${BLUE}Removing $ip from all ban sources...${NC}"
  remove_temp_ban "$ip" >/dev/null

  remove_ip_from_blacklist "$ip" >/dev/null

  if command -v fail2ban-client >/dev/null 2>&1; then
    for j in $(fail2ban-client status 2>/dev/null | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' '); do
      fail2ban-client set "$j" unbanip "$ip" >/devnull 2>&1
    done
  fi
  _log_event "remove" "$ip" "$fam" "system" "remove from all" "success"
  echo -e "${GREEN}Done.${NC}"
}

# ========================
# Unified Views / Search / Sync
# ========================

_list_temp_set_lines() {
  local family_set="$1"
  nft list set inet "$TEMP_BAN_TABLE" "$family_set" 2>/dev/null \
    | sed -n '/elements = {/,/}/p' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E -v '^(elements = \{|})$'
}

list_bans() {
  echo -e "${BLUE}=== Unified Ban List ===${NC}"
  echo -e "Type\tFamily\tIP\tExpires\tReason"
  # Permanent - from files
  if [ -f "$IPV4_BLACKLIST_FILE" ]; then
    grep -E '^[0-9]' "$IPV4_BLACKLIST_FILE" | while read -r line; do
      ip="${line%% *}"; reason="$(get_comment_from_file_line "$line")"
      echo -e "perm\tIPv4\t$ip\t-\t${reason:-no comment}"
    done
  fi
  if [ -f "$IPV6_BLACKLIST_FILE" ]; then
    grep -E '^[0-9a-fA-F:]' "$IPV6_BLACKLIST_FILE" | while read -r line; do
      ip="${line%% *}"; reason="$(get_comment_from_file_line "$line")"
      echo -e "perm\tIPv6\t$ip\t-\t${reason:-no comment}"
    done
  fi
  # Temporary - from nft sets
  ensure_temp_ban_table
  _list_temp_set_lines "temp_ban_v4" | while read -r entry; do
    ip=$(echo "$entry" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    [ -z "$ip" ] && continue
    exp=$(echo "$entry" | grep -Eo 'expires[[:space:]][^ ]+' | awk '{print $2}')
    echo -e "temp\tIPv4\t$ip\t${exp:-unknown}\t"
  done
  _list_temp_set_lines "temp_ban_v6" | while read -r entry; do
    ip=$(echo "$entry" | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
    [ -z "$ip" ] && continue
    exp=$(echo "$entry" | grep -Eo 'expires[[:space:]][^ ]+' | awk '{print $2}')
    echo -e "temp\tIPv6\t$ip\t${exp:-unknown}\t"
  done
  # Fail2Ban - jails
  if command -v fail2ban-client >/dev/null 2>&1; then
    local jails; jails=$(fail2ban-client status 2>/dev/null | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' ' | xargs)
    for j in $jails; do
      ips=$(fail2ban-client status "$j" 2>/dev/null | sed -n 's/^.*Banned IP list:\s*//p')
      [ -n "$ips" ] && for ip in $ips; do
        fam=$(validate_ip "$ip" || echo "unknown")
        echo -e "f2b:$j\t$fam\t$ip\t-\t"
      done
    done
  fi
}

sync_bans() {
  echo -e "${BLUE}Synchronizing...${NC}"
  ensure_temp_ban_table

  # Enforce whitelist precedence (or opposite if configured)
  if [ -f "$ALLOW_FILE" ]; then
    grep -E '^[0-9a-fA-F.:]+' "$ALLOW_FILE" | awk '{print $1}' | while read -r ip; do
      resolve_conflicts_for_ip "$ip"
    done
  fi

  # Reload nftables
  if check_nftables_config; then
    nft -f "$CONF_FILE" >>"$LOG_FILE" 2>&1 && _log "Reloaded nftables from $CONF_FILE"
    systemctl reload nftables 2>/dev/null
    _log_event "sync" "" "" "ruleset" "reload from conf" "success"
  else
    _log_event "sync" "" "" "ruleset" "reload aborted (bad conf)" "fail"
  fi

  # Reload Fail2Ban (non-fatal)
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client reload >/dev/null 2>&1 && _log "Reloaded fail2ban"
    _log_event "sync" "" "" "fail2ban" "reload" "info"
  fi

  echo -e "${GREEN}Sync complete.${NC}"
}

search_ip() {
  local ip="$1"
  if [ -z "$ip" ]; then echo -e "${RED}Usage: --search-ip <IP>${NC}"; return 1; fi
  local fam; fam=$(validate_ip "$ip") || { echo -e "${RED}Invalid IP format${NC}"; return 1; }

  echo -e "${BLUE}Searching for $ip ($fam)...${NC}"
  local found="false"

  # whitelist
  if [ -f "$ALLOW_FILE" ] && grep -q "^$ip\\b" "$ALLOW_FILE"; then
    echo -e "• Whitelist: ${GREEN}YES${NC}"; found="true"
  else echo -e "• Whitelist: ${YELLOW}NO${NC}"; fi

  # blacklists
  if [[ "$fam" = "IPv6" ]]; then
    if [ -f "$IPV6_BLACKLIST_FILE" ] && grep -q "^$ip\\b" "$IPV6_BLACKLIST_FILE"; then
      line=$(grep -m1 "^$ip\\b.*" "$IPV6_BLACKLIST_FILE"); reason=$(get_comment_from_file_line "$line")
      echo -e "• Permanent blacklist: ${RED}YES${NC}  Reason: ${reason}"; found="true"
    else echo -e "• Permanent blacklist: ${YELLOW}NO${NC}"; fi
  else
    if [ -f "$IPV4_BLACKLIST_FILE" ] && grep -q "^$ip\\b" "$IPV4_BLACKLIST_FILE"; then
      line=$(grep -m1 "^$ip\\b.*" "$IPV4_BLACKLIST_FILE"); reason=$(get_comment_from_file_line "$line")
      echo -e "• Permanent blacklist: ${RED}YES${NC}  Reason: ${reason}"; found="true"
    else echo -e "• Permanent blacklist: ${YELLOW}NO${NC}"; fi
  fi

  # temp sets
  ensure_temp_ban_table
  if [ "$fam" = "IPv6" ]; then
    if is_in_set_v6 "$ip"; then
      e=$(_list_temp_set_lines "temp_ban_v6" | grep -F "$ip" | grep -Eo 'expires[[:space:]][^ ]+' | awk '{print $2}')
      echo -e "• Temporary ban set: ${RED}YES${NC}  Expires: ${e:-unknown}"; found="true"
    else echo -e "• Temporary ban set: ${YELLOW}NO${NC}"; fi
  else
    if is_in_set_v4 "$ip"; then
      e=$(_list_temp_set_lines "temp_ban_v4" | grep -F "$ip" | grep -Eo 'expires[[:space:]][^ ]+' | awk '{print $2}')
      echo -e "• Temporary ban set: ${RED}YES${NC}  Expires: ${e:-unknown}"; found="true"
    else echo -e "• Temporary ban set: ${YELLOW}NO${NC}"; fi
  fi

  # fail2ban
  if command -v fail2ban-client >/dev/null 2>&1; then
    local hit="false"
    for j in $(fail2ban-client status 2>/dev/null | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' '); do
      if fail2ban-client status "$j" 2>/dev/null | grep -qw -- "$ip"; then
        echo -e "• Fail2Ban jail ${YELLOW}$j${NC}: ${RED}BANNED${NC}"; hit="true"; found="true"
      fi
    done
    [ "$hit" = "false" ] && echo -e "• Fail2Ban: ${YELLOW}Not banned in any jail${NC}"
  else
    echo -e "• Fail2Ban: ${YELLOW}Not installed${NC}"
  fi

  # conflict note
  if [ -f "$ALLOW_FILE" ] && grep -q "^$ip\\b" "$ALLOW_FILE"; then
    if [[ "$fam" = "IPv6" ]]; then blf="$IPV6_BLACKLIST_FILE"; else blf="$IPV4_BLACKLIST_FILE"; fi
    if [ -f "$blf" ] && grep -q "^$ip\\b" "$blf"; then
      echo -e "${YELLOW}Conflict:${NC} IP is in both whitelist and blacklist. Policy: whitelist precedence=${WHITELIST_PRECEDENCE}"
    fi
  fi

  [ "$found" = "false" ] && echo -e "${GREEN}No matches found.${NC}"
}

# ========================
# Fail2Ban helpers (unchanged-ish)
# ========================

view_fail2ban_jails() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${BLUE}Available Fail2Ban jails:${NC}"
    fail2ban-client status | sed -n 's/^.*Jail list:\s*//p' | tr ',' '\n' | sed 's/^ *//;s/ *$//'
    if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
      echo -e "${BLUE}nftables-specific jails (jail.d):${NC}"
      find "$FAIL2BAN_JAIL_DIR" -name "nftables-*.conf" -exec basename {} .conf \; | sed 's/^nftables-//'
    fi
  else
    echo -e "${RED}Fail2Ban not installed${NC}"
  fi
}

view_fail2ban_rules() {
  local jail="$1"
  [ -z "$jail" ] && { echo -e "${RED}Specify a jail${NC}"; return 1; }
  if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -f "$FAIL2BAN_JAIL_DIR/nftables-$jail.conf" ]; then
      echo -e "${BLUE}Rules for nftables jail '$jail':${NC}"
      cat "$FAIL2BAN_JAIL_DIR/nftables-$jail.conf"
    else
      echo -e "${BLUE}Rules for jail '$jail':${NC}"
      fail2ban-client get "$jail" action | grep -E "(actionstart|actionstop|actioncheck|actionban|actionunban)"
    fi
  fi
}

view_fail2ban_banned() {
  local jail="$1"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -z "$jail" ]; then
      echo -e "${BLUE}Banned IPs (all jails):${NC}"
      for j in $(fail2ban-client status | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' '); do
        ips=$(fail2ban-client status "$j" | sed -n 's/^.*Banned IP list:\s*//p')
        [ -n "$ips" ] && echo -e "${YELLOW}$j:${NC} $ips"
      done
    else
      echo -e "${BLUE}Banned IPs in '$jail':${NC}"
      fail2ban-client status "$jail" | sed -n 's/^.*Banned IP list:\s*//p'
    fi
  else
    echo -e "${RED}Fail2Ban not installed${NC}"
  fi
}

view_all_banned() {
  echo -e "${BLUE}=== NFTables elements (any sets) ===${NC}"
  nft list ruleset | grep -E "elements = {.*}" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | sort -u
  echo -e "${BLUE}=== Fail2Ban (all jails) ===${NC}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    for j in $(fail2ban-client status | sed -n 's/^.*Jail list:\s*//p' | tr ',' ' '); do
      ips=$(fail2ban-client status "$j" | sed -n 's/^.*Banned IP list:\s*//p')
      [ -n "$ips" ] && echo "$ips" | tr ' ' '\n'
    done | sort -u
  else
    echo "Fail2Ban not installed"
  fi
}

# ========================
# Service management w/ IP safety
# ========================
manage_ip() {
  local cip; cip=$(get_current_login_ip)
  [ "$cip" = "unknown" ] && { echo -e "${YELLOW}Warning: cannot detect login IP${NC}"; return 0; }
  echo -e "${BLUE}Current login IP: $cip${NC}"
  if check_ip_in_allow "$cip"; then echo -e "${GREEN}Your IP is already whitelisted${NC}"
  else add_ip_to_allow "$cip" >/dev/null && echo -e "${GREEN}Added your IP to whitelist${NC}"; fi
  remove_ip_from_blacklist "$cip" >/dev/null
}

update_nftables_config() {
  _log "Applying nftables config..."; manage_ip; check_config && { systemctl restart nftables; systemctl restart fail2ban; } || { echo -e "${RED}Config check failed${NC}"; return 1; }
}

# ========================
# CLI
# ========================
show_help() {
  cat <<EOF
NFTBan - unified nftables/Fail2Ban manager

Usage: nftban [OPTIONS]

Core:
  -e, --enable                  Enable & start nftables + Fail2Ban (after config check)
  -d, --disable                 Disable & stop both services
  -s, --start                   Start both services (after config check)
  -r, --restart                 Restart both services (after config check)
  -x, --stop                    Stop both services
  -l, --list                    List current nftables rules
  -c, --check                   Check nftables & Fail2Ban configuration
  -a, --add-ip [IP]             Add your IP (or given) to whitelist
  -i, --info                    Show current login IP & whitelist status

Bans:
  -tb, --temp-ban IP [COMMENT]  Temp-ban IP ($DEFAULT_TEMP_TIMEOUT) with optional comment
  -pb, --perm-ban IP [COMMENT]  Permanently ban IP with optional comment
      --force                   (use with --perm-ban) override whitelist precedence
  -rb, --remove-ban IP          Remove IP from temp set and Fail2Ban
  -ri, --remove-ip IP           Remove IP from all (temp/perm/f2b)
  -lt, --list-temp              List temp-banned IPs

Unified views & ops:
  -lb, --list-bans              Unified list of bans (perm/temp/fail2ban)
  -sy, --sync-bans              Reload blacklist files into nftables, enforce whitelist, reload services
  -si, --search-ip IP           Search IP across whitelist/blacklists/nftables/Fail2Ban

Fail2Ban:
  -fj, --fail2ban-jails         Show Fail2Ban jails
  -fr, --fail2ban-rules JAIL    Show rules for a jail
  -fb, --fail2ban-banned [JAIL] Show banned IPs (optionally by jail)

Validation / Logging:
      --no-validate             Disable reachability checks before banning
      --enable-logging          Enable stdout+file logging
      --disable-logging         Disable stdout+file logging
      --history                 Show path to unified CSV history log

EOF
}

main() {
  [ "$EUID" -ne 0 ] && { echo -e "${RED}Run as root${NC}"; exit 1; }
  command -v nft >/dev/null 2>&1 || { echo -e "${RED}nftables not installed${NC}"; exit 1; }
  _init_history

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-validate) VALIDATE_REACHABILITY="false"; shift;;
      --enable-logging) ENABLE_LOGGING="true"; echo -e "${GREEN}Logging enabled${NC}"; shift;;
      --disable-logging) ENABLE_LOGGING="false"; echo -e "${YELLOW}Logging disabled${NC}"; shift;;
      --history) echo "$HISTORY_FILE"; shift;;

      -e|--enable) echo -e "${BLUE}Enable & start services...${NC}"; if check_config; then backup_config; manage_ip; enable_nftables_service; enable_fail2ban_service; start_nftables_service; start_fail2ban_service; else echo -e "${RED}Config errors; aborting${NC}"; exit 1; fi; shift;;
      -d|--disable) echo -e "${BLUE}Disable & stop services...${NC}"; stop_nftables_service; stop_fail2ban_service; disable_nftables_service; disable_fail2ban_service; shift;;
      -s|--start)   echo -e "${BLUE}Start services...${NC}"; if check_config; then manage_ip; start_nftables_service; start_fail2ban_service; else echo -e "${RED}Config errors; aborting${NC}"; exit 1; fi; shift;;
      -r|--restart) echo -e "${BLUE}Restart services...${NC}"; if check_config; then manage_ip; systemctl restart nftables; systemctl restart fail2ban; else echo -e "${RED}Config errors; aborting${NC}"; exit 1; fi; shift;;
      -x|--stop)    echo -e "${BLUE}Stop services...${NC}"; stop_nftables_service; stop_fail2ban_service; shift;;
      -l|--list)    list_rules; shift;;
      -c|--check)   check_config; shift;;
      -a|--add-ip)  if [ -n "$2" ] && [[ "$2" != -* ]]; then ip="$2"; shift; else ip=$(get_current_login_ip); fi; [ "$ip" = "unknown" ] && { echo -e "${RED}Cannot determine IP${NC}"; exit 1; }; add_ip_to_allow "$ip" >/dev/null && echo -e "${GREEN}Whitelisted $ip${NC}" || echo -e "${YELLOW}$ip already whitelisted${NC}"; update_nftables_config; shift;;
      -i|--info)    cip=$(get_current_login_ip); echo -e "${BLUE}Your IP:${NC} $cip"; if check_ip_in_allow "$cip"; then echo -e "Whitelist: ${GREEN}present${NC}"; else echo -e "Whitelist: ${YELLOW}absent${NC}"; fi; shift;;

      -tb|--temp-ban) [ -z "$2" ] && { echo -e "${RED}Provide IP${NC}"; exit 1; }; ip="$2"; shift; comment=""; if [ -n "$2" ] && [[ "$2" != -* ]]; then comment="$2"; shift; fi; temp_ban_ip "$ip" "$comment";;
      -pb|--perm-ban) [ -z "$2" ] && { echo -e "${RED}Provide IP${NC}"; exit 1; }; ip="$2"; shift; comment=""; force=""; if [ -n "$2" ] && [[ "$2" != -* ]]; then comment="$2"; shift; fi; [ "$1" = "--force" ] && { force="force"; shift; }; perm_ban_ip "$ip" "$comment" "$force";;
      -rb|--remove-ban) [ -z "$2" ] && { echo -e "${RED}Provide IP${NC}"; exit 1; }; remove_temp_ban "$2"; shift; shift;;
      -ri|--remove-ip)  [ -z "$2" ] && { echo -e "${RED}Provide IP${NC}"; exit 1; }; remove_ip_from_all "$2"; shift; shift;;
      -lt|--list-temp)  list_temp_bans() { echo -e "${BLUE}Temp IPv4:${NC}"; nft list set inet "$TEMP_BAN_TABLE" temp_ban_v4 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "None"; echo -e "${BLUE}Temp IPv6:${NC}"; nft list set inet "$TEMP_BAN_TABLE" temp_ban_v6 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' || echo "None"; }; list_temp_bans; shift;;

      -lb|--list-bans) list_bans; shift;;
      -sy|--sync-bans) sync_bans; shift;;
      -si|--search-ip) [ -z "$2" ] && { echo -e "${RED}Provide IP${NC}"; exit 1; }; search_ip "$2"; shift; shift;;

      -fj|--fail2ban-jails)   view_fail2ban_jails; shift;;
      -fr|--fail2ban-rules)   view_fail2ban_rules "$2"; shift; shift;;
      -fb|--fail2ban-banned)  view_fail2ban_banned "$2"; shift; shift;;

      -h|--help) show_help; exit 0;;
      *) echo -e "${RED}Unknown option: $1${NC}"; show_help; exit 1;;
    esac
  done
}

# default when no args
if [ $# -eq 0 ]; then show_help; exit 0; fi
main "$@"

