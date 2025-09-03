#!/bin/bash
################################################################################
# Script: nftban_init_nftables_conf.sh
#
# Version: 1.3.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# Automates nftables configuration on Linux (RHEL 8+/Fedora/CentOS/Debian/Ubuntu)
# Features:
#  - Centralized configuration files under /etc/nftban/config
#  - Local IP protection: prevents self-lockout
#  - Templates to initialize missing files
#  - Layered firewall: blacklist -> whitelist -> allowed ports → established connections
#  - IPv4/IPv6 separation per interface
################################################################################

# --- Configuration ---
BASE_DIR="/etc/nftban/config"
BASE_DIR_INIT="/etc/nftban/templates"

# --- Logging ---
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/install_nftables_process_$(date +%Y-%m-%d-%H%M%S).log"
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
OUTPUT_FILE="$BASE_DIR/nft_rules.conf.local"

# --- Initialize missing config files from templates ---
CONFIG_FILES=(
    "$IPV4_IN_PORTS_FILE"
    "$IPV4_OUT_PORTS_FILE"
    "$IPV6_IN_PORTS_FILE"
    "$IPV6_OUT_PORTS_FILE"
    "$IPV4_BLACKLIST_FILE"
    "$IPV6_BLACKLIST_FILE"
    "$USER_WHITELIST_FILE"
)

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

# --- Helper function: check if IP exists in file ---
ip_exists_in_file() {
    local ip=$1
    local file=$2
    [[ -f "$file" ]] && grep -q -F "$ip" "$file"
}

# --- Start ruleset ---
echo "Flushing existing nftables ruleset..."
echo "flush ruleset" > "$OUTPUT_FILE"

# --- Whitelist local system IPs ---
echo "Checking and adding local IPs to $SYSTEM_WHITELIST_FILE..."
LOCAL_IPS=$(hostname -I | tr ' ' '\n' | grep -v '^$')
if [[ -n "$LOCAL_IPS" ]]; then
    [[ ! -f "$SYSTEM_WHITELIST_FILE" ]] && echo "# Local machine IPs - do not remove" > "$SYSTEM_WHITELIST_FILE"
    for ip in $LOCAL_IPS; do
        if ! ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE"; then
            echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
            echo "  > Added local IP $ip"
        fi
    done
fi

# --- Collect whitelist & blacklist IPs ---
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | sort -u)
IPV4_WHITELIST_IPS=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | tr '\n' ',' | sed 's/,$//')
IPV6_WHITELIST_IPS=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | tr '\n' ',' | sed 's/,$//')
IPV4_BLACKLIST_IPS=$(grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" "$IPV4_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
IPV6_BLACKLIST_IPS=$(grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" "$IPV6_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# --- Global loopback rules ---
{
    echo "add table ip filter_global"
    echo "add chain ip filter_global input { type filter hook input priority 0; policy accept; }"
    echo "add rule ip filter_global input iif \"lo\" accept"
    echo "add table ip6 filter_global"
    echo "add chain ip6 filter_global input { type filter hook input priority 0; policy accept; }"
    echo "add rule ip6 filter_global input iif \"lo\" accept"
} >> "$OUTPUT_FILE"

# --- Discover interfaces ---
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')

# --- Interface rules ---
for IFACE in $INTERFACES; do
    echo "Processing interface: $IFACE"

    # IPv4 rules
    {
        echo "table ip nftban_tbl_${IFACE} {"
        echo "    set whitelist_v4 { type ipv4_addr; elements = { $IPV4_WHITELIST_IPS } }"
        echo "    set blacklist_v4 { type ipv4_addr; elements = { $IPV4_BLACKLIST_IPS } }"
        echo "    chain drop_blacklist_${IFACE}_ipv4 { ip saddr @blacklist_v4 drop }"
        echo "    chain input_${IFACE} {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"$IFACE\" jump drop_blacklist_${IFACE}_ipv4"
        echo "        iifname \"$IFACE\" ip saddr @whitelist_v4 accept"
        echo "        iifname \"$IFACE\" ct state established,related accept"
        [[ -f "$IPV4_IN_PORTS_FILE" ]] && while read -r port; do
            [[ -n "$port" && ! "$port" =~ ^# ]] && echo "        iifname \"$IFACE\" tcp dport $port accept" && echo "        iifname \"$IFACE\" udp dport $port accept"
        done < "$IPV4_IN_PORTS_FILE"
        echo "    }"
        echo "    chain output_${IFACE} {"
        echo "        type filter hook output priority 0; policy accept;"
        [[ -f "$IPV4_OUT_PORTS_FILE" ]] && while read -r port; do
            [[ -n "$port" && ! "$port" =~ ^# ]] && echo "        oifname \"$IFACE\" tcp dport $port accept" && echo "        oifname \"$IFACE\" udp dport $port accept"
        done < "$IPV4_OUT_PORTS_FILE"
        echo "    }"
        echo "}"
    } >> "$OUTPUT_FILE"

    # IPv6 rules
    {
        echo "table ip6 nftban_tbl_${IFACE} {"
        echo "    set whitelist_v6 { type ipv6_addr; elements = { $IPV6_WHITELIST_IPS } }"
        echo "    set blacklist_v6 { type ipv6_addr; elements = { $IPV6_BLACKLIST_IPS } }"
        echo "    chain drop_blacklist_${IFACE}_ipv6 { ip6 saddr @blacklist_v6 drop }"
        echo "    chain input_${IFACE} {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"$IFACE\" jump drop_blacklist_${IFACE}_ipv6"
        echo "        iifname \"$IFACE\" ip6 saddr @whitelist_v6 accept"
        echo "        iifname \"$IFACE\" ct state established,related accept"
        [[ -f "$IPV6_IN_PORTS_FILE" ]] && while read -r port; do
            [[ -n "$port" && ! "$port" =~ ^# ]] && echo "        iifname \"$IFACE\" tcp dport $port accept" && echo "        iifname \"$IFACE\" udp dport $port accept"
        done < "$IPV6_IN_PORTS_FILE"
        echo "    }"
        echo "    chain output_${IFACE} {"
        echo "        type filter hook output priority 0; policy accept;"
        [[ -f "$IPV6_OUT_PORTS_FILE" ]] && while read -r port; do
            [[ -n "$port" && ! "$port" =~ ^# ]] && echo "        oifname \"$IFACE\" tcp dport $port accept" && echo "        oifname \"$IFACE\" udp dport $port accept"
        done < "$IPV6_OUT_PORTS_FILE"
        echo "    }"
        echo "}"
    } >> "$OUTPUT_FILE"
done

# --- Apply ruleset ---
echo "Applying nftables ruleset..."
if ! sudo nft -f "$OUTPUT_FILE"; then
    echo "Failed to load nftables ruleset. Check $OUTPUT_FILE for errors."
    exit 1
fi

# --- Update system whitelist from active ruleset ---
echo "Updating system whitelist from active ruleset..."
sudo nft list ruleset | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | sort -u | while read ip; do
    if ! ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE"; then
        echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
        echo "  > Added $ip to $SYSTEM_WHITELIST_FILE"
    fi
done
# --- Save final configuration snapshot ---
FINAL_CONFIG_SNAPSHOT="$LOG_DIR/nftables_final_config_$(date +%Y-%m-%d-%H%M%S).conf"
cp "$OUTPUT_FILE" "$FINAL_CONFIG_SNAPSHOT"
echo "Final configuration saved to: $FINAL_CONFIG_SNAPSHOT"

echo "nftables ruleset loaded and whitelists updated successfully."
