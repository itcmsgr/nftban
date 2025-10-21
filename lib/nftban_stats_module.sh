#!/usr/bin/env bash

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027


# =============================================================================
# NFTBan Statistics Module
# Version: 0.9.2
# Location: lib/nftban_stats_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Statistics, reporting, and monitoring
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_STATS_LOADED:-}" ]] && return 0
readonly NFTBAN_STATS_LOADED=1

# =============================================================================
# STATS MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_STATS_DB="${NFTBAN_DATA_DIR}/stats.db"
readonly NFTBAN_STATS_CACHE="${NFTBAN_CACHE_DIR}/stats-cache.json"

# =============================================================================
# SHOW COMPREHENSIVE DASHBOARD
# =============================================================================
nftban_stats_dashboard() {
    echo -e "\n${NFTBAN_CYAN}╔════════════════════════════════════════════════╗${NFTBAN_NC}"
    echo -e "${NFTBAN_CYAN}║         NFTBan Statistics Dashboard            ║${NFTBAN_NC}"
    echo -e "${NFTBAN_CYAN}╚════════════════════════════════════════════════╝${NFTBAN_NC}\n"
    
    # System Info
    echo -e "${NFTBAN_BLUE}[SYSTEM]${NFTBAN_NC}"
    echo "  Hostname: $(hostname)"
    echo "  Date: $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Whitelist Stats
    nftban_stats_whitelist_summary
    echo ""
    
    # Blacklist Stats
    nftban_stats_blacklist_summary
    echo ""
    
    # Ban Activity
    nftban_stats_ban_activity
    echo ""
    
    # GEO Blocking
    nftban_stats_geo_summary
    echo ""
    
    # Cloudflare
    nftban_stats_cloudflare_summary
    echo ""
    
    # nftables Status
    nftban_stats_nftables_summary
}

# =============================================================================
# WHITELIST SUMMARY
# =============================================================================
nftban_stats_whitelist_summary() {
    echo -e "${NFTBAN_GREEN}[WHITELIST]${NFTBAN_NC}"

    local wl_system=0
    local wl_user=0
    local wl_cf=0

    if [[ -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        wl_system=$(grep -cvE '^#|^$' "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null)
        wl_system=${wl_system:-0}
    fi
    if [[ -f "$NFTBAN_WHITELIST_USER" ]]; then
        wl_user=$(grep -cvE '^#|^$' "$NFTBAN_WHITELIST_USER" 2>/dev/null)
        wl_user=${wl_user:-0}
    fi
    if [[ -f "${NFTBAN_WHITELIST_CF:-}" ]] && [[ -n "${NFTBAN_WHITELIST_CF:-}" ]]; then
        wl_cf=$(grep -cvE '^#|^$' "$NFTBAN_WHITELIST_CF" 2>/dev/null)
        wl_cf=${wl_cf:-0}
    fi

    local total=$((${wl_system:-0} + ${wl_user:-0} + ${wl_cf:-0}))
    
    echo "  System: $wl_system"
    echo "  User: $wl_user"
    echo "  Cloudflare: $wl_cf"
    echo "  ──────────────"
    echo "  Total: $total"
}

# =============================================================================
# BLACKLIST SUMMARY
# =============================================================================
nftban_stats_blacklist_summary() {
    echo -e "${NFTBAN_RED}[BLACKLIST]${NFTBAN_NC}"

    local bl_persistent=0
    local bl_user=0

    if [[ -f "$NFTBAN_BLACKLIST_PERSISTENT" ]]; then
        bl_persistent=$(grep -cvE '^#|^$' "$NFTBAN_BLACKLIST_PERSISTENT" 2>/dev/null)
        bl_persistent=${bl_persistent:-0}
    fi
    if [[ -f "$NFTBAN_BLACKLIST_USER" ]]; then
        bl_user=$(grep -cvE '^#|^$' "$NFTBAN_BLACKLIST_USER" 2>/dev/null)
        bl_user=${bl_user:-0}
    fi

    local total=$((${bl_persistent:-0} + ${bl_user:-0}))
    
    echo "  Persistent: $bl_persistent"
    echo "  User: $bl_user"
    echo "  ──────────────"
    echo "  Total: $total"
}

# =============================================================================
# BAN ACTIVITY SUMMARY
# =============================================================================
nftban_stats_ban_activity() {
    echo -e "${NFTBAN_YELLOW}[BAN ACTIVITY]${NFTBAN_NC}"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "  No ban activity recorded"
        return 0
    fi
    
    local total=$(wc -l < "$NFTBAN_BAN_LOG")
    echo "  Total events: $total"
    
    if [[ $total -gt 0 ]]; then
        echo ""
        echo "  Breakdown by action:"
        awk -F'|' '{print $4}' "$NFTBAN_BAN_LOG" | sort | uniq -c | sort -rn | while read -r count action; do
            printf "    %-20s %6d\n" "$action" "$count"
        done
        
        echo ""
        echo "  Top 5 banned IPs:"
        awk -F'|' '$4 == "BANNED" {print $2}' "$NFTBAN_BAN_LOG" | sort | uniq -c | sort -rn | head -5 | while read -r count ip; do
            printf "    %-16s %6d times\n" "$ip" "$count"
        done
        
        echo ""
        echo "  Recent activity (last 5):"
        tail -5 "$NFTBAN_BAN_LOG" | while IFS='|' read -r timestamp ip jail action reason; do
            echo "    $timestamp | $ip | $action"
        done
    fi
}

# =============================================================================
# GEO BLOCKING SUMMARY
# =============================================================================
nftban_stats_geo_summary() {
    echo -e "${NFTBAN_MAGENTA}[GEO BLOCKING]${NFTBAN_NC}"
    
    if [[ ! -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        echo "  Not configured"
        return 0
    fi
    
    local blocked_countries=$(grep -cvE '^#|^$' "$NFTBAN_GEO_BLACKLIST" 2>/dev/null)
    blocked_countries=${blocked_countries:-0}
    echo "  Blocked countries: $blocked_countries"
    
    if [[ $blocked_countries -gt 0 ]]; then
        echo "  Countries:"
        grep -vE '^#|^$' "$NFTBAN_GEO_BLACKLIST" | while read -r line; do
            local country=$(echo "$line" | awk '{print $1}')
            echo "    - $country"
        done
    fi
    
    # Count active GEO sets in nftables (v0.9.0 split tables)
    local geo_sets_v4=0
    local geo_sets_v6=0

    if nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null 2>&1; then
        geo_sets_v4=$(nft list sets "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" 2>/dev/null | grep -c "geo_block" || echo 0)
    fi

    if nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null 2>&1; then
        geo_sets_v6=$(nft list sets "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" 2>/dev/null | grep -c "geo_block" || echo 0)
    fi

    local total_geo_sets=$((geo_sets_v4 + geo_sets_v6))
    if [[ $total_geo_sets -gt 0 ]]; then
        echo "  Active nftables sets: $total_geo_sets (IPv4: $geo_sets_v4, IPv6: $geo_sets_v6)"
    fi
}

# =============================================================================
# CLOUDFLARE SUMMARY
# =============================================================================
nftban_stats_cloudflare_summary() {
    echo -e "${NFTBAN_CYAN}[CLOUDFLARE]${NFTBAN_NC}"
    
    local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
    echo "  Status: $cf_enabled"
    
    if [[ "$cf_enabled" == "true" ]]; then
        local ipv4_count=0
        local ipv6_count=0
        
        [[ -f "$NFTBAN_CF_IPV4_CACHE" ]] && ipv4_count=$(wc -l < "$NFTBAN_CF_IPV4_CACHE")
        [[ -f "$NFTBAN_CF_IPV6_CACHE" ]] && ipv6_count=$(wc -l < "$NFTBAN_CF_IPV6_CACHE")
        
        echo "  IPv4 ranges: $ipv4_count"
        echo "  IPv6 ranges: $ipv6_count"
        
        if [[ -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
            local age=$(( ($(date +%s) - $(stat -c %Y "$NFTBAN_CF_IPV4_CACHE")) / 3600 ))
            echo "  Cache age: ${age}h"
        fi
    fi
}

# =============================================================================
# NFTABLES SUMMARY (v0.9.0 SPLIT TABLES)
# =============================================================================
nftban_stats_nftables_summary() {
    echo -e "${NFTBAN_BLUE}[NFTABLES]${NFTBAN_NC}"

    # Check if v0.9.0 split tables exist
    local v4_exists=false
    local v6_exists=false

    if nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null 2>&1; then
        v4_exists=true
    fi

    if nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null 2>&1; then
        v6_exists=true
    fi

    if [[ "$v4_exists" == "false" ]] && [[ "$v6_exists" == "false" ]]; then
        # Check for legacy v0.8.5 table
        if nft list table inet nftban_global &>/dev/null 2>&1; then
            echo "  Legacy v0.8.5 table detected: inet nftban_global"
            echo "  Please run: nftban migrate v085-to-v090"
        else
            echo "  Tables not found (run: nftban nftables init)"
        fi
        return 0
    fi

    # Show split tables info
    if [[ "$v4_exists" == "true" ]]; then
        echo -e "  IPv4 Table: ${NFTBAN_GREEN}$NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4${NFTBAN_NC}"
    else
        echo -e "  IPv4 Table: ${NFTBAN_RED}NOT FOUND${NFTBAN_NC}"
    fi

    if [[ "$v6_exists" == "true" ]]; then
        echo -e "  IPv6 Table: ${NFTBAN_GREEN}$NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6${NFTBAN_NC}"
    else
        echo -e "  IPv6 Table: ${NFTBAN_RED}NOT FOUND${NFTBAN_NC}"
    fi

    echo ""
    echo "  Sets:"

    # Count elements from both tables
    local sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

    for set in "${sets[@]}"; do
        local v4_count=0
        local v6_count=0

        # Count IPv4 set elements
        if [[ "$v4_exists" == "true" ]]; then
            if nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set" &>/dev/null 2>&1; then
                v4_count=$(nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set" 2>/dev/null | \
                           grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l)
            fi
        fi

        # Count IPv6 set elements
        if [[ "$v6_exists" == "true" ]]; then
            if nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set" &>/dev/null 2>&1; then
                v6_count=$(nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set" 2>/dev/null | \
                           grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
            fi
        fi

        local total=$((v4_count + v6_count))
        if [[ $total -gt 0 ]]; then
            printf "    %-20s %6d total (IPv4: %d, IPv6: %d)\n" "$set" "$total" "$v4_count" "$v6_count"
        fi
    done
}

# =============================================================================
# IP BAN HISTORY
# =============================================================================
nftban_stats_ip_history() {
    local ip="$1"
    
    echo -e "\n${NFTBAN_CYAN}=== Ban History for $ip ===${NFTBAN_NC}\n"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "No ban log available"
        return 0
    fi
    
    local results=$(grep "|${ip}|" "$NFTBAN_BAN_LOG" 2>/dev/null || true)
    
    if [[ -z "$results" ]]; then
        echo "No history found for $ip"
        return 0
    fi
    
    local total=$(echo "$results" | wc -l)
    echo "Total events: $total"
    echo ""
    
    # Show all events
    echo "$results" | while IFS='|' read -r timestamp ip_addr jail action reason; do
        local action_color=""
        case "$action" in
            BANNED) action_color="${NFTBAN_RED}" ;;
            WHITELISTED) action_color="${NFTBAN_GREEN}" ;;
            UNBANNED) action_color="${NFTBAN_CYAN}" ;;
            *) action_color="${NFTBAN_NC}" ;;
        esac
        
        echo -e "${action_color}[$action]${NFTBAN_NC} $timestamp"
        echo "  Jail: $jail"
        echo "  Reason: $reason"
        echo ""
    done
    
    # Summary
    echo "Summary:"
    echo "$results" | awk -F'|' '{print $4}' | sort | uniq -c | sort -rn | while read -r count action; do
        printf "  %-15s %4d\n" "$action" "$count"
    done
}

# =============================================================================
# TOP BANNED IPS
# =============================================================================
nftban_stats_top_banned() {
    local limit="${1:-10}"
    
    echo -e "\n${NFTBAN_CYAN}=== Top $limit Banned IPs ===${NFTBAN_NC}\n"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "No ban log available"
        return 0
    fi
    
    awk -F'|' '$4 == "BANNED" {print $2}' "$NFTBAN_BAN_LOG" | \
        sort | uniq -c | sort -rn | head -"$limit" | \
        while read -r count ip; do
            printf "%3d. %-16s %6d bans\n" "$((++i))" "$ip" "$count"
        done
}

# =============================================================================
# RECENT ACTIVITY
# =============================================================================
nftban_stats_recent() {
    local limit="${1:-20}"
    
    echo -e "\n${NFTBAN_CYAN}=== Recent Activity (last $limit) ===${NFTBAN_NC}\n"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "No ban log available"
        return 0
    fi
    
    tail -"$limit" "$NFTBAN_BAN_LOG" | while IFS='|' read -r timestamp ip jail action reason; do
        local action_color=""
        case "$action" in
            BANNED) action_color="${NFTBAN_RED}" ;;
            WHITELISTED) action_color="${NFTBAN_GREEN}" ;;
            UNBANNED) action_color="${NFTBAN_CYAN}" ;;
            PERMANENT_BAN) action_color="${NFTBAN_MAGENTA}" ;;
            *) action_color="${NFTBAN_NC}" ;;
        esac
        
        printf "%s | %-16s | ${action_color}%-15s${NFTBAN_NC} | %s\n" \
            "$timestamp" "$ip" "$action" "$jail"
    done
}

# =============================================================================
# EXPORT TO CSV
# =============================================================================
nftban_stats_export_csv() {
    local output_file="${1:-/tmp/nftban-stats-$(date +%Y%m%d-%H%M%S).csv}"
    
    nftban_log_info "Exporting statistics to CSV: $output_file"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        nftban_log_error "No ban log available"
        return 1
    fi
    
    # Create CSV header
    echo "Timestamp,IP Address,Jail,Action,Reason" > "$output_file"
    
    # Export all data
    cat "$NFTBAN_BAN_LOG" | sed 's/|/,/g' >> "$output_file"
    
    local total=$(wc -l < "$output_file")
    nftban_log_success "Exported $((total - 1)) records to $output_file"
    
    echo "$output_file"
}

# =============================================================================
# GENERATE REPORT
# =============================================================================
nftban_stats_generate_report() {
    local output_file="${1:-/tmp/nftban-report-$(date +%Y%m%d-%H%M%S).txt}"
    
    nftban_log_info "Generating comprehensive report: $output_file"
    
    {
        echo "═══════════════════════════════════════════════════════════"
        echo "            NFTBan Comprehensive Report"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "Generated: $(date +'%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo ""
        
        # Dashboard
        nftban_stats_dashboard
        
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "                   Top 20 Banned IPs"
        echo "═══════════════════════════════════════════════════════════"
        nftban_stats_top_banned 20
        
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "                  Recent Activity (50)"
        echo "═══════════════════════════════════════════════════════════"
        nftban_stats_recent 50
        
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "                    Configuration"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        
        if [[ -f "$NFTBAN_LOCAL_CONFIG" ]]; then
            echo "Configuration file: $NFTBAN_LOCAL_CONFIG"
            echo ""
            grep -v '^#' "$NFTBAN_LOCAL_CONFIG" | grep -v '^$'
        fi
        
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "                     End of Report"
        echo "═══════════════════════════════════════════════════════════"
        
    } > "$output_file"
    
    nftban_log_success "Report generated: $output_file"
    echo "$output_file"
}

# =============================================================================
# MONITOR MODE (real-time)
# =============================================================================
nftban_stats_monitor() {
    nftban_log_info "Starting real-time monitoring (Ctrl+C to exit)..."
    echo ""
    
    trap 'echo ""; nftban_log_info "Monitoring stopped"; exit 0' INT
    
    while true; do
        clear
        echo -e "${NFTBAN_CYAN}╔════════════════════════════════════════════════╗${NFTBAN_NC}"
        echo -e "${NFTBAN_CYAN}║       NFTBan Real-Time Monitor                 ║${NFTBAN_NC}"
        echo -e "${NFTBAN_CYAN}╚════════════════════════════════════════════════╝${NFTBAN_NC}"
        echo ""
        echo "Time: $(date +'%Y-%m-%d %H:%M:%S')"
        echo ""
        
        # Quick stats
        nftban_stats_dashboard
        
        echo ""
        echo -e "${NFTBAN_YELLOW}Recent activity (last 10):${NFTBAN_NC}"
        nftban_stats_recent 10
        
        sleep 5
    done
}

# =============================================================================
# CLEANUP OLD LOGS
# =============================================================================
nftban_stats_cleanup_logs() {
    local days="${1:-30}"
    
    nftban_log_info "Cleaning up logs older than $days days..."
    
    local cleaned=0
    
    # Rotate ban log if too large (>10MB)
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        local size=$(stat -c %s "$NFTBAN_BAN_LOG")
        if [[ $size -gt 10485760 ]]; then  # 10MB
            local backup="${NFTBAN_BAN_LOG}.$(date +%Y%m%d-%H%M%S)"
            mv "$NFTBAN_BAN_LOG" "$backup"
            gzip "$backup" 2>/dev/null || true
            touch "$NFTBAN_BAN_LOG"
            nftban_log_success "Rotated ban log: $backup.gz"
            ((cleaned++))
        fi
    fi
    
    # Find and compress old logs
    find "$NFTBAN_LOG_DIR" -name "*.log" -mtime +7 -type f 2>/dev/null | while read -r file; do
        if [[ ! "$file" =~ \.gz$ ]]; then
            gzip "$file" 2>/dev/null && ((cleaned++))
        fi
    done
    
    # Delete very old compressed logs
    find "$NFTBAN_LOG_DIR" -name "*.log.gz" -mtime +$days -type f -delete 2>/dev/null
    
    nftban_log_success "Log cleanup complete: $cleaned files processed"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_stats_dashboard
export -f nftban_stats_ip_history
export -f nftban_stats_top_banned
export -f nftban_stats_recent
export -f nftban_stats_export_csv
export -f nftban_stats_generate_report
export -f nftban_stats_monitor
export -f nftban_stats_cleanup_logs

nftban_log_debug "NFTBan Stats Module loaded"
