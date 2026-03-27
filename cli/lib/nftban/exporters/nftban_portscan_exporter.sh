#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_portscan_exporter"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Export port scan detection and blocking metrics for Prometheus"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
# shellcheck disable=SC1091  -- dynamic config path resolved at runtime
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# CONFIGURATION
readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR}"
readonly OUTPUT_FILE="${NFTBAN_METRICS_FILE:-/var/lib/node_exporter/textfile_collector/nftban.prom}"
readonly ACTIONS_LOG="${NFTBAN_LOG_DIR}/nftban-actions.log"
readonly PORTSCAN_CONF="${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get monitored ports count from config
get_monitored_ports_count() {
    local count=0

    if [[ ! -f "$PORTSCAN_CONF" ]]; then
        echo "0"
        return
    fi

    # Check if portscan is enabled
    local enabled
    enabled=$(grep "^PORTSCAN_ENABLED=" "$PORTSCAN_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "false")

    if [[ "$enabled" != "true" ]]; then
        echo "0"
        return
    fi

    # Get monitored ports value
    local ports_line
    ports_line=$(grep "^PORTSCAN_MONITOR_PORTS=" "$PORTSCAN_CONF" 2>/dev/null || echo "")

    if [[ -n "$ports_line" ]]; then
        # Extract value: PORTSCAN_MONITOR_PORTS="value"
        local ports_value
        ports_value=$(echo "$ports_line" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)

        # Handle special values
        if [[ "$ports_value" == "closed" ]] || [[ "$ports_value" == "all" ]]; then
            # "closed" or "all" means monitoring is active
            count=1
        else
            # Count specific port numbers
            count=$(echo "$ports_value" | { grep -o '[0-9]\+' || true; } | wc -l || echo "0")
        fi
    fi

    echo "$count"
}

# Get portscan blocked count (24h)
get_portscan_blocked_24h() {
    if [[ ! -f "$ACTIONS_LOG" ]]; then
        echo "0"
        return
    fi

    if ! command -v jq &>/dev/null; then
        echo "0"
        return
    fi

    # Calculate 24 hours ago timestamp
    local yesterday_ts
    yesterday_ts=$(date -d '24 hours ago' +%s 2>/dev/null || date -v-24H +%s 2>/dev/null || echo "0")

    if [[ "$yesterday_ts" == "0" ]]; then
        echo "0"
        return
    fi

    # Count portscan bans in last 24 hours
    local count
    count=$(jq -r --arg ts "$yesterday_ts" \
        'select(.source == "portscan" and .event == "ban") |
         select((.ts | fromdateiso8601) >= ($ts | tonumber))' \
        "$ACTIONS_LOG" 2>/dev/null | \
        jq -s '. | length' 2>/dev/null || echo "0")

    echo "$count"
}

# Get total portscan blocked count
get_portscan_blocked_total() {
    if [[ ! -f "$ACTIONS_LOG" ]]; then
        echo "0"
        return
    fi

    if ! command -v jq &>/dev/null; then
        echo "0"
        return
    fi

    # Count total portscan bans
    local count
    count=$(jq -r 'select(.source == "portscan" and .event == "ban")' \
        "$ACTIONS_LOG" 2>/dev/null | \
        jq -s '. | length' 2>/dev/null || echo "0")

    echo "$count"
}

# Check if portscan module is enabled
get_portscan_enabled() {
    if [[ ! -f "$PORTSCAN_CONF" ]]; then
        echo "0"
        return
    fi

    local enabled
    enabled=$(grep "^PORTSCAN_ENABLED=" "$PORTSCAN_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "false")

    if [[ "$enabled" == "true" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

# =============================================================================
# METRIC COLLECTION
# =============================================================================

collect_portscan_metrics() {
    # Get metrics
    local monitored_ports
    local blocked_24h
    local blocked_total
    local module_enabled

    monitored_ports=$(get_monitored_ports_count)
    blocked_24h=$(get_portscan_blocked_24h)
    blocked_total=$(get_portscan_blocked_total)
    module_enabled=$(get_portscan_enabled)

    # Atomic append: write to temp file, then merge with main metrics file
    local tmp_prom
    tmp_prom=$(mktemp "${OUTPUT_FILE}.XXXXXX") || return 1

    # Copy existing content + append new portscan metrics
    {
        cat "$OUTPUT_FILE" 2>/dev/null || true

        echo "# HELP nftban_portscan_monitored_ports Number of ports being monitored for port scans"
        echo "# TYPE nftban_portscan_monitored_ports gauge"
        echo "nftban_portscan_monitored_ports $monitored_ports"
        echo ""

        echo "# HELP nftban_portscan_blocked_24h Port scans blocked in last 24 hours"
        echo "# TYPE nftban_portscan_blocked_24h gauge"
        echo "nftban_portscan_blocked_24h $blocked_24h"
        echo ""

        echo "# HELP nftban_portscan_blocked_total Total port scans blocked since logging began"
        echo "# TYPE nftban_portscan_blocked_total counter"
        echo "nftban_portscan_blocked_total $blocked_total"
        echo ""

        echo "# HELP nftban_portscan_module_enabled Whether port scan detection module is enabled (1=enabled, 0=disabled)"
        echo "# TYPE nftban_portscan_module_enabled gauge"
        echo "nftban_portscan_module_enabled $module_enabled"
        echo ""
    } > "$tmp_prom"

    mv -f "$tmp_prom" "$OUTPUT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Only run if output file exists (main exporter runs first)
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        exit 0
    fi

    # Collect and append metrics
    collect_portscan_metrics

    exit 0
}

# Run main function
main "$@"

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE
# =============================================================================
