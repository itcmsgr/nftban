#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh
#
# Version: 1.7.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# Enhanced nftables configuration with comprehensive IP whitelisting
# Features:
#  - Server public IP detection and whitelisting
#  - Current user IP detection and whitelisting  
#  - All server interface IPs whitelisting
#  - Safe template initialization
#  - Protection against accidental lockout
################################################################################

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"
BACKUP_DIR="/etc/nftban/backups"

# --- Logging ---
LOG_DIR="/var/log/nftban"
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
OUTPUT_FILE="$BASE_DIR/nft_rules.conf.local"
FAIL2BAN_WHITELIST="$BASE_DIR/nftban-fail2ban-ip-whitelist.conf.local"

# --- Helper functions ---
ip_exists_in_file() {
    local ip=$1
    local file=$2
    [[ -f "$file" ]] && grep -q -F "$ip" "$file"
}

get_public_ip() {
    # Try to detect public IP using multiple services
    local ip_type=$1  # "ipv4" or "ipv6"
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
    # Get the IP address of the current SSH connection
    local ssh_client="${SSH_CLIENT%% *}"  # Get first part of SSH_CLIENT (client IP)
    
    if [[ -n "$ssh_client" ]]; then
        echo "$ssh_client"
        return 0
    fi
    
    # Fallback: try to get IP from who command
    local who_output=$(who -u | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" ]]; then
        echo "$who_output"
        return 0
    fi
    
    # Final fallback: try to get from last command
    local last_ip=$(last -i | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
        echo "$last_ip"
        return 0
    fi
    
    return 1
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

generate_port_rules() {
    local iface=$1
    local file=$2
    local direction=$3
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
                        T) echo "        $direction "$iface" tcp dport $port accept" ;;
                        U) echo "        $direction "$iface" udp dport $port accept" ;;
                        B)
                            echo "        $direction "$iface" tcp dport $port accept"
                            echo "        $direction "$iface" udp dport $port accept"
                            ;;
                    esac
                done
            else
                port=$port_range
                case "$proto" in
                    T) echo "        $direction "$iface" tcp dport $port accept" ;;
                    U) echo "        $direction "$iface" udp dport $port accept" ;;
                    B)
                        echo "        $direction "$iface" tcp dport $port accept"
                        echo "        $direction "$iface" udp dport $port accept"
                        ;;
                esac
            fi
        else
            echo "Warning: Invalid line format '$line' in $file" >&2
        fi
    done < "$file"
}

generate_interface_chains() {
    local iface=$1
    local ipver=$2
    local whitelist=$3
    local blacklist=$4
    local in_ports=$5
    local out_ports=$6
    local ssh_port=$7

    # Determine the correct datatype
    local datatype
    if [[ "$ipver" == "ip" ]]; then
        datatype="ipv4_addr"
    elif [[ "$ipver" == "ip6" ]]; then
        datatype="ipv6_addr"
    fi

    # Handle empty sets
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
        $whitelist_elements
    }
    set nftban_blacklist_${ipver} {
        type $datatype;
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
        tcp dport $ssh_port accept
EOF

    generate_port_rules "$iface" "$in_ports" "iifname"

    if [[ "$ipver" == "ip" ]]; then
        echo "        include \"$BASE_DIR/nftban-nfttables-ct-ipv4.conf.local\"" >> "$OUTPUT_FILE"
    elif [[ "$ipver" == "ip6" ]]; then
        echo "        include \"$BASE_DIR/nftban-nfttables-ct-ipv6.conf.local\"" >> "$OUTPUT_FILE"
    fi

    echo "    }" >> "$OUTPUT_FILE"
    
    cat >> "$OUTPUT_FILE" <<EOF
    chain nftban_output_${iface}_${ipver} {
        type filter hook output priority 0; policy accept;
EOF

    generate_port_rules "$iface" "$out_ports" "oifname"
    
    echo "    }" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
}

# --- Main execution ---

# Create necessary directories
mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR"

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

# --- Dynamically get SSH port ---
SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"
echo "Detected SSH Port: $SSH_PORT"

# --- Get and whitelist ALL server IP addresses ---
echo "--- Detecting and whitelisting server IP addresses ---"

# Get all server interface IPs
SERVER_IPV4=$(ip -4 addr show | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | tr '\n' ' ')
SERVER_IPV6=$(ip -6 addr show | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/[0-9]+' | tr '\n' ' ')

# Get server public IPs
SERVER_PUBLIC_IPV4=$(get_public_ip "ipv4")
SERVER_PUBLIC_IPV6=$(get_public_ip "ipv6")

# Get current user IP
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

IPV4_WHITELIST=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | tr '\n' ',' | sed 's/,$//')
IPV6_WHITELIST=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | tr '\n' ',' | sed 's/,$//')
IPV4_BLACKLIST=$(grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" "$IPV4_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
IPV6_BLACKLIST=$(grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" "$IPV6_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# --- Global loopback rules ---
cat >> "$OUTPUT_FILE" <<EOF
table ip nftban_global {
    chain input {
        type filter hook input priority 0; policy accept;
        iif "lo" accept
    }
}

table ip6 nftban_global {
    chain input {
        type filter hook input priority 0; policy accept;
        iif "lo" accept
    }
}
EOF

# --- Generate chains per interface ---
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
for IFACE in $INTERFACES; do
    echo "Processing interface: $IFACE"
    generate_interface_chains "$IFACE" "ip" "$IPV4_WHITELIST" "$IPV4_BLACKLIST" "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE" "$SSH_PORT"
    generate_interface_chains "$IFACE" "ip6" "$IPV6_WHITELIST" "$IPV6_BLACKLIST" "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE" "$SSH_PORT"
done

# --- Apply ruleset ---
echo "--- Applying nftables ruleset ---"
nft -f "$OUTPUT_FILE" || { echo "Failed to load nftables ruleset"; exit 1; }
echo "nftables ruleset loaded successfully."

# --- Final summary ---
echo "=== Configuration Summary ==="
echo "SSH Port: $SSH_PORT"
echo "Server IPv4 addresses: $SERVER_IPV4"
echo "Server IPv6 addresses: $SERVER_IPV6"
[[ -n "$SERVER_PUBLIC_IPV4" ]] && echo "Server public IPv4: $SERVER_PUBLIC_IPV4"
[[ -n "$SERVER_PUBLIC_IPV6" ]] && echo "Server public IPv6: $SERVER_PUBLIC_IPV6"
[[ -n "$CURRENT_USER_IP" ]] && echo "Current user IP: $CURRENT_USER_IP"
echo "Interfaces configured: $(echo "$INTERFACES" | tr '\n' ' ')"

# --- Save final snapshot ---
FINAL_CONFIG_SNAPSHOT="$LOG_DIR/nftables_final_config_$(date +%Y-%m-%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_CONFIG_SNAPSHOT"
echo "Final configuration saved to: $FINAL_CONFIG_SNAPSHOT"
echo "=== nftables configuration completed successfully ==="
