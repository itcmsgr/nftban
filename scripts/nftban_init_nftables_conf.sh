#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh
#
# Version: 1.6
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# Automates nftables configuration on Linux (RHEL 8+/Fedora/CentOS/Debian/Ubuntu)
# Features:
#  - Centralized configuration files under /etc/nftban/config
#  - Local IP protection: prevents self-lockout
#  - Templates to initialize missing files
#  - Layered firewall: blacklist -> whitelist -> allowed ports → established connections
#  - IPv4/IPv6 separation per interface
#  - Dynamic SSH Port Detection: It reads the SSH port directly from /etc/ssh/sshd_config and defaults to 22 if it cannot be found.
#  - Protocol-Aware Port Rules: The script parses the port configuration files for TCP, UDP, or both, based on the port/protocol format (80/T, 53/U, 22/B).
# All tables: nftban_global, nftban_tbl_<IFACE>.
# All sets: nftban_whitelist_v4/v6, nftban_blacklist_v4/v6.
# All chains: nftban_drop_blacklist_<IFACE>_v4/v6, nftban_input_<IFACE>_v4/v6, nftban_output_<IFACE>_v4/v6.
# Auto remove a whitelist from blacklist lists
# Create a file with unique IPs to used from fail2ban
################################################################################

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"

# --- Logging ---
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/install_nftables_process_$(date +%Y-%m-%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# Config files
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
FAILE2BAN_WHITELIST="$BASE_DIR/nftban-faile2ban-ip-whitelist.conf.local"

# --- Initialize missing config files from templates ---
CONFIG_FILES=(
    "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE"
    "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE"
    "$IPV4_BLACKLIST_FILE" "$IPV6_BLACKLIST_FILE"
    "$USER_CT_FILE_IPv4" "$USER_CT_FILE_IPv6"
    "$USER_WHITELIST_FILE"
)

echo "--- Initializing missing configuration files from templates ---"
for file in "${CONFIG_FILES[@]}"; do
    fname=$(basename "$file")
    template="$BASE_DIR_INIT/$fname"
    if [[ ! -f "$file" ]]; then
        if [[ -f "$template" ]]; then
            cp "$template" "$file"
            echo "Initialized missing config: $file (copied from $template)"
        else
            echo "Warning: $file not found, no template available. Creating empty file."
            touch "$file"
        fi
    fi
done

# --- Helper functions ---
ip_exists_in_file() {
    local ip=$1
    local file=$2
    [[ -f "$file" ]] && grep -q -F "$ip" "$file"
}

generate_port_rules() {
    local iface=$1
    local file=$2
    local direction=$3
    [[ -f "$file" ]] || return
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        port=$(echo "$line" | cut -d'/' -f1)
        proto=$(echo "$line" | cut -d'/' -f2 | tr '[:lower:]' '[:upper:]')
        case "$proto" in
            T) echo "        $direction \"$iface\" tcp dport $port accept" ;;
            U) echo "        $direction \"$iface\" udp dport $port accept" ;;
            B)
                echo "        $direction \"$iface\" tcp dport $port accept"
                echo "        $direction \"$iface\" udp dport $port accept"
                ;;
            *) echo "Warning: Invalid protocol '$proto' for port '$port' in $file" >&2 ;;
        esac
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

    cat >> "$OUTPUT_FILE" <<EOF
table $ipver nftban_tbl_${iface} {
    set nftban_whitelist_${ipver} { type ${ipver}_addr; elements = { $whitelist } }
    set nftban_blacklist_${ipver} { type ${ipver}_addr; elements = { $blacklist } }

    chain nftban_drop_blacklist_${iface}_${ipver} { ${ipver} saddr @nftban_blacklist_${ipver} drop }

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
    echo "    chain nftban_output_${iface}_${ipver} { type filter hook output priority 0; policy accept;" >> "$OUTPUT_FILE"
    generate_port_rules "$iface" "$out_ports" "oifname"
    echo "    }" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
}

# --- Start ruleset ---
echo "--- Flushing existing nftables ruleset and starting generation ---"
echo "flush ruleset" > "$OUTPUT_FILE"

# --- Dynamically get SSH port ---
SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"
echo "Detected SSH Port: $SSH_PORT"

# --- Whitelist local system IPs ---
LOCAL_IPS=$(hostname -I | tr ' ' '\n' | grep -v '^$')
[[ ! -f "$SYSTEM_WHITELIST_FILE" ]] && echo "# Local machine IPs - do not remove" > "$SYSTEM_WHITELIST_FILE"
for ip in $LOCAL_IPS; do
    ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE" || echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
done

# --- Collect whitelist & blacklist IPs ---
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | sort -u | grep -v '^$')

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
echo "$ALL_WHITELIST_IPS" | sort -u > "$FAILE2BAN_WHITELIST"
echo "Fail2Ban whitelist saved to: $FAILE2BAN_WHITELIST"

IPV4_WHITELIST=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | tr '\n' ',' | sed 's/,$//')
IPV6_WHITELIST=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | tr '\n' ',' | sed 's/,$//')
IPV4_BLACKLIST=$(grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" "$IPV4_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
IPV6_BLACKLIST=$(grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" "$IPV6_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# --- Global loopback rules ---
cat >> "$OUTPUT_FILE" <<EOF
add table ip nftban_global
add chain ip nftban_global input { type filter hook input priority 0; policy accept; }
add rule ip nftban_global input iif "lo" accept
add table ip6 nftban_global
add chain ip6 nftban_global input { type filter hook input priority 0; policy accept; }
add rule ip6 nftban_global input iif "lo" accept
EOF

# --- Generate chains per interface ---
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')
for IFACE in $INTERFACES; do
    echo "Processing interface: $IFACE"
    generate_interface_chains "$IFACE" "ip" "$IPV4_WHITELIST" "$IPV4_BLACKLIST" "$IPV4_IN_PORTS_FILE" "$IPV4_OUT_PORTS_FILE" "$SSH_PORT"
    generate_interface_chains "$IFACE" "ip6" "$IPV6_WHITELIST" "$IPV6_BLACKLIST" "$IPV6_IN_PORTS_FILE" "$IPV6_OUT_PORTS_FILE" "$SSH_PORT"
done

# --- Apply ruleset ---
nft -f "$OUTPUT_FILE" || { echo "Failed to load nftables ruleset"; exit 1; }
echo "nftables ruleset loaded successfully."

# --- Update system whitelist from active ruleset ---
nft list ruleset | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | sort -u | while read ip; do
    ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE" || echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
done

# --- Save final snapshot ---
FINAL_CONFIG_SNAPSHOT="$LOG_DIR/nftables_final_config_$(date +%Y-%m-%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_CONFIG_SNAPSHOT"
echo "Final configuration saved to: $FINAL_CONFIG_SNAPSHOT"
echo "nftables ruleset generation and application completed."

