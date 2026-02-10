#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Shared Check Functions Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unified check functions for health, status, and smoke commands
#
# meta:name="nftban_checks"
# meta:type="library"
# meta:header="Shared Check Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Pure check functions returning consistent JSON, reusable across health/status/smoke"
# meta:input="Service names, file paths, timer names"
# meta:output="JSON objects with {ok, checked_at, data, error} contract"
#
# **Inventory & Requirements**
# meta:depends="bash>=4.0,jq"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,stat,file"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,PORTSCAN_EVE_FRESHNESS_THRESHOLD"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# **Contract**
# - All functions return JSON to stdout
# - JSON format: {"ok":bool,"checked_at":"ISO8601Z","data":{...},"error":""}
# - Return 0 if check executed (even if service is down/broken)
# - Return non-zero ONLY if the check itself cannot be performed
# - NEVER call exit() - caller decides what to do
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
nftban_check_suricata_status() {
    # Use FHS central config paths
    local eve_file="${1:-${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"
    local eve_threshold="${2:-${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}}"  # seconds

    local installed="false"
    local service_active="false"
    local eve_exists="false"
    local eve_fresh="false"
    local eve_age=-1
    local rules_loaded=0
    local banning_active="false"
    local status_text="not_installed"

    # Tier 1: Binary check
    if command -v suricata &>/dev/null; then
        installed="true"
        status_text="installed_stopped"

        # Tier 2: Service check
        if systemctl is-active suricata.service &>/dev/null; then
            service_active="true"
            status_text="running_no_eve"

            # Tier 3: EVE freshness check
            if [[ -f "$eve_file" ]] || [[ -L "$eve_file" ]]; then
                eve_exists="true"
                local eve_mtime now_ts
                # Use -L to follow symlinks (eve-alerts.json -> eve.json)
                eve_mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || eve_mtime=0
                now_ts=$(date +%s)
                eve_age=$(( now_ts - eve_mtime ))

                if [[ $eve_age -le $eve_threshold ]]; then
                    eve_fresh="true"
                    status_text="active"

                    # Get rules_loaded from EVE JSON stats
                    rules_loaded=$(grep -o '"rules_loaded":[0-9]*' "$eve_file" 2>/dev/null | tail -1 | cut -d: -f2 || echo "0")
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

    # Build data JSON
    local data
    data=$(printf '{"installed":%s,"service_active":%s,"eve_exists":%s,"eve_fresh":%s,"eve_age_sec":%d,"eve_threshold_sec":%d,"rules_loaded":%d,"banning_active":%s,"status":"%s"}' \
        "$installed" "$service_active" "$eve_exists" "$eve_fresh" \
        "$eve_age" "$eve_threshold" "$rules_loaded" "$banning_active" "$status_text")

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

        # Get file type
        file_type=$(file -b "$binary" 2>/dev/null || echo "unknown")
        # Escape for JSON
        file_type="${file_type//\"/\\\"}"

        if [[ "$file_type" == *"ELF"* ]]; then
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
        data=$(echo "$result" | grep -o '"data":{[^}]*}' | sed 's/"data"://')
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
# Args: $1=eve_file, $2=threshold_seconds
# Returns JSON with: exists, fresh, age_sec
nftban_check_eve_freshness() {
    # Use FHS central config paths
    local eve_file="${1:-${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json}"
    local threshold="${2:-${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}}"

    local exists="false"
    local fresh="false"
    local age_sec=-1
    local status_text="missing"

    if [[ -f "$eve_file" ]] || [[ -L "$eve_file" ]]; then
        exists="true"
        local mtime now_ts
        mtime=$(stat -L -c %Y "$eve_file" 2>/dev/null) || mtime=0
        now_ts=$(date +%s)
        age_sec=$(( now_ts - mtime ))

        if [[ $age_sec -le $threshold ]]; then
            fresh="true"
            status_text="fresh"
        else
            status_text="stale"
        fi
    fi

    local data
    data=$(printf '{"path":"%s","exists":%s,"fresh":%s,"age_sec":%d,"threshold_sec":%d,"status":"%s"}' \
        "$eve_file" "$exists" "$fresh" "$age_sec" "$threshold" "$status_text")

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
            if [[ -f /etc/csf/csf.conf ]]; then
                installed="true"
                status_text="installed"
                if grep -q "^TESTING = \"0\"" /etc/csf/csf.conf 2>/dev/null; then
                    active="true"
                    enabled="true"
                    conflict_level="critical"
                    status_text="active_production"
                elif grep -q "^TESTING = \"1\"" /etc/csf/csf.conf 2>/dev/null; then
                    conflict_level="warning"
                    status_text="testing_mode"
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
