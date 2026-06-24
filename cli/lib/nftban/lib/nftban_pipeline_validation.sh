#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_pipeline_validation" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Validates metrics pipeline health for watchdog capability detection"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_PIPELINE_VALIDATION_LOADED:-}" ]] && return 0
readonly NFTBAN_PIPELINE_VALIDATION_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load main configuration
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi

# Load metrics configuration
# shellcheck source=/dev/null
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf" 2>/dev/null || true
# shellcheck source=/dev/null
# IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
_source_local "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/metrics.conf.local"

# Pipeline defaults (fallbacks if not set in config)
: "${NFTBAN_METRICS_PROM_FILE:=/var/lib/node_exporter/textfile_collector/nftban.prom}"
: "${NFTBAN_METRICS_WATCHDOG_FILE:=/var/lib/nftban/metrics/watchdog.prom}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_VICTORIA_ADDR:=localhost:8428}"

# Agent addresses (for vmagent/prometheus-agent)
: "${NFTBAN_METRICS_VMAGENT_ADDR:=localhost:8429}"
: "${NFTBAN_METRICS_PROM_AGENT_ADDR:=localhost:9091}"

# Pipeline status codes
readonly NFTBAN_PIPELINE_FAIL=0
readonly NFTBAN_PIPELINE_DEGRADED=1
readonly NFTBAN_PIPELINE_OK=2

# Validation timeout (seconds)
: "${NFTBAN_PIPELINE_TIMEOUT:=5}"

# =============================================================================
# VALIDATION A: NFTBan Metrics Endpoint
# =============================================================================

nftban_validate_metrics_endpoint() {
    # Check if NFTBan metrics are being exported
    # Checks: .prom textfile exists and is recent (< 5 minutes old)
    #
    # Returns:
    #   0 = Metrics endpoint healthy
    #   1 = Metrics endpoint unhealthy
    #
    # Output: Writes status to stdout if verbose

    local verbose="${1:-false}"
    local result=1

    # Check 1: NFTBan .prom textfile exists and is recent
    if [[ -f "$NFTBAN_METRICS_PROM_FILE" ]]; then
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_METRICS_PROM_FILE" 2>/dev/null || echo 0) ))

        if [[ $file_age -lt 300 ]]; then
            # File exists and is < 5 minutes old
            result=0
            [[ "$verbose" == "true" ]] && echo "  [A] NFTBan metrics: OK (textfile ${file_age}s old)"
        else
            [[ "$verbose" == "true" ]] && echo "  [A] NFTBan metrics: STALE (textfile ${file_age}s old)"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  [A] NFTBan metrics: NOT FOUND ($NFTBAN_METRICS_PROM_FILE)"
    fi

    # Check 2: Watchdog .prom textfile (secondary check)
    if [[ $result -ne 0 ]] && [[ -f "$NFTBAN_METRICS_WATCHDOG_FILE" ]]; then
        local file_age
        file_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_METRICS_WATCHDOG_FILE" 2>/dev/null || echo 0) ))

        if [[ $file_age -lt 300 ]]; then
            result=0
            [[ "$verbose" == "true" ]] && echo "  [A] Watchdog metrics: OK (${file_age}s old)"
        fi
    fi

    return $result
}

# =============================================================================
# VALIDATION B: Agent Scraping
# =============================================================================

nftban_validate_agent_scrape() {
    # Check if a metrics agent is actively scraping
    # Checks: node_exporter, prometheus, or victoriametrics responding
    #
    # Returns:
    #   0 = Agent is scraping
    #   1 = No agent scraping
    #
    # Output: Writes status to stdout if verbose

    local verbose="${1:-false}"
    local result=1
    local agent_found=""

    # Check 1: Node Exporter (most common - textfile collector)
    if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
        "http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics" >/dev/null 2>&1; then
        result=0
        agent_found="node_exporter"
    fi

    # Check 2: Prometheus (local instance)
    if [[ $result -ne 0 ]]; then
        if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
            "http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/-/ready" >/dev/null 2>&1; then
            result=0
            agent_found="prometheus"
        fi
    fi

    # Check 3: VictoriaMetrics (local instance)
    if [[ $result -ne 0 ]]; then
        if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
            "http://${NFTBAN_METRICS_VICTORIA_ADDR}/health" >/dev/null 2>&1; then
            result=0
            agent_found="victoriametrics"
        fi
    fi

    # Check 4: vmagent (for remote_write scenarios)
    if [[ $result -ne 0 ]]; then
        if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
            "http://${NFTBAN_METRICS_VMAGENT_ADDR}/-/ready" >/dev/null 2>&1; then
            result=0
            agent_found="vmagent"
        fi
    fi

    if [[ "$verbose" == "true" ]]; then
        if [[ $result -eq 0 ]]; then
            echo "  [B] Agent scraping: OK ($agent_found)"
        else
            echo "  [B] Agent scraping: NOT FOUND"
        fi
    fi

    return $result
}

# =============================================================================
# VALIDATION C: Remote Write Health
# =============================================================================

nftban_validate_remote_write() {
    # Check if remote_write is functioning (agent -> remote TSDB)
    # This is optional - only checked if an agent with remote_write is configured
    #
    # Returns:
    #   0 = Remote write healthy (or not configured - pass-through)
    #   1 = Remote write unhealthy
    #
    # Output: Writes status to stdout if verbose

    local verbose="${1:-false}"
    local result=0  # Default to OK (remote_write is optional)

    # Check if remote_write is configured
    local remote_write_configured=false

    # Check vmagent config
    if [[ -f /etc/victoriametrics/vmagent.yml ]]; then
        if grep -q "remoteWrite" /etc/victoriametrics/vmagent.yml 2>/dev/null; then
            remote_write_configured=true
        fi
    fi

    # Check prometheus-agent config
    if [[ -f /etc/prometheus/prometheus.yml ]]; then
        if grep -q "remote_write" /etc/prometheus/prometheus.yml 2>/dev/null; then
            remote_write_configured=true
        fi
    fi

    if [[ "$remote_write_configured" == "true" ]]; then
        # Remote write is configured - check agent health
        local agent_healthy=false

        # Check vmagent metrics for remote_write errors
        if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
            "http://${NFTBAN_METRICS_VMAGENT_ADDR}/metrics" 2>/dev/null | \
            grep -q 'vmagent_remotewrite_conn_bytes_written_total'; then
            agent_healthy=true
        fi

        # Check prometheus-agent remote_write status
        if [[ "$agent_healthy" == "false" ]]; then
            if curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
                "http://${NFTBAN_METRICS_PROM_AGENT_ADDR}/api/v1/status/runtimeinfo" 2>/dev/null | \
                grep -q '"remoteStorage"'; then
                agent_healthy=true
            fi
        fi

        if [[ "$agent_healthy" == "true" ]]; then
            result=0
            [[ "$verbose" == "true" ]] && echo "  [C] Remote write: OK"
        else
            result=1
            [[ "$verbose" == "true" ]] && echo "  [C] Remote write: UNHEALTHY"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  [C] Remote write: NOT CONFIGURED (skipped)"
    fi

    return $result
}

# =============================================================================
# PIPELINE STATUS
# =============================================================================

nftban_pipeline_status() {
    # Get overall pipeline health status
    #
    # Returns status code:
    #   0 = FAIL (pipeline broken - no metrics collection)
    #   1 = DEGRADED (local metrics only, no remote)
    #   2 = OK (full pipeline healthy)
    #
    # Output: Writes status to stdout if verbose

    local verbose="${1:-false}"
    local status=$NFTBAN_PIPELINE_FAIL

    [[ "$verbose" == "true" ]] && echo "Pipeline Validation:"

    # Run validations
    local val_a=1 val_b=1 val_c=0

    nftban_validate_metrics_endpoint "$verbose" && val_a=0
    nftban_validate_agent_scrape "$verbose" && val_b=0
    nftban_validate_remote_write "$verbose" && val_c=0

    # Determine overall status
    if [[ $val_a -eq 0 ]] && [[ $val_b -eq 0 ]] && [[ $val_c -eq 0 ]]; then
        status=$NFTBAN_PIPELINE_OK
    elif [[ $val_a -eq 0 ]] && [[ $val_b -eq 0 ]]; then
        status=$NFTBAN_PIPELINE_DEGRADED
    elif [[ $val_a -eq 0 ]]; then
        # Metrics exist but no agent - still degraded (can read locally)
        status=$NFTBAN_PIPELINE_DEGRADED
    else
        status=$NFTBAN_PIPELINE_FAIL
    fi

    if [[ "$verbose" == "true" ]]; then
        echo ""
        # shellcheck disable=SC2254  # Intentional: matching numeric constants
        case $status in
            "$NFTBAN_PIPELINE_OK")
                echo "Pipeline Status: OK (full functionality)"
                ;;
            "$NFTBAN_PIPELINE_DEGRADED")
                echo "Pipeline Status: DEGRADED (local metrics only)"
                ;;
            "$NFTBAN_PIPELINE_FAIL")
                echo "Pipeline Status: FAIL (no metrics collection)"
                ;;
        esac
    fi

    return $status
}

# =============================================================================
# WATCHDOG CAPABILITY DETECTION
# =============================================================================

nftban_detect_watchdog_capability() {
    # Detect watchdog capability based on pipeline status
    #
    # Returns:
    #   "local" = LOCAL capability only (always available)
    #   "perf"  = PERFORMANCE capability (requires pipeline)
    #
    # Output: Writes capability to stdout

    local verbose="${1:-false}"

    # Get pipeline status (suppress output for detection)
    local pipeline_status
    nftban_pipeline_status false
    pipeline_status=$?

    local capability="local"

    if [[ $pipeline_status -ge $NFTBAN_PIPELINE_DEGRADED ]]; then
        capability="perf"
    fi

    if [[ "$verbose" == "true" ]]; then
        echo "Watchdog Capability: $capability"
        echo "  Pipeline Status: $pipeline_status"
        if [[ "$capability" == "local" ]]; then
            echo "  Features: Load, Memory, I/O Wait, Disk monitoring"
            echo "  Missing: Historical trends, remote alerting"
        else
            echo "  Features: Full monitoring + trends + remote metrics"
        fi
    fi

    echo "$capability"
}

# =============================================================================
# CAPABILITY METRIC VALUE
# =============================================================================

nftban_get_capability_metric_value() {
    # Get numeric value for nftban_watchdog_capability metric
    #
    # Returns:
    #   0 = local (no metrics pipeline)
    #   1 = perf_degraded (local metrics only)
    #   2 = perf_full (full pipeline)
    #
    # Output: Writes value to stdout

    local pipeline_status
    nftban_pipeline_status false
    pipeline_status=$?

    # shellcheck disable=SC2254  # Intentional: matching numeric constants
    case $pipeline_status in
        "$NFTBAN_PIPELINE_FAIL")
            echo "0"  # local only
            ;;
        "$NFTBAN_PIPELINE_DEGRADED")
            echo "1"  # perf_degraded
            ;;
        "$NFTBAN_PIPELINE_OK")
            echo "2"  # perf_full
            ;;
        *)
            echo "0"  # fallback to local
            ;;
    esac
}

# =============================================================================
# HELPER: Check if performance deps are available for installation
# =============================================================================

nftban_check_perf_deps_available() {
    # Check if performance dependencies can be installed
    # Used to determine if we should prompt user
    #
    # Returns:
    #   0 = Dependencies can be installed
    #   1 = Dependencies not available
    #
    # Sets globals:
    #   NFTBAN_PERF_DEPS_MISSING - array of missing packages

    NFTBAN_PERF_DEPS_MISSING=()

    # Check for metrics exporter timer
    if ! systemctl list-unit-files 2>/dev/null | grep -q "nftban-unified-exporter.timer"; then
        NFTBAN_PERF_DEPS_MISSING+=("nftban-unified-exporter.timer")
    fi

    # Check for node_exporter
    local node_exporter_found=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
            node_exporter_found=true
            break
        fi
    done
    if [[ "$node_exporter_found" == "false" ]] && ! command -v node_exporter &>/dev/null; then
        NFTBAN_PERF_DEPS_MISSING+=("node_exporter")
    fi

    # Check for metrics backend (prometheus or victoriametrics)
    local backend_found=false
    if command -v prometheus &>/dev/null || \
       systemctl list-unit-files 2>/dev/null | grep -q "prometheus.service"; then
        backend_found=true
    fi
    if command -v victoria-metrics-prod &>/dev/null || \
       systemctl list-unit-files 2>/dev/null | grep -q "victoriametrics.service"; then
        backend_found=true
    fi
    if [[ "$backend_found" == "false" ]]; then
        NFTBAN_PERF_DEPS_MISSING+=("metrics_backend")
    fi

    if [[ ${#NFTBAN_PERF_DEPS_MISSING[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# VMAGENT VALIDATION
# =============================================================================

nftban_validate_vmagent_targets() {
    # Check if vmagent is scraping nftban targets
    #
    # Returns:
    #   0 = vmagent targets show nftban UP
    #   1 = vmagent not scraping or nftban DOWN
    #
    # Output: Writes status to stdout if verbose

    local verbose="${1:-false}"
    local result=1

    # Check vmagent targets endpoint
    local targets_response
    targets_response=$(curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
        "http://${NFTBAN_METRICS_VMAGENT_ADDR}/targets" 2>/dev/null || echo "")

    if [[ -n "$targets_response" ]]; then
        # Check if nftban target is UP
        if echo "$targets_response" | grep -q '"job":"nftban".*"health":"up"'; then
            result=0
            [[ "$verbose" == "true" ]] && echo "  [B2] vmagent targets: nftban UP"
        elif echo "$targets_response" | grep -q '"job":"nftban"'; then
            [[ "$verbose" == "true" ]] && echo "  [B2] vmagent targets: nftban DOWN"
        else
            [[ "$verbose" == "true" ]] && echo "  [B2] vmagent targets: nftban not configured"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  [B2] vmagent targets: endpoint not responding"
    fi

    return $result
}

nftban_validate_vmagent_remote_write() {
    # Check vmagent remote_write health using agent metrics
    #
    # Classifies as:
    #   OK = bytes written, no persistent errors
    #   DEGRADED = bytes written but some retries/errors
    #   FAIL = no bytes written or connection refused
    #
    # Returns:
    #   0 = OK
    #   1 = DEGRADED
    #   2 = FAIL
    #
    # Output: Sets NFTBAN_REMOTE_WRITE_STATUS global

    local verbose="${1:-false}"
    NFTBAN_REMOTE_WRITE_STATUS="FAIL"
    NFTBAN_REMOTE_WRITE_REASON=""

    # Get vmagent metrics
    local metrics_response
    metrics_response=$(curl -sf --connect-timeout "$NFTBAN_PIPELINE_TIMEOUT" \
        "http://${NFTBAN_METRICS_VMAGENT_ADDR}/metrics" 2>/dev/null || echo "")

    if [[ -z "$metrics_response" ]]; then
        NFTBAN_REMOTE_WRITE_REASON="vmagent not responding"
        [[ "$verbose" == "true" ]] && echo "  [C] Remote write: FAIL (vmagent not responding)"
        return 2
    fi

    # Check for bytes written (indicates successful writes)
    local bytes_written
    bytes_written=$(echo "$metrics_response" | grep 'vmagent_remotewrite_bytes_sent_total' | \
        awk '{sum += $2} END {print sum+0}')

    # Check for persistent errors
    local persistent_errors
    persistent_errors=$(echo "$metrics_response" | grep 'vmagent_remotewrite_requests_total.*status="4' | \
        awk '{sum += $2} END {print sum+0}')

    # Check for retries
    local retries
    retries=$(echo "$metrics_response" | grep 'vmagent_remotewrite_retries_count_total' | \
        awk '{sum += $2} END {print sum+0}')

    # Classify status
    if [[ "$bytes_written" -gt 0 ]] && [[ "$persistent_errors" -eq 0 ]]; then
        NFTBAN_REMOTE_WRITE_STATUS="OK"
        [[ "$verbose" == "true" ]] && echo "  [C] Remote write: OK (${bytes_written} bytes sent)"
        return 0
    elif [[ "$bytes_written" -gt 0 ]]; then
        NFTBAN_REMOTE_WRITE_STATUS="DEGRADED"
        NFTBAN_REMOTE_WRITE_REASON="${retries} retries, ${persistent_errors} 4xx errors"
        [[ "$verbose" == "true" ]] && echo "  [C] Remote write: DEGRADED (${NFTBAN_REMOTE_WRITE_REASON})"
        return 1
    else
        NFTBAN_REMOTE_WRITE_STATUS="FAIL"
        NFTBAN_REMOTE_WRITE_REASON="no bytes sent to remote"
        [[ "$verbose" == "true" ]] && echo "  [C] Remote write: FAIL (no bytes sent)"
        return 2
    fi
}

# =============================================================================
# PRINT PIPELINE REPORT (User-Friendly Output)
# =============================================================================

nftban_print_pipeline_report() {
    # Print user-friendly pipeline status with remediation steps
    #
    # Usage: nftban_print_pipeline_report [--json]
    #
    # Runs all validations and prints detailed report with fixes
    # Includes: metrics endpoint, agent, remote_write, auth, Pro entitlement, inventory

    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    # Load Pro library if available
    local pro_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_pro.sh"
    if [[ -f "$pro_lib" ]] && ! declare -f nftban_pro_is_enabled &>/dev/null; then
        # shellcheck source=/dev/null
        source "$pro_lib" || return 1
    fi

    # Run all validations
    local val_a=1 val_b=1 val_c=0 val_d=0 val_e=0 val_f=0
    local val_a_msg="" val_b_msg="" val_c_msg="" val_d_msg="" val_e_msg="" val_f_msg=""

    # Validation A: NFTBan metrics endpoint
    if nftban_validate_metrics_endpoint false; then
        val_a=0
        val_a_msg="OK"
    else
        val_a_msg="FAIL"
    fi

    # Validation B: Agent scraping
    if nftban_validate_agent_scrape false; then
        val_b=0
        val_b_msg="OK"
    else
        val_b_msg="FAIL"
    fi

    # Validation C: Remote write (only if vmagent configured)
    local is_pro_mode=false
    if [[ -f /etc/victoriametrics/vmagent.yml ]]; then
        if grep -q "pro.nftban.com" /etc/victoriametrics/vmagent.yml 2>/dev/null; then
            is_pro_mode=true
        fi

        if systemctl is-active vmagent &>/dev/null 2>&1; then
            nftban_validate_vmagent_remote_write false
            local rw_status=$?
            case $rw_status in
                0) val_c=0; val_c_msg="OK" ;;
                1) val_c=1; val_c_msg="DEGRADED" ;;
                *) val_c=2; val_c_msg="FAIL" ;;
            esac
        else
            val_c=2
            val_c_msg="AGENT_STOPPED"
        fi
    else
        val_c=0
        val_c_msg="NOT_CONFIGURED"
    fi

    # Validation D: Auth status (check for 401/403 in vmagent metrics)
    val_d=0
    val_d_msg="NOT_APPLICABLE"
    if [[ "$val_c_msg" != "NOT_CONFIGURED" ]] && [[ "$val_c_msg" != "AGENT_STOPPED" ]]; then
        local auth_errors
        auth_errors=$(curl -sf --connect-timeout 5 \
            "http://${NFTBAN_METRICS_VMAGENT_ADDR:-localhost:8429}/metrics" 2>/dev/null | \
            grep 'vmagent_remotewrite_requests_total.*status="4' | \
            awk '{sum += $2} END {print sum+0}')

        if [[ "${auth_errors:-0}" -gt 0 ]]; then
            val_d=1
            val_d_msg="AUTH_REJECTED (${auth_errors} errors)"
        else
            val_d=0
            val_d_msg="OK"
        fi
    fi

    # Validation E: Pro entitlement (only if Pro mode)
    val_e=0
    val_e_msg="NOT_APPLICABLE"
    if [[ "$is_pro_mode" == "true" ]]; then
        local pro_token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"
        if [[ ! -f "$pro_token_file" ]]; then
            val_e=2
            val_e_msg="TOKEN_MISSING"
        elif declare -f nftban_pro_is_enabled &>/dev/null && nftban_pro_is_enabled; then
            val_e=0
            val_e_msg="ACTIVE"
        else
            val_e=1
            val_e_msg="INACTIVE"
        fi
    fi

    # Validation F: Inventory submit (only if Pro mode)
    val_f=0
    val_f_msg="NOT_APPLICABLE"
    if [[ "$is_pro_mode" == "true" ]]; then
        local last_submit_file="${NFTBAN_PRO_DATA_DIR:-/var/lib/nftban/pro}/last_submit.json"
        if [[ -f "$last_submit_file" ]]; then
            local submit_success
            submit_success=$(jq -r '.success // false' "$last_submit_file" 2>/dev/null || echo "false")
            if [[ "$submit_success" == "true" ]]; then
                val_f=0
                val_f_msg="OK"
            else
                val_f=1
                val_f_msg="LAST_FAILED"
            fi
        else
            if [[ "$val_e" -eq 0 ]]; then
                val_f=1
                val_f_msg="PENDING"
            else
                val_f=0
                val_f_msg="SKIPPED (entitlement inactive)"
            fi
        fi
    fi

    # Determine overall status
    local overall_status="FAIL"
    local overall_code=0
    if [[ $val_a -eq 0 ]] && [[ $val_b -eq 0 ]] && [[ $val_c -le 1 ]]; then
        if [[ $val_c -eq 0 ]] || [[ "$val_c_msg" == "NOT_CONFIGURED" ]]; then
            overall_status="OK"
            overall_code=2
        else
            overall_status="DEGRADED"
            overall_code=1
        fi
    elif [[ $val_a -eq 0 ]]; then
        overall_status="DEGRADED"
        overall_code=1
    fi

    # Check for auth or entitlement failures that should degrade status
    if [[ $val_d -gt 0 ]] || [[ $val_e -gt 0 ]]; then
        if [[ "$overall_status" == "OK" ]]; then
            overall_status="DEGRADED"
            overall_code=1
        fi
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat << EOF
{
  "status": "$overall_status",
  "status_code": $overall_code,
  "pro_mode": $is_pro_mode,
  "validations": {
    "metrics_endpoint": {"status": "$val_a_msg", "passed": $([[ $val_a -eq 0 ]] && echo "true" || echo "false")},
    "agent_scraping": {"status": "$val_b_msg", "passed": $([[ $val_b -eq 0 ]] && echo "true" || echo "false")},
    "remote_write": {"status": "$val_c_msg", "passed": $([[ $val_c -le 1 ]] && echo "true" || echo "false")},
    "auth": {"status": "$val_d_msg", "passed": $([[ $val_d -eq 0 ]] && echo "true" || echo "false")},
    "pro_entitlement": {"status": "$val_e_msg", "passed": $([[ $val_e -eq 0 ]] && echo "true" || echo "false")},
    "inventory_submit": {"status": "$val_f_msg", "passed": $([[ $val_f -eq 0 ]] && echo "true" || echo "false")}
  },
  "capability": "$(nftban_detect_watchdog_capability false)",
  "capability_value": $(nftban_get_capability_metric_value)
}
EOF
        return $overall_code
    fi

    # Text output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics Pipeline Report"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Status summary
    local status_icon="❌"
    [[ "$overall_status" == "OK" ]] && status_icon="✅"
    [[ "$overall_status" == "DEGRADED" ]] && status_icon="⚠️"

    echo "  Overall Status: $status_icon $overall_status"
    echo ""
    echo "  Validations:"

    # Validation A
    local a_icon="❌"
    [[ $val_a -eq 0 ]] && a_icon="✅"
    echo "    [A] NFTBan Metrics Endpoint: $a_icon $val_a_msg"

    # Validation B
    local b_icon="❌"
    [[ $val_b -eq 0 ]] && b_icon="✅"
    echo "    [B] Agent Scraping:          $b_icon $val_b_msg"

    # Validation C
    local c_icon="❌"
    [[ $val_c -eq 0 ]] && c_icon="✅"
    [[ $val_c -eq 1 ]] && c_icon="⚠️"
    [[ "$val_c_msg" == "NOT_CONFIGURED" ]] && c_icon="⏭️"
    echo "    [C] Remote Write:            $c_icon $val_c_msg"

    # Validation D (Auth) - only show if relevant
    if [[ "$val_d_msg" != "NOT_APPLICABLE" ]]; then
        local d_icon="❌"
        [[ $val_d -eq 0 ]] && d_icon="✅"
        echo "    [D] Auth Status:             $d_icon $val_d_msg"
    fi

    # Pro-specific validations (only show in Pro mode)
    if [[ "$is_pro_mode" == "true" ]]; then
        echo ""
        echo "  Pro Status:"

        # Validation E (Entitlement)
        local e_icon="❌"
        [[ $val_e -eq 0 ]] && e_icon="✅"
        [[ $val_e -eq 1 ]] && e_icon="⚠️"
        echo "    [E] Pro Entitlement:         $e_icon $val_e_msg"

        # Validation F (Inventory)
        local f_icon="❌"
        [[ $val_f -eq 0 ]] && f_icon="✅"
        [[ $val_f -eq 1 ]] && f_icon="⚠️"
        [[ "$val_f_msg" == "SKIPPED"* ]] && f_icon="⏭️"
        echo "    [F] Inventory Submit:        $f_icon $val_f_msg"
    fi

    echo ""

    # Remediation steps if issues found
    local has_issues=false

    if [[ $val_a -ne 0 ]]; then
        has_issues=true
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo "  [A] FIX: NFTBan Metrics Endpoint"
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo ""
        echo "    The metrics .prom file is missing or stale."
        echo ""
        echo "    1. Enable unified exporter timer:"
        echo "       sudo systemctl enable --now nftban-unified-exporter.timer"
        echo ""
        echo "    2. Trigger immediate collection:"
        echo "       sudo systemctl start nftban-unified-exporter.service"
        echo ""
        echo "    3. Verify file exists:"
        echo "       ls -la /var/lib/node_exporter/textfile_collector/nftban.prom"
        echo ""
    fi

    if [[ $val_b -ne 0 ]]; then
        has_issues=true
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo "  [B] FIX: Agent Scraping"
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo ""
        echo "    No metrics agent is running to scrape nftban metrics."
        echo ""
        echo "    Option 1: Enable local metrics stack"
        echo "       nftban metrics enable --backend victoriametrics"
        echo ""
        echo "    Option 2: Install vmagent for remote submission"
        echo "       nftban metrics enable --remote"
        echo ""
    fi

    if [[ $val_c -eq 2 ]]; then
        has_issues=true
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo "  [C] FIX: Remote Write"
        echo "  ─────────────────────────────────────────────────────────────────────────"
        echo ""
        echo "    Remote write is configured but failing."
        echo "    Reason: ${NFTBAN_REMOTE_WRITE_REASON:-unknown}"
        echo ""
        echo "    1. Check vmagent status:"
        echo "       systemctl status vmagent"
        echo ""
        echo "    2. Check vmagent logs:"
        echo "       journalctl -u vmagent -n 50"
        echo ""
        echo "    3. Verify remote endpoint is reachable:"
        echo "       curl -I <remote_write_url>"
        echo ""
        echo "    4. Verify token file exists:"
        echo "       ls -la /etc/nftban/pro.token"
        echo ""
    fi

    if [[ "$has_issues" == "false" ]]; then
        echo "  All validations passed. Metrics pipeline is healthy."
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return $overall_code
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_validate_metrics_endpoint
export -f nftban_validate_agent_scrape
export -f nftban_validate_remote_write
export -f nftban_validate_vmagent_targets
export -f nftban_validate_vmagent_remote_write
export -f nftban_pipeline_status
export -f nftban_detect_watchdog_capability
export -f nftban_get_capability_metric_value
export -f nftban_check_perf_deps_available
export -f nftban_print_pipeline_report

# Export constants
export NFTBAN_PIPELINE_FAIL
export NFTBAN_PIPELINE_DEGRADED
export NFTBAN_PIPELINE_OK

# Export global status variables (set by validation functions)
export NFTBAN_REMOTE_WRITE_STATUS
export NFTBAN_REMOTE_WRITE_REASON
