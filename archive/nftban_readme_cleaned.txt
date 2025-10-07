#!/bin/bash
# ==============================================================================
# Script: nftban_init_nftables_conf.sh
# Version: 2.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Purpose:
#   Initialize and generate nftables rules using a single global table
#   (inet nftban_global) for simplified firewall management.
#
# Key Features:
#   - One global table: inet nftban_global (applies to both IPv4 and IPv6)
#   - Whitelist always takes priority
#   - Separate sets for:
#       * Whitelist (system and user)
#       * User blacklist (manual bans)
#       * System blacklist (bulk bans, ranges, feeds)
#       * Temporary bans (auto-expire)
#   - Compatible with unified nftban scripts and Fail2Ban integration
#   - Auto-detects server IPs and SSH port
#   - Optional: add Cloudflare IP ranges to whitelist
#
# NFTables Structure Explained
# ----------------------------
# The firewall configuration defined in the script uses a simplified structure:
#
#   Family -> Table -> { Chain, Set }
#
#   Family (inet): Scope, applies to both IPv4 and IPv6 traffic.
#   Table (nftban_global): Container for all related chains and sets.
#   Set (system_blacklist_v4): Data structure inside the table holding a list of
#     IPv4 addresses (or networks). Sets are optimized for fast lookups.
#
# The Table's Components
# ----------------------
# Component   Type   Name                Family   Purpose
# ---------   ----   ------------------  ------   -------------------------------------------
# Table       table  nftban_global       inet     Container for all firewall rules and IP sets
# Set         set    whitelist_v4        (impl.)  IPv4 addresses always allowed
# Set         set    whitelist_v6        (impl.)  IPv6 addresses always allowed
# Set         set    user_blacklist_v4   (impl.)  IPv4 manual user bans
# Set         set    user_blacklist_v6   (impl.)  IPv6 manual user bans
# Set         set    system_blacklist_v4 (impl.)  IPv4 bulk bans (e.g., country blocks, ranges)
# Set         set    system_blacklist_v6 (impl.)  IPv6 bulk bans (ranges)
# Set         set    temp_ban_v4         (impl.)  IPv4 temporary, time-limited bans
# Set         set    temp_ban_v6         (impl.)  IPv6 temporary, time-limited bans
# Chain       chain  input               (impl.)  Processes incoming traffic (whitelist ->
#                                                 blacklist -> temp_ban -> state/ports)
# Chain       chain  forward             (impl.)  Same logic applied to forwarded traffic
# Chain       chain  output              (impl.)  Processes outgoing traffic

# Core Components
# ---------------
# Component   Family    Name           Purpose
# ---------   -------   ------------   --------------------------------------------------------
# Table       inet      nftban_global  The single container for all rules and IP Sets (v4/v6).
# Chain      (implicit) input          Hook: input, Priority: -150. Processes incoming traffic
#                                      (where whitelist/blacklists are checked).
# Chain      (implicit) output         Hook: output, Priority: 0. Processes outgoing traffic.
#
# IP Address Sets (The Lists)
# ---------------------------
# The table contains six primary Sets, three for IPv4 and three for IPv6. These are used to
# store and quickly look up addresses for whitelisting and blacklisting.
#
# Set Name              IP Version  Flags     Purpose
# --------------------  ---------   --------  -----------------------------------------------
# whitelist_v4          IPv4        interval  IPs that are always allowed (system, user,
#                                             Cloudflare). Whitelist always wins.
# whitelist_v6          IPv6        interval  IPs that are always allowed.
# user_blacklist_v4     IPv4        interval  IPs banned manually by the user.
# user_blacklist_v6     IPv6        interval  IPv6 addresses banned manually by the user.
# system_blacklist_v4   IPv4        interval  IPs banned in bulk (e.g., country blocks,
#                                             large ranges).
# system_blacklist_v6   IPv6        interval  IPv6 addresses banned in bulk.
# temp_ban_v4           IPv4        timeout   IPs banned temporarily (e.g., by main script).
# temp_ban_v6           IPv6        timeout   IPv6 addresses banned temporarily.
#
# Example interactions (add IP to a set):
#   sudo nft add element inet nftban_global whitelist_v4 { 192.0.2.1 }
#   sudo nft add element inet nftban_global whitelist_v6 { 2001:db8::1 }
#   sudo nft add element inet nftban_global user_blacklist_v4 { 203.0.113.10 }
#   sudo nft add element inet nftban_global user_blacklist_v6 { 2001:db8:abc::1 }
#   sudo nft add element inet nftban_global system_blacklist_v4 { 198.51.100.0/24 }
#   sudo nft add element inet nftban_global system_blacklist_v6 { 2001:db8:deaf::/48 }
#   sudo nft add element inet nftban_global temp_ban_v4 { 192.0.2.5 timeout 1h }
#   sudo nft add element inet nftban_global temp_ban_v6 { 2001:db8:cafe::1 timeout 1h }
#
# How to Access and Modify Sets
# -----------------------------
# General syntax:
#   nft [add|delete|list] element [family] [table] [set] { element(s) }
#
# Examples for system_blacklist_v4:
#   1) List current contents:
#      sudo nft list set inet nftban_global system_blacklist_v4
#   2) Add an IP:
#      sudo nft add element inet nftban_global system_blacklist_v4 { 203.0.113.5 }
#   3) Remove an IP:
#      sudo nft delete element inet nftban_global system_blacklist_v4 { 203.0.113.5 }
# ==============================================================================

