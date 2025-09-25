#!/usr/bin/env bash


# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 3.1  (Enhanced with Login Monitoring)
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
#   • Updates configs with any missing settings while PRESERVING existing values
#     (especially email-related fields). A backup is created before changes.
#   • Can recreate all jails/filters/actions from templates while keeping your
#     custom values in the *.local file.
#
# Key Changes:
#   • More informative messages on create/update.
#   • Clear guidance to edit nftban.conf.local for customizations.
#   • --recreate behavior exposed via `setup` and template staging.
#
# Usage Examples:
#   # Refresh base config, stage templates, diff vs .local (non-invasive to services)
#   sudo ./nftban_init_fail2ban_conf.sh setup
#
#   # Install login monitor files (does NOT auto-enable)
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor install
#
#   # Enable login monitor:
#   #   live service only (short name: nftban_lfd.service)
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor enable service
#   #   timer-based digest only
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor enable timer
#   #   both live + timer
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor enable hybrid
#
#   # Check / control status
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor status
#   sudo ./nftban_init_fail2ban_conf.sh login-monitor disable [service|timer|hybrid|all]
#
#   # Manual nftables helpers (never auto-run)
#   sudo ./nftban_init_fail2ban_conf.sh nft-init <jail>
#   sudo ./nftban_init_fail2ban_conf.sh ban <jail> <ip> [seconds|Ns|Nm|Nh|Nd]
#   sudo ./nftban_init_fail2ban_conf.sh unban <jail> <ip>
#
# Notes:
#   • Live login monitor unit: nftban_lfd.service
#   • Scan service & timer remain: nftban-login-scan.service / nftban-login-scan.timer
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
  mkdirp "$BASE_DIR/config" "/var/log/nftban" "$F2B_JAIL_DIR" "$F2B_FILTER_DIR" "$F2B_ACTION_DIR"
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
    # Only replace if different
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
  # Source base first, then user overrides. Both may use $BASE_DIR and $(...) expansions.
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
  # Load config (sender/recipient); allow overriding recipient via arg.
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
# Login monitor (live + timer) — install/enable/disable/status/uninstall
# -----------------------------
write_login_monitor_live() {
  install -d -m 0755 /usr/local/sbin /var/log/nftban
  cat >"$LM_LIVE_BIN" <<'PY'
#!/usr/bin/env python3
import os, re, sys, time, subprocess, datetime, collections
BASE_CONF="/etc/nftban/config/nftban.conf"
LOCAL_CONF="/etc/nftban/config/nftban.conf.local"
LOG_DIR="/var/log/nftban"; LOG_FILE=os.path.join(LOG_DIR,"login-monitor.log")
os.makedirs(LOG_DIR, exist_ok=True)
def log(m):
    ts=datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat()
    line=f"[{ts}] {m}"; print(line, flush=True)
    try: open(LOG_FILE,"a").write(line+"\n")
    except Exception: pass
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
            except Exception as e: return False
    return False
def main():
    cfg={}; cfg.update(parse_conf(BASE_CONF)); cfg.update(parse_conf(LOCAL_CONF))
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
    fails=collections.defaultdict(list); last_alert={}
    rx_acc=re.compile(r"Accepted (?:password|publickey|keyboard-interactive/pam) for (\S+) from ([0-9A-Fa-f\.:]+)")
    rx_fail=re.compile(r"Failed password for (?:invalid user )?(\S+) from ([0-9A-Fa-f\.:]+)")
    rx_sudo=re.compile(r"sudo:?\s+(\S+)\s*:.*COMMAND=(.*)$")
    rx_root=re.compile(r"session opened for user root")
    try:
        proc=subprocess.Popen(["journalctl","-f","-n","0","-o","cat","-t","sshd","-t","sudo","-u","ssh","-u","sshd","-u","sudo"],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    except FileNotFoundError:
        return 1
    def prune(ip,t): fails[ip][:]=[x for x in fails[ip] if t-x<=window]
    while True:
        line=proc.stdout.readline()
        if not line:
            time.sleep(0.2)
            if proc.poll() is not None: break
            continue
        l=line.strip(); 
        if not l: continue
        t=time.time()
        m=rx_fail.search(l)
        if m:
            user,ip=m.group(1),m.group(2); prune(ip,t); fails[ip].append(t)
            if len(fails[ip])>=thresh and (ip not in last_alert or t-last_alert[ip]>window):
                subj=f"{prefix} Failed login threshold from {ip} ({len(fails[ip])}/{thresh})"
                body=f"IP: {ip}\nAttempts (last {window}s): {len(fails[ip])}\nLast user: {user}\n"
                send_mail(subj, body, sender, recipient); last_alert[ip]=t
                if aggressive:
                    try: subprocess.run(["/usr/local/sbin/nftban_init_fail2ban_conf.sh","ban","ssh",ip,str(ban_sec)],check=False,timeout=8)
                    except Exception: pass
            continue
        m=rx_acc.search(l)
        if m:
            user,ip=m.group(1),m.group(2)
            if (user=="root" and root_alert) or ssh_alert:
                send_mail(f"{prefix} SSH login: {user} from {ip}", f"Line: {l}\n", sender, recipient)
            continue
        if root_alert and rx_root.search(l):
            send_mail(f"{prefix} root session opened", f"Line: {l}\n", sender, recipient); continue
        if sudo_alert:
            m=rx_sudo.search(l)
            if m:
                who,cmd=m.group(1),m.group(2)
                send_mail(f"{prefix} sudo used by {who}", f"Command: {cmd}\nLine: {l}\n", sender, recipient)
                continue
if __name__=="__main__": sys.exit(main())
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
        out=subprocess.check_output(["journalctl","-o","cat","--since",since_arg,"-t","sshd","-t","sudo","-u","ssh","-u","sshd","-u","sudo"], text=True, stderr=subprocess.DEVNULL)
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
  rm -f "$LM_LIVE_UNIT" "$LM_SCAN_UNIT" "$LM_TIMER_UNIT"
  rm -f "$LM_LIVE_BIN" "$LM_SCAN_BIN"
  systemctl daemon-reload
  echo "Login monitor removed. Logs/state preserved."
}


ensure_local_config() {
  # If user's local config doesn't exist yet, copy the freshly refreshed base and stop.
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
# High-level flows
# -----------------------------
setup_all() {
  ensure_root
  init_dirs
  refresh_base_config           # <-- always ensure reference base is current
  ensure_local_config           # <-- create .local from base on first run, then stop
  backup_jail_local             # move /etc/fail2ban/jail.local out of the way (if any)
  show_config_diff || true      # inform user about missing/different/extra in .local
  load_config_env               # base + .local
  verify_and_stage_templates    # copy templates if missing or template is newer/different
  generate_mail_action          # write portable sendmail action (no-op if no MTA)
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
    If it doesn't exist, the script creates it from the reference and STOPS, so you can edit it,
    then rerun 'setup'. Otherwise, .local is NEVER modified. The script reports any keys missing vs the reference.

Quick start:
  sudo nftban_init_fail2ban_conf.sh setup

Config tools:
  nftban_init_fail2ban_conf.sh setup               # refresh base config, validate, stage templates, generate mail action
  nftban_init_fail2ban_conf.sh check-mail          # detect MTA and advise
  nftban_init_fail2ban_conf.sh test-mail [rcpt]    # send a test email via detected sendmail
  nftban_init_fail2ban_conf.sh diff-config         # show missing/different/extra keys (base vs .local)

Login monitor (pick a mode):
  nftban_init_fail2ban_conf.sh login-monitor install
  nftban_init_fail2ban_conf.sh login-monitor enable service   # live alerts
  nftban_init_fail2ban_conf.sh login-monitor enable timer     # periodic digest (10m default)
  nftban_init_fail2ban_conf.sh login-monitor enable hybrid    # both
  nftban_init_fail2ban_conf.sh login-monitor status
  nftban_init_fail2ban_conf.sh login-monitor disable [service|timer|hybrid|all]
  nftban_init_fail2ban_conf.sh login-monitor uninstall

nftables (manual only; NOT run by 'setup'):
  nftban_init_fail2ban_conf.sh nft-init <jail>
  nftban_init_fail2ban_conf.sh ban <jail> <ip> [seconds|Ns|Nm|Nh|Nd]
  nftban_init_fail2ban_conf.sh unban <jail> <ip>

Notes:
  • Template naming per enabled jail var (e.g. NFTBAN_F2B_SSH_JAIL.conf) in:
      $TEMPLATE_DIR/jail.d, $TEMPLATE_DIR/filter.d, $TEMPLATE_DIR/action.d
  • Mail action written to: $F2B_ACTION_DIR/$MAIL_ACTION_NAME
  • For email alerts, install a sendmail-compatible MTA (postfix/exim/msmtp/nullmailer).
  • This script never starts Fail2ban or creates nftables tables during 'setup'.
  • Login monitor works independently of Fail2ban/nftables; it only auto-bans if you set NFTBAN_F2B_AGGRESSIVE_MODE="true".

USAGE
}

main() {
  local cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    --help|-h|help|"") usage ;;
    setup) setup_all ;;
    diff-config) show_config_diff ;;
    check-mail) check_mail ;;
    test-mail|mail-test) test_mail "$@" ;;
    generate-mail-action) load_config_env; generate_mail_action ;;
    nft-init) [[ $# -eq 1 ]] || die "nft-init requires <jail>"; ensure_nft_for_jail "$1" ;;
    ban) [[ $# -ge 2 ]] || die "ban requires <jail> <ip> [timeout]"; load_config_env; nft_ban_ip "$1" "$2" "${3:-${NFTBAN_F2B_DEF_BAN_TIME:-3600}}" ;;
    unban) [[ $# -eq 2 ]] || die "unban requires <jail> <ip>"; nft_unban_ip "$1" "$2" ;;
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
