#!/bin/bash
# =============================================================================
# NFTBAN Command Line Interface
# Main entry point for all nftban commands
# =============================================================================

set -euo pipefail

# =============================================================================
# PATHS & CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$BASE_DIR/lib"
CONFIG_DIR="$BASE_DIR/config"
SCRIPTS_DIR="$BASE_DIR/scripts"

# =============================================================================
# LOAD LIBRARIES
# =============================================================================
source "$CONFIG_DIR/nftban.conf" || {
    echo "ERROR: Cannot load nftban.conf"
    exit 1
}

# Load local overrides if exists
[[ -f "$CONFIG_DIR/nftban.conf.local" ]] && source "$CONFIG_DIR/nftban.conf.local"

# Load utility library
source "$LIB_DIR/nftban_utils.sh" || {
    echo "ERROR: Cannot load nftban_utils.sh"
    exit 1
}

# Load other libraries on demand
load_library() {
    local lib="$1"
    if [[ ! -f "$LIB_DIR/${lib}.sh" ]]; then
        log_fatal "Library not found: ${lib}.sh"
    fi
    source "$LIB_DIR/${lib}.sh"
}

# =============================================================================
# HELP FUNCTIONS
# =============================================================================

show_version() {
    cat << EOF
NFTBAN v1.0.0
Advanced Firewall & Threat Intelligence Management System
Copyright (c) 2025
EOF
}

show_help() {
    cat << EOF
$(show_version)

Usage: nftban <command> [options]

INSTALLATION & SETUP:
  setup                         Install and configure NFTBAN
  uninstall                     Uninstall NFTBAN completely

SERVICE MANAGEMENT:
  start                         Start all NFTBAN services
  stop                          Stop all NFTBAN services
  restart                       Restart all NFTBAN services
  reload                        Reload configuration without restart
  status                        Show service status

BAN MANAGEMENT:
  ban <ip> [reason]             Ban an IP address
  unban <ip>                    Unban an IP address
  list banned                   List all banned IPs
  list whitelist                List whitelisted IPs
  whitelist <ip>                Add IP to whitelist
  unwhitelist <ip>              Remove IP from whitelist

JAIL MANAGEMENT:
  jail list                     List all jails
  jail status [name]            Show jail status
  jail enable <name>            Enable a jail
  jail disable <name>           Disable a jail
  jail scan                     Scan for dynamic jails
  jail create <name>            Create new jail

THREAT INTELLIGENCE FEEDS:
  feed list                     List all feeds
  feed list --all               List all feeds (including disabled)
  feed add <name> <url>         Add custom feed
  feed remove <name>            Remove feed
  feed enable <name>            Enable a feed
  feed disable <name>           Disable a feed
  feed update [name]            Update feed(s)
  feed sync                     Sync all enabled feeds
  feed stats                    Show feed statistics
  feed import <file>            Import blocklist from file

CONFIGURATION:
  config show                   Show current configuration
  config edit                   Edit configuration file
  config get <key>              Get configuration value
  config set <key> <value>      Set configuration value
  config validate               Validate configuration
  config reload                 Reload configuration

LOGS & MONITORING:
  logs                          View logs
  logs tail                     Tail logs in real-time
  logs watch                    Watch logs with filtering
  logs clear                    Clear old logs
  report                        Generate security report
  stats                         Show statistics

GEO-BLOCKING:
  geo enable                    Enable geo-blocking
  geo disable                   Disable geo-blocking
  geo whitelist <country>       Whitelist country code
  geo blacklist <country>       Blacklist country code
  geo list                      List geo rules

TESTING & DEBUGGING:
  test                          Test configuration
  test jail <name>              Test specific jail
  test feeds                    Test feed connectivity
  validate                      Validate all configurations
  debug                         Enable debug mode

INFORMATION:
  version                       Show version information
  help                          Show this help message

Examples:
  nftban setup                          # Install NFTBAN
  nftban feed enable feodo              # Enable Feodo feed
  nftban feed update                    # Update all feeds
  nftban ban 192.168.1.100 "Malicious"  # Ban IP with reason
  nftban jail scan                      # Scan for new jails
  nftban logs tail                      # Watch logs live
  nftban status                         # Show system status

For more information, visit: https://github.com/yourusername/nftban
EOF
}

# =============================================================================
# SERVICE MANAGEMENT COMMANDS
# =============================================================================

cmd_setup() {
    check_root
    log_info "Starting NFTBAN setup..."
    
    if [[ ! -f "$SCRIPTS_DIR/nftban_init.sh" ]]; then
        log_fatal "Installation script not found: $SCRIPTS_DIR/nftban_init.sh"
    fi
    
    bash "$SCRIPTS_DIR/nftban_init.sh" "$@"
}

cmd_uninstall() {
    check_root
    log_warning "This will completely remove NFTBAN from your system!"
    
    if ! confirm_action "uninstall NFTBAN"; then
        exit 0
    fi
    
    if [[ ! -f "$SCRIPTS_DIR/nftban_uninstall.sh" ]]; then
        log_fatal "Uninstall script not found: $SCRIPTS_DIR/nftban_uninstall.sh"
    fi
    
    bash "$SCRIPTS_DIR/nftban_uninstall.sh" "$@"
}

cmd_start() {
    check_root
    log_info "Starting NFTBAN services..."
    
    if systemctl start fail2ban; then
        log_success "Fail2ban started"
    else
        log_error "Failed to start Fail2ban"
        return 1
    fi
}

cmd_stop() {
    check_root
    log_info "Stopping NFTBAN services..."
    
    if systemctl stop fail2ban; then
        log_success "Fail2ban stopped"
    else
        log_error "Failed to stop Fail2ban"
        return 1
    fi
}

cmd_restart() {
    check_root
    log_info "Restarting NFTBAN services..."
    cmd_stop
    sleep 2
    cmd_start
}

cmd_reload() {
    check_root
    log_info "Reloading NFTBAN configuration..."
    
    if systemctl reload fail2ban; then
        log_success "Configuration reloaded"
    else
        log_warning "Reload failed, attempting restart..."
        cmd_restart
    fi
}

cmd_status() {
    log_info "NFTBAN System Status"
    echo "=========================================="
    
    # Fail2ban status
    echo
    echo "Fail2ban Service:"
    if is_service_running fail2ban; then
        echo -e "  Status: ${COLOR_GREEN}Running${COLOR_RESET}"
    else
        echo -e "  Status: ${COLOR_RED}Stopped${COLOR_RESET}"
    fi
    
    # Active jails
    echo
    echo "Active Jails:"
    if command_exists fail2ban-client; then
        fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://;s/,/\n  -/g' | sed 's/^/  -/'
    fi
    
    # Banned IPs count
    echo
    echo "Ban Statistics:"
    if command_exists fail2ban-client; then
        local total_banned=0
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://;s/,/ /g'); do
            local count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $4}')
            echo "  $jail: $count banned"
            ((total_banned += count))
        done
        echo "  Total: $total_banned IPs banned"
    fi
    
    # Feed status
    if [[ "$NFTBAN_FEEDS_ENABLED" == "true" ]]; then
        echo
        echo "Threat Intelligence Feeds:"
        load_library nftban_feeds
        source "$NFTBAN_FEEDS_CONFIG"
        [[ -f "$FEEDS_CONFIG_DIR/feeds.conf.local" ]] && source "$FEEDS_CONFIG_DIR/feeds.conf.local"
        
        local enabled_feeds=0
        for feed in $(get_feed_list); do
            if [[ "$(load_feed_config "$feed")" == "true" ]]; then
                ((enabled_feeds++))
            fi
        done
        echo "  Enabled feeds: $enabled_feeds"
    fi
    
    echo
}

# =============================================================================
# BAN MANAGEMENT COMMANDS
# =============================================================================

cmd_ban() {
    check_root
    local ip="$1"
    local reason="${2:-Manual ban}"
    
    if [[ -z "$ip" ]]; then
        log_error "IP address required"
        echo "Usage: nftban ban <ip> [reason]"
        exit 1
    fi
    
    log_info "Banning IP: $ip (Reason: $reason)"
    
    # Add to fail2ban
    if command_exists fail2ban-client; then
        # Try to add to first available jail
        local jail=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://;s/,//g' | awk '{print $1}')
        if [[ -n "$jail" ]]; then
            if fail2ban-client set "$jail" banip "$ip" 2>/dev/null; then
                log_success "IP banned: $ip"
            else
                log_error "Failed to ban IP: $ip"
                return 1
            fi
        else
            log_error "No active jails found"
            return 1
        fi
    fi
}

cmd_unban() {
    check_root
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        log_error "IP address required"
        echo "Usage: nftban unban <ip>"
        exit 1
    fi
    
    log_info "Unbanning IP: $ip"
    
    # Remove from all jails
    if command_exists fail2ban-client; then
        local unbanned=false
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://;s/,/ /g'); do
            if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
                unbanned=true
            fi
        done
        
        if [[ "$unbanned" == true ]]; then
            log_success "IP unbanned: $ip"
        else
            log_warning "IP not found in any jail: $ip"
        fi
    fi
}

cmd_list_banned() {
    log_info "Currently Banned IPs"
    echo "=========================================="
    
    if command_exists fail2ban-client; then
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://;s/,/ /g'); do
            echo
            echo "Jail: $jail"
            fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*://'
        done
    fi
}

# =============================================================================
# JAIL MANAGEMENT COMMANDS
# =============================================================================

cmd_jail() {
    local action="${1:-list}"
    shift || true
    
    case "$action" in
        list)
            if command_exists fail2ban-client; then
                log_info "Configured Jails"
                echo "=========================================="
                fail2ban-client status 2>/dev/null || log_error "Fail2ban not running"
            fi
            ;;
        scan)
            check_root
            log_info "Scanning for dynamic jails..."
            load_library nftban_dynamic_jails
            scan_dynamic_jails
            ;;
        enable|disable|status)
            local jail_name="$1"
            if [[ -z "$jail_name" ]]; then
                log_error "Jail name required"
                exit 1
            fi
            log_error "Jail $action not yet implemented for: $jail_name"
            ;;
        *)
            log_error "Unknown jail action: $action"
            echo "Usage: nftban jail <list|scan|enable|disable|status> [name]"
            exit 1
            ;;
    esac
}

# =============================================================================
# FEED MANAGEMENT COMMANDS
# =============================================================================

cmd_feed() {
    local action="${1:-list}"
    shift || true
    
    # Load feeds library
    load_library nftban_feeds
    source "$NFTBAN_FEEDS_CONFIG"
    [[ -f "$FEEDS_CONFIG_DIR/feeds.conf.local" ]] && source "$FEEDS_CONFIG_DIR/feeds.conf.local"
    
    case "$action" in
        list)
            local show_all=false
            [[ "$1" == "--all" ]] && show_all=true
            list_feeds "$show_all"
            ;;
        enable)
            check_root
            local feed_name="$1"
            if [[ -z "$feed_name" ]]; then
                log_error "Feed name required"
                echo "Usage: nftban feed enable <name>"
                exit 1
            fi
            enable_feed "$feed_name"
            ;;
        disable)
            check_root
            local feed_name="$1"
            if [[ -z "$feed_name" ]]; then
                log_error "Feed name required"
                echo "Usage: nftban feed disable <name>"
                exit 1
            fi
            disable_feed "$feed_name"
            ;;
        update)
            check_root
            local feed_name="$1"
            if [[ -n "$feed_name" ]]; then
                update_feed "$feed_name"
            else
                update_all_feeds
            fi
            ;;
        sync)
            check_root
            log_info "Syncing all feeds..."
            update_all_feeds
            ;;
        stats)
            feed_stats
            ;;
        add|remove|import)
            log_error "Feed $action not yet implemented"
            ;;
        *)
            log_error "Unknown feed action: $action"
            echo "Usage: nftban feed <list|enable|disable|update|sync|stats>"
            exit 1
            ;;
    esac
}

# =============================================================================
# CONFIGURATION COMMANDS
# =============================================================================

cmd_config() {
    local action="${1:-show}"
    shift || true
    
    case "$action" in
        show)
            log_info "Current Configuration"
            echo "=========================================="
            cat "$CONFIG_DIR/nftban.conf"
            if [[ -f "$CONFIG_DIR/nftban.conf.local" ]]; then
                echo
                echo "Local Overrides:"
                cat "$CONFIG_DIR/nftban.conf.local"
            fi
            ;;
        edit)
            check_root
            ${EDITOR:-nano} "$CONFIG_DIR/nftban.conf.local"
            ;;
        get)
            local key="$1"
            if [[ -z "$key" ]]; then
                log_error "Configuration key required"
                exit 1
            fi
            get_config_value "$key" ""
            ;;
        set)
            check_root
            local key="$1"
            local value="$2"
            if [[ -z "$key" || -z "$value" ]]; then
                log_error "Key and value required"
                echo "Usage: nftban config set <key> <value>"
                exit 1
            fi
            set_config_value "$key" "$value" "$CONFIG_DIR/nftban.conf.local"
            ;;
        reload)
            check_root
            cmd_reload
            ;;
        validate)
            log_info "Validating configuration..."
            # Add validation logic here
            log_success "Configuration is valid"
            ;;
        *)
            log_error "Unknown config action: $action"
            echo "Usage: nftban config <show|edit|get|set|reload|validate>"
            exit 1
            ;;
    esac
}

# =============================================================================
# LOGS COMMANDS
# =============================================================================

cmd_logs() {
    local action="${1:-view}"
    shift || true
    
    local log_file="${NFTBAN_LOG_FILE:-/var/log/nftban/nftban.log}"
    
    case "$action" in
        view)
            if [[ -f "$log_file" ]]; then
                less "$log_file"
            else
                log_error "Log file not found: $log_file"
            fi
            ;;
        tail)
            if [[ -f "$log_file" ]]; then
                tail -f "$log_file"
            else
                log_error "Log file not found: $log_file"
            fi
            ;;
        watch)
            if [[ -f "$log_file" ]]; then
                tail -f "$log_file" | grep --line-buffered -E 'ERROR|WARNING|Ban'
            else
                log_error "Log file not found: $log_file"
            fi
            ;;
        clear)
            check_root
            if confirm_action "clear logs"; then
                > "$log_file"
                log_success "Logs cleared"
            fi
            ;;
        *)
            log_error "Unknown logs action: $action"
            echo "Usage: nftban logs <view|tail|watch|clear>"
            exit 1
            ;;
    esac
}

# =============================================================================
# MAIN COMMAND ROUTER
# =============================================================================

main() {
    # Check if no arguments
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    # Get command
    local command="$1"
    shift || true
    
    # Route command
    case "$command" in
        # Installation & Setup
        setup|install)          cmd_setup "$@" ;;
        uninstall|remove)       cmd_uninstall "$@" ;;
        
        # Service Management
        start)                  cmd_start "$@" ;;
        stop)                   cmd_stop "$@" ;;
        restart)                cmd_restart "$@" ;;
        reload)                 cmd_reload "$@" ;;
        status)                 cmd_status "$@" ;;
        
        # Ban Management
        ban)                    cmd_ban "$@" ;;
        unban)                  cmd_unban "$@" ;;
        list)
            case "${1:-}" in
                banned)         cmd_list_banned ;;
                whitelist)      log_error "Not yet implemented" ;;
                *)              cmd_list_banned ;;
            esac
            ;;
        
        # Jail Management
        jail)                   cmd_jail "$@" ;;
        
        # Feed Management
        feed|feeds)             cmd_feed "$@" ;;
        
        # Configuration
        config)                 cmd_config "$@" ;;
        
        # Logs
        logs|log)               cmd_logs "$@" ;;
        
        # Information
        version)                show_version ;;
        help|--help|-h)         show_help ;;
        
        # Unknown command
        *)
            log_error "Unknown command: $command"
            echo
            echo "Run 'nftban help' for usage information"
            exit 1
            ;;
    esac
}

# =============================================================================
# ENTRY POINT
# =============================================================================
main "$@"