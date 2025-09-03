#!/bin/bash

################################################################################
# Script: nftban_init_conf.sh
#
# Version: 1.1.0
# Author: ITCMS Team (Antonios Voulvoulis) + Debian/Ubuntu Support
# Description:
# This script automates the configuration of nftables 
# on Linux systems (RHEL 8+/Fedora/CentOS/Debian/Ubuntu).
# It ensures all system ips , interfaces , networking enviroment setup init correct.
# Blacklist functionality approach TO ensures a layered defense: 
# first block known malicious IPs, then allow whitelisted and trusted traffic, and finally manage 
# the remaining open ports. This version will also strictly separate all IPv4 and IPv6 rules as requested, 
# a key feature for clean, robust firewall management.
# Core Improvements in this Version
# Dedicated Blacklist Files: 
# We'll use files (ipv4_blacklist_ips.txt and ipv6_blacklist_ips.txt) for IPs you want to explicitly block.
# Blacklist Chains: A new nftables chain, drop_blacklist_traffic, will be created. 
# The main input chain will jump to this chain first, ensuring blacklisted IPs are immediately dropped. This is a common best practice for organizing and prioritizing firewall rules.
# Separate and Intensified: The script will create dedicated ip and ip6 tables for each interface. All rules, sets, and chains will be defined and applied specifically to either IPv4 or IPv6 traffic.
################################################################################


#!/bin/bash

# Configuration file paths
IPV4_IN_PORTS_FILE="nftban-configuration-ipv4-ports-allow-in.conf.local"
IPV4_OUT_PORTS_FILE="ipv4_out_ports.txt"
IPV6_IN_PORTS_FILE="ipv6_in_ports.txt"
IPV6_OUT_PORTS_FILE="ipv6_out_ports.txt"
IPV4_BLACKLIST_FILE="ipv4_blacklist_ips.txt"
IPV6_BLACKLIST_FILE="ipv6_blacklist_ips.txt"
OUTPUT_FILE="nft_rules.nft"
SYSTEM_WHITELIST_FILE="system_whitelist_ips.txt"
USER_WHITELIST_FILE="user_whitelist_ips.txt"

# --- Function to check if an IP exists in a file ---
ip_exists_in_file() {
    local ip=$1
    local file=$2
    if [[ -f "$file" ]]; then
        grep -q -F "$ip" "$file"
    else
        return 1 # File doesn't exist
    fi
}

# --- Main Script ---

# 1. Start with a clean slate for the ruleset file
echo "Flushing existing nftables ruleset and generating new configuration..."
echo "flush ruleset" > "$OUTPUT_FILE"

# 2. Automatically whitelist local IPs in the system file
echo "Checking and adding local IPs to the system whitelist file..."
LOCAL_IPS=$(hostname -I | tr ' ' '\n' | grep -v '^$')
if [[ ! -z "$LOCAL_IPS" ]]; then
    if [[ ! -f "$SYSTEM_WHITELIST_FILE" || -z "$(cat "$SYSTEM_WHITELIST_FILE")" ]]; then
        echo "# Local machine IPs - do not remove" > "$SYSTEM_WHITELIST_FILE"
    fi
    for ip in $LOCAL_IPS; do
        if ! ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE"; then
            echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
            echo "  > Added local IP $ip to $SYSTEM_WHITELIST_FILE"
        fi
    done
fi

# 3. Combine whitelist IPs and read blacklist IPs
echo "Reading and preparing whitelist and blacklist IPs..."
ALL_WHITELIST_IPS=$(cat "$SYSTEM_WHITELIST_FILE" "$USER_WHITELIST_FILE" 2>/dev/null | sort -u)
IPV4_WHITELIST_IPS=$(echo "$ALL_WHITELIST_IPS" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | tr '\n' ',' | sed 's/,$//')
IPV6_WHITELIST_IPS=$(echo "$ALL_WHITELIST_IPS" | grep -oE "(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|[0-9a-fA-F]{1,4}:(([0-9a-fA-F]{1,4}:){1,6})|:((:[0-9a-fA-F]{1,4}){1,7})|fe80::([0-9a-fA-F]{0,4}:){0,4}%[0-9a-zA-Z]{1,})$" | tr '\n' ',' | sed 's/,$//')

IPV4_BLACKLIST_IPS=$(grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" "$IPV4_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
IPV6_BLACKLIST_IPS=$(grep -oE "(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|[0-9a-fA-F]{1,4}:(([0-9a-fA-F]{1,4}:){1,6})|:((:[0-9a-fA-F]{1,4}){1,7})|fe80::([0-9a-fA-F]{0,4}:){0,4}%[0-9a-zA-Z]{1,})$" "$IPV6_BLACKLIST_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# 4. Add global loopback rules
echo "Adding global loopback rules to file..."
echo "add table ip filter_global" >> "$OUTPUT_FILE"
echo "add chain ip filter_global input { type filter hook input priority 0; policy accept; }" >> "$OUTPUT_FILE"
echo "add rule ip filter_global input iif \"lo\" accept" >> "$OUTPUT_FILE"

echo "add table ip6 filter_global" >> "$OUTPUT_FILE"
echo "add chain ip6 filter_global input { type filter hook input priority 0; policy accept; }" >> "$OUTPUT_FILE"
echo "add rule ip6 filter_global input iif \"lo\" accept" >> "$OUTPUT_FILE"

# 5. Discover network interfaces
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | xargs)

# 6. Process each interface
for IFACE in $INTERFACES; do
    echo "Processing interface: $IFACE"
    
    # Generate IPv4 table and chains
    TABLE_IPV4="table ip nftban_tbl_${IFACE}"
    CHAIN_INPUT_IPV4="chain input_${IFACE}"
    CHAIN_OUTPUT_IPV4="chain output_${IFACE}"
    CHAIN_BLACKLIST_IPV4="chain drop_blacklist_${IFACE}_ipv4"
    
    echo "Creating rules for IPv4 on $IFACE..."
    {
        echo "$TABLE_IPV4 {"
        echo "    set whitelist_v4 { type ipv4_addr; elements = { $IPV4_WHITELIST_IPS } }"
        echo "    set blacklist_v4 { type ipv4_addr; elements = { $IPV4_BLACKLIST_IPS } }"
        echo "    $CHAIN_BLACKLIST_IPV4 {"
        echo "        ip saddr @blacklist_v4 drop"
        echo "    }"
        echo "    $CHAIN_INPUT_IPV4 {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"$IFACE\" jump $CHAIN_BLACKLIST_IPV4"
        echo "        iifname \"$IFACE\" ip saddr @whitelist_v4 accept"
        echo "        iifname \"$IFACE\" ct state established,related accept"
        while IFS= read -r port; do
            if [[ ! "$port" =~ ^# && -n "$port" ]]; then
                echo "        iifname \"$IFACE\" tcp dport $port accept"
                echo "        iifname \"$IFACE\" udp dport $port accept"
            fi
        done < "$IPV4_IN_PORTS_FILE"
        echo "    }"

        echo "    $CHAIN_OUTPUT_IPV4 {"
        echo "        type filter hook output priority 0; policy accept;"
        while IFS= read -r port; do
            if [[ ! "$port" =~ ^# && -n "$port" ]]; then
                echo "        oifname \"$IFACE\" tcp dport $port accept"
                echo "        oifname \"$IFACE\" udp dport $port accept"
            fi
        done < "$IPV4_OUT_PORTS_FILE"
        echo "    }"
        echo "}"
    } >> "$OUTPUT_FILE"

    # Generate IPv6 table and chains
    TABLE_IPV6="table ip6 nftban_tbl_${IFACE}"
    CHAIN_INPUT_IPV6="chain input_${IFACE}"
    CHAIN_OUTPUT_IPV6="chain output_${IFACE}"
    CHAIN_BLACKLIST_IPV6="chain drop_blacklist_${IFACE}_ipv6"

    echo "Creating rules for IPv6 on $IFACE..."
    {
        echo "$TABLE_IPV6 {"
        echo "    set whitelist_v6 { type ipv6_addr; elements = { $IPV6_WHITELIST_IPS } }"
        echo "    set blacklist_v6 { type ipv6_addr; elements = { $IPV6_BLACKLIST_IPS } }"
        echo "    $CHAIN_BLACKLIST_IPV6 {"
        echo "        ip6 saddr @blacklist_v6 drop"
        echo "    }"
        echo "    $CHAIN_INPUT_IPV6 {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"$IFACE\" jump $CHAIN_BLACKLIST_IPV6"
        echo "        iifname \"$IFACE\" ip6 saddr @whitelist_v6 accept"
        echo "        iifname \"$IFACE\" ct state established,related accept"
        while IFS= read -r port; do
            if [[ ! "$port" =~ ^# && -n "$port" ]]; then
                echo "        iifname \"$IFACE\" tcp dport $port accept"
                echo "        iifname \"$IFACE\" udp dport $port accept"
            fi
        done < "$IPV6_IN_PORTS_FILE"
        echo "    }"
        
        echo "    $CHAIN_OUTPUT_IPV6 {"
        echo "        type filter hook output priority 0; policy accept;"
        while IFS= read -r port; do
            if [[ ! "$port" =~ ^# && -n "$port" ]]; then
                echo "        oifname \"$IFACE\" tcp dport $port accept"
                echo "        oifname \"$IFACE\" udp dport $port accept"
            fi
        done < "$IPV6_OUT_PORTS_FILE"
        echo "    }"
        echo "}"
    } >> "$OUTPUT_FILE"
done

echo "nftables ruleset written to $OUTPUT_FILE."
echo "Loading the ruleset..."
# 7. Apply the rules from the generated file
sudo nft -f "$OUTPUT_FILE"

# 8. Extract IPs from the active ruleset and add to the system whitelist
echo "Extracting IPs from the active ruleset to update the system whitelist..."
sudo nft list ruleset | \
    grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}|(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|[0-9a-fA-F]{1,4}:(([0-9a-fA-F]{1,4}:){1,6})|:((:[0-9a-fA-F]{1,4}){1,7})|fe80::([0-9a-fA-F]{0,4}:){0,4}%[0-9a-zA-Z]{1,})$" | \
    sort -u | while read ip; do
    if ! ip_exists_in_file "$ip" "$SYSTEM_WHITELIST_FILE"; then
        echo "$ip" >> "$SYSTEM_WHITELIST_FILE"
        echo "  > Added IP $ip from ruleset to $SYSTEM_WHITELIST_FILE"
    fi
done

echo "nftables ruleset loaded and whitelists updated successfully."


