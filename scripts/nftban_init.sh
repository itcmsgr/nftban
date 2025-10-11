#!/usr/bin/env bash
set -euo pipefail

################################################################################
# nftban Unified Installation & Maintenance Script
#
# Version: 0.5.0-final 
# Description: Comprehensive nftban installer with enhanced functionality
# Features:
# - GitHub repository sync with fallback ZIP download
# - Installs nftables, fail2ban, whois, and DNS utilities
# - Enhanced IP validation using ipcalc and sipcalc
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
VERSION="0.5.0-final"
VERSION_FILE="/etc/nftban/.version"
AUTO_UPDATE_SCRIPT="/etc/nftban/scripts/nftban_auto_update.sh"
AUTO_UPDATE_ENABLED="false"
DO_REMOVE_AUTO_UPDATE="false"
DO_AUTO_UPDATE_STATUS="false"
DO_STATUS="false"
JSON_MODE="false"
DRY_RUN="false"
QUIET="false"

# --- IP Validation Configuration ----------------------------------------------
# Export for use by external scripts
export IP_VALIDATION_MODE="${IP_VALIDATION_MODE:-auto}"  # auto, tools, regex
export IP_VALIDATION_STRICT="${IP_VALIDATION_STRICT:-true}"  # Reject invalid IPs strictly

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
LOGFILE="$LOG_DIR/nftban_init_$(date +%Y-%m-%d-%H%M%S)_$$.log"
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
  local exit_code=$?
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then 
    rm -rf "$WORK_DIR" 2>/dev/null || {
      log "WARN" "Failed to cleanup WORK_DIR: $WORK_DIR"
    }
  fi
  # Clean up any temp files
  rm -f /tmp/nftban_*.tmp.$$ 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

# --- Friendly UI helpers (colors & icons) ---
setup_colors() {
  if [[ "$NO_COLOR" == "true" || ! -t 2 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET="";
  else
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; BOLD="\033[1m"; RESET="\033[0m";
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
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log "INFO" "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "$ASSUME_Y" == "true" ]]; then return 0; fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- IP Validation Functions --------------------------------------------------

# Check if IP validation tools are available
check_ip_validation_tools() {
  local has_ipcalc=false has_sipcalc=false
  
  if command -v ipcalc >/dev/null 2>&1; then
    has_ipcalc=true
    log "INFO" "ipcalc available for IP validation"
  fi
  
  if command -v sipcalc >/dev/null 2>&1; then
    has_sipcalc=true
    log "INFO" "sipcalc available for IP validation"
  fi
  
  if [[ "$has_ipcalc" == "true" || "$has_sipcalc" == "true" ]]; then
    return 0
  else
    log "WARN" "No IP validation tools available, will use regex fallback"
    return 1
  fi
}

# Validate IPv4 address using available tools
validate_ipv4() {
  local ip="$1"
  local method="${2:-${IP_VALIDATION_MODE:-auto}}"
  
  # Auto-detect best method
  if [[ "$method" == "auto" ]]; then
    if command -v ipcalc >/dev/null 2>&1; then
      method="ipcalc"
    elif command -v sipcalc >/dev/null 2>&1; then
      method="sipcalc"
    else
      method="regex"
    fi
  fi
  
  case "$method" in
    ipcalc)
      if ipcalc -c "$ip" >/dev/null 2>&1; then
        return 0
      else
        log "DEBUG" "ipcalc validation failed for: $ip"
        return 1
      fi
      ;;
      
    sipcalc)
      if sipcalc "$ip" >/dev/null 2>&1; then
        return 0
      else
        log "DEBUG" "sipcalc validation failed for: $ip"
        return 1
      fi
      ;;
      
    regex)
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
        # Additional check: ensure octets are <= 255
        local parts addr octets
        IFS='/' read -ra parts <<< "$ip"
        addr="${parts[0]}"
        IFS='.' read -ra octets <<< "$addr"
        for octet in "${octets[@]}"; do
          if (( octet > 255 )); then
            log "DEBUG" "Regex validation failed (octet > 255): $ip"
            return 1
          fi
        done
        return 0
      else
        log "DEBUG" "Regex validation failed (format): $ip"
        return 1
      fi
      ;;
      
    *)
      log "ERROR" "Unknown validation method: $method"
      return 1
      ;;
  esac
}

# Validate IPv6 address using available tools
validate_ipv6() {
  local ip="$1"
  local method="${2:-${IP_VALIDATION_MODE:-auto}}"
  
  # Auto-detect best method
  if [[ "$method" == "auto" ]]; then
    if command -v sipcalc >/dev/null 2>&1; then
      method="sipcalc"
    elif command -v ipcalc >/dev/null 2>&1; then
      method="ipcalc"
    else
      method="regex"
    fi
  fi
  
  case "$method" in
    ipcalc)
      if ipcalc -c "$ip" >/dev/null 2>&1; then
        return 0
      else
        log "DEBUG" "ipcalc IPv6 validation failed for: $ip"
        return 1
      fi
      ;;
      
    sipcalc)
      if sipcalc "$ip" 2>/dev/null | grep -q "IPv6"; then
        return 0
      else
        log "DEBUG" "sipcalc IPv6 validation failed for: $ip"
        return 1
      fi
      ;;
      
    regex)
      if [[ "$ip" =~ ^(([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}|::)(/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$ ]]; then
        return 0
      else
        log "DEBUG" "Regex IPv6 validation failed: $ip"
        return 1
      fi
      ;;
      
    *)
      log "ERROR" "Unknown validation method: $method"
      return 1
      ;;
  esac
}

# Universal IP validation (auto-detects IPv4/IPv6)
validate_ip() {
  local ip="$1"
  local method="${2:-${IP_VALIDATION_MODE:-auto}}"
  
  # Remove leading/trailing whitespace
  ip=$(echo "$ip" | sed 's/^\s*//;s/\s*$//')
  
  # Empty check
  if [[ -z "$ip" ]]; then
    log "DEBUG" "Empty IP address provided"
    return 1
  fi
  
  # Check if it looks like IPv6 (contains colons)
  if [[ "$ip" == *:* ]]; then
    validate_ipv6 "$ip" "$method"
    return $?
  else
    validate_ipv4 "$ip" "$method"
    return $?
  fi
}

# Get detailed IP information using ipcalc
get_ip_info() {
  local ip="$1"
  
  if ! command -v ipcalc >/dev/null 2>&1; then
    log "WARN" "ipcalc not available for detailed IP info"
    return 1
  fi
  
  log "INFO" "IP Information for: $ip"
  ipcalc "$ip" 2>/dev/null || {
    log "WARN" "Could not get IP information for: $ip"
    return 1
  }
}

# Validate and normalize CIDR notation
validate_cidr() {
  local cidr="$1"
  
  # Check if it contains a slash (CIDR notation)
  if [[ ! "$cidr" =~ / ]]; then
    log "DEBUG" "Not CIDR notation: $cidr"
    validate_ip "$cidr"
    return $?
  fi
  
  # Split network and prefix
  local parts network prefix
  IFS='/' read -ra parts <<< "$cidr"
  network="${parts[0]}"
  prefix="${parts[1]}"
  
  # Validate the network part
  if ! validate_ip "$network"; then
    log "WARN" "Invalid network address in CIDR: $network"
    return 1
  fi
  
  # Validate prefix length
  if [[ "$network" == *:* ]]; then
    # IPv6: prefix should be 0-128
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix > 128 )); then
      log "WARN" "Invalid IPv6 prefix length: $prefix (must be 0-128)"
      return 1
    fi
  else
    # IPv4: prefix should be 0-32
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix > 32 )); then
      log "WARN" "Invalid IPv4 prefix length: $prefix (must be 0-32)"
      return 1
    fi
  fi
  
  log "DEBUG" "Valid CIDR notation: $cidr"
  return 0
}

# Legacy functions (kept for compatibility)
is_ipv4() { validate_ipv4 "$1" "auto"; }
is_ipv6() { validate_ipv6 "$1" "auto"; }

# Export validation functions
export -f validate_ip validate_ipv4 validate_ipv6 validate_cidr

# --- Package Manager Detection & Helpers -------------------------------------
export PKG_TOOL=""
export PKG_INSTALL=""

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
    export PKG_TOOL="apt-get"
    export PKG_INSTALL="apt-get update && apt-get install -y"
    export DNSUTILS_PKG="dnsutils"
  elif command -v dnf >/dev/null 2>&1; then
    export PKG_TOOL="dnf"
    export PKG_INSTALL="dnf install -y"
    export DNSUTILS_PKG="bind-utils"
  elif command -v yum >/dev/null 2>&1; then
    export PKG_TOOL="yum"
    export PKG_INSTALL="yum install -y"
    export DNSUTILS_PKG="bind-utils"
  elif command -v zypper >/dev/null 2>&1; then
    export PKG_TOOL="zypper"
    export PKG_INSTALL="zypper install -y"
    export DNSUTILS_PKG="bind-utils"
  elif command -v apk >/dev/null 2>&1; then
    export PKG_TOOL="apk"
    export PKG_INSTALL="apk add --no-cache"
    export DNSUTILS_PKG="bind-tools"
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
    log "INFO" "Installing missing tools: ${missing[*]}"
    case "$PKG_TOOL" in
      apt-get)   run_cmd pkg_install "${missing[@]}" ;;
      dnf|yum|zypper|apk) run_cmd pkg_install "${missing[@]}" ;;
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
  local id_like
  id_like="$(get_os_release_var ID_LIKE || true)"
  [[ "$id_like" == *rhel* || "$id_like" == *fedora* || "$id_like" == *centos* ]]
}

# --- EPEL (RHEL-like) ---------------------------------------------------------
install_epel_if_needed() {
  detect_pm
  if ! is_rhel_like; then return 0; fi
  log "INFO" "RHEL-like system detected - checking EPEL repository"
  if rpm -q epel-release >/dev/null 2>&1; then
    log "INFO" "EPEL repository already installed"
    return 0
  fi
  if [[ "$ASSUME_Y" == "true" ]] || ask_yes_no "EPEL repository is not installed. Do you want to install it?" "Y"; then
    log "INFO" "Installing EPEL repository..."
    if pkg_install epel-release >/dev/null 2>&1; then
      log "INFO" "EPEL repository installed successfully"
      return 0
    else
      ensure_tools curl
      local ver major url
      ver="$(get_os_release_var VERSION_ID || echo "")"
      major="${ver%%.*}"; [[ -z "$major" ]] && major="9"
      url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
      log "INFO" "Falling back to direct EPEL RPM: $url"
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
install_packages() {
  detect_pm
  log "INFO" "Starting package installation using $PKG_TOOL"
  if [[ "$PKG_TOOL" == "apt-get" ]]; then
    log "INFO" "Updating package cache..."
    apt-get update -y >/dev/null 2>&1 || true
  fi
  if is_rhel_like; then install_epel_if_needed; fi

  local packages_to_install="$FAIL2BAN_PKG, $WHOIS_PKG, $DNSUTILS_PKG, nftables, $IPCALC_PKG, $SIPCALC_PKG"
  if [[ "$ASSUME_Y" == "false" ]] && ! ask_yes_no "Do you want to proceed with installing $packages_to_install?" "Y"; then
    log "INFO" "Package installation cancelled by user. Exiting..."; exit 1
  fi

  # nftables
  log "INFO" "Installing nftables..."
  if ! pkg_present nft; then
    pkg_install nftables >/dev/null 2>&1 || die "Failed to install nftables"
    log "INFO" "nftables installed successfully"
  else
    log "INFO" "nftables already installed"
  fi

  # fail2ban
  log "INFO" "Installing $FAIL2BAN_PKG..."
  if ! pkg_present "$FAIL2BAN_PKG"; then
    pkg_install "$FAIL2BAN_PKG" >/dev/null 2>&1 || die "Failed to install $FAIL2BAN_PKG"
    log "INFO" "$FAIL2BAN_PKG installed successfully"
  else
    log "INFO" "$FAIL2BAN_PKG already installed"
  fi

  # whois
  log "INFO" "Installing $WHOIS_PKG..."
  if ! pkg_present "$WHOIS_PKG"; then
    pkg_install "$WHOIS_PKG" >/dev/null 2>&1 || die "Failed to install $WHOIS_PKG"
    log "INFO" "$WHOIS_PKG installed successfully"
  else
    log "INFO" "$WHOIS_PKG already installed"
  fi

  # dnsutils/bind-utils
  log "INFO" "Installing $DNSUTILS_PKG..."
  if ! pkg_present "$DNSUTILS_PKG"; then
    pkg_install "$DNSUTILS_PKG" >/dev/null 2>&1 || die "Failed to install $DNSUTILS_PKG"
    log "INFO" "$DNSUTILS_PKG installed successfully"
  else
    log "INFO" "$DNSUTILS_PKG already installed"
  fi

  # ipcalc (critical for IP validation)
  log "INFO" "Installing $IPCALC_PKG..."
  if ! command -v ipcalc >/dev/null 2>&1; then
    if pkg_install "$IPCALC_PKG" >/dev/null 2>&1; then
      log "INFO" "$IPCALC_PKG installed successfully"
      if command -v ipcalc >/dev/null 2>&1; then
        log "INFO" "ipcalc verified working: $(ipcalc --version 2>&1 | head -1 || echo 'version unknown')"
      else
        log "WARN" "ipcalc installed but not found in PATH"
      fi
    else
      log "WARN" "$IPCALC_PKG installation failed (may not be available in repositories)"
      log "WARN" "IP validation will use regex fallback"
    fi
  else
    log "INFO" "$IPCALC_PKG already installed"
  fi

  # sipcalc (optional but recommended for IPv6)
  log "INFO" "Installing $SIPCALC_PKG..."
  if ! command -v sipcalc >/dev/null 2>&1; then
    if pkg_install "$SIPCALC_PKG" >/dev/null 2>&1; then
      log "INFO" "$SIPCALC_PKG installed successfully"
      if command -v sipcalc >/dev/null 2>&1; then
        log "INFO" "sipcalc verified working: $(sipcalc -v 2>&1 | head -1 || echo 'version unknown')"
      else
        log "WARN" "sipcalc installed but not found in PATH"
      fi
    else
      log "WARN" "$SIPCALC_PKG installation failed (may not be available in repositories)"
      log "WARN" "IPv6 validation will be limited"
    fi
  else
    log "INFO" "$SIPCALC_PKG already installed"
  fi

  # Verify critical packages
  local failed_packages=()
  for cmd in nft fail2ban-client whois; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      failed_packages+=("$cmd")
    fi
  done
  
  if (( ${#failed_packages[@]} > 0 )); then
    die "Critical packages failed to install: ${failed_packages[*]}"
  fi

  log "INFO" "All packages installed. Checking IP validation capabilities..."
  check_ip_validation_tools || log "WARN" "Limited IP validation available (regex only)"
}

# --- Directory structure ------------------------------------------------------
create_dir_structure() {
  log "INFO" "Creating directory structure under $TARGET_DIR"
  mkdir -p "$TARGET_DIR"/{config,scripts,logs,backups,templates,bin,rules,conf.d,systemd} || die "Failed to create directory structure"
  mkdir -p "$TARGET_DIR/templates/control-panels"
  mkdir -p "$LOG_DIR" /var/log/nftban /var/backups
  # symlink logs
  if [[ ! -L "$TARGET_DIR/logs" ]]; then
    rm -rf "$TARGET_DIR/logs" 2>/dev/null || true
    ln -sf "$LOG_DIR" "$TARGET_DIR/logs"
    log "INFO" "Symlink created from $TARGET_DIR/logs to $LOG_DIR"
  fi
  chmod 0755 "$TARGET_DIR" "$TARGET_DIR"/{config,scripts,backups,templates,bin,rules,conf.d,systemd}
  chmod 0755 "$LOG_DIR" /var/log/nftban /var/backups
  chmod 0640 "$LOGFILE" 2>/dev/null || true
  log "INFO" "Directory structure created"
}

# --- Control panel detection / templates -------------------------------------
get_ssh_port() {
  local ssh_port
  if ssh_port=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1); then
    [[ -n "$ssh_port" ]] && echo "$ssh_port" || echo "22"
  else
    echo "22"
  fi
}

create_generic_template() {
  local template_file="$TARGET_DIR/templates/control-panels/generic.conf"
  local ssh_port
  ssh_port=$(get_ssh_port)
  log "INFO" "Creating generic configuration template with SSH port: $ssh_port"
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
    log "INFO" "Generic configuration template created: $template_file"; return 0
  else
    log "ERROR" "Failed to create generic configuration template"; return 1
  fi
}

prompt_for_generic_config() {
  local ssh_port
  ssh_port=$(get_ssh_port)
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
    log "INFO" "Auto-accepting generic configuration due to -y flag"; return 0
  fi
  while true; do
    read -r -p "Create the simple default configuration now? (y/n): " -n 1 REPLY
    echo
    case $REPLY in
      [Yy]) log "INFO" "User selected to create generic configuration"; return 0;;
      [Nn]) log "INFO" "User declined to create generic configuration"; return 1;;
      *)    echo "Please answer y or n.";;
    esac
  done
}

create_empty_configs() {
  local config_dir="$TARGET_DIR/config"
  mkdir -p "$config_dir"
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
  local timestamp
  timestamp=$(date)
  for file in "${files[@]}"; do
    local full_path="$config_dir/$file"
    cat > "$full_path" <<EMPTY_EOF
# Empty configuration - manually configure as needed
# Generated on: $timestamp
#
# Format for port files:
#   portT (TCP), portU (UDP), portB (Both)
#   Example: 80T, 53U, 22B
#
# Format for whitelist files:
#   One IP address per line (IPv4 or IPv6)
#   Example: 192.168.1.1, 10.0.0.0/8, 2001:db8::1
EMPTY_EOF
    log "INFO" "Created empty configuration: $full_path"
  done
  log "INFO" "Empty configuration files created. Manual configuration required."
}

detect_control_panel() {
  log "INFO" "Checking for running control panel..."
  if [ -d "/usr/local/directadmin/" ]; then
    log "INFO" "DirectAdmin detected."
    PANEL="directadmin"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/directadmin.conf"
    return 0
  elif [ -d "/var/cpanel/" ]; then
    log "INFO" "cPanel detected."
    PANEL="cpanel"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/cpanel.conf"
    return 0
  elif [ -d "/usr/local/psa/" ]; then
    log "INFO" "Plesk detected."
    PANEL="plesk"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/plesk.conf"
    return 0
  else
    log "INFO" "No common control panel (DirectAdmin, cPanel, Plesk) detected."
    if prompt_for_generic_config; then
      PANEL="generic"
      if create_generic_template; then
        CONFIG_FILE="$TARGET_DIR/templates/control-panels/generic.conf"
        return 0
      else
        log "ERROR" "Failed to create generic configuration template"
        return 1
      fi
    else
      log "INFO" "User declined generic configuration. Creating empty config files."
      create_empty_configs
      return 2
    fi
  fi
}

process_control_panel_config() {
  local config_file="$1"
  local panel_name="$2"
  local config_dir="$TARGET_DIR/config"
  mkdir -p "$config_dir"
  
  local TCP4_IN="$config_dir/nftban-configuration-ipv4-ports-input-allow.conf.local"
  local TCP4_OUT="$config_dir/nftban-configuration-ipv4-ports-output-allow.conf.local"
  local TCP6_IN="$config_dir/nftban-configuration-ipv6-ports-input-allow.conf.local"
  local TCP6_OUT="$config_dir/nftban-configuration-ipv6-ports-output-allow.conf.local"
  local USER_WHITELIST="$config_dir/nftban-configuration-user-whitelist_ips.conf.local"

  local validation_status
  if command -v ipcalc >/dev/null 2>&1; then
    validation_status="ipcalc available"
  elif command -v sipcalc >/dev/null 2>&1; then
    validation_status="sipcalc available"
  else
    validation_status="regex fallback"
  fi

  local timestamp
  timestamp=$(date)
  for file in "$TCP4_IN" "$TCP4_OUT" "$TCP6_IN" "$TCP6_OUT" "$USER_WHITELIST"; do
    cat > "$file" <<CONFIG_HEADER
# Configuration file generated on: $timestamp
# Control Panel: $panel_name
# IP Validation: $validation_status
# Format: portT (TCP), portU (UDP), portB (Both) for port files
# Format: One IP address per line for whitelist files
CONFIG_HEADER
  done

  if [ ! -f "$config_file" ]; then
    log "ERROR" "Configuration file $config_file not found!"
    return 1
  fi

  log "INFO" "Processing configuration file: $config_file"
  
  # Counters for validation statistics
  local total_ips=0 valid_ips=0 invalid_ips=0
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    line=$(echo "$line" | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//')
    [[ -n "$line" ]] || continue
    
    case "$line" in
      TCP_IN*)
        local ports
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP input ports" >> "$TCP4_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP4_IN"
          done
          echo "" >> "$TCP4_IN"
          log "INFO" "Added TCP input ports: $ports"
        fi
        ;;
      TCP_OUT*)
        local ports
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP output ports" >> "$TCP4_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP4_OUT"
          done
          echo "" >> "$TCP4_OUT"
          log "INFO" "Added TCP output ports: $ports"
        fi
        ;;
      TCP6_IN*)
        local ports
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 input ports" >> "$TCP6_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP6_IN"
          done
          echo "" >> "$TCP6_IN"
          log "INFO" "Added TCP6 input ports: $ports"
        fi
        ;;
      TCP6_OUT*)
        local ports
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 output ports" >> "$TCP6_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^\s*//;s/\s*$//')
            [[ -n "$port" ]] && echo "${port}T" >> "$TCP6_OUT"
          done
          echo "" >> "$TCP6_OUT"
          log "INFO" "Added TCP6 output ports: $ports"
        fi
        ;;
      IP_ADDRESS*)
        local ips
        ips=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ips" ]]; then
          echo "# $panel_name panel IP addresses" >> "$USER_WHITELIST"
          echo "$ips" | tr ',' '\n' | while IFS= read -r ip; do
            ip=$(echo "$ip" | sed 's/^\s*//;s/\s*$//')
            if [[ -n "$ip" ]]; then
              ((total_ips++))
              if validate_ip "$ip"; then
                echo "$ip" >> "$USER_WHITELIST"
                ((valid_ips++))
                log "INFO" "Added IP to whitelist (validated): $ip"
              else
                ((invalid_ips++))
                log "WARN" "Invalid IP address (skipped): $ip"
                if [[ "$IP_VALIDATION_STRICT" == "true" ]]; then
                  echo "# INVALID: $ip" >> "$USER_WHITELIST"
                fi
              fi
            fi
          done
          echo "" >> "$USER_WHITELIST"
        fi
        ;;
    esac
  done < "$config_file"
  
  # Log validation statistics
  if (( total_ips > 0 )); then
    log "INFO" "IP Validation Summary: $valid_ips valid, $invalid_ips invalid out of $total_ips total"
    if (( invalid_ips > 0 )); then
      log "WARN" "Some IP addresses were rejected. Review $USER_WHITELIST for details."
    fi
  fi
  
  log "INFO" "Configuration processed using $panel_name configuration"
  return 0
}

run_control_panel_detection() {
  if [[ "$SKIP_CP_DETECT" == "true" ]]; then
    log "INFO" "Skipping control panel detection (--skip-cp-detect flag)"
    return 0
  fi
  
  if [[ "$ASSUME_Y" == "false" ]] && ! ask_yes_no "Do you want to detect control panel and setup default ports?" "Y"; then
    log "INFO" "Skipping control panel detection"
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
  
  log "INFO" "Starting control panel detection and default ports setup..."
  
  # Initialize variables
  PANEL=""
  CONFIG_FILE=""
  
  # Detect panel
  detect_control_panel
  local panel_detection_result=$?
  
  case $panel_detection_result in
    0)
      log "INFO" "Panel configuration: $PANEL"
      log "INFO" "Config file: $CONFIG_FILE"
      
      if [[ -f "$CONFIG_FILE" ]]; then
        if process_control_panel_config "$CONFIG_FILE" "$PANEL"; then
          echo ""
          echo "=== Control Panel Detection Complete ==="
          echo "Detected: $PANEL"
          echo "Configuration applied successfully"
          echo "Files are ready for nftables initialization"
          echo "========================================="
          
          log "INFO" "Control panel detection and configuration completed successfully"
          return 0
        else
          log "ERROR" "Failed to process configuration"
          return 1
        fi
      else
        log "ERROR" "Configuration file $CONFIG_FILE not found"
        return 1
      fi
      ;;
    2)
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
      
      log "INFO" "Empty configuration files created. Manual configuration required."
      return 0
      ;;
    *)
      log "ERROR" "Panel detection failed with code: $panel_detection_result"
      return 1
      ;;
  esac
}

# --- Download Methods ---
backup_existing() {
  if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]]; then
    local ts bkp
    ts="$(date +%Y%m%d_%H%M%S)"
    bkp="/var/backups/nftban_${ts}.tgz"
    log "INFO" "Backing up existing $TARGET_DIR to $bkp"
    tar -czf "$bkp" -C / "${TARGET_DIR#/}" 2>/dev/null || true
  fi
}

net_check() {
  log "INFO" "Checking network connectivity..."
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsI --connect-timeout 5 "https://github.com" >/dev/null 2>&1; then
      log "WARN" "Cannot reach https://github.com"
      if [[ "$ASSUME_Y" == "false" ]]; then
        ask_yes_no "Network check failed. Continue anyway?" "N" || die "Aborted by user"
      fi
    else
      log "INFO" "Network connectivity verified"
    fi
  else
    log "WARN" "curl not available, skipping network check"
  fi
}

stage_prepare() { WORK_DIR="$(mktemp -d /tmp/nftban_init.XXXXXX)"; }

do_github_flow() {
  log "INFO" "Selected: GitHub flow (branch: $BRANCH)"
  ensure_tools git curl
  net_check
  stage_prepare
  mkdir -p "$TARGET_DIR"
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log "INFO" "Existing repo found. Syncing..."
    pushd "$TARGET_DIR" >/dev/null || die "Failed to change to $TARGET_DIR"
    git fetch --all --quiet || true
    git reset --hard "origin/$BRANCH" --quiet || true
    git pull --rebase --quiet || true
    popd >/dev/null || die "Failed to return from $TARGET_DIR"
  else
    pushd "$WORK_DIR" >/dev/null || die "Failed to change to $WORK_DIR"
    git clone --quiet --branch "$BRANCH" "$REPO_URL" repo
    install -d "$TARGET_DIR"
    cp -a repo/. "$TARGET_DIR/"
    popd >/dev/null || die "Failed to return from $WORK_DIR"
  fi
}

do_zip_flow() {
  log "INFO" "Selected: ZIP flow"
  ensure_tools curl unzip
  net_check
  stage_prepare
  pushd "$WORK_DIR" >/dev/null || die "Failed to change to $WORK_DIR"
  local zip="$WORK_DIR/nftban.zip"
  log "INFO" "Downloading archive: $ZIP_URL"
  curl -fsSL "$ZIP_URL" -o "$zip" || die "Failed to download ZIP."
  if [[ ! -s "$zip" ]]; then
    die "Download failed (empty file)."
  fi
  log "INFO" "Testing archive"
  unzip -t "$zip" >/dev/null 2>&1 || die "Corrupt ZIP archive."
  log "INFO" "Extracting archive"
  unzip -q "$zip" -d "$WORK_DIR"
  local extracted
  extracted="$(find "$WORK_DIR" -maxdepth 1 -type d -name 'nftban-*' -print -quit)"
  [[ -n "$extracted" ]] || die "Could not find extracted folder within ZIP."
  backup_existing
  rm -rf "$TARGET_DIR"
  mkdir -p "$(dirname "$TARGET_DIR")"
  mv "$extracted" "$TARGET_DIR"
  popd >/dev/null || die "Failed to return from $WORK_DIR"
}

# --- nftban Binary Creation ---
create_basic_nftban_binary() {
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
    log "INFO" "Installed repo CLI to: $BIN"
  else
    # no repo CLI; use the real system CLI if it already exists
    if [[ -x "$REAL_BIN" || -f "$REAL_BIN" ]]; then
      BIN="$REAL_BIN"
      log "INFO" "Using existing system CLI: $BIN"
    else
      # last resort: write a tiny stub
      cat > "${TARGET_DIR}/bin/nftban" <<'NFTBAN_EOF'
#!/usr/bin/env bash
echo "nftban is not installed here. Expected real CLI at: /etc/nftban/bin/nftban" >&2
echo "If it exists, relink with: sudo ln -sf /etc/nftban/bin/nftban /usr/local/bin/nftban" >&2
exit 1
NFTBAN_EOF
      chmod 0755 "${TARGET_DIR}/bin/nftban"
      BIN="${TARGET_DIR}/bin/nftban"
      log "WARN" "Created minimal stub at ${BIN}; real CLI not found."
    fi
  fi

  # ensure executable
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

  log "INFO" "Symlink ensured: ${LINK} -> ${BIN}"
}

# --- Auto-update functionality ------------------------------------------------
print_json_status() {
  local enabled="false" lines=0
  local tmpfile
  tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  lines=$(grep -c -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" 2>/dev/null || echo 0)
  rm -f "$tmpfile"
  if [[ "$lines" -gt 0 ]]; then enabled="true"; fi
  printf '{"auto_update_enabled":%s,"auto_update_lines":%s,"target_dir":"%s"}\n' "$enabled" "$lines" "$TARGET_DIR"
}

show_status() {
  log "INFO" "nftban path: $TARGET_DIR"
  if command -v nft >/dev/null 2>&1; then
    log "INFO" "nftables: $(nft --version 2>/dev/null | head -1)"
  else
    log "WARN" "nft not found"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    log "INFO" "fail2ban: $(fail2ban-client --version 2>/dev/null | head -1 | tr -s ' ')"
  else
    log "WARN" "fail2ban not found"
  fi
  
  # IP validation tools status
  log "INFO" "IP Validation Tools:"
  if command -v ipcalc >/dev/null 2>&1; then
    log "INFO" "  - ipcalc: $(ipcalc --version 2>&1 | head -1 || echo 'installed')"
  else
    log "WARN" "  - ipcalc: NOT INSTALLED"
  fi
  
  if command -v sipcalc >/dev/null 2>&1; then
    log "INFO" "  - sipcalc: $(sipcalc -v 2>&1 | head -1 || echo 'installed')"
  else
    log "WARN" "  - sipcalc: NOT INSTALLED"
  fi
  
  if [[ -f "/etc/systemd/system/nftban.service" ]]; then
    log "INFO" "systemd unit present: /etc/systemd/system/nftban.service"
  else
    log "INFO" "systemd unit not found (optional)"
  fi
  auto_update_status
}

auto_update_status() {
  local tmpfile
  tmpfile="$(mktemp)"
  crontab -l 2>/dev/null | tee "$tmpfile" >/dev/null || true
  mapfile -t cron_lines < <(grep -F "$AUTO_UPDATE_SCRIPT" "$tmpfile" || true)
  rm -f "$tmpfile"

  local count="${#cron_lines[@]}"
  if [[ "$count" -gt 0 ]]; then
    log "INFO" "Auto-update via crontab: ENABLED ($count entr$([[ $count -eq 1 ]] && echo 'y' || echo 'ies'))."
    printf '%s\n' "${cron_lines[@]}" | sed 's/^/  • /'
  else
    log "INFO" "Auto-update via crontab: DISABLED (no matching crontab lines)."
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
    log "INFO" "Auto-update script: $AUTO_UPDATE_SCRIPT"
    log "INFO" "  size: ${sz} bytes, modified: ${mtime}, sha256: ${sha}"
  else
    log "WARN" "Auto-update script not found at: $AUTO_UPDATE_SCRIPT"
  fi
}

cron_sanity_check() {
  if command -v systemctl >/dev/null 2>&1; then
    if ! (systemctl is-enabled cron >/dev/null 2>&1 || systemctl is-enabled crond >/dev/null 2>&1); then
      log "WARN" "cron service appears disabled. Auto-update may not run."
    fi
    if ! (systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1); then
      log "WARN" "cron service is not active. Consider: systemctl start cron (or crond)."
    fi
  fi
}

ensure_single_cron_entry() {
  local entry="$1"
  local tmpfile
  tmpfile="$(mktemp)" || die "Failed to create temp file"
  
  # Ensure cleanup even if script fails
  trap 'rm -f "$tmpfile"' RETURN
  
  # Get existing crontab, removing old entries
  if ! crontab -l 2>/dev/null | grep -vF "$AUTO_UPDATE_SCRIPT" > "$tmpfile"; then
    : > "$tmpfile"
  fi
  
  # Add new entry
  printf '%s\n' "$entry" >> "$tmpfile"
  
  # Install new crontab
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    if ! crontab "$tmpfile" 2>/dev/null; then
      log "ERROR" "Failed to install crontab"
      return 1
    fi
  else
    log "INFO" "DRY-RUN: would install crontab entry: $entry"
  fi
  
  return 0
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
    local HH MM
    HH="${DAILY_TIME%%:*}"
    MM="${DAILY_TIME##*:}"
    CRON_LINE="${MM} ${HH} * * * $AUTO_UPDATE_SCRIPT >/dev/null 2>&1"
    log "INFO" "Configuring auto-update daily at ${DAILY_TIME}"
  else
    CRON_LINE="0 */12 * * * $AUTO_UPDATE_SCRIPT >/dev/null 2>&1"
    log "INFO" "Configuring auto-update every 12 hours"
  fi
  ensure_single_cron_entry "$CRON_LINE"
  cron_sanity_check
  log "INFO" "Auto-update cron installed. Use --auto-update-status to check."
}

remove_auto_update() {
  local tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' RETURN
  
  crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_SCRIPT" > "$tmpfile" || true
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    crontab "$tmpfile" 2>/dev/null || true
  else
    log "INFO" "DRY-RUN: would remove existing crontab entries for $AUTO_UPDATE_SCRIPT"
  fi
  
  if [[ -f "$AUTO_UPDATE_SCRIPT" ]]; then
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
      rm -f "$AUTO_UPDATE_SCRIPT"
    else
      log "INFO" "DRY-RUN: would remove $AUTO_UPDATE_SCRIPT"
    fi
    log "INFO" "Removed auto-update script: $AUTO_UPDATE_SCRIPT"
  fi
  log "INFO" "Auto-update cron entries removed (if any existed)."
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
    local CURRENT_VERSION
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
  run_control_panel_detection
  
  # Optional installer if repo provides one
  if [[ -x "$TARGET_DIR/install.sh" ]]; then
    log "INFO" "Running repo installer: $TARGET_DIR/install.sh"
    (cd "$TARGET_DIR" && bash ./install.sh) | tee -a "$LOGFILE"
  fi

  # Optional systemd unit: install but DO NOT enable or start
  if [[ -f "$TARGET_DIR/systemd/nftban.service" ]]; then
    log "INFO" "Installing systemd unit nftban.service (not enabling/starting)"
    install -m 0644 "$TARGET_DIR/systemd/nftban.service" /etc/systemd/system/nftban.service
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log "INFO" "You may enable later with: systemctl enable --now nftban.service"
  fi
  
  create_symlink
  set_permissions
  show_completion_summary
}

create_symlink() {
  local TARGET="$TARGET_DIR/bin/nftban"
  local LINK="/usr/local/bin/nftban"

  if [ ! -f "$TARGET" ]; then
    log "WARN" "Target file $TARGET does not exist, but continuing..."
  elif [ -L "$LINK" ]; then
    log "INFO" "Symlink already exists: $LINK -> $(readlink -f "$LINK")"
  else
    log "INFO" "Creating symlink..."
    ln -s "$TARGET" "$LINK"
    log "INFO" "Symlink created: $LINK -> $TARGET"
  fi
}

set_permissions() {
  log "INFO" "Setting executable permissions..."
  find "$TARGET_DIR/scripts" -type f -name "*.sh" ! -perm -111 -exec chmod +x {} \; 2>/dev/null || true
  if [[ -f "$TARGET_DIR/bin/nftban" ]]; then
    chmod +x "$TARGET_DIR/bin/nftban"
  fi
}

# --- Enhanced Uninstall -------------------------------------------------------
uninstall_service_unit() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nftban.service >/dev/null 2>&1 || true
    systemctl disable nftban.service >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/systemd/system/nftban.service ]]; then
    rm -f /etc/systemd/system/nftban.service
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log "INFO" "Removed /etc/systemd/system/nftban.service"
  fi
  if command -v rc-update >/dev/null 2>&1; then
    rc-update del nftban default >/dev/null 2>&1 || true
  fi
}

do_uninstall() {
  log "INFO" "Uninstall requested"
  if ! ask_yes_no "Proceed to uninstall nftban from $TARGET_DIR?" "Y"; then
    log "INFO" "Uninstall aborted by user"
    exit 0
  fi

  uninstall_service_unit

  if [[ -L "/usr/local/bin/nftban" ]]; then
    rm -f "/usr/local/bin/nftban"
    log "INFO" "Removed symlink /usr/local/bin/nftban"
  fi

  if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
    log "INFO" "Removed $TARGET_DIR"
  fi

  remove_auto_update

  if [[ "$DO_PURGE" == "true" ]]; then
    rm -rf "$LOG_DIR" /var/log/nftban
    log "INFO" "Purged $LOG_DIR and /var/log/nftban"
  else
    log "INFO" "Keeping logs/state (use --purge to remove)"
  fi

  log "INFO" "Uninstall complete"
  exit 0
}

# --- Completion Summary ---
show_completion_summary() {
  echo ""
  echo "=== INSTALLATION COMPLETE ==="
  ui success "Installation finished successfully!"
  echo "Packages installed:"
  echo "  - nftables"
  echo "  - $FAIL2BAN_PKG"
  echo "  - $WHOIS_PKG" 
  echo "  - $DNSUTILS_PKG"
  echo "  - $IPCALC_PKG"
  echo "  - $SIPCALC_PKG"
  echo ""
  echo "nftban linked to /usr/local/bin/nftban"
  echo ""
  echo "Scripts are executable"

  # Enhanced status reporting for control panel detection
  if [[ "$SKIP_CP_DETECT" == "false" ]]; then
    local CONFIG_FILE_COUNT=0
    local config_file
    for config_file in "$TARGET_DIR/config/nftban-configuration-"*.conf.local; do
      if [[ -f "$config_file" ]]; then
        CONFIG_FILE_COUNT=$((CONFIG_FILE_COUNT + 1))
      fi
    done
    
    if [[ $CONFIG_FILE_COUNT -gt 0 ]]; then
      echo ""
      echo "=== CONTROL PANEL CONFIGURATION ==="
      
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
          local SSH_PORT_USED
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
          local total_lines comment_lines empty_lines entry_count filename
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

  # Conditional step 3 based on config files
  local CONFIG_FILE_COUNT=0 TOTAL_ENTRIES=0
  local file config_file
  for config_file in "$TARGET_DIR/config/nftban-configuration-"*.conf.local; do
    if [[ -f "$config_file" ]]; then
      CONFIG_FILE_COUNT=$((CONFIG_FILE_COUNT + 1))
    fi
  done

  if [[ $CONFIG_FILE_COUNT -gt 0 ]]; then
    for file in "$TARGET_DIR/config/nftban-configuration-"*".conf.local"; do
      if [[ -f "$file" ]]; then
        local total_lines comment_lines empty_lines file_entries
        total_lines=$(wc -l < "$file" 2>/dev/null)
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

  echo "=== LOG FILES ==="
  echo "Installation log: $LOGFILE"
  
  local latest_cp_log
  latest_cp_log=$(find "$LOG_DIR" -maxdepth 1 -name "cp_detection_*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  
  if [[ -n "$latest_cp_log" ]]; then
    echo "Control panel detection log: $latest_cp_log"
  fi
  echo "================================="

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
  cat <<EOF
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
  • Ensure required packages are present (nftables, fail2ban, whois, dns utils, ipcalc, sipcalc)
  • (Optional) Detect a control panel and suggest sensible default ports
  • Validate IP addresses using ipcalc/sipcalc
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

  # Check status with JSON output
  sudo $0 --status --json

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
      --beginner)           BEGINNER_MODE="true"; shift ;;
      --no-color)           NO_COLOR="true"; shift ;;
      --no-unicode)         UNICODE_ICONS="false"; shift ;;
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
  
  if [[ "$BEGINNER_MODE" == "true" ]]; then
    ui title "nftban Unified Installer"
    ui info  "Version: $VERSION"
    ui step  "We will prepare your system and set up nftban in a few easy steps."
    ui tip   "Nothing starts automatically; you remain in control."
    echo ""
  fi

  log "INFO" "nftban Unified Installation Script starting"
  log "INFO" "Version: $VERSION"
  log "INFO" "Target directory: $TARGET_DIR"

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
    git) do_github_flow; post_fetch ;;
    zip) do_zip_flow; post_fetch ;;
    local)
      log "INFO" "Proceeding with basic local installation"
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

  log "INFO" "Installation completed successfully"
}

# --- Script Execution ---
main "$@"
