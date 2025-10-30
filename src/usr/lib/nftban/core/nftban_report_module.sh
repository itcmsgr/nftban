#!/usr/bin/env bash

# =============================================================================
# NFTBan Module Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Module inventory scanning and reporting
#
# meta:name=nftban_report_module
# meta:type=core
# meta:header=Module Report Core
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Scans and inventories all NFTBan modules by meta tags
# meta:input=Module scan options, output format
# meta:output=Module inventory reports (terminal, HTML, mail)
#
# **Inventory & Requirements**
# meta:depends=bash,grep,sed
#
# meta:created_date=2025-10-26
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_MODULE_INVENTORY=()  # key: file_path -> "name|version|type|created|depends|owner"
declare -g NFTBAN_MODULE_TIMESTAMP="$(date --iso-8601=seconds)"
declare -g NFTBAN_MODULE_OUTPUT_FORMAT="${NFTBAN_MODULE_OUTPUT_FORMAT:-table}"

# Color symbols
if type -t nftban_render_banner >/dev/null 2>&1; then
    NFTBAN_MODULE_SYM_OK="✔"
    NFTBAN_MODULE_SYM_KO="✖"
else
    NFTBAN_MODULE_SYM_OK="✔"
    NFTBAN_MODULE_SYM_KO="✖"
    C_RESET="\e[0m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    C_BOLD="\e[1m"
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_module_trim() {
    local s="${*-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

nftban_module_extract_meta() {
    # Extract meta tag value from file
    # Args: $1 = file path, $2 = meta tag name
    # Output: meta tag value or empty string

    local file="$1"
    local tag="$2"

    grep -E "^#[[:space:]]*meta:${tag}=" "$file" 2>/dev/null | head -1 | sed -E "s/^#[[:space:]]*meta:${tag}=(.*)/\1/" | sed 's/^"//' | sed 's/"$//' || echo ""
}

# =============================================================================
# MODULE SCANNING FUNCTIONS
# =============================================================================

nftban_module_scan() {
    # Scan all shell scripts for meta tags
    # Populates: NFTBAN_MODULE_INVENTORY

    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

    # Find all .sh files in lib directory
    while IFS= read -r -d '' file; do
        # Skip if file doesn't exist or isn't readable
        [[ ! -r "$file" ]] && continue

        # Check if file has meta tags
        if ! grep -q "^#[[:space:]]*meta:" "$file" 2>/dev/null; then
            continue
        fi

        # Extract meta tags
        local name version module_type created depends owner homepage description
        name="$(nftban_module_extract_meta "$file" "name")"
        version="$(nftban_module_extract_meta "$file" "version")"
        module_type="$(nftban_module_extract_meta "$file" "type")"
        created="$(nftban_module_extract_meta "$file" "created_date")"
        depends="$(nftban_module_extract_meta "$file" "depends")"
        owner="$(nftban_module_extract_meta "$file" "owner")"
        homepage="$(nftban_module_extract_meta "$file" "homepage")"
        description="$(nftban_module_extract_meta "$file" "description")"

        # Skip if no name (invalid module)
        [[ -z "$name" ]] && continue

        # Store in inventory
        NFTBAN_MODULE_INVENTORY["$file"]="${name}|${version}|${module_type}|${created}|${depends}|${owner}|${homepage}|${description}"

    done < <(find "$lib_dir" -type f -name "*.sh" -print0 2>/dev/null || true)
}

nftban_module_check_enabled() {
    # Check if a module is enabled
    # Args: $1 = file path
    # Output: "ENABLED" or "DISABLED"

    local file="$1"

    # If file is executable, consider it enabled
    if [[ -x "$file" ]]; then
        echo "ENABLED"
        return 0
    fi

    # If file is in core/ or cli/, consider it enabled (sourced modules)
    if [[ "$file" =~ /core/ ]] || [[ "$file" =~ /cli/ ]]; then
        echo "ENABLED"
        return 0
    fi

    # Otherwise disabled
    echo "DISABLED"
}

# =============================================================================
# REPORT RENDERING FUNCTIONS
# =============================================================================

nftban_module_render_table() {
    # Render module inventory as terminal table
    # Uses: NFTBAN_MODULE_OUTPUT_FORMAT

    if [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "table" ]]; then
        echo
        echo "════════════════════════════════════════════════════════════════════════════════════"
        printf "%s Module Inventory Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
        echo "════════════════════════════════════════════════════════════════════════════════════"
        printf "%-25s %-10s %-8s %-10s %-12s %-40s\n" \
            "NAME" "VERSION" "TYPE" "STATUS" "CREATED" "PATH"
        echo "------------------------------------------------------------------------------------"
    elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "md" ]]; then
        echo "| NAME | VERSION | TYPE | STATUS | CREATED | PATH | DEPENDS |"
        echo "|:---|:---|:---:|:---:|:---|:---|:---|"
    elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "csv" ]]; then
        echo "NAME,VERSION,TYPE,STATUS,CREATED,PATH,DEPENDS"
    fi

    # Sort by module name
    local -a sorted_paths=()
    local file
    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        sorted_paths+=("$file")
    done

    # Sort by name (extract from inventory)
    IFS=$'\n' read -r -d '' -a sorted_paths < <(
        for file in "${sorted_paths[@]}"; do
            local data="${NFTBAN_MODULE_INVENTORY[$file]}"
            local name="${data%%|*}"
            echo "$name|$file"
        done | sort | cut -d'|' -f2 && printf '\0'
    ) || true

    local file
    for file in "${sorted_paths[@]}"; do
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"

        # Parse inventory data
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        # Get enabled status
        local status
        status="$(nftban_module_check_enabled "$file")"

        # Use full path
        local display_path="$file"

        # Render row
        if [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "table" ]]; then
            # Status badge
            local status_badge
            if [[ "$status" == "ENABLED" ]]; then
                status_badge="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-} ENABLED"
            else
                status_badge="${C_YELLOW:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-} DISABLED"
            fi

            printf "%-25s %-10s %-8s %-10s %-12s %s\n" \
                "${name:0:24}" \
                "${version:0:9}" \
                "${module_type:0:7}" \
                "$status_badge" \
                "${created:0:11}" \
                "$display_path"

        elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "md" ]]; then
            printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
                "$name" "$version" "$module_type" "$status" "$created" "$display_path" "$depends"

        else # csv
            printf "%s,%s,%s,%s,%s,%s,%s\n" \
                "$name" "$version" "$module_type" "$status" "$created" "\"$file\"" "\"$depends\""
        fi
    done

    if [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "table" ]]; then
        echo
        local total="${#NFTBAN_MODULE_INVENTORY[@]}"
        local enabled=0
        for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
            if [[ "$(nftban_module_check_enabled "$file")" == "ENABLED" ]]; then
                (( enabled++ ))
            fi
        done
        echo "Total modules: $total | Enabled: $enabled | Disabled: $((total - enabled))"
        echo
    fi
}

nftban_module_render_detailed() {
    # Render detailed module information

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s Module Details — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Sort by name
    local -a sorted_paths=()
    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        sorted_paths+=("$file")
    done

    IFS=$'\n' read -r -d '' -a sorted_paths < <(
        for file in "${sorted_paths[@]}"; do
            local data="${NFTBAN_MODULE_INVENTORY[$file]}"
            local name="${data%%|*}"
            echo "$name|$file"
        done | sort | cut -d'|' -f2 && printf '\0'
    ) || true

    for file in "${sorted_paths[@]}"; do
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        local status
        status="$(nftban_module_check_enabled "$file")"

        echo "Module: ${C_BOLD:-}$name${C_RESET:-}"
        echo "  Version:     $version"
        echo "  Type:        $module_type"
        echo "  Status:      $status"
        echo "  Created:     $created"
        echo "  Path:        $file"
        [[ -n "$depends" ]] && echo "  Depends:     $depends"
        [[ -n "$owner" ]] && echo "  Owner:       $owner"
        [[ -n "$homepage" ]] && echo "  Homepage:    $homepage"
        [[ -n "$description" ]] && echo "  Description: $description"
        echo
    done
}

# =============================================================================
# MAIN REPORT FUNCTION
# =============================================================================

# =============================================================================
# HTML REPORT GENERATION
# =============================================================================

nftban_module_generate_html_report() {
    # Generate HTML report from module data
    # Returns: Path to generated HTML file

    local template_path="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates}/reports/module_report.html"
    local report_dir="${NFTBAN_REPORT_DIR:-/var/lib/nftban/reports}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="${report_dir}/module_report_${timestamp}.html"

    # Ensure report directory exists
    mkdir -p "$report_dir" 2>/dev/null || true

    # Check if template exists
    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template not found: $template_path" >&2
        return 1
    fi

    # Scan modules if not already scanned
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    # Calculate statistics
    local total_modules=${#NFTBAN_MODULE_INVENTORY[@]}
    local enabled_modules=0
    local disabled_modules=0
    local core_modules=0

    for module_path in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        local info="${NFTBAN_MODULE_INVENTORY[$module_path]}"
        IFS='|' read -r name version type status created depends owner <<< "$info"

        [[ "$status" == "ENABLED" ]] && enabled_modules=$((enabled_modules + 1)) || disabled_modules=$((disabled_modules + 1))
        [[ "$type" == "core" ]] && core_modules=$((core_modules + 1)) || true
    done

    # Generate HTML table rows
    local table_rows=""
    for module_path in $(printf '%s\n' "${!NFTBAN_MODULE_INVENTORY[@]}" | sort); do
        local info="${NFTBAN_MODULE_INVENTORY[$module_path]}"
        IFS='|' read -r name version type status created depends owner <<< "$info"

        # Type badge
        local type_badge="<span class=\"badge badge-${type}\">${type}</span>"

        # Status badge
        local status_badge
        if [[ "$status" == "ENABLED" ]]; then
            status_badge="<span class=\"badge badge-enabled\">ENABLED</span>"
        else
            status_badge="<span class=\"badge badge-disabled\">DISABLED</span>"
        fi

        table_rows+="                <tr>
                    <td><strong>${name}</strong></td>
                    <td>${version}</td>
                    <td>${type_badge}</td>
                    <td>${status_badge}</td>
                    <td>${created:-N/A}</td>
                    <td class=\"path-text\">${module_path}</td>
                    <td>${depends:-none}</td>
                </tr>
"
    done

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
    html_content="${html_content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-0.10.0}}"
    html_content="${html_content//\{COMPANY_NAME\}/${NFTBAN_COMPANY_NAME:-}}"
    html_content="${html_content//\{LOGO_HTML\}/}"
    html_content="${html_content//\{VERSION_HTML\}/<p>Version: <strong>${NFTBAN_VERSION:-0.10.0}</strong></p>}"

    # Statistics
    html_content="${html_content//\{TOTAL_MODULES\}/$total_modules}"
    html_content="${html_content//\{ENABLED_MODULES\}/$enabled_modules}"
    html_content="${html_content//\{DISABLED_MODULES\}/$disabled_modules}"
    html_content="${html_content//\{CORE_MODULES\}/$core_modules}"

    # Table rows
    html_content="${html_content//\{MODULE_TABLE_ROWS\}/$table_rows}"

    # Dependency section (empty for now)
    html_content="${html_content//\{DEPENDENCY_SECTION\}/}"

    # Write HTML file
    echo "$html_content" > "$report_file"

    # Set permissions
    chmod 640 "$report_file" 2>/dev/null || true

    echo "$report_file"
}

nftban_module_report_status() {
    # Main function to generate module inventory report
    # Called by CLI handler

    # Scan modules
    nftban_module_scan

    # Render report
    nftban_module_render_table

    # Explicitly return success
    return 0
}

nftban_module_report_detailed() {
    # Generate detailed module report

    # Scan modules
    nftban_module_scan

    # Render detailed report
    nftban_module_render_detailed

    # Explicitly return success
    return 0
}

nftban_module_report_summary() {
    # Generate one-line summary of modules
    # Output: "Modules: 23 OK, 0 errors"
    # Returns: 0=OK, 1=Warning, 2=Error

    # Scan modules
    nftban_module_scan

    local total="${#NFTBAN_MODULE_INVENTORY[@]}"
    local enabled=0
    local disabled=0
    local errors=0

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        if [[ "$(nftban_module_check_enabled "$file")" == "ENABLED" ]]; then
            enabled=$((enabled + 1))
        else
            disabled=$((disabled + 1))
        fi

        # Check for errors (file not readable or doesn't exist)
        if [[ ! -r "$file" ]]; then
            errors=$((errors + 1))
        fi
    done

    # Output summary
    if [[ $errors -eq 0 && $disabled -eq 0 ]]; then
        echo "Modules: $total OK, 0 errors"
        return 0
    elif [[ $errors -eq 0 ]]; then
        echo "Modules: $enabled OK, $disabled disabled"
        return 1  # Warning - some disabled
    else
        echo "Modules: $enabled OK, $errors errors"
        return 2  # Error - unreadable files
    fi
}

nftban_module_report_json() {
    # Generate JSON output of module inventory
    # Output: JSON object with module data

    # Scan modules
    nftban_module_scan

    local total="${#NFTBAN_MODULE_INVENTORY[@]}"
    local enabled=0
    local disabled=0

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        if [[ "$(nftban_module_check_enabled "$file")" == "ENABLED" ]]; then
            enabled=$((enabled + 1))
        else
            disabled=$((disabled + 1))
        fi
    done

    echo "{"
    echo "  \"timestamp\": \"$NFTBAN_MODULE_TIMESTAMP\","
    echo "  \"total\": $total,"
    echo "  \"enabled\": $enabled,"
    echo "  \"disabled\": $disabled,"
    echo "  \"modules\": ["

    # Output module array
    local first=true
    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"
        local status
        status="$(nftban_module_check_enabled "$file")"

        # Add comma separator
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        # Output module object
        echo "    {"
        echo "      \"name\": \"$name\","
        echo "      \"version\": \"$version\","
        echo "      \"type\": \"$module_type\","
        echo "      \"status\": \"$status\","
        echo "      \"created\": \"$created\","
        echo "      \"path\": \"$file\","
        echo "      \"depends\": \"$depends\","
        echo "      \"owner\": \"$owner\","
        echo "      \"description\": \"$description\""
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
        nftban_module_loaded "nftban_report_module" "1.0.0" "Module Report Core" "core" "bash,grep,sed"
    fi
fi
