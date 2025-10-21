#!/usr/bin/env bash

# =============================================================================
# NFTBan Log Collection Script for Lab Servers
# Version: 0.9.2
# Location: scripts/collect_logs_for_analysis.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Description: Collects all nftban logs for stability and security analysis
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.9.2"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly HOSTNAME="$(hostname -s)"
readonly OUTPUT_DIR="/tmp/nftban-logs-${HOSTNAME}-${TIMESTAMP}"
readonly ARCHIVE_NAME="nftban-logs-${HOSTNAME}-${TIMESTAMP}.tar.gz"

# ANSI Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# =============================================================================
# LOG LOCATIONS
# =============================================================================
readonly NFTBAN_LOG_DIR="/var/log/nftban"
readonly NFTBAN_CONFIG_DIR="/etc/nftban/config"
readonly NFTBAN_DATA_DIR="/etc/nftban/data"
readonly SYSTEMD_JOURNAL="nftban"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  NFTBan Log Collection Script v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_nftban_installed() {
    if [[ ! -d "$NFTBAN_CONFIG_DIR" ]]; then
        log_error "NFTBan not found at $NFTBAN_CONFIG_DIR"
        exit 1
    fi
    log_success "NFTBan installation detected"
}

# =============================================================================
# LOG COLLECTION FUNCTIONS
# =============================================================================

collect_system_info() {
    log_info "Collecting system information..."

    local info_file="$OUTPUT_DIR/00_system_info.txt"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "NFTBan Log Collection - System Information"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "Collection Date: $(date)"
        echo "Hostname: $(hostname -f)"
        echo "Server: $HOSTNAME"
        echo "Kernel: $(uname -r)"
        echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
        echo "Uptime: $(uptime -p)"
        echo ""
        echo "───────────────────────────────────────────────────────────"
        echo "NFTBan Version"
        echo "───────────────────────────────────────────────────────────"
        if [[ -f /etc/nftban/.version ]]; then
            cat /etc/nftban/.version
        else
            echo "Version file not found"
        fi
        echo ""
        echo "───────────────────────────────────────────────────────────"
        echo "Network Interfaces"
        echo "───────────────────────────────────────────────────────────"
        ip -br addr
        echo ""
        echo "───────────────────────────────────────────────────────────"
        echo "Disk Usage"
        echo "───────────────────────────────────────────────────────────"
        df -h | grep -E '^/dev/|Filesystem'
        echo ""
        echo "───────────────────────────────────────────────────────────"
        echo "Memory Usage"
        echo "───────────────────────────────────────────────────────────"
        free -h
        echo ""
    } > "$info_file"

    log_success "System information collected"
}

collect_nftban_logs() {
    log_info "Collecting NFTBan log files..."

    if [[ -d "$NFTBAN_LOG_DIR" ]]; then
        cp -a "$NFTBAN_LOG_DIR" "$OUTPUT_DIR/logs/" 2>/dev/null || true

        # Count log files
        local log_count=$(find "$OUTPUT_DIR/logs/" -type f 2>/dev/null | wc -l)
        log_success "Collected $log_count log files from $NFTBAN_LOG_DIR"
    else
        log_warning "Log directory not found: $NFTBAN_LOG_DIR"
    fi
}

collect_configuration() {
    log_info "Collecting configuration files..."

    mkdir -p "$OUTPUT_DIR/config"

    # Main config
    if [[ -f "$NFTBAN_CONFIG_DIR/nftban.conf" ]]; then
        cp "$NFTBAN_CONFIG_DIR/nftban.conf" "$OUTPUT_DIR/config/" 2>/dev/null || true
        log_success "Collected: nftban.conf"
    fi

    # Local config (may contain sensitive info - sanitized copy)
    if [[ -f "$NFTBAN_CONFIG_DIR/nftban.conf.local" ]]; then
        # Redact sensitive info
        sed -E 's/(RECIPIENT|SENDER|EMAIL|PASSWORD|TOKEN|KEY|SECRET)="[^"]*"/\1="***REDACTED***"/g' \
            "$NFTBAN_CONFIG_DIR/nftban.conf.local" > "$OUTPUT_DIR/config/nftban.conf.local.sanitized" 2>/dev/null || true
        log_success "Collected: nftban.conf.local (sanitized)"
    fi

    # Whitelist (sanitized - remove actual IPs, keep structure)
    if [[ -f "$NFTBAN_CONFIG_DIR/nftban-fail2ban-ip-whitelist.conf.local" ]]; then
        wc -l "$NFTBAN_CONFIG_DIR/nftban-fail2ban-ip-whitelist.conf.local" > "$OUTPUT_DIR/config/whitelist_count.txt" 2>/dev/null || true
        log_success "Collected: whitelist entry count"
    fi

    # Port configurations
    if [[ -d "$NFTBAN_CONFIG_DIR/ports" ]]; then
        cp -a "$NFTBAN_CONFIG_DIR/ports" "$OUTPUT_DIR/config/" 2>/dev/null || true
        log_success "Collected: port configurations"
    fi

    # Feed configurations
    if [[ -d "$NFTBAN_CONFIG_DIR/feeds" ]]; then
        # Copy config files only, not the actual feed data (can be huge)
        mkdir -p "$OUTPUT_DIR/config/feeds"
        find "$NFTBAN_CONFIG_DIR/feeds" -name "*.conf" -exec cp {} "$OUTPUT_DIR/config/feeds/" \; 2>/dev/null || true
        log_success "Collected: feed configurations"
    fi
}

collect_systemd_logs() {
    log_info "Collecting systemd journal logs..."

    mkdir -p "$OUTPUT_DIR/systemd"

    # NFTBan service logs
    if systemctl list-units | grep -q nftban; then
        journalctl -u 'nftban*' --no-pager --since "7 days ago" > "$OUTPUT_DIR/systemd/nftban_services.log" 2>/dev/null || true
        log_success "Collected: nftban systemd service logs (7 days)"
    fi

    # Fail2ban logs (if integrated)
    if systemctl list-units | grep -q fail2ban; then
        journalctl -u fail2ban --no-pager --since "7 days ago" > "$OUTPUT_DIR/systemd/fail2ban.log" 2>/dev/null || true
        log_success "Collected: fail2ban systemd logs (7 days)"
    fi

    # Login monitor logs
    if systemctl list-units | grep -q nftban-login-monitor; then
        journalctl -u 'nftban-login-monitor*' --no-pager --since "7 days ago" > "$OUTPUT_DIR/systemd/login_monitor.log" 2>/dev/null || true
        log_success "Collected: login monitor logs (7 days)"
    fi

    # Boot logs (for reboot safety analysis)
    journalctl -b --no-pager | grep -i nftban > "$OUTPUT_DIR/systemd/boot_logs.log" 2>/dev/null || true
    log_success "Collected: boot logs (current boot)"
}

collect_nftables_state() {
    log_info "Collecting nftables state..."

    mkdir -p "$OUTPUT_DIR/nftables"

    # Current ruleset
    nft list ruleset > "$OUTPUT_DIR/nftables/current_ruleset.nft" 2>/dev/null || true
    log_success "Collected: current nftables ruleset"

    # Table details
    nft list table inet filter > "$OUTPUT_DIR/nftables/inet_filter_table.nft" 2>/dev/null || true
    log_success "Collected: inet filter table"

    # Set statistics
    {
        echo "═══════════════════════════════════════════════════════════"
        echo "NFTables Set Statistics"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        echo "NFTBAN Set (fail2ban bans):"
        nft list set inet filter nftban 2>/dev/null | grep -E 'elements|type|size|policy' || echo "Set not found"
        echo ""

        echo "Feed Blocklist Set:"
        nft list set inet filter feed_blocklist 2>/dev/null | grep -E 'elements|type|size|policy' || echo "Set not found"
        echo ""

        echo "Total Banned IPs:"
        nft list set inet filter nftban 2>/dev/null | grep -o 'elements = {' | wc -l || echo "0"
        echo ""
    } > "$OUTPUT_DIR/nftables/set_statistics.txt"

    log_success "Collected: nftables set statistics"
}

collect_fail2ban_state() {
    log_info "Collecting fail2ban state..."

    mkdir -p "$OUTPUT_DIR/fail2ban"

    # Jail status
    if command -v fail2ban-client &>/dev/null; then
        fail2ban-client status > "$OUTPUT_DIR/fail2ban/jails_status.txt" 2>/dev/null || true

        # Individual jail details
        for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,//g'); do
            fail2ban-client status "$jail" > "$OUTPUT_DIR/fail2ban/jail_${jail}.txt" 2>/dev/null || true
        done

        log_success "Collected: fail2ban jail status"
    else
        log_warning "fail2ban-client not found"
    fi

    # fail2ban config
    if [[ -f /etc/fail2ban/jail.local ]]; then
        cp /etc/fail2ban/jail.local "$OUTPUT_DIR/fail2ban/" 2>/dev/null || true
        log_success "Collected: fail2ban jail.local"
    fi
}

collect_database_state() {
    log_info "Collecting database information..."

    mkdir -p "$OUTPUT_DIR/database"

    # Database sizes
    {
        echo "═══════════════════════════════════════════════════════════"
        echo "NFTBan Database State"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        if [[ -d "$NFTBAN_DATA_DIR/db" ]]; then
            echo "Database Files:"
            ls -lh "$NFTBAN_DATA_DIR/db/" 2>/dev/null || echo "No database files found"
            echo ""

            echo "Total Database Size:"
            du -sh "$NFTBAN_DATA_DIR/db/" 2>/dev/null || echo "0"
            echo ""
        fi

        if [[ -d "$NFTBAN_DATA_DIR/feeds" ]]; then
            echo "Feed Data Size:"
            du -sh "$NFTBAN_DATA_DIR/feeds/" 2>/dev/null || echo "0"
            echo ""

            echo "Feed Files:"
            ls -lh "$NFTBAN_DATA_DIR/feeds/" 2>/dev/null | head -20 || echo "No feed files"
        fi
    } > "$OUTPUT_DIR/database/database_info.txt"

    log_success "Collected: database information"
}

collect_performance_metrics() {
    log_info "Collecting performance metrics..."

    mkdir -p "$OUTPUT_DIR/performance"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "Performance Metrics"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        echo "Top CPU-consuming processes:"
        ps aux --sort=-%cpu | head -15
        echo ""

        echo "Top Memory-consuming processes:"
        ps aux --sort=-%mem | head -15
        echo ""

        echo "NFTBan-related processes:"
        ps aux | grep -E 'nftban|fail2ban' | grep -v grep || echo "No nftban processes found"
        echo ""

        echo "Network connections summary:"
        ss -tunap | grep -E 'ESTAB|LISTEN' | wc -l
        echo ""

        echo "Recent OOM events:"
        journalctl -k --no-pager --since "7 days ago" | grep -i "out of memory" | tail -20 || echo "No OOM events"
        echo ""
    } > "$OUTPUT_DIR/performance/metrics.txt"

    log_success "Collected: performance metrics"
}

collect_security_events() {
    log_info "Collecting security events..."

    mkdir -p "$OUTPUT_DIR/security"

    {
        echo "═══════════════════════════════════════════════════════════"
        echo "Security Events Summary"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        echo "SSH Login Attempts (last 7 days):"
        journalctl --no-pager --since "7 days ago" | grep -i "sshd.*failed\|sshd.*accepted" | wc -l
        echo ""

        echo "Sudo Usage (last 7 days):"
        journalctl --no-pager --since "7 days ago" | grep -i "sudo.*COMMAND" | wc -l
        echo ""

        echo "Recent Failed Login Attempts (last 100):"
        journalctl --no-pager --since "7 days ago" | grep -i "failed password" | tail -100 || echo "None"
        echo ""

        echo "Recent Successful SSH Logins:"
        journalctl --no-pager --since "7 days ago" | grep -i "sshd.*accepted" | tail -50 || echo "None"
        echo ""
    } > "$OUTPUT_DIR/security/security_events.txt"

    log_success "Collected: security events"
}

collect_update_history() {
    log_info "Collecting update history..."

    mkdir -p "$OUTPUT_DIR/updates"

    # Update logs
    if [[ -f "$NFTBAN_LOG_DIR/update.log" ]]; then
        cp "$NFTBAN_LOG_DIR/update.log" "$OUTPUT_DIR/updates/" 2>/dev/null || true
        log_success "Collected: update.log"
    fi

    # Git commit info (if repo exists)
    if [[ -d /etc/nftban/.git ]]; then
        cd /etc/nftban
        git log --oneline -20 > "$OUTPUT_DIR/updates/git_history.txt" 2>/dev/null || true
        git status > "$OUTPUT_DIR/updates/git_status.txt" 2>/dev/null || true
        log_success "Collected: git history"
    fi
}

# =============================================================================
# ARCHIVE CREATION
# =============================================================================

create_archive() {
    log_info "Creating compressed archive..."

    cd /tmp
    tar -czf "$ARCHIVE_NAME" "$(basename "$OUTPUT_DIR")" 2>/dev/null

    local size=$(du -h "$ARCHIVE_NAME" | cut -f1)
    log_success "Archive created: /tmp/$ARCHIVE_NAME ($size)"

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Log Collection Complete!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Archive Location:${NC} /tmp/$ARCHIVE_NAME"
    echo -e "${CYAN}Archive Size:${NC} $size"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Download the archive from the server:"
    echo "     scp root@$HOSTNAME:/tmp/$ARCHIVE_NAME ."
    echo ""
    echo "  2. Extract and analyze:"
    echo "     tar -xzf $ARCHIVE_NAME"
    echo ""
    echo "  3. Clean up temporary files:"
    echo "     rm -rf /tmp/$ARCHIVE_NAME $OUTPUT_DIR"
    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    print_header

    # Pre-flight checks
    check_root
    check_nftban_installed

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    log_success "Created output directory: $OUTPUT_DIR"
    echo ""

    # Collect all data
    collect_system_info
    collect_nftban_logs
    collect_configuration
    collect_systemd_logs
    collect_nftables_state
    collect_fail2ban_state
    collect_database_state
    collect_performance_metrics
    collect_security_events
    collect_update_history

    echo ""

    # Create archive
    create_archive
}

# Run main
main "$@"
