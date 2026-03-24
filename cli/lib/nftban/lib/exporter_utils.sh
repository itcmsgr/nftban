#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="exporter_utils"
# meta:type="lib"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Common utility functions shared across all Prometheus exporters"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Guard against multiple sourcing
[[ -n "${_NFTBAN_EXPORTER_UTILS_LOADED:-}" ]] && return 0
readonly _NFTBAN_EXPORTER_UTILS_LOADED=1

# =============================================================================
# METRIC WRITER FUNCTIONS
# =============================================================================

# Write a metric with multiple label/value pairs in Prometheus text exposition format
# Usage: write_metric "metric_name" "gauge|counter" "Help text" "{label=\"val\"} 123" ...
# Args:
#   $1 = metric name
#   $2 = metric type (gauge, counter, histogram, summary)
#   $3 = HELP description text
#   $4+ = metric lines (with labels and values)
#
# Example:
#   write_metric "nftban_blocks" "gauge" "Number of blocked IPs" \
#       "{type=\"permanent\"} 100" \
#       "{type=\"temporary\"} 50"
write_metric() {
    local name="$1"
    local type="$2"
    local help="$3"
    shift 3

    # Write HELP line
    echo "# HELP ${name} ${help}"
    # Write TYPE line
    echo "# TYPE ${name} ${type}"

    # Write all metric values
    for line in "$@"; do
        echo "${name}${line}"
    done
}

# Write a simple single-value metric in Prometheus text exposition format
# Usage: write_metric_simple "metric_name" "value" "Help text" ["gauge"|"counter"]
# Args:
#   $1 = metric name (without labels)
#   $2 = metric value
#   $3 = HELP description text (optional)
#   $4 = metric type (default: gauge)
#
# Example:
#   write_metric_simple "nftban_blocks_total" "150" "Total blocked IPs"
write_metric_simple() {
    local name="$1"
    local value="$2"
    local help="${3:-}"
    local type="${4:-gauge}"

    # Write HELP line if provided
    if [[ -n "$help" ]]; then
        echo "# HELP ${name} ${help}"
    fi

    # Write TYPE line
    echo "# TYPE ${name} ${type}"

    # Write metric value
    echo "${name} ${value}"
    echo ""
}

# Initialize an empty metrics file for atomic writes
# Usage: init_metrics_file "output_file"
# Returns: Path to temp file (use with atomic move pattern)
init_metrics_file() {
    local output_file="$1"
    local tmp_file="${output_file}.$$"

    # Initialize empty temp file
    : > "$tmp_file"

    echo "$tmp_file"
}

# Atomic move of temp file to final output
# Usage: finalize_metrics_file "tmp_file" "output_file" ["permissions"]
# Args:
#   $1 = temporary file path
#   $2 = final output file path
#   $3 = permissions (default: 644)
finalize_metrics_file() {
    local tmp_file="$1"
    local output_file="$2"
    local permissions="${3:-644}"

    mv "$tmp_file" "$output_file"
    chmod "$permissions" "$output_file"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f write_metric
export -f write_metric_simple
export -f init_metrics_file
export -f finalize_metrics_file

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright © 2024-2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
# =============================================================================
