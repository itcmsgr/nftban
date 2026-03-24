#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Unified Reporting Engine
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unified reporting engine
#
# meta:name="nftban_report_engine"
# meta:type="core"
# meta:header="Unified Reporting Engine"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Centralized report generation system with multiple formats and destinations"
# meta:input="Report type, format selection, and destination parameters"
# meta:output="Reports in text, JSON, or HTML format to terminal, file, or email"
# meta:depends="nftban_health.sh,nftban_stats.sh,nftban_fhs_spec.sh"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

# Source timestamp library (with graceful fallback)
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

declare -g NFTBAN_REPORT_ENGINE_VERSION="1.0.0"
declare -g NFTBAN_REPORT_ENGINE_LOADED=false

# Report data structure
declare -gA NFTBAN_REPORT_DATA=()
declare -gA NFTBAN_REPORT_METADATA=()

# Default configuration
# shellcheck disable=SC2034  # Default report settings - reserved for future use
declare -g NFTBAN_REPORT_DEFAULT_FORMAT="text"
# shellcheck disable=SC2034  # Default report settings - reserved for future use
declare -g NFTBAN_REPORT_DEFAULT_MODE="detailed"

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_report_init() {
    # Initialize report engine and load dependencies
    # Usage: nftban_report_init
    # Returns: 0 on success, 1 on error

    if [[ "$NFTBAN_REPORT_ENGINE_LOADED" == "true" ]]; then
        return 0
    fi

    # Load base library if not already loaded
    if ! declare -f nftban_log >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_base.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_base.sh" || return 1
        fi
    fi

    # Initialize metadata with defaults
    NFTBAN_REPORT_METADATA["hostname"]="${NFTBAN_REPORT_METADATA[hostname]:-$(hostname -f 2>/dev/null || hostname)}"
    # Use library functions with fallback to raw date commands
    if declare -f nftban_timestamp >/dev/null 2>&1; then
        NFTBAN_REPORT_METADATA["timestamp"]="${NFTBAN_REPORT_METADATA[timestamp]:-$(nftban_timestamp)}"
    else
        NFTBAN_REPORT_METADATA["timestamp"]="${NFTBAN_REPORT_METADATA[timestamp]:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
    fi
    if declare -f nftban_timestamp_log >/dev/null 2>&1; then
        # Strip brackets from log format for display
        local ts_log
        ts_log=$(nftban_timestamp_log)
        NFTBAN_REPORT_METADATA["date_display"]="${NFTBAN_REPORT_METADATA[date_display]:-${ts_log:1:-1}}"
    else
        NFTBAN_REPORT_METADATA["date_display"]="${NFTBAN_REPORT_METADATA[date_display]:-$(date "+%Y-%m-%d %H:%M:%S")}"
    fi
    NFTBAN_REPORT_METADATA["title"]="${NFTBAN_REPORT_METADATA[title]:-NFTBan Report}"
    NFTBAN_REPORT_METADATA["sections"]="${NFTBAN_REPORT_METADATA[sections]:-health}"
    NFTBAN_REPORT_METADATA["format"]="${NFTBAN_REPORT_METADATA[format]:-text}"
    NFTBAN_REPORT_METADATA["mode"]="${NFTBAN_REPORT_METADATA[mode]:-detailed}"

    NFTBAN_REPORT_ENGINE_LOADED=true
    return 0
}

# =============================================================================
# MAIN REPORT GENERATOR
# =============================================================================

nftban_report_generate() {
    # Generate a report with specified sections, format, and output destination
    # Usage: nftban_report_generate SECTIONS FORMAT OUTPUT_FILE EMAIL [TITLE] [MODE]
    # Arguments:
    #   SECTIONS    - Comma-separated list: health,module,fhs,services,stats,all
    #   FORMAT      - Output format: text, json, html
    #   OUTPUT_FILE - File path to save (empty for stdout)
    #   EMAIL       - Email address to send (empty to skip)
    #   TITLE       - Optional report title
    #   MODE        - Optional mode: summary or detailed (default: detailed)
    # Returns: Exit code of worst section (0=OK, 1=WARNING, 2=ERROR)

    nftban_report_init

    local sections="${1:-health}"
    local format="${2:-text}"
    local output_file="${3:-}"
    local email="${4:-}"
    local title="${5:-NFTBan System Report}"
    local mode="${6:-detailed}"

    # Expand "all" to all sections
    if [[ "$sections" == "all" ]]; then
        sections="health,module,fhs,services,stats"
    fi

    # Store report configuration
    NFTBAN_REPORT_METADATA["title"]="$title"
    NFTBAN_REPORT_METADATA["sections"]="$sections"
    NFTBAN_REPORT_METADATA["format"]="$format"
    NFTBAN_REPORT_METADATA["mode"]="$mode"

    # Collect data from requested sections
    local overall_exit_code=0
    local exit_code=0

    IFS=',' read -ra section_array <<< "$sections"
    for section in "${section_array[@]}"; do
        section=$(echo "$section" | xargs)  # Trim whitespace

        case "$section" in
            health)
                nftban_report_collect_health "$mode" || exit_code=$?
                ;;
            module)
                nftban_report_collect_module "$mode" || exit_code=$?
                ;;
            fhs)
                nftban_report_collect_fhs "$mode" || exit_code=$?
                ;;
            services)
                nftban_report_collect_services "$mode" || exit_code=$?
                ;;
            stats)
                nftban_report_collect_stats "$mode" || exit_code=$?
                ;;
            *)
                echo "Warning: Unknown section '$section'" >&2
                continue
                ;;
        esac

        # Track worst exit code
        [[ $exit_code -gt $overall_exit_code ]] && overall_exit_code=$exit_code
    done

    # Render report in requested format
    local report_output=""
    case "$format" in
        text)
            report_output=$(nftban_report_render_text)
            ;;
        json)
            report_output=$(nftban_report_render_json)
            ;;
        html)
            report_output=$(nftban_report_render_html)
            ;;
        *)
            echo "Error: Unknown format '$format'" >&2
            return 1
            ;;
    esac

    # Output to requested destinations
    if [[ -n "$output_file" ]]; then
        nftban_report_save_file "$report_output" "$output_file" || return 1
    fi

    if [[ -n "$email" ]]; then
        nftban_report_send_email "$report_output" "$email" "$format" || return 1
    fi

    # If no file or email specified, output to stdout
    if [[ -z "$output_file" && -z "$email" ]]; then
        echo "$report_output"
    fi

    return $overall_exit_code
}

# =============================================================================
# DATA COLLECTION FUNCTIONS
# =============================================================================

nftban_report_collect_health() {
    # Collect health check data (with optional auto-heal)
    # Usage: nftban_report_collect_health MODE [AUTO_HEAL]
    # Arguments:
    #   MODE      - summary or detailed
    #   AUTO_HEAL - 0=check only, 1=auto-heal enabled (optional, default: 0)
    # Returns: Health check exit code (0=OK, 1=WARNING, 2=ERROR)

    local mode="${1:-detailed}"
    local auto_heal="${2:-0}"
    local exit_code=0
    local auto_heal_applied=0

    # Load health module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || return 1
    else
        NFTBAN_REPORT_DATA["health_error"]="Health module not found"
        return 2
    fi

    # Run health check (with auto-heal if requested)
    if [[ $auto_heal -eq 1 ]]; then
        # Capture output to count fixes
        local health_output
        health_output=$(nftban_health_check_all 1 2>&1) || exit_code=$?

        # Extract auto-heal info from output
        if echo "$health_output" | grep -q "Auto-heal complete"; then
            auto_heal_applied=$(echo "$health_output" | grep "Auto-heal complete" | sed 's/.*(\([0-9]*\).*/\1/' || echo 0)
            NFTBAN_REPORT_DATA["health_auto_heal_fixes"]="$auto_heal_applied"
            NFTBAN_REPORT_DATA["health_auto_heal_enabled"]="true"
        fi
    else
        # Standard check without auto-heal
        nftban_health_check_all 0 >/dev/null 2>&1 || exit_code=$?
        NFTBAN_REPORT_DATA["health_auto_heal_enabled"]="false"
    fi

    # Collect summary with auto-heal info
    local summary
    summary=$(nftban_health_render_summary 2>/dev/null || echo "Health check failed")

    # Append auto-heal info to summary if fixes were applied
    if [[ $auto_heal_applied -gt 0 ]]; then
        summary="$summary (auto-healed $auto_heal_applied issues)"
    fi

    NFTBAN_REPORT_DATA["health_summary"]="$summary"
    NFTBAN_REPORT_DATA["health_exit_code"]="$exit_code"

    # Determine status icon for reports
    case $exit_code in
        0) NFTBAN_REPORT_DATA["health_status"]="✅ HEALTHY" ;;
        1) NFTBAN_REPORT_DATA["health_status"]="⚠️  WARNING" ;;
        2) NFTBAN_REPORT_DATA["health_status"]="❌ ERROR" ;;
        *) NFTBAN_REPORT_DATA["health_status"]="❓ UNKNOWN" ;;
    esac

    # Collect detailed if requested
    if [[ "$mode" == "detailed" ]]; then
        NFTBAN_REPORT_DATA["health_detailed"]=$(nftban_health_render_terminal 2>/dev/null || echo "Detailed output unavailable")
    fi

    # Collect JSON data (enhanced with auto-heal info)
    local json_data
    json_data=$(nftban_health_render_json 2>/dev/null || echo "{}")

    # Add auto-heal info to JSON if present
    if [[ $auto_heal -eq 1 ]]; then
        json_data=$(echo "$json_data" | jq --arg fixes "$auto_heal_applied" \
            '. + {auto_heal_enabled: true, auto_heal_fixes_applied: ($fixes | tonumber)}' 2>/dev/null || echo "$json_data")
    fi

    NFTBAN_REPORT_DATA["health_json"]="$json_data"

    return $exit_code
}

nftban_report_collect_module() {
    # Collect module report data
    # Usage: nftban_report_collect_module MODE
    # Arguments: MODE - summary or detailed
    # Returns: Module check exit code (0=OK, 2=ERROR)

    local mode="${1:-detailed}"
    local exit_code=0

    # Load module report
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_report_module.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_report_module.sh" || return 1
    else
        NFTBAN_REPORT_DATA["module_error"]="Module report not found"
        return 2
    fi

    # Collect summary
    NFTBAN_REPORT_DATA["module_summary"]=$(nftban_module_report_summary 2>/dev/null || echo "Module check failed")
    exit_code=$?
    NFTBAN_REPORT_DATA["module_exit_code"]="$exit_code"

    # Collect detailed if requested
    if [[ "$mode" == "detailed" ]]; then
        NFTBAN_REPORT_DATA["module_detailed"]=$(nftban_module_report_detailed 2>/dev/null || echo "Detailed output unavailable")
    fi

    # Collect JSON data
    NFTBAN_REPORT_DATA["module_json"]=$(nftban_module_report_json 2>/dev/null || echo "{}")

    return $exit_code
}

nftban_report_collect_fhs() {
    # Collect FHS report data
    # Usage: nftban_report_collect_fhs MODE
    # Arguments: MODE - summary or detailed
    # Returns: FHS check exit code (0=OK, 1=WARNING, 2=ERROR)

    local mode="${1:-detailed}"
    local exit_code=0

    # Load FHS report
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_report_fhs.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_report_fhs.sh" || return 1
    else
        NFTBAN_REPORT_DATA["fhs_error"]="FHS report not found"
        return 2
    fi

    # Collect summary
    NFTBAN_REPORT_DATA["fhs_summary"]=$(nftban_fhs_report_summary 2>/dev/null || echo "FHS check failed")
    exit_code=$?
    NFTBAN_REPORT_DATA["fhs_exit_code"]="$exit_code"

    # Collect detailed if requested
    if [[ "$mode" == "detailed" ]]; then
        NFTBAN_REPORT_DATA["fhs_detailed"]=$(nftban_fhs_report_detailed 2>/dev/null || echo "Detailed output unavailable")
    fi

    # Collect JSON data
    NFTBAN_REPORT_DATA["fhs_json"]=$(nftban_fhs_report_json 2>/dev/null || echo "{}")

    return $exit_code
}

nftban_report_collect_services() {
    # Collect services report data
    # Usage: nftban_report_collect_services MODE
    # Arguments: MODE - summary or detailed
    # Returns: Services check exit code (0=OK, 1=WARNING, 2=ERROR)

    local mode="${1:-detailed}"
    local exit_code=0

    # Load services report
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_report_services.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_report_services.sh" || return 1
    else
        NFTBAN_REPORT_DATA["services_error"]="Services report not found"
        return 2
    fi

    # Collect summary
    NFTBAN_REPORT_DATA["services_summary"]=$(nftban_services_report_summary 2>/dev/null || echo "Services check failed")
    exit_code=$?
    NFTBAN_REPORT_DATA["services_exit_code"]="$exit_code"

    # Collect detailed if requested
    if [[ "$mode" == "detailed" ]]; then
        NFTBAN_REPORT_DATA["services_detailed"]=$(nftban_services_report_detailed 2>/dev/null || echo "Detailed output unavailable")
    fi

    # Collect JSON data
    NFTBAN_REPORT_DATA["services_json"]=$(nftban_services_report_json 2>/dev/null || echo "{}")

    return $exit_code
}

nftban_report_collect_stats() {
    # Collect stats dashboard data
    # Usage: nftban_report_collect_stats MODE
    # Arguments: MODE - summary or detailed (stats always shows summary)
    # Returns: 0 (stats has no error states)

    local mode="${1:-detailed}"

    # Load stats module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_stats.sh" || return 1
    else
        NFTBAN_REPORT_DATA["stats_error"]="Stats module not found"
        return 2
    fi

    # Collect stats data
    local active_bans
    local whitelist_count
    active_bans=$(nftban_stats_count_active_bans 2>/dev/null || echo 0)
    whitelist_count=$(nftban_stats_count_whitelist 2>/dev/null || echo 0)

    NFTBAN_REPORT_DATA["stats_active_bans"]="$active_bans"
    NFTBAN_REPORT_DATA["stats_whitelist"]="$whitelist_count"
    NFTBAN_REPORT_DATA["stats_summary"]="Active Bans: $active_bans, Whitelist: $whitelist_count"
    NFTBAN_REPORT_DATA["stats_exit_code"]="0"

    # Collect detailed dashboard if requested
    if [[ "$mode" == "detailed" ]]; then
        NFTBAN_REPORT_DATA["stats_detailed"]=$(nftban_stats_dashboard 2>/dev/null || echo "Stats dashboard unavailable")
    fi

    return 0
}

# =============================================================================
# TEXT RENDERER
# =============================================================================

nftban_report_render_text() {
    # Render report as plain text
    # Usage: nftban_report_render_text
    # Returns: Text report

    local output=""
    local sections="${NFTBAN_REPORT_METADATA[sections]}"
    local mode="${NFTBAN_REPORT_METADATA[mode]}"

    # Header
    output+="═══════════════════════════════════════════════════════════════\n"
    output+="  ${NFTBAN_REPORT_METADATA[title]:-NFTBan Report}\n"
    output+="═══════════════════════════════════════════════════════════════\n\n"
    output+="Hostname: ${NFTBAN_REPORT_METADATA[hostname]:-$(hostname)}\n"
    # Use library function with fallback for date display
    local _date_display
    if declare -f nftban_timestamp_log >/dev/null 2>&1; then
        local _ts_log
        _ts_log=$(nftban_timestamp_log)
        _date_display="${NFTBAN_REPORT_METADATA[date_display]:-${_ts_log:1:-1}}"
    else
        _date_display="${NFTBAN_REPORT_METADATA[date_display]:-$(date "+%Y-%m-%d %H:%M:%S")}"
    fi
    output+="Generated: ${_date_display}\n\n"

    # Sections
    IFS=',' read -ra section_array <<< "$sections"
    for section in "${section_array[@]}"; do
        section=$(echo "$section" | xargs)

        case "$section" in
            health)
                output+="[HEALTH]\n"
                if [[ -n "${NFTBAN_REPORT_DATA[health_summary]:-}" ]]; then
                    output+="${NFTBAN_REPORT_DATA[health_summary]}\n"
                    if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[health_detailed]:-}" ]]; then
                        output+="\n${NFTBAN_REPORT_DATA[health_detailed]}\n"
                    fi
                fi
                output+="\n"
                ;;
            module)
                output+="[MODULES]\n"
                if [[ -n "${NFTBAN_REPORT_DATA[module_summary]:-}" ]]; then
                    output+="${NFTBAN_REPORT_DATA[module_summary]}\n"
                    if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[module_detailed]:-}" ]]; then
                        output+="\n${NFTBAN_REPORT_DATA[module_detailed]}\n"
                    fi
                fi
                output+="\n"
                ;;
            fhs)
                output+="[FHS]\n"
                if [[ -n "${NFTBAN_REPORT_DATA[fhs_summary]:-}" ]]; then
                    output+="${NFTBAN_REPORT_DATA[fhs_summary]}\n"
                    if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[fhs_detailed]:-}" ]]; then
                        output+="\n${NFTBAN_REPORT_DATA[fhs_detailed]}\n"
                    fi
                fi
                output+="\n"
                ;;
            services)
                output+="[SERVICES]\n"
                if [[ -n "${NFTBAN_REPORT_DATA[services_summary]:-}" ]]; then
                    output+="${NFTBAN_REPORT_DATA[services_summary]}\n"
                    if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[services_detailed]:-}" ]]; then
                        output+="\n${NFTBAN_REPORT_DATA[services_detailed]}\n"
                    fi
                fi
                output+="\n"
                ;;
            stats)
                output+="[STATS]\n"
                if [[ -n "${NFTBAN_REPORT_DATA[stats_summary]:-}" ]]; then
                    output+="${NFTBAN_REPORT_DATA[stats_summary]}\n"
                    if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[stats_detailed]:-}" ]]; then
                        output+="\n${NFTBAN_REPORT_DATA[stats_detailed]}\n"
                    fi
                fi
                output+="\n"
                ;;
        esac
    done

    # Footer
    output+="═══════════════════════════════════════════════════════════════\n"
    output+="Generated with NFTBan v${NFTBAN_REPORT_ENGINE_VERSION}\n"
    output+="═══════════════════════════════════════════════════════════════\n"

    echo -e "$output"
}

# =============================================================================
# JSON RENDERER
# =============================================================================

nftban_report_render_json() {
    # Render report as JSON
    # Usage: nftban_report_render_json
    # Returns: JSON report

    local sections="${NFTBAN_REPORT_METADATA[sections]:-health}"

    echo "{"
    echo "  \"report\": {"
    echo "    \"hostname\": \"${NFTBAN_REPORT_METADATA[hostname]:-$(hostname)}\","
    # Use library function with fallback for timestamp
    local _json_timestamp
    if declare -f nftban_timestamp >/dev/null 2>&1; then
        _json_timestamp="${NFTBAN_REPORT_METADATA[timestamp]:-$(nftban_timestamp)}"
    else
        _json_timestamp="${NFTBAN_REPORT_METADATA[timestamp]:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
    fi
    echo "    \"timestamp\": \"${_json_timestamp}\","
    echo "    \"title\": \"${NFTBAN_REPORT_METADATA[title]:-NFTBan Report}\","
    echo "    \"format\": \"${NFTBAN_REPORT_METADATA[format]:-json}\","
    echo "    \"mode\": \"${NFTBAN_REPORT_METADATA[mode]:-detailed}\","
    echo "    \"sections\": \"$sections\","
    echo "    \"version\": \"$NFTBAN_REPORT_ENGINE_VERSION\""
    echo "  },"

    # Add section data
    local first_section=true
    IFS=',' read -ra section_array <<< "$sections"
    for section in "${section_array[@]}"; do
        section=$(echo "$section" | xargs)

        # Add comma before each section except the first
        if [[ "$first_section" == "false" ]]; then
            echo ","
        fi
        first_section=false

        # Output section JSON
        case "$section" in
            health|module|fhs|services)
                if [[ -n "${NFTBAN_REPORT_DATA[${section}_json]:-}" ]]; then
                    echo -n "  \"$section\": ${NFTBAN_REPORT_DATA[${section}_json]}"
                fi
                ;;
            stats)
                echo -n "  \"stats\": {"
                echo -n "\"active_bans\": ${NFTBAN_REPORT_DATA[stats_active_bans]:-0},"
                echo -n "\"whitelist_entries\": ${NFTBAN_REPORT_DATA[stats_whitelist]:-0}"
                echo -n "}"
                ;;
        esac
    done

    echo ""
    echo "}"
}

# =============================================================================
# HTML RENDERER
# =============================================================================

nftban_report_render_html() {
    # Render report as HTML
    # Usage: nftban_report_render_html
    # Returns: HTML report

    local sections="${NFTBAN_REPORT_METADATA[sections]}"
    local mode="${NFTBAN_REPORT_METADATA[mode]}"

    cat <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
EOF

    echo "    <title>${NFTBAN_REPORT_METADATA[title]} - ${NFTBAN_REPORT_METADATA[hostname]}</title>"

    cat <<'EOF'
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Courier New', Consolas, monospace; background: #1e1e1e; color: #d4d4d4; line-height: 1.6; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        .header { background: #2d2d30; padding: 25px; border-radius: 5px; margin-bottom: 20px; border-left: 4px solid #007acc; }
        .header h1 { color: #4ec9b0; font-size: 24px; margin-bottom: 15px; }
        .header .meta { color: #858585; font-size: 14px; }
        .section { background: #252526; margin: 15px 0; padding: 20px; border-radius: 5px; border-left: 4px solid #3c3c3c; }
        .section h2 { color: #dcdcaa; font-size: 18px; margin-bottom: 15px; padding-bottom: 10px; border-bottom: 1px solid #3c3c3c; }
        .status-ok { color: #4ec9b0; }
        .status-warning { color: #ce9178; }
        .status-error { color: #f48771; }
        .summary { font-size: 16px; padding: 10px; background: #1e1e1e; border-radius: 3px; margin-bottom: 15px; }
        pre { background: #1e1e1e; padding: 15px; border-radius: 3px; overflow-x: auto; font-size: 13px; line-height: 1.4; border: 1px solid #3c3c3c; }
        details { margin-top: 10px; }
        summary { cursor: pointer; color: #569cd6; padding: 8px; background: #1e1e1e; border-radius: 3px; user-select: none; }
        summary:hover { background: #2d2d30; }
        .footer { text-align: center; color: #858585; padding: 20px; margin-top: 20px; border-top: 1px solid #3c3c3c; font-size: 12px; }
        @media print { body { background: white; color: black; } .header, .section { border: 1px solid #ddd; } }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
EOF

    echo "            <h1>${NFTBAN_REPORT_METADATA[title]}</h1>"
    echo "            <div class=\"meta\">"
    echo "                <div><strong>Hostname:</strong> ${NFTBAN_REPORT_METADATA[hostname]}</div>"
    echo "                <div><strong>Generated:</strong> ${NFTBAN_REPORT_METADATA[date_display]}</div>"
    echo "            </div>"

    cat <<'EOF'
        </div>
EOF

    # Render sections
    IFS=',' read -ra section_array <<< "$sections"
    for section in "${section_array[@]}"; do
        section=$(echo "$section" | xargs)

        local section_title=""
        local status_class="status-ok"
        local exit_code=0

        case "$section" in
            health)
                section_title="Health Status"
                exit_code="${NFTBAN_REPORT_DATA[health_exit_code]:-0}"
                ;;
            module)
                section_title="Modules"
                exit_code="${NFTBAN_REPORT_DATA[module_exit_code]:-0}"
                ;;
            fhs)
                section_title="Filesystem Hierarchy (FHS)"
                exit_code="${NFTBAN_REPORT_DATA[fhs_exit_code]:-0}"
                ;;
            services)
                section_title="Services"
                exit_code="${NFTBAN_REPORT_DATA[services_exit_code]:-0}"
                ;;
            stats)
                section_title="Statistics"
                exit_code=0
                ;;
            *)
                continue
                ;;
        esac

        # Determine status class
        if [[ $exit_code -eq 2 ]]; then
            status_class="status-error"
        elif [[ $exit_code -eq 1 ]]; then
            status_class="status-warning"
        fi

        echo "        <div class=\"section\">"
        echo "            <h2>$section_title</h2>"

        # Summary
        if [[ -n "${NFTBAN_REPORT_DATA[${section}_summary]:-}" ]]; then
            echo "            <div class=\"summary $status_class\">"
            echo "                ${NFTBAN_REPORT_DATA[${section}_summary]}"
            echo "            </div>"
        fi

        # Detailed (collapsible)
        if [[ "$mode" == "detailed" && -n "${NFTBAN_REPORT_DATA[${section}_detailed]:-}" ]]; then
            echo "            <details>"
            echo "                <summary>Show Details</summary>"
            echo "                <pre>${NFTBAN_REPORT_DATA[${section}_detailed]}</pre>"
            echo "            </details>"
        fi

        echo "        </div>"
    done

    # Footer
    cat <<'EOF'
        <div class="footer">
EOF
    echo "            Generated with NFTBan v${NFTBAN_REPORT_ENGINE_VERSION}"
    cat <<'EOF'
        </div>
    </div>
</body>
</html>
EOF
}

# =============================================================================
# OUTPUT FUNCTIONS
# =============================================================================

nftban_report_save_file() {
    # Save report to file
    # Usage: nftban_report_save_file CONTENT FILE_PATH
    # Arguments:
    #   CONTENT   - Report content to save
    #   FILE_PATH - Destination file path
    # Returns: 0 on success, 1 on error

    local content="$1"
    local file_path="$2"

    # Validate path (prevent path traversal)
    if [[ "$file_path" =~ \.\. ]]; then
        echo "Error: Invalid file path (contains '..')" >&2
        return 1
    fi

    # Create directory if needed (atomic, avoids TOCTOU race)
    local dir
    dir=$(dirname "$file_path")
    mkdir -p "$dir" 2>/dev/null || {
        echo "Error: Cannot create directory '$dir'" >&2
        return 1
    }

    # Write file with secure permissions
    echo "$content" > "$file_path" || {
        echo "Error: Cannot write to '$file_path'" >&2
        return 1
    }

    chmod 600 "$file_path" 2>/dev/null || true

    echo "Report saved to: $file_path" >&2
    return 0
}

nftban_report_send_email() {
    # Send report via email
    # Usage: nftban_report_send_email CONTENT EMAIL FORMAT
    # Arguments:
    #   CONTENT - Report content
    #   EMAIL   - Recipient email address
    #   FORMAT  - Report format (text, html)
    # Returns: 0 on success, 1 on error

    local content="$1"
    local email="$2"
    local format="${3:-text}"

    # Validate email address (basic)
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid email address '$email'" >&2
        return 1
    fi

    # Check if mail command is available
    if ! command -v mail >/dev/null 2>&1; then
        echo "Error: 'mail' command not found. Please install mailx package." >&2
        return 1
    fi

    # Send email based on format (subject is embedded in content for nftban_mail_send)
    if [[ "$format" == "html" ]]; then
        # HTML email with MIME headers
        # HTML email via NFTBan unified mail mechanism
        nftban_mail_send "$content" "$email"
    else
        # Plain text email via NFTBan unified mail mechanism
        nftban_mail_send "$content" "$email"
    fi

    if [[ $? -eq 0 ]]; then
        echo "Report sent to: $email" >&2
        return 0
    else
        echo "Error: Failed to send email to '$email'" >&2
        return 1
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

# Export all public functions
export -f nftban_report_init
export -f nftban_report_generate
export -f nftban_report_collect_health
export -f nftban_report_collect_module
export -f nftban_report_collect_fhs
export -f nftban_report_collect_services
export -f nftban_report_collect_stats
export -f nftban_report_render_text
export -f nftban_report_render_json
export -f nftban_report_render_html
export -f nftban_report_save_file
export -f nftban_report_send_email

# Mark as loaded
NFTBAN_REPORT_ENGINE_LOADED=true
