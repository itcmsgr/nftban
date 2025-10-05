#!/usr/bin/env bash

# --- Version Check and Auto-Update ---
VERSION="3.0.0"
VERSION_FILE="/etc/nftban/.version"
AUTO_UPDATE_SCRIPT="/etc/nftban/scripts/nftban_auto_update.sh"

check_version() {
    if [ -f "$VERSION_FILE" ]; then
        CURRENT_VERSION=$(cat "$VERSION_FILE")
        if [ "$CURRENT_VERSION" != "$VERSION" ]; then
            echo "New version detected: $VERSION (was $CURRENT_VERSION)"
            echo "$VERSION" > "$VERSION_FILE"
        fi
    else
        echo "$VERSION" > "$VERSION_FILE"
        echo "Version file created: $VERSION"
    fi
}

setup_auto_update() {
    mkdir -p "$(dirname "$AUTO_UPDATE_SCRIPT")"
    cat > "$AUTO_UPDATE_SCRIPT" <<EOF
#!/bin/bash
REPO_URL="https://github.com/itcmsgr/nftban"
BRANCH="main"
TARGET_DIR="/etc/nftban"

cd "\$TARGET_DIR" || exit 1
if [ -d .git ]; then
    git fetch --quiet
    git reset --hard "origin/\$BRANCH" --quiet
    git pull --quiet
fi
EOF
    chmod +x "$AUTO_UPDATE_SCRIPT"

    # Add crontab entry if not already present
    (crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_SCRIPT"; echo "0 */12 * * * $AUTO_UPDATE_SCRIPT >/dev/null 2>&1") | crontab -
}

#!/usr/bin/env bash
set -euo pipefail

################################################################################
# nftban Unified Installation Script
#
# Version: 3.0.0
# Description: Comprehensive nftban installer with enhanced functionality
# Features:
# - GitHub repository sync with fallback ZIP download
# - Installs nftables, fail2ban, whois, and DNS utilities
# - Enhanced control panel detection (DirectAdmin, cPanel, Plesk, generic)
# - Complete directory structure and configuration templates
# - Comprehensive uninstall functionality with purge options
# - No automatic service start/enable (manual control)
# - Package manager support: apt, dnf, yum, zypper, apk
#
# ** NOTE: THIS SCRIPT MUST BE RUN AS ROOT!
#
# Usage:
#   sudo ./nftban_init.sh [options]
#
# Options:
#   --github            Force Git flow without prompting
#   --zip               Force ZIP flow without prompting
#   --target DIR        Install directory (default: /etc/nftban)
#   --branch NAME       Git branch (default: main)
#   --uninstall         Run uninstall flow
#   --purge             With --uninstall: remove logs/state dirs too
#   -y                  Assume "yes" to prompts
#   --skip-cp-detect    Skip control panel detection
#   --help              Show help
#
# Examples:
#   sudo ./nftban_init.sh --github
#   sudo ./nftban_init.sh --zip --target /opt/nftban
#   sudo ./nftban_init.sh --uninstall --purge -y
################################################################################

# --- Configuration ---
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

# Package definitions
FAIL2BAN_PKG="fail2ban"
WHOIS_PKG="whois"
DNSUTILS_DEB="dnsutils"
DNSUTILS_RHEL="bind-utils"

umask 022

# --- Utility Functions ---
log() {
  local lvl="${1:-INFO}"; shift || true
  local msg="$*"
  mkdir -p "$(dirname "$LOGFILE")"
  printf "[%s] %s %s\n" "$lvl" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOGFILE" >&2
}

die() {
  log "ERROR" "$*"
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "This script must be run as root (use: sudo $0 ...)" >&2
    exit 1
  fi
}

# --- Package Manager Detection ---
detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_TOOL="apt"
    PKG_INSTALL="apt-get update -y && apt-get install -y"
# Helper to install packages without using eval (addresses SC2294).
pkg_install() {
  # Usage: pkg_install pkg1 [pkg2 ...]
  # Detect package manager from PKG_INSTALL string and run native command preserving args safely.
  case "$PKG_INSTALL" in
    apt-get*)
      apt-get update -y >/dev/null && apt-get install -y "$@"
      ;;
    dnf*)
      dnf install -y "$@"
      ;;
    yum*)
      yum install -y "$@"
      ;;
    zypper*)
      zypper --non-interactive install -y "$@"
      ;;
    apk*)
      apk add --no-cache "$@"
      ;;
    *)
      # Fallback: last resort, still avoid word-splitting for args
      # shellcheck disable=SC2294
      eval "$PKG_INSTALL" "$@"
      ;;
  esac
}
    PKG_REMOVE="apt-get remove -y"
    PKG_PURGE="apt-get purge -y"
    # PKG_QUERY="dpkg -s"  # Unused; commented out to satisfy SC2034
    PKG_CHECK="dpkg -l"
    DNSUTILS_PKG="$DNSUTILS_DEB"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_TOOL="dnf"
    PKG_INSTALL="dnf install -y"
    PKG_REMOVE="dnf remove -y"
    PKG_PURGE="$PKG_REMOVE"
    # PKG_QUERY="rpm -q"  # Unused; commented out to satisfy SC2034
    PKG_CHECK="rpm -q"
    DNSUTILS_PKG="$DNSUTILS_RHEL"
  elif command -v yum >/dev/null 2>&1; then
    PKG_TOOL="yum"
    PKG_INSTALL="yum install -y"
    PKG_REMOVE="yum remove -y"
    PKG_PURGE="$PKG_REMOVE"
    # PKG_QUERY="rpm -q"  # Unused; commented out to satisfy SC2034
    PKG_CHECK="rpm -q"
    DNSUTILS_PKG="$DNSUTILS_RHEL"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_TOOL="zypper"
    PKG_INSTALL="zypper --non-interactive install -y"
    PKG_REMOVE="zypper --non-interactive remove -y"
    PKG_PURGE="$PKG_REMOVE"
    # PKG_QUERY="rpm -q"  # Unused; commented out to satisfy SC2034
    PKG_CHECK="rpm -q"
    DNSUTILS_PKG="$DNSUTILS_RHEL"
  elif command -v apk >/dev/null 2>&1; then
    PKG_TOOL="apk"
    PKG_INSTALL="apk add --no-cache"
    PKG_REMOVE="apk del"
    PKG_PURGE="$PKG_REMOVE"
    # PKG_QUERY="apk info -e"  # Unused; commented out to satisfy SC2034
    PKG_CHECK="apk info -e"
    DNSUTILS_PKG="bind-tools"
  else
    die "Supported package manager not found (apt/dnf/yum/zypper/apk)."
  fi
}

pkg_present() {
  local pkg="$1"
  if command -v "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${PKG_CHECK:-}" ]]; then
    eval "$PKG_CHECK \"$pkg\"" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

ensure_tools() {
  detect_pm
  local missing=()
  for t in "$@"; do
    if ! pkg_present "$t"; then
      missing+=("$t")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log INFO "Installing missing tools: ${missing[*]}"
    pkg_install "${missing[@]}" >/dev/null
  fi
}

ask_yes_no() {
  local prompt="$1"; local def="${2:-Y}"
  if [[ "$ASSUME_Y" == "true" ]]; then
    [[ "$def" =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  local suffix="[Y/n]"; [[ "$def" =~ ^[Nn]$ ]] && suffix="[y/N]"
  local ans
  while true; do
    read -r -p "$prompt $suffix " ans || ans=""
    ans="${ans:-$def}"
    case "$ans" in
      Y|y|yes|YES) return 0;;
      N|n|no|NO)   return 1;;
      *) echo "Please answer y or n." ;;
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
  local id_like
  id_like="$(get_os_release_var ID_LIKE || true)"
  if [[ "${PKG_TOOL:-}" == "dnf" || "${PKG_TOOL:-}" == "yum" ]]; then
    return 0
  fi
  [[ "$id_like" == *"rhel"* || "$id_like" == *"fedora"* || "$id_like" == *"centos"* ]] && return 0 || return 1
}

# --- EPEL Repository Installation ---
install_epel_if_needed() {
  detect_pm
  if ! is_rhel_like; then
    return 0
  fi
  
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
      # Fallback to direct RPM installation
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

# --- Package Installation ---
install_packages() {
  detect_pm
  log INFO "Starting package installation using $PKG_TOOL"
  
  # Update package cache for Debian/Ubuntu
  if [[ "$PKG_TOOL" == "apt" ]]; then
    log INFO "Updating package cache..."
    apt-get update -y >/dev/null 2>&1
  fi
  
  # EPEL check for RHEL-like systems
  if is_rhel_like; then
    install_epel_if_needed
  fi
  
  # Confirm package installation
  local packages_to_install="$FAIL2BAN_PKG, $WHOIS_PKG, $DNSUTILS_PKG, nftables"
  if [[ "$ASSUME_Y" == "false" ]] && ! ask_yes_no "Do you want to proceed with installing $packages_to_install?" "Y"; then
    log INFO "Package installation cancelled by user. Exiting..."
    exit 1
  fi
  
  # Install nftables
  log INFO "Installing nftables..."
  if ! pkg_present nft; then
    pkg_install nftables >/dev/null 2>&1 || die "Failed to install nftables"
    log INFO "nftables installed successfully"
  else
    log INFO "nftables already installed"
  fi
  
  # Install Fail2Ban
  log INFO "Installing $FAIL2BAN_PKG..."
  if ! $PKG_CHECK "$FAIL2BAN_PKG" >/dev/null 2>&1; then
    pkg_install $FAIL2BAN_PKG >/dev/null 2>&1 || die "Failed to install $FAIL2BAN_PKG"
    log INFO "$FAIL2BAN_PKG installed successfully"
  else
    log INFO "$FAIL2BAN_PKG already installed"
  fi
  
  # Install whois
  log INFO "Installing $WHOIS_PKG..."
  if ! $PKG_CHECK "$WHOIS_PKG" >/dev/null 2>&1; then
    pkg_install $WHOIS_PKG >/dev/null 2>&1 || die "Failed to install $WHOIS_PKG"
    log INFO "$WHOIS_PKG installed successfully"
  else
    log INFO "$WHOIS_PKG already installed"
  fi
  
  # Install dnsutils/bind-utils
  log INFO "Installing $DNSUTILS_PKG..."
  if ! $PKG_CHECK "$DNSUTILS_PKG" >/dev/null 2>&1; then
    pkg_install $DNSUTILS_PKG >/dev/null 2>&1 || die "Failed to install $DNSUTILS_PKG"
    log INFO "$DNSUTILS_PKG installed successfully"
  else
    log INFO "$DNSUTILS_PKG already installed"
  fi
  
  log INFO "All packages installed successfully"
  log INFO "NOTE: Services are installed but not enabled/started (manual control)"
}

# --- Directory Structure Creation ---
create_dir_structure() {
  log INFO "Creating directory structure under $TARGET_DIR"
  
  # Main directories
  mkdir -p "$TARGET_DIR"/{config,scripts,logs,backups,templates,bin,rules,conf.d,systemd} || die "Failed to create directory structure"
  mkdir -p "$TARGET_DIR/templates/control-panels"
  
  # System directories
  mkdir -p "$LOG_DIR" /var/lib/nftban /var/backups
  
  # Create symlink for logs if it doesn't exist
  if [[ ! -L "$TARGET_DIR/logs" ]]; then
    rm -rf "$TARGET_DIR/logs" 2>/dev/null || true
    ln -sf "$LOG_DIR" "$TARGET_DIR/logs"
    log INFO "Symlink created from $TARGET_DIR/logs to $LOG_DIR"
  fi
  
  # Set permissions
  chmod 0755 "$TARGET_DIR" "$TARGET_DIR"/{config,scripts,backups,templates,bin,rules,conf.d,systemd}
  chmod 0755 "$LOG_DIR" /var/lib/nftban /var/backups
  chmod 0640 "$LOGFILE" 2>/dev/null || true
  
  log INFO "Directory structure created successfully"
}

# --- Control Panel Detection ---
get_ssh_port() {
  local ssh_port
  ssh_port=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
  if [[ -z "$ssh_port" ]]; then
    ssh_port="22"
  fi
  echo "$ssh_port"
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]
}

is_ipv6() {
  [[ "$1" =~ : ]] && [[ "$1" != *.* ]]
}

create_generic_template() {
  local template_file="$TARGET_DIR/templates/control-panels/generic.conf"
  local ssh_port
  ssh_port=$(get_ssh_port)
  
  log INFO "Creating generic configuration template with SSH port: $ssh_port"
  
  mkdir -p "$(dirname "$template_file")"
  
  cat > "$template_file" << 'TEMPLATE_EOF'
# Generic server configuration
# This file contains basic ports for a typical web server setup
# 
# Format:
# TCP_IN="port1,port2,port3"    - Inbound TCP ports
# TCP_OUT="port1,port2,port3"   - Outbound TCP ports  
# TCP6_IN="port1,port2,port3"   - Inbound TCP IPv6 ports
# TCP6_OUT="port1,port2,port3"  - Outbound TCP IPv6 ports
# IP_ADDRESS="ip1,ip2,ip3"      - IP addresses to whitelist

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

  # Replace SSH port placeholder
  sed -i "s/SSH_PORT_PLACEHOLDER/$ssh_port/g" "$template_file"
  
  if [[ -f "$template_file" ]]; then
    log INFO "Generic configuration template created successfully: $template_file"
    return 0
  else
    log INFO "ERROR: Failed to create generic configuration template"
    return 1
  fi
}

prompt_for_generic_config() {
  local ssh_port
  ssh_port=$(get_ssh_port)
  
  echo ""
  echo "======================================================"
  echo "No control panel detected on this system."
  echo "======================================================"
  echo ""
  echo "Would you like to create a generic configuration with basic web server ports?"
  echo ""
  echo "This will include:"
  echo "  - SSH port: $ssh_port (detected from /etc/ssh/sshd_config)"
  echo "  - HTTP port: 80"
  echo "  - HTTPS port: 443"
  echo "  - DNS port: 53 (outbound)"
  echo "  - NTP port: 123 (outbound)"
  echo ""
  echo "You can customize these ports later by editing the configuration files."
  echo ""
  
  if [[ "$ASSUME_Y" == "true" ]]; then
    log INFO "Auto-accepting generic configuration due to -y flag"
    return 0
  fi
  
  while true; do
    read -p "Create generic configuration? (y/n): " -n 1 -r
    echo
    case $REPLY in
      [Yy])
        log INFO "User selected to create generic configuration"
        return 0
        ;;
      [Nn])
        log INFO "User declined to create generic configuration"
        return 1
        ;;
      *)
        echo "Please answer y or n."
        ;;
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
  
  for file in "${files[@]}"; do
    local full_path="$config_dir/$file"
    cat > "$full_path" << 'EMPTY_EOF'
# Empty configuration - manually configure as needed
# Generated on: TIMESTAMP_PLACEHOLDER
# 
# Format for port files:
# portT (TCP), portU (UDP), portB (Both)
# Example: 80T, 53U, 22B
#
# Format for whitelist files:
# One IP address per line (IPv4 or IPv6)
# Example: 192.168.1.1, 10.0.0.0/8, 2001:db8::1

EMPTY_EOF
    # Replace timestamp placeholder
    sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "$full_path"
    log INFO "Created empty configuration: $full_path"
  done
  
  log INFO "Empty configuration files created. Manual configuration required."
}

detect_control_panel() {
  log INFO "Checking for running control panel..."
  
  if [ -d "/usr/local/directadmin/" ]; then
    log INFO "DirectAdmin detected."
    PANEL="directadmin"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/directadmin.conf"
    return 0
  elif [ -d "/var/cpanel/" ]; then
    log INFO "cPanel detected."
    PANEL="cpanel"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/cpanel.conf"
    return 0
  elif [ -d "/usr/local/psa/" ]; then
    log INFO "Plesk detected."
    PANEL="plesk"
    CONFIG_FILE="$TARGET_DIR/templates/control-panels/plesk.conf"
    return 0
  else
    log INFO "No common control panel (DirectAdmin, cPanel, Plesk) detected."
    
    # Interactive prompt for generic configuration
    if prompt_for_generic_config; then
      PANEL="generic"
      # Create the template first
      if create_generic_template; then
        CONFIG_FILE="$TARGET_DIR/templates/control-panels/generic.conf"
        return 0
      else
        log INFO "ERROR: Failed to create generic configuration template"
        return 1
      fi
    else
      log INFO "User declined generic configuration. Creating empty config files."
      create_empty_configs
      return 2
    fi
  fi
}

process_control_panel_config() {
  local config_file="$1"
  local panel_name="$2"
  
  # Use config directory
  local config_dir="$TARGET_DIR/config"
  mkdir -p "$config_dir"
  
  local TCP4_IN="$config_dir/nftban-configuration-ipv4-ports-input-allow.conf.local"
  local TCP4_OUT="$config_dir/nftban-configuration-ipv4-ports-output-allow.conf.local"
  local TCP6_IN="$config_dir/nftban-configuration-ipv6-ports-input-allow.conf.local"
  local TCP6_OUT="$config_dir/nftban-configuration-ipv6-ports-output-allow.conf.local"
  local USER_WHITELIST="$config_dir/nftban-configuration-user-whitelist_ips.conf.local"
  
  # Initialize files with headers
  for file in "$TCP4_IN" "$TCP4_OUT" "$TCP6_IN" "$TCP6_OUT" "$USER_WHITELIST"; do
    cat > "$file" << CONFIG_HEADER
# Configuration file generated on: $(date)
# Control Panel: $panel_name
# Format: portT (TCP), portU (UDP), portB (Both) for port files
# Format: One IP address per line for whitelist files

CONFIG_HEADER
  done
  
  if [ ! -f "$config_file" ]; then
    log INFO "ERROR: Configuration file $config_file not found!"
    return 1
  fi
  
  log INFO "Processing configuration file: $config_file"
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove comments and trim whitespace
    line=$(echo "$line" | sed 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [ -z "$line" ]; then
      continue
    fi
    
    case "$line" in
      TCP_IN*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP input ports" >> "$TCP4_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$port" ] && echo "${port}T" >> "$TCP4_IN"
          done
          echo "" >> "$TCP4_IN"
          log INFO "Added TCP input ports: $ports"
        fi
        ;;
      TCP_OUT*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP output ports" >> "$TCP4_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$port" ] && echo "${port}T" >> "$TCP4_OUT"
          done
          echo "" >> "$TCP4_OUT"
          log INFO "Added TCP output ports: $ports"
        fi
        ;;
      TCP6_IN*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 input ports" >> "$TCP6_IN"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$port" ] && echo "${port}T" >> "$TCP6_IN"
          done
          echo "" >> "$TCP6_IN"
          log INFO "Added TCP6 input ports: $ports"
        fi
        ;;
      TCP6_OUT*)
        ports=$(echo "$line" | cut -d'"' -f2)
        if [[ -n "$ports" ]]; then
          echo "# $panel_name panel TCP IPv6 output ports" >> "$TCP6_OUT"
          echo "$ports" | tr ',' '\n' | while IFS= read -r port; do
            port=$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$port" ] && echo "${port}T" >> "$TCP6_OUT"
          done
          echo "" >> "$TCP6_OUT"
          log INFO "Added TCP6 output ports: $ports"
        fi
        ;;
      IP_ADDRESS*)
        ips=$(echo "$line" | cut -d'"' -f2)
        if [ -n "$ips" ]; then
          echo "# $panel_name panel IP addresses" >> "$USER_WHITELIST"
          echo "$ips" | tr ',' '\n' | while IFS= read -r ip; do
            ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$ip" ]; then
              if is_ipv4 "$ip" || is_ipv6 "$ip"; then
                echo "$ip" >> "$USER_WHITELIST"
                log INFO "Added IP to whitelist: $ip"
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
  if [[ -d "$TARGET_DIR" ]]; then
    local ts bkp
    ts="$(date +%Y%m%d_%H%M%S)"
    bkp="/var/backups/nftban_${ts}.tgz"
    log INFO "Backing up existing $TARGET_DIR to $bkp"
    tar -czf "$bkp" -C / "${TARGET_DIR#/}" 2>/dev/null || true
  fi
}

net_check() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsI "https://github.com" >/dev/null 2>&1 || log INFO "Note: Unable to reach https://github.com (continuing anyway)."
  fi
}

stage_prepare() {
  WORK_DIR="$(mktemp -d /tmp/nftban_init.XXXXXX)"
}

do_github_flow() {
  log INFO "Selected: GitHub flow (branch: $BRANCH)"
  ensure_tools git curl
  net_check
  stage_prepare
  
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log INFO "Existing git repo found at $TARGET_DIR - pulling latest"
    (cd "$TARGET_DIR" && git fetch --all && git reset --hard "origin/$BRANCH" && git pull --rebase) | tee -a "$LOGFILE"
  else
    backup_existing
    rm -rf "$TARGET_DIR"
    mkdir -p "$(dirname "$TARGET_DIR")"
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR" | tee -a "$LOGFILE"
  fi
  post_fetch
}

do_zip_flow() {
  log INFO "Selected: ZIP download flow"
  ensure_tools curl unzip
  net_check
  stage_prepare
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
  post_fetch
}

# --- nftban Binary Creation ---
create_basic_nftban_binary() {
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
VERSION="3.0.0-placeholder"

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

# --- Uninstall Functions ---
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

remove_packages_prompted() {
  detect_pm
  # Ask per package
  if ask_yes_no "Also remove fail2ban package?" "N"; then
    log INFO "Removing fail2ban package"
    eval "$PKG_REMOVE fail2ban" >/dev/null 2>&1 || eval "$PKG_PURGE fail2ban" >/dev/null 2>&1 || true
  else
    log INFO "Keeping fail2ban package"
  fi
  
  if ask_yes_no "Also remove nftables package? (WARNING: firewall tooling)" "N"; then
    log INFO "Removing nftables package"
    eval "$PKG_REMOVE nftables" >/dev/null 2>&1 || eval "$PKG_PURGE nftables" >/dev/null 2>&1 || true
  else
    log INFO "Keeping nftables package"
  fi
  
  if ask_yes_no "Also remove whois package?" "N"; then
    log INFO "Removing whois package"
    eval "$PKG_REMOVE $WHOIS_PKG" >/dev/null 2>&1 || eval "$PKG_PURGE $WHOIS_PKG" >/dev/null 2>&1 || true
  else
    log INFO "Keeping whois package"
  fi
  
  if ask_yes_no "Also remove DNS utilities package ($DNSUTILS_PKG)?" "N"; then
    log INFO "Removing $DNSUTILS_PKG package"
    eval "$PKG_REMOVE $DNSUTILS_PKG" >/dev/null 2>&1 || eval "$PKG_PURGE $DNSUTILS_PKG" >/dev/null 2>&1 || true
  else
    log INFO "Keeping $DNSUTILS_PKG package"
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

  # Purge optional data/logs if requested
  if [[ "$DO_PURGE" == "true" ]]; then
    rm -rf "$LOG_DIR" /var/lib/nftban
    log INFO "Purged $LOG_DIR and /var/lib/nftban"
  else
    log INFO "Keeping logs/state (use --purge to remove)"
  fi

  remove_packages_prompted

  log INFO "Uninstall complete"
  exit 0
}

# --- Completion Summary ---
show_completion_summary() {
  echo ""
  echo "=== INSTALLATION COMPLETE ==="
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
      
      # Determine what type of configuration was applied
      if ls "$LOG_DIR/cp_detection_"*.log >/dev/null 2>&1; then
        LATEST_LOG=$(find $LOG_DIR -maxdepth 1 -type f -name 'cp_detection_*.log' -print0 2>/dev/null | xargs -0 -r ls -1t 2>/dev/null | head -n1)
        if grep -q "DirectAdmin detected" "$LATEST_LOG" 2>/dev/null; then
          echo "DirectAdmin control panel detected and configured"
        elif grep -q "cPanel detected" "$LATEST_LOG" 2>/dev/null; then
          echo "cPanel control panel detected and configured"
        elif grep -q "Plesk detected" "$LATEST_LOG" 2>/dev/null; then
          echo "Plesk control panel detected and configured"
        elif grep -q "User selected to create generic configuration" "$LATEST_LOG" 2>/dev/null; then
          SSH_PORT_USED=$(grep -o "SSH port: [0-9]*" "$LATEST_LOG" 2>/dev/null | cut -d' ' -f3)
          echo "Generic web server configuration applied"
          echo "  - SSH port: ${SSH_PORT_USED:-22}"
          echo "  - HTTP/HTTPS ports: 80, 443"
          echo "  - DNS/NTP outbound: 53, 123"
        elif grep -q "User declined generic configuration" "$LATEST_LOG" 2>/dev/null; then
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
  echo "4. Start using nftban:"
  echo "   nftban --help"
  echo ""

  # Show relevant log files
  echo "=== LOG FILES ==="
  echo "Installation log: $LOGFILE"
  if ls "$LOG_DIR/cp_detection_"*.log >/dev/null 2>&1; then
    LATEST_CP_LOG=$(find $LOG_DIR -maxdepth 1 -type f -name 'cp_detection_*.log' -print0 2>/dev/null | xargs -0 -r ls -1t 2>/dev/null | head -n1)
    echo "Control panel detection log: $LATEST_CP_LOG"
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

# --- Usage and Argument Parsing ---
usage() {
  cat <<EOF
nftban Unified Installation Script

Usage: sudo $0 [options]

Install/update options:
  --github            Use Git clone/pull (installs git if needed)
  --zip               Download and extract main.zip
  --target DIR        Install directory (default: /etc/nftban)
  --branch NAME       Git branch (default: main)
  --skip-cp-detect    Skip control panel detection

Uninstall options:
  --uninstall         Remove nftban (service/unit, directory)
  --purge             With --uninstall: also remove logs and state directories
                      (Packages removal will be prompted separately)

General:
  -y                  Assume "yes" to prompts
  -h, --help          Show this help

Features:
  - Installs nftables, fail2ban, whois, and DNS utilities
  - Enhanced control panel detection (DirectAdmin, cPanel, Plesk)
  - Creates complete directory structure
  - GitHub repository sync or ZIP download
  - No automatic service start/enable (manual control)
  
Notes:
  - This script does NOT enable or start services automatically
  - After setup, run configuration scripts:
      /etc/nftban/scripts/nftban_init_nftables_conf.sh
      /etc/nftban/scripts/nftban_init_fail2ban_conf.sh

Examples:
  sudo $0 --github
  sudo $0 --zip --target /opt/nftban
  sudo $0 --uninstall --purge -y
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --github) FORCE_FLOW="git"; shift ;;
      --zip)    FORCE_FLOW="zip"; shift ;;
      --target) TARGET_DIR="${2:-}"; [[ -z "$TARGET_DIR" ]] && die "Missing value for --target"; shift 2 ;;
      --branch) BRANCH="${2:-}"; [[ -z "$BRANCH" ]] && die "Missing value for --branch"; shift 2 ;;
      --uninstall) DO_UNINSTALL="true"; shift ;;
      --purge)      DO_PURGE="true"; shift ;;
      --skip-cp-detect) SKIP_CP_DETECT="true"; shift ;;
      -y)       ASSUME_Y="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

# --- Main Function ---
main() {
    check_version
    setup_auto_update
  need_root
  parse_args "$@"

  log INFO "nftban Unified Installation Script starting"
  log INFO "Version: 3.0.0"
  log INFO "Target directory: $TARGET_DIR"

  if [[ "$DO_UNINSTALL" == "true" ]]; then
    do_uninstall
  fi

  # Create initial directories and log file
  mkdir -p "$LOG_DIR" /var/backups "$(dirname "$TARGET_DIR")"
  touch "$LOGFILE" || true
  chmod 0640 "$LOGFILE" || true

  if [[ "$FORCE_FLOW" == "git" ]]; then
    do_github_flow
  elif [[ "$FORCE_FLOW" == "zip" ]]; then
    do_zip_flow
  else
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
      do_github_flow
    else
      if ask_yes_no "Download ZIP archive instead?" "Y"; then
        do_zip_flow
      else
        log INFO "Proceeding with basic local installation"
        create_dir_structure
        install_packages
        create_basic_nftban_binary
        run_control_panel_detection
        create_symlink
        set_permissions
        show_completion_summary
      fi
    fi
  fi

  log INFO "Installation completed successfully"
}

# --- Script Execution ---
main "$@"
