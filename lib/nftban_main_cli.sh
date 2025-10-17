#!/usr/bin/env bash

# =============================================================================
# NFTBan - Unified CLI Interface (WITH VALIDATION)
# Version: 7.0.1
# Author: ITCMS Team (Antonios Voulvoulis)
# =============================================================================

set -euo pipefail

VERSION="7.0.1"
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
# HELP SYSTEM
# =============================================================================

show_usage() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║           nftban v7.0.1 - Modular System              ║
╚═══════════════════════════════════════════════════════╝

USAGE:
    nftban <command> [options]

SYSTEM MANAGEMENT:
    init                    Initialize nftban system
    status                  Show system status
    verify                  Verify system health
    version                 Show version information

UPDATE & MAINTENANCE:
    update check            Check for available updates
    update perform          Perform system update
    update rollback         Rollback to previous version
    maintenance panel       Show maintenance panel
    maintenance backup      Create system backup
    maintenance health      Run health check

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

		# Feeds Management
        feeds)
            cmd_feeds "$@"
            ;;
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
