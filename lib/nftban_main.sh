#!/usr/bin/env bash

# =============================================================================
# NFTBan - Unified CLI Interface
# Version: 6.0.0 (Modular Architecture)
# Author: ITCMS Team (Antonios Voulvoulis)
#
# Description:
#   Unified command-line interface for nftban ban management system.
#   All functionality accessible through a single 'nftban' command.
#
# Architecture:
#   - Core module: Foundation (logging, config, validation)
#   - Specialized modules: Cloudflare, GEO, Stats, Search
#   - Main CLI: This file (command routing and user interaction)
# =============================================================================

set -euo pipefail

# =============================================================================
# INITIALIZATION
# =============================================================================
VERSION="6.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# Load core module (which auto-loads other modules)
if [[ ! -f "${LIB_DIR}/nftban-core.sh" ]]; then
    echo "ERROR: Core module not found at ${LIB_DIR}/nftban-core.sh" >&2
    exit 1
fi

source "${LIB_DIR}/nftban-core.sh"

# =============================================================================
# COMMAND IMPLEMENTATIONS
# =============================================================================

# System Management Commands
cmd_init() {
    nftban_check_root || exit 1
    
    nftban_log_info "Initializing nftban system v${VERSION}..."
    
    # Initialize directories
    nftban_init_directories
    
    # TODO: Call nftables initialization
    # This would come from nftban-nftables.sh module
    
    nftban_log_success "nftban initialized successfully"
}

cmd_status() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         nftban System Status v${VERSION}           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    # System info
    echo -e "${NFTBAN_CYAN}System Information:${NFTBAN_NC}"
    echo "  Hostname: $(hostname)"
    echo "  Date: $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Check nftables
    echo -e "${NFTBAN_CYAN}nftables Status:${NFTBAN_NC}"
    if nftban_check_nftables_table; then
        echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Table active"
    else
        echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Table not found (run: nftban init)"
    fi
    echo ""
    
    # Module status
    echo -e "${NFTBAN_CYAN}Loaded Modules:${NFTBAN_NC}"
    [[ -n "${NFTBAN_SEARCH_LOADED:-}" ]] && echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Search" || echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Search"
    [[ -n "${NFTBAN_CLOUDFLARE_LOADED:-}" ]] && echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Cloudflare" || echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Cloudflare"
    [[ -n "${NFTBAN_GEO_LOADED:-}" ]] && echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} GEO" || echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} GEO"
    [[ -n "${NFTBAN_STATS_LOADED:-}" ]] && echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} Stats" || echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} Stats"
    echo ""
}

# Cloudflare Commands
cmd_cloudflare() {
    local action="${1:-status}"
    
    case "$action" in
        enable)
            nftban_check_root || exit 1
            nftban_cloudflare_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_cloudflare_disable
            ;;
        update)
            nftban_check_root || exit 1
            nftban_cloudflare_download_ips
            ;;
        status)
            nftban_cloudflare_status
            ;;
        *)
            nftban_log_error "Unknown Cloudflare action: $action"
            echo ""
            echo "Available actions: enable, disable, update, status"
            exit 1
            ;;
    esac
}

# GEO Commands
cmd_geo() {
    local action="${1:-list}"
    
    case "$action" in
        init)
            nftban_check_root || exit 1
            nftban_geo_init
            ;;
        block)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban geo block <COUNTRY_CODE> [IP_VERSION]"; exit 1; }
            nftban_geo_block_country "$2" "${3:-both}"
            ;;
        unblock)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban geo unblock <COUNTRY_CODE> [IP_VERSION]"; exit 1; }
            nftban_geo_unblock_country "$2" "${3:-both}"
            ;;
        list)
            nftban_geo_list_blocked
            ;;
        sync)
            nftban_check_root || exit 1
            nftban_geo_sync_blacklist
            ;;
        update)
            nftban_check_root || exit 1
            nftban_geo_update_database "${2:-ALL}"
            ;;
        *)
            nftban_log_error "Unknown GEO action: $action"
            echo ""
            echo "Available actions: init, block, unblock, list, sync, update"
            exit 1
            ;;
    esac
}

# Stats Commands
cmd_stats() {
    local action="${1:-dashboard}"
    
    case "$action" in
        dashboard)
            nftban_stats_dashboard
            ;;
        ip)
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban stats ip <IP_ADDRESS>"; exit 1; }
            nftban_stats_ip_history "$2"
            ;;
        top)
            nftban_stats_top_banned "${2:-10}"
            ;;
        recent)
            nftban_stats_recent "${2:-20}"
            ;;
        export)
            nftban_stats_export_csv "${2:-}"
            ;;
        report)
            nftban_stats_generate_report "${2:-}"
            ;;
        monitor)
            nftban_stats_monitor
            ;;
        *)
            nftban_log_error "Unknown stats action: $action"
            echo ""
            echo "Available actions: dashboard, ip, top, recent, export, report, monitor"
            exit 1
            ;;
    esac
}

# Search Commands
cmd_search() {
    [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban search <IP_ADDRESS>"; exit 1; }
    
    local ip="$1"
    
    nftban_validate_ip "$ip" || exit 1
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  IP Search Results: $ip"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Detailed search with all information
    nftban_search_get_details "$ip"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# =============================================================================
# HELP SYSTEM
# =============================================================================

show_usage() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║           nftban v6.0.0 - Modular System              ║
║           ONE COMMAND FOR EVERYTHING                  ║
╚═══════════════════════════════════════════════════════╝

USAGE:
    nftban <command> [options]

SYSTEM MANAGEMENT:
    init                    Initialize nftban system
    status                  Show system status
    version                 Show version information

CLOUDFLARE:
    cf enable               Enable Cloudflare whitelist
    cf disable              Disable Cloudflare whitelist
    cf update               Download latest CF IP ranges
    cf status               Show CF integration status

GEO BLOCKING:
    geo init                Initialize GEO system
    geo block <CC> [IPV]    Block country (e.g., CN, RU)
    geo unblock <CC> [IPV]  Unblock country
    geo list                List blocked countries
    geo sync                Sync GEO blacklist
    geo update [CC]         Update GEO database

STATISTICS:
    stats                   Show statistics dashboard
    stats ip <IP>           Show IP ban history
    stats top [N]           Show top N banned IPs
    stats recent [N]        Show recent N activities
    stats export [FILE]     Export to CSV
    stats report [FILE]     Generate report
    stats monitor           Real-time monitoring

SEARCH:
    search <IP>             Search IP in all locations

EXAMPLES:
    # Initialize system
    sudo nftban init
    
    # Enable Cloudflare
    sudo nftban cf enable
    sudo nftban cf update
    
    # Block country
    sudo nftban geo init
    sudo nftban geo block CN
    
    # View statistics
    nftban stats
    nftban stats top 20
    nftban search 192.0.2.1

ARCHITECTURE:
    Core Module         - Foundation (logging, config, validation)
    Cloudflare Module   - CF IP range management
    GEO Module          - Country-level blocking
    Stats Module        - Reporting and analytics
    Search Module       - Consolidated IP search

For detailed help:
    nftban help <command>

EOF
}

# =============================================================================
# MAIN COMMAND ROUTER
# =============================================================================

main() {
    local command="${1:-}"
    
    # Show usage if no command
    if [[ -z "$command" ]]; then
        show_usage
        exit 0
    fi
    
    shift || true
    
    # Route to appropriate function
    case "$command" in
        # System
        init) cmd_init "$@" ;;
        status) cmd_status "$@" ;;
        version|--version|-v)
            echo "nftban version $VERSION (Modular Architecture)"
            echo "Loaded modules:"
            echo "  - Core: ${NFTBAN_CORE_LOADED:-not loaded}"
            echo "  - Search: ${NFTBAN_SEARCH_LOADED:-not loaded}"
            echo "  - Cloudflare: ${NFTBAN_CLOUDFLARE_LOADED:-not loaded}"
            echo "  - GEO: ${NFTBAN_GEO_LOADED:-not loaded}"
            echo "  - Stats: ${NFTBAN_STATS_LOADED:-not loaded}"
            ;;
        
        # Cloudflare
        cf|cloudflare) cmd_cloudflare "$@" ;;
        
        # GEO
        geo) cmd_geo "$@" ;;
        
        # Stats
        stats|statistics) cmd_stats "$@" ;;
        
        # Search
        search) cmd_search "$@" ;;
        
        # Help
        help|--help|-h)
            show_usage
            ;;
        
        # Unknown
        *)
            nftban_log_error "Unknown command: $command"
            echo ""
            echo "Run 'nftban help' to see available commands"
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
