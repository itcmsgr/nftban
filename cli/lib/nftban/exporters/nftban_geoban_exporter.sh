#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_geoban_exporter"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Prometheus exporter for Geo-blocking metrics"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

# ====================================================================
# LIBRARY LOADING
# ====================================================================

# Determine library path
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR}"

# Source common exporter utilities
if [[ -f "${NFTBAN_LIB_DIR}/lib/exporter_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/exporter_utils.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/exporter_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/exporter_utils.sh"
fi

# ====================================================================
# CONFIGURATION
# ====================================================================

# Textfile collector output
OUTPUT_FILE="${OUTPUT_FILE:-/var/lib/node_exporter/textfile_collector/nftban_geoban.prom}"

# Temporary file for atomic writes (mktemp for collision safety)
TMP_FILE=$(mktemp "${OUTPUT_FILE}.XXXXXX")

# Cleanup on exit
trap 'rm -f "$TMP_FILE"' EXIT

# ====================================================================
# Helper Functions (fallback if library not loaded)
# ====================================================================

# Only define if not already loaded from library
if ! declare -f write_metric &>/dev/null; then
    write_metric() {
        local name="$1"
        local type="$2"
        local help="$3"
        shift 3

        echo "# HELP ${name} ${help}" >> "$TMP_FILE"
        echo "# TYPE ${name} ${type}" >> "$TMP_FILE"

        for line in "$@"; do
            echo "${name}${line}" >> "$TMP_FILE"
        done
    }
fi

# ====================================================================
# Collect Geo-Blocking Metrics
# ====================================================================

collect_geoban_countries() {
    # Count blocked countries from nftables sets
    local blocked_countries=0

    if nft list sets 2>/dev/null | grep -q 'geoban'; then
        blocked_countries=$(nft list sets 2>/dev/null | grep -c 'set.*geoban.*country' || echo 0)
    fi

    write_metric "nftban_geoban_countries_blocked" "gauge" \
        "Number of countries currently blocked" " ${blocked_countries}"
}

collect_geoban_ips_by_country() {
    # Count IPs blocked per country
    # This requires parsing nftables sets

    local metrics=()

    # Try to get geoban sets
    if nft list sets 2>/dev/null | grep -q 'geoban'; then
        while IFS= read -r set_name; do
            # Extract country code from set name (e.g., geoban_cn, geoban_ru)
            local country
            country=$(echo "$set_name" | grep -oP 'geoban_\K[a-z]{2}' || echo "unknown")

            # Count elements in set (v1.18.0: use ip nftban table)
            local ip_count=0
            if nft list set ip nftban "$set_name" 2>/dev/null | grep -q 'elements'; then
                ip_count=$(nft list set ip nftban "$set_name" 2>/dev/null | \
                    { grep -oP 'elements = \{ \K[^}]*' || true; } | tr ',' '\n' | wc -l || echo 0)
            fi

            if [[ -n "$country" && "$country" != "unknown" ]]; then
                metrics+=("{country=\"${country}\"} ${ip_count}")
            fi
        done < <(nft list sets 2>/dev/null | grep 'set geoban_' | awk '{print $2}')
    fi

    if [[ ${#metrics[@]} -gt 0 ]]; then
        write_metric "nftban_geoban_ips_blocked" "gauge" \
            "Number of IP addresses blocked per country" "${metrics[@]}"
    else
        write_metric "nftban_geoban_ips_blocked" "gauge" \
            "Number of IP addresses blocked per country" "{country=\"none\"} 0"
    fi
}

collect_geoban_hit_stats() {
    # Collect hit statistics if counters exist
    # This is a placeholder - actual implementation depends on nftables rules with counters

    local total_hits=0

    # Try to get total geoban hits from nftables counters
    if nft list ruleset 2>/dev/null | grep -q 'geoban.*counter'; then
        total_hits=$(nft list ruleset 2>/dev/null | \
            grep 'geoban.*counter' | grep -oP 'packets \K\d+' | \
            awk '{sum+=$1} END {print sum}' || echo 0)
    fi

    write_metric "nftban_geoban_hits_total" "counter" \
        "Total connection attempts blocked by geo-blocking" " ${total_hits}"
}

# ====================================================================
# Main Collection Function
# ====================================================================

main() {
    local start_time
    start_time=$(date +%s.%N)

    # Initialize output file
    : > "$TMP_FILE"

    # Collect all metrics
    collect_geoban_countries
    collect_geoban_ips_by_country
    collect_geoban_hit_stats

    # Collection duration
    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc)

    write_metric "nftban_geoban_exporter_duration_seconds" "gauge" \
        "Time taken to collect geo-blocking metrics" " ${duration}"

    # Last update timestamp
    write_metric "nftban_geoban_exporter_last_update" "gauge" \
        "Unix timestamp of last successful collection" " $(date +%s)"

    # Atomic move
    chmod 644 "$TMP_FILE"
    mv -f "$TMP_FILE" "$OUTPUT_FILE"
}

# ====================================================================
# Execute
# ====================================================================

main "$@"
