#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_checks" meta:type="lib" meta:version="1.48.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Pure check functions returning consistent JSON, reusable across health/status/smoke"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,stat,file"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,PORTSCAN_EVE_FRESHNESS_THRESHOLD"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail
# - NO side effects, NO global state mutations
# - NO stdout noise except the JSON result
#
# **Usage**
# source "${NFTBAN_LIB_DIR}/lib/nftban_checks.sh"
# result=$(nftban_check_suricata_status)
# ok=$(echo "$result" | jq -r '.ok')
#
# meta:created_date="2026-02-10"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

[[ -n "${_NFTBAN_CHECKS_LOADED:-}" ]] && return 0

# =============================================================================
# INTERNAL HELPERS (not exported)
# =============================================================================

# _checks_timestamp - Returns ISO 8601 UTC timestamp
# Used internally for checked_at field
_checks_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# _checks_eve_freshest_mtime - Returns freshest mtime across eve-alerts*.json
# Handles Suricata 7.x threaded logging (eve-alerts.1.json, eve-alerts.2.json, etc.)
# Args: $1=eve_dir
# Returns: epoch seconds via stdout, or 0 if no matching files found
_checks_eve_freshest_mtime() {
    local eve_dir="${1:?missing eve_dir}"
    local freshest=0
    local f m

    # Ensure glob expands to nothing instead of literal pattern
    shopt -s nullglob

    for f in "$eve_dir"/eve-alerts*.json; do
        # Skip non-regular files and symlinks to missing targets
        [[ -f "$f" ]] || continue

        # stat may fail (permissions/race). Ignore failures safely.
        if m=$(stat -L -c %Y -- "$f" 2>/dev/null); then
            [[ "$m" =~ ^[0-9]+$ ]] || continue
            (( m > freshest )) && freshest="$m"
        fi
    done

    shopt -u nullglob
    echo "$freshest"
}

# _checks_json_result - Builds consistent JSON output
# Args: $1=ok(true/false), $2=data_json, $3=error_msg
_checks_json_result() {
    local ok="${1:-false}"
    local data="${2:-"{}"}"
    local error="${3:-}"
    local ts
    ts=$(_checks_timestamp)

    # Escape error message for JSON
    error="${error//\\/\\\\}"
    error="${error//\"/\\\"}"
    error="${error//$'\n'/\\n}"

    printf '{"ok":%s,"checked_at":"%s","data":%s,"error":"%s"}\n' \
        "$ok" "$ts" "$data" "$error"
}

# =============================================================================
# CHECK: Suricata Status (3-tier check)
# =============================================================================

# nftban_check_suricata_status - Full Suricata health check
# Returns JSON with: installed, service_active, eve_fresh, rules_loaded
# Return 0 always (check executed), data shows actual state
# NOTE: Supports Suricata 7.x threaded logging (eve-alerts.1.json, eve-alerts.2.json, etc.)
nftban_check_suricata_status() {
    # Use FHS central config paths
    local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
    local eve_file="${1:-${eve_dir}/eve-alerts.json}"
    local eve_threshold="${2:-${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}}"  # seconds

    local installed="false"
    local service_active="false"
    local eve_exists="false"
    local eve_fresh="false"
    local eve_age=-1
    local rules_loaded=0
    local banning_active="false"
    local status_text="not_installed"
    local eve_source="none"

    # Tier 1: Binary check
    if command -v suricata &>/dev/null; then
        installed="true"
        status_text="installed_stopped"

        # Tier 2: Service check
        if systemctl is-active suricata.service &>/dev/null; then
            service_active="true"
            status_text="running_no_eve"

            # Tier 3: EVE freshness check
            # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
            local freshest_mtime now_ts
            freshest_mtime=$(_checks_eve_freshest_mtime "$eve_dir")
            now_ts=$(date +%s)

            if [[ $freshest_mtime -gt 0 ]]; then
                eve_exists="true"
                eve_age=$(( now_ts - freshest_mtime ))

                # Determine which file was freshest (for logging/debugging)
                if [[ -f "$eve_file" ]]; then
                    local main_mtime
                    main_mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || main_mtime=0
                    if [[ $main_mtime -eq $freshest_mtime ]]; then
                        eve_source="main"
                    else
                        eve_source="threaded"
                    fi
                else
                    eve_source="threaded"
                fi

                if [[ $eve_age -le $eve_threshold ]]; then
                    eve_fresh="true"
                    status_text="active"

                    # Get rules_loaded from any EVE JSON file that has stats
                    # Check main file first, then any threaded files
                    shopt -s nullglob
                    for ef in "$eve_file" "$eve_dir"/eve-alerts.*.json; do
                        [[ -f "$ef" ]] || continue
                        rules_loaded=$(grep -o '"rules_loaded":[0-9]*' "$ef" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
                        [[ "${rules_loaded:-0}" -gt 0 ]] && break
                    done
                    shopt -u nullglob
                    rules_loaded="${rules_loaded:-0}"

                    if [[ "$rules_loaded" -eq 0 ]]; then
                        status_text="broken_no_rules"
                    fi
                else
                    status_text="degraded_eve_stale"
                fi
            fi

            # Check if nftban-suricata banning service is active
            if systemctl is-active nftban-suricata.service &>/dev/null; then
                banning_active="true"
            fi
        fi
    fi

    # Build data JSON (added eve_source for debugging threaded vs main file)
    local data
    data=$(printf '{"installed":%s,"service_active":%s,"eve_exists":%s,"eve_fresh":%s,"eve_age_sec":%d,"eve_threshold_sec":%d,"eve_source":"%s","rules_loaded":%d,"banning_active":%s,"status":"%s"}' \
        "$installed" "$service_active" "$eve_exists" "$eve_fresh" \
        "$eve_age" "$eve_threshold" "$eve_source" "$rules_loaded" "$banning_active" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: Service Metrics
# =============================================================================

# nftban_check_service_metrics - Get service status with PID, memory, uptime
# Args: $1=systemd_unit (e.g., "nftables.service")
# Returns JSON with: exists, active, enabled, pid, memory_mb, uptime_sec
nftban_check_service_metrics() {
    local unit="${1:-}"

    if [[ -z "$unit" ]]; then
        _checks_json_result "false" "{}" "unit parameter required"
        return 1
    fi

    local exists="false"
    local active="false"
    local enabled="false"
    local pid="null"
    local memory_mb="null"
    local uptime_sec="null"
    local status_text="not_installed"

    # Check if unit exists
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "$unit"; then
        exists="true"
        status_text="inactive"

        # Check enabled state
        if systemctl is-enabled "$unit" &>/dev/null; then
            enabled="true"
            status_text="enabled_stopped"
        fi

        # Check active state
        if systemctl is-active "$unit" &>/dev/null; then
            active="true"
            status_text="active"

            # Get PID
            local main_pid
            main_pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null || echo "0")

            if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
                pid="$main_pid"

                # Get memory (RSS in MB)
                local rss_kb
                rss_kb=$(ps -o rss= -p "$main_pid" 2>/dev/null | tr -d ' ' || echo "0")
                if [[ -n "$rss_kb" && "$rss_kb" != "0" ]]; then
                    # Calculate MB with one decimal
                    memory_mb=$(awk "BEGIN {printf \"%.1f\", $rss_kb/1024}")
                fi

                # Get uptime from process start time
                local start_time
                start_time=$(ps -o lstart= -p "$main_pid" 2>/dev/null || echo "")
                if [[ -n "$start_time" ]]; then
                    local start_epoch now_epoch
                    start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    if [[ "$start_epoch" != "0" ]]; then
                        uptime_sec=$((now_epoch - start_epoch))
                    fi
                fi
            fi
        fi
    fi

    # Build data JSON
    local data
    data=$(printf '{"unit":"%s","exists":%s,"active":%s,"enabled":%s,"pid":%s,"memory_mb":%s,"uptime_sec":%s,"status":"%s"}' \
        "$unit" "$exists" "$active" "$enabled" "$pid" "$memory_mb" "$uptime_sec" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: Timer Status
# =============================================================================

# nftban_check_timer_status - Get timer status with next/last run times
# Args: $1=timer_unit (e.g., "nftban-health.timer")
# Returns JSON with: exists, active, enabled, next_run_epoch, last_run_epoch
nftban_check_timer_status() {
    local timer="${1:-}"

    if [[ -z "$timer" ]]; then
        _checks_json_result "false" "{}" "timer parameter required"
        return 1
    fi

    local exists="false"
    local active="false"
    local enabled="false"
    local next_run_epoch="null"
    local last_run_epoch="null"
    local status_text="not_installed"

    # Check if timer exists
    if systemctl list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
        exists="true"
        status_text="inactive"

        # Check enabled state
        if systemctl is-enabled "$timer" &>/dev/null; then
            enabled="true"
            status_text="enabled_stopped"
        fi

        # Check active state
        if systemctl is-active "$timer" &>/dev/null; then
            active="true"
            status_text="active"

            # Get next run time (parse systemctl show)
            local next_usec
            next_usec=$(systemctl show "$timer" --property=NextElapseUSecRealtime --value 2>/dev/null || echo "")
            if [[ -n "$next_usec" && "$next_usec" != "n/a" ]]; then
                # Convert from human-readable to epoch
                local next_date
                next_date=$(date -d "$next_usec" +%s 2>/dev/null || echo "")
                if [[ -n "$next_date" ]]; then
                    next_run_epoch="$next_date"
                fi
            fi
        fi

        # Get last run time from corresponding service
        local service_unit="${timer%.timer}.service"
        local last_time
        last_time=$(systemctl show "$service_unit" --property=ExecMainExitTimestamp --value 2>/dev/null || echo "")
        if [[ -n "$last_time" && "$last_time" != "n/a" && "$last_time" != "" ]]; then
            local last_epoch
            last_epoch=$(date -d "$last_time" +%s 2>/dev/null || echo "")
            if [[ -n "$last_epoch" ]]; then
                last_run_epoch="$last_epoch"
            fi
        fi
    fi

    # Build data JSON
    local data
    data=$(printf '{"timer":"%s","exists":%s,"active":%s,"enabled":%s,"next_run_epoch":%s,"last_run_epoch":%s,"status":"%s"}' \
        "$timer" "$exists" "$active" "$enabled" "$next_run_epoch" "$last_run_epoch" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: Binary Integrity
# =============================================================================

# nftban_check_binary_integrity - Check if binary is valid ELF file
# Args: $1=binary_path (e.g., "/usr/lib/nftban/bin/nftban-core")
# Returns JSON with: exists, is_elf, file_type, size_bytes
nftban_check_binary_integrity() {
    local binary="${1:-}"

    if [[ -z "$binary" ]]; then
        _checks_json_result "false" "{}" "binary parameter required"
        return 1
    fi

    local exists="false"
    local is_elf="false"
    local file_type=""
    local size_bytes=0
    local status_text="missing"

    if [[ -f "$binary" ]]; then
        exists="true"
        size_bytes=$(stat -c %s "$binary" 2>/dev/null || echo "0")

        # Get file type (guard: 'file' may not be installed on minimal systems)
        if command -v file >/dev/null 2>&1; then
            file_type=$(file -b "$binary" 2>/dev/null || echo "unknown")
        else
            file_type="unknown (file command not installed)"
        fi
        # Escape for JSON
        file_type="${file_type//\"/\\\"}"

        if [[ "$file_type" == *"ELF"* ]] || [[ "$file_type" == *"unknown"* ]]; then
            is_elf="true"
            status_text="valid"
        else
            status_text="corrupted"
        fi
    fi

    # Build data JSON
    local data
    data=$(printf '{"path":"%s","exists":%s,"is_elf":%s,"file_type":"%s","size_bytes":%d,"status":"%s"}' \
        "$binary" "$exists" "$is_elf" "$file_type" "$size_bytes" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# nftban_check_all_binaries - Check all NFTBan core binaries
# Returns JSON with array of binary check results
nftban_check_all_binaries() {
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    local binaries=(
        "${lib_dir}/bin/nftban-core"
        "${lib_dir}/bin/nftband"
    )

    local all_valid="true"
    local checked=0
    local corrupted=0
    local missing=0
    local results=""

    for binary in "${binaries[@]}"; do
        local result
        result=$(nftban_check_binary_integrity "$binary")
        local status
        status=$(echo "$result" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        case "$status" in
            valid) ((++checked)) ;;
            corrupted) ((++corrupted)); all_valid="false" ;;
            missing) ((++missing)); all_valid="false" ;;
        esac

        # Extract just the data portion for the array
        local data
        data=$(echo "$result" | grep -o '"data":{[^}]*}' | sed 's/"data"://' || echo '{}')
        [[ -n "$results" ]] && results+=","
        results+="$data"
    done

    # Build aggregated result
    local data
    data=$(printf '{"all_valid":%s,"checked":%d,"corrupted":%d,"missing":%d,"binaries":[%s]}' \
        "$all_valid" "$checked" "$corrupted" "$missing" "$results")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: Config Exists
# =============================================================================

# nftban_check_config_exists - Check if config file exists and is readable
# Args: $1=config_path (e.g., "/etc/nftban/conf.d/ddos/main.conf")
# Returns JSON with: exists, readable, size_bytes, has_local_override
nftban_check_config_exists() {
    local config="${1:-}"

    if [[ -z "$config" ]]; then
        _checks_json_result "false" "{}" "config parameter required"
        return 1
    fi

    local exists="false"
    local readable="false"
    local size_bytes=0
    local has_local="false"
    local status_text="missing"

    if [[ -f "$config" ]]; then
        exists="true"
        size_bytes=$(stat -c %s "$config" 2>/dev/null || echo "0")

        if [[ -r "$config" ]]; then
            readable="true"
            status_text="ok"
        else
            status_text="not_readable"
        fi

        # Check for .local override
        if [[ -f "${config}.local" ]]; then
            has_local="true"
        fi
    fi

    # Build data JSON
    local data
    data=$(printf '{"path":"%s","exists":%s,"readable":%s,"size_bytes":%d,"has_local_override":%s,"status":"%s"}' \
        "$config" "$exists" "$readable" "$size_bytes" "$has_local" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: EVE Log Freshness (standalone, lighter than full suricata check)
# =============================================================================

# nftban_check_eve_freshness - Check EVE log freshness only
# Args: $1=eve_file (or eve_dir), $2=threshold_seconds
# Returns JSON with: exists, fresh, age_sec
# NOTE: Supports Suricata 7.x threaded logging (eve-alerts.1.json, eve-alerts.2.json, etc.)
nftban_check_eve_freshness() {
    # Use FHS central config paths
    local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
    local eve_file="${1:-${eve_dir}/eve-alerts.json}"
    local threshold="${2:-${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}}"

    local exists="false"
    local fresh="false"
    local age_sec=-1
    local status_text="missing"
    local eve_source="none"

    # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
    local freshest_mtime now_ts
    freshest_mtime=$(_checks_eve_freshest_mtime "$eve_dir")
    now_ts=$(date +%s)

    if [[ $freshest_mtime -gt 0 ]]; then
        exists="true"
        age_sec=$(( now_ts - freshest_mtime ))

        # Determine source (main vs threaded)
        if [[ -f "$eve_file" ]]; then
            local main_mtime
            main_mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || main_mtime=0
            if [[ $main_mtime -eq $freshest_mtime ]]; then
                eve_source="main"
            else
                eve_source="threaded"
            fi
        else
            eve_source="threaded"
        fi

        if [[ $age_sec -le $threshold ]]; then
            fresh="true"
            status_text="fresh"
        else
            status_text="stale"
        fi
    fi

    local data
    data=$(printf '{"path":"%s","exists":%s,"fresh":%s,"age_sec":%d,"threshold_sec":%d,"eve_source":"%s","status":"%s"}' \
        "$eve_file" "$exists" "$fresh" "$age_sec" "$threshold" "$eve_source" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: Firewall Conflict Detection
# =============================================================================

# nftban_check_firewall_conflict - Check if a conflicting firewall is active
# Args: $1=firewall_name (fail2ban|firewalld|ufw|csf|iptables)
# Returns JSON with: installed, active, conflict_level
nftban_check_firewall_conflict() {
    local fw="${1:-}"

    if [[ -z "$fw" ]]; then
        _checks_json_result "false" "{}" "firewall parameter required"
        return 1
    fi

    local installed="false"
    local active="false"
    local enabled="false"
    local conflict_level="none"
    local status_text="not_installed"

    case "$fw" in
        fail2ban)
            if command -v fail2ban-client &>/dev/null || [[ -f /etc/fail2ban/fail2ban.conf ]]; then
                installed="true"
                status_text="installed"
                if systemctl is-enabled fail2ban &>/dev/null; then
                    enabled="true"
                    conflict_level="warning"
                fi
                if systemctl is-active fail2ban &>/dev/null; then
                    active="true"
                    conflict_level="high"
                    status_text="active"
                fi
            fi
            ;;
        firewalld)
            if command -v firewall-cmd &>/dev/null; then
                installed="true"
                status_text="installed"
                if systemctl is-enabled firewalld &>/dev/null; then
                    enabled="true"
                    conflict_level="warning"
                fi
                if systemctl is-active firewalld &>/dev/null; then
                    active="true"
                    conflict_level="critical"
                    status_text="active"
                fi
            fi
            ;;
        ufw)
            if command -v ufw &>/dev/null; then
                installed="true"
                status_text="installed"
                if ufw status 2>/dev/null | grep -q "^Status: active"; then
                    active="true"
                    enabled="true"
                    conflict_level="critical"
                    status_text="active"
                fi
            fi
            ;;
        csf)
            # v1.48.0: Check both config file AND binary (CSF may be in non-standard path)
            if [[ -f /etc/csf/csf.conf ]] || command -v csf &>/dev/null; then
                installed="true"
                status_text="installed"
                # Check if CSF/lfd is actually running (service state is source of truth)
                if systemctl is-active lfd &>/dev/null 2>&1; then
                    active="true"
                    enabled="true"
                    if grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
                        conflict_level="critical"
                        status_text="active_production"
                    else
                        conflict_level="critical"
                        status_text="active_testing"
                    fi
                elif grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
                    conflict_level="warning"
                    status_text="disabled_production_config"
                elif grep -q "^TESTING = \"1\"" /etc/csf/csf.conf 2>/dev/null; then
                    conflict_level="info"
                    status_text="disabled_testing_config"
                fi
            fi
            ;;
        iptables)
            if systemctl list-unit-files iptables.service 2>/dev/null | grep -q iptables; then
                installed="true"
                status_text="installed"
                if systemctl is-enabled iptables &>/dev/null; then
                    enabled="true"
                    conflict_level="warning"
                fi
                if systemctl is-active iptables &>/dev/null || systemctl is-active ip6tables &>/dev/null; then
                    active="true"
                    conflict_level="high"
                    status_text="active"
                fi
            fi
            ;;
        *)
            _checks_json_result "false" "{}" "unknown firewall: $fw"
            return 1
            ;;
    esac

    local data
    data=$(printf '{"firewall":"%s","installed":%s,"active":%s,"enabled":%s,"conflict_level":"%s","status":"%s"}' \
        "$fw" "$installed" "$active" "$enabled" "$conflict_level" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: DNS Resolution
# =============================================================================

# nftban_check_dns - Check if DNS resolution is working
# Args: $1=hostname_to_test (default: google.com)
# Returns JSON with: working, resolver, latency_ms
nftban_check_dns() {
    local hostname="${1:-google.com}"

    local working="false"
    local resolver=""
    local latency_ms=-1
    local status_text="failed"

    # Get resolver from resolv.conf
    resolver=$(grep -m1 "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "unknown")

    # Test DNS with timing
    local start_ns end_ns
    start_ns=$(date +%s%N)

    if host "$hostname" &>/dev/null || nslookup "$hostname" &>/dev/null 2>&1; then
        end_ns=$(date +%s%N)
        working="true"
        status_text="ok"
        latency_ms=$(( (end_ns - start_ns) / 1000000 ))
    fi

    local data
    data=$(printf '{"hostname":"%s","working":%s,"resolver":"%s","latency_ms":%d,"status":"%s"}' \
        "$hostname" "$working" "$resolver" "$latency_ms" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: LOAD AVERAGE
# =============================================================================
# Returns: JSON with load averages and status
# Status: ok, warning, critical based on configurable thresholds

nftban_check_load_average() {
    # Check system load average
    # Args: $1 = warning threshold (default: 10)
    #       $2 = critical threshold (default: 20)
    # Returns: JSON with load 1m/5m/15m, cpu_count, per_cpu load, status

    local warn_threshold="${1:-${NFTBAN_WATCHDOG_LOAD_WARNING:-10}}"
    local crit_threshold="${2:-${NFTBAN_WATCHDOG_LOAD_CRITICAL:-20}}"

    local load_1m="0" load_5m="0" load_15m="0"
    local cpu_count=1
    local status_text="ok"

    # Get load from /proc/loadavg
    if [[ -r /proc/loadavg ]]; then
        read -r load_1m load_5m load_15m _ < /proc/loadavg
    fi

    # Get CPU count
    cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

    # Calculate per-CPU load (5m is most stable)
    local per_cpu_load
    per_cpu_load=$(awk "BEGIN {printf \"%.2f\", $load_5m / $cpu_count}")

    # Determine status based on 5m load
    local load_int=${load_5m%.*}
    load_int=${load_int:-0}
    if [[ $load_int -ge $crit_threshold ]]; then
        status_text="critical"
    elif [[ $load_int -ge $warn_threshold ]]; then
        status_text="warning"
    fi

    local data
    data=$(printf '{"load_1m":%s,"load_5m":%s,"load_15m":%s,"cpu_count":%d,"per_cpu_load":%s,"warn_threshold":%d,"crit_threshold":%d,"status":"%s"}' \
        "$load_1m" "$load_5m" "$load_15m" "$cpu_count" "$per_cpu_load" "$warn_threshold" "$crit_threshold" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: MEMORY USAGE
# =============================================================================
# Returns: JSON with memory stats and status

nftban_check_memory_usage() {
    # Check system memory usage
    # Args: $1 = warning threshold % (default: 80)
    #       $2 = critical threshold % (default: 95)
    # Returns: JSON with total, used, available, percent, swap, status

    local warn_threshold="${1:-${NFTBAN_WATCHDOG_MEM_WARNING:-80}}"
    local crit_threshold="${2:-${NFTBAN_WATCHDOG_MEM_CRITICAL:-95}}"

    local total_kb=0 available_kb=0 free_kb=0 buffers_kb=0 cached_kb=0
    local swap_total_kb=0 swap_free_kb=0
    local status_text="ok"

    # Parse /proc/meminfo
    if [[ -r /proc/meminfo ]]; then
        while IFS=': ' read -r key value _; do
            case "$key" in
                MemTotal) total_kb="${value//[^0-9]/}" ;;
                MemAvailable) available_kb="${value//[^0-9]/}" ;;
                MemFree) free_kb="${value//[^0-9]/}" ;;
                Buffers) buffers_kb="${value//[^0-9]/}" ;;
                Cached) cached_kb="${value//[^0-9]/}" ;;
                SwapTotal) swap_total_kb="${value//[^0-9]/}" ;;
                SwapFree) swap_free_kb="${value//[^0-9]/}" ;;
            esac
        done < /proc/meminfo
    fi

    # Calculate available if not directly available (older kernels)
    if [[ $available_kb -eq 0 && $total_kb -gt 0 ]]; then
        available_kb=$((free_kb + buffers_kb + cached_kb))
    fi

    # Calculate percentages
    local used_kb=$((total_kb - available_kb))
    local used_percent=0
    local swap_used_percent=0

    if [[ $total_kb -gt 0 ]]; then
        used_percent=$((used_kb * 100 / total_kb))
    fi

    if [[ $swap_total_kb -gt 0 ]]; then
        local swap_used_kb=$((swap_total_kb - swap_free_kb))
        swap_used_percent=$((swap_used_kb * 100 / swap_total_kb))
    fi

    # Convert to MB for readability
    local total_mb=$((total_kb / 1024))
    local used_mb=$((used_kb / 1024))
    local available_mb=$((available_kb / 1024))
    local swap_total_mb=$((swap_total_kb / 1024))
    local swap_used_mb=$(((swap_total_kb - swap_free_kb) / 1024))

    # Determine status
    if [[ $used_percent -ge $crit_threshold ]]; then
        status_text="critical"
    elif [[ $used_percent -ge $warn_threshold ]]; then
        status_text="warning"
    fi

    local data
    data=$(printf '{"total_mb":%d,"used_mb":%d,"available_mb":%d,"used_percent":%d,"swap_total_mb":%d,"swap_used_mb":%d,"swap_used_percent":%d,"warn_threshold":%d,"crit_threshold":%d,"status":"%s"}' \
        "$total_mb" "$used_mb" "$available_mb" "$used_percent" "$swap_total_mb" "$swap_used_mb" "$swap_used_percent" "$warn_threshold" "$crit_threshold" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: DISK USAGE
# =============================================================================
# Returns: JSON with disk usage for specified path

nftban_check_disk_usage() {
    # Check disk usage for a path
    # Args: $1 = path to check (default: /var/log)
    #       $2 = warning threshold % (default: 80)
    #       $3 = critical threshold % (default: 95)
    # Returns: JSON with path, total, used, available, percent, status

    local check_path="${1:-${NFTBAN_WATCHDOG_DISK_PATH:-/var/log}}"
    local warn_threshold="${2:-${NFTBAN_WATCHDOG_DISK_WARNING:-80}}"
    local crit_threshold="${3:-${NFTBAN_WATCHDOG_DISK_CRITICAL:-95}}"

    local total_kb=0 used_kb=0 available_kb=0 used_percent=0
    local filesystem="" mount_point=""
    local status_text="ok"

    # Get disk usage via df
    if df -P "$check_path" &>/dev/null; then
        local df_output
        df_output=$(df -P "$check_path" 2>/dev/null | tail -1)
        read -r filesystem total_kb used_kb available_kb used_percent mount_point <<< "$df_output"
        used_percent="${used_percent%\%}"
        used_percent="${used_percent:-0}"
    fi

    # Convert to GB for readability
    local total_gb used_gb available_gb
    total_gb=$(awk "BEGIN {printf \"%.1f\", $total_kb / 1048576}")
    used_gb=$(awk "BEGIN {printf \"%.1f\", $used_kb / 1048576}")
    available_gb=$(awk "BEGIN {printf \"%.1f\", $available_kb / 1048576}")

    # Determine status
    if [[ $used_percent -ge $crit_threshold ]]; then
        status_text="critical"
    elif [[ $used_percent -ge $warn_threshold ]]; then
        status_text="warning"
    fi

    local data
    data=$(printf '{"path":"%s","filesystem":"%s","mount_point":"%s","total_gb":%s,"used_gb":%s,"available_gb":%s,"used_percent":%d,"warn_threshold":%d,"crit_threshold":%d,"status":"%s"}' \
        "$check_path" "$filesystem" "$mount_point" "$total_gb" "$used_gb" "$available_gb" "$used_percent" "$warn_threshold" "$crit_threshold" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: I/O WAIT
# =============================================================================
# Returns: JSON with I/O wait percentage

nftban_check_iowait() {
    # Check CPU I/O wait percentage
    # Args: $1 = warning threshold % (default: 20)
    #       $2 = critical threshold % (default: 40)
    # Returns: JSON with iowait percent and status

    local warn_threshold="${1:-${NFTBAN_WATCHDOG_IOWAIT_WARNING:-20}}"
    local crit_threshold="${2:-${NFTBAN_WATCHDOG_IOWAIT_CRITICAL:-40}}"

    local iowait_percent=0
    local status_text="ok"

    # Get I/O wait from /proc/stat (requires two samples for delta)
    if [[ -r /proc/stat ]]; then
        # Read first sample
        local cpu_line1
        cpu_line1=$(grep '^cpu ' /proc/stat)
        local user1 nice1 system1 idle1 iowait1
        read -r _ user1 nice1 system1 idle1 iowait1 _ <<< "$cpu_line1"

        # Short sleep for delta
        sleep 0.1

        # Read second sample
        local cpu_line2
        cpu_line2=$(grep '^cpu ' /proc/stat)
        local user2 nice2 system2 idle2 iowait2
        read -r _ user2 nice2 system2 idle2 iowait2 _ <<< "$cpu_line2"

        # Calculate deltas
        local total1=$((user1 + nice1 + system1 + idle1 + iowait1))
        local total2=$((user2 + nice2 + system2 + idle2 + iowait2))
        local total_delta=$((total2 - total1))
        local iowait_delta=$((iowait2 - iowait1))

        if [[ $total_delta -gt 0 ]]; then
            iowait_percent=$((iowait_delta * 100 / total_delta))
        fi
    fi

    # Determine status
    if [[ $iowait_percent -ge $crit_threshold ]]; then
        status_text="critical"
    elif [[ $iowait_percent -ge $warn_threshold ]]; then
        status_text="warning"
    fi

    local data
    data=$(printf '{"iowait_percent":%d,"warn_threshold":%d,"crit_threshold":%d,"status":"%s"}' \
        "$iowait_percent" "$warn_threshold" "$crit_threshold" "$status_text")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# CHECK: SYSTEM RESOURCES (Combined)
# =============================================================================
# Returns: JSON with all resource metrics in one call

nftban_check_system_resources() {
    # Combined check for all system resources
    # Returns: JSON with load, memory, disk, iowait all in one response
    # This is more efficient than calling each check separately

    local overall_status="ok"

    # Load average
    local load_1m="0" load_5m="0" load_15m="0"
    if [[ -r /proc/loadavg ]]; then
        read -r load_1m load_5m load_15m _ < /proc/loadavg
    fi
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)

    # Memory
    local mem_total_kb=0 mem_available_kb=0
    if [[ -r /proc/meminfo ]]; then
        mem_total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
        mem_available_kb=$(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    fi
    local mem_used_percent=0
    if [[ $mem_total_kb -gt 0 ]]; then
        mem_used_percent=$(( (mem_total_kb - mem_available_kb) * 100 / mem_total_kb ))
    fi

    # Disk (/var/log)
    local disk_used_percent=0
    if df -P /var/log &>/dev/null; then
        disk_used_percent=$(df -P /var/log 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    fi

    # Determine overall status
    local load_int=${load_5m%.*}
    load_int=${load_int:-0}
    if [[ $load_int -ge 20 ]] || [[ $mem_used_percent -ge 95 ]] || [[ $disk_used_percent -ge 95 ]]; then
        overall_status="critical"
    elif [[ $load_int -ge 10 ]] || [[ $mem_used_percent -ge 80 ]] || [[ $disk_used_percent -ge 80 ]]; then
        overall_status="warning"
    fi

    local data
    data=$(printf '{"load":{"1m":%s,"5m":%s,"15m":%s,"cpus":%d},"memory":{"used_percent":%d,"total_mb":%d},"disk":{"path":"/var/log","used_percent":%d},"status":"%s"}' \
        "$load_1m" "$load_5m" "$load_15m" "$cpu_count" "$mem_used_percent" "$((mem_total_kb / 1024))" "$disk_used_percent" "$overall_status")

    _checks_json_result "true" "$data" ""
    return 0
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_check_suricata_status
export -f nftban_check_service_metrics
export -f nftban_check_timer_status
export -f nftban_check_binary_integrity
export -f nftban_check_all_binaries
export -f nftban_check_config_exists
export -f nftban_check_eve_freshness
export -f nftban_check_firewall_conflict
export -f nftban_check_dns
export -f nftban_check_load_average
export -f nftban_check_memory_usage
export -f nftban_check_disk_usage
export -f nftban_check_iowait
export -f nftban_check_system_resources

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly _NFTBAN_CHECKS_LOADED=1
export _NFTBAN_CHECKS_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
