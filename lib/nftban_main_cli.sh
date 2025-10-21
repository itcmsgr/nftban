#!/usr/bin/env bash

# =============================================================================
# NFTBan - Unified CLI Interface
# Version: 0.9.0
# Location: lib/nftban_main_cli.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Main command-line interface with comprehensive validation
# =============================================================================

# Strict & safe defaults (per NFTBan Remediation Guide 2025-10-20)
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

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
            nftban_feeds_enable "$1"
            ;;
        disable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds disable <provider_id>"; exit 1; }
            nftban_feeds_disable "$1"
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
# FAIL2BAN JAIL MANAGEMENT COMMANDS (NEW)
# =============================================================================

cmd_fail2ban() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        setup)
            nftban_check_root || exit 1
            nftban_fail2ban_setup
            ;;
        status)
            nftban_fail2ban_show_status
            ;;
        list)
            nftban_fail2ban_list_jails
            ;;
        enable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban fail2ban enable <jail_name>"; exit 1; }
            nftban_fail2ban_enable_jail "$1"
            ;;
        disable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban fail2ban disable <jail_name>"; exit 1; }
            nftban_fail2ban_disable_jail "$1"
            ;;
        *)
            nftban_log_error "Unknown fail2ban action: $action"
            echo ""
            echo "Available actions:"
            echo "  setup               Setup fail2ban integration"
            echo "  status              Show fail2ban status and jail details"
            echo "  list                List active jails"
            echo "  enable <jail>       Enable jail"
            echo "  disable <jail>      Disable jail"
            echo ""
            echo "Examples:"
            echo "  sudo nftban fail2ban setup"
            echo "  nftban fail2ban status"
            echo "  nftban fail2ban list"
            echo "  sudo nftban fail2ban enable sshd"
            echo "  sudo nftban fail2ban disable sshd"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# MONITORING COMMANDS (NEW)
# =============================================================================

cmd_monitor() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        run)
            nftban_check_root || exit 1
            nftban_monitor_run
            ;;
        status)
            nftban_monitor_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_log_info "Enabling system monitoring..."

            # Check if systemd is available
            if command -v systemctl >/dev/null 2>&1; then
                # Install systemd timer
                local service_src="${LIB_DIR}/../templates/systemd/nftban-monitor.service"
                local timer_src="${LIB_DIR}/../templates/systemd/nftban-monitor.timer"
                local service_dst="/etc/systemd/system/nftban-monitor.service"
                local timer_dst="/etc/systemd/system/nftban-monitor.timer"

                if [[ ! -f "$service_src" ]] || [[ ! -f "$timer_src" ]]; then
                    nftban_log_error "Systemd templates not found"
                    nftban_log_info "Expected locations:"
                    nftban_log_info "  $service_src"
                    nftban_log_info "  $timer_src"
                    exit 1
                fi

                # Copy unit files
                cp "$service_src" "$service_dst" || { nftban_log_error "Failed to copy service unit"; exit 1; }
                cp "$timer_src" "$timer_dst" || { nftban_log_error "Failed to copy timer unit"; exit 1; }

                # Reload systemd
                systemctl daemon-reload || { nftban_log_error "Failed to reload systemd"; exit 1; }

                # Enable and start timer
                systemctl enable nftban-monitor.timer || { nftban_log_error "Failed to enable timer"; exit 1; }
                systemctl start nftban-monitor.timer || { nftban_log_error "Failed to start timer"; exit 1; }

                nftban_log_success "System monitoring enabled (systemd timer)"
                echo ""
                echo "Monitoring will run every 5 minutes automatically."
                echo ""
                echo "Management commands:"
                echo "  systemctl status nftban-monitor.timer   # Check timer status"
                echo "  systemctl stop nftban-monitor.timer     # Stop monitoring"
                echo "  systemctl disable nftban-monitor.timer  # Disable monitoring"
                echo "  journalctl -u nftban-monitor.service    # View logs"
                echo ""
            else
                # Fallback to cron
                nftban_log_warning "systemd not available, using cron instead"

                local cron_entry="*/5 * * * * /usr/local/bin/nftban monitor run >/dev/null 2>&1"

                # Check if already in crontab
                if crontab -l 2>/dev/null | grep -q "nftban monitor run"; then
                    nftban_log_info "Monitoring already enabled in crontab"
                else
                    # Add to crontab
                    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab - || {
                        nftban_log_error "Failed to add cron entry"
                        exit 1
                    }
                    nftban_log_success "System monitoring enabled (cron)"
                fi

                echo ""
                echo "Monitoring will run every 5 minutes via cron."
                echo ""
                echo "To disable: crontab -e (and remove the nftban monitor line)"
                echo ""
            fi
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_log_info "Disabling system monitoring..."

            # Try systemd first
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl is-enabled nftban-monitor.timer >/dev/null 2>&1; then
                    systemctl stop nftban-monitor.timer 2>/dev/null || true
                    systemctl disable nftban-monitor.timer 2>/dev/null || true
                    nftban_log_success "System monitoring disabled (systemd timer)"
                else
                    nftban_log_info "Systemd timer not enabled"
                fi
            fi

            # Check and remove from cron
            if crontab -l 2>/dev/null | grep -q "nftban monitor run"; then
                crontab -l 2>/dev/null | grep -v "nftban monitor run" | crontab -
                nftban_log_success "Monitoring removed from crontab"
            else
                nftban_log_info "Monitoring not found in crontab"
            fi
            ;;
        test)
            nftban_check_root || exit 1
            nftban_log_info "Testing alert delivery..."

            local hostname=$(hostname -f 2>/dev/null || hostname)
            local recipient
            recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "root@localhost")
            local subject="[nftban] TEST: Monitoring alert test"
            local body="This is a test alert from nftban monitoring system.

Server: ${hostname}
Time: $(date -Iseconds)
Status: Monitoring system is operational

If you received this email, alert delivery is working correctly."

            if declare -f nftban_send_email >/dev/null 2>&1; then
                if nftban_send_email "$recipient" "$subject" "$body"; then
                    nftban_log_success "Test alert sent successfully to: $recipient"
                else
                    nftban_log_error "Failed to send test alert"
                    nftban_log_info "Check email configuration in nftban.conf"
                    exit 1
                fi
            else
                nftban_log_error "Email function not available"
                nftban_log_info "Ensure nftban_core.sh is loaded properly"
                exit 1
            fi
            ;;
        help)
            cat <<'EOF'

nftban monitor - System Resource Monitoring

USAGE:
    nftban monitor <action>

ACTIONS:
    run                Run monitoring checks now
    status             Show current resource status
    enable             Enable automated monitoring
    disable            Disable automated monitoring
    test               Test alert delivery

DESCRIPTION:
    The monitoring system tracks disk space, memory, CPU usage, and inodes.
    Multi-level alerts are sent at 80% (WARNING), 90% (CRITICAL), and
    95% (EMERGENCY) thresholds.

    CPU and memory alerts require sustained threshold violations to prevent
    false alarms (configurable durations).

MONITORING THRESHOLDS:
    Disk Space: 80% / 90% / 95% (instant alert)
    Memory:     80% / 90% / 95% (5min / 5min / 3min sustained)
    CPU:        80% / 90% / 95% (10min / 5min / 3min sustained)
    Inodes:     80% / 90% / 95% (instant alert)

CONFIGURATION:
    Configuration file: /etc/nftban/config/monitoring.conf
    User overrides:     /etc/nftban/config/monitoring.conf.local

    All thresholds and durations are configurable.

AUTOMATED MONITORING:
    When enabled, monitoring runs every 5 minutes via:
    - systemd timer (preferred, if available)
    - cron job (fallback)

LOGS:
    Monitoring log:  /var/log/nftban/monitoring.log
    Systemd journal: journalctl -u nftban-monitor.service

EXAMPLES:
    # Run checks manually
    sudo nftban monitor run

    # View current status
    nftban monitor status

    # Enable automated monitoring
    sudo nftban monitor enable

    # Test alert delivery
    sudo nftban monitor test

    # Disable automated monitoring
    sudo nftban monitor disable

    # View monitoring logs
    tail -f /var/log/nftban/monitoring.log
    journalctl -u nftban-monitor.service -f

CUSTOMIZATION:
    Create /etc/nftban/config/monitoring.conf.local to override defaults:

    # Example: More sensitive thresholds
    NFTBAN_MONITOR_DISK_WARN=70
    NFTBAN_MONITOR_DISK_CRIT=85
    NFTBAN_MONITOR_DISK_EMERG=90

    # Example: Longer CPU duration (less sensitive)
    NFTBAN_MONITOR_CPU_DURATION_WARN=1800  # 30 minutes

    # Example: Change alert cooldown
    NFTBAN_MONITOR_ALERT_COOLDOWN=7200  # 2 hours

For more information, see: /etc/nftban/config/monitoring.conf

EOF
            ;;
        *)
            nftban_log_error "Unknown monitor action: $action"
            echo ""
            echo "Available actions:"
            echo "  run                 Run monitoring checks now"
            echo "  status              Show current resource status"
            echo "  enable              Enable automated monitoring (every 5min)"
            echo "  disable             Disable automated monitoring"
            echo "  test                Test alert delivery"
            echo "  help                Show comprehensive help"
            echo ""
            echo "Examples:"
            echo "  sudo nftban monitor run"
            echo "  nftban monitor status"
            echo "  sudo nftban monitor enable"
            echo "  sudo nftban monitor test"
            echo "  sudo nftban monitor disable"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# LOGIN MONITORING COMMANDS (NEW)
# =============================================================================

cmd_login() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_login_monitor_status
            ;;
        install)
            nftban_check_root || exit 1
            nftban_login_monitor_install
            ;;
        uninstall)
            nftban_check_root || exit 1
            nftban_login_monitor_uninstall
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_login_monitor_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_login_monitor_disable
            ;;
        start)
            nftban_check_root || exit 1
            nftban_login_monitor_start
            ;;
        stop)
            nftban_check_root || exit 1
            nftban_login_monitor_stop
            ;;
        restart)
            nftban_check_root || exit 1
            nftban_login_monitor_restart
            ;;
        test)
            nftban_check_root || exit 1
            nftban_login_monitor_test_config
            ;;
        run)
            nftban_check_root || exit 1
            nftban_login_monitor_run
            ;;
        help)
            cat <<'EOF'

nftban login - Login Event Monitoring & Alerting

USAGE:
    nftban login <action>

ACTIONS:
    status              Show login monitor status
    install             Install systemd service
    uninstall           Uninstall systemd service
    enable              Enable login monitoring (start on boot)
    disable             Disable login monitoring
    start               Start login monitoring
    stop                Stop login monitoring
    restart             Restart login monitoring
    test                Test email configuration
    run                 Run monitoring cycle manually

DESCRIPTION:
    The login monitoring system tracks:
    - Root login events (direct and via su/sudo)
    - SSH login attempts
    - Sudo command execution

    Email alerts are sent when configured events are detected.

CONFIGURATION:
    Configuration file: /etc/nftban/config/nftban.conf
    User overrides:     /etc/nftban/config/nftban.conf.local

    Key settings:
    - NFTBAN_F2B_LOGIN_MONITOR="true"        # Enable login monitoring
    - NFTBAN_F2B_ROOT_LOGIN_ALERT="true"     # Alert on root login
    - NFTBAN_F2B_SUDO_ALERT="true"           # Alert on sudo usage
    - NFTBAN_F2B_SSH_LOGIN_ALERT="true"      # Alert on SSH logins
    - NFTBAN_F2B_RECIPIENT="admin@example.com"  # Alert recipient

EXAMPLES:
    # Install and configure
    sudo nftban login install
    sudo nftban login test          # Test email delivery
    sudo nftban login enable        # Enable on boot
    sudo nftban login start         # Start monitoring

    # View status
    nftban login status

    # Disable monitoring
    sudo nftban login stop
    sudo nftban login disable

LOGS:
    Monitor log:  /var/log/nftban/login-monitor.log
    Alert log:    /var/log/nftban/login-alerts.log

NOTE:
    To enable/disable specific alert types, edit your config file:
      /etc/nftban/config/nftban.conf.local

    Example:
      NFTBAN_F2B_ROOT_LOGIN_ALERT="true"   # Enable root login alerts
      NFTBAN_F2B_SUDO_ALERT="false"        # Disable sudo alerts

EOF
            ;;
        *)
            nftban_log_error "Unknown login action: $action"
            echo ""
            echo "Available actions:"
            echo "  status              Show login monitor status"
            echo "  install             Install systemd service"
            echo "  uninstall           Uninstall systemd service"
            echo "  enable              Enable login monitoring (start on boot)"
            echo "  disable             Disable login monitoring"
            echo "  start               Start login monitoring"
            echo "  stop                Stop login monitoring"
            echo "  restart             Restart login monitoring"
            echo "  test                Test email configuration"
            echo "  run                 Run monitoring cycle manually"
            echo "  help                Show comprehensive help"
            echo ""
            echo "Examples:"
            echo "  nftban login status"
            echo "  sudo nftban login install"
            echo "  sudo nftban login enable"
            echo "  sudo nftban login start"
            echo "  sudo nftban login test"
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
        pin)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban update pin <commit-sha>"; exit 1; }
            nftban_update_set_commit_pin "$1"
            ;;
        show-commit|show-pin)
            echo "Pinned commit:"
            local pinned
            pinned=$(nftban_update_get_pinned_commit)
            if [[ -n "$pinned" ]]; then
                echo "  $pinned"
                echo "  https://github.com/itcmsgr/nftban/commit/$pinned"
            else
                echo "  (not configured - updates disabled)"
            fi
            echo ""
            echo "Remote commit:"
            if remote_sha=$(nftban_update_get_remote_commit_sha 2>/dev/null); then
                echo "  $remote_sha"
                echo "  https://github.com/itcmsgr/nftban/commit/$remote_sha"
            else
                echo "  (failed to fetch)"
            fi
            ;;
        *)
            nftban_log_error "Unknown update action: $action"
            echo ""
            echo "Available actions:"
            echo "  check                   Check for available updates"
            echo "  perform                 Perform update (with confirmation)"
            echo "  auto                    Perform update (no confirmation)"
            echo "  rollback [DIR]          Rollback to previous version"
            echo "  version                 Show current and available versions"
            echo "  pin <commit-sha>        Pin updates to specific commit (security)"
            echo "  show-commit             Show pinned and remote commit SHAs"
            echo ""
            echo "Security (Commit Pinning):"
            echo "  Updates are verified against a pinned git commit SHA"
            echo "  This prevents man-in-the-middle attacks and compromises"
            echo ""
            echo "Examples:"
            echo "  nftban update show-commit           # Show current commits"
            echo "  sudo nftban update pin <sha>        # Pin to trusted commit"
            echo "  nftban update check                 # Check for updates"
            echo "  sudo nftban update perform          # Perform update"
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
        validate)
            nftban_maintenance_validate_config
            ;;
        repair)
            nftban_check_root || exit 1
            nftban_maintenance_repair_config
            ;;
        health)
            nftban_maintenance_health_check_detailed
            ;;
        health-basic)
            nftban_maintenance_health_check
            ;;
        stats)
            nftban_maintenance_show_stats
            ;;
        check-permissions|perms)
            nftban_maintenance_validate_permissions
            ;;
        backup)
            nftban_check_root || exit 1
            nftban_update_create_backup
            ;;
        list-backups)
            nftban_log_info "Available backups:"
            find "${NFTBAN_UPDATE_BACKUP_DIR}" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -10
            ;;
        restore)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && {
                nftban_log_error "Usage: nftban maintenance restore <backup_dir>"
                echo ""
                echo "Available backups:"
                find "${NFTBAN_UPDATE_BACKUP_DIR}" -maxdepth 1 -type d -name "pre_update_*" 2>/dev/null | sort -r | head -10
                exit 1
            }
            nftban_update_rollback "$1"
            ;;
        clean)
            nftban_check_root || exit 1
            nftban_maintenance_run
            ;;
        enable)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Enabling service: $service"
            nftban_service_control "enable" "$service"
            nftban_log_success "Service enabled: $service"
            ;;
        disable)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Disabling service: $service"
            nftban_service_control "disable" "$service"
            nftban_log_success "Service disabled: $service"
            ;;
        start)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Starting service: $service"
            nftban_service_control "start" "$service"
            nftban_log_success "Service started: $service"
            ;;
        stop)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Stopping service: $service"
            nftban_service_control "stop" "$service"
            nftban_log_success "Service stopped: $service"
            ;;
        restart)
            nftban_check_root || exit 1
            local service="${1:-all}"
            nftban_log_info "Restarting service: $service"
            nftban_service_control "restart" "$service"
            nftban_log_success "Service restarted: $service"
            ;;
        *)
            nftban_log_error "Unknown maintenance action: $action"
            echo ""
            echo "Available actions:"
            echo "  panel            Show maintenance panel"
            echo "  validate         Validate configuration files"
            echo "  repair           Repair broken configuration"
            echo "  health           Comprehensive health check"
            echo "  health-basic     Basic health check"
            echo "  stats            Show system statistics"
            echo "  check-permissions Check file/directory permissions"
            echo "  backup           Create manual backup"
            echo "  list-backups     List available backups"
            echo "  restore <dir>    Restore from backup"
            echo "  clean            Run maintenance cleanup"
            echo ""
            echo "Service Management:"
            echo "  enable [service] Enable service (all/nftables/fail2ban)"
            echo "  disable [service] Disable service (all/nftables/fail2ban)"
            echo "  start [service]  Start service (all/nftables/fail2ban)"
            echo "  stop [service]   Stop service (all/nftables/fail2ban)"
            echo "  restart [service] Restart service (all/nftables/fail2ban)"
            echo ""
            echo "Examples:"
            echo "  nftban maintenance panel"
            echo "  nftban maintenance validate"
            echo "  nftban maintenance repair"
            echo "  nftban maintenance health"
            echo "  nftban maintenance stats"
            echo "  nftban maintenance check-permissions"
            echo ""
            echo "  sudo nftban maintenance disable all       # Disable both nftables and fail2ban"
            echo "  sudo nftban maintenance enable all        # Enable both services"
            echo "  sudo nftban maintenance restart nftables  # Restart nftables only"
            echo "  sudo nftban maintenance stop fail2ban     # Stop fail2ban only"
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
        protect-server|add-system)
            nftban_check_root || exit 1
            nftban_whitelist_add_server_ips
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
            echo "  protect-server      Auto-protect all server IPs"
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
# SYNC COMMANDS (NEW)
# =============================================================================

cmd_sync() {
    local action="${1:-verify}"
    shift || true

    case "$action" in
        verify|check|status)
            nftban_sync_verify
            ;;
        test|dry-run)
            nftban_log_info "Running sync test (dry-run mode)..."
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo "  Sync Dry-Run Test"
            echo "═══════════════════════════════════════════════════════"
            echo ""

            # Check for drift without fixing
            local whitelist_drift=false
            local blacklist_drift=false

            if declare -f nftban_sync_check_whitelist_drift >/dev/null 2>&1; then
                echo "Checking whitelist synchronization..."
                if ! nftban_sync_check_whitelist_drift; then
                    whitelist_drift=true
                    nftban_log_warning "  Whitelist drift detected (would be fixed)"
                else
                    nftban_log_success "  Whitelist synchronized"
                fi
            fi
            echo ""

            if declare -f nftban_sync_check_blacklist_drift >/dev/null 2>&1; then
                echo "Checking blacklist synchronization..."
                if ! nftban_sync_check_blacklist_drift; then
                    blacklist_drift=true
                    nftban_log_warning "  Blacklist drift detected (would be fixed)"
                else
                    nftban_log_success "  Blacklist synchronized"
                fi
            fi
            echo ""

            if [[ "$whitelist_drift" == "true" ]] || [[ "$blacklist_drift" == "true" ]]; then
                echo "═══════════════════════════════════════════════════════"
                nftban_log_warning "Dry-run complete: Issues detected"
                echo ""
                echo "To fix these issues, run:"
                echo "  sudo nftban sync repair"
                echo ""
            else
                echo "═══════════════════════════════════════════════════════"
                nftban_log_success "Dry-run complete: No issues detected"
                echo ""
            fi
            ;;
        repair|fix)
            nftban_check_root || exit 1
            nftban_sync_repair
            ;;
        auto)
            nftban_check_root || exit 1
            local sync_type="${1:-all}"
            nftban_sync_auto "$sync_type"
            ;;
        health)
            if nftban_sync_health; then
                nftban_log_success "Synchronization health: OK"
            else
                nftban_log_warning "Synchronization health: Issues detected"
            fi
            ;;
        help)
            cat <<'EOF'

nftban sync - File/nftables Synchronization Management

USAGE:
    nftban sync <action>

ACTIONS:
    verify              Verify synchronization status (default)
    test|dry-run        Test sync without making changes (dry-run mode)
    repair              Repair desynchronization automatically
    auto [type]         Auto-sync specific type (whitelist/blacklist/all)
    health              Check synchronization health

DESCRIPTION:
    The sync system ensures that IP lists in configuration files remain
    synchronized with nftables sets. Drift can occur if files are manually
    edited or if nftables sets are modified directly.

    The sync module detects drift by comparing IP counts between files and
    nftables, then provides automatic repair mechanisms.

SYNCHRONIZATION CHECKS:
    • Whitelist files vs nftables whitelist set
    • Blacklist files vs nftables user_blacklist set
    • Verifies all required nftables sets exist

AUTOMATIC SYNC:
    After IP operations (add/remove), the system automatically syncs changes
    to nftables. The 'auto' command allows manual triggering of this process.

REPAIR PROCESS:
    1. Detects drift (IP count mismatches)
    2. Syncs file contents to nftables sets
    3. Rebuilds search index
    4. Logs all operations

HEALTH SCORING:
    The health check returns a score from 0-100:
    - 100: Perfect synchronization
    - 70-99: Minor issues (e.g., one table missing)
    - 40-69: Moderate issues (e.g., drift detected)
    - 0-39: Severe issues (e.g., multiple tables missing + drift)

EXAMPLES:
    # Check synchronization status
    nftban sync verify

    # Test sync without making changes (dry-run)
    nftban sync test
    nftban sync dry-run

    # Repair any detected drift
    sudo nftban sync repair

    # Auto-sync whitelist only
    sudo nftban sync auto whitelist

    # Auto-sync blacklist only
    sudo nftban sync auto blacklist

    # Auto-sync everything
    sudo nftban sync auto all

    # Check health score
    nftban sync health

LOGS:
    Sync operations are logged to: /var/log/nftban/sync.log

WHEN TO USE:
    - After manually editing whitelist/blacklist files
    - After direct nftables modifications
    - During troubleshooting
    - As part of maintenance procedures
    - After system restores

For more information, see: /etc/nftban/lib/nftban_sync_module.sh

EOF
            ;;
        *)
            nftban_log_error "Unknown sync action: $action"
            echo ""
            echo "Available actions:"
            echo "  verify              Verify synchronization status"
            echo "  test|dry-run        Test sync without making changes"
            echo "  repair              Repair desynchronization"
            echo "  auto [type]         Auto-sync (whitelist/blacklist/all)"
            echo "  health              Check synchronization health"
            echo "  help                Show comprehensive help"
            echo ""
            echo "Examples:"
            echo "  nftban sync verify"
            echo "  nftban sync test"
            echo "  sudo nftban sync repair"
            echo "  sudo nftban sync auto all"
            echo "  nftban sync health"
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
# CLOUDFLARE WHITELIST COMMANDS (NEW)
# =============================================================================

cmd_cloudflare() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_cloudflare_status
            ;;
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
            nftban_cloudflare_update_whitelist
            ;;
        init)
            nftban_check_root || exit 1
            nftban_cloudflare_init
            ;;
        *)
            nftban_log_error "Unknown cloudflare action: $action"
            echo ""
            echo "Available actions:"
            echo "  status              Show Cloudflare whitelist status"
            echo "  enable              Enable Cloudflare IP whitelisting"
            echo "  disable             Disable Cloudflare IP whitelisting"
            echo "  update              Update Cloudflare IP list"
            echo "  init                Initialize Cloudflare whitelist"
            echo ""
            echo "Examples:"
            echo "  nftban cloudflare status"
            echo "  nftban cloudflare enable"
            echo "  nftban cloudflare update"
            echo ""
            exit 1
            ;;
    esac
}

# =============================================================================
# GEO-BLOCKING COMMANDS (NEW)
# =============================================================================

cmd_geo() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_geo_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_geo_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_geo_disable
            ;;
        help)
            nftban_geo_help
            ;;
        block)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo block <COUNTRY> [reason]"; exit 1; }
            nftban_geo_block_country "$1" "both"
            ;;
        unblock)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo unblock <COUNTRY>"; exit 1; }
            nftban_geo_unblock_country "$1" "both"
            ;;
        list)
            nftban_geo_list_blocked
            ;;
        check)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo check <IP>"; exit 1; }
            nftban_geo_check_ip "$1"
            ;;
        reload|sync)
            nftban_check_root || exit 1
            nftban_geo_sync_blacklist
            ;;
        update)
            nftban_check_root || exit 1
            nftban_geo_update_database "${1:-ALL}"
            ;;
        init)
            nftban_check_root || exit 1
            nftban_geo_init
            ;;
        *)
            nftban_log_error "Unknown geo action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                Show GEO-blocking status"
            echo "  enable                Enable GEO-blocking"
            echo "  disable               Disable GEO-blocking"
            echo "  help                  Show comprehensive help"
            echo "  block <COUNTRY>       Block a country (e.g., CN, RU)"
            echo "  unblock <COUNTRY>     Unblock a country"
            echo "  list                  List all blocked countries"
            echo "  check <IP>            Check if IP is GEO-blocked"
            echo "  reload                Reload blacklist to nftables"
            echo "  update [COUNTRY]      Update GeoIP database"
            echo "  init                  Initialize GEO-blocking system"
            echo ""
            echo "Examples:"
            echo "  nftban geo status"
            echo "  nftban geo help"
            echo "  nftban geo block CN"
            echo "  nftban geo unblock RU"
            echo "  nftban geo list"
            echo "  nftban geo check 1.2.3.4"
            echo "  nftban geo update ALL"
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

cmd_uninstall() {
    nftban_check_root || exit 1

    local uninstaller="${NFTBAN_BASE_DIR}/lib/installer/nftban_uninstall_script.sh"

    if [[ ! -f "$uninstaller" ]]; then
        nftban_log_error "Uninstaller script not found: $uninstaller"
        nftban_log_info "Expected location: /etc/nftban/lib/installer/nftban_uninstall_script.sh"
        return 1
    fi

    # Call uninstaller with arguments
    bash "$uninstaller" "$@"
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
    # Check if running as root (required for nftables operations)
    if [[ $EUID -ne 0 ]]; then
        nftban_log_warning "Some verification checks require root permissions"
        nftban_log_warning "Run with sudo for complete verification"
        echo ""
    fi

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

    # Optional: Check search index if function exists
    if declare -f nftban_search_verify_index >/dev/null 2>&1; then
        if nftban_search_verify_index; then
            nftban_log_success "Search index: OK"
        else
            nftban_log_warning "Search index: Needs rebuild"
        fi
    fi

    # Check file permissions (optional, informational only)
    if declare -f nftban_maintenance_validate_permissions >/dev/null 2>&1; then
        nftban_maintenance_validate_permissions || true
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Verification Summary"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    if [[ $errors -eq 0 ]]; then
        nftban_log_success "All critical checks passed"
        echo ""
        echo "System is healthy and ready to use."
    else
        nftban_log_error "Verification failed with $errors critical error(s)"
        echo ""
        echo "Please fix the errors above and run 'nftban verify' again."
    fi
    echo ""

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
    uninstall               Uninstall nftban system
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

SYNCHRONIZATION:
    sync verify             Verify file/nftables synchronization
    sync repair             Repair desynchronization automatically
    sync auto [type]        Auto-sync (whitelist/blacklist/all)
    sync health             Check synchronization health

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

GEO-BLOCKING:
    geo status              Show GEO-blocking status
    geo enable              Enable GEO-blocking
    geo disable             Disable GEO-blocking
    geo help                Show comprehensive GEO-blocking help
    geo block <COUNTRY>     Block a country (e.g., CN, RU)
    geo unblock <COUNTRY>   Unblock a country
    geo list                List all blocked countries
    geo check <IP>          Check if IP is GEO-blocked

UPDATE & MAINTENANCE:
    update check            Check for available updates
    update perform          Perform system update
    update rollback         Rollback to previous version
    maintenance panel       Show maintenance panel
    maintenance validate    Validate configuration files
    maintenance repair      Repair broken configuration
    maintenance health      Comprehensive health check
    maintenance stats       Show system statistics
    maintenance check-permissions Check file/directory permissions
    maintenance backup      Create system backup
    maintenance list-backups List available backups
    maintenance restore <dir> Restore from backup

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

FAIL2BAN JAIL MANAGEMENT:
    fail2ban setup          Setup fail2ban integration
    fail2ban status         Show fail2ban status and jail details
    fail2ban list           List active jails
    fail2ban enable <jail>  Enable jail
    fail2ban disable <jail> Disable jail

SYSTEM MONITORING:
    monitor run             Run monitoring checks now
    monitor status          Show current resource status
    monitor enable          Enable automated monitoring (5min interval)
    monitor disable         Disable automated monitoring
    monitor test            Test alert delivery
    monitor help            Show monitoring help

EXAMPLES (MONITORING):
    nftban monitor status
    sudo nftban monitor run
    sudo nftban monitor enable
    sudo nftban monitor test

EXAMPLES (FEEDS):
    sudo nftban feeds init
    nftban feeds list
    sudo nftban feeds enable spamhaus
    sudo nftban feeds update
    sudo nftban feeds timer-install

EXAMPLES (FAIL2BAN):
    sudo nftban fail2ban setup
    nftban fail2ban status
    nftban fail2ban list
    sudo nftban fail2ban enable sshd
    sudo nftban fail2ban disable apache-auth

EXAMPLES (GEO-BLOCKING):
    nftban geo status
    nftban geo help
    sudo nftban geo block CN
    sudo nftban geo unblock RU
    nftban geo list
    nftban geo check 1.2.3.4

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

    # Try to auto-load modular command from lib/cli/
    local cmd_file="${LIB_DIR}/cli/cmd_${command}.sh"
    if [[ -f "$cmd_file" ]]; then
        source "$cmd_file"
        "cmd_${command}" "$@"
        return $?
    fi

    case "$command" in
        init) cmd_init "$@" ;;
        uninstall|remove) cmd_uninstall "$@" ;;
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

        # Synchronization
        sync) cmd_sync "$@" ;;

        # Statistics & Monitoring
        stats) cmd_stats "$@" ;;

        # Port Management
        port|ports) cmd_port "$@" ;;

        # DDoS Protection
        ddos) cmd_ddos "$@" ;;

        # Port Scan Detection
        portscan) cmd_portscan "$@" ;;

        # GEO-Blocking
        geo) cmd_geo "$@" ;;

        # Cloudflare Whitelist
        cloudflare|cf) cmd_cloudflare "$@" ;;

		# Feeds Management
        feeds) cmd_feeds "$@" ;;

        # Fail2ban Jail Management
        fail2ban|f2b) cmd_fail2ban "$@" ;;

        # System Monitoring
        monitor|monitoring) cmd_monitor "$@" ;;

        # Login Monitoring
        login) cmd_login "$@" ;;

        # Testing & Diagnostics
        test|smoke-test|smoketest) cmd_test "$@" ;;
        diagnostics|diag|debug) cmd_diagnostics "$@" ;;

        # IP Search (Stupid-User-Friendly!)
        search)
            local search_type="${1:-}"
            shift || true
            if [[ "$search_type" == "ip" ]]; then
                [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban search ip <IP_ADDRESS>"; exit 1; }
                nftban_search_ip_everywhere "$1"
            else
                nftban_log_error "Usage: nftban search ip <IP_ADDRESS>"
                echo ""
                echo "Examples:"
                echo "  nftban search ip 192.168.1.100"
                echo "  nftban search ip 2001:db8::1"
                exit 1
            fi
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
