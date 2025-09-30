#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh (Rewritten two separate streams this for simple user and advance for future use )
#
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis) 
# Description:
# Single-table nftables configuration with simplified architecture
# - One global table: inet nftban_global
# - Separate sets for user/system blacklists and temp bans
# - Compatible with unified nftban management script
# - Whitelist always takes priority
#Architect nftables table: inet nftban_global
#├── Sets:
#│   ├── whitelist_v4 / whitelist_v6
#│   ├── user_blacklist_v4 / user_blacklist_v6  (from USER_BLACKLIST_FILE)
#│   ├── system_blacklist_v4 / system_blacklist_v6  (from IPV4/IPV6_BLACKLIST_FILE)
#│   └── temp_ban_v4 / temp_ban_v6
#└── Chains:
#    ├── input (priority -150, runs before other rules)
#    │   ├── Check whitelist → ACCEPT
#    │   ├── Check blacklists → DROP
#    │   └── Check temp_ban → DROP
#    └── forward (same logic for forwarded traffic)
################################################################################

set -euo pipefail

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"
BACKUP_DIR="/etc/nftban/backups"

# --- Logging ---
LOG_DIR="/etc/nftban/logs"
LOG_FILE="${LOG_DIR}/validation_$(date +%F).log"

# Ensure required directories exist
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# Migrate legacy backup directories to $BACKUP_DIR
migrate_legacy_backups() {
  for LEGACY in "/var/lib/nftban" "/var/backups"; do
    if [ -d "$LEGACY" ]; then
      # Move files without overwriting existing backups
      find "$LEGACY" -maxdepth 1 -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
        bn="$(basename "$f")"
        dest="$BACKUP_DIR/$bn"
        if [ -e "$dest" ]; then
          ts="$(date +%F_%H%M%S)"
          dest="$BACKUP_DIR/${bn}.${ts}.migrated"
        fi
        mv "$f" "$dest" 2>/dev/null || cp -a "$f" "$dest"
      done
    fi
  done
}

migrate_legacy_backups

log_msg() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== NFTBAN nftables Configuration Initialization (v2.0) ==="
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
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
# --- Validation mode switch ---
if [[ "$1" == "--validate-only" ]]; then
  echo "--- Validating all rule sources ---"
  VALIDATION_LOG="${VALIDATION_LOG:-/var/log/nftban/validate_all_$(date +%Y-%m-%d-%H%M%S).log}"
  mkdir -p "$(dirname "$VALIDATION_LOG")"

  validate_nft_fragment() {
    local f="$1"
    if [[ -f "$f" ]]; then
      if nft -c -f "$f" 2>>"$VALIDATION_LOG"; then
        echo "✅ Valid nft fragment: $f"
      else
        echo "❌ Invalid nft fragment: $f"
        echo "  ↳ See: $VALIDATION_LOG"
      fi
    else
      echo "ℹ️ Missing file (skip): $f"
    fi
  }

  validate_ip_port_list() {
    local f="$1"
    local kind="$2" # ipv_mixed | ports
    [[ -f "$f" ]] || { echo "ℹ️ Missing file (skip): $f"; return; }
    local total=0 ok=0 bad=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line//[$'\t\r ']/}"
      [[ -z "$line" ]] && continue
      ((total++))
      case "$kind" in        ports)
          if [[ "$line" =~ ^[0-9]+$ ]]; then
            local a="$line"
            if (( a>=1 && a<=65535 )); then
              ((ok++))
            else
              echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          elif [[ "$line" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
            if (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )); then
              ((ok++))
            else
              echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          else
            echo "[INVALID port] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
          fi
          ;;        ipv_mixed)
          if [[ "$line" == *:* ]]; then
            # IPv6
            if [[ "$line" =~ /([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ ]] || [[ "$line" == *"-"* ]] || [[ "$line" == *:* ]]; then
              ((ok++))
            else
              echo "[INVALID ipv6] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          else
            # IPv4
            if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
              # range bounds loosely checked here
              ((ok++))
            else
              echo "[INVALID ipv4] $line ($f)" >> "$VALIDATION_LOG"; ((bad++))
            fi
          fi
          ;;
      esac
    done < "$f"
    echo "• $f  -> $ok valid / $bad invalid / $total total"
    [[ $bad -gt 0 ]] && echo "  ↳ See: $VALIDATION_LOG"
  }

  # Validate CT nft fragments
  validate_nft_fragment "$USER_CT_FILE_IPv4"
  validate_nft_fragment "$USER_CT_FILE_IPv6"

  # Validate port lists
  validate_ip_port_list "$IPV4_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV4_OUT_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_IN_PORTS_FILE" ports
  validate_ip_port_list "$IPV6_OUT_PORTS_FILE" ports

  # Validate IP lists (mixed v4/v6 allowed)
  for f in "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" "$USER_BLACKLIST_FILE" "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE" "$FAIL2BAN_WHITELIST"; do
    validate_ip_port_list "$f" ipv_mixed
  done

  echo "Validation complete. Log saved to: $VALIDATION_LOG"
  exit 0
fi


# --- Helper functions ---
append_if_set() {
  local __arr_name="$1"
  local __val=\"${2//[$'\t\r\n ']/}\"

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

  # Validation helpers (lightweight, no external deps)
  _is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
      (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
  }
  _is_ipv4_cidr() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    _is_ipv4 "${s%/*}"
  }
  _is_ipv4_interval() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    _is_ipv4 "${s%-*}" && _is_ipv4 "${s#*-}"
  }
  _is_ipv6() {
    # very permissive ipv6 matcher (covers :: and hex groups)
    local ip="$1"
    [[ "$ip" =~ ^(([0-9A-Fa-f]{1,4}:){1,7}:|:?:([0-9A-Fa-f]{1,4}:){1,7}[0-9A-Fa-f]{0,4}|::1|::)$ ]] && return 0
    # Fallback simple check (colon present)
    [[ "$ip" == *:* ]]
  }
  _is_ipv6_cidr() {
    local s="$1"
    [[ "$s" =~ /([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$ ]] || return 1
    _is_ipv6 "${s%/*}"
  }
  _is_ipv6_interval() {
    local s="$1"
    [[ "$s" == *"-"* ]] || return 1
    _is_ipv6 "${s%-*}" && _is_ipv6 "${s#*-}"
  }
  _is_port_token() {
    local t="$1"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      (( t>=1 && t<=65535 )) && return 0 || return 1
    elif [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) && return 0 || return 1
    else
      return 1
    fi
  }

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
    echo "[IGNORED] Invalid entry for $__arr_name: $__val" >> "$VALIDATION_LOG"
  fi
}

dedup() {
  awk -v RS=' ' '!a[$0]++' <<<"${*}"
}

print_elements_from_array() {
  local -n __arr_ref="$1"
  if [ "${#__arr_ref[@]}" -gt 0 ]; then
    local joined
    joined=$(IFS=' '; dedup "${__arr_ref[@]}")
    set -f
    local -a __tokens=()
    read -r -a __tokens <<< "$joined"
    printf '        elements = { %s }\n' "$(IFS=,; echo "${__tokens[*]}")"
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

initialize_config_from_template() {
    local config_file=$1
    local template_file
    template_file="$BASE_DIR_INIT/$(basename "$config_file" .local)"
    
    if [[ ! -f "$config_file" ]]; then
        if [[ -f "$template_file" ]]; then
            backup_config "$config_file" 2>/dev/null
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
        wget -q -O "$tmpfile" "$url" || return 1
    elif command -v curl &>/dev/null; then
        curl -s -o "$tmpfile" "$url" || return 1
    else
        echo "Error: Neither wget nor curl available" >&2
        return 1
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
    local _direction=$2  # "input" or "output"
    [[ -f "$file" ]] || return
    
    while read -r line; do
        line=$(echo "$line" | sed 's/^ *//;s/ *$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        if [[ "$line" =~ ^([0-9]+(-[0-9]+)?)([TUB])$ ]]; then
            port_range=${BASH_REMATCH[1]}
            proto=${BASH_REMATCH[3]}
            
            if [[ "$port_range" == *-* ]]; then
                start=$(echo "$port_range" | cut -d'-' -f1)
                end=$(echo "$port_range" | cut -d'-' -f2)
                for ((port=start; port<=end; port++)); do
                    case "$proto" in
                        T) echo "        tcp dport $port accept" ;;
                        U) echo "        udp dport $port accept" ;;
                        B)
                            echo "        tcp dport $port accept"
                            echo "        udp dport $port accept"
                            ;;
                    esac
                done
            else
                port=$port_range
                case "$proto" in
                    T) echo "        tcp dport $port accept" ;;
                    U) echo "        udp dport $port accept" ;;
                    B)
                        echo "        tcp dport $port accept"
                        echo "        udp dport $port accept"
                        ;;
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
  --cloudflare [yes|no|auto]   Include Cloudflare IP ranges in whitelist.
                               Default: "auto" (ask if interactive, else no).
  --yes-cloudflare             Shortcut for --cloudflare yes
  --no-cloudflare              Shortcut for --cloudflare no
  -y                           Assume "yes" for prompts (non-interactive friendly)
  
  --install-final               Run install_final_config after generation
  --silent-auto                Run in silent mode with auto-confirmation and no prompts
  -h, --help                   Show this help
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
      N|n|no|NO)   return 1;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Parse CLI args
INSTALL_FINAL=false
SILENT_AUTO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-final) INSTALL_FINAL=true ;;
    --silent-auto) ASSUME_Y="true"; SILENT_AUTO=true ;;
    *) break ;;
  esac
  shift
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloudflare)
      shift
      case "${1:-}" in
        yes|no|auto) USE_CLOUDFLARE="$1";;
        *) echo "Invalid value for --cloudflare: ${1:-<missing>}"; usage; exit 1;;
      esac
      ;;
    --yes-cloudflare) USE_CLOUDFLARE="yes";;
    --no-cloudflare)  USE_CLOUDFLARE="no";;
    -y) ASSUME_Y="true";;
    -h|--help) usage; exit 0;;
    *) break;;
  esac
  shift
done

# Decide final Cloudflare setting
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
mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BASE_DIR_INIT"

# Initialize config files
echo "--- Initializing configuration files ---"
CONFIG_FILES=(
    "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE"
    "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"
    "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
    "$USER_CT_FILE_IPv4" "$USER_CT_FILE_IPv6"
    "$USER_WHITELIST_FILE"
    "$USER_BLACKLIST_FILE"
)

for file in "${CONFIG_FILES[@]}"; do
    initialize_config_from_template "$file"
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

# Create system whitelist
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

echo "Server IPv4 addresses: $SERVER_IPV4"
echo "Server IPv6 addresses: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

# Fetch Cloudflare IPs if requested
if [[ "$USE_CLOUDFLARE" == "yes" ]]; then
    echo "Fetching Cloudflare IP ranges..."
    fetch_cloudflare_ips "$CLOUDFLARE_IPV4_URL" "#ipv4 from cloudflare"
    fetch_cloudflare_ips "$CLOUDFLARE_IPV6_URL" "#ipv6 from cloudflare"
else
    echo "Skipping Cloudflare IP ranges"
fi

# Collect all whitelist IPs
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | grep -v '^#' | sort -u | grep -v '^$')

# Remove whitelisted IPs from blacklists
if [[ -f "$IPV4_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}") "$IPV4_BLACKLIST_FILE" > "${IPV4_BLACKLIST_FILE}.tmp" || true
    mv "${IPV4_BLACKLIST_FILE}.tmp" "$IPV4_BLACKLIST_FILE"
fi

if [[ -f "$IPV6_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}") "$IPV6_BLACKLIST_FILE" > "${IPV6_BLACKLIST_FILE}.tmp" || true
    mv "${IPV6_BLACKLIST_FILE}.tmp" "$IPV6_BLACKLIST_FILE"
fi

# Save Fail2Ban whitelist
echo "$ALL_WHITELIST_IPS" | sort -u > "$FAIL2BAN_WHITELIST"
echo "Fail2Ban whitelist saved to: $FAIL2BAN_WHITELIST"

# Build arrays
ipv4_whitelist=()
ipv6_whitelist=()
ipv4_system_blacklist=()
ipv6_system_blacklist=()
ipv4_user_blacklist=()
ipv6_user_blacklist=()

# Parse whitelist
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    if [[ "$ip" == *:* ]]; then
        append_if_set ipv6_whitelist "$ip"
    else
        append_if_set ipv4_whitelist "$ip"
    fi
done < <(echo "$ALL_WHITELIST_IPS")

# Parse system blacklists
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv4_system_blacklist "$ip"
done < "$IPV4_BLACKLIST_FILE"

while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    append_if_set ipv6_system_blacklist "$ip"
done < "$IPV6_BLACKLIST_FILE"

# Parse user blacklist
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    ip=$(echo "$ip" | awk '{print $1}')
    if [[ "$ip" == *:* ]]; then
        append_if_set ipv6_user_blacklist "$ip"
    else
        append_if_set ipv4_user_blacklist "$ip"
    fi
done < "$USER_BLACKLIST_FILE"

# Generate single global table
{
cat <<'EOF'
# ============================================================================
# NFTBAN Global Firewall Table
# Single table architecture for simplified management
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
    
    # Temporary bans (with timeout)
    set temp_ban_v4 {
        type ipv4_addr;
        flags timeout;
        comment "Temporary bans set by nftban script";
    }
    
    set temp_ban_v6 {
        type ipv6_addr;
        flags timeout;
        comment "Temporary bans set by nftban script";
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

echo "        tcp dport $SSH_PORT accept" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 5: User-defined port rules (IPv4)
EOF

generate_port_rules "$IPV4_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 6: User-defined port rules (IPv6)
EOF

generate_port_rules "$IPV6_IN_PORTS_FILE" "input" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # PRIORITY 7: Connection tracking rules (IPv4)
EOF

if [[ -f "$USER_CT_FILE_IPv4" ]]; then
    cat "$USER_CT_FILE_IPv4" >> "$OUTPUT_FILE"
fi

cat <<'EOF'
        
        # PRIORITY 8: Connection tracking rules (IPv6)
EOF

if [[ -f "$USER_CT_FILE_IPv6" ]]; then
    cat "$USER_CT_FILE_IPv6" >> "$OUTPUT_FILE"
fi

cat <<'EOF'
    }
    
    # Output chain (for outgoing traffic filtering if needed)
    chain output {
        type filter hook output priority 0;
        policy accept;
        
        # User-defined output port rules (IPv4)
EOF

generate_port_rules "$IPV4_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"

cat <<'EOF'
        
        # User-defined output port rules (IPv6)
EOF

generate_port_rules "$IPV6_OUT_PORTS_FILE" "output" >> "$OUTPUT_FILE"

cat <<'EOF'
    }
}

# ============================================================================
# Fail2Ban Integration Tables
# Each jail gets its own table for isolation and easier management
# ============================================================================
# 
# NOTE: These tables are created and managed by Fail2Ban actions.
# They follow the naming convention: inet nftban_f2b_<JAIL_NAME>
#
# Example structure for each jail:
#
# table inet nftban_f2b_sshd {
#     set banned_v4 { type ipv4_addr; flags timeout; }
#     set banned_v6 { type ipv6_addr; flags timeout; }
#     
#     chain input {
#         type filter hook input priority -100;
#         policy accept;
#         ip saddr @banned_v4 drop
#         ip6 saddr @banned_v6 drop
#     }
# }
#
# The Fail2Ban action adds IPs with:
#   nft add element inet nftban_f2b_sshd banned_v4 { <IP> timeout <TIME> }
#
# This keeps Fail2Ban bans separate from manual bans for clearer management.
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
#actionban = nft add element inet nftban_f2b_sshd banned_v4 { <ip> timeout <bantime> }
#
#actionunban = nft delete element inet nftban_f2b_sshd banned_v4 { <ip> }

#[Init]
#bantime = 3600

# ============================================================================
EOF
} >> "$OUTPUT_FILE"

# Configuration will be validated and applied by install_final_config function

# Summary
echo ""
echo "=== Configuration Summary ==="
echo "Architecture: Single global table (inet nftban_global)"
echo "SSH Port: $SSH_PORT"
echo "Whitelisted IPs: ${#ipv4_whitelist[@]} IPv4, ${#ipv6_whitelist[@]} IPv6"
echo "User Blacklist: ${#ipv4_user_blacklist[@]} IPv4, ${#ipv6_user_blacklist[@]} IPv6"
echo "System Blacklist: ${#ipv4_system_blacklist[@]} IPv4, ${#ipv6_system_blacklist[@]} IPv6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

echo ""
echo "=== Fail2Ban Table Convention ==="
echo "Fail2Ban jails should use tables named: inet nftban_f2b_<JAIL_NAME>"
echo "Examples:"
echo "  - inet nftban_f2b_sshd"
echo "  - inet nftban_f2b_nginx"
echo "  - inet nftban_f2b_wordpress"
echo ""
echo "Each jail table should have:"
echo "  - Sets: banned_v4, banned_v6 (with timeout flags)"
echo "  - Chain: input hook at priority -100"
echo ""

FINAL_SNAPSHOT="$LOG_DIR/nftables_final_$(date +%Y%m%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_SNAPSHOT"
echo "Configuration snapshot: $FINAL_SNAPSHOT"

# --- Function to install and activate the configuration ---
install_final_config() {
  echo "--- Installing final nftables configuration ---"
  FINAL_CONFIG="/etc/nftables.conf"

  if [[ -f "$OUTPUT_FILE" ]]; then
    cp "$OUTPUT_FILE" "$FINAL_CONFIG"
    echo "Configuration copied to: $FINAL_CONFIG"

    if nft -c -f "$FINAL_CONFIG"; then
      echo "✅ Syntax check passed."
    else
      echo "❌ Syntax error in final config. Aborting."
      return 1
    fi

    if systemctl is-active --quiet nftables; then
      echo "Reloading nftables service..."
      systemctl reload nftables && echo "✅ Reload successful." || echo "❌ Reload failed."
    else
      echo "nftables service not active. You may need to start it manually."
    fi
  else
    echo "ERROR: Output file not found: $OUTPUT_FILE"
    return 1
  fi
}

# --- Finalize: validate and install the generated config ---
echo "=== Finalizing configuration ==="

if [ -f "$OUTPUT_FILE" ]; then
  # Validate syntax first
  if nft -c -f "$OUTPUT_FILE"; then
    echo "✅ Final ruleset syntax OK."
  else
    echo "❌ Final ruleset has syntax errors. See $LOG_FILE for details."
    exit 1
  fi
  
  # Install if requested or in silent mode
  if [[ "$INSTALL_FINAL" == "true" ]] || [[ "$SILENT_AUTO" == "true" ]]; then
    install_final_config || exit 1
  else
    echo ""
    echo "Configuration generated successfully but not applied."
    echo "To apply: nft -f $OUTPUT_FILE"
    echo "Or run: $0 --install-final"
  fi
else
  log_msg "ERROR: Expected OUTPUT_FILE not found: $OUTPUT_FILE"
  exit 1
fi

echo "=== Initialization complete ==="
