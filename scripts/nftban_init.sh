#!/usr/bin/env bash
set -euo pipefail

################################################################################
# nftban Unified Installation & Maintenance Script
#
# Version: 3.0.3
# Description: Comprehensive nftban installer with enhanced functionality
# Features:
# - GitHub repository sync with fallback ZIP download
# - Installs nftables, fail2ban, whois, and DNS utilities
# - Enhanced control panel detection (DirectAdmin, cPanel, Plesk, generic)
# - Complete directory structure and configuration templates
# - Comprehensive uninstall functionality with purge options
# - No automatic service start/enable (manual control)
# - Package manager support: apt, dnf, yum, zypper, apk
# - Auto-update functionality with cron scheduling
# - Enhanced status reporting with JSON output
# - Dry-run mode and quiet operation support
#
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
#
# Usage:
#   sudo ./nftban_init.sh [options]
#
# Quick start examples:
#   sudo ./nftban_init.sh --github -y
#   sudo ./nftban_init.sh --zip -y --target /etc/nftban
#   sudo ./nftban_init.sh --github -y --enable-auto-update
#   sudo ./nftban_init.sh --remove-auto-update
#   sudo ./nftban_init.sh --uninstall --purge -y
#   sudo ./nftban_init.sh --status --json
################################################################################

# --- Versioning & Auto-update -------------------------------------------------
VERSION="3.0.3"
VERSION_FILE="/etc/nftban/.version"
AUTO_UPDATE_SCRIPT="/etc/nftban/scripts/nftban_auto_update.sh"
AUTO_UPDATE_ENABLED="false"
DO_REMOVE_AUTO_UPDATE="false"
DO_AUTO_UPDATE_STATUS="false"
DO_STATUS="false"
JSON_MODE="false"
DRY_RUN="false"
QUIET="false"

# --- UI Preferences (for friendlier output) ---
BEGINNER_MODE="false"
NO_COLOR="false"
UNICODE_ICONS="true"

# --- Defaults / Paths ---------------------------------------------------------
REPO_URL="https://github.com/itcmsgr/nftban"
ZIP_URL="https://github.com/itcmsgr/nftban/archive/refs/heads/main.zip"
BRANCH="main"
TARGET_DIR="/etc/nftban"
LOG_DIR="/var/log/nftban"
LOGFILE="$LOG_DIR/nftban_init_$(date +%Y-%m-%d-%H%M%S).log"
WORK_DIR=""
ASSUME_Y="false"
FORCE_FLOW=""
DO_UNINSTALL="false"
DO_PURGE="false"
SKIP_CP_DETECT="false"
DAILY_TIME=""

# Package names
FAIL2BAN_PKG="fail2ban"
WHOIS_PKG="whois"
DNSUTILS_PKG=""
IPCALC_PKG="ipcalc"
SIPCALC_PKG="sipcalc"

umask 022

# --- Enhanced Logging & Utility Functions -------------------------------------
log() {
  local lvl="${1:-INFO}"; shift || true
  local msg="$*"
  mkdir -p "$(dirname "$LOGFILE")"
  local line
  line=$(printf "[%s] %s %s\n" "$lvl" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg")
  echo "$line" >> "$LOGFILE"
  if [[ "${QUIET:-false}" == "true" && "$lvl" == "INFO" ]]; then
    return
  fi
  echo "$line" >&2
}

die() { log "ERROR" "$*"; exit 1; }

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT

# --- Friendly UI helpers (colors & icons) ---
setup_colors() {
  if [[ "$NO_COLOR" == "true" || ! -t 2 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET="";
  else
    RED="[31m"; GREEN="[32m"; YELLOW="[33m"; BLUE="[34m"; BOLD="[1m"; RESET="[0m";
  fi
  if [[ "$UNICODE_ICONS" == "true" ]]; then
    ICON_INFO="ℹ️"; ICON_OK="✅"; ICON_WARN="⚠️"; ICON_ERR="❌"; ICON_STEP="👉"; ICON_TIP="💡";
  else
    ICON_INFO="[i]"; ICON_OK="[ok]"; ICON_WARN="[!]"; ICON_ERR="[x]"; ICON_STEP="->"; ICON_TIP="(*)";
  fi
}
ui() {
  local kind="${1:-info}"; shift || true; local msg="$*"
  case "$kind" in
    title)   echo -e "${BOLD}${BLUE}${msg}${RESET}";;
    info)    echo -e "${BLUE}${ICON_INFO} ${msg}${RESET}";;
    success) echo -e "${GREEN}${ICON_OK} ${msg}${RESET}";;
    warn)    echo -e "${YELLOW}${ICON_WARN} ${msg}${RESET}";;
    error)   echo -e "${RED}${ICON_ERR} ${msg}${RESET}";;
    step)    echo -e "${BOLD}${ICON_STEP} ${msg}${RESET}";;
    tip)     echo -e "${ICON_TIP} ${msg}";;
    *)       echo "$msg";;
  esac
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    ui error "Administrator rights are required to run this installer."
    echo "Try: sudo $0 [options]" >&2
    exit 1
  fi
}

run_cmd() {
  # Accept a single command string; avoid 'eval' (SC2294).
  # Usage: run_cmd "apt-get update && apt-get install -y pkg1 pkg2"
  local cmd="$*"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log INFO "DRY-RUN: $cmd"
    return 0
  fi
  bash -c "$cmd"
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "$ASSUME_Y" == "true" ]]; then return 0; fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- Package Manager Detection & Helpers -------------------------------------
PKG_TOOL=""
PKG_INSTALL=""

pkg_install() {
  case "${PKG_TOOL:-}" in
    apt-get) apt-get update -y >/dev/null && apt-get install -y "$@";;
    dnf)     dnf install -y "$@";;
    yum)     yum install -y "$@";;
    zypper)  zypper --non-interactive install -y "$@";;
    apk)     apk add --no-cache "$@";;
    *)       die "Unsupported package tool (${PKG_TOOL:-unset})";;
  esac
}

pkg_present() { command -v "$1" >/dev/null 2>&1; }

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_TOOL="apt-get";   PKG_INSTALL="apt-get update && apt-get install -y"; DNSUTILS_PKG="dnsutils"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_TOOL="dnf";       PKG_INSTALL="dnf install -y";  DNSUTILS_PKG="bind-utils"
  elif command -v yum >/dev/null 2>&1; then
    PKG_TOOL="yum";       PKG_INSTALL="yum install -y";  DNSUTILS_PKG="bind-utils"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_TOOL="zypper";    PKG_INSTALL="zypper install -y"; DNSUTILS_PKG="bind-utils"
  elif command -v apk >/dev/null 2>&1; then
    PKG_TOOL="apk";       PKG_INSTALL="apk add --no-cache"; DNSUTILS_PKG="bind-tools"
  else
    die "Supported package manager not found (apt/dnf/yum/zypper/apk)."
  fi
}

ensure_tools() {
  detect_pm
  local missing=()
  for t in "$@"; do
    if ! pkg_present "$t"; then missing+=("$t"); fi
  done
  if (( ${#missing[@]} > 0 )); then
    log INFO "Installing missing tools: ${missing[*]}"
    case "$PKG_TOOL" in
      apt-get)   run_cmd "$PKG_INSTALL ${missing[*]}" ;;
      dnf|yum|zypper|apk) run_cmd "$PKG_INSTALL ${missing[*]}" ;;
      *)         die "Unsupported package tool (${PKG_TOOL:-unset})";;
    esac
  fi
}

# --- Prompts & OS helpers -----------------------------------------------------
ask_yes_no() {
  local prompt="$1"; local def="${2:-Y}"
  if [[ "$ASSUME_Y" == "true" ]]; then
    [[ "$def" =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  local suffix="[Y/n]"; [[ "$def" =~ ^[Nn]$ ]] && suffix="[y/N]"
  local ans
  while true; do
    read -r -p "$prompt $suffix " ans
    ans="${ans:-$def}"
    case "$ans" in
      Y|y|yes|YES) return 0;;
      N|n|no|NO)   return 1;;
      *) echo "Please answer y or n.";;
    esac
  done
}

get_os_release_var() {
  local var="$1"
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  eval "echo \"\${$var:-}\""
}

is_rhel_like() {
  [[ "${PKG_TOOL:-}" == "dnf" || "${PKG_TOOL:-}" == "yum" ]] && return 0
  local id_like; id_like="$(get_os_release_var ID_LIKE || true)"
  [[ "$id_like" == *rhel* || "$id_like" == *fedora* || "$id_like" == *centos* ]]
}

# --- EPEL (RHEL-like) ---------------------------------------------------------
install_epel_if_needed() {
  detect_pm
  if ! is_rhel_like; then return 0; fi
  log INFO "RHEL-like system detected - checking EPEL repository"
  if rpm -q epel-release >/dev/null 2>&1; then
    log INFO "EPEL repository already installed"
    return 0
  fi
  if [[ "$ASSUME_Y" == "true" ]] || ask_yes_no "EPEL repository is not installed. Do you want to install it?" "Y"; then
    log INFO "Installing EPEL repository..."
    if pkg_install epel-release >/dev/null 2>&1; then
      log INFO "EPEL repository installed successfully"
      return 0
    else
      ensure_tools curl
      local ver major url
      ver="$(get_os_release_var VERSION_ID || echo "")"
      major="${ver%%.*}"; [[ -z "$major" ]] && major="9"
      url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
      log INFO "Falling back to direct EPEL RPM: $url"
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install "$url" >/dev/null 2>&1 || die "Failed to install EPEL from $url"
      elif command -v yum >/dev/null 2>&1; then
        yum -y install "$url" >/dev/null 2>&1 || die "Failed to install EPEL from $url"
      else
        die "Cannot install EPEL: neither dnf nor yum available."
      fi
    fi
  else
    die "EPEL repository is required for fail2ban installation. Exiting..."
  fi
}

# --- Package installation -----------------------------------------------------
# --- Package installation -----------------------------------------------------
install_packages() {
  detect_pm
  log INFO "Starting package installation using $PKG_TOOL"
  if [[ "$PKG_TOOL" == "apt-get" ]]; then
    log INFO "Updating package cache..."
    apt-get update -y >/dev/null 2>&1 || true
  fi
  if is_rhel_like; then install_epel_if_needed; fi

  local packages_to_install="$FAIL2BAN_PKG, $WHOIS_PKG, $DNSUTILS_PKG, nftables, $IPCALC_PKG, $SIPCALC_PKG"
  if [[ "$ASSUME_Y" == "false" ]] && ! ask_yes_no "Do you want to proceed with installing $packages_to_install?" "Y"; then
    log INFO "Package installation cancelled by user. Exiting..."; exit 1
  fi

  # nftables
  log INFO "Installing nftables..."
  if ! pkg_present nft; then
    pkg_install nftables >/dev/null 2>&1 || die "Failed to install nftables"
    log INFO "nftables installed successfully"
  else
    log INFO "nftables already installed"
  fi

  # fail2ban
  log INFO "Installing $FAIL2BAN_PKG..."
  if ! pkg_present "$FAIL2BAN_PKG"; then
    pkg_install "$FAIL2BAN_PKG" >/dev/null 2>&1 || die "Failed to install $FAIL2BAN_PKG"
    log INFO "$FAIL2BAN_PKG installed successfully"
  else
    log INFO "$FAIL2BAN_PKG already installed"
  fi

  # whois
  log INFO "Installing $WHOIS_PKG..."
  if ! pkg_present "$WHOIS_PKG"; then
    pkg_install "$WHOIS_PKG" >/dev/null 2>&1 || die "Failed to install $WHOIS_PKG"
    log INFO "$WHOIS_PKG installed successfully"
  else
    log INFO "$WHOIS_PKG already installed"
  fi

  # dnsutils/bind-utils
  log INFO "Installing $DNSUTILS_PKG..."
  if ! pkg_present "$DNSUTILS_PKG"; then
    pkg_install "$DNSUTILS_PKG" >/dev/null 2>&1 || die "Failed to install $DNSUTILS_PKG"
    log INFO "$DNSUTILS_PKG installed successfully"
  else
    log INFO "$DNSUTILS_PKG already installed"
  fi

  # ipcalc
  log INFO "Installing $IPCALC_PKG..."
  if ! pkg_present "$IPCALC_PKG"; then
    pkg_install "$IPCALC_PKG" >/dev/null 2>&1 || die "Failed to install $IPCALC_PKG"
    log INFO "$IPCALC_PKG installed successfully"
  else
    log INFO "$IPCALC_PKG already installed"
  fi

  # sipcalc (may require EPEL on RHEL systems)
  log INFO "Installing $SIPCALC_PKG..."
  if ! pkg_present "$SIPCALC_PKG"; then
    if pkg_install "$SIPCALC_PKG" >/dev/null 2>&1; then
      log INFO "$SIPCALC_PKG installed successfully"
    else
      # sipcalc might not be available on all systems
      log WARN "$SIPCALC_PKG installation failed (may not be available in repositories)"
      log WARN "Continuing without $SIPCALC_PKG - some functionality may be limited"
    fi
  else
    log INFO "$SIPCALC_PKG already installed"
  fi

  log INFO "All packages installed (services not enabled/started)."
}

# --- Directory structure ------------------------------------------------------
create_dir_structure() {
  log INFO "Creating directory structure under $TARGET_DIR"
  mkdir -p "$TARGET_DIR"/{config,scripts,logs,backups,templates,bin,rules,conf.d,systemd} || die "Failed to create directory structure"
  mkdir -p "$TARGET_DIR/templates/control-panels"
  mkdir -p "$LOG_DIR" /var/log/nftban /var/backups
  # symlink logs
  if [[ ! -L "$TARGET_DIR/logs" ]]; then
    rm -rf "$TARGET_DIR/logs" 2>/dev/null || true
    ln -sf "$LOG_DIR" "$TARGET_DIR/logs"
    log INFO "Symlink created from $TARGET_DIR/logs to $LOG_DIR"
  fi
  chmod 0755 "$TARGET_DIR" "$TARGET_DIR"/{config,scripts,backups,templates,bin,rules,conf.d,systemd}
  chmod 0755 "$LOG_DIR" /var/log/nftban /var/backups
  chmod 0640 "$LOGFILE" 2>/dev/null || true
  log INFO "Directory structure created"
}

# --- Control panel detection / templates -------------------------------------
get_ssh_port() {
  local ssh_port
  ssh_port=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
  [[ -z "$ssh_port" ]] && ssh_port="22"
  echo "$ssh_port"
}

is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" != *.* ]]; }

create_generic_template() {
  local template_file="$TARGET_DIR/templates/control-panels/generic.conf"
  local ssh_port; ssh_port=$(get_ssh_port)
  log INFO "Creating generic configuration template with SSH port: $ssh_port"
  mkdir -p "$(dirname "$template_file")"
  cat > "$template_file" <<'TEMPLATE_EOF'
# Generic server configuration
# Format:
#   TCP_IN="port1,port2,port3"   - Inbound TCP ports
#   TCP_OUT="port1,port2,port3"  - Outbound TCP ports
#   TCP6_IN="port1,port2,port3"  - Inbound TCP IPv6 ports
#   TCP6_OUT="port1,port2,port3" - Outbound TCP IPv6 ports
#   IP_ADDRESS="ip1,ip2,ip3"     - IP addresses to whitelist

# Basic inbound ports
TCP_IN="SSH_PORT_PLACEHOLDER,80,443"
# Basic outbound ports (DNS, HTTP, HTTPS, NTP)
TCP_OUT="53,80,443,123"
# Basic IPv6 inbound ports
TCP6_IN="SSH_PORT_PLACEHOLDER,80,443"
# Basic IPv6 outbound ports
TCP6_OUT="53,80,443,123"
# No specific IP addresses for generic setup
IP_ADDRESS=""
TEMPLATE_EOF
  sed -i "s/SSH_PORT_PLACEHOLDER/$ssh_port/g" "$template_file"
  if [[ -f "$template_file" ]]; then
    log INFO "Generic configuration template created: $template_file"; return 0
  else
    log INFO "ERROR: Failed to create generic configuration template"; return 1
  fi
}

prompt_for_generic_config() {
  local ssh_port; ssh_port=$(get_ssh_port)
  ui title "No control panel detected on this server."
  echo ""
  ui info  "I can create a simple, safe default configuration for a typical web server."
  ui info  "This includes:"
  echo "  - SSH: ${ssh_port} (detected)"
  echo "  - HTTP: 80"
  echo "  - HTTPS: 443"
  echo "  - Outbound DNS: 53"
  echo "  - Outbound NTP: 123"
  echo ""
  ui tip   "You can edit these later under: $TARGET_DIR/config/"
  echo ""
  if [[ "$ASSUME_Y" == "true" ]]; then
    log INFO "Auto-accepting generic configuration due to -y flag"; return 0
  fi
  while true; do
    read -p "Create the simple default configuration now? (y/n): " -n 1 -r; echo
    case $REPLY in
      [Yy]) log INFO "User selected to create generic configuration"; return 0;;
      [Nn]) log INFO "User declined to create generic configuration"; return 1;;
      *)    echo "Please answer y or n.";;
    esac
  done
}

create_empty_configs() {
  local config_dir="$TARGET_DIR/config"; mkdir -p "$config_dir"
  local files=(
    "nftban-configuration-ipv4-ports-input-allow.conf"
    "nftban-configuration-ipv4-ports-output-allow.conf"
    "nftban-configuration-ipv6-ports-input-allow.conf"
    "nftban-configuration-ipv6-ports-output-allow.conf"
    "nftban-configuration-user-whitelist_ips.conf"
    "nftban-configuration-user-blacklist_ips.conf"
    "nftban-configuration-ipv4-ports-input-allow.conf.local"
    "nftban-configuration-ipv4-ports-output-allow.conf.local"
    "nftban-configuration-ipv6-ports-input-allow.conf.local"
    "nftban-configuration-ipv6-ports-output-allow.conf.local"
    "nftban-configuration-user-whitelist_ips.conf.local"
    "nftban-configuration-user-blacklist_ips.conf.local"
    "nftban-configuration-f2b-ips_temp-blacklists_conf.local"
  )
  for file in "${files[@]}"; do
    local full_path="$config_dir/$file"
    cat > "$full_path" <<'EMPTY_EOF'
# Empty configuration - manually configure as needed
# Generated on: TIMESTAMP_PLACEHOLDER
#
# Format for port files:
#   portT (TCP), portU (UDP), portB (Both)
#   Example: 80T, 53U, 22B
#
# Format for whitelist files:
#   One IP address per line (IPv4 or IPv6)
#   Example: 192.168.1.1, 10.0.0.0/8, 2001:db8::1
EMPTY_EOF
    sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "$full_path"
    log INFO "Created empty configuration: $full_path"
  done
  log INFO "Empty configuration files created. Manual configuration required."
}

detect_control_panel() {
  log INFO "Checking for running control panel..."
  if [ -d "/usr/local/directadmin/" ]; then
    log INFO "DirectAdmin detected."; PANEL="directadmin"; CONFIG_FILE="$TARGET_DIR/templates/control-panels/directadmin.conf"; return 0
  elif [ -d "/var/cpanel/" ]; then
    log INFO "cPanel detected."; PANEL="cpanel"; CONFIG_FILE="$TARGET_DIR/templates/control-panels/cpanel.conf"; return 0
  elif [ -d "/usr/local/psa/" ]; then
    log INFO "Plesk detected."; PANEL="plesk"; CONFIG_FILE="$TARGET_DIR/templates/control-panels/plesk.conf"; return 0
  else
    log INFO "No common control panel (DirectAdmin, cPanel, Plesk) detected."
    if prompt_for_generic_config; then
      PANEL="generic"
      if create_generic_template; then CONFIG_FILE="$TARGET_DIR/templates/control-panels/generic.conf"; return 0
      else log INFO "ERROR: Failed to create generic configuration template"; return 1; fi
    else
      log INFO "User declined generic configuration. Creating empty config files."; create_empty_configs; return 2
    fi
  fi
}

process_control_panel_config() {
  local config_file="$1"; local panel_name="$2"
  local config_dir="$TARGET_DIR/config"; mkdir -p "$config_dir"
  local TCP4_IN="$config_dir/nftban-configuration-ipv4-ports-input-allow.conf.local"
  local TCP4_OUT="$config_dir/nftban-configuration-ipv4-ports-output-allow.conf.local"
  local TCP6_IN="$config_dir/nftban-configuration-ipv6-ports-input-allow.conf.local"
  local TCP6_OUT="$config_dir/nftban-configuration-ipv6-ports-output-allow.conf.local"
  local USER_WHITELIST="$config_dir/nftban-configuration-user-whitelist_ips.conf.local"

  for file in "$TCP4_IN" "$TCP4_OUT" "$TCP6_IN" "$TCP6_OUT" "$USER_WHITELIST"; do
    cat > "$file" <<CONFIG_HEADER
# Configuration file generated on: $(date)
# Control Panel: $panel_name
# Format: portT (TCP), portU (UDP), portB (Both) for port files
# Format: One IP address per line for whitelist files
CONFIG_HEADER
  done

  if [ ! -f "$config_file" ]; then log INFO "ERROR: Configuration file $config_file not found!"; return 1; fi

  log INFO "Processing configuration file: $config_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    line=$(echo "$line" | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//')
    [[ -n "$line" ]] || continue
    case "$line" in
      TCP_IN*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP input ports" >> "$TCP4_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP4_IN"
          done
          echo "" >> "$TCP4_IN"; log INFO "Added TCP input ports: $ports"
        fi
        ;;
      TCP_OUT*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP output ports" >> "$TCP4_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP4_OUT"
          done
          echo "" >> "$TCP4_OUT"; log INFO "Added TCP output ports: $ports"
        fi
        ;;
      TCP6_IN*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 input ports" >> "$TCP6_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP6_IN"
          done
          echo "" >> "$TCP6_IN"; log INFO "Added TCP6 input ports: $ports"
        fi
        ;;
      TCP6_OUT*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 output ports" >> "$TCP6_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP6_OUT"
          done
          echo "" >> "$TCP6_OUT"; log INFO "Added TCP6 output ports: $ports"
        fi
        ;;
      IP_ADDRESS*)
        ips=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ips" ]]; then
          echo "# $panel_name panel IP addresses" >> "$USER_WHITELIST"
          echo "$ips" | tr ',' '\n' | while IFS= read -r ip; do
            ip=$(echo "$ip" | sed 's/^\s*//;s/\s*$//')
            if [[ -n "$ip" ]]; then
              if is_ipv4 "$ip" || is_ipv6 "$ip"; then
                echo "$ip" >> "$USER_WHITELIST"; log INFO "Added IP to whitelist: $ip"
              else
                log INFO "WARNING: Invalid IP format: $ip"
              fi
            fi
          done
          echo "" >> "$USER_WHITELIST"
        fi
        ;;
    esac
  done < "$config_file"
  
  log INFO "Configuration processed using $panel_name configuration"
  return 0
}

run_control_panel_detection() {
  if [[ "$SKIP_CP_DETECT" == "true" ]]; then
    log INFO "Skipping control panel detection (--skip-cp-detect flag)"
    return 0
  fi
  
  if [[ "$ASSUME_Y" == "false" ]] && ! ask_yes_no "Do you want to detect control panel and setup default ports?" "Y"; then
    log INFO "Skipping control panel detection"
    echo ""
    echo "Manual configuration will be required"
    echo "You will need to create these files manually:"
    echo "  - $TARGET_DIR/config/nftban-configuration-ipv4-ports-input-allow.conf.local"
    echo "  - $TARGET_DIR/config/nftban-configuration-ipv4-ports-output-allow.conf.local"
    echo "  - $TARGET_DIR/config/nftban-configuration-ipv6-ports-input-allow.conf.local"
    echo "  - $TARGET_DIR/config/nftban-configuration-ipv6-ports-output-allow.conf.local"
    echo "  - $TARGET_DIR/config/nftban-configuration-user-whitelist_ips.conf.local"
    return 0
  fi
  
  log INFO "Starting control panel detection and default ports setup..."
  
  # Initialize variables
  PANEL=""
  CONFIG_FILE=""
  
  # Detect panel
  detect_control_panel
  local panel_detection_result=$?
  
  case $panel_detection_result in
    0)
      # Panel detected or generic config accepted
      log INFO "Panel configuration: $PANEL"
      log INFO "Config file: $CONFIG_FILE"
      
      if [[ -f "$CONFIG_FILE" ]]; then
        if process_control_panel_config "$CONFIG_FILE" "$PANEL"; then
          echo ""
          echo "=== Control Panel Detection Complete ==="
          echo "Detected: $PANEL"
          echo "Configuration applied successfully"
          echo "Files are ready for nftables initialization"
          echo "========================================="
          
          log INFO "Control panel detection and configuration completed successfully"
          return 0
        else
          log INFO "ERROR: Failed to process configuration"
          return 1
        fi
      else
        log INFO "ERROR: Configuration file $CONFIG_FILE not found"
        return 1
      fi
      ;;
    2)
      # User declined generic config - empty files created
      echo ""
      echo "=== Manual Configuration Required ==="
      echo "Empty configuration files created"
      echo "No automatic port configuration applied"
      echo ""
      echo "Manual steps required:"
      echo "1. Edit configuration files in: $TARGET_DIR/config/"
      echo "2. Add required ports and IP addresses"
      echo "3. Run initialization scripts"
      echo "====================================="
      
      log INFO "Empty configuration files created. Manual configuration required."
      return 0
      ;;
    *)
      log INFO "ERROR: Panel detection failed with code: $panel_detection_result"
      return 1
      ;;
  esac
}

# --- Download Methods ---
backup_existing() {
  if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
    local ts bkp; ts="$(date +%Y%m%d_%H%M%S)"; bkp="/var/backups/nftban_${ts}.tgz"
    log INFO "Backing up existing $TARGET_DIR to $bkp"
    tar -czf "$bkp" -C / "${TARGET_DIR#/}" 2>/dev/null || true
  fi
}

net_check() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsI "https://github.com" >/dev/null 2>&1 || log INFO "Note: Unable to reach https://github.com (continuing anyway)."
  fi
}

stage_prepare() { WORK_DIR="$(mktemp -d /tmp/nftban_init.XXXXXX)"; }

do_github_flow() {
  log INFO "Selected: GitHub flow (branch: $BRANCH)"; ensure_tools git curl; net_check; stage_prepare
  mkdir -p "$TARGET_DIR"
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log INFO "Existing repo found. Syncing..."
    pushd "$TARGET_DIR" >/dev/null
    git fetch --all --quiet || true
    git reset --hard "origin/$BRANCH" --quiet || true
    git pull --rebase --quiet || true
    popd >/dev/null
  else
    pushd "$WORK_DIR" >/dev/null
    git clone --quiet --branch "$BRANCH" "$REPO_URL" repo
    install -d "$TARGET_DIR"
    cp -a repo/. "$TARGET_DIR/"
    popd >/dev/null
  fi
}

do_zip_flow() {
  log INFO "Selected: ZIP flow"; ensure_tools curl unzip; net_check; stage_prepare
  pushd "$WORK_DIR" >/dev/null
  local zip="$WORK_DIR/nftban.zip"
  log INFO "Downloading archive: $ZIP_URL"
  curl -fsSL "$ZIP_URL" -o "$zip" || die "Failed to download ZIP."
  if [[ ! -s "$zip" ]]; then
    die "Download failed (empty file)."
  fi
  log INFO "Testing archive"
  unzip -t "$zip" >/dev/null 2>&1 || die "Corrupt ZIP archive."
  log INFO "Extracting archive"
  unzip -q "$zip" -d "$WORK_DIR"
  local extracted
  extracted="$(find "$WORK_DIR" -maxdepth 1 -type d -name 'nftban-*' -print -quit)"
  [[ -n "$extracted" ]] || die "Could not find extracted folder within ZIP."
  backup_existing
  rm -rf "$TARGET_DIR"
  mkdir -p "$(dirname "$TARGET_DIR")"
  mv "$extracted" "$TARGET_DIR"
  popd >/dev/null
}

# --- nftban Binary Creation ---
create_basic_nftban_binary() {
  # expected existing vars:
  #   TARGET_DIR (e.g., /etc/nftban)
  #   WORK_DIR   (temp/checkout dir; may or may not exist)
  # helper: log <LEVEL> <msg>  (assumed present in your script)

  local BIN="${TARGET_DIR}/bin/nftban"
  local LINK="/usr/local/bin/nftban"
  local REAL_BIN="/etc/nftban/bin/nftban"
  local SRC=""

  # find a repo-provided nftban in WORK_DIR, if any
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    if [[ -x "${WORK_DIR}/bin/nftban" ]]; then
      SRC="${WORK_DIR}/bin/nftban"
    elif [[ -f "${WORK_DIR}/bin/nftban" ]]; then
      SRC="${WORK_DIR}/bin/nftban"
    fi
  fi

  mkdir -p "$(dirname "$BIN")"

  if [[ -n "$SRC" ]]; then
    # install the repo-built CLI
    if command -v install >/dev/null 2>&1; then
      install -m 0755 "$SRC" "$BIN"
    else
      cp -f "$SRC" "$BIN" && chmod 0755 "$BIN"
    fi
    log INFO "Installed repo CLI to: $BIN"
  else
    # no repo CLI; use the real system CLI if it already exists
    if [[ -x "$REAL_BIN" || -f "$REAL_BIN" ]]; then
      BIN="$REAL_BIN"
      log INFO "Using existing system CLI: $BIN"
    else
      # last resort: write a tiny stub that *only* points to the real path
      cat > "${TARGET_DIR}/bin/nftban" <<'NFTBAN_EOF'
#!/usr/bin/env bash
echo "nftban is not installed here. Expected real CLI at: /etc/nftban/bin/nftban" >&2
echo "If it exists, relink with: sudo ln -sf /etc/nftban/bin/nftban /usr/local/bin/nftban" >&2
exit 1
NFTBAN_EOF
      chmod 0755 "${TARGET_DIR}/bin/nftban"
      BIN="${TARGET_DIR}/bin/nftban"
      log WARN "Created minimal stub at ${BIN}; real CLI not found."
    fi
  fi

  # ensure executable (safe even if BIN points to REAL_BIN)
  if [[ -f "$BIN" ]]; then
    chmod +x "$BIN" || true
  fi

  # ensure global symlink
  mkdir -p "$(dirname "$LINK")"
  ln -sf "$BIN" "$LINK"

  # SELinux contexts if applicable
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    if command -v restorecon >/dev/null 2>&1; then
      restorecon -F "$BIN" "$LINK" >/dev/null 2>&1 || true
    fi
  fi

  log INFO "Symlink ensured: ${LINK} -> ${BIN}"
}

create_basic_nftban_binary_for_review_delete() {
  if [[ ! -f "$TARGET_DIR/bin/nftban" ]]; then
    log INFO "Creating basic nftban binary..."
    mkdir -p "$TARGET_DIR/bin"
    cat > "$TARGET_DIR/bin/nftban" << 'NFTBAN_EOF'
#!/bin/bash

################################################################################
# nftban - Basic nftables firewall management tool
# This is a placeholder binary created by the installation script
################################################################################

BASE_DIR="/etc/nftban"
VERSION="3.0.3-placeholder"

show_help() {
    cat << 'EOF'
nftban - nftables firewall management tool

Usage: nftban [COMMAND] [OPTIONS]

Commands:
    help, --help, -h     Show this help message
    version, --version   Show version information
    status              Show nftables status
    list                List current nftables rules
    flush               Flush all nftables rules (WARNING: Use with caution!)
    init                Initialize nftables configuration
    reload              Reload nftables configuration
    config              Show configuration directory

Configuration files location: /etc/nftban/config/
Log files location: /var/log/nftban/
Templates location: /etc/nftban/templates/

Note: This is a basic placeholder binary. 
For full functionality, sync with the GitHub repository.
EOF
}

show_version() {
    echo "nftban version $VERSION"
    echo "Configuration directory: $BASE_DIR"
}

case "${1:-help}" in
    help|--help|-h)
        show_help
        ;;
    version|--version)
        show_version
        ;;
    status)
        echo "nftables status:"
        nft list tables 2>/dev/null || echo "No nftables rules found or nftables not available"
        ;;
    list)
        echo "Current nftables rules:"
        nft list ruleset 2>/dev/null || echo "No rules found or insufficient permissions"
        ;;
    flush)
        echo "WARNING: This will remove all nftables rules!"
        read -p "Are you sure? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            nft flush ruleset && echo "nftables rules flushed" || echo "Failed to flush rules"
        else
            echo "Operation cancelled"
        fi
        ;;
    init)
        if [[ -f "$BASE_DIR/scripts/nftban_init_nftables_conf.sh" ]]; then
            exec "$BASE_DIR/scripts/nftban_init_nftables_conf.sh"
        else
            echo "nftables initialization script not found"
            echo "Run the installation script with GitHub sync enabled"
        fi
        ;;
    reload)
        if [[ -f "$BASE_DIR/config/nft_rules.conf.local" ]]; then
            nft -f "$BASE_DIR/config/nft_rules.conf.local" && echo "nftables rules reloaded" || echo "Failed to reload rules"
        else
            echo "nftables configuration file not found"
            echo "Run: nftban init"
        fi
        ;;
    config)
        echo "Configuration directory: $BASE_DIR/config/"
        echo "Available configuration files:"
        if ls "$BASE_DIR/config/"*.conf.local >/dev/null 2>&1; then
            for file in "$BASE_DIR/config/"*.conf.local; do
                echo "  - $(basename "$file")"
            done
        else
            echo "  No configuration files found"
        fi
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'nftban help' for usage information"
        exit 1
        ;;
esac
NFTBAN_EOF

    chmod +x "$TARGET_DIR/bin/nftban"
    log INFO "Basic nftban binary created"
  fi
}

# --- Auto-update functionality ------------------------------------------------
print_json_status() {
  local enabled="false" lines=0
  local tmpfile; tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  lines=$(grep -c -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" 2>/dev/null || echo 0)
  rm -f "$tmpfile"
  if [[ "$lines" -gt 0 ]]; then enabled="true"; fi
  printf '{"auto_update_enabled":%s,"auto_update_lines":%s,"target_dir":"%s"}\n' "$enabled" "$lines" "$TARGET_DIR"
}

show_status() {
  log INFO "nftban path: $TARGET_DIR"
  if command -v nft >/dev/null 2>&1; then
    log INFO "nftables: $(nft --version 2>/dev/null | head -1)"
  else
    log WARN "nft not found"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    log INFO "fail2ban: $(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')"
  else
    log WARN "fail2ban not found"
  fi
  if [[ -f "/etc/systemd/system/nftban.service" ]]; then
    log INFO "systemd unit present: /etc/systemd/system/nftban.service"
  else
    log INFO "systemd unit not found (optional)"
  fi
  auto_update_status
}

auto_update_status() {
  local tmpfile; tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  mapfile -t cron_lines < <(grep -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" || true)
  rm -f "$tmpfile"

  local count="${#cron_lines[@]}"
  if [[ "$count" -gt 0 ]]; then
    log INFO "Auto-update via crontab: ENABLED ($count entr$([[ $count -eq 1 ]] && echo 'y' || echo 'ies'))."
    printf '%s\n' "${cron_lines[@]}" | sed 's/^/  • /'
  else
    log INFO "Auto-update via crontab: DISABLED (no matching crontab lines)."
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
    log INFO "Auto-update script: $AUTO_UPDATE_SCRIPT"
    log INFO "  size: ${sz} bytes, modified: ${mtime}, sha256: ${sha}"
  else
    log WARN "Auto-update script not found at: $AUTO_UPDATE_SCRIPT"
  fi
}

cron_sanity_check() {
  if command -v systemctl >/dev/null 2>&1; then
    if ! (systemctl is-enabled cron >/dev/null 2>&1 || systemctl is-enabled crond >/dev/null 2>&1); then
      log WARN "cron service appears disabled. Auto-update may not run."
    fi
    if ! (systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1); then
      log WARN "cron service is not active. Consider: systemctl start cron (or crond)."
    fi
  fi
}

ensure_single_cron_entry() {
  local entry="$1"
  local tmpfile; tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$AUTO_UPDATE_SCRIPT" > "$tmpfile" || true
  printf '%s\n' "$entry" >> "$tmpfile"
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    crontab "$tmpfile" 2>/dev/null || true
  else
    log INFO "DRY-RUN: would install crontab entry: $entry"
  fi
  rm -f "$tmpfile"
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
  # Choose schedule
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
  log INFO "Auto-update cron installed. Use --auto-update-status to check."
}

remove_auto_update() {
  # Remove cron entries referencing the auto-update script and delete the script
  local tmpfile; tmpfile=$(mktemp)
  crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_SCRIPT" > "$tmpfile" || true
  if [[ "${DRY_RUN:-false}" != "true" ]]; then crontab "$tmpfile" 2>/dev/null || true; else log INFO "DRY-RUN: would remove existing crontab entries for $AUTO_UPDATE_SCRIPT"; fi
  rm -f "$tmpfile"
  if [[ -f "$AUTO_UPDATE_SCRIPT" ]]; then
    if [[ "${DRY_RUN:-false}" != "true" ]]; then rm -f "$AUTO_UPDATE_SCRIPT"; else log INFO "DRY-RUN: would remove $AUTO_UPDATE_SCRIPT"; fi
    log INFO "Removed auto-update script: $AUTO_UPDATE_SCRIPT"
  fi
  log INFO "Auto-update cron entries removed (if any existed)."
}

# --- Version management -------------------------------------------------------
check_version() {
  # Handle pure status/info commands early
  if [[ "$DO_AUTO_UPDATE_STATUS" == "true" ]]; then
    cron_sanity_check
    auto_update_status
    exit 0
  fi
  if [[ "$DO_STATUS" == "true" ]]; then
    if [[ "$JSON_MODE" == "true" ]]; then
      print_json_status
    else
      show_status
    fi
    exit 0
  fi

  mkdir -p "$(dirname "$VERSION_FILE")"
  if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
    if [ "$CURRENT_VERSION" != "$VERSION" ]; then
      echo "New version detected: $VERSION (was $CURRENT_VERSION)"
      echo "$VERSION" > "$VERSION_FILE"
    fi
  else
    echo "$VERSION" > "$VERSION_FILE"
  fi
}

# --- Post-fetch Processing ---
post_fetch() {
  create_dir_structure
  install_packages
  create_basic_nftban_binary
  
  # Run control panel detection
  run_control_panel_detection
  
  # Optional installer if repo provides one (no service enable/start here)
  if [[ -x "$TARGET_DIR/install.sh" ]]; then
    log INFO "Running repo installer: $TARGET_DIR/install.sh"
    (cd "$TARGET_DIR" && bash ./install.sh) | tee -a "$LOGFILE"
  fi

  # Optional systemd unit: install but DO NOT enable or start
  if [[ -f "$TARGET_DIR/systemd/nftban.service" ]]; then
    log INFO "Installing systemd unit nftban.service (not enabling/starting)"
    install -m 0644 "$TARGET_DIR/systemd/nftban.service" /etc/systemd/system/nftban.service
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log INFO "You may enable later with: systemctl enable --now nftban.service"
  fi
  
  # Create symlink
  create_symlink
  
  # Set executable permissions
  set_permissions
  
  show_completion_summary
}

create_symlink() {
  local TARGET="$TARGET_DIR/bin/nftban"
  local LINK="/usr/local/bin/nftban"

  if [ ! -f "$TARGET" ]; then
    log INFO "Warning: Target file $TARGET does not exist, but continuing..."
  elif [ -L "$LINK" ]; then
    log INFO "Symlink already exists: $LINK -> $(readlink -f "$LINK")"
  else
    log INFO "Creating symlink..."
    ln -s "$TARGET" "$LINK"
    log INFO "Symlink created: $LINK -> $TARGET"
  fi
}

set_permissions() {
  log INFO "Setting executable permissions..."
  find "$TARGET_DIR/scripts" -type f -name "*.sh" ! -perm -111 -exec chmod +x {} \; 2>/dev/null || true
  if [[ -f "$TARGET_DIR/bin/nftban" ]]; then
    chmod +x "$TARGET_DIR/bin/nftban"
  fi
}

# --- Enhanced Uninstall (no package removal prompts) --------------------------
uninstall_service_unit() {
  # Stop/disable nftban service if present, remove unit file
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nftban.service >/dev/null 2>&1 || true
    systemctl disable nftban.service >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/systemd/system/nftban.service ]]; then
    rm -f /etc/systemd/system/nftban.service
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log INFO "Removed /etc/systemd/system/nftban.service"
  fi
  # OpenRC cleanup (best-effort)
  if command -v rc-update >/dev/null 2>&1; then
    rc-update del nftban default >/dev/null 2>&1 || true
  fi
}

do_uninstall() {
  log INFO "Uninstall requested"
  if ! ask_yes_no "Proceed to uninstall nftban from $TARGET_DIR?" "Y"; then
    log INFO "Uninstall aborted by user"
    exit 0
  fi

  uninstall_service_unit

  # Remove symlink
  if [[ -L "/usr/local/bin/nftban" ]]; then
    rm -f "/usr/local/bin/nftban"
    log INFO "Removed symlink /usr/local/bin/nftban"
  fi

  # Remove main directory
  if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
    log INFO "Removed $TARGET_DIR"
  fi

  # Remove auto-update
  remove_auto_update

  # Purge optional data/logs if requested
  if [[ "$DO_PURGE" == "true" ]]; then
    rm -rf "$LOG_DIR" /var/log/nftban
    log INFO "Purged $LOG_DIR and /var/log/nftban"
  else
    log INFO "Keeping logs/state (use --purge to remove)"
  fi

  log INFO "Uninstall complete"
  exit 0
}

# --- Completion Summary ---
show_completion_summary() {
  echo ""
  echo "=== INSTALLATION COMPLETE ==="
  ui success \"Installation finished successfully!\"
  echo "Packages installed:"
  echo "  - nftables"
  echo "  - $FAIL2BAN_PKG"
  echo "  - $WHOIS_PKG" 
  echo "  - $DNSUTILS_PKG"
  echo ""
  echo "nftban linked to /usr/local/bin/nftban"
  echo ""
  echo "Scripts are executable"

  # Enhanced status reporting for control panel detection
  if [[ "$SKIP_CP_DETECT" == "false" ]]; then
    # Count configuration files created
    CONFIG_FILE_COUNT=0
    for config_file in "$TARGET_DIR/config/nftban-configuration-"*.conf.local; do
      if [[ -f "$config_file" ]]; then
        CONFIG_FILE_COUNT=$((CONFIG_FILE_COUNT + 1))
      fi
    done
    
    if [[ $CONFIG_FILE_COUNT -gt 0 ]]; then
      echo ""
      echo "=== CONTROL PANEL CONFIGURATION ==="
      
      # Use find instead of ls to handle non-alphanumeric filenames
      local latest_log
      latest_log=$(find "$LOG_DIR" -maxdepth 1 -name "cp_detection_*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
      
      if [[ -n "$latest_log" && -f "$latest_log" ]]; then
        if grep -q "DirectAdmin detected" "$latest_log" 2>/dev/null; then
          echo "DirectAdmin control panel detected and configured"
        elif grep -q "cPanel detected" "$latest_log" 2>/dev/null; then
          echo "cPanel control panel detected and configured"
        elif grep -q "Plesk detected" "$latest_log" 2>/dev/null; then
          echo "Plesk control panel detected and configured"
        elif grep -q "User selected to create generic configuration" "$latest_log" 2>/dev/null; then
          SSH_PORT_USED=$(grep -o "SSH port: [0-9]*" "$latest_log" 2>/dev/null | cut -d' ' -f3)
          echo "Generic web server configuration applied"
          echo "  - SSH port: ${SSH_PORT_USED:-22}"
          echo "  - HTTP/HTTPS ports: 80, 443"
          echo "  - DNS/NTP outbound: 53, 123"
        elif grep -q "User declined generic configuration" "$latest_log" 2>/dev/null; then
          echo "Empty configuration files created"
          echo "  Manual configuration required"
        fi
      fi
      
      echo ""
      echo "Configuration files created ($CONFIG_FILE_COUNT files):"
      for config_file in "$TARGET_DIR/config/nftban-configuration-"*.conf.local; do
        if [[ -f "$config_file" ]]; then
          # Count entries using simple arithmetic
          total_lines=$(wc -l < "$config_file" 2>/dev/null)
          comment_lines=$(grep -c '^#' "$config_file" 2>/dev/null || true)
          empty_lines=$(grep -c '^[[:space:]]*$' "$config_file" 2>/dev/null || true)
          entry_count=$((total_lines - comment_lines - empty_lines))
          filename=$(basename "$config_file")
          case "$filename" in
            *"input"*) echo "  - $filename ($entry_count inbound rules)" ;;
            *"output"*) echo "  - $filename ($entry_count outbound rules)" ;;
            *"whitelist"*) echo "  - $filename ($entry_count whitelisted IPs)" ;;
            *) echo "  - $filename ($entry_count entries)" ;;
          esac
        fi
      done
      echo "==================================="
    else
      echo ""
      echo "Control panel detection completed but no configuration files were created"
      echo "Manual configuration will be required"
    fi
  fi

  echo ""
  echo "=== NEXT STEPS ==="
  echo "1. Initialize nftables environment:"
  if [[ -f "$TARGET_DIR/scripts/nftban_init_nftables_conf.sh" ]]; then
    echo "   sudo $TARGET_DIR/scripts/nftban_init_nftables_conf.sh"
  else
    echo "   nftables initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
  fi
  echo ""

  echo "2. Initialize fail2ban environment:"
  if [[ -f "$TARGET_DIR/scripts/nftban_init_fail2ban_conf.sh" ]]; then
    echo "   sudo $TARGET_DIR/scripts/nftban_init_fail2ban_conf.sh"
  else
    echo "   fail2ban initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
  fi
  echo ""

  # Conditional step 3 based on whether config files were created
  CONFIG_FILE_COUNT=0
  for config_file in "$TARGET_DIR/config/nftban-configuration-"*.conf.local; do
    if [[ -f "$config_file" ]]; then
      CONFIG_FILE_COUNT=$((CONFIG_FILE_COUNT + 1))
    fi
  done

  if [[ $CONFIG_FILE_COUNT -gt 0 ]]; then
    # Count total entries across all files
    TOTAL_ENTRIES=0
    for file in "$TARGET_DIR/config/nftban-configuration-"*".conf.local"; do
      if [[ -f "$file" ]]; then
        total_lines=$(wc -l < "$file" 2>/dev/null )
        comment_lines=$(grep -c '^#' "$file" 2>/dev/null || true)
        empty_lines=$(grep -c '^[[:space:]]*$' "$file" 2>/dev/null || true)
        file_entries=$((total_lines - comment_lines - empty_lines))
        TOTAL_ENTRIES=$((TOTAL_ENTRIES + file_entries))
      fi
    done
    
    if [[ $TOTAL_ENTRIES -gt 0 ]]; then
      echo "3. (Optional) Review and customize configuration:"
      echo "   Configuration files in: $TARGET_DIR/config/"
      echo "   Current configuration has $TOTAL_ENTRIES total rules/entries"
    else
      echo "3. REQUIRED: Configure ports and IP addresses:"
      echo "   Edit files in: $TARGET_DIR/config/"
      echo "   Add your required ports and whitelisted IPs"
    fi
  else
    echo "3. REQUIRED: Create configuration files:"
    echo "   Create and configure files in: $TARGET_DIR/config/"
    if [[ "$FORCE_FLOW" == "git" ]] || [[ "$FORCE_FLOW" == "zip" ]]; then
      echo "   Templates available in: $TARGET_DIR/templates/"
    else
      echo "   Consider using --github or --zip for templates"
    fi
  fi

  echo ""
  echo "4. Auto-update options:"
  if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
    echo "   Auto-update: ENABLED"
    if [[ -n "$DAILY_TIME" ]]; then
      echo "   Schedule: Daily at $DAILY_TIME"
    else
      echo "   Schedule: Every 12 hours"
    fi
  else
    echo "   Auto-update: DISABLED"
    echo "   Enable with: $0 --enable-auto-update"
    echo "   Or schedule daily: $0 --enable-auto-update --daily-time \"03:30\""
  fi
  echo ""

  echo "5. Start using nftban:"
  echo "   nftban --help"
  echo ""

  # Show relevant log files
  echo "=== LOG FILES ==="
  echo "Installation log: $LOGFILE"
  
  # Use find instead of ls for the control panel detection logs
  local latest_cp_log
  latest_cp_log=$(find "$LOG_DIR" -maxdepth 1 -name "cp_detection_*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  
  if [[ -n "$latest_cp_log" ]]; then
    echo "Control panel detection log: $latest_cp_log"
  fi
  echo "================================="

  # Final status
  echo ""
  if [[ "$FORCE_FLOW" == "git" ]] || [[ "$FORCE_FLOW" == "zip" ]]; then
    echo "Installation completed successfully with repository sync!"
  else
    echo "Installation completed with basic functionality only."
    echo "For full features, consider using --github or --zip flags."
  fi
  echo ""
}

# --- Enhanced Usage -----------------------------------------------------------
usage() {
  cat <<'EOF'
###############################################
# nftban Installer (Friendly Help)
# Version: $VERSION
###############################################

Quick start (recommended):
  sudo $0 --github -y                    # Install/refresh from GitHub
  sudo $0 --github -y --enable-auto-update   # + keep it up to date via cron

If GitHub is blocked for you:
  sudo $0 --zip -y                        # Download & install from ZIP

Beginner mode (more guidance & colorful output):
  sudo $0 --github -y --beginner

What this installer will do (safely):
  • Create/update nftban files under: $TARGET_DIR
  • Ensure required packages are present (nftables, fail2ban, whois, dns utils)
  • (Optional) Detect a control panel and suggest sensible default ports
  • It does NOT enable or start services automatically

Common options:
  --github                 Use Git to sync the repository
  --zip                    Use ZIP download instead of Git
  --target DIR             Install directory (default: /etc/nftban)
  --branch NAME            Git branch (default: main)
  --skip-cp-detect         Skip control panel detection
  --enable-auto-update     Set up a cron job to keep nftban updated
  --remove-auto-update     Remove the auto-update cron job
  --auto-update-status     Show auto-update status
  --status [--json]        Show an overall status
  --daily-time HH:MM       With --enable-auto-update: run daily at HH:MM
  --beginner               Friendlier, step-by-step messages
  --no-color               Disable colored output
  --no-unicode             Use plain ASCII icons
  -y                       Assume "yes" to prompts
  -h, --help               Show this help

Uninstall (safe):
  sudo $0 --uninstall -y
  sudo $0 --uninstall --purge -y   # also remove logs/state

Examples:
  # Install to a custom path
  sudo $0 --zip -y --target /etc/nftban

  # Enable daily auto-update at 03:30
  sudo $0 --enable-auto-update --daily-time "03:30"

EOF
}

# --- Argument parsing ---------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --github)             FORCE_FLOW="git"; shift ;;
      --zip)                FORCE_FLOW="zip"; shift ;;
      --target)             TARGET_DIR="${2:-}"; [[ -z "$TARGET_DIR" ]] && die "Missing value for --target"; shift 2 ;;
      --branch)             BRANCH="${2:-}"; [[ -z "$BRANCH" ]] && die "Missing value for --branch"; shift 2 ;;
      --uninstall)          DO_UNINSTALL="true"; shift ;;
      --purge)              DO_PURGE="true"; shift ;;
      --skip-cp-detect)     SKIP_CP_DETECT="true"; shift ;;
      --enable-auto-update) AUTO_UPDATE_ENABLED="true"; shift ;;
      --remove-auto-update) DO_REMOVE_AUTO_UPDATE="true"; shift ;;
      --auto-update-status) DO_AUTO_UPDATE_STATUS="true"; shift ;;
      --status)             DO_STATUS="true"; shift ;;
      --json)               JSON_MODE="true"; shift ;;
      --quiet)              QUIET="true"; shift ;;
      --dry-run)            DRY_RUN="true"; shift ;;
      --daily-time)         DAILY_TIME="${2:-}"; [[ -z "$DAILY_TIME" ]] && die "Missing value for --daily-time (HH:MM)"; shift 2 ;;
      -y)                   ASSUME_Y="true"; shift ;;
      -h|--help)            usage; exit 0 ;;
      *)                    die "Unknown argument: $1" ;;
    esac
  done
}

# --- Main Function ---
main() {
  need_root
  parse_args "$@"
  check_version
  setup_colors
  if [[ \"$BEGINNER_MODE\" == \"true\" ]]; then
    ui title \"nftban Unified Installer\"
    ui info  \"Version: $VERSION\"
    ui step  \"We will prepare your system and set up nftban in a few easy steps.\"
    ui tip   \"Nothing starts automatically; you remain in control.\"
    echo \"\"
  fi

  log INFO "nftban Unified Installation Script starting"
  log INFO "Version: $VERSION"
  log INFO "Target directory: $TARGET_DIR"

  if [[ "$DO_UNINSTALL" == "true" ]]; then
    do_uninstall
  fi

  if [[ "$DO_REMOVE_AUTO_UPDATE" == "true" ]]; then
    remove_auto_update
    exit 0
  fi

  # Create initial directories and log file
  mkdir -p "$LOG_DIR" /var/backups "$(dirname "$TARGET_DIR")"
  touch "$LOGFILE" || true
  chmod 0640 "$LOGFILE" || true

  if [[ -z "$FORCE_FLOW" ]]; then
    # Interactive selection
    echo "nftban Installation Options:"
    echo ""
    echo "1. GitHub (Recommended) - Clone/pull latest repository"
    echo "   - Always gets the latest version"
    echo "   - Includes all scripts and templates"
    echo "   - Requires git (will be installed if missing)"
    echo ""
    echo "2. ZIP Download - Download and extract archive"
    echo "   - Faster download"
    echo "   - No git dependency"
    echo "   - Fixed version (main branch)"
    echo ""
    echo "3. Basic Install - Local installation only"
    echo "   - No repository sync"
    echo "   - Basic functionality only"
    echo "   - Manual configuration required"
    echo ""
    
    if ask_yes_no "Use GitHub repository sync (recommended)?" "Y"; then
      FORCE_FLOW="git"
    else
      if ask_yes_no "Download ZIP archive instead?" "Y"; then
        FORCE_FLOW="zip"
      else
        FORCE_FLOW="local"
      fi
    fi
  fi

  case "$FORCE_FLOW" in
    git) do_github_flow ;;
    zip) do_zip_flow ;;
    local)
      log INFO "Proceeding with basic local installation"
      create_dir_structure
      install_packages
      create_basic_nftban_binary
      run_control_panel_detection
      create_symlink
      set_permissions
      show_completion_summary
      ;;
    *) die "Unknown flow: $FORCE_FLOW" ;;
  esac

  if [[ "$AUTO_UPDATE_ENABLED" == "true" ]]; then
    setup_auto_update
  fi

  log INFO "Installation completed successfully"
}

# --- Script Execution ---
main "$@"
