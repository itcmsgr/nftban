#!/usr/bin/env bash

# =============================================================================
# Script: nftban_init_fail2ban_conf.sh
#
# Version: 3.5  (Adds config validation, status, backup/restore, docs; fixes timer)
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
#actionban = nft add element inet temp_ban temp_ban_v4 { <ip> timeout <bantime> }
#
#actionunban = nft delete element inet temp_ban temp_ban_v4 { <ip> }

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
on_abort(){ rc=$?; echo "[$(ts)] Aborted (exit $rc)" >>"$LOGFILE"; exit "$rc"; }; trap 'on_abort' ERR INT

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
  echo "To use in a jail: action = ${MAIL_ACTION_NAME}[name=%(name)s, dest=$dest, sender=$sender]"
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
  local subj
  subj="[nftban-test] sendmail check on $(hostname -f)"
  local body
  body="This is a test message from nftban_init_fail2ban_conf.sh at $(date -R).
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
  # Global mode: use the unified nftban_global table
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"

  local global_table="nftban_global"

  # Verify table exists (should be created by nftban_init_nftables_conf.sh)
  if ! nft list table inet "$global_table" >/dev/null 2>&1; then
    die "Table inet $global_table not found. Run nftban_init_nftables_conf.sh first."
  fi

  # Verify sets exist
  nft list set inet "$global_table" temp_ban_v4 >/dev/null 2>&1 || \
    die "Set temp_ban_v4 not found in table $global_table. Run init script first."
  
  nft list set inet "$global_table" temp_ban_v6 >/dev/null 2>&1 || \
    die "Set temp_ban_v6 not found in table $global_table. Run init script first."

  log "Global nftables mode ready: inet $global_table with sets temp_ban_v4/temp_ban_v6"
}

# --- Global helper functions for idempotent add/remove -----------------------
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
      nft add element inet "$table" temp_ban_v6 "{ $ip timeout $to }"
    else
      nft add element inet "$table" temp_ban_v6 "{ $ip }"
    fi
  else
    if [[ -n "$to" ]]; then
      nft add element inet "$table" temp_ban_v4 "{ $ip timeout $to }"
    else
      nft add element inet "$table" temp_ban_v4 "{ $ip }"
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
    nft delete element inet "$table" temp_ban_v6 "{ $ip }" || true
  else
    nft delete element inet "$table" temp_ban_v4 "{ $ip }" || true
  fi
}
# -----------------------------------------------------------------------------

nft_ban_ip() {
  command -v nft >/dev/null 2>&1 || die "Missing command: nft"
  local jail ip to table
  jail="$1"
  ip="$2"
  to="${3:-${NFTBAN_F2B_DEF_BAN_TIME:-3600}}"
  table="nftban_${jail}"
  ensure_nft_for_jail "$jail"
  if [[ -f "$WHITELIST_FILE" ]] && grep -E -v '^\s*(#|$)' "$WHITELIST_FILE" | awk '{$1=$1};1' | grep -Fxq "$ip"; then log "SKIP ban (whitelisted): $ip (jail=$jail)"; return 0; fi
  to="$(fmt_timeout "$to")"
  if [[ "$ip" == *:* ]]; then nft_global_add_ip "$ip" "$to" || true
  else nft_global_add_ip "$ip" "$to" || true; fi
  echo "[$(ts)] jail=${jail} action=ban ip=${ip} timeout=${to}" >>"$LOGFILE_IP"
  log "Banned $ip in $table for $to"
}
nft_unban_ip() {
  local ip="$1"
  # Idempotent unban using the global helper
  nft_global_del_ip "$ip"
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
