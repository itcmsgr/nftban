#!/usr/bin/env bash

# =============================================================================
# NFTBan - Unified CLI Interface (WITH VALIDATION)
# Version: 0.8.5
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# =============================================================================

set -euo pipefail

VERSION="0.8.5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

if [[ ! -f "${LIB_DIR}/nftban_core.sh" ]]; then
    echo "ERROR: Core module not found at ${LIB_DIR}/nftban_core.sh" >&2
    exit 1
fi

source "${LIB_DIR}/nftban_core.sh"

# =============================================================================
# VALIDATION COMMANDS (NEW)
# =============================================================================

cmd_validate() {
    local action="${1:-run}"
    shift || true
    
    local validator_github="${LIB_DIR}/nftban-validator-github.sh"
    local validator_panel="${LIB_DIR}/nftban-validator-panel.sh"
    
    case "$action" in
        run)
            nftban_log_info "Running GitHub-based validation..."
            
            if [[ ! -f "$validator_github" ]]; then
                nftban_log_error "GitHub validator not found: $validator_github"
                return 1
            fi
            
            # shellcheck source=/dev/null
            source "$validator_github"
            github_validate_directory "$LIB_DIR"
            ;;
            
        panel)
            if [[ ! -f "$validator_panel" ]]; then
                nftban_log_error "Validator panel not found: $validator_panel"
                nftban_log_info "Try: nftban validate status"
                return 1
            fi
            bash "$validator_panel"
            ;;
            
        status)
            nftban_log_info "Checking validation status..."
            
            if [[ ! -f "$validator_github" ]]; then
                nftban_log_error "GitHub validator not found: $validator_github"
                return 1
            fi
            
            # shellcheck source=/dev/null
            source "$validator_github"
            
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo "  NFTBan Validation Status"
            echo "═══════════════════════════════════════════════════════"
            echo ""
            
            if github_check_sha256sums_exists; then
                echo "  ✓ GitHub SHA256SUMS.txt: Available"
            else
                echo "  ⚠ GitHub SHA256SUMS.txt: Not found"
                echo ""
                echo "This is normal if:"
                echo "  • First installation"
                echo "  • GitHub Action hasn't run yet"
                echo ""
                return 1
            fi
            
            if ! github_download_sha256sums; then
                echo "  ✗ Failed to download SHA256SUMS.txt"
                echo ""
                return 1
            fi
            
            echo "  ✓ Downloaded SHA256SUMS.txt"
            echo ""
            echo "Module Status:"
            echo "─────────────────────────────────────────────────────"
            
            local total=0 ok=0 fail=0 unknown=0
            
            while IFS= read -r filepath; do
                ((total++))
                local filename
                filename="$(basename "$filepath")"
                
                local result status
                result=$(github_validate_file "$filepath")
                status=$?
                
                case $status in
                    0) 
                        echo "  ✓ $filename"
                        ((ok++))
                        ;;
                    1) 
                        echo "  ✗ $filename (CHECKSUM MISMATCH)"
                        ((fail++))
                        ;;
                    4) 
                        echo "  ? $filename (not tracked)"
                        ((unknown++))
                        ;;
                    *) 
                        echo "  ⚠ $filename (error: $status)"
                        ((fail++))
                        ;;
                esac
            done < <(find "$LIB_DIR" -type f -name "*.sh" 2>/dev/null | sort)
            
            echo ""
            echo "─────────────────────────────────────────────────────"
            echo "Summary: $ok OK, $fail FAILED, $unknown UNKNOWN, $total total"
            echo ""
            
            if [[ $fail -gt 0 ]]; then
                echo "⚠️  VALIDATION ISSUES DETECTED"
                echo ""
                echo "Review details with:"
                echo "  nftban validate run      # Full report"
                echo "  nftban validate panel    # Interactive review"
                echo ""
                return 1
            elif [[ $unknown -gt 0 ]]; then
                echo "ℹ️  Some files are not yet tracked in SHA256SUMS.txt"
                echo "   This is normal for new/modified files"
                echo ""
            else
                echo "✓ All files validated successfully"
                echo ""
            fi
            ;;
            
        update-sums)
            nftban_log_info "Updating SHA256SUMS.txt cache..."
            
            if [[ ! -f "$validator_github" ]]; then
                nftban_log_error "GitHub validator not found: $validator_github"
                return 1
            fi
            
            # shellcheck source=/dev/null
            source "$validator_github"
            
            if github_download_sha256sums; then
                nftban_log_success "SHA256SUMS.txt cache updated"
            else
                nftban_log_error "Failed to update SHA256SUMS.txt"
                return 1
            fi
            ;;
            
        file)
            local filepath="${1:-}"
            
            if [[ -z "$filepath" ]]; then
                nftban_log_error "Usage: nftban validate file <filepath>"
                return 1
            fi
            
            if [[ ! -f "$filepath" ]]; then
                nftban_log_error "File not found: $filepath"
                return 1
            fi
            
            if [[ ! -f "$validator_github" ]]; then
                nftban_log_error "GitHub validator not found: $validator_github"
                return 1
            fi
            
            # shellcheck source=/dev/null
            source "$validator_github"
            
            github_validate_single "$filepath"
            ;;
            
        *)
            nftban_log_error "Unknown validate action: $action"
            echo ""
            echo "Available actions:"
            echo "  run           Full validation report"
            echo "  panel         Interactive TUI panel"
            echo "  status        Quick status check"
            echo "  update-sums   Update SHA256SUMS.txt cache"
            echo "  file <path>   Validate single file"
            echo ""
            return 1
            ;;
    esac
}


# =============================================================================
# FEEDS COMMANDS (NEW)
# =============================================================================

cmd_feeds() {
    local action="${1:-list}"
    shift || true
    
    case "$action" in
        init)
            nftban_check_root || exit 1
            nftban_feeds_init
            ;;
        list)
            nftban_feeds_list
            ;;
        enable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds enable <provider_id>"; exit 1; }
            nftban_feeds_enable_provider "$1"
            ;;
        disable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds disable <provider_id>"; exit 1; }
            nftban_feeds_disable_provider "$1"
            ;;
        update)
            nftban_check_root || exit 1
            nftban_feeds_update "${1:-}"
            ;;
        status)
            nftban_feeds_status
            ;;
        set-interval)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds set-interval <interval>"; exit 1; }
            nftban_feeds_set_interval "$1"
            ;;
        timer-install)
            nftban_check_root || exit 1
            nftban_feeds_timer_install
            ;;
        timer-remove)
            nftban_check_root || exit 1
            nftban_feeds_timer_remove
            ;;
        memory)
            nftban_feeds_memory_status
            ;;
        *)
            nftban_log_error "Unknown feeds action: $action"
            echo ""
            echo "Available actions:"
            echo "  init              Initialize feeds system"
            echo "  list              List feed providers"
            echo "  enable <id>       Enable provider"
            echo "  disable <id>      Disable provider"
            echo "  update [id]       Update feeds (all or specific)"
            echo "  status            Show feeds status"
            echo "  set-interval <i>  Set update interval"
            echo "  timer-install     Install systemd timer"
            echo "  timer-remove      Remove systemd timer"
            echo "  memory            Show memory usage"
            echo ""
            exit 1
            ;;
    esac
}
# =============================================================================
# UPDATE COMMANDS (NEW)
# =============================================================================

cmd_update() {
    local action="${1:-check}"
    shift || true

    case "$action" in
        check)
            nftban_check_root || exit 1
            nftban_update_check "true"
            ;;
        perform|upgrade|install)
            nftban_check_root || exit 1
            nftban_update_perform "false"
            ;;
        auto)
            nftban_check_root || exit 1
            nftban_update_perform "true"  # Skip confirmation
            ;;
        rollback)
            nftban_check_root || exit 1
            nftban_log_warning "Rolling back to previous version..."
            nftban_update_rollback "$1"
            ;;
        version)
            echo "Current version: $(nftban_update_get_local_version)"
            if remote_ver=$(nftban_update_get_remote_version 2>/dev/null); then
                echo "Available version: $remote_ver"
            fi
            ;;
        *)
            nftban_log_error "Unknown update action: $action"
            echo ""
            echo "Available actions:"
            echo "  check             Check for available updates"
            echo "  perform           Perform update (with confirmation)"
            echo "  auto              Perform update (no confirmation)"
            echo "  rollback [DIR]    Rollback to previous version"
            echo "  version           Show current and available versions"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# MAINTENANCE COMMANDS (NEW)
# =============================================================================

cmd_maintenance() {
    local action="${1:-panel}"
    shift || true

    case "$action" in
        panel)
            nftban_maintenance_show_panel
            ;;
        backup)
            nftban_check_root || exit 1
            nftban_update_create_backup
            ;;
        list-backups)
            nftban_log_info "Available backups:"
            find "${NFTBAN_UPDATE_BACKUP_DIR}" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -10
            ;;
        clean)
            nftban_check_root || exit 1
            nftban_maintenance_run
            ;;
        health)
            nftban_maintenance_health_check
            ;;
        *)
            nftban_log_error "Unknown maintenance action: $action"
            echo ""
            echo "Available actions:"
            echo "  panel            Show maintenance panel"
            echo "  backup           Create manual backup"
            echo "  list-backups     List available backups"
            echo "  clean            Run maintenance cleanup"
            echo "  health           Run health check"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# WHITELIST COMMANDS (NEW)
# =============================================================================

cmd_whitelist() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist add <IP> [reason]"; exit 1; }
            nftban_whitelist_add_ip "$1" "${2:-Manual addition}"
            ;;
        remove|delete|del)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist remove <IP>"; exit 1; }
            nftban_whitelist_remove_ip "$1"
            ;;
        list|show)
            nftban_whitelist_list
            ;;
        check)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist check <IP>"; exit 1; }
            if nftban_whitelist_check_ip "$1"; then
                nftban_log_success "IP $1 is whitelisted"
            else
                nftban_log_info "IP $1 is NOT whitelisted"
            fi
            ;;
        sync)
            nftban_check_root || exit 1
            nftban_whitelist_sync_to_nftables
            ;;
        protect-me)
            nftban_check_root || exit 1
            nftban_whitelist_protect_current_user
            ;;
        stats)
            nftban_whitelist_get_stats
            ;;
        verify)
            nftban_whitelist_verify
            ;;
        *)
            nftban_log_error "Unknown whitelist action: $action"
            echo ""
            echo "Available actions:"
            echo "  add <IP> [reason]   Add IP to whitelist"
            echo "  remove <IP>         Remove IP from whitelist"
            echo "  list                Show all whitelisted IPs"
            echo "  check <IP>          Check if IP is whitelisted"
            echo "  sync                Sync whitelist to nftables"
            echo "  protect-me          Add your current IP to whitelist"
            echo "  stats               Show whitelist statistics"
            echo "  verify              Verify whitelist integrity"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# BLACKLIST COMMANDS (NEW)
# =============================================================================

cmd_blacklist() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        ban)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist ban <IP> [timeout] [reason]"; exit 1; }
            nftban_blacklist_ban_ip "$1" "${3:-Manual ban}" "${2:-3600}"
            ;;
        unban)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist unban <IP>"; exit 1; }
            nftban_blacklist_unban_ip "$1"
            ;;
        permanent|perm)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist permanent <IP> [reason]"; exit 1; }
            nftban_blacklist_add_permanent "$1" "${2:-Permanent ban}"
            ;;
        remove-permanent|rmperm)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist remove-permanent <IP>"; exit 1; }
            nftban_blacklist_remove_permanent "$1"
            ;;
        list)
            nftban_blacklist_list_permanent
            ;;
        stats)
            nftban_blacklist_show_recent_stats
            ;;
        top)
            nftban_blacklist_get_top_ips "${1:-10}"
            ;;
        sync)
            nftban_check_root || exit 1
            nftban_blacklist_sync_to_nftables
            ;;
        *)
            nftban_log_error "Unknown blacklist action: $action"
            echo ""
            echo "Available actions:"
            echo "  ban <IP> [timeout] [reason]  Temporarily ban IP"
            echo "  unban <IP>                    Unban IP"
            echo "  permanent <IP> [reason]       Permanently ban IP"
            echo "  remove-permanent <IP>         Remove permanent ban"
            echo "  list                          Show permanent bans"
            echo "  stats                         Show ban statistics"
            echo "  top [N]                       Show top N banned IPs"
            echo "  sync                          Sync blacklist to nftables"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# STATS COMMANDS (NEW)
# =============================================================================

cmd_stats() {
    local action="${1:-dashboard}"
    shift || true

    case "$action" in
        dashboard|show)
            nftban_stats_dashboard
            ;;
        whitelist)
            nftban_stats_whitelist_summary
            ;;
        blacklist)
            nftban_stats_blacklist_summary
            ;;
        bans)
            nftban_stats_ban_activity
            ;;
        geo)
            nftban_stats_geo_summary
            ;;
        cloudflare|cf)
            nftban_stats_cloudflare_summary
            ;;
        nftables|nft)
            nftban_stats_nftables_summary
            ;;
        history)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban stats history <IP>"; exit 1; }
            nftban_stats_ip_history "$1"
            ;;
        top)
            nftban_stats_top_banned "${1:-10}"
            ;;
        recent)
            nftban_stats_recent "${1:-20}"
            ;;
        export)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban stats export <output_file.csv>"; exit 1; }
            nftban_stats_export_csv "$1"
            ;;
        report)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban stats report <output_file>"; exit 1; }
            nftban_stats_generate_report "$1"
            ;;
        *)
            nftban_log_error "Unknown stats action: $action"
            echo ""
            echo "Available actions:"
            echo "  dashboard           Show main dashboard"
            echo "  whitelist           Whitelist summary"
            echo "  blacklist           Blacklist summary"
            echo "  bans                Ban activity"
            echo "  geo                 GEO summary"
            echo "  cloudflare          Cloudflare summary"
            echo "  nftables            nftables summary"
            echo "  history <IP>        IP history"
            echo "  top [N]             Top N banned IPs"
            echo "  recent [N]          Recent N events"
            echo "  export <file.csv>   Export to CSV"
            echo "  report <file>       Generate report"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# PORT COMMANDS (NEW)
# =============================================================================

cmd_port() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban port add <port> <protocol> [comment]"; exit 1; }
            nftban_port_add "$1" "$2" "${3:-Manual addition}"
            ;;
        remove|delete|del)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban port remove <port> <protocol>"; exit 1; }
            nftban_port_remove "$1" "$2"
            ;;
        list|show)
            nftban_port_list
            ;;
        apply)
            nftban_check_root || exit 1
            nftban_port_apply_to_nftables
            ;;
        validate)
            nftban_port_validate_all
            ;;
        *)
            nftban_log_error "Unknown port action: $action"
            echo ""
            echo "Available actions:"
            echo "  add <port> <proto> [comment]  Add port (proto: tcp/udp)"
            echo "  remove <port> <proto>          Remove port"
            echo "  list                           Show all allowed ports"
            echo "  apply                          Apply port config to nftables"
            echo "  validate                       Validate port configuration"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# DDOS PROTECTION COMMANDS (NEW)
# =============================================================================

cmd_ddos() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_ddos_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_ddos_enable_all
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_ddos_disable_all
            ;;
        synflood)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_synflood_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_synflood_disable
                    ;;
                status)
                    nftban_ddos_synflood_status
                    ;;
                *)
                    nftban_log_error "Unknown synflood action: $subaction"
                    echo "Available: enable, disable, status"
                    exit 1
                    ;;
            esac
            ;;
        connlimit)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_connlimit_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_connlimit_disable
                    ;;
                status)
                    nftban_ddos_connlimit_status
                    ;;
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban ddos connlimit add <port> <limit>"; exit 1; }
                    nftban_ddos_connlimit_add_port "$1" "$2"
                    ;;
                *)
                    nftban_log_error "Unknown connlimit action: $subaction"
                    echo "Available: enable, disable, status, add"
                    exit 1
                    ;;
            esac
            ;;
        portflood)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_portflood_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_portflood_disable
                    ;;
                status)
                    nftban_ddos_portflood_status
                    ;;
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban ddos portflood add <port> <rate/time>"; exit 1; }
                    nftban_ddos_portflood_add_port "$1" "$2"
                    ;;
                *)
                    nftban_log_error "Unknown portflood action: $subaction"
                    echo "Available: enable, disable, status, add"
                    exit 1
                    ;;
            esac
            ;;
        icmp)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_icmp_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_icmp_disable
                    ;;
                status)
                    nftban_ddos_icmp_status
                    ;;
                *)
                    nftban_log_error "Unknown icmp action: $subaction"
                    echo "Available: enable, disable, status"
                    exit 1
                    ;;
            esac
            ;;
        *)
            nftban_log_error "Unknown ddos action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                    Show DDoS protection status"
            echo "  enable                    Enable all DDoS protections"
            echo "  disable                   Disable all DDoS protections"
            echo "  synflood <action>         SYN flood protection (enable/disable/status)"
            echo "  connlimit <action>        Connection limit (enable/disable/status/add)"
            echo "  portflood <action>        Port flood protection (enable/disable/status/add)"
            echo "  icmp <action>             ICMP protection (enable/disable/status)"
            echo ""
            echo "Examples:"
            echo "  nftban ddos status"
            echo "  nftban ddos enable"
            echo "  nftban ddos synflood enable"
            echo "  nftban ddos connlimit add 22 5"
            echo "  nftban ddos portflood add 80 20/5"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# PORT SCAN DETECTION COMMANDS (NEW)
# =============================================================================

cmd_portscan() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_portscan_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_portscan_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_portscan_disable
            ;;
        check)
            nftban_check_root || exit 1
            nftban_portscan_check
            ;;
        check-ip)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan check-ip <IP>"; exit 1; }
            nftban_portscan_check_ip_manual "$1"
            ;;
        stats)
            nftban_portscan_stats
            ;;
        cleanup)
            nftban_check_root || exit 1
            nftban_portscan_cleanup
            ;;
        whitelist)
            local subaction="${1:-list}"
            shift || true
            case "$subaction" in
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan whitelist add <IP> [comment]"; exit 1; }
                    nftban_portscan_whitelist_add "$1" "${2:-Manual addition}"
                    ;;
                remove)
                    nftban_check_root || exit 1
                    [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan whitelist remove <IP>"; exit 1; }
                    nftban_portscan_whitelist_remove "$1"
                    ;;
                list)
                    nftban_portscan_whitelist_list
                    ;;
                *)
                    nftban_log_error "Unknown whitelist action: $subaction"
                    echo "Available: add, remove, list"
                    exit 1
                    ;;
            esac
            ;;
        *)
            nftban_log_error "Unknown portscan action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                       Show port scan detection status"
            echo "  enable                       Enable port scan detection"
            echo "  disable                      Disable port scan detection"
            echo "  check                        Check for port scanners now"
            echo "  check-ip <IP>                Check specific IP for scanning"
            echo "  stats                        Show detection statistics"
            echo "  cleanup                      Clean up old tracking data"
            echo "  whitelist add <IP> [comment] Add IP to portscan whitelist"
            echo "  whitelist remove <IP>        Remove IP from whitelist"
            echo "  whitelist list               List whitelisted IPs"
            echo ""
            echo "Examples:"
            echo "  nftban portscan status"
            echo "  nftban portscan enable"
            echo "  nftban portscan check"
            echo "  nftban portscan check-ip 192.168.1.100"
            echo "  nftban portscan whitelist add 192.168.1.1 'Office scanner'"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# EXISTING COMMANDS (UNCHANGED - KEEPING ORIGINAL)
# =============================================================================

cmd_init() {
    nftban_check_root || exit 1
    nftban_log_info "Initializing nftban system v${VERSION}..."
    nftban_init_directories
    nftban_nftables_create_table
    nftban_nftables_apply_rules
    nftban_nftables_init_port_configs
    nftban_whitelist_init
    nftban_blacklist_init
    nftban_search_init
    nftban_whitelist_add_ip "127.0.0.1" "Localhost IPv4"
    nftban_whitelist_add_ip "::1" "Localhost IPv6"
    nftban_log_success "nftban initialized successfully"
}

cmd_status() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         nftban System Status v${VERSION}              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo -e "${NFTBAN_CYAN}System Information:${NFTBAN_NC}"
    echo "  Hostname: $(hostname)"
    echo "  Date: $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""
    
    echo -e "${NFTBAN_CYAN}nftables Status:${NFTBAN_NC}"
    if nftban_nftables_check_table; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Table active"
        nftban_nftables_show_set_stats
    else
        echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Table not found"
    fi
    echo ""
}

cmd_verify() {
    nftban_log_info "Running system verification..."
    echo ""
    
    local errors=0
    
    if nftban_nftables_verify_structure; then
        nftban_log_success "nftables structure: OK"
    else
        nftban_log_error "nftables structure: FAILED"
        ((errors++))
    fi
    
    if nftban_whitelist_verify; then
        nftban_log_success "Whitelist system: OK"
    else
        nftban_log_warning "Whitelist system: Issues detected"
    fi
    
    if nftban_search_verify_index; then
        nftban_log_success "Search index: OK"
    else
        nftban_log_warning "Search index: Needs rebuild"
    fi
    
    echo ""
    if [[ $errors -eq 0 ]]; then
        nftban_log_success "Verification passed"
    else
        nftban_log_error "Verification failed with $errors error(s)"
    fi
    
    return $errors
}

# =============================================================================
# TESTING & DIAGNOSTICS COMMANDS (NEW)
# =============================================================================

cmd_test() {
    local action="${1:-quick}"
    shift || true

    case "$action" in
        quick)
            nftban_smoketest_run "quick"
            ;;
        full)
            nftban_smoketest_run "full"
            ;;
        category)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban test category <category_name>"; exit 1; }
            nftban_smoketest_run "category" "$1"
            ;;
        help)
            nftban_smoketest_show_help
            ;;
        *)
            nftban_log_error "Unknown test action: $action"
            echo ""
            echo "Available actions:"
            echo "  quick                   Quick smoke test (essential checks)"
            echo "  full                    Comprehensive smoke test (all categories)"
            echo "  category <name>         Test specific category"
            echo "  help                    Show detailed help"
            echo ""
            echo "Categories:"
            echo "  installation, nftables, modules, deps, cli,"
            echo "  safety, config, logging, network"
            echo ""
            echo "Examples:"
            echo "  nftban test quick"
            echo "  nftban test full"
            echo "  nftban test category nftables"
            echo ""
            exit 1
            ;;
    esac
}

cmd_diagnostics() {
    local action="${1:-collect}"
    shift || true

    case "$action" in
        collect|generate)
            local output_file="${1:-/tmp/nftban_diagnostics_$(date +%Y%m%d_%H%M%S).txt}"
            nftban_diagnostics_collect "$output_file"
            ;;
        help)
            cat <<'EOF'

nftban diagnostics - Collect system diagnostics for support

USAGE:
    nftban diagnostics [collect] [output_file]

DESCRIPTION:
    Collects comprehensive system information including:
    - Version information
    - nftables ruleset and sets
    - Configuration files
    - Recent logs
    - Fail2Ban status
    - System services status
    - Disk usage

EXAMPLES:
    nftban diagnostics                              # Default output
    nftban diagnostics collect /tmp/my_diag.txt     # Custom output file

The generated file can be shared for support purposes.

EOF
            ;;
        *)
            nftban_log_error "Unknown diagnostics action: $action"
            echo "Available actions: collect, help"
            exit 1
            ;;
    esac
}

# =============================================================================
# HELP SYSTEM
# =============================================================================

show_usage() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║           nftban v0.8.5 - Modular System              ║
╚═══════════════════════════════════════════════════════╝

USAGE:
    nftban <command> [options]

SYSTEM MANAGEMENT:
    init                    Initialize nftban system
    status                  Show system status
    verify                  Verify system health
    version                 Show version information

IP MANAGEMENT:
    whitelist add <IP>      Add IP to whitelist
    whitelist remove <IP>   Remove IP from whitelist
    whitelist list          Show all whitelisted IPs
    whitelist protect-me    Whitelist your current IP

    blacklist ban <IP>      Temporarily ban IP
    blacklist unban <IP>    Unban IP
    blacklist permanent <IP> Permanently ban IP
    blacklist list          Show permanent bans

    ban <IP> [timeout]      Quick ban (alias for blacklist ban)
    unban <IP>              Quick unban (alias for blacklist unban)

STATISTICS & MONITORING:
    stats                   Show main dashboard
    stats whitelist         Whitelist statistics
    stats blacklist         Blacklist statistics
    stats top [N]           Top N banned IPs
    stats recent [N]        Recent N events
    stats export <file>     Export to CSV

PORT MANAGEMENT:
    port add <port> <proto> Add allowed port (tcp/udp)
    port remove <port> <proto> Remove port
    port list               Show all allowed ports
    port apply              Apply port config to nftables

DDOS PROTECTION:
    ddos status             Show DDoS protection status
    ddos enable             Enable all DDoS protections
    ddos disable            Disable all DDoS protections
    ddos synflood <action>  SYN flood protection
    ddos connlimit <action> Connection limits
    ddos portflood <action> Port flood protection
    ddos icmp <action>      ICMP protection

PORT SCAN DETECTION:
    portscan status         Show port scan detection status
    portscan enable         Enable port scan detection
    portscan disable        Disable port scan detection
    portscan check          Check for port scanners now
    portscan stats          Show detection statistics

UPDATE & MAINTENANCE:
    update check            Check for available updates
    update perform          Perform system update
    update rollback         Rollback to previous version
    maintenance panel       Show maintenance panel
    maintenance backup      Create system backup
    maintenance health      Run health check

TESTING & DIAGNOSTICS:
    test quick              Quick smoke test (essential checks)
    test full               Comprehensive smoke test (all categories)
    test category <name>    Test specific category
    diagnostics             Collect full diagnostics report

VALIDATION:
    validate run            Run full validation report
    validate panel          Interactive validation TUI
    validate status         Quick validation status
    validate update-sums    Update SHA256SUMS.txt cache
    validate file <PATH>    Validate single file
	
FEEDS MANAGEMENT:
    feeds init              Initialize feeds system
    feeds list              List feed providers
    feeds enable <ID>       Enable provider
    feeds disable <ID>      Disable provider
    feeds update [ID]       Update feeds
    feeds status            Show feeds status
    feeds set-interval <T>  Set update interval
    feeds timer-install     Install systemd timer
    feeds timer-remove      Remove systemd timer
    feeds memory            Show memory usage

EXAMPLES (FEEDS):
    sudo nftban feeds init
    nftban feeds list
    sudo nftban feeds enable spamhaus
    sudo nftban feeds update
    sudo nftban feeds timer-install

EXAMPLES:
    # Initialize system
    sudo nftban init
    
    # Check status
    nftban status
    
    # Validate installation
    nftban validate status
    sudo nftban validate run
    sudo nftban validate panel
    
    # Validate specific file
    sudo nftban validate file /etc/nftban/lib/nftban_core.sh

For full command list, run: nftban help

EOF
}

# =============================================================================
# MAIN COMMAND ROUTER
# =============================================================================

main() {
    local command="${1:-}"
    
    if [[ -z "$command" ]]; then
        show_usage
        exit 0
    fi
    
    shift || true
    
    case "$command" in
        init) cmd_init "$@" ;;
        status) cmd_status "$@" ;;
        verify) cmd_verify "$@" ;;
        validate|validator) cmd_validate "$@" ;;

        # Update & Maintenance
        update) cmd_update "$@" ;;
        maintenance|maint) cmd_maintenance "$@" ;;

        # IP Management
        whitelist|wl) cmd_whitelist "$@" ;;
        blacklist|bl) cmd_blacklist "$@" ;;
        ban) cmd_blacklist ban "$@" ;;
        unban) cmd_blacklist unban "$@" ;;

        # Statistics & Monitoring
        stats) cmd_stats "$@" ;;

        # Port Management
        port|ports) cmd_port "$@" ;;

        # DDoS Protection
        ddos) cmd_ddos "$@" ;;

        # Port Scan Detection
        portscan) cmd_portscan "$@" ;;

		# Feeds Management
        feeds) cmd_feeds "$@" ;;

        # Testing & Diagnostics
        test|smoke-test|smoketest) cmd_test "$@" ;;
        diagnostics|diag|debug) cmd_diagnostics "$@" ;;

        version|--version|-v)
            echo "nftban version $VERSION"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            nftban_log_error "Unknown command: $command"
            echo "Run 'nftban help' to see available commands"
            exit 1
            ;;
    esac
}

main "$@"
