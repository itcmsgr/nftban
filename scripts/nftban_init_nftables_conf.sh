#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh
#
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis) + Enhanced Features
# Description:
# Enhanced nftables configuration with comprehensive IP whitelisting and advanced features
# Features:
#  - Server public IP detection and whitelisting
#  - Current user IP detection and whitelisting  
#  - All server interface IPs whitelisting
#  - Safe template initialization
#  - Protection against accidental lockout
#  - Cloudflare IP integration with TLS 1.2+
#  - Improved SSH port detection (multiple ports)
#  - Better error handling and validation
#  - Command-line argument parsing
#  - Enhanced logging and backup system
################################################################################

set -Eeuo pipefail

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"
BACKUP_DIR="/etc/nftban/backups"
LOG_DIR="/var/log/nftban"
OUTPUT_FILE="$BASE_DIR/nft_rules.conf.local"

# Cloudflare settings
CLOUDFLARE_ENABLE="${CLOUDFLARE_ENABLE:-no}"
CLOUDFLARE_DIR="$BASE_DIR/cloudflare"
CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"

# --- New flags ---
PURGE="no"
ASSUME_YES="no"
VALIDATE_ONLY="no"

# --- Logging ---
LOG_FILE="$LOG_DIR/install_nftables_process_$(date +%Y-%m-%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== nftban nftables Configuration Initialization ==="
echo "Log file: $LOG_FILE"

# Config files (user-editable .local files)
IPV4_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-input-allow.conf.local"
IPV4_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv4-ports-output-allow.conf.local"
IPV6_IN_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-input-allow.conf.local"
IPV6_OUT_PORTS_FILE="$BASE_DIR/nftban-configuration-ipv6-ports-output-allow.conf.local"
IPV4_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv4-blacklist_ips.conf.local"
IPV6_BLACKLIST_FILE="$BASE_DIR/nftban-configuration-ipv6-blacklist_ips.conf.local"
SYSTEM_WHITELIST_FILE="$BASE_DIR/nftban-configuration-system_whitelist_ips.conf.local"
USER_WHITELIST_FILE="$BASE_DIR/nftban-configuration-user-whitelist_ips.conf.local"
USER_CT_FILE_IPv4="$BASE_DIR/nftban-nfttables-ct-ipv4.conf.local"
USER_CT_FILE_IPv6="$BASE_DIR/nftban-nfttables-ct-ipv6.conf.local"
FAIL2BAN_WHITELIST="$BASE_DIR/nftban-fail2ban-ip-whitelist.conf.local"

# --- Enhanced Helper functions ---
log()  { printf '[*] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ip_exists_in_file() {
    local ip=$1
    local file=$2
    [[ -f "$file" ]] && grep -q -F "$ip" "$file"
}

sanitize_ports_list() {
  local file="$1"
  [[ -n "$file" && -r "$file" ]] || { echo ""; return 0; }
  awk '
    /^[[:space:]]*($|#)/{next}
    {
      gsub(/[[:space:]]+/,"");
      if ($0 ~ /^[0-9]+$/) {
        p=$0+0;
        if (p>=1 && p<=65535) print p;
      }
    }' "$file" | sort -n | uniq | paste -sd',' - || true
}

read_cidrs_for_family() {
  local file="$1" family="$2"
  [[ -n "$file" && -r "$file" ]] || { echo ""; return 0; }
  awk -v fam="$family" '
    /^[[:space:]]*($|#)/{next}
    {
      gsub(/[[:space:]]+/,"");
      line=$0
      if (fam=="ip") {
        if (line ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$/) print line
      } else if (fam=="ip6") {
        if (line ~ /^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))?$/) print line
      }
    }' "$file" | sort -u | paste -sd',' - || true
}

get_public_ip() {
    local ip_type=$1
    local ip=""
    
    local services_v4=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
    )
    
    local services_v6=(
        "https://ipv6.icanhazip.com" 
        "https://api64.ipify.org"
        "https://ifconfig.me"
    )
    
    local services=()
    [[ "$ip_type" == "ipv4" ]] && services=("${services_v4[@]}") || services=("${services_v6[@]}")
    
    for service in "${services[@]}"; do
        if cmd_exists curl; then
            ip=$(curl --tlsv1.2 -4 -s --connect-timeout 3 "$service" 2>/dev/null | head -1 | tr -d '\r\n')
        elif cmd_exists wget; then
            ip=$(wget --secure-protocol=TLSv1_2 --https-only -q -O - --timeout=3 "$service" 2>/dev/null | head -1 | tr -d '\r\n')
        fi
        
        # Validate IP format
        if [[ -n "$ip" ]]; then
            if [[ "$ip_type" == "ipv4" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                break
            elif [[ "$ip_type" == "ipv6" && "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
                break
            else
                ip=""
            fi
        fi
    done
    
    echo "$ip"
}

get_current_user_ip() {
    local ssh_client="${SSH_CLIENT%% *}"
    
    if [[ -n "$ssh_client" && "$ssh_client" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ssh_client"
        return 0
    fi
    
    local who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" && "$who_output" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$who_output"
        return 0
    fi
    
    local last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$last_ip"
        return 0
    fi
    
    return 1
}

detect_ssh_ports() {
    local ports
    ports=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null \
            | awk '{print $2}' | sort -n | uniq | paste -sd ',' -)
    [[ -z "$ports" ]] && ports="22"
    echo "$ports"
}

backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup_file="$BACKUP_DIR/$(basename "$file").backup.$(date +%Y%m%d%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$backup_file"
        echo "Backup created: $backup_file"
    fi
}

initialize_config_from_template() {
    local config_file=$1
    local template_file="$BASE_DIR_INIT/$(basename "$config_file" .local)"
    
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
    
    if cmd_exists wget; then
        wget --secure-protocol=TLSv1_2 --https-only -q -O "$tmpfile" "$url" || return 1
    elif cmd_exists curl; then
        curl --tlsv1.2 -fsS -o "$tmpfile" "$url" || return 1
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

emit_cf_nft_set_file() {
    local family="$1" raw="$2" nftfile="$3" setname="$4"
    local type_s="ipv4_addr"
    [[ "$family" == "ip6" ]] && type_s="ipv6_addr"

    local elems
    if [[ -r "$raw" ]]; then
        elems=$(awk '/^[^#[:space:]]/ {gsub(/[[:space:]]+/,""); print $0}' "$raw" \
                 | paste -sd',' -) || elems=""
    fi

    {
        echo "set $setname {"
        echo "    type $type_s; flags interval;"
        if [[ -n "$elems" ]]; then
            echo "    elements = { $elems }"
        else
            echo "    elements = { }"
        fi
        echo "}"
    } > "$nftfile"
}

generate_interface_chains() {
    local iface=$1
    local ipver=$2
    local whitelist=$3
    local blacklist=$4
    local in_ports=$5
    local out_ports=$6
    local ssh_ports=$7

    local datatype
    if [[ "$ipver" == "ip" ]]; then
        datatype="ipv4_addr"
    elif [[ "$ipver" == "ip6" ]]; then
        datatype="ipv6_addr"
    fi

    local whitelist_elements=""
    if [[ -n "$whitelist" ]]; then
        whitelist_elements="elements = { $whitelist }"
    fi
    
    local blacklist_elements=""
    if [[ -n "$blacklist" ]]; then
        blacklist_elements="elements = { $blacklist }"
    fi

    cat >> "$OUTPUT_FILE" <<EOF
table $ipver nftban_tbl_${iface} {
    set nftban_whitelist_${ipver} {
        type $datatype;
        flags interval;
        $whitelist_elements
    }
    set nftban_blacklist_${ipver} {
        type $datatype;
        flags interval;
        $blacklist_elements
    }

    chain nftban_drop_blacklist_${iface}_${ipver} {
        $ipver saddr @nftban_blacklist_${ipver} drop
    }

    chain nftban_input_${iface}_${ipver} {
        type filter hook input priority 0; policy drop;
        $ipver saddr @nftban_whitelist_${ipver} accept
        jump nftban_drop_blacklist_${iface}_${ipver}
        ct state established,related accept
        tcp dport { $ssh_ports } accept
EOF

    # Generate port rules
    if [[ -n "$in_ports" ]]; then
        IFS=',' read -ra ports <<< "$in_ports"
        for port in "${ports[@]}"; do
            echo "        tcp dport $port accept" >> "$OUTPUT_FILE"
            echo "        udp dport $port accept" >> "$OUTPUT_FILE"
        done
    fi

    if [[ "$ipver" == "ip" ]]; then
        echo "        include \"$USER_CT_FILE_IPv4\"" >> "$OUTPUT_FILE"
    elif [[ "$ipver" == "ip6" ]]; then
        echo "        include \"$USER_CT_FILE_IPv6\"" >> "$OUTPUT_FILE"
    fi

    # Cloudflare integration for HTTP/HTTPS
    if [[ "${CLOUDFLARE_ENABLE,,}" =~ ^(on|yes|true)$ ]]; then
        if [[ "$ipver" == "ip" ]]; then
            cat >> "$OUTPUT_FILE" <<EOF
        # Cloudflare IP restriction for web ports
        tcp dport {80,443} ip saddr @cloudflare_ipv4 accept
        udp dport 443 ip saddr @cloudflare_ipv4 accept  # QUIC
EOF
        else
            cat >> "$OUTPUT_FILE" <<EOF
        # Cloudflare IP restriction for web ports
        tcp dport {80,443} ip6 saddr @cloudflare_ipv6 accept
        udp dport 443 ip6 saddr @cloudflare_ipv6 accept  # QUIC
EOF
        fi
    fi

    echo "    }" >> "$OUTPUT_FILE"
    
    cat >> "$OUTPUT_FILE" <<EOF
    chain nftban_output_${iface}_${ipver} {
        type filter hook output priority 0; policy accept;
        ct state established,related accept
EOF

    # Generate output port rules
    if [[ -n "$out_ports" ]]; then
        IFS=',' read -ra ports <<< "$out_ports"
        for port in "${ports[@]}"; do
            echo "        tcp sport $port accept" >> "$OUTPUT_FILE"
            echo "        udp sport $port accept" >> "$OUTPUT_FILE"
        done
    fi
    
    echo "    }" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
}

# --- Argument parsing ---

# --- Confirmation helper ---
confirm() {
  local prompt="${1:-Are you sure?} [y/N] "
  if [[ "$ASSUME_YES" == "yes" ]]; then
    return 0
  fi
  read -r -p "$prompt" reply || reply=""
  case "$reply" in
    [Yy][Ee][Ss]|[Yy]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Purge state and reinitialize from templates ---
purge_state() {
  echo "--- Purge requested ---"
  echo "This will remove generated files and *.local configs under: $BASE_DIR"
  echo "It will NOT delete templates in: $BASE_DIR_INIT or backups in: $BACKUP_DIR"
  if confirm "Proceed with purge?"; then
    mkdir -p "$BACKUP_DIR"
    ts=$(date +%Y%m%d%H%M%S)
    tarball="$BACKUP_DIR/nftban-pre-purge-$ts.tgz"
    (
      cd / || exit 1
      tar -czf "$tarball" \
        "$BASE_DIR"/*.local 2>/dev/null || true
      tar -rzf "$tarball" "$OUTPUT_FILE" 2>/dev/null || true
      tar -rzf "$tarball" "$CLOUDFLARE_DIR" 2>/dev/null || true
      tar -rzf "$tarball" "$FAIL2BAN_WHITELIST" 2>/dev/null || true
    ) || true
    echo "Backup archive (if any files existed): $tarball"

    # Remove files safely
    rm -f "$BASE_DIR"/*.local 2>/dev/null || true
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
    rm -rf "$CLOUDFLARE_DIR"/* 2>/dev/null || true
    rm -f "$FAIL2BAN_WHITELIST" 2>/dev/null || true

    echo "Purge complete. Re-initializing from templates..."
  else
    die "Purge aborted by user."
  fi
}

# --- Validation: environment & configs ---
validate_configs() {
  local ok=0

  # Commands
  for bin in nft ip awk sed grep sort uniq paste tr cut head tail date tee; do
    if ! cmd_exists "$bin"; then
      warn "Missing required command: $bin"
      ok=1
    fi
  done

  # Directories
  for dir in "$BASE_DIR" "$BASE_DIR_INIT" "$BACKUP_DIR" "$LOG_DIR"; do
    if [[ ! -d "$dir" ]]; then
      warn "Directory missing: $dir (will be created)"
    fi
  done

  # Templates
  local must_templates=(
    "$BASE_DIR_INIT/$(basename "$IPV4_IN_PORTS_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$IPV4_OUT_PORTS_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$IPV6_IN_PORTS_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$IPV6_OUT_PORTS_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$SYSTEM_WHITELIST_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$USER_WHITELIST_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$IPV4_BLACKLIST_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$IPV6_BLACKLIST_FILE" .local)"
    "$BASE_DIR_INIT/$(basename "$USER_CT_FILE_IPv4" .local)"
    "$BASE_DIR_INIT/$(basename "$USER_CT_FILE_IPv6" .local)"
  )
  for t in "${must_templates[@]}"; do
    if [[ ! -f "$t" ]]; then
      warn "Template missing: $t"
      ok=1
    fi
  done

  # Config sanity
  local bad=0
  # Warn on default routes in whitelist
  if grep -qE '(^|[^0-9])0\.0\.0\.0/0([^0-9]|$)' "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null; then
    warn "Whitelist contains 0.0.0.0/0 which defeats firewall."
    bad=1
  fi
  if grep -qE '(^|[^:]):*:*/0([^:]|$)' "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null; then
    warn "Whitelist contains ::/0 which defeats firewall."
    bad=1
  fi

  # Ports files: flag invalid lines
  for pf in "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE" "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"; do
    if [[ -f "$pf" ]]; then
      if grep -vE '^[[:space:]]*([#]|$|[0-9]+[[:space:]]*$)' "$pf" >/dev/null; then
        warn "Port file has invalid lines (will be ignored): $pf"
      fi
    fi
  done

  # Ensure SSH port(s) are allowed somehow
  local ssh_ports
  ssh_ports=$(detect_ssh_ports)
  local in4_ports in6_ports
  in4_ports=$(sanitize_ports_list "$IPV4_IN_PORTS_FILE")
  in6_ports=$(sanitize_ports_list "$IPV6_IN_PORTS_FILE")
  for sp in ${ssh_ports//,/ }; do
    if [[ "$in4_ports" != *"$sp"* && "$in6_ports" != *"$sp"* ]]; then
      warn "SSH port $sp is not listed in input-allow ports; ensure your IP is whitelisted to avoid lockout."
      bad=1
    fi
  done

  # Cloudflare sets recency
  if [[ "${CLOUDFLARE_ENABLE,,}" =~ ^(on|yes|true)$ ]]; then
    if [[ -d "$CLOUDFLARE_DIR" ]]; then
      recent=$(find "$CLOUDFLARE_DIR" -type f -mtime -7 | wc -l | tr -d ' ')
      if [[ "$recent" -eq 0 ]]; then
        warn "Cloudflare IP files look older than 7 days; consider refreshing."
      fi
    fi
  fi

  if [[ $ok -ne 0 || $bad -ne 0 ]]; then
    warn "Validation found issues (see messages above)."
  else
    log "Validation passed."
  fi
  return 0
}
print_usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  -o, --output FILE                Output nft config file (default: $OUTPUT_FILE)
  -I, --interfaces IF1,IF2         Comma-separated interfaces; default: all UP (except lo)
      --cloudflare on|off          Download CF IPs and create nft sets (default: $CLOUDFLARE_ENABLE)
      --cloudflare-dir DIR         Directory for CF files (default: $CLOUDFLARE_DIR)
  -p, --purge                      Purge *.local configs, CF sets, and generated files, then re-init from templates (asks for confirmation)
  -y, --yes                        Assume 'yes' for any confirmation prompts (non-interactive)
      --validate-only              Only validate configs and environment; do not generate rules
  -h, --help                       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        -I|--interfaces) INTERFACES="$2"; shift 2 ;;
        --cloudflare) CLOUDFLARE_ENABLE="$2"; shift 2 ;;
        --cloudflare-dir) CLOUDFLARE_DIR="$2"; shift 2 ;;
        -p|--purge) PURGE="yes"; shift 1 ;;
        -y|--yes) ASSUME_YES="yes"; shift 1 ;;
        --validate-only) VALIDATE_ONLY="yes"; shift 1 ;;
        -h|--help) print_usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)";;
    esac
done

# --- Main execution ---
require_root

# Create necessary directories
mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BASE_DIR_INIT" "$CLOUDFLARE_DIR"

# Optional purge
if [[ "$PURGE" == "yes" ]]; then
    purge_state
fi

# Pre-flight validation (runs always; suggests improvements)
validate_configs

# Validate-only mode: stop after validation
if [[ "$VALIDATE_ONLY" == "yes" ]]; then
    echo "Validation-only mode; exiting without generating rules."
    exit 0
fi

# --- Initialize missing config files from templates ---
echo "--- Initializing configuration files ---"
CONFIG_FILES=(
    "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE"
    "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"
    "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
    "$USER_CT_FILE_IPv4" "$USER_CT_FILE_IPv6"
    "$USER_WHITELIST_FILE"
)

for file in "${CONFIG_FILES[@]}"; do
    initialize_config_from_template "$file"
done

# --- Start ruleset generation ---
echo "--- Flushing existing nftables ruleset and starting generation ---"
echo "flush ruleset" > "$OUTPUT_FILE"

# --- Enhanced SSH port detection ---
SSH_PORTS=$(detect_ssh_ports)
echo "Detected SSH Ports: $SSH_PORTS"

# --- Get and whitelist ALL server IP addresses ---
echo "--- Detecting and whitelisting server IP addresses ---"

SERVER_IPV4=$(ip -4 addr show 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | tr '\n' ' ')
SERVER_IPV6=$(ip -6 addr show 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/[0-9]+' | tr '\n' ' ')

SERVER_PUBLIC_IPV4=$(get_public_ip "ipv4")
SERVER_PUBLIC_IPV6=$(get_public_ip "ipv6")
CURRENT_USER_IP=$(get_current_user_ip)

# Create/update system whitelist file
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

echo "Server IPv4 addresses whitelisted: $SERVER_IPV4"
echo "Server IPv6 addresses whitelisted: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"

# --- Cloudflare IP integration ---
if [[ "${CLOUDFLARE_ENABLE,,}" =~ ^(on|yes|true)$ ]]; then
    echo "--- Fetching Cloudflare IP ranges ---"
    CF_V4_RAW="$CLOUDFLARE_DIR/cloudflare-ips-v4.txt"
    CF_V6_RAW="$CLOUDFLARE_DIR/cloudflare-ips-v6.txt"
    CF_V4_NFT="$CLOUDFLARE_DIR/cloudflare-ipv4.nft"
    CF_V6_NFT="$CLOUDFLARE_DIR/cloudflare-ipv6.nft"

    fetch_cloudflare_ips "$CLOUDFLARE_IPV4_URL" "#ipv4 from cloudflare"
    fetch_cloudflare_ips "$CLOUDFLARE_IPV6_URL" "#ipv6 from cloudflare"
    
    # Create nft set files
    emit_cf_nft_set_file "ip" "$CF_V4_RAW" "$CF_V4_NFT" "cloudflare_ipv4"
    emit_cf_nft_set_file "ip6" "$CF_V6_RAW" "$CF_V6_NFT" "cloudflare_ipv6"
    
    # Include Cloudflare sets in main config
    cat >> "$OUTPUT_FILE" <<EOF
# Cloudflare IP sets
include "$CF_V4_NFT"
include "$CF_V6_NFT"

EOF
fi

# --- Collect whitelist & blacklist IPs ---
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | grep -v '^#' | sort -u | grep -v '^$')

# --- Ensure whitelist IPs are NOT in blacklist ---
if [[ -f "$IPV4_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}") "$IPV4_BLACKLIST_FILE" > "${IPV4_BLACKLIST_FILE}.tmp"
    mv "${IPV4_BLACKLIST_FILE}.tmp" "$IPV4_BLACKLIST_FILE"
fi

if [[ -f "$IPV6_BLACKLIST_FILE" ]]; then
    grep -vFf <(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}") "$IPV6_BLACKLIST_FILE" > "${IPV6_BLACKLIST_FILE}.tmp"
    mv "${IPV6_BLACKLIST_FILE}.tmp" "$IPV6_BLACKLIST_FILE"
fi

# --- Save Fail2Ban-compatible whitelist ---
echo "$ALL_WHITELIST_IPS" | sort -u > "$FAIL2BAN_WHITELIST"
echo "Fail2Ban whitelist saved to: $FAIL2BAN_WHITELIST"

# --- Process IP lists with enhanced functions ---
IPV4_WHITELIST_ELEMS=$(read_cidrs_for_family "$SYSTEM_WHITELIST_FILE" ip)
IPV4_WHITELIST_ELEMS+=",$(read_cidrs_for_family "$USER_WHITELIST_FILE" ip)"
IPV4_WHITELIST_ELEMS=$(echo "$IPV4_WHITELIST_ELEMS" | sed 's/^,//; s/,,*/,/g')

IPV6_WHITELIST_ELEMS=$(read_cidrs_for_family "$SYSTEM_WHITELIST_FILE" ip6)
IPV6_WHITELIST_ELEMS+=",$(read_cidrs_for_family "$USER_WHITELIST_FILE" ip6)"
IPV6_WHITELIST_ELEMS=$(echo "$IPV6_WHITELIST_ELEMS" | sed 's/^,//; s/,,*/,/g')

IPV4_BLACKLIST_ELEMS=$(read_cidrs_for_family "$IPV4_BLACKLIST_FILE" ip)
IPV6_BLACKLIST_ELEMS=$(read_cidrs_for_family "$IPV6_BLACKLIST_FILE" ip6)

IPV4_IN_PORTS=$(sanitize_ports_list "$IPV4_IN_PORTS_FILE")
IPV4_OUT_PORTS=$(sanitize_ports_list "$IPV4_OUT_PORTS_FILE")
IPV6_IN_PORTS=$(sanitize_ports_list "$IPV6_IN_PORTS_FILE")
IPV6_OUT_PORTS=$(sanitize_ports_list "$IPV6_OUT_PORTS_FILE")

# --- Global loopback rules ---
cat >> "$OUTPUT_FILE" <<EOF
table ip nftban_global {
    chain input {
        type filter hook input priority -1; policy accept;
        iif "lo" accept
    }
}

table ip6 nftban_global {
    chain input {
        type filter hook input priority -1; policy accept;
        iif "lo" accept
    }
}

EOF

# --- Determine interfaces ---
if [[ -z "${INTERFACES:-}" ]]; then
    INTERFACES=$(ip -o link show up 2>/dev/null \
                  | awk -F': ' '{print $2}' \
                  | awk '$0!="lo"{print $0}' \
                  | paste -sd' ' -) || true
    [[ -z "$INTERFACES" ]] && die "No active interfaces detected."
else
    INTERFACES="${INTERFACES//,/ }"
fi

# Validate interfaces
VALID_INTERFACES=""
for IFACE in $INTERFACES; do
    if ip link show "$IFACE" >/dev/null 2>&1; then
        VALID_INTERFACES+="$IFACE "
    else
        warn "Interface $IFACE does not exist; skipping."
    fi
done
INTERFACES="${VALID_INTERFACES%% }"
[[ -z "$INTERFACES" ]] && die "No valid interfaces to configure."

echo "Processing interfaces: $INTERFACES"

# --- Generate chains per interface ---
for IFACE in $INTERFACES; do
    echo "Generating rules for interface: $IFACE"
    generate_interface_chains "$IFACE" "ip" "$IPV4_WHITELIST_ELEMS" "$IPV4_BLACKLIST_ELEMS" "$IPV4_IN_PORTS" "$IPV4_OUT_PORTS" "$SSH_PORTS"
    generate_interface_chains "$IFACE" "ip6" "$IPV6_WHITELIST_ELEMS" "$IPV6_BLACKLIST_ELEMS" "$IPV6_IN_PORTS" "$IPV6_OUT_PORTS" "$SSH_PORTS"
done

# --- Apply ruleset ---
echo "--- Applying nftables ruleset ---"
if nft -f "$OUTPUT_FILE"; then
    echo "nftables ruleset loaded successfully."
else
    echo "Failed to load nftables ruleset"
    echo "Please check the configuration file: $OUTPUT_FILE"
    exit 1
fi

# --- Final summary ---
echo "=== Configuration Summary ==="
echo "SSH Ports: $SSH_PORTS"
echo "Server IPv4 addresses: $SERVER_IPV4"
echo "Server IPv6 addresses: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"
echo "Interfaces configured: $INTERFACES"
[[ "${CLOUDFLARE_ENABLE,,}" =~ ^(on|yes|true)$ ]] && echo "Cloudflare integration: Enabled"

# --- Save final snapshot ---
FINAL_CONFIG_SNAPSHOT="$LOG_DIR/nftables_final_config_$(date +%Y-%m-%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_CONFIG_SNAPSHOT"
echo "Final configuration saved to: $FINAL_CONFIG_SNAPSHOT"
echo "=== nftables configuration completed successfully ==="
