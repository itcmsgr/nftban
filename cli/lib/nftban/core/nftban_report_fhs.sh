#!/usr/bin/env bash

# =============================================================================
# NFTBan v1.0.0 - FHS Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: FHS directory permissions and ownership audit
#
# meta:name="nftban_report_fhs"
# meta:type="core"
# meta:header="FHS Report Core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Audits NFTBan directory permissions and ownership against FHS standards"
# meta:input="Output format options"
# meta:output="FHS compliance reports (terminal, HTML, mail)"
#
# **Inventory & Requirements**
# meta:depends="bash,stat"
# meta:inventory.files=""
# meta:inventory.binaries="stat"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-15"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_FHS_DIRECTORIES=()  # key: path -> "expected_perms|expected_owner|expected_group|purpose"
declare -g -A NFTBAN_FHS_STATUS=()       # key: path -> "OK|ERROR|WARNING"
declare -g NFTBAN_FHS_TIMESTAMP
NFTBAN_FHS_TIMESTAMP="$(date --iso-8601=seconds)"
declare -g NFTBAN_FHS_OUTPUT_FORMAT="${NFTBAN_FHS_OUTPUT_FORMAT:-table}"

# Color symbols
if type -t nftban_render_banner >/dev/null 2>&1; then
    NFTBAN_FHS_SYM_OK="✔"
    NFTBAN_FHS_SYM_KO="✖"
    NFTBAN_FHS_SYM_WARN="⚠"
else
    NFTBAN_FHS_SYM_OK="✔"
    NFTBAN_FHS_SYM_KO="✖"
    NFTBAN_FHS_SYM_WARN="⚠"
    C_RESET="\e[0m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    C_BOLD="\e[1m"
fi

# =============================================================================
# FHS DIRECTORY DEFINITIONS
# =============================================================================

nftban_fhs_define_directories() {
    # Load canonical FHS specification from single source of truth
    # IMPORTANT: Do NOT define directories here - use nftban_fhs_spec.sh

    if ! declare -f nftban_fhs_load_spec >/dev/null 2>&1; then
        source /usr/lib/nftban/core/nftban_fhs_spec.sh || {
            echo "ERROR: Failed to load canonical FHS specification" >&2
            return 1
        }
    fi

    # Ensure spec is loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_fhs_trim() {
    local s="${*-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

nftban_fhs_get_perms() {
    # Get octal permissions for a path
    # Args: $1 = path
    # Output: octal permissions (e.g., "755") or empty if not exists

    local path="$1"
    [[ ! -e "$path" ]] && return 1

    stat -c "%a" "$path" 2>/dev/null || stat -f "%Op" "$path" 2>/dev/null | tail -c 4
}

nftban_fhs_get_owner() {
    # Get owner for a path
    # Args: $1 = path
    # Output: owner name or empty if not exists

    local path="$1"
    [[ ! -e "$path" ]] && return 1

    stat -c "%U" "$path" 2>/dev/null || stat -f "%Su" "$path" 2>/dev/null
}

nftban_fhs_get_group() {
    # Get group for a path
    # Args: $1 = path
    # Output: group name or empty if not exists

    local path="$1"
    [[ ! -e "$path" ]] && return 1

    stat -c "%G" "$path" 2>/dev/null || stat -f "%Sg" "$path" 2>/dev/null
}

# =============================================================================
# FHS CHECKING FUNCTIONS
# =============================================================================

nftban_fhs_check_directory() {
    # Check a single directory against expected values
    # Args: $1 = path
    # Populates: NFTBAN_FHS_STATUS

    local path="$1"
    local expected="${NFTBAN_FHS_DIRECTORIES[$path]}"

    IFS='|' read -r exp_perms exp_owner exp_group purpose <<< "$expected"

    # Check if directory exists
    if [[ ! -e "$path" ]]; then
        NFTBAN_FHS_STATUS["$path"]="MISSING"
        return 1
    fi

    # Check if it's a directory
    if [[ ! -d "$path" ]]; then
        NFTBAN_FHS_STATUS["$path"]="NOT_DIR"
        return 1
    fi

    # Get actual values
    local act_perms act_owner act_group
    act_perms="$(nftban_fhs_get_perms "$path")"
    act_owner="$(nftban_fhs_get_owner "$path")"
    act_group="$(nftban_fhs_get_group "$path")"

    # Compare
    local issues=()
    # Skip permission check if expected is "*" (OS-managed directory)
    # Normalize permissions: strip leading zeros for comparison (0750 vs 750)
    local exp_perms_normalized="${exp_perms#0}"
    local act_perms_normalized="${act_perms#0}"
    [[ "$exp_perms" != "*" && "$act_perms_normalized" != "$exp_perms_normalized" ]] && issues+=("perms")
    # v1.24.1: Accept nftban/root as owner when expected user doesn't exist on system
    if [[ "$act_owner" != "$exp_owner" ]]; then
        if ! id "$exp_owner" &>/dev/null && [[ "$act_owner" == "nftban" || "$act_owner" == "root" ]]; then
            : # acceptable fallback owner
        else
            issues+=("owner")
        fi
    fi
    [[ "$act_group" != "$exp_group" ]] && issues+=("group")

    if [[ ${#issues[@]} -eq 0 ]]; then
        NFTBAN_FHS_STATUS["$path"]="OK"
    else
        # Join issues with commas (save/restore IFS to avoid newline issues)
        local old_ifs="$IFS"
        IFS=","
        NFTBAN_FHS_STATUS["$path"]="ERROR:${issues[*]}"
        IFS="$old_ifs"
    fi
}

nftban_fhs_check_all() {
    # Check all defined directories

    nftban_fhs_define_directories

    local path
    for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        # Ignore return value - missing/incorrect directories are tracked in NFTBAN_FHS_STATUS
        nftban_fhs_check_directory "$path" || true
    done
}

# =============================================================================
# REPORT RENDERING FUNCTIONS
# =============================================================================

nftban_fhs_render_table() {
    # Render FHS audit report as terminal table

    if [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "table" ]]; then
        echo
        echo "════════════════════════════════════════════════════════════════════════════════════"
        printf "%s FHS Compliance Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_FHS_TIMESTAMP" "${C_RESET:-}"
        echo "════════════════════════════════════════════════════════════════════════════════════"
        printf "%-40s %-18s %-18s %-10s %s\n" \
            "DIRECTORY" "EXPECTED" "ACTUAL" "STATUS" "NOTES"
        echo "------------------------------------------------------------------------------------"
    elif [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "md" ]]; then
        echo "| DIRECTORY | EXPECTED | ACTUAL | STATUS | NOTES |"
        echo "|:---|:---|:---|:---:|:---|"
    elif [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "csv" ]]; then
        echo "DIRECTORY,EXPECTED,ACTUAL,STATUS,NOTES"
    fi

    # Sort paths - use mapfile which is more reliable with strict mode
    local -a sorted_paths=()
    local path

    # First collect all paths
    local -a temp_paths=()
    for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        temp_paths+=("$path")
    done

    # Sort using mapfile (readarray)
    mapfile -t sorted_paths < <(printf '%s\n' "${temp_paths[@]}" | sort)

    local ok_count=0 error_count=0 missing_count=0

    for path in "${sorted_paths[@]}"; do
        local expected="${NFTBAN_FHS_DIRECTORIES[$path]}"
        local status="${NFTBAN_FHS_STATUS[$path]:-UNKNOWN}"

        IFS='|' read -r exp_perms exp_owner exp_group purpose <<< "$expected"

        local exp_str="${exp_perms} ${exp_owner}:${exp_group}"
        local act_str notes=""

        if [[ "$status" == "MISSING" ]]; then
            act_str="(not found)"
            notes="Directory does not exist"
            missing_count=$((missing_count + 1))
        elif [[ "$status" == "NOT_DIR" ]]; then
            act_str="(not a directory)"
            notes="Path exists but is not a directory"
            error_count=$((error_count + 1))
        elif [[ "$status" == "OK" ]]; then
            local act_perms act_owner act_group
            act_perms="$(nftban_fhs_get_perms "$path")"
            act_owner="$(nftban_fhs_get_owner "$path")"
            act_group="$(nftban_fhs_get_group "$path")"
            act_str="${act_perms} ${act_owner}:${act_group}"
            notes="$purpose"
            ok_count=$((ok_count + 1))
        else
            # ERROR with issues
            local act_perms act_owner act_group
            act_perms="$(nftban_fhs_get_perms "$path")"
            act_owner="$(nftban_fhs_get_owner "$path")"
            act_group="$(nftban_fhs_get_group "$path")"
            act_str="${act_perms} ${act_owner}:${act_group}"
            notes="${status#ERROR:}"
            notes="Mismatch: ${notes// /, }"
            error_count=$((error_count + 1))
        fi

        # Render row
        if [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "table" ]]; then
            local status_badge
            if [[ "$status" == "OK" ]]; then
                status_badge="${C_GREEN:-}${NFTBAN_FHS_SYM_OK}${C_RESET:-} OK"
            elif [[ "$status" == "MISSING" ]]; then
                status_badge="${C_YELLOW:-}${NFTBAN_FHS_SYM_WARN}${C_RESET:-} MISSING"
            else
                status_badge="${C_RED:-}${NFTBAN_FHS_SYM_KO}${C_RESET:-} ERROR"
            fi

            printf "%-40s %-18s %-18s %-10s %s\n" \
                "${path:0:39}" \
                "${exp_str:0:17}" \
                "${act_str:0:17}" \
                "$status_badge" \
                "$notes"

        elif [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "md" ]]; then
            printf "| %s | %s | %s | %s | %s |\n" \
                "$path" "$exp_str" "$act_str" "$status" "$notes"

        else # csv
            printf "%s,%s,%s,%s,%s\n" \
                "\"$path\"" "\"$exp_str\"" "\"$act_str\"" "$status" "\"$notes\""
        fi
    done

    if [[ "$NFTBAN_FHS_OUTPUT_FORMAT" == "table" ]]; then
        echo
        local total="${#NFTBAN_FHS_DIRECTORIES[@]}"
        echo "Total directories: $total | ${C_GREEN:-}OK: $ok_count${C_RESET:-} | ${C_RED:-}Errors: $error_count${C_RESET:-} | ${C_YELLOW:-}Missing: $missing_count${C_RESET:-}"
        echo
        if (( error_count > 0 || missing_count > 0 )); then
            echo "${C_YELLOW:-}${NFTBAN_FHS_SYM_WARN}${C_RESET:-} FHS compliance issues detected. Review errors above."
            echo
        fi
    fi
}

# =============================================================================
# HTML REPORT GENERATION
# =============================================================================

nftban_fhs_generate_html_report() {
    # Generate HTML report from FHS data
    # Returns: Path to generated HTML file

    local template_path="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates}/reports/fhs_report.html"
    local report_dir="${NFTBAN_REPORT_DIR:-/var/lib/nftban/reports}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="${report_dir}/fhs_report_${timestamp}.html"

    # Ensure report directory exists
    mkdir -p "$report_dir" 2>/dev/null || true

    # Check if template exists
    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template not found: $template_path" >&2
        return 1
    fi

    # Check directories if not already checked
    if [[ ${#NFTBAN_FHS_STATUS[@]} -eq 0 ]]; then
        nftban_fhs_check_all
    fi

    # Calculate statistics
    local total_directories=${#NFTBAN_FHS_DIRECTORIES[@]}
    local ok_directories=0
    local error_directories=0
    local missing_directories=0

    for path in "${!NFTBAN_FHS_STATUS[@]}"; do
        local status="${NFTBAN_FHS_STATUS[$path]}"
        if [[ "$status" == "OK" ]]; then
            ok_directories=$((ok_directories + 1))
        elif [[ "$status" == "MISSING" ]]; then
            missing_directories=$((missing_directories + 1))
        else
            error_directories=$((error_directories + 1))
        fi
    done

    # Generate compliance alert
    local compliance_alert=""
    if (( error_directories > 0 || missing_directories > 0 )); then
        compliance_alert='<div class="alert alert-danger">
            <strong>⚠ FHS Compliance Issues Detected!</strong><br>
            Found '"$error_directories"' permission/ownership errors and '"$missing_directories"' missing directories. Please review and fix the issues below.
        </div>'
    else
        compliance_alert='<div class="alert alert-success">
            <strong>✓ FHS Compliance Verified!</strong><br>
            All NFTBan directories have correct permissions and ownership.
        </div>'
    fi

    # Generate HTML table rows
    local table_rows=""
    for path in $(printf '%s\n' "${!NFTBAN_FHS_DIRECTORIES[@]}" | sort); do
        local expected="${NFTBAN_FHS_DIRECTORIES[$path]}"
        local actual="${NFTBAN_FHS_ACTUAL[$path]:-N/A}"
        local status="${NFTBAN_FHS_STATUS[$path]}"

        # Status badge and row class
        local status_badge
        local row_class=""
        if [[ "$status" == "OK" ]]; then
            status_badge="<span class=\"badge badge-ok\">✔ OK</span>"
        elif [[ "$status" == "MISSING" ]]; then
            status_badge="<span class=\"badge badge-missing\">⚠ MISSING</span>"
            row_class=' class="error-row"'
        else
            status_badge="<span class=\"badge badge-error\">✖ ERROR</span>"
            row_class=' class="error-row"'
            # Extract issues from status
            # shellcheck disable=SC2178,SC2128  # Intentional string from array
            local issues="${status#ERROR:}"
        fi

        table_rows+="                <tr${row_class}>
                    <td class=\"path-text\">${path}</td>
                    <td class=\"perm-text\">${expected}</td>
                    <td class=\"perm-text\">${actual}</td>
                    <td>${status_badge}</td>
                    <td>${issues:-—}</td>
                </tr>
"
    done

    # Generate recommendations section
    local recommendations_section=""
    if (( error_directories > 0 || missing_directories > 0 )); then
        recommendations_section='<h2>🔧 Recommendations</h2>
        <div class="alert alert-info">
            <strong>To fix permission issues:</strong><br>
            <code>nftban fhs fix</code> - Automatically fix all permission issues (coming soon)<br>
            <br>
            <strong>Manual fix commands:</strong>'

        for path in $(printf '%s\n' "${!NFTBAN_FHS_STATUS[@]}" | sort); do
            local status="${NFTBAN_FHS_STATUS[$path]}"
            if [[ "$status" != "OK" && "$status" != "MISSING" ]]; then
                local expected="${NFTBAN_FHS_DIRECTORIES[$path]}"
                IFS=' ' read -r perms owner_group <<< "$expected"
                recommendations_section+="<br><code>chmod ${perms} ${path} && chown ${owner_group} ${path}</code>"
            fi
        done

        recommendations_section+='
        </div>'
    fi

    # Read template
    local html_content
    html_content=$(cat "$template_path")

    # Get system info
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    local current_date
    current_date=$(date +%Y-%m-%d)
    local current_time
    current_time=$(date +%H:%M:%S)

    # Substitute placeholders
    html_content="${html_content//\{HOSTNAME\}/$hostname}"
    html_content="${html_content//\{SERVER_IP\}/$server_ip}"
    html_content="${html_content//\{DATE\}/$current_date}"
    html_content="${html_content//\{TIME\}/$current_time}"
    html_content="${html_content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-unknown}}"
    html_content="${html_content//\{COMPANY_NAME\}/${NFTBAN_COMPANY_NAME:-}}"
    html_content="${html_content//\{LOGO_HTML\}/}"
    html_content="${html_content//\{VERSION_HTML\}/<p>Version: <strong>${NFTBAN_VERSION:-unknown}</strong></p>}"

    # Statistics
    html_content="${html_content//\{TOTAL_DIRECTORIES\}/$total_directories}"
    html_content="${html_content//\{OK_DIRECTORIES\}/$ok_directories}"
    html_content="${html_content//\{ERROR_DIRECTORIES\}/$error_directories}"
    html_content="${html_content//\{MISSING_DIRECTORIES\}/$missing_directories}"

    # Alerts and sections
    html_content="${html_content//\{COMPLIANCE_ALERT\}/$compliance_alert}"
    html_content="${html_content//\{RECOMMENDATIONS_SECTION\}/$recommendations_section}"

    # Table rows
    html_content="${html_content//\{FHS_TABLE_ROWS\}/$table_rows}"

    # Write HTML file
    echo "$html_content" > "$report_file"

    # Set permissions
    chmod 640 "$report_file" 2>/dev/null || true

    echo "$report_file"
}

# =============================================================================
# MAIN REPORT FUNCTION
# =============================================================================

nftban_fhs_report_status() {
    # Main function to generate FHS compliance report

    # Check all directories
    nftban_fhs_check_all

    # Render report
    nftban_fhs_render_table

    # Explicitly return success
    return 0
}

nftban_fhs_report_summary() {
    # Generate one-line summary of FHS compliance
    # Output: "FHS: 5 OK, 12 errors, 3 missing"
    # Returns: 0=OK, 1=Warning, 2=Error

    # Check all directories
    nftban_fhs_check_all

    local ok_count=0
    local error_count=0
    local missing_count=0

    for path in "${!NFTBAN_FHS_STATUS[@]}"; do
        local status="${NFTBAN_FHS_STATUS[$path]}"
        if [[ "$status" == "OK" ]]; then
            ok_count=$((ok_count + 1))
        elif [[ "$status" == "MISSING" ]]; then
            missing_count=$((missing_count + 1))
        else
            error_count=$((error_count + 1))
        fi
    done

    # Output summary
    if [[ $error_count -eq 0 && $missing_count -eq 0 ]]; then
        echo "FHS: $ok_count OK, 0 errors"
        return 0
    elif [[ $error_count -eq 0 ]]; then
        echo "FHS: $ok_count OK, $missing_count missing"
        return 1  # Warning - missing directories
    else
        echo "FHS: $ok_count OK, $error_count errors, $missing_count missing"
        return 2  # Error - permission/ownership issues
    fi
}

nftban_fhs_report_json() {
    # Generate JSON output of FHS compliance
    # Output: JSON object with FHS data

    # Check all directories
    nftban_fhs_check_all

    local ok_count=0
    local error_count=0
    local missing_count=0

    for path in "${!NFTBAN_FHS_STATUS[@]}"; do
        local status="${NFTBAN_FHS_STATUS[$path]}"
        if [[ "$status" == "OK" ]]; then
            ok_count=$((ok_count + 1))
        elif [[ "$status" == "MISSING" ]]; then
            missing_count=$((missing_count + 1))
        else
            error_count=$((error_count + 1))
        fi
    done

    echo "{"
    echo "  \"timestamp\": \"$NFTBAN_FHS_TIMESTAMP\","
    echo "  \"total\": ${#NFTBAN_FHS_DIRECTORIES[@]},"
    echo "  \"ok\": $ok_count,"
    echo "  \"errors\": $error_count,"
    echo "  \"missing\": $missing_count,"
    echo "  \"directories\": ["

    # Output directory array
    local first=true
    for path in $(printf '%s\n' "${!NFTBAN_FHS_DIRECTORIES[@]}" | sort); do
        local expected="${NFTBAN_FHS_DIRECTORIES[$path]}"
        local actual="${NFTBAN_FHS_ACTUAL[$path]:-}"
        local status="${NFTBAN_FHS_STATUS[$path]}"

        IFS='|' read -r exp_perms exp_owner exp_group purpose <<< "$expected"

        # Add comma separator
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        # Parse issues from status
        # shellcheck disable=SC2178  # Intentional string from array
        local issues=""
        if [[ "$status" =~ ^ERROR: ]]; then
            # shellcheck disable=SC2178  # Intentional string from array
            issues="${status#ERROR:}"
        fi

        # Output directory object
        echo "    {"
        echo "      \"path\": \"$path\","
        echo "      \"expected\": \"$expected\","
        echo "      \"actual\": \"$actual\","
        echo "      \"status\": \"${status%%:*}\","
        # shellcheck disable=SC2128  # issues is a string, not an array
        echo "      \"issues\": \"$issues\","
        echo "      \"purpose\": \"$purpose\""
        echo -n "    }"
    done

    echo ""
    echo "  ]"
    echo "}"

    return 0
}

# =============================================================================
# MODULE FOOTER
# =============================================================================

# Module loaded notification (only in debug mode)
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    if type -t nftban_module_loaded >/dev/null 2>&1; then
        nftban_module_loaded "nftban_report_fhs" "1.0.0" "FHS Report Core" "core" "bash,stat"
    fi
fi
