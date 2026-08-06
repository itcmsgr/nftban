#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# NFTBan - Report Generation & Scheduling CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for report generation and automated scheduling
#
# meta:name="cmd_report"
# meta:type="cli"
# meta:header="Report Generation CLI Handler"
# meta:version="1.41.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for report generation and automated scheduling"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_REPORT_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_REPORT_LOADED=1

# =============================================================================

# LOAD DEPENDENCIES
# =============================================================================


# Load stats core module
if ! declare -f nftban_stats_generate_dashboard >/dev/null 2>&1; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" || {
            echo "ERROR: Failed to load stats core module" >&2
            return 1
        }
    fi
fi

# Load mail module if available
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_mail.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_mail.sh" 2>/dev/null || true
fi

# Load panel common module for admin email detection
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_panel_common.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_panel_common.sh" 2>/dev/null || true
fi

# Load path security module
if ! declare -f nftban_path_get_safe_output >/dev/null 2>&1; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_path_security.sh" || {
            echo "ERROR: Failed to load path security module" >&2
            return 1
        }
    fi
fi

# Load distro config for distribution-specific paths
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" || return 1
fi

# =============================================================================

# CONFIGURATION
# =============================================================================


readonly NFTBAN_CRON_FILE="${DISTRO_PATHS[cron_d]:-/etc/cron.d}/nftban-stats"
readonly NFTBAN_REPORTS_DIR="${STATS_REPORTS_DIR:-${NFTBAN_LOG_DIR:-/var/log/nftban}/reports}"

# =============================================================================

# MAIN CLI HANDLER
# =============================================================================


nftban_cmd_report() {
    # Main report command handler
    # Usage: nftban report [subcommand] [options]

    local subcommand="${1:-help}"

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        help|-h|--help)
            nftban_report_cmd_help
            return 0
            ;;
        generate)
            shift
            nftban_report_cmd_generate "$@"
            ;;
        email)
            shift
            nftban_report_cmd_email "$@"
            ;;
        email-setup)
            shift
            nftban_report_cmd_email_setup "$@"
            ;;
        schedule)
            shift
            nftban_report_cmd_schedule "$@"
            ;;
        run)
            shift
            nftban_report_cmd_run "$@"
            ;;
        list)
            shift || true
            nftban_report_cmd_list "$@"
            ;;
        status)
            shift || true
            nftban_report_cmd_status "$@"
            ;;
        *)
            echo "ERROR: Unknown report command: $subcommand" >&2
            echo "Run 'nftban report help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# SUBCOMMAND: GENERATE
# =============================================================================


nftban_report_cmd_generate() {
    # Generate report
    # Usage: nftban report generate [--format FORMAT] [--output FILE] [OPTIONS]

    local format="${REPORTS_DEFAULT_FORMAT:-html}"
    local output=""
    local since
    since="$(date -d '7 days ago' +%Y-%m-%d)"
    local until
    until="$(date +%Y-%m-%d)"
    local theme="${REPORTS_THEME:-dark}"
    local allow_unsafe=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                format="$2"
                shift 2
                ;;
            --output)
                output="$2"
                shift 2
                ;;
            --unsafe-allow-tmp)
                allow_unsafe="allow-unsafe"
                shift
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --until)
                until="$2"
                shift 2
                ;;
            --last)
                local period="$2"
                case "$period" in
                    *d) since="$(date -d "${period%d} days ago" +%Y-%m-%d)" ;;
                    *h) since="$(date -d "${period%h} hours ago" +%Y-%m-%d)" ;;
                esac
                shift 2
                ;;
            --theme)
                theme="$2"
                shift 2
                ;;
            *)
                echo "WARNING: Unknown option: $1" >&2
                shift
                ;;
        esac
    done

    # Security notice for users
    if [[ -n "$output" ]]; then
        echo "[SECURITY] Output path validation enabled - only approved directories allowed" >&2
        echo "[INFO] Approved locations: ${NFTBAN_DATA_DIR:-/var/lib/nftban}/* (reports, metrics, exports)" >&2
    fi

    # Generate based on format
    case "$format" in
        json)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe" ".json") || return 1
            nftban_stats_export_json "$safe_output" "$since" "$until"
            ;;
        csv)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe" ".csv") || return 1
            nftban_stats_export_csv "$safe_output" "$since" "$until"
            ;;
        html)
            local safe_output
            safe_output=$(nftban_path_get_safe_output "$output" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe" ".html") || return 1
            # v1.228.5 WRITER-TRUTH: propagate generation failure to the caller's exit code.
            nftban_report_generate_html "$safe_output" "$since" "$until" "$theme" || return 1
            ;;
        all)
            local base_name
            base_name="report-$(date +%Y%m%d-%H%M%S)"
            local safe_json safe_csv safe_html

            # Use filename-only mode for 'all' format
            safe_json=$(nftban_path_get_safe_output "${base_name}.json" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe") || return 1
            safe_csv=$(nftban_path_get_safe_output "${base_name}.csv" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe") || return 1
            safe_html=$(nftban_path_get_safe_output "${base_name}.html" "${NFTBAN_REPORTS_DIR}" "$allow_unsafe") || return 1

            nftban_stats_export_json "$safe_json" "$since" "$until"
            nftban_stats_export_csv "$safe_csv" "$since" "$until"
            nftban_report_generate_html "$safe_html" "$since" "$until" "$theme"
            ;;
        *)
            echo "ERROR: Unknown format: $format" >&2
            echo "Valid formats: json, csv, html, all" >&2
            return 1
            ;;
    esac
}

# =============================================================================

# SUBCOMMAND: EMAIL
# =============================================================================


nftban_report_cmd_email() {
    # Email report to recipient
    # Usage: nftban report email <RECIPIENT> [OPTIONS]

    local recipient="${1:-}"

    if [[ -z "$recipient" ]]; then
        echo "ERROR: Recipient email required" >&2
        echo "Usage: nftban report email <recipient@example.com>" >&2
        return 1
    fi

    shift

    local format="${STATS_EMAIL_FORMAT:-html}"
    local attach_csv="${STATS_EMAIL_ATTACH_CSV:-false}"
    local since
    since="$(date -d '7 days ago' +%Y-%m-%d)"
    local until
    until="$(date +%Y-%m-%d)"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                format="$2"
                shift 2
                ;;
            --attach-csv)
                attach_csv=true
                shift
                ;;
            --since)
                since="$2"
                shift 2
                ;;
            --until)
                until="$2"
                shift 2
                ;;
            --last)
                local period="$2"
                case "$period" in
                    *d) since="$(date -d "${period%d} days ago" +%Y-%m-%d)" ;;
                esac
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Preparing report email for ${recipient}..."
    else
        echo "[INFO] Preparing email..."
    fi

    # Generate reports
    local temp_dir
    temp_dir=$(mktemp -d)
    local report_json="${temp_dir}/report.json"
    local report_csv="${temp_dir}/report.csv"
    # shellcheck disable=SC2034  # Reserved for HTML reports
    local report_html="${temp_dir}/report.html"

    nftban_stats_export_json "$report_json" "$since" "$until" &>/dev/null

    if [[ "${attach_csv,,}" =~ ^(yes|true|1|on)$ ]]; then
        nftban_stats_export_csv "$report_csv" "$since" "$until" &>/dev/null
    fi

    # Send email with full HTML report

    # Load report email generator if not already loaded
    if ! declare -f nftban_report_email_generate >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_report_email.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_report_email.sh" 2>/dev/null || true
        fi
    fi

    # Try to use the full HTML report generator
    if declare -f nftban_report_email_generate >/dev/null 2>&1; then
        if ! nftban_report_email_generate "$recipient"; then
            echo "ERROR: Failed to send email" >&2
            rm -rf "$temp_dir"
            return 1
        fi

        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "success" "Report emailed to ${recipient}"
        else
            echo "[SUCCESS] Email submitted to ${recipient} (delivery not confirmed)"
        fi
    elif declare -f nftban_mail_send >/dev/null 2>&1; then
        # Fallback: Use mail module with basic content
        local body
        body=$(cat <<EOF
<h2>NFTBan Statistics Report</h2>

<p><strong>Period:</strong> ${since} to ${until}</p>
<p><strong>Generated:</strong> $(date)</p>
<p><strong>Hostname:</strong> $(hostname)</p>

<p>See attached files for detailed statistics.</p>

<hr>
<p><small>Automated by NFTBan v${NFTBAN_VERSION:-unknown}</small></p>
EOF
)

        # nftban_mail_send signature: content, recipient (optional)
        if ! NFTBAN_MAIL_SUBJECT_OVERRIDE="NFTBan Statistics Report" nftban_mail_send "$body" "$recipient"; then
            echo "ERROR: Failed to send email" >&2
            rm -rf "$temp_dir"
            return 1
        fi

        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "success" "Report emailed to ${recipient}"
        else
            echo "[SUCCESS] Email submitted to ${recipient} (delivery not confirmed)"
        fi
    else
        echo ""
        echo "❌ Email not configured"
        echo ""
        echo "To enable email reports, you have two options:"
        echo ""
        echo "Option 1: Interactive Setup (Recommended)"
        echo "  └─ Run: nftban report email-setup"
        echo ""
        echo "Option 2: Manual Configuration"
        echo "  1. Edit: /etc/nftban/conf.d/mail.conf"
        echo "  2. Set: MAIL_ENABLED=\"true\""
        echo "  3. Set: MAIL_TO=\"admin@example.com\""
        echo "  4. Configure SMTP settings (or use sendmail)"
        echo "  5. Test: nftban mail test"
        echo ""
        echo "Documentation: nftban help mail"
        echo ""
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup
    rm -rf "$temp_dir"
}

nftban_report_cmd_email_setup() {
    # Interactive email configuration setup
    # Usage: nftban report email-setup

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Email Configuration Setup"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local mail_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"

    # Check if mail.conf exists
    if [[ ! -f "$mail_conf" ]]; then
        echo "⚠️  Mail configuration file not found: $mail_conf"
        echo ""
        read -p "Create configuration file? (y/n): " create_conf
        if [[ "${create_conf,,}" != "y" ]]; then
            echo "Setup cancelled."
            return 1
        fi
        mkdir -p "$(dirname "$mail_conf")" || return 1
        touch "$mail_conf"
        chmod 640 "$mail_conf"
        chown root:nftban "$mail_conf"
        echo "✓ Created $mail_conf"
        echo ""
    fi

    # Prompt for email address (with auto-detection from panel)
    echo "Email Configuration"
    echo "───────────────────────────────────────────────────────────────"

    # Try to auto-detect email from panel
    local detected_email=""
    local detected_panel=""
    if declare -f nftban_panel_get_admin_email &>/dev/null; then
        detected_email=$(nftban_panel_get_admin_email 2>/dev/null) || true
        detected_panel=$(nftban_panel_detect 2>/dev/null) || true
    fi

    if [[ -n "$detected_email" ]]; then
        echo "✓ Detected admin email from ${detected_panel}: ${detected_email}"
        read -p "Use this email? (Y/n): " use_detected
        if [[ "${use_detected,,}" != "n" ]]; then
            user_email="$detected_email"
        else
            read -p "Enter your email address: " user_email
        fi
    else
        read -p "Enter your email address: " user_email
    fi

    if [[ -z "$user_email" ]]; then
        echo "❌ Email address is required"
        return 1
    fi

    # Prompt for mail method
    echo ""
    echo "Mail Method:"
    echo "  1) sendmail (recommended if available)"
    echo "  2) SMTP server (requires configuration)"
    read -p "Select method (1 or 2): " mail_method

    # Update configuration
    echo ""
    echo "Updating configuration..."

    # Backup existing config
    if [[ -f "$mail_conf" ]] && [[ -s "$mail_conf" ]]; then
        cp "$mail_conf" "${mail_conf}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "✓ Backed up existing configuration"
    fi

    # Check if file already has the standard NFTBan variables
    if grep -q "NFTBAN_MAIL_RECIPIENT" "$mail_conf" 2>/dev/null; then
        # File uses standard NFTBan variables - update in place
        echo "✓ Updating existing mail configuration..."

        # Update recipient (proper escaping for sed)
        if grep -q "^NFTBAN_MAIL_RECIPIENT=" "$mail_conf"; then
            # Use different delimiter and proper escaping
            sed -i "s|^NFTBAN_MAIL_RECIPIENT=.*|NFTBAN_MAIL_RECIPIENT=\"${user_email}\"|g" "$mail_conf"
        else
            echo "NFTBAN_MAIL_RECIPIENT=\"$user_email\"" >> "$mail_conf"
        fi

        # Update mail system based on user choice
        if [[ "$mail_method" == "1" ]]; then
            sed -i 's|^NFTBAN_MAIL_SYSTEM=.*|NFTBAN_MAIL_SYSTEM="sendmail"|g' "$mail_conf"
        else
            sed -i 's|^NFTBAN_MAIL_SYSTEM=.*|NFTBAN_MAIL_SYSTEM="smtp"|g' "$mail_conf"
        fi

    else
        # Old format or empty file - write new configuration using STANDARD variables
        {
            echo "# ============================================================================="
            echo "# NFTBan Mail Configuration"
            echo "# Generated: $(date)"
            echo "# ============================================================================="
            echo ""
            echo "# Recipient email (STANDARD VARIABLE)"
            echo "NFTBAN_MAIL_RECIPIENT=\"$user_email\""
            echo ""

            if [[ "$mail_method" == "1" ]]; then
                echo "# Use sendmail"
                echo "NFTBAN_MAIL_SYSTEM=\"sendmail\""
            else
                echo "# Use SMTP (requires additional configuration)"
                echo "NFTBAN_MAIL_SYSTEM=\"smtp\""
                echo ""
                echo "# SMTP Configuration (edit these in /etc/nftban/nftban.conf.local)"
                echo "# NFTBAN_SMTP_HOST=\"smtp.example.com\""
                echo "# NFTBAN_SMTP_PORT=\"587\""
                echo "# NFTBAN_SMTP_USER=\"user@example.com\""
                echo "# NFTBAN_SMTP_PASS=\"your-password\""
                echo "# NFTBAN_SMTP_TLS=\"yes\""
            fi
        } > "$mail_conf"
    fi

    chmod 640 "$mail_conf"
    chown root:nftban "$mail_conf" 2>/dev/null || true

    echo "✓ Configuration saved to $mail_conf"
    echo ""

    if [[ "$mail_method" == "2" ]]; then
        echo "⚠️  SMTP configuration incomplete!"
        echo ""
        echo "Next steps:"
        echo "  1. Edit $mail_conf"
        echo "  2. Update SMTP settings (host, port, username, password)"
        echo "  3. Test: nftban mail test"
        echo ""
    else
        echo "Testing email configuration..."
        echo ""
        if command -v sendmail >/dev/null 2>&1; then
            echo "✓ sendmail found"
            echo ""
            read -p "Send test email to $user_email? (y/n): " send_test
            if [[ "${send_test,,}" == "y" ]]; then
                if declare -f nftban_mail_send >/dev/null 2>&1; then
                    nftban_mail_send "$user_email" "NFTBan Test Email" "This is a test email from NFTBan." || {
                        echo "❌ Test email failed"
                        echo "   Check /var/log/mail.log for details"
                    }
                else
                    echo "ℹ️  Mail module not loaded, skipping test"
                    echo "   Run: nftban mail test"
                fi
            fi
        else
            echo "⚠️  sendmail not found"
            echo ""
            echo "Install sendmail or postfix:"
            echo "  Fedora/RHEL: dnf install postfix"
            echo "  Debian/Ubuntu: apt install postfix"
            echo ""
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Email Configuration Complete"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Test email:    nftban mail test"
    echo "Send report:   nftban report email $user_email"
    echo "View config:   cat $mail_conf"
    echo ""
}

# =============================================================================

# SUBCOMMAND: SCHEDULE
# =============================================================================


nftban_report_cmd_schedule() {
    # Manage scheduled reports
    # Usage: nftban report schedule <enable|disable|status|daily|weekly|monthly|list|remove> [OPTIONS]

    local action="${1:-list}"

    case "$action" in
        enable)
            # v1.41.0: Enable systemd timer for report schedule
            shift
            nftban_report_schedule_timer_enable "${1:-daily}"
            ;;
        disable)
            # v1.41.0: Disable systemd timer
            shift
            nftban_report_schedule_timer_disable "${1:-daily}"
            ;;
        status)
            # v1.41.0: Show timer state
            nftban_report_schedule_timer_status
            ;;
        daily|weekly|monthly)
            shift
            nftban_report_schedule_add "$action" "$@"
            ;;
        list)
            nftban_report_schedule_list
            ;;
        remove)
            shift
            nftban_report_schedule_remove "$@"
            ;;
        *)
            echo "ERROR: Unknown schedule action: $action" >&2
            echo "Valid actions: enable, disable, status, daily, weekly, monthly, list, remove" >&2
            return 1
            ;;
    esac
}

# v1.41.0: Systemd timer management for scheduled reports

nftban_report_schedule_timer_enable() {
    local frequency="${1:-daily}"

    local timer_unit="nftban-report-${frequency}.timer"

    if ! systemctl list-unit-files "$timer_unit" &>/dev/null; then
        echo "ERROR: Timer unit $timer_unit not found" >&2
        echo "Only 'daily' timer is available in v1.41.0" >&2
        return 1
    fi

    echo "Enabling $timer_unit..."
    systemctl enable --now "$timer_unit" 2>/dev/null || {
        echo "ERROR: Failed to enable $timer_unit" >&2
        return 1
    }

    echo "Timer enabled. Next run:"
    systemctl list-timers "$timer_unit" --no-pager 2>/dev/null || true
    return 0
}

nftban_report_schedule_timer_disable() {
    local frequency="${1:-daily}"

    local timer_unit="nftban-report-${frequency}.timer"

    echo "Disabling $timer_unit..."
    systemctl disable --now "$timer_unit" 2>/dev/null || {
        echo "WARNING: Timer $timer_unit may not exist or already disabled" >&2
        return 0
    }

    echo "Timer disabled."
    return 0
}

nftban_report_schedule_timer_status() {
    echo "Report Timer Status:"
    echo "===================="

    local has_timer=false
    for freq in daily weekly monthly; do
        local timer_unit="nftban-report-${freq}.timer"
        if systemctl list-unit-files "$timer_unit" &>/dev/null 2>&1; then
            local state
            state=$(systemctl is-enabled "$timer_unit" 2>/dev/null || echo "not-found")
            local active
            active=$(systemctl is-active "$timer_unit" 2>/dev/null || echo "inactive")
            printf "  %-12s enabled=%-8s active=%s\n" "$freq:" "$state" "$active"
            has_timer=true
        fi
    done

    if ! $has_timer; then
        echo "  No report timers installed."
        echo "  Install timer units and run: nftban report schedule enable daily"
    fi

    echo ""
    echo "Active Timers:"
    systemctl list-timers "nftban-report-*" --no-pager 2>/dev/null || echo "  (none)"
    return 0
}

nftban_report_schedule_add() {
    # Add scheduled report
    local frequency="$1"
    shift

    local time="08:00"
    local day=""
    local email="${STATS_EMAIL_RECIPIENTS:-${NFTBAN_MAIL_RECIPIENT:-}}"

    # Fallback to panel admin email if not configured
    if [[ -z "$email" ]] && declare -f nftban_panel_get_admin_email &>/dev/null; then
        email=$(nftban_panel_get_admin_email 2>/dev/null) || true
    fi

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --time)
                time="$2"
                shift 2
                ;;
            --day)
                day="$2"
                shift 2
                ;;
            --email)
                # shellcheck disable=SC2034  # Reserved for email delivery
                email="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Creating ${frequency} scheduled report..."
    else
        echo "[INFO] Creating schedule..."
    fi

    # Create cron file
    mkdir -p "$(dirname "$NFTBAN_CRON_FILE")" || return 1

    # Parse time (HH:MM)
    local hour="${time%:*}"
    local minute="${time#*:}"

    # Build cron entry
    local cron_entry=""
    case "$frequency" in
        daily)
            cron_entry="${minute} ${hour} * * * root /usr/sbin/nftban report run daily"
            ;;
        weekly)
            local dow=1  # Monday
            case "${day,,}" in
                monday) dow=1 ;;
                tuesday) dow=2 ;;
                wednesday) dow=3 ;;
                thursday) dow=4 ;;
                friday) dow=5 ;;
                saturday) dow=6 ;;
                sunday) dow=0 ;;
            esac
            cron_entry="${minute} ${hour} * * ${dow} root /usr/sbin/nftban report run weekly"
            ;;
        monthly)
            local dom="${day:-1}"
            cron_entry="${minute} ${hour} ${dom} * * root /usr/sbin/nftban report run monthly"
            ;;
    esac

    # Create/update cron file
    {
        echo "# NFTBan Statistics Reports - Automated Scheduling"
        echo "# Generated: $(date)"
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
        echo ""

        # Add entry
        echo "# ${frequency^} report"
        echo "${cron_entry}"
        echo ""

        # Add other standard entries
        echo "# Hourly snapshot"
        echo "0 * * * * root ${NFTBAN_BIN:-/usr/sbin/nftban} stats snapshot >> ${NFTBAN_LOG_DIR:-/var/log/nftban}/cron.log 2>&1"
        echo ""
        echo "# Daily cleanup"
        echo "0 3 * * * root ${NFTBAN_BIN:-/usr/sbin/nftban} stats cleanup >> ${NFTBAN_LOG_DIR:-/var/log/nftban}/cron.log 2>&1"
    } > "$NFTBAN_CRON_FILE"

    chmod 644 "$NFTBAN_CRON_FILE"

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "${frequency^} report scheduled at ${time}"
    else
        echo "[SUCCESS] Schedule created: ${time}"
    fi
}

nftban_report_schedule_list() {
    # List scheduled reports
    if [[ ! -f "$NFTBAN_CRON_FILE" ]]; then
        echo "No scheduled reports configured"
        echo "Use: nftban report schedule daily --time \"08:00\""
        return 0
    fi

    echo "Scheduled Reports:"
    echo ""
    grep -E "^[0-9]" "$NFTBAN_CRON_FILE" | grep -v "^#" || echo "  (none configured)"
    echo ""
}

nftban_report_schedule_remove() {
    # Remove scheduled report
    local frequency="${1:-}"

    if [[ -z "$frequency" ]]; then
        echo "ERROR: Specify frequency to remove (daily, weekly, monthly, or all)" >&2
        return 1
    fi

    if [[ ! -f "$NFTBAN_CRON_FILE" ]]; then
        echo "No scheduled reports configured"
        return 0
    fi

    if [[ "$frequency" == "all" ]]; then
        rm -f "$NFTBAN_CRON_FILE"
        echo "All scheduled reports removed"
    else
        # Selective removal - remove only the specified frequency
        local pattern=""
        case "$frequency" in
            daily)
                pattern="nftban report run daily"
                ;;
            weekly)
                pattern="nftban report run weekly"
                ;;
            monthly)
                pattern="nftban report run monthly"
                ;;
            *)
                echo "ERROR: Invalid frequency: $frequency" >&2
                echo "Valid options: daily, weekly, monthly, all" >&2
                return 1
                ;;
        esac

        # Create temp file without the matching entries
        local temp_file
        temp_file=$(mktemp)
        # Ensure cleanup on exit/error
        trap 'rm -f "$temp_file" 2>/dev/null' EXIT

        # Remove matching cron entry and its comment line
        local skip_next=false
        while IFS= read -r line; do
            # Skip comment line for this frequency
            if [[ "$line" =~ ^#.*${frequency^}.*report ]]; then
                skip_next=true
                continue
            fi

            # Skip the actual cron entry
            if [[ "$line" == *"$pattern"* ]]; then
                skip_next=false
                continue
            fi

            # Skip blank line after removed entry
            if $skip_next && [[ -z "$line" ]]; then
                skip_next=false
                continue
            fi

            skip_next=false
            echo "$line"
        done < "$NFTBAN_CRON_FILE" > "$temp_file"

        # Check if anything remains besides headers
        local remaining_entries
        remaining_entries=$(grep -cE "^[0-9].*nftban report run" "$temp_file" 2>/dev/null || true)
        remaining_entries=${remaining_entries:-0}

        if [[ "$remaining_entries" -eq 0 ]]; then
            # No report entries left, but keep snapshot/cleanup
            local has_other
            has_other=$(grep -cE "^[0-9]" "$temp_file" 2>/dev/null || true)
            has_other=${has_other:-0}
            if [[ "$has_other" -eq 0 ]]; then
                rm -f "$NFTBAN_CRON_FILE" "$temp_file"
                echo "${frequency^} report removed (cron file cleaned up - no entries remaining)"
                return 0
            fi
        fi

        mv "$temp_file" "$NFTBAN_CRON_FILE"
        chmod 644 "$NFTBAN_CRON_FILE"
        echo "${frequency^} report schedule removed"
    fi
}

# =============================================================================

# SUBCOMMAND: RUN
# =============================================================================


nftban_report_cmd_run() {
    # Manually trigger scheduled report
    # Usage: nftban report run <daily|weekly|monthly>

    local frequency="${1:-daily}"

    local since until
    case "$frequency" in
        daily)
            since="$(date -d '1 day ago' +%Y-%m-%d)"
            until="$(date +%Y-%m-%d)"
            ;;
        weekly)
            since="$(date -d '7 days ago' +%Y-%m-%d)"
            until="$(date +%Y-%m-%d)"
            ;;
        monthly)
            since="$(date -d '30 days ago' +%Y-%m-%d)"
            until="$(date +%Y-%m-%d)"
            ;;
        *)
            echo "ERROR: Unknown frequency: $frequency" >&2
            return 1
            ;;
    esac

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "info" "Generating ${frequency} report..."
    else
        echo "[INFO] Generating ${frequency} report..."
    fi

    # Generate report
    local output_dir="${NFTBAN_REPORTS_DIR}/${frequency}"
    mkdir -p "$output_dir" || return 1

    local output_file
    output_file="${output_dir}/report-$(date +%Y%m%d).html"
    # v1.228.5 WRITER-TRUTH: this return code was DISCARDED. Combined with
    # SuccessExitStatus=0 1 on nftban-report-daily.service it produced the release-blocking
    # failure mode: SELinux denied the write, the report was 0 bytes, and systemd still
    # reported success. Report generation is the entire purpose of this command — if it
    # fails, the command fails, and the unit fails with it.
    if ! nftban_report_generate_html "$output_file" "$since" "$until" "${REPORTS_THEME:-dark}"; then
        echo "ERROR: ${frequency} report generation failed: $output_file" >&2
        return 1
    fi

    # Email if configured
    if [[ "${STATS_EMAIL_ENABLED,,}" =~ ^(yes|true|1|on)$ ]] && [[ -n "${STATS_EMAIL_RECIPIENTS:-}" ]]; then
        nftban_report_cmd_email "${STATS_EMAIL_RECIPIENTS}" --format html --since "$since" --until "$until"
    fi

    # Send login digest if mode is digest or both (only for daily reports)
    if [[ "$frequency" == "daily" ]]; then
        # Load login alert config
        local login_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf"
        local login_config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login_alert.conf.local"
        source "$login_config" 2>/dev/null || true
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "$login_config_local"

        local alert_mode="${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
        if [[ "$alert_mode" == "digest" ]] || [[ "$alert_mode" == "both" ]]; then
            # Load and call digest send function
            local login_alert_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_login_alert.sh"
            if [[ -f "$login_alert_lib" ]]; then
                source "$login_alert_lib" || return 1
                if type -t nftban_login_digest_send >/dev/null 2>&1; then
                    echo "[INFO] Sending login digest..."
                    nftban_login_digest_send
                fi
            fi
        fi
    fi
}

# =============================================================================

# SUBCOMMAND: LIST
# =============================================================================


nftban_report_cmd_list() {
    # List generated reports
    if [[ ! -d "$NFTBAN_REPORTS_DIR" ]]; then
        echo "No reports directory found"
        return 0
    fi

    echo "Generated Reports:"
    echo ""

    find "$NFTBAN_REPORTS_DIR" -type f -name "*.html" -o -name "*.json" -o -name "*.csv" | \
    sort -r | head -20 | \
    while read -r file; do
        local size
        size=$(du -h "$file" | cut -f1)
        local date
        date=$(stat -c %y "$file" | cut -d' ' -f1)
        printf "  [%s] %10s  %s\n" "$date" "$size" "$(basename "$file")"
    done

    echo ""
}

# =============================================================================

# SUBCOMMAND: STATUS
# =============================================================================

nftban_report_cmd_status() {
    # Show comprehensive report configuration status
    # Usage: nftban report status [--json]

    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1

    # Source mail config if available
    local mail_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"
    local mail_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf.local"
    [[ -f "$mail_conf" ]] && source "$mail_conf" 2>/dev/null || true
    _source_local "$mail_local"

    # Source stats config if available
    local stats_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/stats.conf"
    local stats_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/stats.conf.local"
    [[ -f "$stats_conf" ]] && source "$stats_conf" 2>/dev/null || true
    _source_local "$stats_local"

    if [[ $json_mode -eq 1 ]]; then
        _report_status_json
        return 0
    fi

    echo "=============================================================="
    echo "  NFTBan Report Configuration Status"
    echo "=============================================================="
    echo ""

    # ─────────────────────────────────────────────────────────────────
    # EMAIL DELIVERY
    # ─────────────────────────────────────────────────────────────────
    echo "EMAIL DELIVERY"
    echo "--------------------------------------------------------------"

    local mail_enabled="${MAIL_ENABLED:-${NFTBAN_MAIL_ENABLED:-false}}"
    local mail_recipients="${STATS_EMAIL_RECIPIENTS:-${NFTBAN_MAIL_RECIPIENT:-}}"
    local mail_from="${MAIL_FROM:-${NFTBAN_MAIL_FROM:-nftban@$(hostname -f 2>/dev/null || hostname)}}"
    local mail_cmd=""

    # Detect mail command
    if command -v msmtp &>/dev/null; then
        mail_cmd="msmtp"
    elif command -v sendmail &>/dev/null; then
        mail_cmd="sendmail"
    elif command -v mailx &>/dev/null; then
        mail_cmd="mailx"
    elif command -v mail &>/dev/null; then
        mail_cmd="mail"
    else
        mail_cmd="NOT FOUND"
    fi

    if [[ "${mail_enabled,,}" =~ ^(yes|true|1|on)$ ]]; then
        printf "  %-20s %s\n" "Status.............." "ENABLED"
    else
        printf "  %-20s %s\n" "Status.............." "DISABLED"
    fi

    if [[ -n "$mail_recipients" ]]; then
        printf "  %-20s %s\n" "Recipients.........." "$mail_recipients"
    else
        # Try to detect from panel
        local panel_email=""
        if declare -f nftban_panel_get_admin_email &>/dev/null; then
            panel_email=$(nftban_panel_get_admin_email 2>/dev/null) || true
        fi
        if [[ -n "$panel_email" ]]; then
            printf "  %-20s %s\n" "Recipients.........." "(not configured)"
            printf "  %-20s %s\n" "Panel Admin Email..." "$panel_email (auto-detected)"
        else
            printf "  %-20s %s\n" "Recipients.........." "(not configured)"
        fi
    fi

    printf "  %-20s %s\n" "From Address........" "$mail_from"
    printf "  %-20s %s\n" "Mail Command........" "$mail_cmd"
    echo ""

    # ─────────────────────────────────────────────────────────────────
    # SCHEDULED REPORTS
    # ─────────────────────────────────────────────────────────────────
    echo "SCHEDULED REPORTS"
    echo "--------------------------------------------------------------"

    local cron_file="${NFTBAN_CRON_FILE:-/etc/cron.d/nftban-stats}"
    local has_schedules=0

    if [[ -f "$cron_file" ]]; then
        # Parse cron entries
        local daily_time="" weekly_time="" monthly_time=""

        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue

            if [[ "$line" =~ nftban.*report.*run.*daily ]]; then
                local min hour
                min=$(echo "$line" | awk '{print $1}')
                hour=$(echo "$line" | awk '{print $2}')
                # Use 10# to force decimal interpretation (avoid octal issues with 08, 09)
                daily_time=$(printf "%02d:%02d" "$((10#$hour))" "$((10#$min))")
                has_schedules=1
            elif [[ "$line" =~ nftban.*report.*run.*weekly ]]; then
                local min hour dow
                min=$(echo "$line" | awk '{print $1}')
                hour=$(echo "$line" | awk '{print $2}')
                dow=$(echo "$line" | awk '{print $5}')
                weekly_time=$(printf "%02d:%02d (day %s)" "$((10#$hour))" "$((10#$min))" "$dow")
                has_schedules=1
            elif [[ "$line" =~ nftban.*report.*run.*monthly ]]; then
                local min hour dom
                min=$(echo "$line" | awk '{print $1}')
                hour=$(echo "$line" | awk '{print $2}')
                dom=$(echo "$line" | awk '{print $3}')
                monthly_time=$(printf "%02d:%02d (day %s)" "$((10#$hour))" "$((10#$min))" "$dom")
                # shellcheck disable=SC2034  # Reserved for schedule validation
                has_schedules=1
            fi
        done < "$cron_file"

        if [[ -n "$daily_time" ]]; then
            printf "  %-20s %s\n" "Daily..............." "$daily_time"
        else
            printf "  %-20s %s\n" "Daily..............." "Not configured"
        fi

        if [[ -n "$weekly_time" ]]; then
            printf "  %-20s %s\n" "Weekly.............." "$weekly_time"
        else
            printf "  %-20s %s\n" "Weekly.............." "Not configured"
        fi

        if [[ -n "$monthly_time" ]]; then
            printf "  %-20s %s\n" "Monthly............." "$monthly_time"
        else
            printf "  %-20s %s\n" "Monthly............." "Not configured"
        fi
    else
        printf "  %-20s %s\n" "Daily..............." "Not configured"
        printf "  %-20s %s\n" "Weekly.............." "Not configured"
        printf "  %-20s %s\n" "Monthly............." "Not configured"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────
    # STORAGE
    # ─────────────────────────────────────────────────────────────────
    echo "STORAGE"
    echo "--------------------------------------------------------------"

    local reports_dir="${NFTBAN_REPORTS_DIR:-${NFTBAN_LOG_DIR:-/var/log/nftban}/reports}"
    printf "  %-20s %s\n" "Reports Directory..." "$reports_dir"

    if [[ -d "$reports_dir" ]]; then
        local report_count
        report_count=$(find "$reports_dir" -type f \( -name "*.html" -o -name "*.json" -o -name "*.csv" \) 2>/dev/null | wc -l)
        local total_size
        total_size=$(du -sh "$reports_dir" 2>/dev/null | awk '{print $1}' || echo "0")
        local last_report=""
        last_report=$(find "$reports_dir" -type f \( -name "*.html" -o -name "*.json" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

        printf "  %-20s %s\n" "Report Count........" "$report_count files"
        printf "  %-20s %s\n" "Total Size.........." "$total_size"

        if [[ -n "$last_report" ]]; then
            local last_date
            last_date=$(stat -c %y "$last_report" 2>/dev/null | cut -d' ' -f1)
            printf "  %-20s %s\n" "Last Report........." "$last_date ($(basename "$last_report"))"
        else
            printf "  %-20s %s\n" "Last Report........." "(none)"
        fi
    else
        printf "  %-20s %s\n" "Report Count........" "(directory not found)"
    fi
    echo ""

    # ─────────────────────────────────────────────────────────────────
    # QUICK COMMANDS
    # ─────────────────────────────────────────────────────────────────
    echo "=============================================================="
    echo "QUICK COMMANDS"
    echo "  nftban report generate            Generate report now"
    echo "  nftban report schedule daily      Set up daily schedule"
    echo "  nftban report email test          Send test email"
    echo "  nftban report list                List generated reports"
    echo "=============================================================="

    return 0
}

_report_status_json() {
    # JSON output for report status
    local mail_enabled_raw="${MAIL_ENABLED:-${NFTBAN_MAIL_ENABLED:-false}}"
    local mail_enabled=false
    [[ "${mail_enabled_raw,,}" =~ ^(yes|true|1|on)$ ]] && mail_enabled=true
    local mail_recipients="${STATS_EMAIL_RECIPIENTS:-${NFTBAN_MAIL_RECIPIENT:-}}"
    local reports_dir="${NFTBAN_REPORTS_DIR:-${NFTBAN_LOG_DIR:-/var/log/nftban}/reports}"
    local cron_file="${NFTBAN_CRON_FILE:-/etc/cron.d/nftban-stats}"

    local report_count=0
    [[ -d "$reports_dir" ]] && report_count=$(find "$reports_dir" -type f \( -name "*.html" -o -name "*.json" \) 2>/dev/null | wc -l)

    local has_daily=false has_weekly=false has_monthly=false
    if [[ -f "$cron_file" ]]; then
        grep -q "report.*run.*daily" "$cron_file" 2>/dev/null && has_daily=true
        grep -q "report.*run.*weekly" "$cron_file" 2>/dev/null && has_weekly=true
        grep -q "report.*run.*monthly" "$cron_file" 2>/dev/null && has_monthly=true
    fi

    cat <<EOF
{
  "email": {
    "enabled": $mail_enabled,
    "recipients": "$mail_recipients"
  },
  "schedules": {
    "daily": $has_daily,
    "weekly": $has_weekly,
    "monthly": $has_monthly
  },
  "storage": {
    "directory": "$reports_dir",
    "report_count": $report_count
  }
}
EOF
}

# =============================================================================

# HTML REPORT GENERATION (PLACEHOLDER)
# =============================================================================

nftban_report_generate_html() {
    # Generate HTML report using template with Chart.js
    local output="$1"
    local since="$2"
    local until="$3"
    local theme="${4:-dark}"

    # Default template ships under /usr/share; NFTBAN_REPORT_TEMPLATE overrides it for
    # testability (production default unchanged).
    local template="${NFTBAN_REPORT_TEMPLATE:-/usr/share/nftban/templates/reports/stats_dashboard.html}"

    if [[ ! -f "$template" ]]; then
        echo "ERROR: HTML template not found: $template" >&2
        return 1
    fi

    # v1.228.5 WRITER-TRUTH: the destination directory must exist before any temporary is
    # placed in it. mkdir -p is not enough on its own — it returns non-zero for a path that
    # already exists as something other than a directory, and it succeeds vacuously under a
    # concurrent create, so the -d test is the authority.
    local out_dir
    out_dir="$(dirname "$output")"
    if ! mkdir -p "$out_dir" 2>/dev/null && [[ ! -d "$out_dir" ]]; then
        echo "ERROR: Cannot create report directory: $out_dir" >&2
        return 1
    fi

    # v1.228.5 WRITER-TRUTH: temporaries live in the DESTINATION directory, never /tmp.
    # Two load-bearing reasons:
    #   1. rename(2) is atomic only WITHIN one filesystem. The unit sets PrivateTmp=true, so
    #      /tmp is a separate tmpfs mount; a /tmp temporary could not be renamed into
    #      /var/log at all, and any copy-based fallback reopens the torn-write window this
    #      change exists to close.
    #   2. It removes the tmp_t dependency outright. No SELinux grant is needed for a type
    #      the workflow no longer touches — a smaller policy, not a broader one.
    # The names carry NO .html/.json/.csv extension, so neither `report list` (which globs
    # those three) nor any logrotate pattern can adopt a half-written temporary as if it
    # were a published report.
    local temp_json temp_html
    temp_json=$(mktemp "${out_dir}/.nftban-report-json.XXXXXX" 2>/dev/null) || {
        echo "ERROR: Cannot create temporary JSON file in: $out_dir" >&2
        return 1
    }
    temp_html=$(mktemp "${out_dir}/.nftban-report-html.XXXXXX" 2>/dev/null) || {
        echo "ERROR: Cannot create temporary HTML file in: $out_dir" >&2
        rm -f "$temp_json" 2>/dev/null
        return 1
    }

    # Generate JSON data.
    # nftban_stats_export_json ends with `echo "$output_file"`, so its RETURN CODE reports
    # the echo, not the write — it cannot be trusted to detect a failed heredoc. The
    # produced artifact is therefore validated directly below.
    nftban_stats_export_json "$temp_json" "$since" "$until" &>/dev/null

    if [[ ! -s "$temp_json" ]]; then
        echo "ERROR: Statistics export produced no data: $temp_json" >&2
        rm -f "$temp_json" "$temp_html" 2>/dev/null
        return 1
    fi
    # Structural check when jq is available: a truncated write can still be non-empty.
    if command -v jq >/dev/null 2>&1 && ! jq -e . "$temp_json" >/dev/null 2>&1; then
        echo "ERROR: Statistics export is not valid JSON: $temp_json" >&2
        rm -f "$temp_json" "$temp_html" 2>/dev/null
        return 1
    fi

    # Read JSON data
    local json_data
    if ! json_data=$(cat "$temp_json"); then
        echo "ERROR: Cannot read generated statistics: $temp_json" >&2
        rm -f "$temp_json" "$temp_html" 2>/dev/null
        return 1
    fi

    # v1.227 MAIL-F4: this JSON is injected into a <script> block. jq escapes quotes for JSON
    # validity but does NOT neutralize characters the HTML parser acts on — a data value
    # containing </script> (or <!--, ]]>, U+2028/U+2029) breaks out of the <script> element
    # regardless of JS-string context, because the HTML tokenizer closes the tag on the literal
    # </script>. \u-escape the HTML-significant characters INSIDE the compact JSON: they only
    # occur inside string values, so this stays valid JSON and the browser decodes them back to
    # the same text (identical render). This is NOT HTML-entity escaping (&lt; etc. would corrupt
    # the JS). The replacement strings contain no <, >, or &, so escape order is immaterial.
    json_data="${json_data//&/\\u0026}"
    json_data="${json_data//</\\u003c}"
    json_data="${json_data//>/\\u003e}"
    json_data="${json_data//$'\u2028'/\\u2028}"
    json_data="${json_data//$'\u2029'/\\u2029}"

    # Inject data into template (replace the placeholder line).
    # v1.227 MAIL-F4: the prior `${html_content//… = {  …  }/… = ${json_data}}` form was fragile —
    # the literal `}` inside the substitution PATTERN prematurely closed bash's ${…} parse, so the
    # data was mis-injected and the document was malformed (delimiter/replacement text leaked). Use
    # awk keyed on the unique placeholder comment, with the (already \u-escaped) JSON passed via the
    # ENVIRONMENT so neither the shell nor awk performs escape processing on the \uXXXX sequences and
    # the JSON braces cannot perturb any brace parser.
    # v1.228.5 WRITER-TRUTH: awk writes STRAIGHT to the temporary file. The prior form
    # captured the whole document into a variable and then `echo "$html_content" > "$output"`
    # with no check at all — the defect this change closes. Redirecting here means the
    # shell's open(2)/write(2) failures land in awk's exit status, which IS checked.
    if ! NFTBAN_REPORT_JSON="$json_data" awk '
        /window\.__NFTBAN_DATA__ = \{.*Placeholder - will be replaced/ {
            print "window.__NFTBAN_DATA__ = " ENVIRON["NFTBAN_REPORT_JSON"]
            next
        }
        { print }
    ' "$template" > "$temp_html"; then
        echo "ERROR: Failed to render HTML report to: $temp_html" >&2
        rm -f "$temp_json" "$temp_html" 2>/dev/null
        return 1
    fi

    rm -f "$temp_json" 2>/dev/null

    # v1.228.5 WRITER-TRUTH: validate the ARTIFACT before publishing it. A zero-byte or
    # truncated document must never reach the destination — that is precisely what shipped
    # under Enforcing while the unit reported success. Three independent assertions:
    #   -s                     the write produced bytes at all (ENOSPC/EACCES/EROFS)
    #   __NFTBAN_DATA__        the data injection actually ran (not a bare template copy)
    #   </html>                the document is complete, not cut off mid-write
    if [[ ! -s "$temp_html" ]]; then
        echo "ERROR: Generated report is empty: $temp_html" >&2
        rm -f "$temp_html" 2>/dev/null
        return 1
    fi
    if ! grep -q 'window\.__NFTBAN_DATA__' "$temp_html"; then
        echo "ERROR: Generated report is missing its data section" >&2
        rm -f "$temp_html" 2>/dev/null
        return 1
    fi
    if ! grep -qi '</html>' "$temp_html"; then
        echo "ERROR: Generated report is truncated (no closing </html>)" >&2
        rm -f "$temp_html" 2>/dev/null
        return 1
    fi

    # v1.228.5 WRITER-TRUTH: publish atomically. Same directory, therefore same filesystem,
    # therefore rename(2) — a reader sees either the previous report or the complete new
    # one, never a partial document. A failure here leaves the PREVIOUS report intact and
    # is reported; it is never swallowed.
    if ! mv -f "$temp_html" "$output"; then
        echo "ERROR: Failed to publish report to: $output" >&2
        rm -f "$temp_html" 2>/dev/null
        return 1
    fi

    if type -t nftban_print_status >/dev/null 2>&1; then
        nftban_print_status "success" "HTML report generated: $output"
    else
        echo "[SUCCESS] Report: $output"
    fi

    echo "$output"
}

# =============================================================================

# HELP TEXT
# =============================================================================


nftban_report_cmd_help() {
    cat <<'EOF'
NFTBan Report Generation & Scheduling

USAGE:
    nftban report [COMMAND] [OPTIONS]

COMMANDS:
    status                 Show report configuration status (email, schedules, storage)
    generate               Generate report
    email <RECIPIENT>      Email report to recipient
    email-setup            Interactive email configuration wizard
    schedule               Manage scheduled reports (cron)
    run <FREQ>             Manually trigger scheduled report
    list                   List generated reports
    help                   Show this help message

GENERATE OPTIONS:
    --format FORMAT        Report format (html, json, csv, all)
    --output FILE          Output file path
    --since DATE           Start date (YYYY-MM-DD)
    --until DATE           End date (YYYY-MM-DD)
    --last PERIOD          Time window (7d, 30d)
    --theme THEME          HTML theme (dark, light)

EMAIL OPTIONS:
    --format FORMAT        Email format (html, text)
    --attach-csv           Attach CSV data
    --since DATE           Start date
    --until DATE           End date

SCHEDULE OPTIONS:
    daily --time HH:MM     Schedule daily report
    weekly --day DAY       Schedule weekly report
    monthly --day N        Schedule monthly report (day of month)
    list                   List scheduled reports
    remove <FREQ>          Remove scheduled report

EXAMPLES:
    # Check report configuration status
    nftban report status

    # Setup email configuration (interactive)
    nftban report email-setup

    # Generate HTML report (last 7 days)
    nftban report generate --format html

    # Generate all formats (last 30 days)
    nftban report generate --format all --last 30d

    # Email report
    nftban report email admin@example.com --attach-csv

    # Schedule daily report at 8 AM
    nftban report schedule daily --time "08:00"

    # Schedule weekly report (Monday 9 AM)
    nftban report schedule weekly --day Monday --time "09:00"

    # Schedule monthly report (1st of month, 10 AM)
    nftban report schedule monthly --day 1 --time "10:00"

    # List scheduled reports
    nftban report schedule list

    # Manually run daily report
    nftban report run daily

    # List generated reports
    nftban report list

CRON AUTOMATION:
    Scheduled reports are stored in: /etc/cron.d/nftban-stats
    Reports are saved to: /var/lib/nftban/reports/

CONFIGURATION:
    /etc/nftban/conf.d/stats.conf      Statistics configuration
    /etc/nftban/conf.d/mail.conf       Email configuration

For real-time statistics, see: nftban stats help
EOF
}

# =============================================================================

# EXPORTS
# =============================================================================


export -f nftban_cmd_report
export -f nftban_report_cmd_email_setup

# =============================================================================

# MODULE INITIALIZATION
# =============================================================================


# CLI module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Report CLI loaded"
fi
