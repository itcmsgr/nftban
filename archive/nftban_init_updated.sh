#!/usr/bin/env bash
set -euo pipefail

################################################################################
# nftban Unified Installation & Maintenance Script
#
# Version: 3.1.0 (Updated for nftban_init_nftables_conf.sh v2.3.0)
# Description: Comprehensive nftban installer with enhanced functionality
# Features:
# - GitHub repository sync with fallback ZIP download
# - Installs nftables, fail2ban, whois, and DNS utilities
# - Enhanced control panel detection (DirectAdmin, cPanel, Plesk, generic)
# - Creates template files ONLY (no .conf.local population)
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
VERSION="3.1.0"
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

create_all_control_panel_templates() {
  local template_dir="$TARGET_DIR/templates/control-panels"
  mkdir -p "$template_dir"
  
  log INFO "Creating control panel configuration templates..."
  
  # DirectAdmin template
  cat > "$template_dir/directadmin.conf" <<'EOF'
# DirectAdmin Control Panel Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv4)
TCP_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# TCP Input Ports (IPv6)
TCP6_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv6)
TCP6_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# UDP Input Ports (IPv4)
UDP_IN = "53"

# UDP Output Ports (IPv4)
UDP_OUT = "53"

# UDP Input Ports (IPv6)
UDP6_IN = "53"

# UDP Output Ports (IPv6)
UDP6_OUT = "53"

# Control Panel IP Addresses (comma-separated, optional)
# IP_ADDRESS = "192.168.1.100,2001:db8::1"
EOF
  log INFO "Created DirectAdmin template"

  # cPanel template
  cat > "$template_dir/cpanel.conf" <<'EOF'
# cPanel/WHM Control Panel Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "20,21,22,25,26,53,80,110,143,443,465,587,993,995,2077,2078,2082,2083,2086,2087,2089,2095,2096,3306"

# TCP Output Ports (IPv4)
TCP_OUT = "20,21,22,25,37,43,53,80,110,113,443,587,873,993,995,2089"

# TCP Input Ports (IPv6)
TCP6_IN = "20,21,22,25,26,53,80,110,143,443,465,587,993,995,2077,2078,2082,2083,2086,2087,2089,2095,2096,3306"

# TCP Output Ports (IPv6)
TCP6_OUT = "20,21,22,25,37,43,53,80,110,113,443,587,873,993,995,2089"

# UDP Input Ports (IPv4)
UDP_IN = "53,123"

# UDP Output Ports (IPv4)
UDP_OUT = "53,123"

# UDP Input Ports (IPv6)
UDP6_IN = "53,123"

# UDP Output Ports (IPv6)
UDP6_OUT = "53,123"

# Control Panel IP Addresses (comma-separated, optional)
# IP_ADDRESS = ""
EOF
  log INFO "Created cPanel template"

  # Plesk template
  cat > "$template_dir/plesk.conf" <<'EOF'
# Plesk Control Panel Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,3306,5432,8443,8880"

# TCP Output Ports (IPv4)
TCP_OUT = "20,21,22,25,53,80,110,113,443,587,993,995"

# TCP Input Ports (IPv6)
TCP6_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,3306,5432,8443,8880"

# TCP Output Ports (IPv6)
TCP6_OUT = "20,21,22,25,53,80,110,113,443,587,993,995"

# UDP Input Ports (IPv4)
UDP_IN = "53,123"

# UDP Output Ports (IPv4)
UDP_OUT = "53,123"

# UDP Input Ports (IPv6)
UDP6_IN = "53,123"

# UDP Output Ports (IPv6)
UDP6_OUT = "53,123"

# Control Panel IP Addresses (comma-separated, optional)
# IP_ADDRESS = ""
EOF
  log INFO "Created Plesk template"

  # Generic template
  local ssh_port; ssh_port=$(get_ssh_port)
  cat > "$template_dir/generic.conf" <<EOF
# Generic Server Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "${ssh_port},25,53,80,443"

# TCP Output Ports (IPv4)
TCP_OUT = "${ssh_port},25,53,80,443"

# TCP Input Ports (IPv6)
TCP6_IN = "${ssh_port},25,53,80,443"

# TCP Output Ports (IPv6)
TCP6_OUT = "${ssh_port},25,53,80,443"

# UDP Input Ports (IPv4)
UDP_IN = "53"

# UDP Output Ports (IPv4)
UDP_OUT = "53"

# UDP Input Ports (IPv6)
UDP6_IN = "53"

# UDP Output Ports (IPv6)
UDP6_OUT = "53"

# Control Panel IP Addresses (comma-separated, optional)
# IP_ADDRESS = ""
EOF
  log INFO "Created Generic template with SSH port: $ssh_port"
  
  log INFO "All control panel templates created successfully"
}

create_empty_user_configs() {
  local config_dir="$TARGET_DIR/config"
  mkdir -p "$config_dir"
  
  log INFO "Creating empty user configuration files (.conf.local)..."
  
  # Port configuration files with helpful headers
  for file in "ipv4-ports-input-allow" "ipv4-ports-output-allow" "ipv6-ports-input-allow" "ipv6-ports-output-allow"; do
    local full_path="$config_dir/nftban-configuration-${file}.conf.local"
    cat > "$full_path" <<'EOF'
# User Port Configuration (YOUR CUSTOMIZATIONS)
# Generated by nftban_init.sh
# 
# This file is for YOUR custom ports - it will NEVER be overwritten
# System ports from control panel are in .conf files (auto-managed)
#
# ============================================================================
# IMPORTANT: Do NOT edit .conf files - edit THIS (.conf.local) file instead!
# ============================================================================
#
# Format: PORTRANGE?PROTOCOL
#
# Protocol codes:
# T = TCP only
# U = UDP only
# B = Both TCP and UDP
#
# Examples:
# 8080T          - Allow TCP port 8080
# 53U            - Allow UDP port 53 (DNS)
# 3000-3010T     - Allow TCP ports 3000-3010
# 9000B          - Allow TCP and UDP port 9000
#
# One entry per line. Comments allowed with '#'
#
# After editing this file, run:
# sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
#
EOF
    log INFO "Created empty config: $(basename "$full_path")"
  done
  
  # IP whitelist/blacklist files
  for file in "user-whitelist_ips" "user-blacklist_ips"; do
    local full_path="$config_dir/nftban-configuration-${file}.conf.local"
    cat > "$full_path" <<'EOF'
# User IP Configuration (YOUR CUSTOMIZATIONS)
# Generated by nftban_init.sh
#
# This file is for YOUR custom IPs - it will NEVER be overwritten
#
# Format: One IP address per line (IPv4 or IPv6)
#
# Examples:
# 192.168.1.100          - Single IPv4
# 10.0.0.0/8             - IPv4 CIDR range
# 2001:db8::1            - Single IPv6
# 2001:db8::/48          - IPv6 CIDR range
#
# One entry per line. Comments allowed with '#'
#
# After editing this file, run:
# sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
#
EOF
    log INFO "Created empty config: $(basename "$full_path")"
  done
  
  # Other config files
  for file in "ipv4-blacklist_ips" "ipv6-blacklist_ips" "f2b-ips_temp-blacklists_conf"; do
    local full_path="$config_dir/nftban-configuration-${file}.conf.local"
    cat > "$full_path" <<EOF
# Configuration file - Generated on: $(date)
# One entry per line. Comments allowed with '#'
EOF
    log INFO "Created empty config: $(basename "$full_path")"
  done
  
  log INFO "All empty user configuration files created"
}

detect_control_panel() {
  log INFO "Detecting control panel..."
  
  if [ -d "/usr/local/directadmin/" ]; then
    log INFO "DirectAdmin detected"
    echo "directadmin"
    return 0
  elif [ -d "/var/cpanel/" ]; then
    log INFO "cPanel detected"
    echo "cpanel"
    return 0
  elif [ -d "/usr/local/psa/" ]; then
    log INFO "Plesk detected"
    echo "plesk"
    return 0
  else
    log INFO "No control panel detected"
    echo "generic"
    return 0
  fi
}

run_control_panel_detection() {
  if [[ "$SKIP_CP_DETECT" == "true" ]]; then
    log INFO "Skipping control panel detection (--skip-cp-detect flag)"
    create_empty_user_configs
    return 0
  fi
  
  log INFO "=== Control Panel Template Creation ==="
  echo ""
  
  # Always create all templates
  create_all_control_panel_templates
  
  # Detect which panel is installed
  local detected_panel
  detected_panel=$(detect_control_panel)
  
  echo ""
  ui title "Control Panel Detection Result"
  case "$detected_panel" in
    directadmin)
      ui success "DirectAdmin detected"
      echo "  Template: $TARGET_DIR/templates/control-panels/directadmin.conf"
      ;;
    cpanel)
      ui success "cPanel/WHM detected"
      echo "  Template: $TARGET_DIR/templates/control-panels/cpanel.conf"
      ;;
    plesk)
      ui success "Plesk detected"
      echo "  Template: $TARGET_DIR/templates/control-panels/plesk.conf"
      ;;
    generic)
      ui info "No control panel detected - using generic template"
      echo "  Template: $TARGET_DIR/templates/control-panels/generic.conf"
      ;;
  esac
  
  echo ""
  ui info "Template files are ready for nftban_init_nftables_conf.sh"
  echo ""
  
  # Create empty user config files
  create_empty_user_configs
  
  echo ""
  ui success "Template creation complete!"
  echo ""
  ui tip "The actual port configuration will be done by nftban_init_nftables_conf.sh"
  echo "    which will read these templates and merge with your custom settings."
  echo ""
  
  log INFO "Control panel detection completed - templates created"
  return 0
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
      # last resort: write a tiny stub
      cat > "${TARGET_DIR}/bin/nftban" <<'NFTBAN_EOF'
#!/usr/bin/env bash
echo "nftban is not fully installed. Run nftban_init.sh with --github or --zip for full functionality." >&2
exit 1
NFTBAN_EOF
      chmod 0755 "${TARGET_DIR}/bin/nftban"
      BIN="${TARGET_DIR}/bin/nftban"
      log WARN "Created minimal stub at ${BIN}; full CLI requires --github or --zip"
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

  log INFO "Symlink ensured: ${LINK} -> ${BIN}"
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
  
  # Run control panel detection (creates templates only)
  run_control_panel_detection
  
  # Optional installer if repo provides one
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

# --- Enhanced Uninstall -------------------------------------------------------
uninstall_service_unit() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nftban.service >/dev/null 2>&1 || true
    systemctl disable nftban.service >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/systemd/system/nftban.service ]]; then
    rm -f /etc/systemd/system/nftban.service
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    log INFO "Removed /etc/systemd/system/nftban.service"
  fi
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

  if [[ -L "/usr/local/bin/nftban" ]]; then
    rm -f "/usr/local/bin/nftban"
    log INFO "Removed symlink /usr/local/bin/nftban"
  fi

  if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
    log INFO "Removed $TARGET_DIR"
  fi

  remove_auto_update

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
  ui success "Installation finished successfully!"
  echo ""
  echo "Packages installed:"
  echo "  - nftables"
  echo "  - $FAIL2BAN_PKG"
  echo "  - $WHOIS_PKG"
  echo "  - $DNSUTILS_PKG"
  echo ""
  echo "nftban linked to /usr/local/bin/nftban"
  echo ""

  # Control panel template status
  echo "=== CONTROL PANEL TEMPLATES ==="
  local detected_panel
  detected_panel=$(detect_control_panel)
  
  case "$detected_panel" in
    directadmin)
      ui success "DirectAdmin template ready"
      ;;
    cpanel)
      ui success "cPanel/WHM template ready"
      ;;
    plesk)
      ui success "Plesk template ready"
      ;;
    generic)
      ui info "Generic template ready"
      ;;
  esac
  
  echo "Templates location: $TARGET_DIR/templates/control-panels/"
  echo "User config files: $TARGET_DIR/config/*.conf.local"
  echo ""
  ui tip "Templates are ready but NOT YET APPLIED"
  echo "    Configuration will be applied by nftban_init_nftables_conf.sh"
  echo "=================================="
  echo ""

  echo "=== NEXT STEPS (IMPORTANT!) ==="
  echo ""
  echo "1. Initialize nftables firewall rules:"
  echo "   This will detect your control panel and configure ports automatically"
  if [[ -f "$TARGET_DIR/scripts/nftban_init_nftables_conf.sh" ]]; then
    echo ""
    ui step "sudo $TARGET_DIR/scripts/nftban_init_nftables_conf.sh --install-final"
    echo ""
    echo "   What this does:"
    echo "   • Detects control panel ($detected_panel)"
    echo "   • Reads template from templates/control-panels/"
    echo "   • Writes system ports to .conf files"
    echo "   • Merges with your .conf.local customizations"
    echo "   • Generates and applies nftables rules"
  else
    ui warn "nftables initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
  fi
  echo ""

  echo "2. Initialize fail2ban configuration:"
  if [[ -f "$TARGET_DIR/scripts/nftban_init_fail2ban_conf.sh" ]]; then
    echo "   sudo $TARGET_DIR/scripts/nftban_init_fail2ban_conf.sh"
  else
    ui warn "fail2ban initialization script not found"
    echo "   Enable GitHub sync to get the full script suite"
  fi
  echo ""

  echo "3. (Optional) Customize your configuration:"
  echo "   Before or after running step 1, you can add custom ports:"
  echo ""
  echo "   Edit: $TARGET_DIR/config/*.conf.local"
  echo ""
  echo "   Example - add custom port 8080:"
  echo "   echo '8080T' >> $TARGET_DIR/config/nftban-configuration-ipv4-ports-input-allow.conf.local"
  echo ""
  echo "   Then re-run step 1 to apply changes"
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

  echo "=== IMPORTANT NOTES ==="
  ui warn "Configuration files (.conf.local) are EMPTY and need review"
  echo "    • System will apply control panel template automatically"
  echo "    • Add YOUR custom ports/IPs to .conf.local files"
  echo "    • Run nftban_init_nftables_conf.sh to apply configuration"
  echo ""
  
  ui tip "Architecture:"
  echo "    • .conf files = System (auto-managed from templates)"
  echo "    • .conf.local files = Your customizations (preserved)"
  echo "    • Both are merged by nftban_init_nftables_conf.sh"
  echo ""

  echo "=== LOG FILES ==="
  echo "Installation log: $LOGFILE"
  echo "Templates created in: $TARGET_DIR/templates/control-panels/"
  echo "================================="
  echo ""

  if [[ "$FORCE_FLOW" == "git" ]] || [[ "$FORCE_FLOW" == "zip" ]]; then
    ui success "Installation completed successfully with repository sync!"
  else
    ui warn "Installation completed with basic functionality only."
    echo "For full features, consider using --github or --zip flags."
  fi
  echo ""
  
  ui step "Next: Run nftban_init_nftables_conf.sh to configure your firewall!"
  echo ""
}

# --- Enhanced Usage -----------------------------------------------------------
usage() {
  cat <<EOF
###############################################
# nftban Installer (v${VERSION})
###############################################

Quick start (recommended):
  sudo $0 --github -y                         # Install from GitHub
  sudo $0 --github -y --enable-auto-update    # + keep it up to date via cron

If GitHub is blocked:
  sudo $0 --zip -y                             # Download & install from ZIP

What this installer does:
  • Creates directory structure under /etc/nftban
  • Installs required packages (nftables, fail2ban, whois, etc.)
  • Detects control panel (DirectAdmin, cPanel, Plesk)
  • Creates configuration TEMPLATES (does not configure ports yet)
  • Creates empty .conf.local files for your customizations
  • Does NOT start or enable services automatically

Configuration workflow:
  1. nftban_init.sh (this script) → Creates templates
  2. nftban_init_nftables_conf.sh → Applies configuration from templates

Common options:
  --github                 Use Git to sync the repository
  --zip                    Use ZIP download instead of Git
  --target DIR             Install directory (default: /etc/nftban)
  --branch NAME            Git branch (default: main)
  --skip-cp-detect         Skip control panel detection
  --enable-auto-update     Set up a cron job to keep nftban updated
  --remove-auto-update     Remove the auto-update cron job
  --auto-update-status     Show auto-update status
  --status [--json]        Show overall status
  --daily-time HH:MM       With --enable-auto-update: run daily at HH:MM
  --beginner               Friendlier, step-by-step messages
  --no-color               Disable colored output
  --no-unicode             Use plain ASCII icons
  -y                       Assume "yes" to prompts
  -h, --help               Show this help

Uninstall:
  sudo $0 --uninstall -y
  sudo $0 --uninstall --purge -y   # also remove logs/state

Examples:
  # Install to custom path
  sudo $0 --zip -y --target /opt/nftban

  # Enable daily auto-update at 03:30
  sudo $0 --enable-auto-update --daily-time "03:30"

  # Skip control panel detection
  sudo $0 --github -y --skip-cp-detect

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
    git) do_github_flow; post_fetch ;;
    zip) do_zip_flow; post_fetch ;;
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
