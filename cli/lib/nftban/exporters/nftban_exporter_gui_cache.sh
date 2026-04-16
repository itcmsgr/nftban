#!/usr/bin/env bash
# TRANSITIONAL: sourced by unified exporter (collect.sh:1646). Scheduled for
# removal after nftban-ui migrates to daemon API. See V190_HANDOFF_PLAN.md.
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_exporter_gui_cache"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="GUI cache file generation (traffic history, dropped by country/port)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# Split from nftban_unified_exporter_collect.sh (BUG-L24: large file refactoring)
# Contains: generate_gui_cache_files(), generate_traffic_history(),
#           generate_dropped_by_country(), generate_dropped_by_port()

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_EXPORTER_GUI_CACHE_LOADED:-}" ]] && return 0
_EXPORTER_GUI_CACHE_LOADED="true"

generate_gui_cache_files() {
    local timestamp="$1"
    local collection_groups="${2:-live}"
    local cache_dir="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}"

    mkdir -p "$cache_dir" || return 1

    # -------------------------------------------------------------------------
    # 1. Traffic History (updated every run in LIVE group)
    # Maintains a rolling 24-sample history of bandwidth measurements
    # -------------------------------------------------------------------------
    if [[ " $collection_groups " =~ " live " ]]; then
        generate_traffic_history "$cache_dir" "$timestamp"
    fi

    # -------------------------------------------------------------------------
    # 2. Dropped by Country (updated in EXTENDED group - every 5 minutes)
    # Aggregates geoban blocks by country code from bans.log
    # -------------------------------------------------------------------------
    if [[ " $collection_groups " =~ " extended " ]]; then
        generate_dropped_by_country "$cache_dir" "$timestamp"
        generate_dropped_by_port "$cache_dir" "$timestamp"
    fi
}

# Generate traffic history JSON for GUI bandwidth charts
# Maintains a rolling window of 24 samples (one per hour at hourly intervals,
# or 24 most recent samples if collected more frequently)
generate_traffic_history() {
    local cache_dir="$1"
    local timestamp="$2"
    local history_file="$cache_dir/traffic_history.json"
    local max_samples=24

    # Get current bandwidth values from bandwidth state
    local current_rx_mbps=0 current_tx_mbps=0
    if [[ -f "$BANDWIDTH_STATE" ]]; then
        # Read the most recent interface totals
        # State file format: interface rx_bytes tx_bytes timestamp
        local total_rx=0 total_tx=0 prev_total_rx=0 prev_total_tx=0 prev_ts=0
        while read -r iface rx tx ts; do
            [[ -z "$iface" ]] && continue
            total_rx=$((total_rx + rx))
            total_tx=$((total_tx + tx))
            prev_ts=$ts
        done < "$BANDWIDTH_STATE"

        # Calculate Mbps from previous reading if available
        if [[ -f "${BANDWIDTH_STATE}.prev" ]]; then
            while read -r iface rx tx ts; do
                [[ -z "$iface" ]] && continue
                prev_total_rx=$((prev_total_rx + rx))
                prev_total_tx=$((prev_total_tx + tx))
            done < "${BANDWIDTH_STATE}.prev"

            local time_delta=$((timestamp - prev_ts))
            if [[ $time_delta -gt 0 ]]; then
                local rx_delta=$((total_rx - prev_total_rx))
                local tx_delta=$((total_tx - prev_total_tx))
                [[ $rx_delta -lt 0 ]] && rx_delta=0
                [[ $tx_delta -lt 0 ]] && tx_delta=0
                current_rx_mbps=$(calculate_mbps $rx_delta $time_delta)
                current_tx_mbps=$(calculate_mbps $tx_delta $time_delta)
            fi
        fi
        # Save current state as previous for next run
        cp "$BANDWIDTH_STATE" "${BANDWIDTH_STATE}.prev" 2>/dev/null || true
    fi

    # Load existing history or start fresh
    local existing_samples=""
    if [[ -f "$history_file" ]]; then
        existing_samples=$(cat "$history_file" 2>/dev/null || echo "[]")
    else
        existing_samples="[]"
    fi

    # Create new sample entry
    local time_str
    time_str=$(date -d "@$timestamp" '+%H:%M' 2>/dev/null || date '+%H:%M')
    local new_sample="{\"timestamp\":\"$time_str\",\"epoch\":$timestamp,\"rx_mbps\":$current_rx_mbps,\"tx_mbps\":$current_tx_mbps}"

    # Append to existing samples and keep only last max_samples
    # Use jq if available, otherwise use awk for JSON manipulation
    if command -v jq &>/dev/null; then
        echo "$existing_samples" | jq --argjson new "$new_sample" --argjson max "$max_samples" \
            '(. + [$new]) | .[-$max:]' > "${history_file}.tmp"
    else
        # Fallback: simple append with awk-based trimming
        # Parse existing JSON array, append new sample, output last 24
        awk -v new="$new_sample" -v max="$max_samples" '
        BEGIN { RS = "},{"; samples = "" }
        {
            gsub(/^\[/, "", $0)
            gsub(/\]$/, "", $0)
            if (samples != "" && $0 != "") samples = samples "},{" $0
            else if ($0 != "") samples = $0
        }
        END {
            if (samples == "") {
                printf "[%s]\n", new
            } else {
                printf "[%s},{%s]\n", samples, new
                # Note: This simple approach may exceed max_samples
                # Full trimming requires proper JSON parsing
            }
        }
        ' <<< "$existing_samples" > "${history_file}.tmp"
    fi

    mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
    chmod 644 "$history_file" 2>/dev/null || true
    log_debug "Updated traffic_history.json (rx: ${current_rx_mbps} Mbps, tx: ${current_tx_mbps} Mbps)"
}

# Generate dropped by country JSON for GUI geo-block visualization
# Parses bans.log for geoban entries and aggregates by country code
generate_dropped_by_country() {
    local cache_dir="$1"
    local timestamp="$2"
    local output_file="$cache_dir/dropped_by_country.json"
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"

    # Country code to name mapping
    declare -A country_names=(
        ["CN"]="China" ["RU"]="Russia" ["US"]="United States" ["BR"]="Brazil"
        ["IN"]="India" ["KR"]="South Korea" ["VN"]="Vietnam" ["TH"]="Thailand"
        ["ID"]="Indonesia" ["PH"]="Philippines" ["UA"]="Ukraine" ["DE"]="Germany"
        ["NL"]="Netherlands" ["FR"]="France" ["GB"]="United Kingdom" ["JP"]="Japan"
        ["HK"]="Hong Kong" ["TW"]="Taiwan" ["SG"]="Singapore" ["MY"]="Malaysia"
        ["PK"]="Pakistan" ["BD"]="Bangladesh" ["IR"]="Iran" ["TR"]="Turkey"
        ["PL"]="Poland" ["RO"]="Romania" ["BG"]="Bulgaria" ["CZ"]="Czech Republic"
        ["AR"]="Argentina" ["MX"]="Mexico" ["CO"]="Colombia" ["CL"]="Chile"
        ["ZA"]="South Africa" ["NG"]="Nigeria" ["EG"]="Egypt" ["KE"]="Kenya"
        ["AU"]="Australia" ["NZ"]="New Zealand" ["CA"]="Canada" ["IT"]="Italy"
        ["ES"]="Spain" ["PT"]="Portugal" ["SE"]="Sweden" ["NO"]="Norway"
        ["FI"]="Finland" ["DK"]="Denmark" ["AT"]="Austria" ["CH"]="Switzerland"
        ["BE"]="Belgium" ["IE"]="Ireland" ["IL"]="Israel" ["AE"]="UAE"
        ["SA"]="Saudi Arabia" ["QA"]="Qatar" ["KW"]="Kuwait"
    )

    # Parse bans.log for country data
    # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
    # Or older: geoban entries with country: XX pattern
    if [[ -f "$bans_log" ]]; then
        # Use gawk to aggregate by country code (requires gawk for match() with capture)
        # v1.13.13: Explicitly use gawk - added to package dependencies
        if ! command -v gawk &>/dev/null; then
            log_warn "gawk not installed - skipping country analytics"
            echo "[]" > "$output_file"
            return 0
        fi
        gawk -F'|' -v now="$timestamp" '
        BEGIN {
            # Initialize arrays
        }
        {
            cc = ""
            blocked = 0

            # New format: check 5th field for country code
            if (NF >= 5 && length($5) == 2 && $5 ~ /^[A-Z][A-Z]$/) {
                cc = $5
                if ($6 == "BANNED") blocked = 1
            }
            # Check for geoban source
            else if (tolower($3) == "geoban" || tolower($3) == "geoip") {
                cc = $5
                if ($6 == "BANNED") blocked = 1
            }
            # Legacy: look for country: XX pattern anywhere in line
            else if (match($0, /country:[[:space:]]*([A-Z][A-Z])/, arr)) {
                cc = arr[1]
                blocked = 1
            }
            else if (match($0, /COUNTRY=([A-Z][A-Z])/, arr)) {
                cc = arr[1]
                blocked = 1
            }

            if (cc != "" && blocked) {
                count[cc]++
            }
        }
        END {
            # Output as JSON array sorted by count
            # v1.13.13: POSIX-compatible (replaces gawk-only asorti)
            n = 0
            for (key in count) {
                n++
                sorted[n] = key
            }
            # Simple bubble sort by value (descending)
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if (count[sorted[j]] > count[sorted[i]]) {
                        tmp = sorted[i]
                        sorted[i] = sorted[j]
                        sorted[j] = tmp
                    }
                }
            }

            printf "[\n"
            for (i = 1; i <= n && i <= 20; i++) {
                cc = sorted[i]
                if (i > 1) printf ",\n"
                printf "  {\"code\":\"%s\",\"blocked\":%d}", cc, count[cc]
            }
            printf "\n]\n"
        }
        ' "$bans_log" > "${output_file}.tmp.raw" 2>/dev/null

        # Add country names using a second pass (bash associative array)
        if [[ -s "${output_file}.tmp.raw" ]]; then
            # Read raw output and add names
            local json_content=""
            local first=true
            while IFS= read -r line; do
                if [[ "$line" =~ \"code\":\"([A-Z]{2})\" ]]; then
                    local cc="${BASH_REMATCH[1]}"
                    local name="${country_names[$cc]:-$cc}"
                    # Replace the line to include name
                    line="${line/\}$/,\"name\":\"$name\"}"
                fi
                if [[ "$first" == "true" ]]; then
                    json_content="$line"
                    first=false
                else
                    json_content+=$'\n'"$line"
                fi
            done < "${output_file}.tmp.raw"
            echo "$json_content" > "${output_file}.tmp"
            rm -f "${output_file}.tmp.raw"
        else
            # Empty result
            echo "[]" > "${output_file}.tmp"
            rm -f "${output_file}.tmp.raw"
        fi
    else
        # No bans.log, create empty array
        echo "[]" > "${output_file}.tmp"
    fi

    mv "${output_file}.tmp" "$output_file" 2>/dev/null || true
    chmod 644 "$output_file" 2>/dev/null || true
    log_debug "Updated dropped_by_country.json"
}

# Generate dropped by port JSON for GUI port analysis visualization
# Parses portscan.log and bans.log for port-specific blocks
generate_dropped_by_port() {
    local cache_dir="$1"
    local timestamp="$2"
    local output_file="$cache_dir/dropped_by_port.json"
    local portscan_log="${NFTBAN_LOG_DIR}/portscan.log"
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"

    # Common port to protocol mapping
    declare -A port_protocols=(
        [21]="tcp" [22]="tcp" [23]="tcp" [25]="tcp" [53]="udp"
        [80]="tcp" [110]="tcp" [143]="tcp" [443]="tcp" [445]="tcp"
        [465]="tcp" [587]="tcp" [993]="tcp" [995]="tcp" [1433]="tcp"
        [1521]="tcp" [3306]="tcp" [3389]="tcp" [5432]="tcp" [5900]="tcp"
        [6379]="tcp" [8080]="tcp" [8443]="tcp" [27017]="tcp" [11211]="tcp"
        [123]="udp" [161]="udp" [1194]="udp" [500]="udp" [4500]="udp"
    )

    # Determine which log file to use
    local log_file="$portscan_log"
    [[ ! -f "$log_file" ]] && log_file="$bans_log"

    if [[ -f "$log_file" ]]; then
        # Use gawk to extract and aggregate port data (requires gawk for match() with capture)
        # v1.13.13: Explicitly use gawk - added to package dependencies
        if ! command -v gawk &>/dev/null; then
            log_warn "gawk not installed - skipping port analytics"
            echo "[]" > "$output_file"
            return 0
        fi
        gawk -v now="$timestamp" '
        BEGIN {
            # Port patterns to look for
        }
        {
            port = 0

            # Pattern 1: port:XXXX
            if (match($0, /port:[[:space:]]*([0-9]+)/, arr)) {
                port = arr[1]
            }
            # Pattern 2: dpt:XXXX (iptables style)
            else if (match($0, /dpt:([0-9]+)/, arr)) {
                port = arr[1]
            }
            # Pattern 3: DPT=XXXX
            else if (match($0, /DPT=([0-9]+)/, arr)) {
                port = arr[1]
            }
            # Pattern 4: :port at end of IP:port
            else if (match($0, /:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:([0-9]+)/, arr)) {
                port = arr[1]
            }
            # Pattern 5: portscan in source field with port in reason
            else if (tolower($0) ~ /portscan/ && match($0, /([0-9]+)\/(tcp|udp)/, arr)) {
                port = arr[1]
            }

            # Validate port range
            if (port > 0 && port <= 65535) {
                count[port]++
            }
        }
        END {
            # Output as JSON array sorted by count (descending)
            # v1.13.13: POSIX-compatible (replaces gawk-only asorti)
            n = 0
            for (key in count) {
                n++
                sorted[n] = key
            }
            # Bubble sort by value
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if (count[sorted[j]] > count[sorted[i]]) {
                        tmp = sorted[i]
                        sorted[i] = sorted[j]
                        sorted[j] = tmp
                    }
                }
            }

            printf "[\n"
            for (i = 1; i <= n && i <= 15; i++) {
                p = sorted[i]
                if (i > 1) printf ",\n"
                printf "  {\"port\":%d,\"blocked\":%d}", p, count[p]
            }
            printf "\n]\n"
        }
        ' "$log_file" > "${output_file}.tmp.raw" 2>/dev/null

        # Add protocol information using bash associative array
        if [[ -s "${output_file}.tmp.raw" ]]; then
            local json_content=""
            local first=true
            while IFS= read -r line; do
                if [[ "$line" =~ \"port\":([0-9]+) ]]; then
                    local port="${BASH_REMATCH[1]}"
                    local proto="${port_protocols[$port]:-tcp}"
                    # Replace closing brace with protocol field
                    line="${line/\}$/,\"protocol\":\"$proto\"}"
                fi
                if [[ "$first" == "true" ]]; then
                    json_content="$line"
                    first=false
                else
                    json_content+=$'\n'"$line"
                fi
            done < "${output_file}.tmp.raw"
            echo "$json_content" > "${output_file}.tmp"
            rm -f "${output_file}.tmp.raw"
        else
            echo "[]" > "${output_file}.tmp"
            rm -f "${output_file}.tmp.raw"
        fi
    else
        # No log files, create empty array
        echo "[]" > "${output_file}.tmp"
    fi

    mv "${output_file}.tmp" "$output_file" 2>/dev/null || true
    chmod 644 "$output_file" 2>/dev/null || true
    log_debug "Updated dropped_by_port.json"
}
