#!/bin/bash
# =============================================================================
# NFTBan v1.0.0 - CLI Inventory Export Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="export_cli_inventory"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Exports all CLI commands with metadata to various formats"
# meta:input="format (table, json, list, help)"
# meta:output="CLI inventory in specified format"
# meta:depends="bash, grep"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./export_cli_inventory.sh [format]
#
# Formats:
#   table    - Markdown table (default)
#   json     - JSON output
#   list     - Simple command list
#   help     - Export all help text
# =============================================================================

set -Eeuo pipefail

CLI_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli"
FORMAT="${1:-table}"

# Fallback for development environment
if [[ ! -d "$CLI_DIR" ]]; then
    CLI_DIR="/home/gituser/github/nftban-v1.0-dev/cli/lib/nftban/cli"
fi

if [[ ! -d "$CLI_DIR" ]]; then
    echo "ERROR: CLI directory not found: $CLI_DIR" >&2
    exit 1
fi

# Count commands
CMD_COUNT=$(ls "$CLI_DIR"/cmd_*.sh 2>/dev/null | wc -l)

case "$FORMAT" in
    list)
        # Simple command list
        for cmd_file in "$CLI_DIR"/cmd_*.sh; do
            basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g'
        done | sort
        ;;

    json)
        # JSON output
        nftban_ver=$(cat "${BASH_SOURCE[0]%/*}/../VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
        echo "{"
        echo '  "version": "'"${nftban_ver}"'",'
        echo '  "generated": "'"$(date -Iseconds)"'",'
        echo '  "total_commands": '$CMD_COUNT','
        echo '  "commands": ['

        first=true
        for cmd_file in "$CLI_DIR"/cmd_*.sh; do
            name=$(basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g')
            desc=$(grep -oP 'meta:description=\K.*' "$cmd_file" 2>/dev/null | head -1 || echo "")
            ver=$(grep -oP 'meta:version=\K[0-9.]+' "$cmd_file" 2>/dev/null | head -1 || echo "unknown")

            [[ "$first" != "true" ]] && echo ","
            first=false

            # Escape quotes in description
            desc=$(echo "$desc" | sed 's/"/\\"/g')

            printf '    {"name": "%s", "version": "%s", "description": "%s"}' \
                "$name" "$ver" "$desc"
        done

        echo ""
        echo "  ]"
        echo "}"
        ;;

    help)
        # Export all help text
        OUTPUT_DIR="${2:-/tmp/nftban_help_export}"
        mkdir -p "$OUTPUT_DIR"

        echo "Exporting help text to: $OUTPUT_DIR"
        echo ""

        for cmd_file in "$CLI_DIR"/cmd_*.sh; do
            cmd_name=$(basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g')
            echo "  Exporting: nftban $cmd_name"

            # Source and extract help
            (
                export NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
                [[ -f /etc/nftban/nftban.conf ]] && source /etc/nftban/nftban.conf 2>/dev/null || true
                # shellcheck source=/dev/null
                source "$cmd_file" 2>/dev/null || true

                # Try different help function patterns
                func_name="${cmd_name//-/_}"
                for func in "_nftban_${func_name}_help" "show_${func_name}_help" "show_usage"; do
                    if declare -f "$func" >/dev/null 2>&1; then
                        "$func" 2>/dev/null
                        exit 0
                    fi
                done
                echo "No help function found"
            ) > "$OUTPUT_DIR/${cmd_name}.txt" 2>/dev/null || echo "  (error)"
        done

        echo ""
        echo "Exported $CMD_COUNT commands to: $OUTPUT_DIR"
        ;;

    table|*)
        # Markdown table (default)
        echo "# NFTBan CLI Commands"
        echo ""
        echo "**Total Commands:** $CMD_COUNT"
        echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "| Command | Version | Description |"
        echo "|---------|---------|-------------|"

        for cmd_file in "$CLI_DIR"/cmd_*.sh; do
            name=$(basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g')
            desc=$(grep -oP 'meta:description=\K.*' "$cmd_file" 2>/dev/null | head -1 || echo "-")
            ver=$(grep -oP 'meta:version=\K[0-9.]+' "$cmd_file" 2>/dev/null | head -1 || echo "unknown")

            echo "| \`nftban $name\` | $ver | $desc |"
        done | sort
        ;;
esac
