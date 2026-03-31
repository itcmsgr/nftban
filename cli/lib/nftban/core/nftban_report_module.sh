#!/usr/bin/env bash

# =============================================================================
# NFTBan v1.0.0 - Module Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Module inventory scanning and reporting with validation
#
# meta:name="nftban_report_module"
# meta:type="core"
# meta:header="Module Report Core"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Scans, inventories, and validates NFTBan modules by meta tags"
# meta:input="Module scan options, output format, validation flags"
# meta:output="Module inventory reports with validation results"
#
# **Inventory & Requirements**
# meta:depends="bash,grep,sed"
#
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
# meta:contributors="Claude (Anthropic) - Testing and integration, ChatGPT (OpenAI) - Code review"
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_MODULE_INVENTORY=()  # key: file_path -> "name|version|type|created|depends|owner|homepage|description"
declare -g NFTBAN_MODULE_TIMESTAMP
NFTBAN_MODULE_TIMESTAMP="$(date --iso-8601=seconds)"
declare -g NFTBAN_MODULE_OUTPUT_FORMAT="${NFTBAN_MODULE_OUTPUT_FORMAT:-table}"

# Color symbols
if type -t nftban_render_banner >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_MODULE_SYM_OK="✔"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_MODULE_SYM_KO="✖"
else
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_MODULE_SYM_OK="✔"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_MODULE_SYM_KO="✖"
    C_RESET="\e[0m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    # shellcheck disable=SC2034  # Reserved for future use
    C_BLUE="\e[34m"
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

nftban_module_extract_license() {
    # Extract SPDX license from file
    # Args: $1 = file path
    # Output: license identifier or empty string

    local file="$1"
    grep -E "^#[[:space:]]*SPDX-License-Identifier:" "$file" 2>/dev/null | head -1 | sed -E 's/^#[[:space:]]*SPDX-License-Identifier:[[:space:]]*(.*)/\1/' | xargs || echo ""
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

    # All modules in recognized directories are considered enabled (sourced/active)
    # - core/     : Core functionality modules
    # - cli/      : Command-line interface handlers
    # - lib/      : Shared libraries
    # - helpers/  : Helper utilities
    # - cron/     : Scheduled task modules
    # - setup/    : Installation and setup scripts
    # - exporters/: Metrics exporters
    if [[ "$file" =~ /core/ ]] || [[ "$file" =~ /cli/ ]] || [[ "$file" =~ /lib/ ]] || \
       [[ "$file" =~ /helpers/ ]] || [[ "$file" =~ /cron/ ]] || [[ "$file" =~ /setup/ ]] || \
       [[ "$file" =~ /exporters/ ]]; then
        echo "ENABLED"
        return 0
    fi

    # nftban_help.sh is also sourced (not executed)
    if [[ "$file" =~ nftban_help\.sh$ ]]; then
        echo "ENABLED"
        return 0
    fi

    # Otherwise disabled
    echo "DISABLED"
}

# =============================================================================
# NEW: VALIDATION FUNCTIONS (INFORMATIONAL ONLY)
# =============================================================================

nftban_module_validate_metadata() {
    # Validate module metadata completeness (INFORMATIONAL ONLY)
    # Returns: Report of modules with missing or incomplete metadata
    # Does NOT fix anything - only reports issues

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s Metadata Validation Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Scan modules if not already done
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    local total=0
    local complete=0
    local incomplete=0

    printf "%-40s %-8s %-8s %-8s %-10s %-10s\n" "MODULE" "NAME" "VERSION" "TYPE" "OWNER" "LICENSE"
    echo "------------------------------------------------------------------------------------"

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        total=$((total + 1))
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        # Extract license
        local license
        license="$(nftban_module_extract_license "$file")"

        # Check completeness
        local missing_fields=()
        [[ -z "$name" ]] && missing_fields+=("name")
        [[ -z "$version" ]] && missing_fields+=("version")
        [[ -z "$module_type" ]] && missing_fields+=("type")
        [[ -z "$owner" ]] && missing_fields+=("owner")
        [[ -z "$license" ]] && missing_fields+=("license")

        # Status symbols
        local name_status="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-}"
        local version_status="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-}"
        local type_status="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-}"
        local owner_status="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-}"
        local license_status="${C_GREEN:-}${NFTBAN_MODULE_SYM_OK}${C_RESET:-}"

        [[ -z "$name" ]] && name_status="${C_RED:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-}"
        [[ -z "$version" ]] && version_status="${C_RED:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-}"
        [[ -z "$module_type" ]] && type_status="${C_RED:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-}"
        [[ -z "$owner" ]] && owner_status="${C_YELLOW:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-}"
        [[ -z "$license" ]] && license_status="${C_RED:-}${NFTBAN_MODULE_SYM_KO}${C_RESET:-}"

        if [[ ${#missing_fields[@]} -eq 0 ]]; then
            complete=$((complete + 1))
        else
            incomplete=$((incomplete + 1))
            local basename
            basename="$(basename "$file")"
            printf "%-40s %-8s %-8s %-8s %-10s %-10s\n" \
                "${basename:0:39}" "$name_status" "$version_status" "$type_status" "$owner_status" "$license_status"
        fi
    done

    echo
    echo "Summary:"
    echo "  Total Modules:      $total"
    echo "  Complete Metadata:  ${C_GREEN:-}$complete${C_RESET:-}"
    echo "  Incomplete Metadata: ${C_YELLOW:-}$incomplete${C_RESET:-}"
    echo
    echo "Note: This is informational only. No files were modified."
    echo
}

nftban_module_check_duplicates() {
    # Check for duplicate module names and version conflicts (INFORMATIONAL ONLY)
    # Reports: Multiple files with same meta:name, version mismatches
    # Does NOT fix anything

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s Duplicate Module & Version Conflict Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Scan modules if not already done
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    # Build index: module_name -> array of (file_path|version)
    declare -A name_index

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        # Skip if no name
        [[ -z "$name" ]] && continue

        # Append to name index
        if [[ -n "${name_index[$name]:-}" ]]; then
            name_index["$name"]+=$'\n'"${file}|${version}"
        else
            name_index["$name"]="${file}|${version}"
        fi
    done

    local total_duplicates=0
    local total_version_conflicts=0

    # Check for duplicates
    for module_name in "${!name_index[@]}"; do
        local entries="${name_index[$module_name]}"
        local entry_count
        entry_count=$(echo "$entries" | wc -l)

        # If more than one file has this module name, it's a duplicate
        if [[ $entry_count -gt 1 ]]; then
            total_duplicates=$((total_duplicates + 1))

            echo "${C_RED:-}⚠ DUPLICATE MODULE NAME: ${module_name}${C_RESET:-}"
            echo "  Found in $entry_count files:"

            # Check for version conflicts
            local versions=()
            while IFS='|' read -r filepath fileversion; do
                versions+=("$fileversion")
                local basename
                basename="$(basename "$filepath")"
                printf "    - %-50s (version: %s)\n" "$basename" "${fileversion:-MISSING}"
            done <<< "$entries"

            # Check if all versions are the same
            local unique_versions
            unique_versions=$(printf '%s\n' "${versions[@]}" | sort -u | wc -l)

            if [[ $unique_versions -gt 1 ]]; then
                total_version_conflicts=$((total_version_conflicts + 1))
                echo "    ${C_YELLOW:-}⚠ VERSION CONFLICT: Multiple versions detected!${C_RESET:-}"
            elif [[ "${versions[0]}" == "" ]]; then
                echo "    ${C_YELLOW:-}⚠ WARNING: Version metadata missing${C_RESET:-}"
            fi
            echo
        fi
    done

    # Summary
    echo "------------------------------------------------------------------------------------"
    echo
    echo "Summary:"
    echo "  Total Unique Module Names:  ${#name_index[@]}"
    echo "  Duplicate Module Names:     ${C_RED:-}${total_duplicates}${C_RESET:-}"
    echo "  Version Conflicts:          ${C_YELLOW:-}${total_version_conflicts}${C_RESET:-}"
    echo

    if [[ $total_duplicates -eq 0 ]]; then
        echo "${C_GREEN:-}✔ No duplicate module names found${C_RESET:-}"
    else
        echo "${C_RED:-}✖ Fix: Remove or rename duplicate module files${C_RESET:-}"
        echo "  Recommendation: Keep only the most recent version of each module"
    fi

    if [[ $total_version_conflicts -gt 0 ]]; then
        echo "${C_YELLOW:-}⚠ Version conflicts detected - update metadata in duplicate files${C_RESET:-}"
    fi

    echo
    echo "Note: This is informational only. No files were modified."
    echo

    # Return non-zero if issues found
    [[ $total_duplicates -gt 0 || $total_version_conflicts -gt 0 ]] && return 1
    return 0
}

nftban_module_check_license() {
    # Check license compliance (INFORMATIONAL ONLY)
    # Reports: MPL-2.0 vs GPL vs missing licenses
    # Does NOT fix anything

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s License Compliance Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Scan modules if not already done
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    local total=0
    local mpl_count=0
    local gpl_count=0
    local missing_count=0
    local other_count=0

    local -a mpl_files=()
    local -a gpl_files=()
    local -a missing_files=()
    local -a other_files=()

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        total=$((total + 1))
        local license
        license="$(nftban_module_extract_license "$file")"

        if [[ "$license" == "MPL-2.0" ]]; then
            mpl_count=$((mpl_count + 1))
            mpl_files+=("$file")
        elif [[ "$license" =~ GPL ]]; then
            gpl_count=$((gpl_count + 1))
            gpl_files+=("$file")
        elif [[ -z "$license" ]]; then
            missing_count=$((missing_count + 1))
            missing_files+=("$file")
        else
            other_count=$((other_count + 1))
            other_files+=("$file")
        fi
    done

    echo "Summary:"
    echo "  Total Modules:      $total"
    echo "  ${C_GREEN:-}✔ MPL-2.0 (correct):${C_RESET:-}   $mpl_count ($(( mpl_count * 100 / total ))%)"
    echo "  ${C_RED:-}✖ GPL (wrong):${C_RESET:-}       $gpl_count"
    echo "  ${C_YELLOW:-}⚠ Missing License:${C_RESET:-}  $missing_count"
    [[ $other_count -gt 0 ]] && echo "  ${C_YELLOW:-}⚠ Other License:${C_RESET:-}    $other_count"
    echo

    if [[ $gpl_count -gt 0 ]]; then
        echo "${C_RED:-}CRITICAL: Scripts with GPL license (should be MPL-2.0):${C_RESET:-}"
        for file in "${gpl_files[@]}"; do
            local license
            license="$(nftban_module_extract_license "$file")"
            printf "  ✖ %-60s License: %s\n" "$(basename "$file")" "$license"
            echo "    Path: $file"
        done
        echo
    fi

    if [[ $missing_count -gt 0 ]]; then
        echo "${C_YELLOW:-}WARNING: Scripts missing SPDX license:${C_RESET:-}"
        for file in "${missing_files[@]}"; do
            printf "  ⚠ %s\n" "$(basename "$file")"
            echo "    Path: $file"
        done
        echo
    fi

    echo "Note: This is informational only. No files were modified."
    echo "      Standard: All scripts should have SPDX-License-Identifier: MPL-2.0"
    echo
}

nftban_module_check_author() {
    # Check author attribution (INFORMATIONAL ONLY)
    # Reports: Correct author vs wrong vs missing
    # Does NOT fix anything

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s Author Attribution Report — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Scan modules if not already done
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    local total=0
    local correct_count=0
    local wrong_count=0
    local missing_count=0

    local -a correct_files=()
    local -a wrong_files=()
    local -a missing_files=()

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        total=$((total + 1))
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        if [[ "$owner" == *"Antonios Voulvoulis"* ]] || [[ "$owner" == *"Voulvoulis"* ]]; then
            correct_count=$((correct_count + 1))
            correct_files+=("$file")
        elif [[ -n "$owner" ]]; then
            wrong_count=$((wrong_count + 1))
            wrong_files+=("$file|$owner")
        else
            missing_count=$((missing_count + 1))
            missing_files+=("$file")
        fi
    done

    echo "Summary:"
    echo "  Total Modules:        $total"
    echo "  ${C_GREEN:-}✔ Correct Author:${C_RESET:-}      $correct_count ($(( correct_count * 100 / total ))%)"
    echo "  ${C_RED:-}✖ Wrong Author:${C_RESET:-}        $wrong_count"
    echo "  ${C_YELLOW:-}⚠ Missing Author:${C_RESET:-}     $missing_count"
    echo

    if [[ $wrong_count -gt 0 ]]; then
        echo "${C_RED:-}CRITICAL: Scripts with wrong author attribution:${C_RESET:-}"
        for item in "${wrong_files[@]}"; do
            IFS='|' read -r file owner <<< "$item"
            printf "  ✖ %-60s Author: %s\n" "$(basename "$file")" "$owner"
            echo "    Path: $file"
        done
        echo
    fi

    if [[ $missing_count -gt 0 ]]; then
        echo "${C_YELLOW:-}WARNING: Scripts missing author attribution:${C_RESET:-}"
        for file in "${missing_files[@]}"; do
            printf "  ⚠ %s\n" "$(basename "$file")"
            echo "    Path: $file"
        done
        echo
    fi

    echo "Note: This is informational only. No files were modified."
    echo "      Standard: meta:owner=\"Antonios Voulvoulis <contact@nftban.com>\""
    echo
}

nftban_module_analyze_dependencies() {
    # Analyze module dependencies
    # Shows: What each module depends on and reverse dependencies

    echo
    echo "════════════════════════════════════════════════════════════════════════════════════"
    printf "%s Module Dependency Analysis — %s %s\n" "${C_BOLD:-}" "$NFTBAN_MODULE_TIMESTAMP" "${C_RESET:-}"
    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo

    # Scan modules if not already done
    if [[ ${#NFTBAN_MODULE_INVENTORY[@]} -eq 0 ]]; then
        nftban_module_scan
    fi

    local total=0
    local with_deps=0
    local without_deps=0

    # Collect dependency stats
    declare -A dep_count=()
    
    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        total=$((total + 1))
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        if [[ -n "$depends" ]]; then
            with_deps=$((with_deps + 1))
            # Count individual dependencies
            IFS=',' read -ra DEPS <<< "$depends"
            for dep in "${DEPS[@]}"; do
                dep=$(echo "$dep" | xargs)  # trim whitespace
                if [[ -n "${dep_count[$dep]:-}" ]]; then
                    dep_count[$dep]=$((dep_count[$dep] + 1))
                else
                    dep_count[$dep]=1
                fi
            done
        else
            without_deps=$((without_deps + 1))
        fi
    done

    echo "Summary:"
    echo "  Total Modules:           $total"
    echo "  Modules with Dependencies: $with_deps"
    echo "  Modules without Dependencies: $without_deps"
    echo

    # Show most common dependencies
    if [[ ${#dep_count[@]} -gt 0 ]]; then
        echo "Most Common Dependencies:"
        for dep in "${!dep_count[@]}"; do
            printf "  %-20s (used by %d modules)\n" "$dep" "${dep_count[$dep]}"
        done | sort -t'(' -k2 -rn | head -10
        echo
    fi

    # Show modules grouped by dependencies
    echo "Modules by Dependencies:"
    echo

    for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
        local data="${NFTBAN_MODULE_INVENTORY[$file]}"
        IFS='|' read -r name version module_type created depends owner homepage description <<< "$data"

        if [[ -n "$depends" ]]; then
            printf "  ${C_BOLD:-}%-30s${C_RESET:-} → %s\n" "$name" "$depends"
        fi
    done | sort

    echo
}

# =============================================================================
# REPORT RENDERING FUNCTIONS
# =============================================================================

nftban_module_render_table() {
    # Render module inventory as terminal table
    # Uses: NFTBAN_MODULE_OUTPUT_FORMAT

    if [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "table" ]]; then
        local short_ts
        short_ts=$(date +"%Y-%m-%d %H:%M")
        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        printf "║  NFTBan Modules                 %-12s    ║\n" "$short_ts"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        printf "%-25s %-10s %-8s %-10s %-40s\n" \
            "NAME" "VERSION" "TYPE" "STATUS" "PATH"
        echo "────────────────────────────────────────────────────────"
    elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "md" ]]; then
        echo "| NAME | VERSION | TYPE | STATUS | PATH | DEPENDS |"
        echo "|:---|:---|:---:|:---:|:---|:---|"
    elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "csv" ]]; then
        echo "NAME,VERSION,TYPE,STATUS,PATH,DEPENDS"
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

            printf "%-25s %-10s %-8s %-10s %s\n" \
                "${name:0:24}" \
                "${version:0:9}" \
                "${module_type:0:7}" \
                "$status_badge" \
                "$display_path"

        elif [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "md" ]]; then
            printf "| %s | %s | %s | %s | %s | %s |\n" \
                "$name" "$version" "$module_type" "$status" "$display_path" "$depends"

        else # csv
            printf "%s,%s,%s,%s,%s,%s\n" \
                "$name" "$version" "$module_type" "$status" "\"$file\"" "\"$depends\""
        fi
    done

    if [[ "$NFTBAN_MODULE_OUTPUT_FORMAT" == "table" ]]; then
        echo
        local total="${#NFTBAN_MODULE_INVENTORY[@]}"
        local enabled=0
        for file in "${!NFTBAN_MODULE_INVENTORY[@]}"; do
            if [[ "$(nftban_module_check_enabled "$file")" == "ENABLED" ]]; then
                # v1.19.20 FIX
                (( enabled++ )) || true
            fi
        done
        echo "Total modules: $total | Enabled: $enabled | Disabled: $((total - enabled))"
        echo

        # Module Type Legend
        echo "────────────────────────────────────────────────────────────────────────────────────"
        echo "MODULE TYPES:"
        echo "  cli      - Command-line interface handlers (nftban <command>)"
        echo "  core     - Core functionality modules (loaded by CLI commands)"
        echo "  lib      - Shared libraries (sourced by multiple modules)"
        echo "  helper   - Helper utilities (logging, JSON output, etc.)"
        echo "  setup    - Installation and setup scripts"
        echo "  exporter - Prometheus/metrics exporters"
        echo "  cron     - Scheduled task modules (timers)"
        echo ""
        echo "STATUS:"
        echo "  ✔ ENABLED  - Module is active and available"
        echo "  ✖ DISABLED - Module exists but not in active path"
        echo ""
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

        # Extract license
        local license
        license="$(nftban_module_extract_license "$file")"

        echo "Module: ${C_BOLD:-}$name${C_RESET:-}"
        echo "  Version:     $version"
        echo "  Type:        $module_type"
        echo "  Status:      $status"
        echo "  Created:     $created"
        [[ -n "$license" ]] && echo "  License:     $license"
        echo "  Path:        $file"
        [[ -n "$depends" ]] && echo "  Depends:     $depends"
        [[ -n "$owner" ]] && echo "  Owner:       $owner"
        [[ -n "$homepage" ]] && echo "  Homepage:    $homepage"
        [[ -n "$description" ]] && echo "  Description: $description"
        echo
    done
}

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
    html_content="${html_content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-unknown}}"
    html_content="${html_content//\{COMPANY_NAME\}/${NFTBAN_COMPANY_NAME:-}}"
    html_content="${html_content//\{LOGO_HTML\}/}"
    html_content="${html_content//\{VERSION_HTML\}/<p>Version: <strong>${NFTBAN_VERSION:-unknown}</strong></p>}"

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
    echo "$html_content" > "${report_file}.tmp" && mv -f "${report_file}.tmp" "$report_file"

    # Set permissions
    chmod 640 "$report_file" 2>/dev/null || true

    echo "$report_file"
}

# =============================================================================
# MAIN REPORT FUNCTIONS
# =============================================================================

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

        # Extract license
        local license
        license="$(nftban_module_extract_license "$file")"

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
        echo "      \"license\": \"$license\","
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
        nftban_module_loaded "nftban_report_module" "1.1.0" "Module Report Core" "core" "bash,grep,sed"
    fi
fi
