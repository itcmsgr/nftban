#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.32.0 - Scale CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Display set scale levels and huge-set management status
#
# meta:name="cmd_scale"
# meta:type="cli"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-03-21"
#
# meta:description="Show nftables set scale levels, daemon counter status, and adaptive intervals"
# meta:input="Command line arguments for scale display"
# meta:output="Scale levels, counter status, recommended intervals"
# meta:depends="bash,jq"
#
# meta:inventory.files="/usr/lib/nftban/cli/cmd_scale.sh"
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RUN_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load dependencies
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_RUN_DIR:-}" ]] && readonly NFTBAN_RUN_DIR="/run/nftban"

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=../helpers/json_output.sh
    source "$JSON_HELPER" || true
fi

# Cache file path (must match pkg/stats/set_counters.go)
readonly SCALE_CACHE_FILE="${NFTBAN_RUN_DIR}/set_counts.json"

# =============================================================================
# SCALE DISPLAY
# =============================================================================

_scale_show() {
    local json_mode="${1:-false}"

    if [[ ! -f "$SCALE_CACHE_FILE" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo '{"error":"daemon cache not available","hint":"is nftband running?"}'
        else
            echo "Scale data not available — daemon may not be running."
            echo ""
            echo "The daemon maintains in-memory counters for all nft sets."
            echo "Start it with: systemctl start nftband"
        fi
        return 1
    fi

    # Validate cache freshness
    local cache_age
    cache_age=$(( $(date +%s) - $(stat -c %Y "$SCALE_CACHE_FILE" 2>/dev/null || echo 0) ))

    if [[ "$json_mode" == "true" ]]; then
        # Raw JSON output
        jq --argjson age "$cache_age" '. + {cache_age_seconds: $age}' "$SCALE_CACHE_FILE" 2>/dev/null
        return
    fi

    # Human-readable display
    local scale_mode exporter_interval timestamp
    scale_mode=$(jq -r '.scale_mode // "UNKNOWN"' "$SCALE_CACHE_FILE" 2>/dev/null)
    exporter_interval=$(jq -r '.exporter_interval_seconds // 60' "$SCALE_CACHE_FILE" 2>/dev/null)
    timestamp=$(jq -r '.timestamp // "unknown"' "$SCALE_CACHE_FILE" 2>/dev/null)

    echo "NFTBan Scale Status"
    echo "==================="
    echo ""
    echo "Global scale:        $scale_mode"
    echo "Exporter interval:   ${exporter_interval}s"
    echo "Cache age:           ${cache_age}s"
    echo "Last update:         $timestamp"
    echo ""

    # Per-set table
    printf "%-30s %10s  %-15s  %-8s  %s\n" "SET" "COUNT" "SCALE" "TREND" "LAST RECONCILED"
    printf "%-30s %10s  %-15s  %-8s  %s\n" "---" "-----" "-----" "-----" "---------------"

    jq -r '.sets | to_entries[] | [.key, (.value.count | tostring), .value.scale, (.value.trend // "stable"), (.value.last_reconciled // "never")] | @tsv' \
        "$SCALE_CACHE_FILE" 2>/dev/null | \
    while IFS=$'\t' read -r name count scale trend reconciled; do
        # Use display field if available, otherwise raw count
        local display
        display=$(jq -r --arg s "$name" '.sets[$s].display // empty' "$SCALE_CACHE_FILE" 2>/dev/null)
        [[ -z "$display" ]] && display="$count"
        printf "%-30s %10s  %-15s  %-8s  %s\n" "$name" "$display" "$scale" "$trend" "$reconciled"
    done

    echo ""

    # Summary
    local total_sets total_elements
    total_sets=$(jq '.sets | length' "$SCALE_CACHE_FILE" 2>/dev/null || echo 0)
    total_elements=$(jq '[.sets[].count] | add // 0' "$SCALE_CACHE_FILE" 2>/dev/null || echo 0)

    echo "Total sets:          $total_sets"
    echo "Total elements:      $total_elements"

    if [[ "$cache_age" -gt 120 ]]; then
        echo ""
        echo "WARNING: Cache is ${cache_age}s old (>120s) — daemon may be stopped"
    fi
}

# =============================================================================
# HELP
# =============================================================================

nftban_cmd_scale_help() {
    echo "Usage: nftban scale [status] [--json]"
    echo ""
    echo "Show nftables set scale levels and daemon counter status."
    echo ""
    echo "Subcommands:"
    echo "  status    Show current scale levels (default)"
    echo ""
    echo "Options:"
    echo "  --json    Output raw JSON from daemon cache"
    echo ""
    echo "Scale Levels:"
    echo "  NORMAL         0 – 9,999 elements"
    echo "  LARGE          10,000 – 49,999"
    echo "  VERY_LARGE     50,000 – 99,999"
    echo "  HUGE           100,000 – 249,999"
    echo "  EXTREME        250,000 – 499,999"
    echo "  CRITICAL_SCALE 500,000+"
    echo ""
    echo "The daemon maintains exact in-memory counters updated on every"
    echo "add/delete/flush operation. Cache file: $SCALE_CACHE_FILE"
}

# =============================================================================
# COMMAND ENTRY POINT
# =============================================================================

nftban_cmd_scale() {
    local subcmd="${1:-}"
    local json_mode=false

    # Parse global flags
    for arg in "$@"; do
        case "$arg" in
            --json) json_mode=true ;;
        esac
    done

    case "$subcmd" in
        ""|status)
            _scale_show "$json_mode"
            ;;
        help|--help|-h)
            nftban_cmd_scale_help
            ;;
        *)
            echo "Unknown subcommand: $subcmd" >&2
            echo "Run 'nftban scale help' for usage" >&2
            return 1
            ;;
    esac
}
