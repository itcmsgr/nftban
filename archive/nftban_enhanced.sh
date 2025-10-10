#!/bin/bash
###################################################################################################
# Script: nftban_init_nftables_conf.sh (Enhanced with Control Panel Detection)
#
# Version: 2.3.0 (Added Control Panel Port Management)
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   Single-table nftables configuration with simplified architecture
#   - Automatic control panel detection (DirectAdmin, cPanel, Plesk, generic)
#   - Automatic port configuration based on detected panel
#   - Merges system (.conf) and user (.conf.local) configurations
#   - One global table: inet nftban_global
#   - Separate sets for user/system blacklists and temp bans
#   - Fail2ban uses temp_ban_v4 and temp_ban_v6 sets
#   - Compatible with unified nftban management script
#   - Whitelist always takes priority
#
###################################################################################################

set -euo pipefail

# --- Dependency Checks ---
echo "Checking required dependencies..."
for cmd in nft ip awk grep sed; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found. Please install it first." >&2
    exit 1
  fi
done
echo "[OK] All dependencies found"

have_cmd() { command -v "$1" &>/dev/null; }

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"
BACKUP_DIR="/etc/nftban/backups"
CONTROL_PANEL_TEMPLATES="$BASE_DIR/templates/control-panels"

# --- Logging ---
LOG_DIR="/etc/nftban/logs"
LOG_FILE="${LOG_DIR}/validation_$(date +%F).log"

# Ensure required directories exist
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$CONTROL_PANEL_TEMPLATES"
log_msg() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== NFTBAN nftables Configuration Initialization (v2.3.0) ==="
echo "Log file: $LOG_FILE"

# Config files
IPV4_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf.local"
IPV4_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf.local"
IPV6_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf.local"
IPV6_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf.local"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf.local"
USER_WHITELIST_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
USER_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-user-blacklist_ips.conf.local"
USER_CT_FILE_IPv4="$BASE_DIR/nftban-nfttables-ct-ipv4.conf.local"
USER_CT_FILE_IPv6="$BASE_DIR/nftban-nfttables-ct-ipv6.conf.local"
OUTPUT_FILE="${BASE_DIR}/nft_rules.conf.local"
FAIL2BAN_WHITELIST="$BASE_DIR/nftban-fail2ban-ip-whitelist.conf.local"
FAIL2BAN_ACTION_DIR="/etc/fail2ban/action.d"
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
FAIL2BAN_TEMP_IPS_="$BASE_DIR/nftban-configuration-f2b-ips_temp-blacklists_conf.local"
LOCK_FILE="/var/run/nftban_init.lock"

# System config files (managed by script)
IPV4_IN_SYSTEM="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf"
IPV4_OUT_SYSTEM="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf"
IPV6_IN_SYSTEM="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf"
IPV6_OUT_SYSTEM="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf"
SYSTEM_WHITELIST_BASE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf"

# --- Lock mechanism to prevent concurrent runs ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "ERROR: Another instance is already running. Exiting." >&2
  exit 1
fi

# =========================
# Control Panel Detection and Configuration
# =========================

# Detect installed control panel
detect_control_panel() {
  local panel="generic"
  
  # Check for DirectAdmin
  if [[ -d "/usr/local/directadmin" ]] || [[ -f "/usr/local/directadmin/directadmin" ]]; then
    panel="directadmin"
    log_msg "[INFO] Detected control panel: DirectAdmin"
  # Check for cPanel
  elif [[ -d "/usr/local/cpanel" ]] || [[ -f "/usr/local/cpanel/cpanel" ]]; then
    panel="cpanel"
    log_msg "[INFO] Detected control panel: cPanel"
  # Check for Plesk
  elif [[ -d "/usr/local/psa" ]] || command -v plesk &>/dev/null; then
    panel="plesk"
    log_msg "[INFO] Detected control panel: Plesk"
  else
    log_msg "[INFO] No specific control panel detected, using generic configuration"
  fi
  
  echo "$panel"
}

# Parse control panel configuration file
parse_control_panel_config() {
  local panel="$1"
  local config_file="$CONTROL_PANEL_TEMPLATES/${panel}.conf"
  
  if [[ ! -f "$config_file" ]]; then
    log_msg "[WARN] Control panel config not found: $config_file"
    config_file="$CONTROL_PANEL_TEMPLATES/generic.conf"
    if [[ ! -f "$config_file" ]]; then
      log_msg "[WARN] Generic config not found either, skipping control panel port merge"
      return 1
    fi
  fi
  
  log_msg "[INFO] Loading control panel config: $config_file"
  
  # Read and parse the config file
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Parse KEY = "VALUE" format (handles with or without quotes)
    if [[ "$line" =~ ^([A-Z0-9_]+)[[:space:]]*=[[:space:]]*\"?([^\"]+)\"?[[:space:]]*$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # Remove trailing quote if present
      value="${value%\"}"
      
      # Export as environment variable for later use
      eval "PANEL_${key}=\"${value}\""
      log_msg "[DEBUG] Panel config: $key = $value"
    fi
  done < "$config_file"
  
  return 0
}

# Convert comma-separated ports to nftban format
convert_ports_to_nftban_format() {
  local ports="$1"
  local protocol="$2"  # T, U, or B
  local output_file="$3"
  
  [[ -z "$ports" ]] && return 0
  
  # Split by comma and process each port
  IFS=',' read -ra PORT_ARRAY <<< "$ports"
  for port in "${PORT_ARRAY[@]}"; do
    # Trim whitespace
    port="${port//[[:space:]]/}"
    [[ -z "$port" ]] && continue
    
    # Validate port
    if _is_port_token "$port"; then
      echo "${port}${protocol}" >> "$output_file"
    else
      log_msg "[WARN] Invalid port from control panel config: $port"
    fi
  done
}

# Merge control panel ports into system configuration
merge_control_panel_ports() {
  local panel="$1"
  
  log_msg "--- Merging control panel ($panel) port configuration ---"
  
  # Parse control panel config
  if ! parse_control_panel_config "$panel"; then
    log_msg "[WARN] Failed to parse control panel config, skipping merge"
    return 0
  fi
  
  # Create system .conf files (these are managed by the script)
  for sysfile in "$IPV4_IN_SYSTEM" "$IPV4_OUT_SYSTEM" "$IPV6_IN_SYSTEM" "$IPV6_OUT_SYSTEM"; do
    cat > "$sysfile" <<EOF
# Auto-generated system port configuration for $panel
# Generated on: $(date)
# DO NOT EDIT - This file is managed by nftban_init_nftables_conf.sh
# Use .conf.local files for custom port rules
#
# Format: PORTRANGE?PROTOCOL
# T = TCP only, U = UDP only, B = Both TCP and UDP
# Examples: 22T, 53U, 80-443B
EOF
  done
  
  # Convert and write TCP ports
  if [[ -n "${PANEL_TCP_IN:-}" ]]; then
    log_msg "[INFO] Adding TCP_IN ports: ${PANEL_TCP_IN}"
    convert_ports_to_nftban_format "$PANEL_TCP_IN" "T" "$IPV4_IN_SYSTEM"
  fi
  
  if [[ -n "${PANEL_TCP_OUT:-}" ]]; then
    log_msg "[INFO] Adding TCP_OUT ports: ${PANEL_TCP_OUT}"
    convert_ports_to_nftban_format "$PANEL_TCP_OUT" "T" "$IPV4_OUT_SYSTEM"
  fi
  
  if [[ -n "${PANEL_TCP6_IN:-}" ]]; then
    log_msg "[INFO] Adding TCP6_IN ports: ${PANEL_TCP6_IN}"
    convert_ports_to_nftban_format "$PANEL_TCP6_IN" "T" "$IPV6_IN_SYSTEM"
  fi
  
  if [[ -n "${PANEL_TCP6_OUT:-}" ]]; then
    log_msg "[INFO] Adding TCP6_OUT ports: ${PANEL_TCP6_OUT}"
    convert_ports_to_nftban_format "$PANEL_TCP6_OUT" "T" "$IPV6_OUT_SYSTEM"
  fi
  
  # Convert and write UDP ports
  if [[ -n "${PANEL_UDP_IN:-}" ]]; then
    log_msg "[INFO] Adding UDP_IN ports: ${PANEL_UDP_IN}"
    convert_ports_to_nftban_format "$PANEL_UDP_IN" "U" "$IPV4_IN_SYSTEM"
  fi
  
  if [[ -n "${PANEL_UDP_OUT:-}" ]]; then
    log_msg "[INFO] Adding UDP_OUT ports: ${PANEL_UDP_OUT}"
    convert_ports_to_nftban_format "$PANEL_UDP_OUT" "U" "$IPV4_OUT_SYSTEM"
  fi
  
  if [[ -n "${PANEL_UDP6_IN:-}" ]]; then
    log_msg "[INFO] Adding UDP6_IN ports: ${PANEL_UDP6_IN}"
    convert_ports_to_nftban_format "$PANEL_UDP6_IN" "U" "$IPV6_IN_SYSTEM"
  fi
  
  if [[ -n "${PANEL_UDP6_OUT:-}" ]]; then
    log_msg "[INFO] Adding UDP6_OUT ports: ${PANEL_UDP6_OUT}"
    convert_ports_to_nftban_format "$PANEL_UDP6_OUT" "U" "$IPV6_OUT_SYSTEM"
  fi
  
  # Handle IP addresses for whitelist
  if [[ -n "${PANEL_IP_ADDRESS:-}" ]]; then
    log_msg "[INFO] Adding control panel IPs to whitelist: ${PANEL_IP_ADDRESS}"
    
    # Create header if file doesn't exist
    if [[ ! -f "$SYSTEM_WHITELIST_BASE" ]]; then
      cat > "$SYSTEM_WHITELIST_BASE" <<EOF
# Auto-generated system whitelist
# Generated on: $(date)
# DO NOT EDIT - This file is managed by nftban_init_nftables_conf.sh
EOF
    fi
    
    # Add control panel IPs
    IFS=',' read -ra IP_ARRAY <<< "$PANEL_IP_ADDRESS"
    for ip in "${IP_ARRAY[@]}"; do
      ip="${ip//[[:space:]]/}"
      [[ -z "$ip" ]] && continue
      
      # Validate IP before adding
      local is_valid=0
      if [[ "$ip" == *:* ]]; then
        { _is_ipv6 "$ip" || _is_ipv6_cidr "$ip"; } && is_valid=1
      else
        { _is_ipv4 "$ip" || _is_ipv4_cidr "$ip"; } && is_valid=1
      fi
      
      if (( is_valid )); then
        # Check if IP is already in the file
        if ! grep -qF "$ip" "$SYSTEM_WHITELIST_BASE" 2>/dev/null; then
          echo "$ip # Control panel ($panel)" >> "$SYSTEM_WHITELIST_BASE"
        fi
      else
        log_msg "[WARN] Invalid IP from control panel config: $ip"
      fi
    done
  fi
  
  log_msg "[OK] Control panel port configuration merged"
}

# Read ports from both system and user files (combined)
read_ports_combined() {
  local system_file="$1"
  local user_file="$2"
  local temp_combined
  temp_combined=$(mktemp)
  
  # Combine system and user files
  if [[ -f "$system_file" ]]; then
    grep -v '^#' "$system_file" 2>/dev/null | grep -v '^[[:space:]]*$' >> "$temp_combined" || true
  fi
  
  if [[ -f "$user_file" ]]; then
    grep -v '^#' "$user_file" 2>/dev/null | grep -v '^[[:space:]]*$' >> "$temp_combined" || true
  fi
  
  # Remove duplicates, sort, and output
  sort -u "$temp_combined"
  rm -f "$temp_combined"
}

# Generate port rules from combined system and user files
generate_port_rules_combined() {
  local system_file="$1"
  local user_file="$2"
  local _direction="$3"  # not used functionally here, kept for future
  
  # Create temporary combined file
  local temp_combined
  temp_combined=$(mktemp)
  read_ports_combined "$system_file" "$user_file" > "$temp_combined"
  
  # Process combined file
  while read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^ *//;s/ *$//')
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    if [[ "$line" =~ ^([0-9]+(-[0-9]+)?)(([TUB]))$ ]]; then
      local port_range="${BASH_REMATCH[1]}"
      local proto="${BASH_REMATCH[3]}"
      
      if [[ "$port_range" == *"-"* ]]; then
        local start end
        start=$(echo "$port_range" | cut -d'-' -f1)
        end=$(echo "$port_range" | cut -d'-' -f2)
        if ! _is_port_token "$port_range"; then
          log_msg "[WARN] Invalid port range '$port_range'"
          continue
        fi
        for ((port=start; port<=end; port++)); do
          case "$proto" in
            T) echo "    tcp dport $port accept" ;;
            U) echo "    udp dport $port accept" ;;
            B) echo "    tcp dport $port accept"; echo "    udp dport $port accept" ;;
          esac
        done
      else
        local port="$port_range"
        if ! _is_port_token "$port"; then
          log_msg "[WARN] Invalid port '$port'"
          continue
        fi
        case "$proto" in
          T) echo "    tcp dport $port accept" ;;
          U) echo "    udp dport $port accept" ;;
          B) echo "    tcp dport $port accept"; echo "    udp dport $port accept" ;;
        esac
      fi
    else
      log_msg "[WARN] Invalid line format '$line'"
    fi
  done < "$temp_combined"
  
  rm -f "$temp_combined"
}

# Create example control panel configuration templates
create_example_panel_configs() {
  log_msg "[INFO] Creating example control panel configuration templates..."
  
  # DirectAdmin template
  cat > "$CONTROL_PANEL_TEMPLATES/directadmin.conf" <<'EOF'
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

  # cPanel template
  cat > "$CONTROL_PANEL_TEMPLATES/cpanel.conf" <<'EOF'
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

  # Plesk template
  cat > "$CONTROL_PANEL_TEMPLATES/plesk.conf" <<'EOF'
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

  # Generic template
  cat > "$CONTROL_PANEL_TEMPLATES/generic.conf" <<'EOF'
# Generic Server Port Configuration
# Format: VARIABLE = "comma,separated,ports"

# TCP Input Ports (IPv4)
TCP_IN = "22,25,53,80,443"

# TCP Output Ports (IPv4)
TCP_OUT = "22,25,53,80,443"

# TCP Input Ports (IPv6)
TCP6_IN = "22,25,53,80,443"

# TCP Output Ports (IPv6)
TCP6_OUT = "22,25,53,80,443"

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

  log_msg "[OK] Example control panel configurations created in $CONTROL_PANEL_TEMPLATES"
}

# =========================
# Stronger Validation Layer
# =========================
# Strategy:
#  1) Prefer external tools if available:
#     - IPv4/CIDR: ipcalc (or nft -c)
#     - IPv6/CIDR: sipcalc (or nft -c)
#  2) Otherwise, validate by compiling a tiny nft set with 'nft -c' (syntax-only, no apply).
#  3) Fallback to strict regex + numeric bounds.

nft_validate_element() {
  # $1: family token for nft set type (ipv4_addr|ipv6_addr)
  # $2: value to validate (e.g., 192.0.2.0/24 or 2001:db8::1-2001:db8::ffff)
  local family="$1" value="$2"
  local tmpfile
  tmpfile=$(mktemp)
  # Validate element syntax via nft -c
  {
    echo "table inet __nftban_validate__ {"
    echo " set __s__ { type $family; flags interval; elements = { $value } }"
    echo "}"
  } >"$tmpfile"
  if nft -c -f "$tmpfile" &>/dev/null; then
    rm -f "$tmpfile"
    return 0
  fi
  rm -f "$tmpfile"
  return 1
}

# IPv4 strict regex + bounds
_ipv4_octets_ok() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

# RFC 4291-style permissive IPv6 (still strict compared to previous)
_ipv6_regex_ok() {
  local ip="$1"
  # Covers full/shortened, leading/trailing ::, 1-7 groups as allowed.
  [[ "$ip" =~ ^(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(::[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})|([0-9A-Fa-f]{1,4}::([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{0,4})|(::))$ ]] || return 1
  return 0
}

_is_ipv4() {
  local ip="$1"
  if have_cmd ipcalc; then
    # ipcalc -c returns 0 for valid IPv4 address on many distros
    ipcalc -c "$ip" >/dev/null 2>&1 && return 0
  fi
  # nft -c syntax validation
  nft_validate_element "ipv4_addr" "$ip" && return 0
  # regex+bounds fallback
  _ipv4_octets_ok "$ip"
}

_is_ipv4_cidr() {
  local s="$1"
  # Prefer nft syntax validation (handles CIDR precisely)
  nft_validate_element "ipv4_addr" "$s" && return 0
  # regex + bounds fallback
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  local ip="${s%/*}" pfx="${s#*/}"
  _ipv4_octets_ok "$ip" || return 1
  (( pfx >= 0 && pfx <= 32 ))
}

_is_ipv4_interval() {
  local s="$1"
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local left="${s%-*}" right="${s#*-}"
  _ipv4_octets_ok "$left" && _ipv4_octets_ok "$right" || return 1
  # nft syntax check (interval semantics)
  nft_validate_element "ipv4_addr" "$s"
}

_is_ipv6() {
  local ip="$1"
  if have_cmd sipcalc; then
    sipcalc "$ip" >/dev/null 2>&1 && return 0
  fi
  nft_validate_element "ipv6_addr" "$ip" && return 0
  _ipv6_regex_ok "$ip"
}

_is_ipv6_cidr() {
  local s="$1"
  nft_validate_element "ipv6_addr" "$s" && return 0
  # fallback: split and check prefix
  [[ "$s" == */* ]] || return 1
  local ip="${s%/*}" pfx="${s#*/}"
  [[ "$pfx" =~ ^[0-9]{1,3}$ ]] || return 1
  (( pfx >= 0 && pfx <= 128 )) || return 1
  _ipv6_regex_ok "$ip"
}

_is_ipv6_interval() {
  local s="$1"
  [[ "$s" == *"-"* ]] || return 1
  local left="${s%-*}" right="${s#*-}"
  # nft -c is the most reliable for IPv6 intervals
  nft_validate_element "ipv6_addr" "$s" && return 0
  # fallback: regex on each endpoint
  _ipv6_regex_ok "$left" && _ipv6_regex_ok "$right"
}

_is_port_token() {
  local t="$1"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    (( t >= 1 && t <= 65535 )) && return 0 || return 1
  elif [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    (( a >= 1 && a <= 65535 && b >= 1 && b <= 65535 && a <= b )) && return 0 || return 1
  else
    return 1
  fi
}

# =========================
# Seed temporary bans (as-is)
# =========================
seed_temp_bans_from_csv() {
  local csv_file="${FAIL2BAN_TEMP_IPS:-${FAIL2BAN_TEMP_IPS_}}"
  local table="inet nftban_global"
  local set_v4="temp_ban_v4"
  local set_v6="temp_ban_v6"
  [[ -n "$csv_file" && -f "$csv_file" ]] || { echo "[INFO] No temp-bans CSV found: $csv_file (skip)"; return; }
  echo "--- Seeding temporary bans from: $csv_file ---"
  _nft_has_element() { nft get element "$table" "$1" "{ $2 }" >/dev/null 2>&1; }
  _nft_add_timeout() {
    local s="$1" ip="$2" hours="$3" cmt="$4"
    if _nft_has_element "$s" "$ip"; then
      nft delete element "$table" "$s" "{ $ip }" >/dev/null 2>&1 || true
    fi
    if nft add element "$table" "$s" "{ $ip timeout ${hours}h }" >/dev/null 2>&1; then
      echo " [OK] $ip -> $s (${hours}h) ${cmt:+# $cmt}"
    else
      echo " [FAIL] Failed to add $ip to $s with timeout ${hours}h" >&2
    fi
  }
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line="${raw//$'\r'/}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    IFS=',' read -r ip hours rest <<<"$line"
    ip="${ip//[[:space:]]/}"; hours="${hours//[[:space:]]/}"
    local comment="${rest# }"
    [[ -z "$ip" || -z "$hours" ]] && { echo " [WARN] Skip malformed row: $raw"; continue; }
    [[ "$hours" =~ ^[0-9]+$ ]] || { echo " [WARN] Invalid HOURS for $ip: $hours"; continue; }
    local family setname
    if [[ "$ip" == *:* ]]; then
      family="v6"; setname="$set_v6"
      _is_ipv6 "$ip" || { echo " [WARN] Bad IPv6: $ip"; continue; }
    else
      family="v4"; setname="$set_v4"
      { _is_ipv4 "$ip" || _is_ipv4_cidr "$ip"; } || { echo " [WARN] Bad IPv4/CIDR: $ip"; continue; }
    fi
    _nft_has_element "whitelist_${family}" "$ip" && { echo " -> Skip $ip (in whitelist_${family})"; continue; }
    _nft_has_element "user_blacklist_${family}" "$ip" && { echo " -> Skip $ip (in user_blacklist_${family})"; continue; }
    _nft_has_element "system_blacklist_${family}" "$ip" && { echo " -> Skip $ip (in system_blacklist_${family})"; continue; }
    _nft_add_timeout "$setname" "$ip" "$hours" "$comment"
  done < "$csv_file"
  echo "--- Temp-ban seeding complete ---"
}

# =========================
# Generate Fail2ban Action Config
# =========================
generate_fail2ban_action() {
  local action_file="${FAIL2BAN_ACTION_DIR}/nftban-global.conf"
  
  echo "[INFO] Generating Fail2ban action configuration..."
  
  mkdir -p "$FAIL2BAN_ACTION_DIR"
  
  cat > "$action_file" <<'FAIL2BAN_ACTION'
# Fail2ban nftables action for nftban_global table
# Uses the single global table with temp_ban sets
#
# Author: ITCMS Team
# Version: 2.3.0

[Definition]

# Option: actionstart
# Notes: Command executed on demand at the first ban (or at the start of Fail2Ban if actionstart_on_demand is set to false)
# Values: CMD
actionstart = 

# Option: actionstop
# Notes: Command executed at the stop of jail (or at the end of Fail2Ban)
# Values: CMD
actionstop = 

# Option: actioncheck
# Notes: Command executed once before each actionban command
# Values: CMD
actioncheck = nft list table inet nftban_global >/dev/null 2>&1

# Option: actionban
# Notes: Command executed when banning an IP. Take care that the command is executed with Fail2Ban user rights.
# Tags: <ip> IP address
actionban = nft add element inet nftban_global <set> { <ip> timeout <bantime>s comment "f2b-<name>" }

# Option: actionunban
# Notes: Command executed when unbanning an IP. Take care that the command is executed with Fail2Ban user rights.
# Tags: <ip> IP address
actionunban = nft delete element inet nftban_global <set> { <ip> }

[Init]

# Set name based on IP family
set = temp_ban_v4

# Default ban time (10 minutes)
bantime = 600

# Jail name
name = unknown

FAIL2BAN_ACTION

  echo "[OK] Fail2ban action created: $action_file"
  
  # Create example jail configuration
  local jail_example="${FAIL2BAN_ACTION_DIR}/nftban-global-jail-example.conf"
  cat > "$jail_example" <<'JAIL_EXAMPLE'
# Example jail configuration for nftban_global
# Place this in /etc/fail2ban/jail.d/ or /etc/fail2ban/jail.local
#
# IMPORTANT: This is an EXAMPLE only. Customize for your needs.

[DEFAULT]
# Use the nftban-global action
banaction = nftban-global[name=%(name)s, bantime="%(bantime)s", set="temp_ban_v4"]
banaction_allports = nftban-global[name=%(name)s, bantime="%(bantime)s", set="temp_ban_v4"]

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime = 1h
# For IPv4
action = nftban-global[name=sshd, bantime="%(bantime)s", set="temp_ban_v4"]
# For IPv6, use: action = nftban-global[name=sshd, bantime="%(bantime)s", set="temp_ban_v6"]

[nginx-http-auth]
enabled = false
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 2h
action = nftban-global[name=nginx-auth, bantime="%(bantime)s", set="temp_ban_v4"]

JAIL_EXAMPLE
  
  echo "[OK] Example jail config created: $jail_example"
}

# =========================
# Validation mode switch
# =========================
if [[ "${1:-}" == "--validate-only" ]]; then
  echo "--- Validating all rule sources ---"
  VALIDATION_LOG="${VALIDATION_LOG:-/var/log/nftban/validate_all_$(date +%Y-%m-%d-%H%M%S).log}"
  mkdir -p "$(dirname "$VALIDATION_LOG")"
  validate_nft_fragment() {
    local f="$1"
    if [[ -f "$f" ]]; then
      if nft -c -f "$f" 2>>"$VALIDATION_LOG"; then
        echo "[OK] Valid nft fragment: $f"
      else
        echo "[FAIL] Invalid nft fragment: $f"
        echo " -> See: $VALIDATION_LOG"
      fi
    else
      echo "[INFO] Missing file (skip): $f"
    fi
  }
  validate_ip_port_list() {
    local f="$1" kind="$2"
    [[ -f "$f" ]] || { echo "[INFO] Missing file (skip): $f"; return; }
    local total=0 ok=0 bad=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      line="${line%%#*}"
      line="${line//$'\t'/}"
      line="${line//$'\r'/}"
      line="${line// /}"
      [[ -z "$line" ]] && continue
      ((total++))
      case "$kind" in
        ports)
          if _is_port_token "$line"; then ((ok++)); else echo "[INVALID port] $line ($f)" >>"$VALIDATION_LOG"; ((bad++)); fi
        ;;
        ipv_mixed)
          if [[ "$line" == *:* ]]; then
            if { _is_ipv6 "$line" || _is_ipv6_cidr "$line" || _is_ipv6_interval "$line"; }; then ((ok++)); else echo "[INVALID ipv6] $line ($f)" >>"$VALIDATION_LOG"; ((bad++)); fi
          else
            if { _is_ipv4 "$line" || _is_ipv4_cidr "$line" || _is_ipv4_interval "$line"; }; then ((ok++)); else echo "[INVALID ipv4] $line ($f)" >>"$VALIDATION_LOG"; ((bad++)); fi
          fi
        ;;
      esac
    done < "$f"
    echo "  $f -> $ok valid / $bad invalid / $total total"
    [[ $bad -gt 0 ]] && echo " -> See: $VALIDATION_LOG"
  }
  validate_nft_fragment "$USER_CT_FILE_IPv4"
  validate_nft_fragment "$USER_CT_FILE_IPv6"
  validate_ip_port_list "$IPV4_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV4_OUT_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_OUT_PORTS_FILE" ports
  for f in "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" "$USER_BLACKLIST_FILE" "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "$FAIL2BAN_WHITELIST"; do
    validate_ip_port_list "$f" ipv_mixed
  done
  echo "Validation complete. Log saved to: $VALIDATION_LOG"
  exit 0
fi

# =========================
# Helper functions
# =========================
append_if_set() {
  local __arr_name="$1"
  local __val="${2//$'\t\r\n '/}"
  # Skip empty or comment
  [[ -z "$__val" ]] && return 0
  [[ "$__val" =~ ^[[:space:]]*# ]] && return 0

  # Determine expected type from array name
  local __type="generic"
  if [[ "$__arr_name" == *"port"* || "$__arr_name" == *"ports"* ]]; then
    __type="port"
  elif [[ "$__arr_name" == *"ipv6"* ]]; then
    __type="ipv6"
  elif [[ "$__arr_name" == *"ipv4"* ]]; then
    __type="ipv4"
  fi

  local VALIDATION_LOG="${VALIDATION_LOG:-/var/log/nftban/validation_$(date +%Y-%m-%d).log}"
  mkdir -p "$(dirname "$VALIDATION_LOG")"
  local ok=0
  case "$__type" in
    port)
      _is_port_token "$__val" && ok=1
      ;;
    ipv4)
      { _is_ipv4 "$__val" || _is_ipv4_cidr "$__val" || _is_ipv4_interval "$__val"; } && ok=1
      ;;
    ipv6)
      { _is_ipv6 "$__val" || _is_ipv6_cidr "$__val" || _is_ipv6_interval "$__val"; } && ok=1
      ;;
    *)
      ok=1
      ;;
  esac
  if (( ok )); then
    eval "$__arr_name+=(\"$__val\")"
  else
    echo "[IGNORED] Invalid entry for $__arr_name: $__val" >>"$VALIDATION_LOG"
  fi
}

dedup() { awk -v RS=' ' '!a[$0]++' <<<"${*}"; }

print_elements_from_array() {
  local -n __arr_ref="$1"
  if [[ "${#__arr_ref[@]}" -gt 0 ]]; then
    local joined
    joined=$(IFS=' '; dedup "${__arr_ref[@]}")
    set -f
    local -a __tokens=()
    read -r -a __tokens <<<"$joined"
    printf '    elements = { %s }\n' "$(IFS=,; echo "${__tokens[*]}")"
    set +f
  fi
}

get_public_ip() {
  local ip_type=$1
  local ip=""
  local services=(
    "https://api.ipify.org"
    "https://icanhazip.com"
    "https://ident.me"
    "https://ifconfig.me/ip"
  )
  for service in "${services[@]}"; do
    if command -v curl &>/dev/null; then
      if [[ "$ip_type" == "ipv4" ]]; then
        ip=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
      else
        ip=$(curl -6 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
      fi
      [[ -n "$ip" ]] && break
    elif command -v wget &>/dev/null; then
      if [[ "$ip_type" == "ipv4" ]]; then
        ip=$(wget -4 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
      else
        ip=$(wget -6 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}')
      fi
      [[ -n "$ip" ]] && break
    fi
  done
  echo "$ip"
}

get_current_user_ip() {
  # shellcheck disable=SC2153
  local ssh_client="${SSH_CLIENT%% *}"
  if [[ -n "$ssh_client" ]]; then
    echo "$ssh_client"
    return 0
  fi
  local who_output
  who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
  if [[ -n "$who_output" && "$who_output" != "0.0.0.0" ]]; then
    echo "$who_output"
    return 0
  fi
  local last_ip
  last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
  if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
    echo "$last_ip"
    return 0
  fi
  return 1
}

backup_config() {
  local file=$1
  if [[ -f "$file" ]]; then
    local backup_file
    backup_file="$BACKUP_DIR/$(basename "$file").backup.$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$file" "$backup_file"
    echo "Backup created: $backup_file"
  fi
}

cleanup_old_backups() {
  local keep_count=10
  local backup_pattern="$BACKUP_DIR/*.backup.*"
  local count
  count=$(ls -1t $backup_pattern 2>/dev/null | wc -l)
  if (( count > keep_count )); then
    echo "Cleaning up old backups (keeping last $keep_count)..."
    # shellcheck disable=SC2012
    ls -1t $backup_pattern | tail -n +$((keep_count + 1)) | xargs rm -f
  fi
}

initialize_config_from_template() {
  local config_file=$1
  local template_file
  template_file="$BASE_DIR_INIT/$(basename "$config_file" .local)"
  if [[ ! -f "$config_file" ]]; then
    if [[ -f "$template_file" ]]; then
      backup_config "$config_file" 2>/dev/null || true
      cp "$template_file" "$config_file"
      echo "Initialized: $config_file (from template)"
    else
      echo "Warning: No template found for $config_file, creating empty file"
      touch "$config_file"
    fi
  fi
}

fetch_cloudflare_ips() {
  local url=$1
  local comment=$2
  local tmpfile
  tmpfile=$(mktemp)
  if command -v wget &>/dev/null; then
    wget -q -O "$tmpfile" "$url" || { rm -f "$tmpfile"; return 1; }
  elif command -v curl &>/dev/null; then
    curl -s -o "$tmpfile" "$url" || { rm -f "$tmpfile"; return 1; }
  else
    echo "Error: Neither wget nor curl available" >&2
    rm -f "$tmpfile"; return 1
  fi
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    if ! grep -q "^$ip" "$SYSTEM_WHITELIST_FILE"; then
      echo "$ip $comment" >> "$SYSTEM_WHITELIST_FILE"
    fi
  done < "$tmpfile"
  rm -f "$tmpfile"
}

generate_port_rules() {
  local file=$1
  local _direction=$2 # not used functionally here, kept for future
  [[ -f "$file" ]] || return
  while read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | sed 's/^ *//;s/ *$//')
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^([0-9]+(-[0-9]+)?)(([TUB]))$ ]]; then
      local port_range="${BASH_REMATCH[1]}"
      local proto="${BASH_REMATCH[3]}"
      if [[ "$port_range" == *"-"* ]]; then
        local start end
        start=$(echo "$port_range" | cut -d'-' -f1)
        end=$(echo "$port_range" | cut -d'-' -f2)
        if ! _is_port_token "$port_range"; then
          echo "Warning: Invalid port range '$port_range' in $file" >&2
          continue
        fi
        for ((port=start; port<=end; port++)); do
          case "$proto" in
            T) echo "    tcp dport $port accept" ;;
            U) echo "    udp dport $port accept" ;;
            B) echo "    tcp dport $port accept"; echo "    udp dport $port accept" ;;
          esac
        done
      else
        local port="$port_range"
        if ! _is_port_token "$port"; then
          echo "Warning: Invalid port '$port' in $file" >&2
          continue
        fi
        case "$proto" in
          T) echo "    tcp dport $port accept" ;;
          U) echo "    udp dport $port accept" ;;
          B) echo "    tcp dport $port accept"; echo "    udp dport $port accept" ;;
        esac
      fi
    else
      echo "Warning: Invalid line format '$line' in $file" >&2
    fi
  done < "$file"
}

# --- Cloudflare option ---
USE_CLOUDFLARE="${NFTBAN_USE_CLOUDFLARE:-auto}"
ASSUME_Y="${ASSUME_Y:-false}"
usage() {
  cat <<'USAGE'
Usage: $0 [options]
Options:
  --cloudflare [yes|no|auto]  Include Cloudflare IP ranges in whitelist (default: auto)
  --yes-cloudflare            Shortcut for --cloudflare yes
  --no-cloudflare             Shortcut for --cloudflare no
  -y                          Assume "yes" for prompts (non-interactive friendly)
  --install-final             Run install_final_config after generation
  --silent-auto               Run in silent mode with auto-confirmation and no prompts
  --validate-only             Only validate configuration files without applying
  --dry-run                   Show what would be changed without applying (preview)
  --test                      Generate config and run 'nft -c' ONLY (simulation), no apply/copy
  --run-tests                 Run built-in unit tests and exit
  --generate-f2b-action       Generate Fail2ban action configuration
  --create-panel-templates    Create example control panel configuration templates
  -h, --help                  Show this help
USAGE
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
      N|n|no|NO)  return 1;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# --- Parse CLI args ---
INSTALL_FINAL=false
SILENT_AUTO=false
DRY_RUN=false
TEST_MODE=false
RUN_TESTS=false
GENERATE_F2B_ACTION=false
CREATE_PANEL_TEMPLATES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-final) INSTALL_FINAL=true ;;
    --silent-auto) ASSUME_Y="true"; SILENT_AUTO=true ;;
    --dry-run) DRY_RUN=true ;;
    --test) TEST_MODE=true ;;
    --run-tests) RUN_TESTS=true ;;
    --generate-f2b-action) GENERATE_F2B_ACTION=true ;;
    --create-panel-templates) CREATE_PANEL_TEMPLATES=true ;;
    --cloudflare)
      shift
      case "${1:-}" in
        yes|no|auto) USE_CLOUDFLARE="$1" ;;
        *) echo "Invalid value for --cloudflare: ${1:-<missing>}"; usage; exit 1 ;;
      esac
      ;;
    --yes-cloudflare) USE_CLOUDFLARE="yes" ;;
    --no-cloudflare)  USE_CLOUDFLARE="no" ;;
    -y) ASSUME_Y="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# --- Create panel templates if requested ---
if $CREATE_PANEL_TEMPLATES; then
  create_example_panel_configs
  echo ""
  echo "=== Control Panel Templates Created ==="
  echo "Templates directory: $CONTROL_PANEL_TEMPLATES"
  echo ""
  echo "Available templates:"
  echo "  - directadmin.conf"
  echo "  - cpanel.conf"
  echo "  - plesk.conf"
  echo "  - generic.conf"
  echo ""
  echo "Edit these files to customize port configurations for your control panel."
  exit 0
fi

# --- Generate F2B action if requested ---
if $GENERATE_F2B_ACTION; then
  generate_fail2ban_action
  echo ""
  echo "=== Fail2ban Configuration Generated ==="
  echo "Action file: ${FAIL2BAN_ACTION_DIR}/nftban-global.conf"
  echo "Example jail: ${FAIL2BAN_ACTION_DIR}/nftban-global-jail-example.conf"
  echo ""
  echo "Next steps:"
  echo "1. Review and customize the example jail configuration"
  echo "2. Copy relevant sections to /etc/fail2ban/jail.local"
  echo "3. Restart fail2ban: systemctl restart fail2ban"
  echo "4. Check status: fail2ban-client status"
  exit 0
fi

# --- Unit Test Harness (ONLY when --run-tests) ---
if $RUN_TESTS; then
  echo "=== Running unit tests ==="
  tests_total=0; tests_failed=0
  assert_true() { ((tests_total++)); if ! eval "$1"; then echo "[FAIL] $2"; ((tests_failed++)); else echo "[OK] $2"; fi }
  assert_eq() { ((tests_total++)); local expected="$1" actual="$2" name="$3"; if [[ "$expected" != "$actual" ]]; then echo "[FAIL] $name (expected='$expected', actual='$actual')"; ((tests_failed++)); else echo "[OK] $name"; fi }

  # append_if_set tests
  ipv4_whitelist=(); ipv6_whitelist=(); ports_arr=()
  append_if_set ipv4_whitelist "192.168.1.10"
  append_if_set ipv4_whitelist "256.1.1.1"        # invalid
  append_if_set ipv6_whitelist "2001:db8::1"
  append_if_set ports_arr "22"
  append_if_set ports_arr "70000"                 # invalid
  assert_eq "1" "${#ipv4_whitelist[@]}" "append_if_set ipv4 valid"
  assert_eq "1" "${#ipv6_whitelist[@]}" "append_if_set ipv6 valid"
  assert_eq "1" "${#ports_arr[@]}" "append_if_set ports valid"

  # generate_port_rules tests
  tmp_ports="$(mktemp)"
  cat >"$tmp_ports" <<'EOF'
22T
53U
80-81B
#comment
bad
EOF
  mapfile -t prules < <(generate_port_rules "$tmp_ports" "input")
  rm -f "$tmp_ports"
  # Expect 1 (22T) + 1 (53U) + 4 lines for 80-81B = 6 lines
  assert_eq "6" "${#prules[@]}" "generate_port_rules count"
  assert_true 'printf "%s\n" "${prules[@]}" | grep -q "^    tcp dport 22 accept$"' "generate_port_rules includes 22/TCP"
  assert_true 'printf "%s\n" "${prules[@]}" | grep -q "^    udp dport 53 accept$"' "generate_port_rules includes 53/UDP"
  assert_true 'printf "%s\n" "${prules[@]}" | grep -q "^    tcp dport 80 accept$"' "generate_port_rules includes 80/TCP"
  assert_true 'printf "%s\n" "${prules[@]}" | grep -q "^    udp dport 81 accept$"' "generate_port_rules includes 81/UDP"

  # IP validation tests
  assert_true '_is_ipv4 "8.8.8.8"' "IPv4 valid"
  assert_true '! _is_ipv4 "999.1.1.1"' "IPv4 invalid"
  assert_true '_is_ipv4_cidr "10.0.0.0/8"' "IPv4 CIDR valid"
  assert_true '! _is_ipv4_cidr "10.0.0.0/33"' "IPv4 CIDR invalid prefix"
  assert_true '_is_ipv6 "2001:db8::1"' "IPv6 valid"
  assert_true '! _is_ipv6 "gggg::1"' "IPv6 invalid"
  assert_true '_is_ipv6_cidr "2001:db8::/48"' "IPv6 CIDR valid"
  assert_true '! _is_ipv6_cidr "2001:db8::/129"' "IPv6 CIDR invalid prefix"
  assert_true '_is_ipv4_interval "192.168.1.1-192.168.1.9"' "IPv4 interval valid"
  assert_true '_is_ipv6_interval "2001:db8::1-2001:db8::ffff"' "IPv6 interval valid (nft -c)"

  echo "=== Unit tests: $((tests_total-tests_failed))/$tests_total passed ==="
  [[ $tests_failed -eq 0 ]] || exit 1
  exit 0
fi

# --- Decide final Cloudflare setting ---
if [[ "$USE_CLOUDFLARE" == "auto" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    if ask_yes_no "Include Cloudflare IP ranges in the whitelist?" "N"; then
      USE_CLOUDFLARE="yes"
    else
      USE_CLOUDFLARE="no"
    fi
  else
    USE_CLOUDFLARE="no"
  fi
fi

# --- Main execution ---
mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BASE_DIR_INIT" "$CONTROL_PANEL_TEMPLATES"
cleanup_old_backups

# --- Control Panel Detection and Configuration ---
DETECTED_PANEL=$(detect_control_panel)
log_msg "Detected control panel: $DETECTED_PANEL"

# Create example templates if they don't exist
if [[ ! -f "$CONTROL_PANEL_TEMPLATES/${DETECTED_PANEL}.conf" && ! -f "$CONTROL_PANEL_TEMPLATES/generic.conf" ]]; then
  log_msg "[INFO] No control panel templates found, creating defaults..."
  create_example_panel_configs
fi

# Merge control panel ports into system configuration
merge_control_panel_ports "$DETECTED_PANEL"

# Initialize config files
echo "--- Initializing configuration files ---"
CONFIG_FILES=(
  "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE"
  "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"
  "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
  "$USER_CT_FILE_IPv4" "$USER_CT_FILE_IPv6"
  "$USER_WHITELIST_FILE" "$USER_BLACKLIST_FILE"
)
for file in "${CONFIG_FILES[@]}"; do
  initialize_config_from_template "$file"
done

# Seed port configuration files with format documentation (only if empty)
for port_file in "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE" "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"; do
  if [[ ! -s "$port_file" ]]; then
    cat > "$port_file" <<'EOF'
# Port configuration for nftban (USER CUSTOMIZATIONS)
# System ports from control panel are in .conf files (auto-managed)
# Add your custom ports here - they will be merged with system ports
#
# Format: PORTRANGE?PROTOCOL
#
# Protocol codes:
# T = TCP only
# U = UDP only
# B = Both TCP and UDP
#
# Examples:
# 22T            - Allow TCP port 22 (SSH)
# 80T            - Allow TCP port 80 (HTTP)
# 443T           - Allow TCP port 443 (HTTPS)
# 53U            - Allow UDP port 53 (DNS)
# 80-443B        - Allow TCP and UDP ports 80-443
# 3000-3010T     - Allow TCP ports 3000-3010
#
# One entry per line. Comments allowed with '#'
EOF
  fi
done

# Seed USER_BLACKLIST_FILE with comments if empty
if [[ ! -s "$USER_BLACKLIST_FILE" ]]; then
  cat > "$USER_BLACKLIST_FILE" <<'EOF'
# User blacklist for nftban (manual bans)
# One entry per line; comments allowed with '#'
# Supports IPv4 / IPv6 and CIDR, e.g.:
# 203.0.113.45
# 198.51.100.0/24
# 2001:db8::dead:beef
# 2001:db8:abcd::/48
EOF
fi

echo "--- Starting nftables configuration generation ---"
echo "flush ruleset" > "$OUTPUT_FILE"

# Detect SSH port
SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"
echo "Detected SSH Port: $SSH_PORT"

# Detect server IPs
echo "--- Detecting server IP addresses ---"
SERVER_IPV4=$(ip -4 addr show 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | tr '\n' ' ')
SERVER_IPV6=$(ip -6 addr show 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/[0-9]+' | tr '\n' ' ')
SERVER_PUBLIC_IPV4=$(get_public_ip "ipv4")
SERVER_PUBLIC_IPV6=$(get_public_ip "ipv6")
CURRENT_USER_IP=$(get_current_user_ip)

# Create/update system whitelist
echo "# Auto-generated system whitelist - DO NOT EDIT MANUALLY" > "$SYSTEM_WHITELIST_FILE"
echo "# Generated on: $(date)" >> "$SYSTEM_WHITELIST_FILE"
echo "# Server interface IPv4 addresses" >> "$SYSTEM_WHITELIST_FILE"
for ip in $SERVER_IPV4; do echo "$ip" >> "$SYSTEM_WHITELIST_FILE"; done
echo "# Server interface IPv6 addresses" >> "$SYSTEM_WHITELIST_FILE"
for ip in $SERVER_IPV6; do echo "$ip" >> "$SYSTEM_WHITELIST_FILE"; done
if [[ -n "$SERVER_PUBLIC_IPV4" ]]; then
  echo "# Server public IPv4 address" >> "$SYSTEM_WHITELIST_FILE"
  echo "$SERVER_PUBLIC_IPV4" >> "$SYSTEM_WHITELIST_FILE"
fi
if [[ -n "$SERVER_PUBLIC_IPV6" ]]; then
  echo "# Server public IPv6 address" >> "$SYSTEM_WHITELIST_FILE"
  echo "$SERVER_PUBLIC_IPV6" >> "$SYSTEM_WHITELIST_FILE"
fi
if [[ -n "$CURRENT_USER_IP" ]]; then
  echo "# Current user IP address" >> "$SYSTEM_WHITELIST_FILE"
  echo "$CURRENT_USER_IP" >> "$SYSTEM_WHITELIST_FILE"
fi

# Merge system whitelist base if exists
if [[ -f "$SYSTEM_WHITELIST_BASE" ]]; then
  cat "$SYSTEM_WHITELIST_BASE" >> "$SYSTEM_WHITELIST_FILE"
fi

echo "Server IPv4 addresses: $SERVER_IPV4"
echo "Server IPv6 addresses: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

# Fetch Cloudflare IPs if requested (unchanged behavior)
if [[ "$USE_CLOUDFLARE" == "yes" ]]; then
  echo "Fetching Cloudflare IP ranges..."
  if ! grep -q "# BEGIN CLOUDFLARE" "$SYSTEM_WHITELIST_FILE" 2>/dev/null; then
    echo "" >> "$SYSTEM_WHITELIST_FILE"
    echo "# BEGIN CLOUDFLARE" >> "$SYSTEM_WHITELIST_FILE"
    fetch_cloudflare_ips "$CLOUDFLARE_IPV4_URL" "#ipv4 from cloudflare"
    fetch_cloudflare_ips "$CLOUDFLARE_IPV6_URL" "#ipv6 from cloudflare"
    echo "# END CLOUDFLARE" >> "$SYSTEM_WHITELIST_FILE"
  else
    echo "Cloudflare IPs already present, skipping..."
  fi
else
  echo "Skipping Cloudflare IP ranges"
fi

# Collect all whitelist IPs
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null \
  | grep -v '^#' | sort -u | grep -v '^$' || true)

# Remove whitelisted IPs from blacklists (same behavior; safer stderr suppression)
if [[ -f "$IPV4_BLACKLIST_FILE" ]]; then
  grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}') "$IPV4_BLACKLIST_FILE" \
    > "${IPV4_BLACKLIST_FILE}.tmp" 2>/dev/null || true
  mv "${IPV4_BLACKLIST_FILE}.tmp" "$IPV4_BLACKLIST_FILE" 2>/dev/null || true
fi
if [[ -f "$IPV6_BLACKLIST_FILE" ]]; then
  grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}') "$IPV6_BLACKLIST_FILE" \
    > "${IPV6_BLACKLIST_FILE}.tmp" 2>/dev/null || true
  mv "${IPV6_BLACKLIST_FILE}.tmp" "$IPV6_BLACKLIST_FILE" 2>/dev/null || true
fi

# Save the Fail2Ban whitelist
{
  echo "$ALL_WHITELIST_IPS"
  cat "$IPV4_BLACKLIST_FILE" 2>/dev/null | grep -v '^#' | grep -v '^$' || true
  cat "$IPV6_BLACKLIST_FILE" 2>/dev/null | grep -v '^#' | grep -v '^$' || true
} | sort -u > "$FAIL2BAN_WHITELIST"
echo "Fail2Ban whitelist saved to: $FAIL2BAN_WHITELIST"

# Build arrays
ipv4_whitelist=()
ipv6_whitelist=()
ipv4_system_blacklist=()
ipv6_system_blacklist=()
ipv4_user_blacklist=()
ipv6_user_blacklist=()

# Parse whitelist
while IFS= read -r ip || [[ -n "$ip" ]]; do
  [[ -z "$ip" || "$ip" =~ ^# ]] && continue
  ip=$(echo "$ip" | awk '{print $1}')
  if [[ "$ip" == *:* ]]; then
    append_if_set ipv6_whitelist "$ip"
  else
    append_if_set ipv4_whitelist "$ip"
  fi
done < <(echo "$ALL_WHITELIST_IPS")

# Parse system blacklists
if [[ -f "$IPV4_BLACKLIST_FILE" ]]; then
  while IFS= read -r ip || [[ -n "$ip" ]]; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv4_system_blacklist "$ip"
  done < "$IPV4_BLACKLIST_FILE"
fi
if [[ -f "$IPV6_BLACKLIST_FILE" ]]; then
  while IFS= read -r ip || [[ -n "$ip" ]]; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv6_system_blacklist "$ip"
  done < "$IPV6_BLACKLIST_FILE"
fi

# Parse user blacklist
if [[ -f "$USER_BLACKLIST_FILE" ]]; then
  while IFS= read -r ip || [[ -n "$ip" ]]; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    if [[ "$ip" == *:* ]]; then
      append_if_set ipv6_user_blacklist "$ip"
    else
      append_if_set ipv4_user_blacklist "$ip"
    fi
  done < "$USER_BLACKLIST_FILE"
fi

# Generate single global table
{
cat <<'EOF'
# ============================================================================
# NFTBAN Global Firewall Table
# Single table architecture for simplified management
# 
# Fail2ban Integration: All jails add banned IPs to temp_ban_v4/temp_ban_v6
# ============================================================================
table inet nftban_global {
  # Whitelist sets (always take priority)
  set whitelist_v4 {
    type ipv4_addr;
    flags interval;
EOF
print_elements_from_array ipv4_whitelist
cat <<'EOF'
  }
  set whitelist_v6 {
    type ipv6_addr;
    flags interval;
EOF
print_elements_from_array ipv6_whitelist
cat <<'EOF'
  }
  # User blacklist (manual bans)
  set user_blacklist_v4 {
    type ipv4_addr;
    flags interval;
    comment "Manual bans from USER_BLACKLIST_FILE";
EOF
print_elements_from_array ipv4_user_blacklist
cat <<'EOF'
  }
  set user_blacklist_v6 {
    type ipv6_addr;
    flags interval;
    comment "Manual bans from USER_BLACKLIST_FILE";
EOF
print_elements_from_array ipv6_user_blacklist
cat <<'EOF'
  }
  # System blacklist (country blocks, bulk bans)
  set system_blacklist_v4 {
    type ipv4_addr;
    flags interval;
    comment "System-managed bulk bans (countries, ranges)";
EOF
print_elements_from_array ipv4_system_blacklist
cat <<'EOF'
  }
  set system_blacklist_v6 {
    type ipv6_addr;
    flags interval;
    comment "System-managed bulk bans (countries, ranges)";
EOF
print_elements_from_array ipv6_system_blacklist
cat <<'EOF'
  }
  # Temporary bans (with timeout) - USED BY FAIL2BAN
  set temp_ban_v4 {
    type ipv4_addr;
    flags timeout;
    comment "Temporary bans from Fail2ban and nftban script";
  }
  set temp_ban_v6 {
    type ipv6_addr;
    flags timeout;
    comment "Temporary bans from Fail2ban and nftban script";
  }

  # Input chain (processes incoming traffic)
  chain input {
    type filter hook input priority -150;
    policy accept;

    # Allow loopback
    iif "lo" accept

    # PRIORITY 1: Whitelist always wins
    ip saddr @whitelist_v4 accept
    ip6 saddr @whitelist_v6 accept

    # PRIORITY 2: Drop banned IPs
    ip saddr @user_blacklist_v4 drop
    ip6 saddr @user_blacklist_v6 drop
    ip saddr @system_blacklist_v4 drop
    ip6 saddr @system_blacklist_v6 drop
    ip saddr @temp_ban_v4 drop
    ip6 saddr @temp_ban_v6 drop

    # PRIORITY 3: Allow established/related connections
    ct state established,related accept

    # PRIORITY 4: Allow SSH
EOF
echo "    tcp dport $SSH_PORT accept"
cat <<'EOF'
    # PRIORITY 5: User-defined port rules (IPv4 - combined system + user)
EOF
generate_port_rules_combined "$IPV4_IN_SYSTEM" "$IPV4_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"
cat <<'EOF'
    # PRIORITY 6: User-defined port rules (IPv6 - combined system + user)
EOF
generate_port_rules_combined "$IPV6_IN_SYSTEM" "$IPV6_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"
cat <<'EOF'
    # PRIORITY 7: Connection tracking rules (IPv4)
EOF
[[ -f "$USER_CT_FILE_IPv4" ]] && cat "$USER_CT_FILE_IPv4" >> "$OUTPUT_FILE"
cat <<'EOF'
    # PRIORITY 8: Connection tracking rules (IPv6)
EOF
[[ -f "$USER_CT_FILE_IPv6" ]] && cat "$USER_CT_FILE_IPv6" >> "$OUTPUT_FILE"
cat <<'EOF'
  }

  # Output chain (for outgoing traffic filtering if needed)
  chain output {
    type filter hook output priority 0;
    policy accept;

    # User-defined output port rules (IPv4 - combined system + user)
EOF
generate_port_rules_combined "$IPV4_OUT_SYSTEM" "$IPV4_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"
cat <<'EOF'
    # User-defined output port rules (IPv6 - combined system + user)
EOF
generate_port_rules_combined "$IPV6_OUT_SYSTEM" "$IPV6_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"
cat <<'EOF'
  }
}
EOF
} > "$OUTPUT_FILE"

# --- Summary ---
echo ""
echo "=== Configuration Summary ==="
echo "Control Panel: $DETECTED_PANEL"
echo "Architecture: Single global table (inet nftban_global)"
echo "SSH Port: $SSH_PORT"
echo "Whitelisted IPs: ${#ipv4_whitelist[@]} IPv4, ${#ipv6_whitelist[@]} IPv6"
echo "User Blacklist: ${#ipv4_user_blacklist[@]} IPv4, ${#ipv6_user_blacklist[@]} IPv6"
echo "System Blacklist: ${#ipv4_system_blacklist[@]} IPv4, ${#ipv6_system_blacklist[@]} IPv6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"
echo ""

echo "=== Control Panel Port Configuration ==="
echo "System ports (.conf files) are auto-managed from:"
echo "  $CONTROL_PANEL_TEMPLATES/${DETECTED_PANEL}.conf"
echo "User custom ports (.conf.local files) merged with system ports"
echo "Edit templates with: nano $CONTROL_PANEL_TEMPLATES/${DETECTED_PANEL}.conf"
echo ""

echo "=== Fail2Ban Integration ==="
echo "Table: inet nftban_global (single table for everything)"
echo "Fail2ban sets:"
echo "  - temp_ban_v4 (IPv4 temporary bans with timeout)"
echo "  - temp_ban_v6 (IPv6 temporary bans with timeout)"
echo ""
echo "To configure Fail2ban:"
echo "  1. Run: $0 --generate-f2b-action"
echo "  2. Or manually configure your jails to use:"
echo "     banaction = nftban-global[set=temp_ban_v4]"
echo "     (for IPv6 use: set=temp_ban_v6)"
echo ""
FINAL_SNAPSHOT="$LOG_DIR/nftables_final_$(date +%Y%m%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_SNAPSHOT"
echo "Configuration snapshot: $FINAL_SNAPSHOT"

# --- Install / Apply helpers ---
install_final_config() {
  echo "--- Installing final nftables configuration ---"
  FINAL_CONFIG="/etc/nftables.conf"
  FINAL_CONFIG_BACKUP="/etc/nftables.conf.backup"
  if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo "ERROR: Output file not found: $OUTPUT_FILE"
    return 1
  fi
  # Backup current working config
  if [[ -f "$FINAL_CONFIG" ]]; then
    cp "$FINAL_CONFIG" "$FINAL_CONFIG_BACKUP"
    echo "Current config backed up to: $FINAL_CONFIG_BACKUP"
  fi
  # Syntax check before applying
  if ! nft -c -f "$OUTPUT_FILE"; then
    echo "[FAIL] Syntax error in generated config. Aborting."
    return 1
  fi
  echo "[OK] Syntax check passed."
  # Copy new config
  cp "$OUTPUT_FILE" "$FINAL_CONFIG"
  echo "Configuration copied to: $FINAL_CONFIG"
  # Apply
  echo "Applying new ruleset..."
  if nft -f "$FINAL_CONFIG"; then
    echo "[OK] Ruleset applied successfully!"
    # Seed temporary bans after successful apply
    seed_temp_bans_from_csv
    # Persist if nftables service is active
    if systemctl is-active --quiet nftables; then
      echo "nftables service is active. Changes will persist."
    else
      echo "[WARN] nftables service not active. Enable with: systemctl enable --now nftables"
    fi
  else
    echo "[FAIL] Failed to apply rules. Attempting rollback..."
    if [[ -f "$FINAL_CONFIG_BACKUP" ]]; then
      nft -f "$FINAL_CONFIG_BACKUP" && echo "[OK] Rollback successful" || echo "[FAIL] Rollback failed!"
      cp "$FINAL_CONFIG_BACKUP" "$FINAL_CONFIG"
    fi
    return 1
  fi
}

echo "=== Finalizing configuration ==="
if [[ ! -f "$OUTPUT_FILE" ]]; then
  log_msg "ERROR: Expected OUTPUT_FILE not found: $OUTPUT_FILE"
  exit 1
fi

# Syntax check first (always)
if nft -c -f "$OUTPUT_FILE"; then
  echo "[OK] Final ruleset syntax OK."
else
  echo "[FAIL] Final ruleset has syntax errors. See $LOG_FILE for details."
  exit 1
fi

# --- TEST MODE ---
if $TEST_MODE; then
  echo ""
  echo "=== TEST MODE ==="
  echo "Simulating apply with 'nft -c' only (no copy, no reload)."
  echo "Generated config: $OUTPUT_FILE"
  # Already ran nft -c above; run once more verbosely
  if nft -c -f "$OUTPUT_FILE"; then
    echo "[OK] nft -c simulation successful. No changes applied."
    exit 0
  else
    echo "[FAIL] nft -c simulation found errors. See $LOG_FILE."
    exit 1
  fi
fi

# Dry run mode (unchanged behavior)
if $DRY_RUN; then
  echo ""
  echo "=== DRY RUN MODE ==="
  echo "Configuration generated but NOT applied."
  echo "Generated config: $OUTPUT_FILE"
  echo "Preview (first 50 lines):"
  head -n 50 "$OUTPUT_FILE" || true
  echo "..."
  echo ""
  echo "To apply manually: nft -f $OUTPUT_FILE"
  exit 0
fi

# Install if requested or in silent mode
if $INSTALL_FINAL || $SILENT_AUTO; then
  install_final_config || exit 1
else
  echo ""
  echo "Configuration generated successfully but not applied."
  echo "Generated config: $OUTPUT_FILE"
  echo ""
  echo "To apply manually:"
  echo "  nft -f $OUTPUT_FILE"
  echo ""
  echo "Or run with --install-final:"
  echo "  $0 --install-final"
fi

echo "=== Initialization complete ==="