#!/usr/bin/env bash

# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 3.6 (Enhanced with security, validation, dry-run, better mail testing)
# Author:  ITCMS Team (Antonios Voulvoulis) + Enhancements
#
# Description:
#   Comprehensive automation for Fail2Ban using the nftables backend.
#   Enhanced with security features, better validation, dry-run mode,
#   improved mail testing, backup rotation, and comprehensive status reporting.
#
# Usage Examples:
#   sudo ./nftban_init_fail2ban_conf.sh setup
#   sudo ./nftban_init_fail2ban_conf.sh status
#   sudo ./nftban_init_fail2ban_conf.sh self-test
#   sudo ./nftban_init_fail2ban_conf.sh test-mail admin@example.com
#   sudo ./nftban_init_fail2ban_conf.sh --dry-run setup
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================
readonly SCRIPT_VERSION="3.6"
readonly SCRIPT_NAME="$(basename "$0")"

# Paths
BASE_DIR="/etc/nftban"
LOGFILE="/var/log/nftban/nftban-setup.log"
LOGFILE_IP="/var/log/nftban/nftban-bans.log"
CONFIG_FILE="$BASE_DIR/config/nftban.conf"
CONFIG_FILE_USER="$BASE_DIR/config/nftban.conf.local"
TEMPLATE_DIR="$BASE_DIR/templates/fail2ban"
WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
BLACKLIST_FILE="$BASE_DIR/config/nftban-configuration-user-blacklist_ips.conf.local"
F2B_WHITELIST_FILE="$BASE_DIR/config/nftban-fail2ban-ip-whitelist.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/config/nftban-configuration-system_whitelist_ips.conf.local"

F2B_JAIL_DIR="/etc/fail2ban/jail.d"
F2B_FILTER_DIR="/etc/fail2ban/filter.d"
F2B_ACTION_DIR="/etc/fail2ban/action.d"
F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

MAIL_ACTION_NAME="NFTBAN_F2B_SENDMAIL.conf"
BACKUP_DIR="$BASE_DIR/backups"

# Login monitor files
LM_LIVE_BIN="/usr/local/sbin/nftban-login-monitor"
LM_SCAN_BIN="/usr/local/sbin/nftban-login-scan"
LM_LIVE_UNIT="/etc/systemd/system/nftban_lfd.service"
LM_SCAN_UNIT="/etc/systemd/system/nftban-login-scan.service"
LM_TIMER_UNIT="/etc/systemd/system/nftban-login-scan.timer"

# Limits & Timeouts
readonly SENDMAIL_TIMEOUT=10
readonly NFT_TIMEOUT=5
readonly BACKUP_RETENTION_DAYS=30
readonly MAX_BAN_RATE=10
readonly MAX_BACKUPS=50

# Global flags
DRY_RUN=false

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Rate limiting
declare -A BAN_TIMESTAMPS

# =============================================================================
# LOGGING & ERROR HANDLING
# =============================================================================
ts() { date -Is; }
log() { echo -e "[$(ts)] $*" | tee -a "$LOGFILE"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOGFILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOGFILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOGFILE" >&2; }
die() { log_error "$*"; exit 1; }

on_error() {
  local rc=$?
  local line=$1
  local bash_command="$2"
  
  log_error "Command failed with exit code $rc at line $line: $bash_command"
  
  if [[ -f "$LOGFILE" ]]; then
    echo "Recent log entries:" >&2
    tail -5 "$LOGFILE" >&2
  fi
  
  exit "$rc"
}

trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR INT

# =============================================================================
# DRY-RUN WRAPPER
# =============================================================================
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would execute: $*"
    return 0
  fi
  "$@"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================
ensure_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

validate_ip() {
  local ip="$1"
  
  # IPv4 validation
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
      ((octet > 255)) && return 1
    done
    return 0
  fi
  
  # IPv6 validation (basic)
  [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] && return 0
  
  return 1
}

sanitize_path() {
  local path="$1"
  local resolved
  resolved=$(readlink -f "$path" 2>/dev/null) || return 1
  [[ "$resolved" == "$BASE_DIR"* ]] || [[ "$resolved" == "/etc/fail2ban"* ]] || return 1
  echo "$resolved"
}

# =============================================================================
# BASIC HELPERS
# =============================================================================
mkdirp() { mkdir -p "$1"; }

init_dirs() {
  mkdirp "$BASE_DIR/config" "/var/log/nftban" "$F2B_JAIL_DIR" "$F2B_FILTER_DIR" "$F2B_ACTION_DIR" "$BACKUP_DIR"
  : > "$LOGFILE"
  touch "$LOGFILE_IP"
  : > "$WHITELIST_FILE"
  : > "$BLACKLIST_FILE"
  : > "$F2B_WHITELIST_FILE"
  : > "$SYSTEM_WHITELIST_FILE"
}

backup_jail_local() {
  if [[ -f "$F2B_JAIL_LOCAL" ]]; then
    local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
    run_cmd mv -f "$F2B_JAIL_LOCAL" "${F2B_JAIL_LOCAL}_${tsf}"
    log "Backed up $F2B_JAIL_LOCAL -> ${F2B_JAIL_LOCAL}_${tsf}"
  fi
}

# =============================================================================
# BASE CONFIG (CANONICAL REFERENCE)
# =============================================================================
canonical_base_config() {
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
NFTBAN_F2B_DEF_BAN_TIME="3600"
NFTBAN_F2B_DEF_FIND_TIME="600"
NFTBAN_F2B_DEF_MAX_RETRY="5"
NFTBAN_F2B_BACKEND="systemd"

# Enhanced Security
NFTBAN_F2B_AGGRESSIVE_MODE="false"
NFTBAN_F2B_GEOIP_ENABLE="true"
NFTBAN_F2B_WHOIS_ENABLE="true"

# Login Monitoring Settings
NFTBAN_F2B_LOGIN_MONITOR="true"
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_SSH_LOGIN_ALERT="false"
NFTBAN_F2B_FAILED_LOGIN_THRESHOLD="5"

# Jail Configurations
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
NFTBAN_F2B_IGNOREIP="$BASE_DIR/config/nftban-fail2ban-ip-whitelist.conf.local"
EOF
}

refresh_base_config() {
  ensure_root
  install -d -m 0755 "$BASE_DIR/config"
  local tmp; tmp="$(mktemp)"
  canonical_base_config >"$tmp"
  
  if [[ ! -f "$CONFIG_FILE" ]]; then
    run_cmd install -m 0644 -o root -g root "$tmp" "$CONFIG_FILE"
    log "Wrote reference base config: $CONFIG_FILE"
  else
    local cnew cold
    cnew="$(sha256sum "$tmp" | awk '{print $1}')"
    cold="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    if [[ "$cnew" != "$cold" ]]; then
      local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
      run_cmd cp -a "$CONFIG_FILE" "${CONFIG_FILE}.${tsf}.bak"
      run_cmd install -m 0644 -o root -g root "$tmp" "$CONFIG_FILE"
      log "Updated reference base config (backup: ${CONFIG_FILE}.${tsf}.bak)"
    else
      log "Reference base config is up to date."
    fi
  fi
  rm -f "$tmp"
}

# =============================================================================
# CONFIG COMPARE & LOAD
# =============================================================================
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
  echo "=== Config Comparison ==="
  echo "Base:  $CONFIG_FILE"
  echo "Local: $CONFIG_FILE_USER (user-owned)"
  echo
  
  local missing=() diffs=() extra=()
  
  for k in "${!BASE_KV[@]}"; do
    if [[ -z "${USER_KV[$k]+x}" ]]; then
      missing+=("$k")
    elif [[ "${USER_KV[$k]}" != "${BASE_KV[$k]}" ]]; then
      diffs+=("$k|BASE='${BASE_KV[$k]}'|USER='${USER_KV[$k]}'")
    fi
  done
  
  for k in "${!USER_KV[@]}"; do
    [[ -z "${BASE_KV[$k]+x}" ]] && extra+=("$k|USER='${USER_KV[$k]}'")
  done

  if ((${#missing[@]})); then
    echo "MISSING in .local (consider adding):"
    for k in "${missing[@]}"; do echo "  - $k"; done
  else
    echo "✅ No missing keys."
  fi
  
  echo
  
  if ((${#diffs[@]})); then
    echo "DIFFERENT values (override ok):"
    for row in "${diffs[@]}"; do
      IFS='|' read -r key b u <<<"$row"
      echo "  - $key"
      echo "      $b"
      echo "      $u"
    done
  else
    echo "✅ No differing values."
  fi
  
  echo
  
  if ((${#extra[@]})); then
    echo "EXTRA in .local (not in base):"
    for row in "${extra[@]}"; do
      IFS='|' read -r key u <<<"$row"
      echo "  - $key  ($u)"
    done
  else
    echo "✅ No extra keys."
  fi
}

load_config_env() {
  # Validate syntax before sourcing
  if [[ -f "$CONFIG_FILE" ]]; then
    if ! bash -n "$CONFIG_FILE" 2>/dev/null; then
      die "Syntax error in $CONFIG_FILE"
    fi
  fi
  
  if [[ -f "$CONFIG_FILE_USER" ]]; then
    if ! bash -n "$CONFIG_FILE_USER" 2>/dev/null; then
      die "Syntax error in $CONFIG_FILE_USER"
    fi
  fi
  
  set -a
  # shellcheck disable=SC1090
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
  # shellcheck disable=SC1090
  [[ -f "$CONFIG_FILE_USER" ]] && source "$CONFIG_FILE_USER"
  set +a
  
  log "Configuration loaded (base + .local overrides)."
}

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================
validate_config() {
  local errors=()

  # Email validation
  if [[ -n "${NFTBAN_F2B_RECIPIENT:-}" ]] && ! [[ "$NFTBAN_F2B_RECIPIENT" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
    errors+=("Invalid email format: NFTBAN_F2B_RECIPIENT='$NFTBAN_F2B_RECIPIENT'")
  fi
  
  if [[ -n "${NFTBAN_F2B_SENDER:-}" ]] && ! [[ "$NFTBAN_F2B_SENDER" =~ ^[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+$ ]]; then
    errors+=("Sender should look like an email address: NFTBAN_F2B_SENDER='$NFTBAN_F2B_SENDER'")
  fi

  # Numeric validation
  local numeric_vars=(
    NFTBAN_F2B_DEF_BAN_TIME NFTBAN_F2B_DEF_FIND_TIME NFTBAN_F2B_DEF_MAX_RETRY
    NFTBAN_F2B_SSH_BAN_TIME NFTBAN_F2B_SSH_MAX_RETRY NFTBAN_F2B_SSH_FIND_TIME
    NFTBAN_F2B_APACHE_BAN_TIME NFTBAN_F2B_APACHE_MAX_RETRY
    NFTBAN_F2B_NGINX_BAN_TIME NFTBAN_F2B_NGINX_MAX_RETRY
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
    log_error "Configuration validation errors:"
    printf '  - %s\n' "${errors[@]}" | tee -a "$LOGFILE"
    return 1
  fi
  
  log_info "Configuration validated OK."
  return 0
}

# =============================================================================
# JAILS & TEMPLATES
# =============================================================================
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
  if [[ ! -f "$dst" ]]; then
    run_cmd install -m 0644 -o root -g root "$src" "$dst"
    echo "CREATED"
    return 0
  fi
  
  local csrc cdst msrc mdst tsf
  csrc="$(file_checksum "$src")"; cdst="$(file_checksum "$dst")"
  msrc="$(file_mtime "$src")";   mdst="$(file_mtime "$dst")"
  
  if [[ "$csrc" != "$cdst" ]] || (( msrc > mdst )); then
    tsf="$(date +%Y%m%d-%H%M%S)"
    run_cmd cp -a "$dst" "${dst}.${tsf}.bak"
    run_cmd install -m 0644 -o root -g root "$src" "$dst"
    echo "UPDATED"
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
    for f in "${tmpls[@]}"; do
      [[ -f "$f" ]] || { any_missing=1; missing+=("$jail:$f"); }
    done
    
    if (( any_missing )); then
      log_warn "Jail '$jail' templates incomplete. Skipping copy."
      continue
    fi
    
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
  
  [[ ${#created[@]}   -gt 0 ]] && { log_info "Created:";   printf '  - %s\n' "${created[@]}"; }
  [[ ${#updated[@]}   -gt 0 ]] && { log_info "Updated:";   printf '  - %s\n' "${updated[@]}"; }
  [[ ${#uptodate[@]}  -gt 0 ]] && { log "Up-to-date:"; printf '  - %s\n' "${uptodate[@]}"; }
  [[ ${#missing[@]}   -gt 0 ]] && { log_warn "Missing templates:"; printf '  - %s\n' "${missing[@]}"; }
  
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "All enabled jails have complete templates staged."
  else
    log_warn "Some enabled jails are missing templates."
  fi
}

# =============================================================================
# MAIL DETECTION & TESTING (ENHANCED)
# =============================================================================
detect_sendmail() {
  for p in /usr/sbin/sendmail /usr/lib/sendmail /usr/bin/sendmail /usr/sbin/exim /usr/sbin/msmtp; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
  return 1
}

detect_mailx() {
  for p in /usr/bin/mail /bin/mail; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  echo ""
  return 1
}

check_mail() {
  echo "=== Mail System Check ==="
  
  local sendmail_path; sendmail_path="$(detect_sendmail)"
  if [[ -n "$sendmail_path" ]]; then
    echo -e "${GREEN}✅${NC} Sendmail-compatible MTA found: $sendmail_path"
    
    # Check if it's actually executable
    if [[ -x "$sendmail_path" ]]; then
      echo -e "${GREEN}✅${NC} Binary is executable"
    else
      echo -e "${RED}✗${NC} Binary found but not executable"
    fi
    
    # Try to identify the MTA
    if command -v postfix &>/dev/null; then
      echo "   MTA: Postfix detected"
    elif command -v exim &>/dev/null; then
      echo "   MTA: Exim detected"
    elif command -v msmtp &>/dev/null; then
      echo "   MTA: MSMTP detected"
    fi
  else
    echo -e "${RED}✗${NC} No sendmail-compatible MTA detected"
    echo "   Install options:"
    echo "   - apt install postfix (Debian/Ubuntu)"
    echo "   - dnf install postfix (RHEL/Fedora)"
    echo "   - apk add postfix (Alpine)"
    echo "   - apt install msmtp-mta (lightweight alternative)"
  fi
  
  local mailx_path; mailx_path="$(detect_mailx)"
  if [[ -n "$mailx_path" ]]; then
    echo -e "${GREEN}✅${NC} Mailx found: $mailx_path"
  else
    echo -e "${YELLOW}⚠${NC}  Mailx not found (optional)"
  fi
  
  echo
  load_config_env 2>/dev/null || true
  echo "Configured recipient: ${NFTBAN_F2B_RECIPIENT:-not set}"
  echo "Configured sender: ${NFTBAN_F2B_SENDER:-not set}"
}

test_mail() {
  echo "=== Enhanced Mail Test ==="
  
  load_config_env 2>/dev/null || true
  local rcpt="${1:-${NFTBAN_F2B_RECIPIENT:-root@localhost}}"
  local sender="${NFTBAN_F2B_SENDER:-nftban@$(hostname -f)}"
  
  echo "Testing email delivery..."
  echo "  From: $sender"
  echo "  To:   $rcpt"
  echo
  
  # Try all available sendmail paths
  local sendmail_paths=(
    "/usr/sbin/sendmail"
    "/usr/lib/sendmail"
    "/usr/bin/sendmail"
    "/usr/sbin/exim"
    "/usr/sbin/msmtp"
  )
  
  local found=false
  local tested=0
  
  for sm in "${sendmail_paths[@]}"; do
    if [[ ! -x "$sm" ]]; then
      continue
    fi
    
    found=true
    tested=$((tested + 1))
    
    echo "Testing with: $sm"
    
    local subj="[nftban-test] Mail test from $(hostname -f) at $(date +%Y-%m-%d\ %H:%M:%S)"
    local body="This is a test message from nftban_init_fail2ban_conf.sh

Timestamp: $(date -R)
Hostname: $(hostname -f)
Sender: $sender
Recipient: $rcpt
MTA Path: $sm

If you receive this message, your mail system is working correctly.

---
NFTBAN v${SCRIPT_VERSION}
"
    
    # Create email message
    local msg
    msg="From: $sender
To: $rcpt
Subject: $subj

$body"
    
    # Test with timeout
    if timeout "$SENDMAIL_TIMEOUT" bash -c "echo '$msg' | '$sm' -t -oi" 2>&1; then
      local ec=$?
      if [[ $ec -eq 0 ]]; then
        echo -e "${GREEN}✅ SUCCESS${NC}: Test mail submitted via $sm"
        echo
        echo "Next steps:"
        echo "  1. Check $rcpt mailbox for the test message"
        echo "  2. Check mail logs: tail -f /var/log/mail.log"
        echo "  3. If not received, check spam folder"
        return 0
      else
        echo -e "${RED}✗ FAILED${NC}: Sendmail exited with code $ec"
      fi
    else
      echo -e "${RED}✗ FAILED${NC}: Timeout or error"
    fi
    
    echo
  done
  
  if [[ "$found" == "false" ]]; then
    echo -e "${RED}✗ No sendmail-compatible MTA found${NC}"
    echo
    echo "To enable email alerts, install an MTA:"
    echo "  • Postfix (recommended): apt install postfix"
    echo "  • Exim: apt install exim4"
    echo "  • MSMTP (lightweight): apt install msmtp-mta"
    echo
    echo "After installation, run this test again."
    return 2
  elif [[ $tested -eq 0 ]]; then
    echo -e "${RED}✗ Sendmail binaries found but not executable${NC}"
    return 2
  else
    echo -e "${RED}✗ All mail delivery attempts failed${NC}"
    echo
    echo "Troubleshooting:"
    echo "  1. Check MTA service: systemctl status postfix"
    echo "  2. Check mail logs: tail -f /var/log/mail.log"
    echo "  3. Test manually: echo 'test' | sendmail -v $rcpt"
    return 1
  fi
}

generate_mail_action() {
  local dest="${NFTBAN_F2B_RECIPIENT:-root@localhost}"
  local sender="${NFTBAN_F2B_SENDER:-nftban@$(hostname -f)}"
  local prefix="[nftban]"
  local sendmail_path; sendmail_path="$(detect_sendmail)"
  local action_file="$F2B_ACTION_DIR/$MAIL_ACTION_NAME"
  local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
  
  [[ -f "$action_file" ]] && run_cmd cp -a "$action_file" "${action_file}.${tsf}.bak"
  
  if [[ -n "$sendmail_path" ]]; then
    cat >"$action_file" <<EOF
# $MAIL_ACTION_NAME - Autogenerated by nftban_init_fail2ban_conf.sh
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
    run_cmd chmod 0644 "$action_file"
    log_info "Wrote $action_file (active via $sendmail_path)"
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
    run_cmd chmod 0644 "$action_file"
    log_warn "Wrote $action_file (NO-OP: no MTA)"
    echo "⚠️  No sendmail-compatible MTA found. Install postfix/exim/msmtp for email alerts."
  fi
}

# =============================================================================
# FAIL2BAN GLOBAL NFT ACTION & DEFAULTS
# =============================================================================
generate_nftban_global_action() {
  local action_file="$F2B_ACTION_DIR/nftban-global.conf"
  install -d -m 0755 "$F2B_ACTION_DIR"
  local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
  [[ -f "$action_file" ]] && run_cmd cp -a "$action_file" "${action_file}.${tsf}.bak"
  
  cat >"$action_file" <<'EOF'
# nftban-global.conf – Enforce bans via global nftables sets
[Definition]
actionstart =
actionstop   =
actioncheck  = /usr/sbin/nft list table inet nftban_global
actionban    = /usr/sbin/nft add element inet nftban_global temp_ban_v4 { <ip> timeout <bantime> } || true
               /usr/sbin/nft add element inet nftban_global temp_ban_v6 { <ip> timeout <bantime> } || true
actionunban  = /usr/sbin/nft delete element inet nftban_global temp_ban_v4 { <ip> } || true
               /usr/sbin/nft delete element inet nftban_global temp_ban_v6 { <ip> } || true
[Init]
EOF
  run_cmd chmod 0644 "$action_file"
  log "Wrote $action_file"
}

write_nftban_defaults() {
  local defaults_file="$F2B_JAIL_DIR/00-nftban.conf"
  install -d -m 0755 "$F2B_JAIL_DIR"
  local tsf; tsf="$(date +%Y%m%d-%H%M%S)"
  [[ -f "$defaults_file" ]] && run_cmd cp -a "$defaults_file" "${defaults_file}.${tsf}.bak"
  
  cat >"$defaults_file" <<EOF
[DEFAULT]
banaction = nftban-global
ignoreip  = file:${F2B_WHITELIST_FILE}
EOF
  run_cmd chmod 0644 "$defaults_file"
  log "Wrote $defaults_file"
}

build_fail2ban_whitelist() {
  install -d -m 0755 "$(dirname "$F2B_WHITELIST_FILE")"
  : > "$F2B_WHITELIST_FILE"
  
  for f in "$SYSTEM_WHITELIST_FILE" "$WHITELIST_FILE"; do
    [[ -f "$f" ]] || continue
    grep -v '^\s*#' "$f" | awk '{print $1}' | sed '/^\s*$/d' >> "$F2B_WHITELIST_FILE"
  done
  
  sort -u -o "$F2B_WHITELIST_FILE" "$F2B_WHITELIST_FILE"
  log "Fail2Ban whitelist built: $F2B_WHITELIST_FILE"
}

# =============================================================================
# NFTABLES HELPERS
# =============================================================================
fmt_timeout() {
  local t="$1"
  if [[ "$t" =~ ^[0-9]+$ ]]; then echo "${t}s"
  elif [[ "$t" =~ ^[0-9]+[smhd]$ ]]; then echo "$t"
  else echo "${t}s"; fi
}

verify_nft_setup() {
  local table="nftban_global"
  local issues=()
  
  if ! nft list table inet "$table" &>/dev/null; then
    issues+=("Table 'inet $table' not found")
  fi
  
  for set in temp_ban_v4 temp_ban_v6; do
    if ! nft list set inet "$table" "$set" &>/dev/null; then
      issues+=("Set '$set' not found in table '$table'")
    fi
  done
  
  if ((${#issues[@]} > 0)); then
    log_error "NFTables verification failed:"
    printf '  ✗ %s\n' "${issues[@]}"
    return 1
  fi
  
  return 0
}

ensure_nft_for_jail() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  
  local global_table="nftban_global"
  
  if ! nft list table inet "$global_table" >/dev/null 2>&1; then
    die "Table inet $global_table not found. Run nftban_init_nftables_conf.sh first."
  fi
  
  nft list set inet "$global_table" temp_ban_v4 >/dev/null 2>&1 || \
    die "Set temp_ban_v4 not found. Run init script first."
  
  nft list set inet "$global_table" temp_ban_v6 >/dev/null 2>&1 || \
    die "Set temp_ban_v6 not found. Run init script first."
  
  log "Global nftables mode ready"
}

nft_global_ip_in_set() {
  local ip="$1"
  local table="nftban_global"
  if [[ "$ip" == *:* ]]; then
    nft get element inet "$table" temp_ban_v6 "{ $ip }" >/dev/null 2>&1
  else
    nft get element inet "$table" temp_ban_v4 "{ $ip }" >/dev/null 2>&1
  fi
}

nft_global_add_ip() {
  local ip="$1"
  local to="${2:-}"
  local table="nftban_global"
  
  ensure_nft_for_jail "_ignored_"
  
  if nft_global_ip_in_set "$ip"; then
    log "nft: already present: $ip"
    return 0
  fi
  
  if [[ "$ip" == *:* ]]; then
    if [[ -n "$to" ]]; then
      run_cmd nft add element inet "$table" temp_ban_v6 "{ $ip timeout $to }"
    else
      run_cmd nft add element inet "$table" temp_ban_v6 "{ $ip }"
    fi
  else
    if [[ -n "$to" ]]; then
      run_cmd nft add element inet "$table" temp_ban_v4 "{ $ip timeout $to }"
    else
      run_cmd nft add element inet "$table" temp_ban_v4 "{ $ip }"
    fi
  fi
}

nft_global_del_ip() {
  local ip="$1"
  local table="nftban_global"
  
  if ! nft_global_ip_in_set "$ip"; then
    log "nft: not present (skip delete): $ip"
    return 0
  fi
  
  if [[ "$ip" == *:* ]]; then
    run_cmd nft delete element inet "$table" temp_ban_v6 "{ $ip }" || true
  else
    run_cmd nft delete element inet "$table" temp_ban_v4 "{ $ip }" || true
  fi
}

check_ban_rate_limit() {
  local now; now=$(date +%s)
  local minute_ago=$((now - 60))
  
  # Clean old entries
  for ts in "${!BAN_TIMESTAMPS[@]}"; do
    ((ts < minute_ago)) && unset "BAN_TIMESTAMPS[$ts]"
  done
  
  # Check limit
  if ((${#BAN_TIMESTAMPS[@]} >= MAX_BAN_RATE)); then
    log_warn "Rate limit exceeded: ${#BAN_TIMESTAMPS[@]} bans in last minute"
    return 1
  fi
  
  BAN_TIMESTAMPS[$now]=1
  return 0
}

nft_ban_ip() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  
  local jail ip to
  jail="$1"
  ip="$2"
  to="${3:-${NFTBAN_F2B_DEF_BAN_TIME:-3600}}"
  
  # Validate IP
  validate_ip "$ip" || die "Invalid IP address: $ip"
  
  # Rate limiting
  check_ban_rate_limit || {
    log_warn "Skipping ban due to rate limit: $ip"
    return 1
  }
  
  ensure_nft_for_jail "$jail"
  
  # Check whitelist
  if [[ -f "$WHITELIST_FILE" ]] && grep -E -v '^\s*(#|$)' "$WHITELIST_FILE" | awk '{$1=$1};1' | grep -Fxq "$ip"; then
    log "SKIP ban (whitelisted): $ip (jail=$jail)"
    return 0
  fi
  
  to="$(fmt_timeout "$to")"
  nft_global_add_ip "$ip" "$to" || true
  
  echo "[$(ts)] jail=${jail} action=ban ip=${ip} timeout=${to}" >>"$LOGFILE_IP"
  log_info "Banned $ip for $to"
}

nft_unban_ip() {
  local ip="$1"
  validate_ip "$ip" || die "Invalid IP address: $ip"
  nft_global_del_ip "$ip"
  echo "[$(ts)] action=unban ip=${ip}" >>"$LOGFILE_IP"
  log_info "Unbanned $ip"
}

# =============================================================================
# LOGIN MONITOR
# =============================================================================
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
    """Enhanced email sending with multiple MTA support and better error handling"""
    debug_log(f"Attempting to send email: {subj} to {dest}")
    
    sendmail_paths = [
        "/usr/sbin/sendmail",
        "/usr/lib/sendmail",
        "/usr/bin/sendmail",
        "/usr/sbin/exim",
        "/usr/sbin/msmtp"
    ]
    
    for p in sendmail_paths:
        if not (os.path.exists(p) and os.access(p, os.X_OK)):
            continue
            
        try:
            debug_log(f"Trying sendmail at: {p}")
            proc=subprocess.Popen(
                [p,"-t","-oi"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            msg=f"From: {sender}\nTo: {dest}\nSubject: {subj}\n\n{body}\n"
            stdout, stderr = proc.communicate(msg, timeout=10)
            
            if proc.returncode==0:
                debug_log(f"Email sent successfully via {p}")
                return True
            else:
                debug_log(f"Sendmail failed (code {proc.returncode}): {stderr}")
                
        except subprocess.TimeoutExpired:
            proc.kill()
            debug_log(f"Sendmail timeout at {p}")
        except Exception as e:
            debug_log(f"Exception with {p}: {e}")
            
    debug_log("All sendmail attempts failed")
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

    debug_log(f"Config - recipient: {recipient}, root_alert: {root_alert}")

    fails=collections.defaultdict(list)
    last_alert={}

    rx_acc=re.compile(r"Accepted (?:password|publickey|keyboard-interactive/pam|gssapi-with-mic) for (\S+) from ([0-9A-Fa-f\.:]+)", re.IGNORECASE)
    rx_fail=re.compile(r"Failed (?:password|publickey|keyboard-interactive/pam|gssapi-with-mic) for (?:invalid user )?(\S+) from ([0-9A-Fa-f\.:]+)", re.IGNORECASE)
    rx_sudo=re.compile(r"sudo:?\s+(\S+)\s*:.*(?:COMMAND=|command:)\s*(.*)$", re.IGNORECASE)
    rx_root_session=re.compile(r"session opened for user root", re.IGNORECASE)
    rx_su_root=re.compile(r"su:.*session opened for user root", re.IGNORECASE)
    rx_su_user=re.compile(r"su:.*session opened for user (\S+)", re.IGNORECASE)

    try:
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
            log(f"Failed login: user={user}, ip={ip}, total={len(fails[ip])}")

            if len(fails[ip]) >= thresh and (ip not in last_alert or t-last_alert[ip] > window):
                subj = f"{prefix} Failed login threshold from {ip} ({len(fails[ip])}/{thresh})"
                body = f"IP: {ip}\nAttempts: {len(fails[ip])}\nUser: {user}\nTime: {datetime.datetime.now()}\n"

                if send_mail(subj, body, sender, recipient):
                    log(f"Alert sent for {ip}")
                else:
                    log(f"Failed to send alert for {ip}")

                last_alert[ip] = t

                if aggressive:
                    try:
                        subprocess.run(["/usr/local/sbin/nftban_init_fail2ban_conf.sh","ban","ssh",ip,str(ban_sec)],
                                     check=False, timeout=8)
                        log(f"Auto-banned {ip}")
                    except Exception as e:
                        log(f"Auto-ban failed for {ip}: {e}")
            continue

        m = rx_acc.search(l)
        if m:
            user, ip = m.group(1), m.group(2)
            log(f"Successful login: user={user}, ip={ip}")

            if (user=="root" and root_alert) or ssh_alert:
                subj = f"{prefix} SSH login: {user} from {ip}"
                body = f"User: {user}\nIP: {ip}\nTime: {datetime.datetime.now()}\nLog: {l}\n"

                if send_mail(subj, body, sender, recipient):
                    log(f"Alert sent for SSH login: {user}@{ip}")
            continue

        if root_alert and (rx_root_session.search(l) or rx_su_root.search(l)):
            subj = f"{prefix} root session opened"
            body = f"Time: {datetime.datetime.now()}\nLog: {l}\n"
            send_mail(subj, body, sender, recipient)
            continue

        if sudo_alert:
            m = rx_sudo.search(l)
            if m:
                who, cmd = m.group(1), m.group(2)
                log(f"Sudo usage: user={who}, command={cmd}")
                subj = f"{prefix} sudo used by {who}"
                body = f"User: {who}\nCommand: {cmd}\nTime: {datetime.datetime.now()}\n"
                send_mail(subj, body, sender, recipient)

if __name__=="__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Login monitor stopped")
        sys.exit(0)
    except Exception as e:
        log(f"Login monitor crashed: {e}")
        sys.exit(1)
PY
  run_cmd chmod 0755 "$LM_LIVE_BIN"
  
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
        body.append(""); body.append("SSH logins (sample):")
        for (u,ip,line) in ssh_logins[:10]: body.append(f"  {u} from {ip}")
    send_mail(f"{prefix} digest", "\n".join(body), sender, recipient); return 0
if __name__=="__main__": sys.exit(run())
PY
  run_cmd chmod 0755 "$LM_SCAN_BIN"
  
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
  run_cmd systemctl daemon-reload
  log_info "Login monitor files installed."
}

login_monitor_enable() {
  local mode="${1:-}"; [[ -z "$mode" ]] && die "login-monitor enable requires <service|timer|hybrid>"
  case "$mode" in
    service) run_cmd systemctl enable --now "$(basename "$LM_LIVE_UNIT")" ;;
    timer)   run_cmd systemctl enable --now "$(basename "$LM_TIMER_UNIT")" ;;
    hybrid)  run_cmd systemctl enable --now "$(basename "$LM_LIVE_UNIT")" "$(basename "$LM_TIMER_UNIT")" ;;
    *) die "Unknown mode: $mode" ;;
  esac
  log_info "Enabled login monitor ($mode)."
}

login_monitor_disable() {
  local mode="${1:-all}"
  case "$mode" in
    service) run_cmd systemctl disable --now "$(basename "$LM_LIVE_UNIT")" || true ;;
    timer)   run_cmd systemctl disable --now "$(basename "$LM_TIMER_UNIT")" || true ;;
    hybrid|all)
      run_cmd systemctl disable --now "$(basename "$LM_LIVE_UNIT")" || true
      run_cmd systemctl disable --now "$(basename "$LM_TIMER_UNIT")" || true
      ;;
    *) die "Unknown mode: $mode" ;;
  esac
  log_info "Disabled login monitor ($mode)."
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
  run_cmd systemctl stop nftban_lfd.service nftban-login-scan.service nftban-login-scan.timer 2>/dev/null || true
  run_cmd systemctl disable nftban_lfd.service nftban-login-scan.timer 2>/dev/null || true
  run_cmd systemctl reset-failed nftban_lfd.service nftban-login-scan.service nftban-login-scan.timer 2>/dev/null || true
  pkill -f '/usr/local/sbin/nftban-login-monitor' 2>/dev/null || true
  run_cmd rm -f "$LM_LIVE_UNIT" "$LM_SCAN_UNIT" "$LM_TIMER_UNIT" "$LM_LIVE_BIN" "$LM_SCAN_BIN"
  run_cmd systemctl daemon-reload
  log_info "Login monitor removed."
}

ensure_local_config() {
  if [[ ! -f "$CONFIG_FILE_USER" ]]; then
    run_cmd install -D -m 0644 -o root -g root "$CONFIG_FILE" "$CONFIG_FILE_USER"
    log_info "Created user config: $CONFIG_FILE_USER"
    echo ""
    echo "Next steps:"
    echo "  1) Edit $CONFIG_FILE_USER"
    echo "  2) Run: $SCRIPT_NAME setup"
    echo ""
    exit 0
  fi
}

# =============================================================================
# ENHANCED STATUS REPORTING
# =============================================================================
show_system_status() {
  echo "╔═══════════════════════════════════════╗"
  echo "║     NFTBAN System Status Report      ║"
  echo "╚═══════════════════════════════════════╝"
  echo
  
  # Configuration
  echo -e "${BLUE}📁 Configuration:${NC}"
  echo "  Base:  $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo "✓" || echo "✗")"
  echo "  Local: $CONFIG_FILE_USER $([ -f "$CONFIG_FILE_USER" ] && echo "✓" || echo "✗")"
  
  if load_config_env &>/dev/null && validate_config &>/dev/null; then
    echo -e "  Status: ${GREEN}✅ Valid${NC}"
  else
    echo -e "  Status: ${YELLOW}⚠️  Issues detected${NC} (run 'validate-config')"
  fi
  echo
  
  # Jails
  echo -e "${BLUE}🔒 Enabled Jails:${NC}"
  local jail_count=0
  while read -r jail; do
    [[ -n "$jail" ]] || continue
    ((jail_count++))
    local status="❓"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
      if fail2ban-client status "$jail" &>/dev/null 2>&1; then
        status="${GREEN}✅${NC}"
      else
        status="${YELLOW}⚠️${NC}"
      fi
    fi
    echo -e "  $status $jail"
  done < <(enabled_jails)
  [[ $jail_count -eq 0 ]] && echo "  (none configured)"
  echo
  
  # Services
  echo -e "${BLUE}🔧 Services:${NC}"
  for svc in fail2ban nftban_lfd nftban-login-scan.timer; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo -e "  ${GREEN}✅${NC} $svc (active)"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      echo -e "  ${YELLOW}⏸️${NC}  $svc (enabled but inactive)"
    else
      echo -e "  ${RED}❌${NC} $svc (disabled)"
    fi
  done
  echo
  
  # NFTables
  echo -e "${BLUE}🛡️  NFTables:${NC}"
  if verify_nft_setup &>/dev/null; then
    echo -e "  ${GREEN}✅${NC} Global table configured"
    local v4_count v6_count
    v4_count=$(nft list set inet nftban_global temp_ban_v4 2>/dev/null | grep -o 'elements = {[^}]*}' | grep -o '[0-9.:]' | wc -l || echo "0")
    v6_count=$(nft list set inet nftban_global temp_ban_v6 2>/dev/null | grep -o 'elements = {[^}]*}' | grep -o '[0-9.:]' | wc -l || echo "0")
    echo "  📊 Active bans: IPv4≈$v4_count, IPv6≈$v6_count"
  else
    echo -e "  ${YELLOW}⚠️${NC}  Not properly configured"
  fi
  echo
  
  # Recent activity
  echo -e "${BLUE}📜 Recent Bans (last 5):${NC}"
  if [[ -f "$LOGFILE_IP" ]]; then
    tail -n 5 "$LOGFILE_IP" 2>/dev/null | sed 's/^/  /' || echo "  (no bans logged)"
  else
    echo "  (log file not found)"
  fi
  echo
  
  # Disk usage
  echo -e "${BLUE}💾 Storage:${NC}"
  du -sh "$BASE_DIR" 2>/dev/null | awk '{print "  Total: " $1}' || true
  du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print "  Backups: " $1}' || true
  echo
  
  # Last setup
  if [[ -f "$LOGFILE" ]]; then
    local last_setup
    last_setup=$(grep -i "setup complete\|Setup complete" "$LOGFILE" 2>/dev/null | tail -1 | awk '{print $1, $2}')
    echo "⏱️  Last setup: ${last_setup:-never}"
  fi
}

show_ban_stats() {
  echo "=== Ban Statistics ==="
  
  if [[ ! -f "$LOGFILE_IP" ]]; then
    echo "No ban log found"
    return
  fi
  
  echo
  echo "Top 10 Banned IPs:"
  awk '{print $5}' "$LOGFILE_IP" | grep -oE 'ip=[^ ]+' | cut -d= -f2 | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "  %3d  %s\n", $1, $2}'
  
  echo
  echo "Bans by Jail:"
  awk '{print $3}' "$LOGFILE_IP" | grep -oE 'jail=[^ ]+' | cut -d= -f2 | \
    sort | uniq -c | sort -rn | \
    awk '{printf "  %3d  %s\n", $1, $2}'
  
  echo
  echo "Ban Timeline (last 7 days):"
  awk '
    {
      match($0, /\[([^\]]+)\]/, arr)
      cmd = "date -d \"" arr[1] "\" +%Y-%m-%d 2>/dev/null"
      cmd | getline day
      close(cmd)
      if (day) days[day]++
    }
    END {
      for (d in days) print "  " d ": " days[d]
    }
  ' "$LOGFILE_IP" | sort
}

# =============================================================================
# BACKUP / RESTORE WITH ROTATION
# =============================================================================
rotate_backups() {
  local max_backups=${1:-$MAX_BACKUPS}
  
  [[ -d "$BACKUP_DIR" ]] || return 0
  
  local count
  count=$(find "$BACKUP_DIR" -name "nftban-config-*.tar.gz" 2>/dev/null | wc -l)
  
  if ((count > max_backups)); then
    log_warn "Found $count backups (max: $max_backups), rotating..."
    
    find "$BACKUP_DIR" -name "nftban-config-*.tar.gz" -type f -printf '%T+ %p\n' | \
      sort | head -n $((count - max_backups)) | cut -d' ' -f2- | \
      while read -r old_backup; do
        run_cmd rm -f "$old_backup"
        log "Deleted old backup: $old_backup"
      done
  fi
  
  # Delete old backups
  find "$BACKUP_DIR" -name "nftban-config-*.tar.gz" -type f -mtime "+$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
}

backup_config() {
  install -d -m 0755 "$BACKUP_DIR"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local archive="$BACKUP_DIR/nftban-config-$ts.tar.gz"
  
  tar -czf "$archive" -C "$(dirname "$CONFIG_FILE_USER")" \
      "$(basename "$CONFIG_FILE_USER")" \
      "$(basename "$WHITELIST_FILE")" \
      "$(basename "$BLACKLIST_FILE")" 2>/dev/null || true
  
  rotate_backups
  
  log_info "Configuration backed up to: $archive"
  echo "$archive"
}

list_backups() {
  [[ -d "$BACKUP_DIR" ]] || { echo "No backups found."; return 1; }
  ls -1ht "$BACKUP_DIR"/nftban-config-*.tar.gz 2>/dev/null || echo "No backups found."
}

restore_config() {
  local src="${1:-}"
  [[ -n "$src" ]] || die "restore-config requires </path/to/archive.tar.gz>"
  [[ -f "$src" ]] || die "Archive not found: $src"
  
  local tmp; tmp="$(mktemp -d)"
  tar -xzf "$src" -C "$tmp"
  
  run_cmd install -D -m 0644 -o root -g root "$tmp/$(basename "$CONFIG_FILE_USER")" "$CONFIG_FILE_USER" 2>/dev/null || true
  [[ -f "$tmp/$(basename "$WHITELIST_FILE")" ]] && run_cmd install -D -m 0644 -o root -g root "$tmp/$(basename "$WHITELIST_FILE")" "$WHITELIST_FILE"
  [[ -f "$tmp/$(basename "$BLACKLIST_FILE")" ]] && run_cmd install -D -m 0644 -o root -g root "$tmp/$(basename "$BLACKLIST_FILE")" "$BLACKLIST_FILE"
  
  rm -rf "$tmp"
  log_info "Configuration restored from: $src"
}

# =============================================================================
# DOCUMENTATION GENERATION
# =============================================================================
generate_config_docs() {
  install -d -m 0755 "$BASE_DIR"
  cat > "$BASE_DIR/CONFIG_REFERENCE.md" <<'DOC'
# NFTBAN Configuration Reference

## Email Settings
- `NFTBAN_F2B_RECIPIENT` – Recipient for alerts
- `NFTBAN_F2B_SENDER` – From address for alerts
- `NFTBAN_F2B_ALERT_ENABLED` – Enable/disable email alerts

## Default Settings
- `NFTBAN_F2B_DEF_BAN_TIME` – Default ban duration (seconds)
- `NFTBAN_F2B_DEF_FIND_TIME` – Failure window (seconds)
- `NFTBAN_F2B_DEF_MAX_RETRY` – Max retries in window
- `NFTBAN_F2B_BACKEND` – Backend type (systemd/polling)

## Security & Monitoring
- `NFTBAN_F2B_AGGRESSIVE_MODE` – Auto-ban on threshold
- `NFTBAN_F2B_LOGIN_MONITOR` – Enable login monitoring
- `NFTBAN_F2B_ROOT_LOGIN_ALERT` – Alert on root logins
- `NFTBAN_F2B_SUDO_ALERT` – Alert on sudo usage
- `NFTBAN_F2B_SSH_LOGIN_ALERT` – Alert on all SSH logins
- `NFTBAN_F2B_FAILED_LOGIN_THRESHOLD` – Failed login threshold

## Jails
Set `*_JAIL="true"` to enable:
- SSH / Apache / Nginx / Postfix / WordPress / XMLRPC / DirectAdmin

Each jail has: `*_BAN_TIME`, `*_MAX_RETRY`, `*_FIND_TIME`

## File Locations
- Config: `/etc/nftban/config/nftban.conf.local`
- Whitelist: `/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local`
- Blacklist: `/etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local`
DOC
  log_info "Configuration reference written to $BASE_DIR/CONFIG_REFERENCE.md"
}

# =============================================================================
# SELF-TEST
# =============================================================================
run_self_test() {
  echo "=== NFTBAN Self-Test ==="
  local failed=0
  
  # Root check
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗${NC} Must run as root"
    ((failed++))
  else
    echo -e "${GREEN}✅${NC} Running as root"
  fi
  
  # Required commands
  for cmd in nft fail2ban-client systemctl; do
    if command -v "$cmd" &>/dev/null; then
      echo -e "${GREEN}✅${NC} Command found: $cmd"
    else
      echo -e "${RED}✗${NC} Missing command: $cmd"
      ((failed++))
    fi
  done
  
  # Directory permissions
  for dir in "$BASE_DIR" "/var/log/nftban" "/etc/fail2ban"; do
    if [[ -d "$dir" && -w "$dir" ]]; then
      echo -e "${GREEN}✅${NC} Directory writable: $dir"
    else
      echo -e "${RED}✗${NC} Directory issue: $dir"
      ((failed++))
    fi
  done
  
  # Config syntax
  if [[ -f "$CONFIG_FILE_USER" ]]; then
    if bash -n "$CONFIG_FILE_USER" 2>/dev/null; then
      echo -e "${GREEN}✅${NC} Config syntax valid"
    else
      echo -e "${RED}✗${NC} Config syntax error"
      ((failed++))
    fi
  fi
  
  # NFTables
  if verify_nft_setup &>/dev/null; then
    echo -e "${GREEN}✅${NC} NFTables configured"
  else
    echo -e "${YELLOW}⚠️${NC}  NFTables not configured"
  fi
  
  # MTA
  if [[ -n "$(detect_sendmail)" ]]; then
    echo -e "${GREEN}✅${NC} Mail system detected"
  else
    echo -e "${YELLOW}⚠️${NC}  No mail system"
  fi
  
  echo
  if ((failed == 0)); then
    echo -e "${GREEN}✅ All critical tests passed${NC}"
    return 0
  else
    echo -e "${RED}✗ $failed test(s) failed${NC}"
    return 1
  fi
}

# =============================================================================
# HIGH-LEVEL FLOWS
# =============================================================================
setup_all() {
  ensure_root
  init_dirs
  refresh_base_config
  ensure_local_config
  show_config_diff || true
  load_config_env
  validate_config || die "Configuration validation failed"
  build_fail2ban_whitelist
  generate_nftban_global_action
  write_nftban_defaults
  verify_and_stage_templates
  generate_mail_action
  
  # Verify NFTables (non-fatal)
  if ! verify_nft_setup; then
    log_warn "NFTables not properly configured. Run nftban_init_nftables_conf.sh first."
  fi
  
  log_info "Setup complete (non-invasive)."
  echo ""
  echo "Next steps:"
  echo "  • Review config: $CONFIG_FILE_USER"
  echo "  • Test mail: $SCRIPT_NAME test-mail"
  echo "  • Check status: $SCRIPT_NAME status"
  echo "  • Enable services manually if desired"
}

# =============================================================================
# CLI & HELP
# =============================================================================
usage() {
  cat <<USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION} - Fail2Ban + nftables automation

Quick Start:
  sudo $SCRIPT_NAME setup

Config & Validation:
  $SCRIPT_NAME diff-config          - Compare base vs local config
  $SCRIPT_NAME validate-config      - Validate configuration
  $SCRIPT_NAME gen-docs             - Generate documentation

Status & Monitoring:
  $SCRIPT_NAME status               - Show system status
  $SCRIPT_NAME stats                - Show ban statistics
  $SCRIPT_NAME self-test            - Run system tests

Mail Testing:
  $SCRIPT_NAME check-mail           - Check mail system
  $SCRIPT_NAME test-mail [email]    - Send test email
  $SCRIPT_NAME generate-mail-action - Generate mail action

Backup & Restore:
  $SCRIPT_NAME backup-config        - Backup configuration
  $SCRIPT_NAME list-backups         - List backups
  $SCRIPT_NAME restore-config <file> - Restore from backup

Login Monitor:
  $SCRIPT_NAME login-monitor install
  $SCRIPT_NAME login-monitor enable <service|timer|hybrid>
  $SCRIPT_NAME login-monitor disable [mode]
  $SCRIPT_NAME login-monitor status
  $SCRIPT_NAME login-monitor uninstall

Manual NFTables (not run by 'setup'):
  $SCRIPT_NAME nft-init <jail>      - Initialize NFT for jail
  $SCRIPT_NAME ban <jail> <ip> [time] - Ban IP
  $SCRIPT_NAME unban <ip>           - Unban IP

Global Options:
  --dry-run                         - Show what would be done

Examples:
  sudo $SCRIPT_NAME setup
  sudo $SCRIPT_NAME test-mail admin@example.com
  sudo $SCRIPT_NAME ban ssh 192.168.1.100 1h
  sudo $SCRIPT_NAME --dry-run setup
USAGE
}

main() {
  # Parse global flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h|help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done
  
  local cmd="${1:-}"; shift || true
  
  case "${cmd:-}" in
    "") usage ;;
    setup) setup_all ;;
    diff-config) show_config_diff ;;
    validate-config) load_config_env; validate_config && echo -e "${GREEN}✅ Configuration is valid${NC}" ;;
    gen-docs) generate_config_docs ;;
    status) show_system_status ;;
    stats) show_ban_stats ;;
    self-test|test) run_self_test ;;
    
    backup-config) backup_config ;;
    list-backups) list_backups ;;
    restore-config) restore_config "${1:-}" ;;
    
    check-mail) check_mail ;;
    test-mail|mail-test) test_mail "$@" ;;
    generate-mail-action) load_config_env; generate_mail_action ;;
    
    nft-init) [[ $# -eq 1 ]] || die "nft-init requires <jail>"; ensure_nft_for_jail "$1" ;;
    ban) [[ $# -ge 2 ]] || die "ban requires <jail> <ip> [timeout]"; load_config_env; nft_ban_ip "$1" "$2" "${3:-}" ;;
    unban) [[ $# -eq 1 ]] || die "unban requires <ip>"; nft_unban_ip "$1" ;;
    
    login-monitor)
      local sub="${1:-}"; shift || true
      case "${sub:-}" in
        install) login_monitor_install ;;
        enable) login_monitor_enable "${1:-}" ;;
        disable) login_monitor_disable "${1:-all}" ;;
        status) login_monitor_status ;;
        uninstall) login_monitor_uninstall ;;
        ""|-h|--help) echo "login-monitor {install|enable|disable|status|uninstall}" ;;
        *) die "Unknown login-monitor subcommand: $sub" ;;
      esac
      ;;
    
    *) die "Unknown command: $cmd (use --help)" ;;
  esac
}

main "$@"
