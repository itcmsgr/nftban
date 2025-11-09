#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.22 - Report Generation & Scheduling CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for report generation and automated scheduling
#
# meta:name=cmd_report
# meta:type=cli
# meta:header=Report Generation CLI Handler
# meta:version=0.32.22
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI interface for report generation and automated scheduling
# meta:input=Report type, format, and scheduling parameters
# meta:output=Generated reports in text, JSON, or HTML format
#
# **Inventory & Requirements**
# meta:depends=nftban_stats.sh,nftban_report_engine.sh
#
# meta:created_date=2025-11-05
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
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
    if [[ -f "/usr/lib/nftban/core/nftban_stats.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_stats.sh" || {
            echo "ERROR: Failed to load stats core module" >&2
            return 1
        }
    fi
fi

# Load mail module if available
if [[ -f "/usr/lib/nftban/core/nftban_mail.sh" ]]; then
    source "/usr/lib/nftban/core/nftban_mail.sh" 2>/dev/null || true
fi

# Load path security module
if ! declare -f nftban_path_get_safe_output >/dev/null 2>&1; then
    if [[ -f "/usr/lib/nftban/core/nftban_path_security.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_path_security.sh" || {
            echo "ERROR: Failed to load path security module" >&2
            return 1
        }
    fi
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_CRON_FILE="/etc/cron.d/nftban-stats"
readonly NFTBAN_REPORTS_DIR="${STATS_REPORTS_DIR:-/var/lib/nftban/reports}"

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_report() {
    # Main report command handler
    # Usage: nftban report [subcommand] [options]

    local subcommand="${1:-help}"

    case "$subcommand" in
        help|--help|-h)
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
        echo "[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)" >&2
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
            nftban_report_generate_html "$safe_output" "$since" "$until" "$theme"
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
    local report_html="${temp_dir}/report.html"

    nftban_stats_export_json "$report_json" "$since" "$until" &>/dev/null

    if [[ "$attach_csv" == "true" ]]; then
        nftban_stats_export_csv "$report_csv" "$since" "$until" &>/dev/null
    fi

    # Send email
    local subject
    subject="${STATS_EMAIL_SUBJECT_PREFIX:-[NFTBan Stats]} Report - $(date +%Y-%m-%d)"

    if declare -f nftban_mail_send >/dev/null 2>&1; then
        # Use mail module
        local body
        body=$(cat <<EOF
NFTBan Statistics Report

Period: ${since} to ${until}
Generated: $(date)
Hostname: $(hostname)

See attached files for detailed statistics.

---
Automated by NFTBan v${NFTBAN_VERSION:-0.32.1}
EOF
)

        if [[ "$attach_csv" == "true" ]]; then
            nftban_mail_send "$recipient" "$subject" "$body" "$report_csv" || {
                echo "ERROR: Failed to send email" >&2
                rm -rf "$temp_dir"
                return 1
            }
        else
            nftban_mail_send "$recipient" "$subject" "$body" || {
                echo "ERROR: Failed to send email" >&2
                rm -rf "$temp_dir"
                return 1
            }
        fi

        if type -t nftban_print_status >/dev/null 2>&1; then
            nftban_print_status "success" "Report emailed to ${recipient}"
        else
            echo "[SUCCESS] Email sent to ${recipient}"
        fi
    else
        echo "ERROR: Mail module not available" >&2
        echo "Configure email in /etc/nftban/conf.d/mail.conf" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup
    rm -rf "$temp_dir"
}

# =============================================================================
# SUBCOMMAND: SCHEDULE
# =============================================================================

nftban_report_cmd_schedule() {
    # Manage scheduled reports
    # Usage: nftban report schedule <daily|weekly|monthly|list|remove> [OPTIONS]

    local action="${1:-list}"

    case "$action" in
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
            echo "Valid actions: daily, weekly, monthly, list, remove" >&2
            return 1
            ;;
    esac
}

nftban_report_schedule_add() {
    # Add scheduled report
    local frequency="$1"
    shift

    local time="08:00"
    local day=""
    local email="${STATS_EMAIL_RECIPIENTS:-${NFTBAN_MAIL_RECIPIENT:-}}"

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
    mkdir -p "$(dirname "$NFTBAN_CRON_FILE")"

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
        echo "0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1"
        echo ""
        echo "# Daily cleanup"
        echo "0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1"
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

    if [[ "$frequency" == "all" ]]; then
        rm -f "$NFTBAN_CRON_FILE"
        echo "All scheduled reports removed"
    else
        # TODO: Implement selective removal
        echo "Selective removal not yet implemented"
        echo "Use: rm /etc/cron.d/nftban-stats"
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
    mkdir -p "$output_dir"

    local output_file
    output_file="${output_dir}/report-$(date +%Y%m%d).html"
    nftban_report_generate_html "$output_file" "$since" "$until" "${REPORTS_THEME:-dark}"

    # Email if configured
    if [[ "${STATS_EMAIL_ENABLED}" == "true" ]] && [[ -n "${STATS_EMAIL_RECIPIENTS:-}" ]]; then
        nftban_report_cmd_email "${STATS_EMAIL_RECIPIENTS}" --format html --since "$since" --until "$until"
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
# HTML REPORT GENERATION (PLACEHOLDER)
# =============================================================================

nftban_report_generate_html() {
    # Generate HTML report using template with Chart.js
    local output="$1"
    local since="$2"
    local until="$3"
    local theme="${4:-dark}"

    local template="/usr/share/nftban/templates/reports/stats_dashboard.html"

    if [[ ! -f "$template" ]]; then
        echo "ERROR: HTML template not found: $template" >&2
        return 1
    fi

    # Generate JSON data
    local temp_json
    temp_json=$(mktemp)
    nftban_stats_export_json "$temp_json" "$since" "$until" &>/dev/null

    # Read template
    local html_content
    html_content=$(cat "$template")

    # Read JSON data
    local json_data
    json_data=$(cat "$temp_json")

    # Inject data into template (replace placeholder)
    html_content="${html_content//window.__NFTBAN_DATA__ = {            \/\/ Placeholder - will be replaced        }/window.__NFTBAN_DATA__ = ${json_data}}"

    # Write final HTML
    echo "$html_content" > "$output"

    rm -f "$temp_json"

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
    generate               Generate report
    email <RECIPIENT>      Email report to recipient
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

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

# CLI module loaded
if type -t nftban_print_status >/dev/null 2>&1; then
    nftban_print_status "debug" "Report CLI loaded"
fi
