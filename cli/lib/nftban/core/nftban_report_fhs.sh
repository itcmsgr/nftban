#!/usr/bin/env bash

# =============================================================================
# NFTBan - FHS Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
# V131 PR-A CB-2 fix: NFTBAN_FHS_ACTUAL was referenced at lines :379 and :564
# (HTML + JSON reports) via `${NFTBAN_FHS_ACTUAL[$path]:-...}` BUT was never
# declared. Without `declare -A`, bash treats `[$path]` as arithmetic
# evaluation; when $path is e.g. "/etc/nftban", arithmetic fails with
# "syntax error: operand expected (error token is '/etc/nftban')" and crashes
# the report. The `:-` fallback never fires because the crash is at the array
# subscript step, not the value lookup. Adding the declaration makes the
# subscript an associative key (string), and the existing fallback handles
# the "not populated yet" case.
declare -g -A NFTBAN_FHS_ACTUAL=()       # key: path -> actual filesystem state ("perms|owner|group") or empty
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

    # v1.229.15: record what was actually observed. The HTML and JSON reports
    # read NFTBAN_FHS_ACTUAL[$path]; until now nothing ever wrote to it, so the
    # "Actual" column rendered the :-N/A fallback for every directory including
    # ones that had just been probed successfully. The declaration was added by
    # V131 PR-A CB-2 to stop a crash; it did not populate the data.
    # A directory that is MISSING or NOT_DIR returns above without reaching here,
    # so its N/A remains honest: not probed, rather than probed-and-unknown.
    NFTBAN_FHS_ACTUAL["$path"]="${act_perms}|${act_owner}|${act_group}"

    # Compare
    local issues=()
    # Skip permission check if expected is "*" (OS-managed directory)
    # Normalize permissions: strip leading zeros for comparison (0750 vs 750)
    local exp_perms_normalized="${exp_perms#0}"
    local act_perms_normalized="${act_perms#0}"
    [[ "$exp_perms" != "*" && "$act_perms_normalized" != "$exp_perms_normalized" ]] && issues+=("perms")
    # v1.24.1: Accept nftban/root as owner when expected user doesn't exist on system
    if [[ "$act_owner" != "$exp_owner" ]]; then
        # v1.229.15: `! id "$exp_owner"` is true both when the expected user does
        # not exist AND when `id` itself cannot run. Conflating them let a real
        # ownership mismatch register as OK whenever the probe tool was the thing
        # that failed. Absence of the tool is not absence of the user.
        if ! command -v id >/dev/null 2>&1; then
            issues+=("owner-unverifiable")
        elif ! id "$exp_owner" &>/dev/null && [[ "$act_owner" == "nftban" || "$act_owner" == "root" ]]; then
            : # expected user genuinely absent; nftban/root is an accepted fallback
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


# -----------------------------------------------------------------------------
# _nftban_report_esc <value> -- HTML-escape one interpolated value.
#
# All report HTML is built by shell string substitution, so nothing escapes by
# default and every interpolated field is a potential sink.
#
# ⛔ THIS MUST NOT FAIL OPEN. An earlier form of this helper delegated to
#    nftban_sanitize_html and silently returned the value UNESCAPED when
#    lib/validation.sh could not be sourced -- a missing dependency would have
#    quietly disabled escaping across every report. Escaping is done inline so it
#    cannot degrade, and report_generator_content_truth asserts this produces
#    output IDENTICAL to nftban_sanitize_html, so the two cannot drift apart.
#
# Order matters: & FIRST. Escaping it after the others would re-escape the
# ampersands they introduce and "<" would render as "&amp;lt;".
# -----------------------------------------------------------------------------
_nftban_report_esc() {
    local v="${1-}"
    # ⛔ THE BACKSLASHES ARE LOAD-BEARING. In bash 5.2+ an unescaped & in the
    # replacement of ${var//pat/repl} expands to the MATCHED TEXT, exactly as in
    # sed -- so "${v//</&lt;}" yields "<lt;", silently emitting a raw "<" into the
    # document while looking like it escapes. \& forces a literal ampersand and is
    # correct on older bash too. This is why the sed-based authority was written
    # the way it was; the equivalence assertion in the test binds the two forms.
    v="${v//&/\&amp;}"
    v="${v//</\&lt;}"
    v="${v//>/\&gt;}"
    v="${v//\"/\&quot;}"
    v="${v//\'/\&#39;}"
    printf '%s' "$v"
}

# -----------------------------------------------------------------------------
# _nftban_report_lit <varname>... -- make each named variable safe to use as the
# REPLACEMENT half of ${doc//placeholder/value}.
#
# ⛔ PRE-EXISTING DEFECT, not introduced by escaping. In bash 5.2+ an unescaped &
#    in the replacement expands to the MATCHED TEXT, so a value containing "&"
#    injects the PLACEHOLDER NAME into the operator's data. Measured at v1.229.14:
#    a module declaring depends="curl&jq" rendered as "curl{DEPENDENCY_SECTION}jq".
#    Any report value containing an ampersand has always corrupted the document.
#    HTML-escaping makes every escaped character produce an "&", so the fault goes
#    from occasional to constant -- it must be fixed alongside, not after.
# -----------------------------------------------------------------------------
_nftban_report_lit() {
    local _n
    for _n in "$@"; do
        local -n _ref="$_n"
        _ref="${_ref//&/\\&}"
    done
}

# -----------------------------------------------------------------------------
# _nftban_report_publish <report_file> <html_content> -- validate, then publish.
#
# Mirrors the discipline cmd_report.sh already documents, which was the only
# generator that had it:
#
#   mktemp IN THE DESTINATION DIRECTORY  rename(2) is atomic only within one
#                                        filesystem, and an unpredictable name
#                                        cannot be pre-created as a symlink in a
#                                        directory writable by the nftban user
#   chmod BEFORE publish                 mktemp creates 0600; the previous
#                                        `echo >` form produced 0640 under this
#                                        file's umask 027. Setting the mode
#                                        explicitly keeps publication from
#                                        depending on how the temporary happened
#                                        to be created.
#   VALIDATE BEFORE RENAME               success must mean the document is
#                                        semantically complete, not that a file
#                                        appeared. `[[ -f ]]` is what let three
#                                        generators ship wrong content for
#                                        releases.
#
# On any failure the temporary is removed and the PREVIOUS report is left intact:
# a stale-but-valid report beats a truncated one presented as current.
# -----------------------------------------------------------------------------
_nftban_report_publish() {
    local report_file="$1" content="$2"
    local report_dir; report_dir="$(dirname "$report_file")"
    local tmp
    tmp="$(mktemp "${report_dir}/.nftban-report.XXXXXX" 2>/dev/null)" || {
        echo "ERROR: cannot create a temporary in $report_dir" >&2
        return 1
    }
    chmod 0640 "$tmp" 2>/dev/null || { rm -f "$tmp"; echo "ERROR: cannot set mode on $tmp" >&2; return 1; }
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; echo "ERROR: write failed: $tmp" >&2; return 1; }

    [[ -s "$tmp" ]] || { rm -f "$tmp"; echo "ERROR: refusing to publish an empty report" >&2; return 1; }
    if grep -qE '\{[A-Z_][A-Z0-9_]*\}' "$tmp"; then
        echo "ERROR: refusing to publish, unresolved placeholder(s): $(grep -oE '\{[A-Z_][A-Z0-9_]*\}' "$tmp" | sort -u | tr '\n' ' ')" >&2
        rm -f "$tmp"; return 1
    fi
    grep -qi '</html>' "$tmp" || { rm -f "$tmp"; echo "ERROR: refusing to publish an unterminated document" >&2; return 1; }

    mv -f "$tmp" "$report_file" || { rm -f "$tmp"; echo "ERROR: publish failed: $report_file" >&2; return 1; }
    return 0
}

nftban_fhs_generate_html_report() {
    # Generate HTML report from FHS data
    # Returns: Path to generated HTML file

    local template_path="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates}/reports/fhs_report.html"
    local report_dir="${NFTBAN_REPORT_DIR:-/var/log/nftban/reports}"
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
        local expected_raw="${NFTBAN_FHS_DIRECTORIES[$path]}"
        local actual_raw="${NFTBAN_FHS_ACTUAL[$path]:-}"
        local status="${NFTBAN_FHS_STATUS[$path]}"

        # v1.229.15: render both columns in the same shape the terminal renderer
        # uses ("perms owner:group"). The HTML previously printed the raw stored
        # tuple, which for the expected column also carried the purpose text.
        local e_perms e_owner e_group
        IFS='|' read -r e_perms e_owner e_group _ <<< "$expected_raw"
        local expected="${e_perms} ${e_owner}:${e_group}"
        local actual="N/A"
        if [[ -n "$actual_raw" ]]; then
            local a_perms a_owner a_group
            IFS='|' read -r a_perms a_owner a_group <<< "$actual_raw"
            actual="${a_perms} ${a_owner}:${a_group}"
        fi

        # v1.229.15: issues is reset per row. It was assigned only inside the
        # ERROR branch but read on every row, so an OK row following an ERROR row
        # inherited and displayed the previous directory's issue list.
        local row_issues=""
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
            row_issues="${status#ERROR:}"
        fi

        # Lower reachability than the other two -- these originate from the shipped
        # spec and from stat(1) -- but escaped for the same reason: nothing in this
        # pipeline escapes by default, so an unescaped field is one spec edit away
        # from being a sink.
        local e_path e_expected e_actual e_issues
        e_path="$(_nftban_report_esc "$path")"
        e_expected="$(_nftban_report_esc "$expected")"
        e_actual="$(_nftban_report_esc "$actual")"
        e_issues="$(_nftban_report_esc "$row_issues")"

        table_rows+="                <tr${row_class}>
                    <td class=\"path-text\">${e_path}</td>
                    <td class=\"perm-text\">${e_expected}</td>
                    <td class=\"perm-text\">${e_actual}</td>
                    <td>${status_badge}</td>
                    <td>${e_issues:-—}</td>
                </tr>
"
    done

    # Generate recommendations section
    local recommendations_section=""
    if (( error_directories > 0 || missing_directories > 0 )); then
        recommendations_section='<h2>🔧 Recommendations</h2>
        <div class="alert alert-info">
            <strong>To fix permission issues:</strong><br>
            <code>nftban fhs fix</code> - Automatically fix all permission issues (planned for v2.x)<br>
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
    _nftban_report_lit table_rows hostname server_ip current_date current_time
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
    _nftban_report_publish "$report_file" "$html_content" || return 1

    # Set permissions
    # mode is set on the temporary before publish by _nftban_report_publish

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
