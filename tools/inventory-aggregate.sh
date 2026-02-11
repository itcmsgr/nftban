#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Inventory Aggregator & Validator
# =============================================================================
# meta:name="inventory-aggregate"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Aggregates meta:inventory.* from all files, validates dependencies"
# meta:inventory.files=""
# meta:inventory.binaries="grep,jq,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# PURPOSE:
#   Senior-level tooling to aggregate and validate the distributed inventory
#   metadata across 300+ files. Instead of manually updating each file,
#   this tool provides visibility into the current state.
#
# USAGE:
#   ./inventory-aggregate.sh [command] [options]
#
# COMMANDS:
#   aggregate    Build unified inventory from all meta:inventory.* headers
#   validate     Check that referenced binaries/files/configs exist
#   report       Generate human-readable summary report
#   json         Output full inventory as JSON
#   orphans      Find references to non-existent resources
#   coverage     Show files missing inventory headers
#
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Inventory categories
declare -A BINARIES
declare -A CONFIG_FILES
declare -A DATA_FILES
declare -A SYSTEMD_UNITS
declare -A ENV_VARS
declare -A NETWORK_PORTS
declare -A PRIVILEGES

# File tracking
declare -a FILES_WITH_INVENTORY
declare -a FILES_MISSING_INVENTORY

# =============================================================================
# PARSING FUNCTIONS
# =============================================================================

parse_inventory_line() {
    local line="$1"
    local file="$2"

    # Extract key and value from meta:inventory.KEY="VALUE"
    if [[ "$line" =~ meta:inventory\.([a-z_]+)=\"([^\"]*)\" ]]; then
        local key="${BASH_REMATCH[1]}"
        local value="${BASH_REMATCH[2]}"

        # Skip empty values
        [[ -z "$value" ]] && return 0

        # Parse comma-separated values
        IFS=',' read -ra items <<< "$value"
        for item in "${items[@]}"; do
            item=$(echo "$item" | xargs)  # Trim whitespace
            [[ -z "$item" ]] && continue

            case "$key" in
                binaries)
                    BINARIES["$item"]+="$file "
                    ;;
                config_files)
                    CONFIG_FILES["$item"]+="$file "
                    ;;
                files)
                    DATA_FILES["$item"]+="$file "
                    ;;
                systemd_units)
                    SYSTEMD_UNITS["$item"]+="$file "
                    ;;
                env_vars)
                    ENV_VARS["$item"]+="$file "
                    ;;
                network)
                    NETWORK_PORTS["$item"]+="$file "
                    ;;
                privileges)
                    PRIVILEGES["$item"]+="$file "
                    ;;
            esac
        done
    fi
}

scan_file() {
    local file="$1"
    local has_inventory=false

    # Read first 100 lines for header
    while IFS= read -r line; do
        if [[ "$line" =~ meta:inventory\. ]]; then
            has_inventory=true
            parse_inventory_line "$line" "$file"
        fi
    done < <(head -100 "$file" 2>/dev/null || true)

    if $has_inventory; then
        FILES_WITH_INVENTORY+=("$file")
    else
        FILES_MISSING_INVENTORY+=("$file")
    fi
}

# =============================================================================
# AGGREGATION
# =============================================================================

cmd_aggregate() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Inventory Aggregator"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Scanning: $REPO_ROOT"
    echo ""

    local count=0

    # Scan shell scripts
    while IFS= read -r -d '' file; do
        scan_file "$file"
        ((count++))
    done < <(find "$REPO_ROOT" -type f -name "*.sh" ! -path "*/vendor/*" ! -path "*/.git/*" -print0 2>/dev/null)

    # Scan Go files
    while IFS= read -r -d '' file; do
        scan_file "$file"
        ((count++))
    done < <(find "$REPO_ROOT" -type f -name "*.go" ! -path "*/vendor/*" ! -path "*/.git/*" -print0 2>/dev/null)

    # Scan systemd units
    while IFS= read -r -d '' file; do
        scan_file "$file"
        ((count++))
    done < <(find "$REPO_ROOT" -type f \( -name "*.service" -o -name "*.timer" \) ! -path "*/vendor/*" -print0 2>/dev/null)

    echo "Scanned: $count files"
    echo "With inventory: ${#FILES_WITH_INVENTORY[@]}"
    echo "Missing inventory: ${#FILES_MISSING_INVENTORY[@]}"
    echo ""

    # Summary
    echo "DEPENDENCY SUMMARY"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-20s %d unique\n" "Binaries:" "${#BINARIES[@]}"
    printf "  %-20s %d unique\n" "Config Files:" "${#CONFIG_FILES[@]}"
    printf "  %-20s %d unique\n" "Data Files:" "${#DATA_FILES[@]}"
    printf "  %-20s %d unique\n" "Systemd Units:" "${#SYSTEMD_UNITS[@]}"
    printf "  %-20s %d unique\n" "Env Variables:" "${#ENV_VARS[@]}"
    printf "  %-20s %d unique\n" "Network:" "${#NETWORK_PORTS[@]}"
    printf "  %-20s %d unique\n" "Privileges:" "${#PRIVILEGES[@]}"
    echo ""
}

# =============================================================================
# VALIDATION
# =============================================================================

cmd_validate() {
    cmd_aggregate

    local errors=0
    local warnings=0

    echo "VALIDATION RESULTS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Check binaries
    echo "BINARIES (checking if installed)"
    echo "───────────────────────────────────────────────────────────────"
    for bin in "${!BINARIES[@]}"; do
        # Clean up binary name (remove paths, common prefixes)
        local check_bin="$bin"
        check_bin="${check_bin##*/}"  # Remove path
        check_bin="${check_bin%%:*}"  # Remove suffixes like :read

        # Skip special values
        [[ "$check_bin" == "none" ]] && continue
        [[ "$check_bin" == "optional" ]] && continue
        [[ -z "$check_bin" ]] && continue

        if command -v "$check_bin" &>/dev/null; then
            printf "  ✓ %-30s installed\n" "$bin"
        else
            printf "  ✗ %-30s NOT FOUND\n" "$bin"
            ((errors++))
        fi
    done
    echo ""

    # Check systemd units
    echo "SYSTEMD UNITS (checking if exist)"
    echo "───────────────────────────────────────────────────────────────"
    for unit in "${!SYSTEMD_UNITS[@]}"; do
        [[ "$unit" == "none" ]] && continue
        [[ -z "$unit" ]] && continue

        # Check in repo install directory
        local unit_file="${REPO_ROOT}/install/systemd/${unit}"
        if [[ -f "$unit_file" ]]; then
            printf "  ✓ %-40s exists\n" "$unit"
        elif systemctl list-unit-files "$unit" &>/dev/null 2>&1; then
            printf "  ✓ %-40s (system)\n" "$unit"
        else
            printf "  ? %-40s (not in repo, may be external)\n" "$unit"
            ((warnings++))
        fi
    done
    echo ""

    # Summary
    echo "───────────────────────────────────────────────────────────────"
    echo "Errors: $errors | Warnings: $warnings"

    return $errors
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

cmd_json() {
    cmd_aggregate >/dev/null 2>&1

    # Build JSON
    cat <<EOF
{
  "schema_version": "1.0",
  "generated": "$(date -Iseconds)",
  "repository": "$REPO_ROOT",
  "coverage": {
    "files_with_inventory": ${#FILES_WITH_INVENTORY[@]},
    "files_missing_inventory": ${#FILES_MISSING_INVENTORY[@]}
  },
  "binaries": [
EOF

    local first=true
    for bin in "${!BINARIES[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false
        local count
        count=$(echo "${BINARIES[$bin]}" | wc -w)
        printf '    {"name": "%s", "used_by_count": %d}' "$bin" "$count"
    done

    cat <<EOF

  ],
  "config_files": [
EOF

    first=true
    for cfg in "${!CONFIG_FILES[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false
        local count
        count=$(echo "${CONFIG_FILES[$cfg]}" | wc -w)
        printf '    {"path": "%s", "used_by_count": %d}' "$cfg" "$count"
    done

    cat <<EOF

  ],
  "systemd_units": [
EOF

    first=true
    for unit in "${!SYSTEMD_UNITS[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false
        local count
        count=$(echo "${SYSTEMD_UNITS[$unit]}" | wc -w)
        printf '    {"unit": "%s", "used_by_count": %d}' "$unit" "$count"
    done

    cat <<EOF

  ],
  "env_vars": [
EOF

    first=true
    for var in "${!ENV_VARS[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false
        local count
        count=$(echo "${ENV_VARS[$var]}" | wc -w)
        printf '    {"name": "%s", "used_by_count": %d}' "$var" "$count"
    done

    cat <<EOF

  ],
  "privileges": [
EOF

    first=true
    for priv in "${!PRIVILEGES[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false
        local count
        count=$(echo "${PRIVILEGES[$priv]}" | wc -w)
        printf '    {"level": "%s", "used_by_count": %d}' "$priv" "$count"
    done

    cat <<EOF

  ]
}
EOF
}

# =============================================================================
# COVERAGE REPORT
# =============================================================================

cmd_coverage() {
    cmd_aggregate >/dev/null 2>&1

    echo "FILES MISSING INVENTORY HEADERS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local total=${#FILES_MISSING_INVENTORY[@]}
    local shown=0

    # Group by directory
    declare -A by_dir
    for file in "${FILES_MISSING_INVENTORY[@]}"; do
        local dir
        dir=$(dirname "$file" | sed "s|$REPO_ROOT/||")
        by_dir["$dir"]+="$(basename "$file") "
        ((shown++))
    done

    for dir in $(echo "${!by_dir[@]}" | tr ' ' '\n' | sort); do
        echo "$dir/"
        for f in ${by_dir[$dir]}; do
            echo "  - $f"
        done
        echo ""
    done

    echo "───────────────────────────────────────────────────────────────"
    echo "Total missing: $total"
    echo ""
    echo "COVERAGE: $((100 * ${#FILES_WITH_INVENTORY[@]} / (${#FILES_WITH_INVENTORY[@]} + total)))%"
}

# =============================================================================
# REPORT
# =============================================================================

cmd_report() {
    cmd_aggregate

    echo ""
    echo "TOP BINARIES (by usage)"
    echo "───────────────────────────────────────────────────────────────"
    for bin in "${!BINARIES[@]}"; do
        local count
        count=$(echo "${BINARIES[$bin]}" | wc -w)
        printf "%3d  %s\n" "$count" "$bin"
    done | sort -rn | head -20

    echo ""
    echo "TOP CONFIG FILES (by usage)"
    echo "───────────────────────────────────────────────────────────────"
    for cfg in "${!CONFIG_FILES[@]}"; do
        local count
        count=$(echo "${CONFIG_FILES[$cfg]}" | wc -w)
        printf "%3d  %s\n" "$count" "$cfg"
    done | sort -rn | head -15

    echo ""
    echo "PRIVILEGE LEVELS"
    echo "───────────────────────────────────────────────────────────────"
    for priv in "${!PRIVILEGES[@]}"; do
        local count
        count=$(echo "${PRIVILEGES[$priv]}" | wc -w)
        printf "%3d files require: %s\n" "$count" "$priv"
    done | sort -rn

    echo ""
    echo "ENV VARIABLES"
    echo "───────────────────────────────────────────────────────────────"
    for var in "${!ENV_VARS[@]}"; do
        local count
        count=$(echo "${ENV_VARS[$var]}" | wc -w)
        printf "%3d  %s\n" "$count" "$var"
    done | sort -rn | head -15
}

# =============================================================================
# HELP
# =============================================================================

cmd_help() {
    cat <<'EOF'
NFTBan Inventory Aggregator
═══════════════════════════════════════════════════════════════════════════════

USAGE:
  ./inventory-aggregate.sh [command]

COMMANDS:
  aggregate    Scan all files \and build unified inventory (default)
  validate     Check that referenced binaries/files exist
  report       Generate human-readable summary with top dependencies
  json         Output full inventory as JSON
  coverage     Show files missing inventory headers
  help         Show this help

EXAMPLES:
  # Quick overview
  ./inventory-aggregate.sh

  # Validate all dependencies exist
  ./inventory-aggregate.sh validate

  # Export to JSON for CI/tooling
  ./inventory-aggregate.sh json > inventory.json

  # Find files without inventory headers
  ./inventory-aggregate.sh coverage

PURPOSE:
  Instead of manually updating 300+ files, this tool provides visibility
  into the current inventory state across the entire codebase.

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local cmd="${1:-aggregate}"

    case "$cmd" in
        aggregate)  cmd_aggregate ;;
        validate)   cmd_validate ;;
        report)     cmd_report ;;
        json)       cmd_json ;;
        coverage)   cmd_coverage ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
