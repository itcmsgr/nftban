#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_firewall_exporter"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Prometheus exporter for NFTables firewall metrics"
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
# shellcheck disable=SC1091
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# ====================================================================
# LIBRARY LOADING
# ====================================================================

# Determine library path
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR}"

# Source common exporter utilities
if [[ -f "${NFTBAN_LIB_DIR}/lib/exporter_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/exporter_utils.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/exporter_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/exporter_utils.sh" || return 1
fi

# ====================================================================
# CONFIGURATION
# ====================================================================

# Textfile collector output
OUTPUT_FILE="${OUTPUT_FILE:-/var/lib/node_exporter/textfile_collector/nftban_firewall.prom}"

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
# Collect NFTables Metrics
# ====================================================================

collect_nftables_rules() {
    # Total rules count
    local total_rules
    total_rules=$(nft list ruleset 2>/dev/null | grep -c '^[[:space:]]*[^#]' || echo 0)

    write_metric "nftban_nftables_rules_total" "gauge" "Total number of nftables rules" \
        " ${total_rules}"
}

collect_nftables_chains() {
    # Total chains count
    local total_chains
    total_chains=$(nft list chains 2>/dev/null | grep -c 'chain ' || echo 0)

    write_metric "nftban_nftables_chains_total" "gauge" "Total number of nftables chains" \
        " ${total_chains}"
}

collect_nftables_sets() {
    # NFTBan sets count
    local nftban_sets=0
    local temp_sets=0
    local perm_sets=0

    if nft list sets 2>/dev/null | grep -q 'nftban'; then
        # Use subshell to avoid grep exit code 1 when count is 0
        nftban_sets=$(nft list sets 2>/dev/null | grep -c 'set nftban' 2>/dev/null) || nftban_sets=0
        temp_sets=$(nft list sets 2>/dev/null | grep -c 'set nftban.*temp' 2>/dev/null) || temp_sets=0
        perm_sets=$(nft list sets 2>/dev/null | grep -c 'set nftban.*perm' 2>/dev/null) || perm_sets=0
    fi

    write_metric "nftban_nftables_sets_total" "gauge" "Total number of NFTBan nftables sets" \
        "{type=\"all\"} ${nftban_sets}" \
        "{type=\"temporary\"} ${temp_sets}" \
        "{type=\"permanent\"} ${perm_sets}"
}

collect_nftables_counters() {
    # Packet counters from nftables
    local input_packets=0
    local forward_packets=0
    local output_packets=0

    # Try to get counter stats if available
    if nft list chain inet filter input 2>/dev/null | grep -q 'counter'; then
        input_packets=$(nft list chain inet filter input 2>/dev/null | \
            grep -oP 'packets \K\d+' | head -1 || echo 0)
    fi

    if nft list chain inet filter forward 2>/dev/null | grep -q 'counter'; then
        forward_packets=$(nft list chain inet filter forward 2>/dev/null | \
            grep -oP 'packets \K\d+' | head -1 || echo 0)
    fi

    if nft list chain inet filter output 2>/dev/null | grep -q 'counter'; then
        output_packets=$(nft list chain inet filter output 2>/dev/null | \
            grep -oP 'packets \K\d+' | head -1 || echo 0)
    fi

    write_metric "nftban_nftables_packets_total" "counter" "Total packets processed by chain" \
        "{chain=\"input\"} ${input_packets}" \
        "{chain=\"forward\"} ${forward_packets}" \
        "{chain=\"output\"} ${output_packets}"
}

collect_drop_stats() {
    # Dropped packets count
    local dropped=0

    if nft list ruleset 2>/dev/null | grep -q 'drop'; then
        # This is approximate - actual drop counters depend on ruleset
        dropped=$(nft list ruleset 2>/dev/null | grep -c 'drop' || echo 0)
    fi

    write_metric "nftban_nftables_drop_rules" "gauge" "Number of drop rules" \
        " ${dropped}"
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
    collect_nftables_rules
    collect_nftables_chains
    collect_nftables_sets
    collect_nftables_counters
    collect_drop_stats

    # Collection duration
    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $start_time" | bc)

    write_metric "nftban_firewall_exporter_duration_seconds" "gauge" \
        "Time taken to collect firewall metrics" " ${duration}"

    # Last update timestamp
    write_metric "nftban_firewall_exporter_last_update" "gauge" \
        "Unix timestamp of last successful collection" " $(date +%s)"

    # Atomic move
    chmod 644 "$TMP_FILE"
    mv -f "$TMP_FILE" "$OUTPUT_FILE"
}

# ====================================================================
# Execute
# ====================================================================

main "$@"
