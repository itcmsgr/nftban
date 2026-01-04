#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Pipeline Validation Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Shared validation functions for metrics pipeline health
#
# meta:name=nftban_pipeline_validation
# meta:type=lib
# meta:header=Pipeline Validation Library
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Validates metrics pipeline health for watchdog capability detection
# meta:input=N/A (library only)
# meta:output=Pipeline status codes and validation results
#
# **Pipeline Health Model**
#   Validation A: NFTBan metrics endpoint (local .prom file or HTTP)
#   Validation B: Agent scraping (vmagent or prometheus-agent)
#   Validation C: Remote write health (agent -> remote TSDB)
#
# **Pipeline Status Codes**
#   0 = FAIL (pipeline broken)
#   1 = DEGRADED (partial functionality)
#   2 = OK (full functionality)
#
# **Watchdog Capability**
#   LOCAL: Always available, no metrics pipeline needed
#   PERF: Requires healthy pipeline (status >= 1)
#
# meta:created_date=2026-01-04
# meta:updated_date=2026-01-04
# =============================================================================

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
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
fi

# Pipeline defaults
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
        case $status in
            $NFTBAN_PIPELINE_OK)
                echo "Pipeline Status: OK (full functionality)"
                ;;
            $NFTBAN_PIPELINE_DEGRADED)
                echo "Pipeline Status: DEGRADED (local metrics only)"
                ;;
            $NFTBAN_PIPELINE_FAIL)
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

    case $pipeline_status in
        $NFTBAN_PIPELINE_FAIL)
            echo "0"  # local only
            ;;
        $NFTBAN_PIPELINE_DEGRADED)
            echo "1"  # perf_degraded
            ;;
        $NFTBAN_PIPELINE_OK)
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
    if ! systemctl list-unit-files 2>/dev/null | grep -q "nftban-metrics-exporter.timer"; then
        NFTBAN_PERF_DEPS_MISSING+=("nftban-metrics-exporter.timer")
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
# EXPORTS
# =============================================================================

export -f nftban_validate_metrics_endpoint
export -f nftban_validate_agent_scrape
export -f nftban_validate_remote_write
export -f nftban_pipeline_status
export -f nftban_detect_watchdog_capability
export -f nftban_get_capability_metric_value
export -f nftban_check_perf_deps_available

# Export constants
export NFTBAN_PIPELINE_FAIL
export NFTBAN_PIPELINE_DEGRADED
export NFTBAN_PIPELINE_OK
