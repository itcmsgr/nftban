#!/bin/bash

###############################################################################
# Script: nftban.sh
# A comprehensive nftables and fail2ban management tool with IP allowlist
# Version: 0.5.0-final (Enhanced with auto-update, stats, and advanced features)
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   Advanced nftables & Fail2Ban management with auto-update, comprehensive
#   statistics, IP management, and validation features.
#   Compatible with the single-table layout: table inet nftban_global
#
# NEW in v0.5.0-final:
#   • Complete auto-update mechanism with cron scheduling
#   • Enhanced statistics and reporting with JSON output
#   • Dry-run mode for safe testing
#   • Quiet mode for scripting
#   • Package health monitoring
#   • Control panel detection status
#   • Advanced filtering and search capabilities
#   • Comprehensive validation and sync checking
#   • Better error handling and logging
#   • Unicode icons and colored output
#   • Complete input validation and security hardening
###############################################################################

# ------------------------------ Configuration ------------------------------ #

# --- GEO (country) configuration ---------------------------------------------
GEO_PROVIDER="${GEO_PROVIDER:-ipdeny}"            # only 'ipdeny' supported out-of-the-box
GEO_USE_AGGREGATED="${GEO_USE_AGGREGATED:-true}"  # use aggregated lists for fewer entries
GEO_TTL_HOURS="${GEO_TTL_HOURS:-24}"              # cache lifetime
GEO_CACHE_DIR="${GEO_CACHE_DIR:-$BASE_DIR/geo-cache}"

# ISO code lists (one code per line, e.g. RU, UA). Comments with #
COUNTRY_WHITELIST_FILE="${COUNTRY_WHITELIST_FILE:-$BASE_DIR/nftban-country-whitelist.conf}"
COUNTRY_BLACKLIST_FILE="${COUNTRY_BLACKLIST_FILE:-$BASE_DIR/nftban-country-blacklist.conf}"

VERSION="0.5.0-final"
VERSION_FILE="/etc/nftban/.version"
BASE_DIR="/etc/nftban/config"
SCRIPTS_DIR="/etc/nftban/scripts"
CONF_FILE="/etc/nftables.conf"
USER_WHITELIST_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf.local"
BACKUP_DIR="/etc/nftables/backups"
LOG_FILE="/var/log/nftban/nftban.log"
LOG_DIR="/var/log/nftban"

# Auto-update configuration
AUTO_UPDATE_SCRIPT="$SCRIPTS_DIR/nftban_auto_update.sh"
AUTO_UPDATE_ENABLED="false"
DO_REMOVE_AUTO_UPDATE="false"
DO_AUTO_UPDATE_STATUS="false"
DAILY_TIME=""

# NFTables configuration
TEMP_BAN_TABLE="nftban_global"
TEMP_BAN_SET_V4="temp_ban_v4"
TEMP_BAN_SET_V6="temp_ban_v6"
WHITELIST_SET_V4="whitelist_v4"
WHITELIST_SET_V6="whitelist_v6"
USER_BLACKLIST_SET_V4="user_blacklist_v4"
USER_BLACKLIST_SET_V6="user_blacklist_v6"
SYSTEM_BLACKLIST_SET_V4="system_blacklist_v4"
SYSTEM_BLACKLIST_SET_V6="system_blacklist_v6"

# Fail2Ban configuration
FAIL2BAN_DIR="/etc/fail2ban"
FAIL2BAN_JAIL_DIR="$FAIL2BAN_DIR/jail.d"

# Blacklist files
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
USER_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-user-blacklist_ips.conf.local"

# Operation modes
DRY_RUN="false"
QUIET="false"
JSON_MODE="false"
NO_COLOR="false"
UNICODE_ICONS="true"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"
REQUIRE_F2B="${REQUIRE_F2B:-false}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'
NC='\033[0m'

# Temporary files array for cleanup
TMP_FILES=()

# ------------------------------ UI & Utility Functions --------------------- #
setup_colors() {
  if [[ "$NO_COLOR" == "true" || ! -t 2 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; BOLD=""; RESET=""; NC="";
  fi
  if [[ "$UNICODE_ICONS" == "true" ]]; then
    ICON_INFO="ℹ️"; ICON_OK="✅"; ICON_WARN="⚠️"; ICON_ERR="❌"; ICON_STEP="👉"; ICON_TIP="💡";
    ICON_FIRE="🔥"; ICON_LOCK="🔒"; ICON_UNLOCK="🔓"; ICON_CHART="📊"; ICON_CLOCK="⏰";
  else
    ICON_INFO="[i]"; ICON_OK="[ok]"; ICON_WARN="[!]"; ICON_ERR="[x]"; ICON_STEP="->"; ICON_TIP="(*)";
    ICON_FIRE="[*]"; ICON_LOCK="[L]"; ICON_UNLOCK="[U]"; ICON_CHART="[#]"; ICON_CLOCK="[@]";
  fi
}

ui() {
  [[ "$QUIET" == "true" ]] && return
  local kind="${1:-info}"; shift || true; local msg="$*"
  case "$kind" in
    title)   echo -e "${BOLD}${BLUE}${msg}${RESET}";;
    info)    echo -e "${BLUE}${ICON_INFO} ${msg}${RESET}";;
    success) echo -e "${GREEN}${ICON_OK} ${msg}${RESET}";;
    warn)    echo -e "${YELLOW}${ICON_WARN} ${msg}${RESET}";;
    error)   echo -e "${RED}${ICON_ERR} ${msg}${RESET}";;
    step)    echo -e "${BOLD}${ICON_STEP} ${msg}${RESET}";;
    tip)     echo -e "${ICON_TIP} ${msg}";;
    fire)    echo -e "${RED}${ICON_FIRE} ${msg}${RESET}";;
    lock)    echo -e "${GREEN}${ICON_LOCK} ${msg}${RESET}";;
    unlock)  echo -e "${YELLOW}${ICON_UNLOCK} ${msg}${RESET}";;
    chart)   echo -e "${CYAN}${ICON_CHART} ${msg}${RESET}";;
    clock)   echo -e "${MAGENTA}${ICON_CLOCK} ${msg}${RESET}";;
    *)       echo "$msg";;
  esac
}

log() {
  local level="${1:-INFO}"
  shift
  local message="$*"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  mkdir -p "$LOG_DIR"
  
  if [[ "${ENABLE_LOGGING:-true}" == "true" ]]; then
    echo "[$timestamp] $level: $message" >> "$LOG_FILE"
  fi
  
  if [[ "$level" == "ERROR" || ("$QUIET" != "true" && "$level" == "INFO") ]]; then
    echo "[$timestamp] $level: $message" >&2
  fi
}

die() { log "ERROR" "$*"; exit 1; }

cleanup() {
  for tmpfile in "${TMP_FILES[@]}"; do
    rm -f "$tmpfile" 2>/dev/null
  done
}

trap cleanup EXIT INT TERM

run_cmd() {
  local cmd="$*"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log INFO "DRY-RUN: $cmd"
    return 0
  fi
  
  # Add timeout and better error handling
  if timeout 30s bash -c "$cmd" 2>&1; then
    return 0
  else
    local exit_code=$?
    log ERROR "Command failed (exit $exit_code): $cmd"
    return $exit_code
  fi
}

# ------------------------------ Version Management ------------------------- #
check_version() {
  mkdir -p "$(dirname "$VERSION_FILE")"
  if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
    if [ "$CURRENT_VERSION" != "$VERSION" ]; then
      log INFO "Version updated: $VERSION (was $CURRENT_VERSION)"
      echo "$VERSION" > "$VERSION_FILE"
    fi
  else
    echo "$VERSION" > "$VERSION_FILE"
  fi
}

show_version() {
  echo "nftban version $VERSION"
  echo "Configuration directory: $BASE_DIR"
  if [ -f "$VERSION_FILE" ]; then
    local installed_version
    installed_version=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
    echo "Installed version: $installed_version"
  fi
  
  # Show component versions
  if command -v nft >/dev/null 2>&1; then
    echo "nftables: $(nft --version 2>/dev/null | head -1)"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "fail2ban: $(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')"
  fi
}

# ------------------------------ IP Validation ------------------------------ #
# ============================================================================
# Enhanced IP/CIDR validation & normalization using sipcalc/ipcalc
# ============================================================================

have() { command -v "$1" >/dev/null 2>&1; }

# Quick pre-filters (do not rely on these for final validation)
_is_ipv4_quick() { [[ "$1" == *.* && "$1" != *:* ]]; }    # presence of dots, no colons
_is_ipv6_quick() { [[ "$1" == *:* ]]; }                   # presence of colon(s)

# Add default mask if omitted: v4 -> /32, v6 -> /128
normalize_cidr() {
  local x="$1"
  if [[ "$x" == */* ]]; then printf '%s\n' "$x"; return; fi
  if _is_ipv4_quick "$x"; then printf '%s/32\n' "$x"; else printf '%s/128\n' "$x"; fi
}

# Tool-backed validation (0 = valid, 1 = invalid)
validate_cidr() {
  local input; input="$(normalize_cidr "$1")"

  # Prefer sipcalc for both families
  if have sipcalc; then
    sipcalc "$input" >/dev/null 2>&1 || return 1
  else
    # Minimal fallback: accept IPv4 only with ipcalc; reject IPv6 without sipcalc
    if _is_ipv4_quick "$input" && have ipcalc; then
      ipcalc -c "${input%/*}" >/dev/null 2>&1 || return 1
    else
      return 1
    fi
  fi

  # Extra IPv4 lint with ipcalc if present
  if _is_ipv4_quick "$input" && have ipcalc; then
    ipcalc -c "${input%/*}" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Canonicalize to compressed address with correct prefix
canonical_cidr() {
  local input; input="$(normalize_cidr "$1")"
  if ! have sipcalc; then printf '%s\n' "$input"; return; fi

  if _is_ipv4_quick "$input"; then
    sipcalc "$input" 2>/dev/null | awk '
      /Compressed address/ {addr=$3}
      /Network mask \(bits\)/ {bits=$5}
      END { if(addr && bits) print addr"/"bits; else exit 1 }'
  else
    sipcalc "$input" 2>/dev/null | awk '
      /Compressed address/ {addr=$3}
      /Prefix length/ {bits=$3}
      END { if(addr && bits) print addr"/"bits; else exit 1 }'
  fi
}

# Human-friendly explanation (optional hook for --check / --info)
explain_cidr() {
  local input; input="$(normalize_cidr "$1")"
  if ! validate_cidr "$input"; then
    echo "INVALID: $1"; return 1
  fi
  echo "OK: $(canonical_cidr "$input")"
  if _is_ipv4_quick "$input"; then
    if have ipcalc; then ipcalc "$input"; else sipcalc "$input"; fi
  else
    sipcalc "$input"
  fi
}

# Batch validator for lists/files -> prints canonical entries; errors to stderr
validate_list_with_tools() {
  local line num=0 bad=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((num++))
    line="${line%%#*}"; line="${line//[$'\t\r ']/}"
    [[ -z "$line" ]] && continue
    if validate_cidr "$line"; then
      canonical_cidr "$line"
    else
      echo "Line $num invalid: $line" >&2
      ((bad++))
    fi
  done
  return $(( bad > 0 ))
}

# --- Overrides: replace regex-based validators with tool-backed checks --------
# Return 0 if IPv4 or IPv4/CIDR is valid
is_ipv4_or_cidr() {
  local x="$1"
  if [[ -z "$x" ]]; then return 1; fi
  # Reject obvious IPv6
  [[ "$x" == *:* ]] && return 1
  validate_cidr "$x"
}

# Return 0 if IPv6 or IPv6/CIDR is valid
is_ipv6_or_cidr() {
  local x="$1"
  if [[ -z "$x" ]]; then return 1; fi
  # Require IPv6-like input
  [[ "$x" != *:* ]] && return 1
  validate_cidr "$x"
}
# ============================================================================


is_ipv4_or_cidr() {
    local ip="$1"
    
    # More robust regex matching
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 1
    fi
    
    local ip_part="${ip%/*}"
    local cidr_part="${ip#*/}"
    
    if [[ "$ip" == *"/"* ]]; then
        [[ "$cidr_part" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
    fi
    
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
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:./]+$ ]] || return 1
    
    if [[ "$ip" == *"/"* ]]; then
        local cidr="${ip#*/}"
        [[ "$cidr" =~ ^([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$ ]] || return 1
    fi
    return 0
}

is_ip_like() { is_ipv4_or_cidr "$1" || is_ipv6_or_cidr "$1"; }

# ------------------------------ Service Status ----------------------------- #
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

# ------------------------------ Set Operations ----------------------------- #

# -----------------------------------------------------------------------------
# GEO country → CIDR fetch & sync (IPv4/IPv6), with caching
# Sources:
#   - IPv4: https://www.ipdeny.com/ipblocks/ (e.g., ru.zone)
#   - IPv6: https://www.ipdeny.com/ipv6/ipaddresses/aggregated/ (e.g., ru-aggregated.zone)
# -----------------------------------------------------------------------------

_geo_now_epoch() { date +%s; }
_geo_file_age_hours() {  # $1 = file
  [ -f "$1" ] || { echo 1e9; return; }
  local now=$(_geo_now_epoch); local mod=$(stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s)
  echo $(( (now - mod) / 3600 ))
}

_geo_norm_iso() { echo "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z]//g' | cut -c1-2; }

_geo_ipdeny_url_v4() {  # $1=ISO
  local cc="$(echo "$1" | tr A-Z a-z)"
  echo "https://www.ipdeny.com/ipblocks/data/countries/${cc}.zone"
}
_geo_ipdeny_url_v6() {  # $1=ISO
  local cc="$(echo "$1" | tr A-Z a-z)"
  if [ "${GEO_USE_AGGREGATED}" = "true" ]; then
    echo "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${cc}-aggregated.zone"
  else
    # Non-aggregated directory exists too, but aggregated is recommended
    echo "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/${cc}-aggregated.zone"
  fi
}

_geo_fetch_country() {  # $1=ISO, $2=family (v4|v6), print path to cached file
  local cc="$(_geo_norm_iso "$1")"
  local fam="$2"
  mkdir -p "$GEO_CACHE_DIR/$fam"
  local target="$GEO_CACHE_DIR/$fam/${cc}.zone"
  local age=$(_geo_file_age_hours "$target")
  if [ "$age" -ge "$GEO_TTL_HOURS" ]; then
    local url
    case "$GEO_PROVIDER" in
      ipdeny)
        if [ "$fam" = "v4" ]; then url="$(_geo_ipdeny_url_v4 "$cc")"; else url="$(_geo_ipdeny_url_v6 "$cc")"; fi
        ;;
      *)
        ui error "Unsupported GEO provider: $GEO_PROVIDER"
        return 1
        ;;
    esac
    ui info "Fetching $fam CIDRs for $cc from $url"
    if ! curl -fsSL "$url" -o "$target.tmp"; then
      ui error "Failed to download $url"
      rm -f "$target.tmp"
      return 1
    fi
    # sanitize: keep only CIDR-looking lines
    grep -E '^[0-9a-fA-F:.]+/[0-9]+' "$target.tmp" | sed 's/\r$//' | sort -u > "$target"
    rm -f "$target.tmp"
  fi
  echo "$target"
}

_geo_read_iso_file() {  # $1=file -> prints ISO codes (two letters) one per line
  [ -f "$1" ] || return 0
  sed -E 's/#.*$//' "$1" | tr -d ' \t\r' | awk 'length($0)>0' | \
    awk '{print toupper(substr($0,1,2))}' | sed -E 's/[^A-Z]//g'
}

# Add/remove a whole country's cidrs to a set pair (v4/v6)
_geo_apply_country_to_sets() {  # $1=ISO $2=set_v4 $3=set_v6 $4=action(add|del)
  local cc="$(_geo_norm_iso "$1")"; local set4="$2"; local set6="$3"; local action="$4"
  local f4 f6 ip
  f4="$(_geo_fetch_country "$cc" v4)" || return 1
  f6="$(_geo_fetch_country "$cc" v6)" || true
  if [ "$action" = "add" ]; then
    while IFS= read -r ip; do [ -n "$ip" ] || continue; nft add element inet "$TEMP_BAN_TABLE" "$set4" "{ $ip }" >/dev/null 2>&1 || true; done < "$f4"
    if [ -f "$f6" ]; then while IFS= read -r ip; do [ -n "$ip" ] || continue; nft add element inet "$TEMP_BAN_TABLE" "$set6" "{ $ip }" >/dev/null 2>&1 || true; done < "$f6"; fi
  else
    while IFS= read -r ip; do [ -n "$ip" ] || continue; nft delete element inet "$TEMP_BAN_TABLE" "$set4" "{ $ip }" >/dev/null 2>&1 || true; done < "$f4"
    if [ -f "$f6" ]; then while IFS= read -r ip; do [ -n "$ip" ] || continue; nft delete element inet "$TEMP_BAN_TABLE" "$set6" "{ $ip }" >/dev/null 2>&1 || true; done < "$f6"; fi
  fi
}

# Public entry: sync countries from files into sets
geo_sync_countries() {
  ui title "GEO sync: applying country lists to nft sets"
  ensure_temp_ban_table || return 1
  ensure_whitelist_sets || true
  ensure_blacklist_sets || true

  # Whitelist countries -> whitelist sets
  if [ -f "$COUNTRY_WHITELIST_FILE" ]; then
    ui step "Applying whitelist countries from $COUNTRY_WHITELIST_FILE"
    while read -r cc; do
      [ -n "$cc" ] || continue
      ui info "Whitelist country $cc"
      _geo_apply_country_to_sets "$cc" "$WHITELIST_SET_V4" "$WHITELIST_SET_V6" add
    done < <(_geo_read_iso_file "$COUNTRY_WHITELIST_FILE")
  fi

  # Blacklist countries -> system blacklist sets (kept separate from user list)
  if [ -f "$COUNTRY_BLACKLIST_FILE" ]; then
    ui step "Applying blacklist countries from $COUNTRY_BLACKLIST_FILE"
    while read -r cc; do
      [ -n "$cc" ] || continue
      ui info "Blacklist country $cc"
      _geo_apply_country_to_sets "$cc" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6" add
    done < <(_geo_read_iso_file "$COUNTRY_BLACKLIST_FILE")
  fi
  ui success "GEO sync complete"
}



# -----------------------------------------------------------------------------
# Reverse sync: nft → files (make files match nft)
#   - Backs up files, then updates content based on live sets
#   - Honors DRY_RUN to only print planned changes
# -----------------------------------------------------------------------------
_sync_set_to_files_from_nft() {
  # $1 = label ; $2=set_v4 ; $3=set_v6 ; $4.. = files to update (two: v4 file, v6 file)
  local label="$1"; local set_v4="$2"; local set_v6="$3"; shift 3
  local out_v4="$1"; local out_v6="$2"

  _diff_family_files_vs_set "$label" "$set_v4" "$set_v6" "$out_v4" "$out_v6"
  _print_diff_summary "$label"

  if [ "$DRY_RUN" == "true" ]; then
    echo "  [dry-run] Skipping file writes for $label"
    return 0
  fi

  # Build canonical from nft
  local t4; t4=$(mktemp); TMP_FILES+=("$t4")
  local t6; t6=$(mktemp); TMP_FILES+=("$t6")
  get_set_elements "$TEMP_BAN_TABLE" "$set_v4" > "$t4" 2>/dev/null || true
  get_set_elements "$TEMP_BAN_TABLE" "$set_v6" > "$t6" 2>/dev/null || true
  sort -u "$t4" -o "$t4"; sort -u "$t6" -o "$t6"

  # Backup and write
  mkdir -p "$BASE_DIR" || true
  [ -n "$out_v4" ] && [ "$out_v4" != "-" ] && { cp -a "$out_v4" "$out_v4.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true; }
  [ -n "$out_v6" ] && [ "$out_v6" != "-" ] && { cp -a "$out_v6" "$out_v6.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true; }

  if [ -n "$out_v4" ] && [ "$out_v4" != "-" ]; then
    {
      echo "# $out_v4 - synced from nft ($label v4) on $(date -Iseconds)"
      cat "$t4"
    } > "$out_v4"
  fi
  if [ -n "$out_v6" ] && [ "$out_v6" != "-" ]; then
    {
      echo "# $out_v6 - synced from nft ($label v6) on $(date -Iseconds)"
      cat "$t6"
    } > "$out_v6"
  fi
  echo "  Wrote $label to files."
}

sync_nft_to_files() {
  ui title "Syncing nft sets → files"
  ensure_temp_ban_table || return 1
  ensure_whitelist_sets || true
  ensure_blacklist_sets || true

  # Whitelist: replicate set into both user/system files (keeps them aligned)
  _sync_set_to_files_from_nft "Whitelist" "$WHITELIST_SET_V4" "$WHITELIST_SET_V6" \
    "$USER_WHITELIST_FILE" "$SYSTEM_WHITELIST_FILE"

  # User Blacklist
  _sync_set_to_files_from_nft "User Blacklist" "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6" \
    "$USER_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"

  # System Blacklist
  _sync_set_to_files_from_nft "System Blacklist" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6" \
    "$SYSTEM_BLACKLIST_FILE" "$IPV6_SYSTEM_BLACKLIST_FILE"

  ui success "Sync complete"
}

# Diff-only views
diff_lists() {
  ui title "Diff: files ↔ nft (what would change)"
  ensure_temp_ban_table || return 1

  _diff_family_files_vs_set "Whitelist" "$WHITELIST_SET_V4" "$WHITELIST_SET_V6" \
    "$USER_WHITELIST_FILE" "$SYSTEM_WHITELIST_FILE"; _print_diff_summary "Whitelist"

  _diff_family_files_vs_set "User Blacklist" "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6" \
    "$USER_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"; _print_diff_summary "User Blacklist"

  _diff_family_files_vs_set "System Blacklist" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6" \
    "$SYSTEM_BLACKLIST_FILE" "$IPV6_SYSTEM_BLACKLIST_FILE"; _print_diff_summary "System Blacklist"
}

diff_files_add() {
  ui title "Diff: entries present in nft but missing in files (ADD list)"
  ensure_temp_ban_table || return 1

  _diff_family_files_vs_set "Whitelist" "$WHITELIST_SET_V4" "$WHITELIST_SET_V6" \
    "$USER_WHITELIST_FILE" "$SYSTEM_WHITELIST_FILE"
  echo "  Whitelist to ADD (v4):"; cat "$ADD_V4" | sed 's/^/    /' || true
  echo "  Whitelist to ADD (v6):"; cat "$ADD_V6" | sed 's/^/    /' || true

  _diff_family_files_vs_set "User Blacklist" "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6" \
    "$USER_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
  echo "  User Blacklist to ADD (v4):"; cat "$ADD_V4" | sed 's/^/    /' || true
  echo "  User Blacklist to ADD (v6):"; cat "$ADD_V6" | sed 's/^/    /' || true

  _diff_family_files_vs_set "System Blacklist" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6" \
    "$SYSTEM_BLACKLIST_FILE" "$IPV6_SYSTEM_BLACKLIST_FILE"
  echo "  System Blacklist to ADD (v4):"; cat "$ADD_V4" | sed 's/^/    /' || true
  echo "  System Blacklist to ADD (v6):"; cat "$ADD_V6" | sed 's/^/    /' || true
}



# -----------------------------------------------------------------------------
# Diff helpers: compare files ↔ nft sets
#   - _diff_family_files_vs_set prints four files: add_v4, del_v4, add_v6, del_v6
# -----------------------------------------------------------------------------
_diff_family_files_vs_set() {
  # $1 = label ; $2 = set_v4 ; $3 = set_v6 ; $4.. = files (may not exist)
  local label="$1"; local set_v4="$2"; local set_v6="$3"; shift 3

  local file_f4; file_f4=$(mktemp); TMP_FILES+=("$file_f4")
  local file_f6; file_f6=$(mktemp); TMP_FILES+=("$file_f6")

  # Build canonical file lists
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -vE '^\s*#' "$f" | awk '{print $1}' | grep -v ":" | validate_list_with_tools >> "$file_f4" 2>/dev/null || true
    grep -vE '^\s*#' "$f" | awk '{print $1}' | grep ":"  | validate_list_with_tools >> "$file_f6" 2>/dev/null || true
  done
  sort -u "$file_f4" -o "$file_f4"; sort -u "$file_f6" -o "$file_f6"

  # Active nft lists
  local act_f4; act_f4=$(mktemp); TMP_FILES+=("$act_f4")
  local act_f6; act_f6=$(mktemp); TMP_FILES+=("$act_f6")
  get_set_elements "$TEMP_BAN_TABLE" "$set_v4" > "$act_f4" 2>/dev/null || true
  get_set_elements "$TEMP_BAN_TABLE" "$set_v6" > "$act_f6" 2>/dev/null || true
  sort -u "$act_f4" -o "$act_f4"; sort -u "$act_f6" -o "$act_f6"

  # Compute deltas: what to ADD to files (nft minus files) and what to REMOVE from files (files minus nft)
  ADD_V4=$(mktemp); TMP_FILES+=("$ADD_V4")
  ADD_V6=$(mktemp); TMP_FILES+=("$ADD_V6")
  DEL_V4=$(mktemp); TMP_FILES+=("$DEL_V4")
  DEL_V6=$(mktemp); TMP_FILES+=("$DEL_V6")

  comm -23 "$act_f4" "$file_f4" > "$ADD_V4"
  comm -13 "$act_f4" "$file_f4" > "$DEL_V4"
  comm -23 "$act_f6" "$file_f6" > "$ADD_V6"
  comm -13 "$act_f6" "$file_f6" > "$DEL_V6"

  # Export vars for the caller
  export ADD_V4 ADD_V6 DEL_V4 DEL_V6
}

# Pretty-printer for diffs
_print_diff_summary() {
  local label="$1"
  local a4=$(wc -l < "$ADD_V4"); local d4=$(wc -l < "$DEL_V4")
  local a6=$(wc -l < "$ADD_V6"); local d6=$(wc -l < "$DEL_V6")
  echo "  $label: +$a4 v4 / +$a6 v6 to ADD into files; -$d4 v4 / -$d6 v6 to REMOVE from files"
}


# -----------------------------------------------------------------------------
# Export nft sets → files (canonical, sorted). Existing files are backed up.
# -----------------------------------------------------------------------------
_backup_file_if_exists() {
  local f="$1"
  [ -f "$f" ] || return 0
  cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)" || true
}

_export_set_to_file() {
  # $1=set_v4  $2=set_v6  $3=output_v4  $4=output_v6  $5=label
  local set_v4="$1"; local set_v6="$2"; local out_v4="$3"; local out_v6="$4"; local label="$5"
  local t4; t4=$(mktemp); TMP_FILES+=("$t4")
  local t6; t6=$(mktemp); TMP_FILES+=("$t6")

  get_set_elements "$TEMP_BAN_TABLE" "$set_v4" > "$t4" 2>/dev/null || true
  get_set_elements "$TEMP_BAN_TABLE" "$set_v6" > "$t6" 2>/dev/null || true
  sort -u "$t4" -o "$t4"; sort -u "$t6" -o "$t6"

  _backup_file_if_exists "$out_v4"
  _backup_file_if_exists "$out_v6"

  {
    echo "# $out_v4 - exported from nft ($label v4) on $(date -Iseconds)"
    cat "$t4"
  } > "$out_v4"

  {
    echo "# $out_v6 - exported from nft ($label v6) on $(date -Iseconds)"
    cat "$t6"
  } > "$out_v6"

  echo "  Exported $label: $(wc -l < "$t4") v4, $(wc -l < "$t6") v6"
}

export_whitelist_from_nft() {
  ensure_whitelist_sets || return 1
  mkdir -p "$BASE_DIR" || true
  _export_set_to_file "$WHITELIST_SET_V4" "$WHITELIST_SET_V6"     "$USER_WHITELIST_FILE" "$SYSTEM_WHITELIST_FILE" "Whitelist"
}

export_blacklist_from_nft() {
  ensure_blacklist_sets || return 1
  mkdir -p "$BASE_DIR" || true
  _export_set_to_file "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6"     "$USER_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "User Blacklist"
  _export_set_to_file "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6"     "$SYSTEM_BLACKLIST_FILE" "$IPV6_SYSTEM_BLACKLIST_FILE" "System Blacklist"
}

export_all_lists_from_nft() {
  ui title "Exporting nft sets → files"
  ensure_temp_ban_table || return 1
  export_whitelist_from_nft
  export_blacklist_from_nft
  ui success "Export complete"
}



# -----------------------------------------------------------------------------
# Bulk sync from files -> nft sets
#   - Reads user + system files, canonicalizes via sipcalc/ipcalc helpers
#   - Compares with active nft set contents
#   - Adds missing elements; removes extraneous ones
# -----------------------------------------------------------------------------
_sync_family_from_files_to_set() {
  # $1 = human name, $2 = set_v4, $3 = set_v6, $4.. = files to read (may not exist)
  local label="$1"; local set_v4="$2"; local set_v6="$3"; shift 3
  local tmp_f4; tmp_f4=$(mktemp); TMP_FILES+=("$tmp_f4")
  local tmp_f6; tmp_f6=$(mktemp); TMP_FILES+=("$tmp_f6")

  # Collect and canonicalize file IPs
  for f in "$@"; do
    [ -f "$f" ] || continue
    # Split by family, then canonicalize with the tool-backed validator
    grep -vE '^\s*#' "$f" | awk '{print $1}' | grep -v ":" | validate_list_with_tools >> "$tmp_f4" 2>/dev/null || true
    grep -vE '^\s*#' "$f" | awk '{print $1}' | grep ":"  | validate_list_with_tools >> "$tmp_f6" 2>/dev/null || true
  done
  sort -u "$tmp_f4" -o "$tmp_f4"
  sort -u "$tmp_f6" -o "$tmp_f6"

  # Pull active from nft sets
  local act_f4; act_f4=$(mktemp); TMP_FILES+=("$act_f4")
  local act_f6; act_f6=$(mktemp); TMP_FILES+=("$act_f6")
  get_set_elements "$TEMP_BAN_TABLE" "$set_v4" > "$act_f4" 2>/dev/null || true
  get_set_elements "$TEMP_BAN_TABLE" "$set_v6" > "$act_f6" 2>/dev/null || true

  # Compute diffs
  local add_f4; add_f4=$(mktemp); TMP_FILES+=("$add_f4")
  local add_f6; add_f6=$(mktemp); TMP_FILES+=("$add_f6")
  local del_f4; del_f4=$(mktemp); TMP_FILES+=("$del_f4")
  local del_f6; del_f6=$(mktemp); TMP_FILES+=("$del_f6")

  comm -23 "$tmp_f4" "$act_f4" > "$add_f4"      # in files, not in nft
  comm -13 "$tmp_f4" "$act_f4" > "$del_f4"      # in nft, not in files
  comm -23 "$tmp_f6" "$act_f6" > "$add_f6"
  comm -13 "$tmp_f6" "$act_f6" > "$del_f6"
# Apply adds
  if [ "$DRY_RUN" == "true" ]; then
    echo "  [dry-run] Will add to $set_v4: $(wc -l < $add_f4) IPv4";
    echo "  [dry-run] Will add to $set_v6: $(wc -l < $add_f6) IPv6";
  else
  local ip
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    nft add element inet "$TEMP_BAN_TABLE" "$set_v4" "{ $ip }" >/dev/null 2>&1 || true
  done < "$add_f4"
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    nft add element inet "$TEMP_BAN_TABLE" "$set_v6" "{ $ip }" >/dev/null 2>&1 || true
  done < "$add_f6"  fi
# Apply deletes
  if [ "$DRY_RUN" == "true" ]; then
    echo "  [dry-run] Will delete from $set_v4: $(wc -l < $del_f4) IPv4";
    echo "  [dry-run] Will delete from $set_v6: $(wc -l < $del_f6) IPv6";
  else
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    nft delete element inet "$TEMP_BAN_TABLE" "$set_v4" "{ $ip }" >/dev/null 2>&1 || true
  done < "$del_f4"
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    nft delete element inet "$TEMP_BAN_TABLE" "$set_v6" "{ $ip }" >/dev/null 2>&1 || true
  done < "$del_f6"  fi

  # Report
  local add4=$(wc -l < "$add_f4"); local del4=$(wc -l < "$del_f4")
  local add6=$(wc -l < "$add_f6"); local del6=$(wc -l < "$del_f6")
  echo "  $label: +$add4 v4 / +$add6 v6 added; -$del4 v4 / -$del6 v6 removed"
}

sync_whitelist_to_nft() {
  ensure_whitelist_sets || return 1
  _sync_family_from_files_to_set "Whitelist" "$WHITELIST_SET_V4" "$WHITELIST_SET_V6" \
    "$USER_WHITELIST_FILE" "$SYSTEM_WHITELIST_FILE"
}

sync_blacklist_to_nft() {
  ensure_blacklist_sets || return 1
  _sync_family_from_files_to_set "User Blacklist" "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6" \
    "$USER_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
  _sync_family_from_files_to_set "System Blacklist" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6" \
    "$SYSTEM_BLACKLIST_FILE" "$IPV6_SYSTEM_BLACKLIST_FILE"
}

sync_all_lists_to_nft() {
  ui title "Syncing files → nft sets"
  ensure_temp_ban_table || return 1
  sync_whitelist_to_nft
  sync_blacklist_to_nft
  ui success "Sync complete"
}


get_set_elements() {
    local table="$1"
    local set_name="$2"
    
    if ! nft list set inet "$table" "$set_name" >/dev/null 2>&1; then
        return 1
    fi
    
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
    
    grep -v '^\s*#' "$file" 2>/dev/null | \
        awk '{print $1}' | \
        grep -E '^[0-9]|^[0-9a-fA-F]*:' | \
        sort -u
}

# ------------------------------ IP Checking -------------------------------- #
is_ip_whitelisted() {
    local ip="$1"
    local found=false
    
    if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
        found=true
    fi
    
    if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
        found=true
    fi
    
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

verify_ip_location() {
    local ip="$1"
    local found_anywhere=false
    
    ui title "IP Location Report: $ip"
    echo ""
    
    ui info "Whitelist Files:"
    if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
        ui success "Found in user whitelist: $USER_WHITELIST_FILE"
        found_anywhere=true
    else
        ui warn "Not in user whitelist"
    fi
    
    if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
        ui success "Found in system whitelist: $SYSTEM_WHITELIST_FILE"
        found_anywhere=true
    else
        ui warn "Not in system whitelist"
    fi
    
    echo ""
    ui info "Blacklist Files:"
    if [ -f "$USER_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_BLACKLIST_FILE"; then
        ui fire "Found in user blacklist: $USER_BLACKLIST_FILE"
        found_anywhere=true
    else
        ui warn "Not in user blacklist"
    fi
    
    if [[ "$ip" =~ .*:.* ]]; then
        if [ -f "$IPV6_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$IPV6_BLACKLIST_FILE"; then
            ui fire "Found in IPv6 blacklist: $IPV6_BLACKLIST_FILE"
            found_anywhere=true
        else
            ui warn "Not in IPv6 blacklist"
        fi
    else
        if [ -f "$IPV4_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$IPV4_BLACKLIST_FILE"; then
            ui fire "Found in IPv4 blacklist: $IPV4_BLACKLIST_FILE"
            found_anywhere=true
        else
            ui warn "Not in IPv4 blacklist"
        fi
    fi
    
    echo ""
    ui info "Active nftables Sets:"
    
    local set_v4_or_v6
    if [[ "$ip" =~ .*:.* ]]; then
        set_v4_or_v6="v6"
    else
        set_v4_or_v6="v4"
    fi
    
    local whitelist_set="WHITELIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!whitelist_set}" 2>/dev/null | grep -Fxq "$ip"; then
        ui success "Found in ${!whitelist_set}"
        found_anywhere=true
    else
        ui warn "Not in ${!whitelist_set}"
    fi
    
    local user_bl_set="USER_BLACKLIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!user_bl_set}" 2>/dev/null | grep -Fxq "$ip"; then
        ui fire "Found in ${!user_bl_set}"
        found_anywhere=true
    else
        ui warn "Not in ${!user_bl_set}"
    fi
    
    local sys_bl_set="SYSTEM_BLACKLIST_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!sys_bl_set}" 2>/dev/null | grep -Fxq "$ip"; then
        ui fire "Found in ${!sys_bl_set}"
        found_anywhere=true
    else
        ui warn "Not in ${!sys_bl_set}"
    fi
    
    local temp_ban_set="TEMP_BAN_SET_V${set_v4_or_v6^^}"
    if get_set_elements "$TEMP_BAN_TABLE" "${!temp_ban_set}" 2>/dev/null | grep -Fxq "$ip"; then
        ui fire "Found in ${!temp_ban_set} (temporary)"
        found_anywhere=true
    else
        ui warn "Not in ${!temp_ban_set}"
    fi
    
    echo ""
    ui info "Fail2Ban Status:"
    if command -v fail2ban-client >/dev/null 2>&1; then
        local found_in_jail=false
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
            if fail2ban-client status "$jail" 2>/dev/null | grep -q "$ip"; then
                ui fire "Banned in fail2ban jail: $jail"
                found_in_jail=true
                found_anywhere=true
            fi
        done
        if [ "$found_in_jail" = false ]; then
            ui warn "Not banned in any fail2ban jail"
        fi
    else
        ui warn "Fail2ban not installed"
    fi
    
    echo ""
    if [ "$found_anywhere" = true ]; then
        ui success "IP found in at least one location"
        return 0
    else
        ui warn "IP not found in any location"
        return 1
    fi
}

# ------------------------------ Sync Validation ---------------------------- #
validate_sync_status() {
    ui title "Sync Status: Files vs Active nftables Sets"
    echo ""
    
    local issues_found=0
    
    ui info "Whitelist Synchronization:"
    
    local file_whitelist_v4=$(mktemp)
    TMP_FILES+=("$file_whitelist_v4")
    local file_whitelist_v6=$(mktemp)
    TMP_FILES+=("$file_whitelist_v6")
    
    get_ips_from_file "$USER_WHITELIST_FILE" | grep -v ':' > "$file_whitelist_v4" 2>/dev/null || true
    get_ips_from_file "$SYSTEM_WHITELIST_FILE" | grep -v ':' >> "$file_whitelist_v4" 2>/dev/null || true
    get_ips_from_file "$USER_WHITELIST_FILE" | grep ':' > "$file_whitelist_v6" 2>/dev/null || true
    get_ips_from_file "$SYSTEM_WHITELIST_FILE" | grep ':' >> "$file_whitelist_v6" 2>/dev/null || true
    
    sort -u "$file_whitelist_v4" -o "$file_whitelist_v4"
    sort -u "$file_whitelist_v6" -o "$file_whitelist_v6"
    
    local active_whitelist_v4=$(mktemp)
    TMP_FILES+=("$active_whitelist_v4")
    local active_whitelist_v6=$(mktemp)
    TMP_FILES+=("$active_whitelist_v6")
    
    get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" > "$active_whitelist_v4" 2>/dev/null || true
    get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" > "$active_whitelist_v6" 2>/dev/null || true
    
    local file_count=$(wc -l < "$file_whitelist_v4")
    local active_count=$(wc -l < "$active_whitelist_v4")
    
    echo "  IPv4 Whitelist: ${file_count} in files, ${active_count} in ${WHITELIST_SET_V4}"
    
    local in_file_not_active=$(comm -23 "$file_whitelist_v4" "$active_whitelist_v4" | wc -l)
    local in_active_not_file=$(comm -13 "$file_whitelist_v4" "$active_whitelist_v4" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        ui warn "${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        ui warn "${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        ui success "IPv4 whitelist in sync"
    fi
    
    file_count=$(wc -l < "$file_whitelist_v6")
    active_count=$(wc -l < "$active_whitelist_v6")
    
    echo "  IPv6 Whitelist: ${file_count} in files, ${active_count} in ${WHITELIST_SET_V6}"
    
    in_file_not_active=$(comm -23 "$file_whitelist_v6" "$active_whitelist_v6" | wc -l)
    in_active_not_file=$(comm -13 "$file_whitelist_v6" "$active_whitelist_v6" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        ui warn "${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        ui warn "${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        ui success "IPv6 whitelist in sync"
    fi
    
    echo ""
    ui info "Blacklist Synchronization:"
    
    local file_bl_v4=$(mktemp)
    TMP_FILES+=("$file_bl_v4")
    local active_bl_v4=$(mktemp)
    TMP_FILES+=("$active_bl_v4")
    
    get_ips_from_file "$USER_BLACKLIST_FILE" | grep -v ':' > "$file_bl_v4" 2>/dev/null || true
    get_ips_from_file "$IPV4_BLACKLIST_FILE" >> "$file_bl_v4" 2>/dev/null || true
    sort -u "$file_bl_v4" -o "$file_bl_v4"
    
    get_set_elements "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V4" > "$active_bl_v4" 2>/dev/null || true
    
    file_count=$(wc -l < "$file_bl_v4")
    active_count=$(wc -l < "$active_bl_v4")
    
    echo "  IPv4 User Blacklist: ${file_count} in files, ${active_count} in ${USER_BLACKLIST_SET_V4}"
    
    in_file_not_active=$(comm -23 "$file_bl_v4" "$active_bl_v4" | wc -l)
    in_active_not_file=$(comm -13 "$file_bl_v4" "$active_bl_v4" | wc -l)
    
    if [ "$in_file_not_active" -gt 0 ]; then
        ui warn "${in_file_not_active} IPs in files but not in active set"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_active_not_file" -gt 0 ]; then
        ui warn "${in_active_not_file} IPs in active set but not in files"
        issues_found=$((issues_found + 1))
    fi
    
    if [ "$in_file_not_active" -eq 0 ] && [ "$in_active_not_file" -eq 0 ]; then
        ui success "IPv4 user blacklist in sync"
    fi
    
    echo ""
    if [ "$issues_found" -eq 0 ]; then
        ui success "All sets are in sync with configuration files"
        return 0
    else
        ui warn "Found $issues_found sync issue(s)"
        ui tip "Run 'nftban --sync' to reload nftables configuration"
        return 1
    fi
}

show_all_sets() {
    ui title "All nftables Sets in ${TEMP_BAN_TABLE}"
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
        
        ui info "${set_label} (${set_name}):"
        
        if ! nft list set inet "$TEMP_BAN_TABLE" "$set_name" >/dev/null 2>&1; then
            ui error "Set not found"
            continue
        fi
        
        local elements
        elements=$(get_set_elements "$TEMP_BAN_TABLE" "$set_name")
        
        if [ -z "$elements" ]; then
            echo "  (empty)"
        else
            local count=$(echo "$elements" | wc -l)
            ui success "${count} element(s)"
            echo "$elements" | sed 's/^/    /'
        fi
        echo ""
    done
}

sync_nftables() {
    ui step "Synchronizing nftables with configuration files..."
    
    local init_script="$SCRIPTS_DIR/nftban_init_nftables_conf.sh"
    
    if [ ! -f "$init_script" ]; then
        ui error "Init script not found: $init_script"
        ui warn "Cannot reload configuration automatically"
        return 1
    fi
    
    ui info "Running nftables initialization script..."
    
    if [ -x "$init_script" ]; then
        if "$init_script" --install-final; then
            ui success "nftables configuration reloaded successfully"
            log "Synchronized nftables configuration from files"
            return 0
        else
            ui error "Failed to reload nftables configuration"
            return 1
        fi
    else
        ui info "Making script executable and running..."
        chmod +x "$init_script"
        if "$init_script" --install-final; then
            ui success "nftables configuration reloaded successfully"
            log "Synchronized nftables configuration from files"
            return 0
        else
            ui error "Failed to reload nftables configuration"
            return 1
        fi
    fi
}

# ------------------------------ Auto-Update Functions ---------------------- #
cron_sanity_check() {
  if command -v systemctl >/dev/null 2>&1; then
    if ! (systemctl is-enabled cron >/dev/null 2>&1 || systemctl is-enabled crond >/dev/null 2>&1); then
      ui warn "cron service appears disabled. Auto-update may not run."
    fi
    if ! (systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1); then
      ui warn "cron service is not active. Consider: systemctl start cron (or crond)."
    fi
  fi
}

ensure_single_cron_entry() {
  local entry="$1"
  local tmpfile; tmpfile="$(mktemp)"
  TMP_FILES+=("$tmpfile")
  crontab -l 2>/dev/null | grep -vF "$AUTO_UPDATE_SCRIPT" > "$tmpfile" || true
  printf '%s\n' "$entry" >> "$tmpfile"
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    crontab "$tmpfile" 2>/dev/null || true
  else
    log INFO "DRY-RUN: would install crontab entry: $entry"
  fi
}

setup_auto_update() {
  mkdir -p "$(dirname "$AUTO_UPDATE_SCRIPT")"
  cat > "$AUTO_UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO_URL="https://github.com/itcmsgr/nftban"
BRANCH="main"
TARGET_DIR="/etc/nftban"
cd "$TARGET_DIR"
if [ -d .git ]; then
  git fetch --quiet
  git reset --hard "origin/$BRANCH" --quiet
  git pull --quiet --rebase
else
  git init -q
  git remote add origin "$REPO_URL" 2>/dev/null || true
  git fetch -q origin "$BRANCH"
  git checkout -q -B "$BRANCH" "origin/$BRANCH"
fi
EOF
  chmod +x "$AUTO_UPDATE_SCRIPT"
  
  local CRON_LINE
  if [[ -n "${DAILY_TIME:-}" ]]; then
    local HH="${DAILY_TIME%%:*}"
    local MM="${DAILY_TIME##*:}"
    CRON_LINE="${MM} ${HH} * * * $AUTO_UPDATE_SCRIPT >/dev/null 2>&1"
    log INFO "Configuring auto-update daily at ${DAILY_TIME}"
  else
    CRON_LINE="0 */12 * * * $AUTO_UPDATE_SCRIPT >/dev/null 2>&1"
    log INFO "Configuring auto-update every 12 hours"
  fi
  ensure_single_cron_entry "$CRON_LINE"
  cron_sanity_check
  ui success "Auto-update cron installed"
}

remove_auto_update() {
  local tmpfile; tmpfile=$(mktemp)
  TMP_FILES+=("$tmpfile")
  crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_SCRIPT" > "$tmpfile" || true
  if [[ "${DRY_RUN:-false}" != "true" ]]; then 
    crontab "$tmpfile" 2>/dev/null || true
  else 
    log INFO "DRY-RUN: would remove existing crontab entries for $AUTO_UPDATE_SCRIPT"
  fi
  
  if [[ -f "$AUTO_UPDATE_SCRIPT" ]]; then
    if [[ "${DRY_RUN:-false}" != "true" ]]; then 
      rm -f "$AUTO_UPDATE_SCRIPT"
    else 
      log INFO "DRY-RUN: would remove $AUTO_UPDATE_SCRIPT"
    fi
    ui success "Removed auto-update script: $AUTO_UPDATE_SCRIPT"
  fi
  ui success "Auto-update cron entries removed"
}

auto_update_status() {
  local tmpfile; tmpfile="$(mktemp)"
  TMP_FILES+=("$tmpfile")
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  mapfile -t cron_lines < <(grep -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" || true)

  local count="${#cron_lines[@]}"
  if [[ "$count" -gt 0 ]]; then
    ui clock "Auto-update via crontab: ENABLED ($count entr$([[ $count -eq 1 ]] && echo 'y' || echo 'ies'))"
    printf '%s\n' "${cron_lines[@]}" | sed 's/^/  • /'
  else
    ui warn "Auto-update via crontab: DISABLED (no matching crontab lines)"
  fi

  if [[ -f "$AUTO_UPDATE_SCRIPT" ]]; then
    local sz mtime sha
    sz=$(stat -c '%s' "$AUTO_UPDATE_SCRIPT" 2>/dev/null || stat -f '%z' "$AUTO_UPDATE_SCRIPT" 2>/dev/null || echo "?")
    mtime=$(date -r "$AUTO_UPDATE_SCRIPT" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
    if command -v sha256sum >/dev/null 2>&1; then
      sha=$(sha256sum "$AUTO_UPDATE_SCRIPT" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
      sha=$(shasum -a 256 "$AUTO_UPDATE_SCRIPT" | awk '{print $1}')
    else
      sha="(sha256 tool not found)"
    fi
    ui info "Auto-update script: $AUTO_UPDATE_SCRIPT"
    echo "  size: ${sz} bytes, modified: ${mtime}"
    echo "  sha256: ${sha}"
  else
    ui warn "Auto-update script not found at: $AUTO_UPDATE_SCRIPT"
  fi
}

print_json_status() {
  local enabled="false" lines=0
  local tmpfile; tmpfile="$(mktemp)"
  TMP_FILES+=("$tmpfile")
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  lines=$(grep -c -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" 2>/dev/null || echo 0)
  if [[ "$lines" -gt 0 ]]; then enabled="true"; fi
  printf '{"auto_update_enabled":%s,"auto_update_lines":%s,"version":"%s","nftables_status":"%s","fail2ban_status":"%s"}\n' \
    "$enabled" "$lines" "$VERSION" "$(get_nftables_status)" "$(get_fail2ban_status)"
}

# ------------------------------ Statistics & Reporting --------------------- #
show_statistics() {
    ui title "nftban Statistics Report"
    echo ""
    
    # System info
    ui chart "System Information:"
    echo "  Version: $VERSION"
    echo "  Base Directory: $(dirname "$BASE_DIR")"
    echo "  Log Directory: $LOG_DIR"
    
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
        local log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
        echo "  Log File: $log_size ($log_lines lines)"
    fi
    
    echo ""
    ui chart "Service Status:"
    local nft_status=$(get_nftables_status)
    local f2b_status=$(get_fail2ban_status)
    
    if [ "$nft_status" = "active" ]; then
        ui success "nftables: ACTIVE"
    else
        ui warn "nftables: INACTIVE"
    fi
    
    if [ "$f2b_status" = "active" ]; then
        ui success "fail2ban: ACTIVE"
    elif [ "$f2b_status" = "not installed" ]; then
        ui warn "fail2ban: NOT INSTALLED"
    else
        ui warn "fail2ban: INACTIVE"
    fi
    
    echo ""
    ui chart "IP Statistics:"
    
    # Count whitelisted IPs
    local user_wl_count=0
    local sys_wl_count=0
    if [ -f "$USER_WHITELIST_FILE" ]; then
        user_wl_count=$(grep -v '^\s*#' "$USER_WHITELIST_FILE" 2>/dev/null | grep -c '[0-9]' || echo 0)
    fi
    if [ -f "$SYSTEM_WHITELIST_FILE" ]; then
        sys_wl_count=$(grep -v '^\s*#' "$SYSTEM_WHITELIST_FILE" 2>/dev/null | grep -c '[0-9]' || echo 0)
    fi
    
    echo "  Whitelisted IPs:"
    echo "    User: $user_wl_count"
    echo "    System: $sys_wl_count"
    echo "    Total: $((user_wl_count + sys_wl_count))"
    
    # Count blacklisted IPs
    local user_bl_count=0
    local ipv4_bl_count=0
    local ipv6_bl_count=0
    if [ -f "$USER_BLACKLIST_FILE" ]; then
        user_bl_count=$(grep -v '^\s*#' "$USER_BLACKLIST_FILE" 2>/dev/null | grep -c '[0-9]' || echo 0)
    fi
    if [ -f "$IPV4_BLACKLIST_FILE" ]; then
        ipv4_bl_count=$(grep -v '^\s*#' "$IPV4_BLACKLIST_FILE" 2>/dev/null | grep -c '[0-9]' || echo 0)
    fi
    if [ -f "$IPV6_BLACKLIST_FILE" ]; then
        ipv6_bl_count=$(grep -v '^\s*#' "$IPV6_BLACKLIST_FILE" 2>/dev/null | grep -c '[0-9]' || echo 0)
    fi
    
    echo "  Blacklisted IPs:"
    echo "    User: $user_bl_count"
    echo "    IPv4: $ipv4_bl_count"
    echo "    IPv6: $ipv6_bl_count"
    echo "    Total: $((user_bl_count + ipv4_bl_count + ipv6_bl_count))"
    
    # Active set statistics
    if nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
        echo ""
        ui chart "Active nftables Sets:"
        
        local temp_v4_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | wc -l)
        local temp_v6_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | wc -l)
        local wl_v4_count=$(get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" 2>/dev/null | wc -l)
        local wl_v6_count=$(get_set_elements "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" 2>/dev/null | wc -l)
        local ubl_v4_count=$(get_set_elements "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V4" 2>/dev/null | wc -l)
        local ubl_v6_count=$(get_set_elements "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V6" 2>/dev/null | wc -l)
        
        echo "  Temporary Bans: $temp_v4_count IPv4, $temp_v6_count IPv6"
        echo "  Whitelists: $wl_v4_count IPv4, $wl_v6_count IPv6"
        echo "  User Blacklists: $ubl_v4_count IPv4, $ubl_v6_count IPv6"
    else
        ui warn "Global table not found"
    fi
    
    # Fail2Ban statistics
    if command -v fail2ban-client >/dev/null 2>&1 && [ "$f2b_status" = "active" ]; then
        echo ""
        ui chart "Fail2Ban Statistics:"
        
        local total_banned=0
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
            local jail_banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
            if [ -n "$jail_banned" ]; then
                total_banned=$((total_banned + jail_banned))
                echo "  $jail: $jail_banned banned"
            fi
        done
        echo "  Total: $total_banned IPs banned across all jails"
    fi
    
    # Auto-update status
    echo ""
    ui clock "Auto-Update Status:"
    local tmpfile; tmpfile="$(mktemp)"
    TMP_FILES+=("$tmpfile")
    crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
    local cron_count=$(grep -c -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" 2>/dev/null || echo 0)
    
    if [ "$cron_count" -gt 0 ]; then
        ui success "Enabled ($cron_count cron entries)"
    else
        ui warn "Disabled"
    fi
}

show_package_status() {
    ui title "Package Health Status"
    echo ""
    
    local packages=(
        "nft:nftables"
        "fail2ban-client:fail2ban"
        "whois:whois"
        "dig:dnsutils/bind-utils"
        "git:git"
    )
    
    for pkg_info in "${packages[@]}"; do
        local cmd="${pkg_info%%:*}"
        local name="${pkg_info#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            ui success "$name installed"
            if [ "$cmd" = "nft" ]; then
                local version=$(nft --version 2>/dev/null | head -1)
                echo "    $version"
            elif [ "$cmd" = "fail2ban-client" ]; then
                local version=$(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')
                echo "    $version"
            fi
        else
            ui error "$name NOT installed"
        fi
    done
}

# ------------------------------ Current Login IP --------------------------- #
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
  if [ -f "$SYSTEM_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$SYSTEM_WHITELIST_FILE"; then
    return 0
  fi
  return 1
}

is_current_login_ip() {
  local ip="$1"
  local current_ip
  current_ip=$(get_current_login_ip)
  [ "$ip" = "$current_ip" ]
}

# ------------------------------ IP Management ------------------------------ #
sanitize_comment() {
    local comment="$1"
    # Remove potentially dangerous characters
    echo "$comment" | sed 's/[<>$`|&;()*?[\]{}]//g' | tr -d '\n\r' | cut -c1-200
}

add_ip_to_allow() {
    local ip="$1"
    local added=false
    local comment
    comment=" # Added by nftban on $(date '+%Y-%m-%d %H:%M:%S') for user $(whoami)"
    
    if [ ! -d "$BASE_DIR" ]; then
        if ! mkdir -p "$BASE_DIR"; then
            log "ERROR" "Failed to create directory $BASE_DIR"
            ui error "Failed to create configuration directory"
            return 1
        fi
        chmod 755 "$BASE_DIR"
    fi
    
    if [ ! -f "$USER_WHITELIST_FILE" ]; then
        if ! touch "$USER_WHITELIST_FILE"; then
            log "ERROR" "Failed to create $USER_WHITELIST_FILE"
            ui error "Failed to create allow file"
            return 1
        fi
        chmod 644 "$USER_WHITELIST_FILE"
        echo "# User whitelist IPs - managed by nftban" > "$USER_WHITELIST_FILE"
        echo "# Format: IP_ADDRESS [optional comment]" >> "$USER_WHITELIST_FILE"
        echo "" >> "$USER_WHITELIST_FILE"
    fi
    
    if check_ip_in_allow "$ip"; then
        log "INFO" "IP $ip already in allow file"
        return 2
    fi
    
    if echo "$ip$comment" >> "$USER_WHITELIST_FILE"; then
        log "INFO" "Added IP $ip to user allow file"
        added=true
    else
        log "ERROR" "Failed to write to $USER_WHITELIST_FILE"
        ui error "Failed to add IP to allow file"
        return 1
    fi
    
    if [[ "$ip" =~ .*:.* ]]; then
        if ! nft add element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" "{ $ip }" 2>/dev/null; then
            ui warn "Failed to add IP to active whitelist set (v6)"
            log "ERROR" "Failed to add $ip to whitelist_v6 set"
        else
            log "INFO" "Added $ip to whitelist_v6 set"
        fi
    else
        if ! nft add element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" "{ $ip }" 2>/dev/null; then
            ui warn "Failed to add IP to active whitelist set (v4)"
            log "ERROR" "Failed to add $ip to whitelist_v4 set"
        else
            log "INFO" "Added $ip to whitelist_v4 set"
        fi
    fi
    
    [ "$added" = true ] && return 0 || return 1
}

remove_ip_from_whitelist() {
  local ip="$1"
  local removed=false
  
  if [ -f "$USER_WHITELIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_WHITELIST_FILE"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$USER_WHITELIST_FILE"
    log "INFO" "Removed IP $ip from user whitelist file"
    removed=true
  fi
  
  if [[ "$ip" =~ .*:.* ]]; then
    if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V6" "{ $ip }" 2>/dev/null; then
      ui warn "Failed to remove IP from whitelist_v6 set"
      log "WARN" "Failed to remove $ip from whitelist_v6 set"
    else
      log "INFO" "Removed $ip from whitelist_v6 set"
    fi
  else
    if ! nft delete element inet "$TEMP_BAN_TABLE" "$WHITELIST_SET_V4" "{ $ip }" 2>/dev/null; then
      ui warn "Failed to remove IP from whitelist_v4 set"
      log "WARN" "Failed to remove $ip from whitelist_v4 set"
    else
      log "INFO" "Removed $ip from whitelist_v4 set"
    fi
  fi
  
  [ "$removed" = true ] && return 0 || return 1
}

add_ip_to_blacklist() {
    local ip="$1"
    local comment="$2"
    local blacklist_file
    local temp_file
    
    [[ "$ip" =~ .*:.* ]] && blacklist_file="$IPV6_BLACKLIST_FILE" || blacklist_file="$IPV4_BLACKLIST_FILE"
    temp_file="${blacklist_file}.tmp"
    
    [ -z "$comment" ] && comment="Banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    
    comment=$(sanitize_comment "$comment")
    
    mkdir -p "$(dirname "$blacklist_file")"
    
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
    
    if ! cp "$blacklist_file" "$temp_file"; then
        log "ERROR" "Failed to create temporary file"
        return 1
    fi
    
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$temp_file"
    
    echo "$ip # $comment" >> "$temp_file"
    # Also add to nft set (user blacklist)
    if ensure_blacklist_sets; then
      if [[ "$ip" == *:* ]]; then
        nft add element inet "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V6" "{ $ip }" >/dev/null 2>&1 || true
      else
        nft add element inet "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V4" "{ $ip }" >/dev/null 2>&1 || true
      fi
    fi
    if mv "$temp_file" "$blacklist_file"; then
        log "INFO" "Added IP $ip to blacklist with comment: $comment"
        remove_ip_from_whitelist "$ip" 2>/dev/null
        return 0
    else
        log "ERROR" "Failed to update blacklist file"
        rm -f "$temp_file"
        return 1
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
    log "INFO" "Removed IP $ip from blacklist file $blacklist_file"
    removed=true
  fi
  
  if [ -f "$USER_BLACKLIST_FILE" ] && grep -Eq "^${ip}([[:space:]]|$)" "$USER_BLACKLIST_FILE"; then
    sed -i "/^${ip}\([[:space:]]\|$\)/d" "$USER_BLACKLIST_FILE"
    log "INFO" "Removed IP $ip from user blacklist file"
    removed=true
  fi
  
  if [ "$removed" = true ]; then
  if ensure_blacklist_sets; then
    if [[ "$ip" == *:* ]]; then
      nft delete element inet "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V6" "{ $ip }" >/dev/null 2>&1 || true
      nft delete element inet "$TEMP_BAN_TABLE" "$SYSTEM_BLACKLIST_SET_V6" "{ $ip }" >/dev/null 2>&1 || true
    else
      nft delete element inet "$TEMP_BAN_TABLE" "$USER_BLACKLIST_SET_V4" "{ $ip }" >/dev/null 2>&1 || true
      nft delete element inet "$TEMP_BAN_TABLE" "$SYSTEM_BLACKLIST_SET_V4" "{ $ip }" >/dev/null 2>&1 || true
    fi
  fi
  return 0
else
  return 1
fi
}

##
# @brief Add IP to temporary ban with timeout
# @param $1 IP address to ban
# @param $2 Optional comment
# @return 0 on success, 1 on failure, 2 if already banned
# @note Ban expires after 1 hour automatically
##
temp_ban_ip() {
    local ip="$1"
    local comment="$2"
    
    comment=$(sanitize_comment "$comment")
    
    if is_current_login_ip "$ip"; then
        ui error "Cannot ban your own login IP ($ip)"
        log "WARN" "Attempted to ban own login IP: $ip"
        return 1
    fi
    
    if is_ip_whitelisted "$ip"; then
        ui error "Cannot ban whitelisted IP ($ip)"
        log "WARN" "Attempted to ban whitelisted IP: $ip"
        return 1
    fi
    
    if ! ensure_temp_ban_table; then 
        ui tip "Run 'nftban init' to set up the required tables"
        return 1
    fi
    
    [ -z "$comment" ] && comment="Temporarily banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
    
    local set_name
    local ip_version
    if [[ "$ip" =~ .*:.* ]]; then
        set_name="$TEMP_BAN_SET_V6"
        ip_version="IPv6"
    else
        set_name="$TEMP_BAN_SET_V4"
        ip_version="IPv4"
    fi
    
    local nft_output
    nft_output=$(nft add element inet "$TEMP_BAN_TABLE" "$set_name" "{ $ip timeout 1h }" 2>&1)
    local nft_rc=$?
    
    if [ $nft_rc -eq 0 ]; then
        log "INFO" "Temporarily banned $ip_version address: $ip with comment: $comment"
        ui fire "Temporarily banned $ip_version address: $ip (1 hour)"
        echo "Comment: $comment"
        return 0
    else
        if nft list set inet "$TEMP_BAN_TABLE" "$set_name" 2>/dev/null | grep -q "$ip"; then
            ui warn "IP $ip is already temporarily banned"
            log "INFO" "IP $ip already in temporary ban set"
            return 2
        else
            ui error "Failed to add $ip_version $ip to temporary ban set"
            echo "Error: $nft_output"
            log "ERROR" "Failed to ban $ip: $nft_output"
            return 1
        fi
    fi
}

perm_ban_ip() {
  local ip="$1"
  local comment="$2"
  
  comment=$(sanitize_comment "$comment")
  
  if is_current_login_ip "$ip"; then
    ui error "Cannot ban your own login IP ($ip)"
    log "WARN" "Attempted to ban own login IP: $ip"
    return 1
  fi
  
  if is_ip_whitelisted "$ip"; then
    ui error "Cannot ban whitelisted IP ($ip)"
    log "WARN" "Attempted to ban whitelisted IP: $ip"
    return 1
  fi
  
  if [ -z "$comment" ]; then
    comment="Permanently banned by nftban on $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  
  if add_ip_to_blacklist "$ip" "$comment"; then
    log "INFO" "Permanently banned IP: $ip with comment: $comment"
    ui fire "Permanently banned IP: $ip"
    echo "Comment: $comment"
    temp_ban_ip "$ip" "$comment (also permanently banned)" >/dev/null 2>&1 || true
    return 0
  else
    ui warn "IP $ip is already banned"
    return 1
  fi
}

remove_temp_ban() {
  local ip="$1"
  local removed=false
  
  if [[ "$ip" =~ .*:.* ]]; then
    if nft delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" "{ $ip }" 2>/dev/null; then
      log "INFO" "Removed temporary ban for IPv6 address: $ip"
      ui success "Removed temporary ban for IPv6 address: $ip"
      removed=true
    fi
  else
    if nft delete element inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" "{ $ip }" 2>/dev/null; then
      log "INFO" "Removed temporary ban for IPv4 address: $ip"
      ui success "Removed temporary ban for IPv4 address: $ip"
      removed=true
    fi
  fi
  
  if [ "$removed" = true ]; then return 0; fi
  log "INFO" "IP $ip was not found in temporary ban sets"
  ui warn "IP $ip was not found in temporary ban sets"
  return 1
}

remove_ip_from_fail2ban() {
  local ip="$1"
  local unjailed=false
  
  if command -v fail2ban-client >/dev/null 2>&1; then
    for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
      if fail2ban-client status "$jail" 2>/dev/null | grep -q "$ip"; then
        if fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1; then
          log "INFO" "Unbanned IP $ip from Fail2Ban jail: $jail"
          ui success "Unbanned IP $ip from Fail2Ban jail: $jail"
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
  
  ui step "Removing IP $ip from all ban lists..."
  
  if remove_temp_ban "$ip"; then removed_any=true; fi
  if remove_ip_from_blacklist "$ip"; then removed_any=true; fi
  if remove_ip_from_whitelist "$ip"; then removed_any=true; fi
  if remove_ip_from_fail2ban "$ip"; then removed_any=true; fi
  
  if [ "$removed_any" = true ]; then
    log "INFO" "Removed IP $ip from all ban lists and whitelist"
    ui success "Removed IP $ip from all ban lists and whitelist"
    ui tip "Run 'nftban --sync' to reload permanent nftables sets"
    return 0
  else
    log "INFO" "IP $ip was not found in any ban lists or whitelist"
    ui warn "IP $ip was not found in any ban lists or whitelist"
    return 1
  fi
}

manage_ip() {
  local current_ip
  current_ip=$(get_current_login_ip)
  
  if [ "$current_ip" = "unknown" ]; then
    ui warn "Could not determine your login IP address"
    return 1
  fi
  
  ui info "Your current login IP is: $current_ip"
  
  if check_ip_in_allow "$current_ip"; then
    ui lock "Your IP is already in the allow file"
    return 0
  else
    ui unlock "Your IP is not in the allow file"
    add_ip_to_allow "$current_ip"; rc=$?
    case $rc in
      0) ui lock "Added your IP ($current_ip) to the allow file" ;;
      2) ui lock "Your IP is already in the allow file" ;;
      *) ui error "Failed to add your IP to the allow file"; return 1 ;;
    esac
    
    if remove_ip_from_blacklist "$current_ip"; then
      ui success "Removed your IP from blacklist files"
    fi
    return 0
  fi
}

# ------------------------------ Configuration Checks ----------------------- #
validate_config() {
    local errors=0
    
    ui step "Validating nftban configuration..."
    
    # Check required directories
    for dir in "$BASE_DIR" "$LOG_DIR" "$BACKUP_DIR"; do
        if [ ! -d "$dir" ]; then
            ui warn "Missing directory: $dir"
            ((errors++))
        fi
    done
    
    # Check required files
    for file in "$CONF_FILE" "$USER_WHITELIST_FILE"; do
        if [ ! -f "$file" ]; then
            ui warn "Missing file: $file"
        fi
    done
    
    # Check nftables table
    if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
        ui error "Missing nftables table: inet $TEMP_BAN_TABLE"
        ((errors++))
    fi
    
    if [ "$errors" -eq 0 ]; then
        ui success "Configuration validation passed"
        return 0
    else
        ui error "Configuration validation failed with $errors error(s)"
        return 1
    fi
}

ensure_temp_ban_table() {
  if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    log "ERROR" "Table inet $TEMP_BAN_TABLE not found!"
    ui error "Global table 'inet $TEMP_BAN_TABLE' not found"
    ui tip "Run the nftables init script to create the structure"
    return 1
  fi
  
  if ! nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" >/dev/null 2>&1; then
    log "ERROR" "Set $TEMP_BAN_SET_V4 not found in table $TEMP_BAN_TABLE"
    ui error "Set '$TEMP_BAN_SET_V4' not found. Run init script first"
    return 1
  fi
  
  if ! nft list set inet "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" >/dev/null 2>&1; then
    log "ERROR" "Set $TEMP_BAN_SET_V6 not found in table $TEMP_BAN_TABLE"
    ui error "Set '$TEMP_BAN_SET_V6' not found. Run init script first"
    return 1
  fi
  
  log "INFO" "Verified: Global table structure exists (inet $TEMP_BAN_TABLE)"
  return 0
}


ensure_blacklist_sets() {
  if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    log "ERROR" "Table inet $TEMP_BAN_TABLE not found!"
    ui error "Global table 'inet $TEMP_BAN_TABLE' not found"
    ui tip "Run the nftables init script to create the structure"
    return 1
  fi
  local missing=0
  for s in "$USER_BLACKLIST_SET_V4" "$USER_BLACKLIST_SET_V6" "$SYSTEM_BLACKLIST_SET_V4" "$SYSTEM_BLACKLIST_SET_V6"; do
    if ! nft list set inet "$TEMP_BAN_TABLE" "$s" >/dev/null 2>&1; then
      log "ERROR" "Set $s not found in table $TEMP_BAN_TABLE"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    ui error "One or more blacklist sets are missing in '$TEMP_BAN_TABLE'"
    ui tip "Run the nftables init script to create missing sets"
    return 1
  fi
  return 0
}


ensure_whitelist_sets() {
  if ! nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    ui error "Global table 'inet $TEMP_BAN_TABLE' not found"; return 1
  fi
  local missing=0
  for s in "$WHITELIST_SET_V4" "$WHITELIST_SET_V6"; do
    if ! nft list set inet "$TEMP_BAN_TABLE" "$s" >/dev/null 2>&1; then
      log "ERROR" "Set $s not found in table $TEMP_BAN_TABLE"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || { ui error "Missing whitelist sets in '$TEMP_BAN_TABLE'"; return 1; }
  return 0
}



check_nftables_config() {
  if ! nft -c -f "$CONF_FILE" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR" "nftables configuration check failed for $CONF_FILE"
    ui error "nftables configuration check failed!"
    return 1
  fi
  log "INFO" "nftables configuration check passed for $CONF_FILE"
  ui success "nftables configuration check passed"
  return 0
}

check_fail2ban_config() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client --test 2>&1 | tee -a "$LOG_FILE"; then
      log "INFO" "Fail2Ban configuration check passed"
      ui success "Fail2Ban configuration check passed"
      return 0
    else
      log "ERROR" "Fail2Ban configuration check failed"
      ui error "Fail2Ban configuration check failed!"
      return 1
    fi
  else
    log "WARN" "Fail2Ban is not installed"
    ui warn "Fail2Ban is not installed"
    return 1
  fi
}

check_config() {
  local nft_ok=true
  local f2b_ok=true
  
  ui step "Checking nftables configuration..."
  if ! check_nftables_config; then nft_ok=false; fi
  
  ui step "Checking Fail2Ban configuration..."
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
    log "INFO" "Backed up configuration to $BACKUP_DIR/nftables.conf.$timestamp"
  fi
}

backup_configs() {
    local backup_dir="/etc/nftban/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    ui step "Backing up configurations to $backup_dir..."
    
    # Backup configuration files
    if [ -d "$BASE_DIR" ]; then
        cp -r "$BASE_DIR" "$backup_dir/" 2>/dev/null || true
    fi
    
    # Backup main config
    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "$backup_dir/" 2>/dev/null
    fi
    
    # Backup scripts
    if [ -d "$SCRIPTS_DIR" ]; then
        cp -r "$SCRIPTS_DIR" "$backup_dir/" 2>/dev/null || true
    fi
    
    log "INFO" "Configuration backed up to $backup_dir"
    ui success "Configuration backed up to $backup_dir"
}

# ------------------------------ Service Management ------------------------- #
enable_nftables_service()  { systemctl enable nftables 2>/dev/null; log "INFO" "Enabled nftables service"; }
disable_nftables_service() { systemctl disable nftables 2>/dev/null; log "INFO" "Disabled nftables service"; }

start_nftables_service() {
  if systemctl start nftables 2>/dev/null; then
    log "INFO" "Started nftables service"
    ui success "nftables service started"
    return 0
  else
    log "ERROR" "Failed to start nftables service"
    ui error "Failed to start nftables service"
    return 1
  fi
}

stop_nftables_service() {
  if systemctl stop nftables 2>/dev/null; then
    log "INFO" "Stopped nftables service"
    ui warn "nftables service stopped"
    return 0
  else
    log "ERROR" "Failed to stop nftables service"
    ui error "Failed to stop nftables service"
    return 1
  fi
}

enable_fail2ban_service()  { systemctl enable fail2ban 2>/dev/null; log "INFO" "Enabled Fail2Ban service"; }
disable_fail2ban_service() { systemctl disable fail2ban 2>/dev/null; log "INFO" "Disabled Fail2Ban service"; }

start_fail2ban_service() {
  if systemctl start fail2ban 2>/dev/null; then
    log "INFO" "Started Fail2Ban service"
    ui success "Fail2Ban service started"
    return 0
  else
    log "ERROR" "Failed to start Fail2Ban service"
    ui error "Failed to start Fail2Ban service"
    return 1
  fi
}

stop_fail2ban_service() {
  if systemctl stop fail2ban 2>/dev/null; then
    log "INFO" "Stopped Fail2Ban service"
    ui warn "Fail2Ban service stopped"
    return 0
  else
    log "ERROR" "Failed to stop Fail2Ban service"
    ui error "Failed to stop Fail2Ban service"
    return 1
  fi
}

restart_fail2ban_service() {
  if systemctl restart fail2ban 2>/dev/null; then
    log "INFO" "Restarted Fail2Ban service"
    ui success "Fail2Ban service restarted"
    return 0
  else
    log "ERROR" "Failed to restart Fail2Ban service"
    ui error "Failed to restart Fail2Ban service"
    return 1
  fi
}

# ------------------------------ Listing Functions -------------------------- #
list_rules() {
  ui title "Current nftables rules:"
  nft list ruleset
}

list_temp_bans() {
  ui title "Temporarily banned addresses"
  echo ""
  
  ui info "IPv4 (set: ${TEMP_BAN_SET_V4} in table ${TEMP_BAN_TABLE}):"
  local v4
  v4=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null)
  if [ -n "$v4" ]; then
    echo "$v4"
  else
    echo "None"
  fi
  
  echo ""
  ui info "IPv6 (set: ${TEMP_BAN_SET_V6} in table ${TEMP_BAN_TABLE}):"
  local v6
  v6=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null)
  if [ -n "$v6" ]; then
    echo "$v6"
  else
    echo "None"
  fi
}

# ------------------------------ Fail2Ban Functions ------------------------- #
view_fail2ban_jails() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    ui title "Available Fail2Ban jails:"
    fail2ban-client status | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'
    
    if [ -d "$FAIL2BAN_JAIL_DIR" ]; then
      echo ""
      ui info "NFTables-specific jails:"
      find "$FAIL2BAN_JAIL_DIR" -name "nftables-*.conf" -exec basename {} .conf \; | sed 's/^/  /'
    fi
  else
    ui error "Fail2Ban is not installed"
    return 1
  fi
}

view_fail2ban_rules() {
  local jail="$1"
  
  if [ -z "$jail" ]; then
    ui warn "Usage: nftban --fail2ban-rules <jail>"
    ui info "Available jails:"
    view_fail2ban_jails
    return 1
  fi
  
  if command -v fail2ban-client >/dev/null 2>&1; then
    ui title "Fail2Ban rules for jail '$jail':"
    fail2ban-client get "$jail" banip
  else
    ui error "Fail2Ban is not installed"
    return 1
  fi
}

view_fail2ban_banned() {
  local jail="$1"
  
  if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -n "$jail" ]; then
      ui title "Banned IPs in Fail2Ban jail '$jail':"
      fail2ban-client status "$jail" | grep "Banned IP list:" | sed 's/^.*Banned IP list://'
    else
      ui title "Banned IPs in all Fail2Ban jails:"
      for j in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
        echo ""
        ui info "Jail: $j"
        fail2ban-client status "$j" | grep "Banned IP list:" | sed 's/^.*Banned IP list://'
      done
    fi
  else
    ui error "Fail2Ban is not installed"
    return 1
  fi
}

view_all_banned() {
  ui title "All Banned IPs (Combined View)"
  echo ""
  
  ui warn "1. nftables temporary bans (IPv4):"
  local v4
  v4=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null)
  if [ -n "$v4" ]; then
    echo "$v4" | sed 's/^/  /'
  else
    echo "  None"
  fi
  
  echo ""
  ui warn "2. nftables temporary bans (IPv6):"
  local v6
  v6=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null)
  if [ -n "$v6" ]; then
    echo "$v6" | sed 's/^/  /'
  else
    echo "  None"
  fi
  
  echo ""
  ui warn "3. Permanent blacklist (IPv4):"
  if [ -f "$IPV4_BLACKLIST_FILE" ]; then
    grep -v '^#' "$IPV4_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $IPV4_BLACKLIST_FILE"
  fi
  
  echo ""
  ui warn "4. Permanent blacklist (IPv6):"
  if [ -f "$IPV6_BLACKLIST_FILE" ]; then
    grep -v '^#' "$IPV6_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $IPV6_BLACKLIST_FILE"
  fi
  
  echo ""
  ui warn "5. User blacklist:"
  if [ -f "$USER_BLACKLIST_FILE" ]; then
    grep -v '^#' "$USER_BLACKLIST_FILE" | sed 's/^/  /'
  else
    echo "  File not found: $USER_BLACKLIST_FILE"
  fi
  
  echo ""
  ui warn "6. Fail2Ban bans:"
  if command -v fail2ban-client >/dev/null 2>&1; then
    for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/^.*Jail list://' | tr ',' '\n' | sed 's/^ *//;s/ *$//'); do
      banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/^.*Banned IP list://')
      if [ -n "$banned_ips" ] && [ "$banned_ips" != " " ]; then
        echo "  Jail: $jail"
        echo "$banned_ips" | tr ' ' '\n' | sed 's/^/    /'
      fi
    done
  else
    echo "  Fail2Ban not installed"
  fi
}

# ------------------------------ Status & Info Functions -------------------- #
show_status() {
    ui title "nftban Status"
    echo ""
    
    ui info "System:"
    echo "  nftban path: $(dirname "$BASE_DIR")"
    echo "  Version: $VERSION"
    
    if command -v nft >/dev/null 2>&1; then
        echo "  nftables: $(nft --version 2>/dev/null | head -1)"
    else
        ui error "nft: not found"
    fi
    
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "  fail2ban: $(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')"
    else
        ui warn "fail2ban: not installed"
    fi
    
    if [ -f "/etc/systemd/system/nftban.service" ]; then
        ui success "systemd unit: present"
    else
        ui warn "systemd unit: not found (optional)"
    fi
    
    echo ""
    ui info "Services:"
    local nft_status=$(get_nftables_status)
    local f2b_status=$(get_fail2ban_status)
    
    if [ "$nft_status" = "active" ]; then
        ui success "nftables service: ACTIVE"
    else
        ui warn "nftables service: INACTIVE"
    fi
    
    if [ "$f2b_status" = "active" ]; then
        ui success "Fail2Ban service: ACTIVE"
    elif [ "$f2b_status" = "not installed" ]; then
        ui warn "Fail2Ban: NOT INSTALLED"
    else
        ui warn "Fail2Ban service: INACTIVE"
    fi
    
    echo ""
    ui info "nftables Table:"
    if nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
        ui success "Global table: exists"
        
        local temp_v4_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V4" 2>/dev/null | wc -l)
        local temp_v6_count=$(get_set_elements "$TEMP_BAN_TABLE" "$TEMP_BAN_SET_V6" 2>/dev/null | wc -l)
        
        echo "  Temp bans: ${temp_v4_count} IPv4, ${temp_v6_count} IPv6"
    else
        ui error "Global table: missing"
    fi
}

show_info() {
  local current_ip
  current_ip=$(get_current_login_ip)
  
  ui title "nftban Information"
  echo ""
  
  ui info "Current Session:"
  echo "  Login IP: $current_ip"
  
  if is_ip_whitelisted "$current_ip"; then
    ui lock "Allow status: WHITELISTED"
  else
    ui unlock "Allow status: NOT WHITELISTED"
  fi
  
  echo ""
  ui info "Service Status:"
  echo "  nftables: $(get_nftables_status)"
  echo "  Fail2Ban: $(get_fail2ban_status)"
  
  if nft list table inet "$TEMP_BAN_TABLE" >/dev/null 2>&1; then
    ui success "Global table: exists"
  else
    ui error "Global table: missing"
  fi
  
  echo ""
  ui info "Configuration Files:"
  echo "  User whitelist: $USER_WHITELIST_FILE"
  if [ -f "$USER_WHITELIST_FILE" ]; then
    echo "    Lines: $(grep -v '^#' "$USER_WHITELIST_FILE" | grep -c .)"
  else
    ui warn "    File not found"
  fi
  
  echo "  System whitelist: $SYSTEM_WHITELIST_FILE"
  if [ -f "$SYSTEM_WHITELIST_FILE" ]; then
    echo "    Lines: $(grep -v '^#' "$SYSTEM_WHITELIST_FILE" | grep -c .)"
  else
    ui warn "    File not found"
  fi
  
  echo ""
  echo "  Blacklist files:"
  for file in "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "$USER_BLACKLIST_FILE"; do
    if [ -f "$file" ]; then
      echo "    $(basename "$file"): $(grep -v '^#' "$file" | grep -c .) IPs"
    else
      echo "    $(basename "$file"): not found"
    fi
  done
  
  echo ""
  ui tip "Run 'nftban --validate-sync' to check if files match active sets"
}

# ------------------------------ Management Functions ----------------------- #
flush_rules() {
    ui warn "WARNING: This will remove ALL nftables rules!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if nft flush ruleset; then
            log "INFO" "nftables rules flushed"
            ui success "nftables rules flushed"
        else
            log "ERROR" "Failed to flush nftables rules"
            ui error "Failed to flush rules"
            return 1
        fi
    else
        ui info "Operation cancelled"
    fi
}

init_config() {
    ui step "Initializing nftables configuration..."
    
    local init_script="$SCRIPTS_DIR/nftban_init_nftables_conf.sh"
    
    if [ -f "$init_script" ]; then
        ui success "Found initialization script: $init_script"
        if [ -x "$init_script" ]; then
            "$init_script"
        else
            ui info "Making script executable and running..."
            chmod +x "$init_script"
            "$init_script"
        fi
    else
        ui error "Initialization script not found at: $init_script"
        ui warn "Please ensure nftban is properly installed"
        return 1
    fi
}

reload_config() {
    ui step "Reloading nftables configuration..."
    
    if [ -f "$CONF_FILE" ]; then
        if nft -f "$CONF_FILE"; then
            log "INFO" "nftables configuration reloaded from $CONF_FILE"
            ui success "nftables configuration reloaded"
        else
            log "ERROR" "Failed to reload nftables configuration from $CONF_FILE"
            ui error "Failed to reload nftables configuration"
            return 1
        fi
    else
        ui error "Configuration file not found: $CONF_FILE"
        ui tip "Run 'nftban init' to initialize configuration"
        return 1
    fi
}

show_config_dir() {
    ui title "Configuration Directory"
    echo ""
    
    ui info "Main directory: $BASE_DIR"
    
    if [ -d "$BASE_DIR" ]; then
        local count=0
        for file in "$BASE_DIR"/*.conf.local; do
            if [ -f "$file" ]; then
                local filename
                filename=$(basename "$file")
                local size
                size=$(wc -l < "$file" 2>/dev/null)
                echo "  - $filename ($size lines)"
                count=$((count + 1))
            fi
        done
        
        if [ $count -eq 0 ]; then
            ui warn "No configuration files found"
        else
            echo ""
            ui success "Found $count configuration file(s)"
        fi
    else
        ui error "Configuration directory does not exist"
        ui tip "Run 'nftban init' to initialize configuration"
    fi
    
    local templates_dir
    templates_dir="$(dirname "$BASE_DIR")/templates"
    if [ -d "$templates_dir" ]; then
        echo ""
        ui info "Available templates:"
        for template in "$templates_dir"/control-panels/*.conf; do
            if [ -f "$template" ]; then
                echo "  - $(basename "$template")"
            fi
        done
    fi
}

# ------------------------------ Enhanced Help ------------------------------ #
show_help() {
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════╗
║                    NFTBan v0.5.0-final - Help Guide                      ║
║              nftables & Fail2Ban Management Tool                         ║
╚══════════════════════════════════════════════════════════════════════════╝

USAGE
─────
  nftban [OPTION] [ARGUMENTS]

CORE SERVICE MANAGEMENT
───────────────────────
  -e, --enable          Enable and start nftables and Fail2Ban services
  -d, --disable         Disable and stop services
  -s, --start           Start services after config check
  -r, --restart         Restart services after config check
  -x, --stop            Stop services
  -c, --check           Check configuration syntax

IP MANAGEMENT
─────────────
  -a, --add-ip [IP]              Add IP to whitelist (current IP if omitted)
  -tb, --temp-ban IP [COMMENT]   Temporarily ban IP for 1 hour
  -pb, --perm-ban IP [COMMENT]   Permanently ban IP
  -rb, --remove-ban IP           Remove IP from all ban lists
  -ri, --remove-ip IP            Remove IP from all lists
  -i, --info                     Show current IP and system info

LISTING & VIEWING
─────────────────
  -l, --list            List current nftables rules
  -lt, --list-temp      List temporarily banned IPs
  -vb, --view-banned    View all banned IPs (comprehensive)
  --show-sets           Show contents of all nftables sets
  --verify-ip IP        Show where an IP exists in the system

VALIDATION & SYNC
─────────────────
  --validate-sync       Check if files match active nftables sets
  --sync                Reload nftables from configuration files
  --validate-config     Validate nftban configuration
  --backup              Backup current configuration

FAIL2BAN OPERATIONS
───────────────────
  -fj, --fail2ban-jails         View available Fail2Ban jails
  -fr, --fail2ban-rules JAIL    View Fail2Ban jail rules
  -fb, --fail2ban-banned [JAIL] View banned IPs in Fail2Ban
  -fc, --fail2ban-check         Check Fail2Ban configuration only

MANAGEMENT COMMANDS
───────────────────
  status                Show nftables and service status
  version, --version    Show version information
  flush                 Flush all nftables rules (WARNING!)
  init                  Initialize nftables configuration
  reload                Reload nftables configuration
  config                Show configuration directory

AUTO-UPDATE
───────────
  --enable-auto-update              Enable auto-update via cron
  --enable-auto-update --daily-time HH:MM  Enable with daily schedule
  --remove-auto-update              Disable auto-update
  --auto-update-status              Show auto-update status

STATISTICS & REPORTING
──────────────────────
  --stats, --statistics Show comprehensive statistics
  --packages            Show package health status
  --status --json       Output status in JSON format

OPERATION MODES
───────────────
  --dry-run             Test mode (no actual changes)
  --quiet               Suppress informational output
  --no-color            Disable colored output
  --enable-logging      Enable logging to file (default)
  --disable-logging     Disable logging to file

COMMON EXAMPLES
───────────────
  Add current login IP to whitelist:
    nftban --add-ip

  Temporarily ban an IP with note:
    nftban --temp-ban 203.0.113.9 "SSH brute-force attempt"

  Permanently ban an IP:
    nftban --perm-ban 2001:db8::dead:beef "Abusive client"

  Remove IP from everywhere:
    nftban --remove-ip 203.0.113.9

  Check where an IP exists:
    nftban --verify-ip 203.0.113.9

  Validate configuration sync:
    nftban --validate-sync

  Show comprehensive statistics:
    nftban --stats

  Enable auto-update (daily at 3:30 AM):
    nftban --enable-auto-update --daily-time "03:30"

  Test command without making changes:
    nftban --temp-ban 1.2.3.4 --dry-run

ENVIRONMENT VARIABLES
─────────────────────
  REQUIRE_F2B=true      Fail when Fail2Ban is missing or misconfigured
  ENABLE_LOGGING=false  Disable file logging

FILES & DIRECTORIES
───────────────────
  /etc/nftables.conf                                    Main nftables config
  /etc/nftban/config/*.conf.local                       User configurations
  /var/log/nftban/nftban.log                           Script log
  /etc/nftban/scripts/nftban_auto_update.sh            Auto-update script

EXIT CODES
──────────
  0  Success
  1  Generic failure
  2  No change (e.g., IP already present)

NOTES
─────
  • Whitelist IPs take priority over bans
  • Temporary bans expire after 1 hour
  • Permanent bans persist across reboots
  • Use --verify-ip to check IP status across all sources
  • Use --validate-sync before --sync to preview changes

For more information, visit: https://github.com/itcmsgr/nftban
EOF
  echo "  --sync-lists           Sync whitelist/blacklist files to nft sets"
  echo "  --sync-lists           Sync whitelist/blacklist files to nft sets"
  echo "  --sync-lists --dry-run  Show planned changes without applying"
  echo "  --export-lists         Export current nft sets back into files (backs up existing files)"
  echo "  --sync-lists                 Sync whitelist/blacklist files to nft sets"
  echo "  --sync-lists --dry-run        Show planned changes without applying"
  echo "  --export-lists               Export current nft sets back into files (backs up existing files)"
  echo "  --sync-source nft            Make files match nft (reverse sync; honors --dry-run)"
  echo "  --diff-lists                 Show adds/removes between files and nft"
  echo "  --diff-files-add             Show only items missing in files (to be added from nft)"
  echo "  --geo-sync              Apply country lists (files) to nft sets"
  echo "  --geo-provider ipdeny   Use ipdeny (default) for country CIDRs"
  echo "  --geo-ttl <hours>       Cache TTL for country CIDRs (default 24h)"
}

# ------------------------------ Main Logic -------------------------------- #
main() {
  setup_colors
  check_version
  
  local arg1="${1:-}"
  local arg2="${2:-}"
  local arg3="${3:-}"
  local arg4="${4:-}"
  
  # Handle special flags first
  case "$arg1" in
    --geo-ttl)
      shift; GEO_TTL_HOURS="${1:-24}"; return 0 ;;

    --geo-provider)
      shift; GEO_PROVIDER="${1:-ipdeny}"; return 0 ;;

    --geo-sync)
      geo_sync_countries; return $? ;;

    --diff-files-add)
      diff_files_add; return $? ;;

    --diff-lists)
      diff_lists; return $? ;;

    --sync-source)
      if [ "$arg2" = "nft" ]; then sync_nft_to_files; return $?; fi ;;

    --export-lists)
      export_all_lists_from_nft; return $? ;;

    --sync-lists)
      sync_all_lists_to_nft; return $? ;;

    --dry-run)
      DRY_RUN="true"
      shift
      arg1="${1:-}"
      arg2="${2:-}"
      arg3="${3:-}"
      ;;
    --quiet)
      QUIET="true"
      shift
      arg1="${1:-}"
      arg2="${2:-}"
      arg3="${3:-}"
      ;;
    --no-color)
      NO_COLOR="true"
      setup_colors
      shift
      arg1="${1:-}"
      arg2="${2:-}"
      arg3="${3:-}"
      ;;
  esac

  case "$arg1" in
    # Service management
    -e|--enable)
      backup_config
      if check_config; then
        enable_nftables_service
        enable_fail2ban_service
        start_nftables_service
        start_fail2ban_service
      else
        ui error "Configuration check failed, not enabling services"
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
        ui error "Configuration check failed, not starting services"
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
        ui error "Configuration check failed, not restarting services"
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
      
    # IP management
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
        ui error "Usage: nftban --temp-ban <IP> [COMMENT]"
        return 1
      fi
      ;;
    -pb|--perm-ban)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        perm_ban_ip "$arg2" "$arg3"
      else
        ui error "Usage: nftban --perm-ban <IP> [COMMENT]"
        return 1
      fi
      ;;
    -rb|--remove-ban|-ri|--remove-ip)
      if [ -n "$arg2" ] && is_ip_like "$arg2"; then
        remove_ip_from_all "$arg2"
      else
        ui error "Usage: nftban $arg1 <IP>"
        return 1
      fi
      ;;
    -lt|--list-temp)
      list_temp_bans
      ;;
      
    # Logging control
    --enable-logging)
      ENABLE_LOGGING=true
      ui success "Logging enabled"
      ;;
    --disable-logging)
      ENABLE_LOGGING=false
      ui warn "Logging disabled"
      ;;
      
    # Help
    -h|--help|help)
      show_help
      ;;
      
    # Version and status
    version|--version)
      show_version
      ;;
    status)
      if [ "$arg2" = "--json" ]; then
        print_json_status
      else
        show_status
      fi
      ;;
      
    # Management commands
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
    --validate-config)
      validate_config
      ;;
    --backup)
      backup_configs
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
      
    # Auto-update commands
    --enable-auto-update)
      if [ "$arg2" = "--daily-time" ] && [ -n "$arg3" ]; then
        DAILY_TIME="$arg3"
      fi
      setup_auto_update
      ;;
    --remove-auto-update)
      remove_auto_update
      ;;
    --auto-update-status)
      auto_update_status
      ;;
      
    # Statistics and reporting
    --stats|--statistics)
      show_statistics
      ;;
    --packages)
      show_package_status
      ;;
      
    # Fail2Ban operations
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