#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034  # SC1090: Dynamic paths; SC2034: Global arrays used by render module
# =============================================================================
# NFTBan v1.0 - Health Check Integrations Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Integration-related health check functions (metrics, zabbix, connectors, pro, gui)
#
# meta:name="nftban_health_checks_integrations"
# meta:type="lib"
# meta:header="Health Check Integrations Functions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Integration health check functions for system verification"
# meta:depends="nftban_health.sh,nftban_health_checks_core.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_INTEGRATIONS_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_INTEGRATIONS_LOADED=1

# =============================================================================
# SHARED LIBRARY LOADING
# =============================================================================

# shellcheck source=/dev/null
_NFTBAN_LIB_PATH="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib"

# Load timestamp utilities (for nftban_timestamp_unix)
if [[ -f "${_NFTBAN_LIB_PATH}/nftban_timestamp.sh" ]]; then
    source "${_NFTBAN_LIB_PATH}/nftban_timestamp.sh" || return 1
fi

# Load file utilities (for nftban_file_age, nftban_file_mtime)
if [[ -f "${_NFTBAN_LIB_PATH}/nftban_file_utils.sh" ]]; then
    source "${_NFTBAN_LIB_PATH}/nftban_file_utils.sh" || return 1
fi

# Load service control (for nftban_service_is_active, nftban_service_exists, etc.)
if [[ -f "${_NFTBAN_LIB_PATH}/nftban_service_control.sh" ]]; then
    source "${_NFTBAN_LIB_PATH}/nftban_service_control.sh" || return 1
fi

# =============================================================================
# FALLBACK FUNCTIONS (if libraries not available)
# =============================================================================

# Fallback for nftban_file_age
if ! declare -F nftban_file_age >/dev/null 2>&1; then
    nftban_file_age() {
        local filepath="$1"
        [[ ! -e "$filepath" ]] && { echo "0"; return 1; }
        local mtime current_time
        mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
        current_time=$(date +%s)
        echo $(( current_time - mtime ))
    }
fi

# Fallback for nftban_service_is_active
if ! declare -F nftban_service_is_active >/dev/null 2>&1; then
    nftban_service_is_active() {
        systemctl is-active --quiet "$1" 2>/dev/null
    }
fi

# Fallback for nftban_service_is_enabled
if ! declare -F nftban_service_is_enabled >/dev/null 2>&1; then
    nftban_service_is_enabled() {
        systemctl is-enabled --quiet "$1" 2>/dev/null
    }
fi

# Fallback for nftban_service_exists
if ! declare -F nftban_service_exists >/dev/null 2>&1; then
    nftban_service_exists() {
        local service="$1"
        [[ "$service" != *.service ]] && [[ "$service" != *.timer ]] && service="${service}.service"
        systemctl list-unit-files "$service" 2>/dev/null | grep -q "^${service}" && return 0
        [[ -f "/etc/systemd/system/${service}" ]] && return 0
        [[ -f "/usr/lib/systemd/system/${service}" ]] && return 0
        return 1
    }
fi

# Fallback for nftban_timer_is_active
if ! declare -F nftban_timer_is_active >/dev/null 2>&1; then
    nftban_timer_is_active() {
        local timer="$1"
        [[ "$timer" != *.timer ]] && timer="${timer}.timer"
        systemctl is-active --quiet "$timer" 2>/dev/null
    }
fi

# =============================================================================
# METRICS INTEGRATION CHECK (v0.6.0)
# =============================================================================

nftban_health_check_metrics() {
    # Check Prometheus/Grafana metrics integration (NFTBan v0.6.0)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Uses central config: NFTBAN_METRICS_ENABLED, NFTBAN_METRICS_BACKEND

    local status=$HEALTH_OK
    local metrics_issues=()

    # Check if metrics exporter script exists (determine if metrics are installable)
    local exporter_installed=false
    if [[ -f "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        exporter_installed=true
    fi

    # Check central config - if metrics disabled, report appropriately
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]]; then
        if [[ "$exporter_installed" == "true" ]]; then
            # Installed but disabled by user choice
            NFTBAN_HEALTH_ISSUES["metrics"]="Disabled (set NFTBAN_METRICS_ENABLED=true to enable)"
            NFTBAN_HEALTH_RESULTS["metrics"]=$HEALTH_DISABLED
            return $HEALTH_DISABLED
        else
            # Not installed (optional feature)
            NFTBAN_HEALTH_ISSUES["metrics"]="Not installed (optional feature)"
            NFTBAN_HEALTH_RESULTS["metrics"]=$HEALTH_NOT_INSTALLED
            return $HEALTH_NOT_INSTALLED
        fi
    fi

    # Check if metrics exporter script exists
    if [[ ! -f "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        metrics_issues+=("Metrics exporter not installed (optional)")
        NFTBAN_HEALTH_ISSUES["metrics"]="Not installed (optional feature)"
        return $HEALTH_NOT_INSTALLED
    fi

    # Check if exporter script is executable
    if [[ ! -x "${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh" ]]; then
        metrics_issues+=("Metrics exporter not executable")
        metrics_issues+=("FIX: sudo chmod +x ${NFTBAN_LIB_DIR}/exporters/nftban_prometheus_exporter.sh")
        status=$HEALTH_ERROR
    fi

    # Check pipeline validation library (watchdog capability detection)
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
        metrics_issues+=("✓ Pipeline validation library: Installed")
        # Test if it can be sourced
        if bash -n "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" 2>/dev/null; then
            metrics_issues+=("✓ Pipeline validation library: Syntax OK")
        else
            metrics_issues+=("Pipeline validation library has syntax errors")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        metrics_issues+=("ℹ️ Pipeline validation library not installed (optional for watchdog)")
    fi

    # PRIMARY CHECK: Unified exporter timer (nc-based, exports to ALL configured targets)
    # The unified exporter collects metrics ONCE and sends to: Zabbix, Prometheus, Connectors
    local unified_timer_ok=false
    if nftban_timer_is_active "nftban-unified-exporter.timer"; then
        metrics_issues+=("✓ Unified exporter timer: Active")
        unified_timer_ok=true
    elif nftban_service_exists "nftban-unified-exporter.timer"; then
        metrics_issues+=("⚠ Unified exporter timer exists but not running")
        metrics_issues+=("FIX: sudo systemctl enable --now nftban-unified-exporter.timer")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        metrics_issues+=("Unified exporter timer not installed")
        metrics_issues+=("FIX: sudo ./install.sh systemd")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    fi

    # Load metrics config to check export targets
    local metrics_conf="${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf"
    local metrics_local="${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf.local"
    [[ -f "$metrics_conf" ]] && source "$metrics_conf" 2>/dev/null || true
    [[ -f "$metrics_local" ]] && source "$metrics_local" 2>/dev/null || true

    # PROMETHEUS EXPORT CHECK (OPTIONAL - only if enabled)
    # Note: Prometheus export is OPTIONAL. NFTBan's default is nc-based unified export.
    local prometheus_export="${NFTBAN_EXPORT_PROMETHEUS:-auto}"

    # Auto-detect: enable only if node_exporter textfile dir exists
    if [[ "$prometheus_export" == "auto" ]]; then
        if [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
            prometheus_export="true"
        else
            prometheus_export="false"
        fi
    fi

    if [[ "$prometheus_export" == "true" ]]; then
        local metrics_file="/var/lib/node_exporter/textfile_collector/nftban.prom"
        if [[ -f "$metrics_file" ]]; then
            local file_age
            file_age=$(nftban_file_age "$metrics_file")

            if [[ $file_age -lt 120 ]]; then
                metrics_issues+=("✓ Prometheus export: Working (file ${file_age}s old)")
            elif [[ $file_age -lt 300 ]]; then
                metrics_issues+=("⚠ Prometheus export: File ${file_age}s old (may be stale)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            else
                metrics_issues+=("⚠ Prometheus export: File stale (${file_age}s old)")
                # Only ERROR if timer is also not running - may just be export lag
                if [[ "$unified_timer_ok" != "true" ]]; then
                    [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
                else
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            if [[ "$unified_timer_ok" == "true" ]]; then
                metrics_issues+=("⚠ Prometheus export: No file yet (may be first run)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            else
                metrics_issues+=("Prometheus export: Not working (no file, timer not running)")
                [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
            fi
        fi
    else
        # Prometheus export explicitly disabled - this is OK, not an error
        metrics_issues+=("ℹ️ Prometheus export: Disabled (NFTBAN_EXPORT_PROMETHEUS=false)")
        # If timer is running, unified exporter still works for other targets (Zabbix, connectors)
        if [[ "$unified_timer_ok" == "true" ]]; then
            metrics_issues+=("  → Unified exporter still exports to other configured targets")
        fi
    fi

    # Check Node Exporter (OPTIONAL - only needed for Prometheus scraping)
    local node_exporter_running=false
    if command -v node_exporter >/dev/null 2>&1 || command -v prometheus-node-exporter >/dev/null 2>&1; then
        if nftban_service_is_active "node_exporter" || \
           nftban_service_is_active "prometheus-node-exporter" || \
           nftban_service_is_active "node-exporter"; then
            metrics_issues+=("✓ Node Exporter: Running")
            # shellcheck disable=SC2034  # Reserved for metrics validation
            node_exporter_running=true
        else
            metrics_issues+=("ℹ️ Node Exporter installed but not running (optional - for Prometheus)")
        fi
    else
        metrics_issues+=("ℹ️ Node Exporter not installed (optional - only needed for Prometheus scraping)")
    fi

    # Check Prometheus or VictoriaMetrics (optional alternatives)
    local configured_backend="${NFTBAN_METRICS_BACKEND:-prometheus}"

    if command -v prometheus >/dev/null 2>&1 || nftban_service_exists "prometheus.service"; then
        if nftban_service_is_active "prometheus"; then
            metrics_issues+=("✓ Prometheus: Running")

            if command -v curl >/dev/null 2>&1; then
                if curl -s --connect-timeout "${NFTBAN_TIMEOUT_FAST}" "http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/-/healthy" >/dev/null 2>&1; then
                    metrics_issues+=("✓ Prometheus: Healthy")
                else
                    metrics_issues+=("Prometheus not responding on ${NFTBAN_METRICS_PROMETHEUS_ADDR}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            if [[ "$configured_backend" == "prometheus" ]]; then
                metrics_issues+=("Prometheus installed but not running")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    if command -v victoria-metrics >/dev/null 2>&1 || nftban_service_exists "victoria-metrics.service"; then
        if nftban_service_is_active "victoria-metrics"; then
            metrics_issues+=("✓ VictoriaMetrics: Running")

            if command -v curl >/dev/null 2>&1; then
                if curl -s --connect-timeout "${NFTBAN_TIMEOUT_FAST}" "http://${NFTBAN_METRICS_VICTORIA_ADDR}/metrics" >/dev/null 2>&1; then
                    metrics_issues+=("✓ VictoriaMetrics: Healthy")
                else
                    metrics_issues+=("VictoriaMetrics not responding on ${NFTBAN_METRICS_VICTORIA_ADDR}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            if [[ "$configured_backend" == "victoriametrics" ]]; then
                metrics_issues+=("VictoriaMetrics installed but not running")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check Grafana (optional)
    if command -v grafana-server >/dev/null 2>&1 || nftban_service_exists "grafana-server"; then
        if nftban_service_is_active "grafana-server"; then
            metrics_issues+=("✓ Grafana: Running")
        else
            metrics_issues+=("Grafana installed but not running")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check Bandwidth Exporter (v0.6 GUI redesign)
    # NOTE: Bandwidth exporter runs via unified-exporter, no separate timer exists
    if [[ -f "${NFTBAN_LIB_DIR}/exporters/nftban_bandwidth_exporter.sh" ]]; then
        # Check if unified exporter timer is running (it handles bandwidth metrics)
        if nftban_service_exists "nftban-unified-exporter.timer"; then
            if nftban_timer_is_active "nftban-unified-exporter.timer"; then
                metrics_issues+=("✓ Bandwidth exporter: via unified-exporter")
            else
                metrics_issues+=("Unified exporter timer not running (affects bandwidth)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            metrics_issues+=("Unified exporter timer not installed")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        local bandwidth_metrics_file="/var/lib/node_exporter/textfile_collector/nftban_bandwidth.prom"
        if [[ -f "$bandwidth_metrics_file" ]]; then
            local file_age
            file_age=$(nftban_file_age "$bandwidth_metrics_file")

            if [[ $file_age -lt 30 ]]; then
                metrics_issues+=("✓ Bandwidth metrics: Fresh (${file_age}s old)")
            elif [[ $file_age -lt 60 ]]; then
                metrics_issues+=("Bandwidth metrics ${file_age}s old (may be stale)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            else
                metrics_issues+=("⚠ Bandwidth metrics stale (${file_age}s old)")
                [[ $status -eq $HEALTH_OK ]] && status=$HEALTH_WARNING
            fi
        else
            metrics_issues+=("ℹ️ Bandwidth metrics file not found (optional - exporter may not have run yet)")
        fi
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["metrics"]=$status
    if [[ ${#metrics_issues[@]} -gt 0 ]]; then
        local formatted_issues=""
        for issue in "${metrics_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["metrics"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# ZABBIX EXPORTER CHECK (v1.3.0)
# =============================================================================

nftban_health_check_zabbix() {
    # Check Zabbix trapper export health
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL, 4=NOT_INSTALLED, 5=DISABLED

    local status=$HEALTH_OK
    local zabbix_issues=()

    # Load Zabbix config
    local zabbix_conf="${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf"
    local zabbix_local="${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf.local"
    [[ -f "$zabbix_conf" ]] && source "$zabbix_conf" 2>/dev/null || true
    [[ -f "$zabbix_local" ]] && source "$zabbix_local" 2>/dev/null || true

    # Check if Zabbix export is enabled
    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" != "true" ]]; then
        if [[ -f "$zabbix_conf" ]]; then
            NFTBAN_HEALTH_ISSUES["zabbix"]="Disabled (set NFTBAN_ZABBIX_ENABLED=true in zabbix.conf.local)"
            NFTBAN_HEALTH_RESULTS["zabbix"]=$HEALTH_DISABLED
            return $HEALTH_DISABLED
        else
            NFTBAN_HEALTH_ISSUES["zabbix"]="Not installed (optional feature)"
            NFTBAN_HEALTH_RESULTS["zabbix"]=$HEALTH_NOT_INSTALLED
            return $HEALTH_NOT_INSTALLED
        fi
    fi

    zabbix_issues+=("✓ Zabbix export: Enabled")

    # Check if Zabbix server is configured
    if [[ -z "${NFTBAN_ZABBIX_SERVER:-}" ]]; then
        zabbix_issues+=("⚠ Zabbix server not configured")
        zabbix_issues+=("FIX: Set NFTBAN_ZABBIX_SERVER in zabbix.conf.local")
        status=$HEALTH_ERROR
    else
        zabbix_issues+=("✓ Zabbix server: ${NFTBAN_ZABBIX_SERVER}:${NFTBAN_ZABBIX_PORT:-10051}")

        # Check connectivity to Zabbix server (quick TCP check)
        if command -v nc >/dev/null 2>&1 || command -v ncat >/dev/null 2>&1; then
            local nc_cmd="nc"
            command -v ncat >/dev/null 2>&1 && nc_cmd="ncat"
            if timeout "${NFTBAN_TIMEOUT_FAST:-5}" $nc_cmd -z "${NFTBAN_ZABBIX_SERVER}" "${NFTBAN_ZABBIX_PORT:-10051}" 2>/dev/null; then
                zabbix_issues+=("✓ Zabbix server: Reachable")
            else
                zabbix_issues+=("⚠ Zabbix server: Not reachable (may be filtered)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        elif command -v bash >/dev/null 2>&1; then
            if timeout "${NFTBAN_TIMEOUT_FAST:-5}" bash -c "echo >/dev/tcp/${NFTBAN_ZABBIX_SERVER}/${NFTBAN_ZABBIX_PORT:-10051}" 2>/dev/null; then
                zabbix_issues+=("✓ Zabbix server: Reachable (via bash)")
            else
                zabbix_issues+=("⚠ Zabbix server: Not reachable (may be filtered)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            zabbix_issues+=("INFO: Cannot test connectivity (no nc/ncat)")
        fi
    fi

    # Check unified exporter timer (required for Zabbix export)
    if nftban_timer_is_active "nftban-unified-exporter.timer"; then
        zabbix_issues+=("✓ Unified exporter timer: Active")
    elif nftban_service_exists "nftban-unified-exporter.timer"; then
        zabbix_issues+=("⚠ Unified exporter timer: Not active")
        zabbix_issues+=("FIX: sudo systemctl enable --now nftban-unified-exporter.timer")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        zabbix_issues+=("⚠ Unified exporter timer not installed")
        zabbix_issues+=("FIX: Run install.sh to install systemd timers")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check transport binary (zabbix_sender preferred, ncat/nc fallback)
    if command -v zabbix_sender >/dev/null 2>&1; then
        zabbix_issues+=("✓ Transport: zabbix_sender (preferred)")
    elif command -v nc >/dev/null 2>&1 || command -v ncat >/dev/null 2>&1; then
        zabbix_issues+=("✓ Transport: nc/ncat (fallback)")
        zabbix_issues+=("INFO: Install zabbix_sender for best results")
    else
        local ncat_pkg="ncat"
        local install_cmd="install"
        if declare -F nftban_distro_get_package >/dev/null 2>&1; then
            ncat_pkg=$(nftban_distro_get_package "ncat" 2>/dev/null) || ncat_pkg="ncat"
        fi
        if declare -F nftban_distro_get_pkgmgr_cmd >/dev/null 2>&1; then
            install_cmd=$(nftban_distro_get_pkgmgr_cmd "install_cmd" 2>/dev/null) || install_cmd="install"
        fi
        zabbix_issues+=("⚠ No transport binary (zabbix_sender, nc, or ncat)")
        zabbix_issues+=("FIX: Install zabbix_sender or: sudo ${install_cmd} ${ncat_pkg}")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check TLS/PSK configuration if enabled
    if [[ "${NFTBAN_ZABBIX_TLS_ENABLED:-false}" == "true" ]]; then
        if [[ -z "${NFTBAN_ZABBIX_TLS_PSK_FILE:-}" ]]; then
            zabbix_issues+=("⚠ TLS enabled but PSK file not configured")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        elif [[ ! -f "${NFTBAN_ZABBIX_TLS_PSK_FILE}" ]]; then
            zabbix_issues+=("⚠ TLS PSK file not found: ${NFTBAN_ZABBIX_TLS_PSK_FILE}")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            zabbix_issues+=("✓ TLS/PSK: Configured")
        fi
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["zabbix"]=$status
    if [[ ${#zabbix_issues[@]} -gt 0 ]]; then
        local formatted_issues=""
        for issue in "${zabbix_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["zabbix"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# CONNECTORS CHECK (v1.3.0)
# =============================================================================

nftban_health_check_connectors() {
    # Check generic connectors health (Elasticsearch, Kafka, file, syslog, webhook)
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL, 4=NOT_INSTALLED, 5=DISABLED

    local status=$HEALTH_OK
    local connector_issues=()
    local enabled_count=0

    # Load connectors config
    local connectors_conf="${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf"
    local connectors_local="${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf.local"
    [[ -f "$connectors_conf" ]] && source "$connectors_conf" 2>/dev/null || true
    [[ -f "$connectors_local" ]] && source "$connectors_local" 2>/dev/null || true

    # Check if connector framework is enabled
    if [[ "${NFTBAN_CONNECTOR_ENABLED:-false}" != "true" ]]; then
        if [[ -f "$connectors_conf" ]]; then
            NFTBAN_HEALTH_ISSUES["connectors"]="Disabled (set NFTBAN_CONNECTOR_ENABLED=true)"
            NFTBAN_HEALTH_RESULTS["connectors"]=$HEALTH_DISABLED
            return $HEALTH_DISABLED
        else
            NFTBAN_HEALTH_ISSUES["connectors"]="Not installed (optional feature)"
            NFTBAN_HEALTH_RESULTS["connectors"]=$HEALTH_NOT_INSTALLED
            return $HEALTH_NOT_INSTALLED
        fi
    fi

    connector_issues+=("✓ Connector framework: Enabled")

    # Check Elasticsearch connector
    if [[ "${NFTBAN_CONNECTOR_ES_ENABLED:-false}" == "true" ]]; then
        enabled_count=$((enabled_count + 1))
        connector_issues+=("✓ Elasticsearch: Enabled (${NFTBAN_CONNECTOR_ES_ADDRESSES:-localhost:9200})")

        local es_addr="${NFTBAN_CONNECTOR_ES_ADDRESSES%%,*}"
        if command -v curl >/dev/null 2>&1; then
            if curl -s --connect-timeout "${NFTBAN_TIMEOUT_FAST:-5}" "${es_addr}/_cluster/health" >/dev/null 2>&1; then
                connector_issues+=("  ✓ Elasticsearch: Reachable")
            else
                connector_issues+=("  ⚠ Elasticsearch: Not reachable")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check Kafka connector
    if [[ "${NFTBAN_CONNECTOR_KAFKA_ENABLED:-false}" == "true" ]]; then
        enabled_count=$((enabled_count + 1))
        connector_issues+=("✓ Kafka: Enabled (${NFTBAN_CONNECTOR_KAFKA_BROKERS:-localhost:9092})")
    fi

    # Check file connector
    if [[ "${NFTBAN_CONNECTOR_FILE_ENABLED:-false}" == "true" ]]; then
        enabled_count=$((enabled_count + 1))
        local file_dir="${NFTBAN_CONNECTOR_FILE_DIR:-/var/log/nftban/metrics}"
        connector_issues+=("✓ File (NDJSON): Enabled ($file_dir)")

        if [[ -d "$file_dir" ]] && [[ -w "$file_dir" ]]; then
            connector_issues+=("  ✓ Output directory: Writable")
        elif [[ ! -d "$file_dir" ]]; then
            connector_issues+=("  ⚠ Output directory does not exist")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            connector_issues+=("  ⚠ Output directory not writable")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check syslog connector
    if [[ "${NFTBAN_CONNECTOR_SYSLOG_ENABLED:-false}" == "true" ]]; then
        enabled_count=$((enabled_count + 1))
        connector_issues+=("✓ Syslog: Enabled (${NFTBAN_CONNECTOR_SYSLOG_SERVER:-localhost}:${NFTBAN_CONNECTOR_SYSLOG_PORT:-514})")
    fi

    # Check webhook connector
    if [[ "${NFTBAN_CONNECTOR_WEBHOOK_ENABLED:-false}" == "true" ]]; then
        enabled_count=$((enabled_count + 1))
        connector_issues+=("✓ Webhook: Enabled (${NFTBAN_CONNECTOR_WEBHOOK_URL:-not set})")
    fi

    if [[ $enabled_count -eq 0 ]]; then
        connector_issues+=("⚠ No connectors enabled")
        connector_issues+=("Enable at least one: ES, Kafka, File, Syslog, or Webhook")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        connector_issues+=("Total enabled connectors: $enabled_count")
    fi

    # Check unified exporter timer
    if nftban_timer_is_active "nftban-unified-exporter.timer"; then
        connector_issues+=("✓ Unified exporter timer: Active")
    elif nftban_service_exists "nftban-unified-exporter.timer"; then
        connector_issues+=("⚠ Unified exporter timer: Not active")
        connector_issues+=("FIX: sudo systemctl enable --now nftban-unified-exporter.timer")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["connectors"]=$status
    if [[ ${#connector_issues[@]} -gt 0 ]]; then
        local formatted_issues=""
        for issue in "${connector_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["connectors"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# PRO SUBSCRIPTION CHECK (v1.0.0)
# =============================================================================

nftban_health_check_pro() {
    # Check NFTBan Pro subscription health
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL, 4=NOT_INSTALLED

    local status=$HEALTH_OK
    local pro_issues=()

    # Check if Pro is enabled in config
    if [[ "${NFTBAN_PRO_ENABLED:-false}" != "true" ]]; then
        NFTBAN_HEALTH_ISSUES["pro"]="Disabled in config (run 'nftban pro enroll' to enable)"
        NFTBAN_HEALTH_RESULTS["pro"]=$HEALTH_NOT_INSTALLED
        return $HEALTH_NOT_INSTALLED
    fi

    pro_issues+=("✓ Pro subscription: Enabled")

    # Check token file exists
    local token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"
    if [[ ! -f "$token_file" ]]; then
        pro_issues+=("Token file missing: $token_file")
        pro_issues+=("FIX: Run 'nftban pro enroll' to set up token")
        status=$HEALTH_ERROR
    else
        pro_issues+=("✓ Token file: Present")

        # Check token file permissions (must be 0600 or 0640)
        local token_perms
        token_perms=$(stat -c %a "$token_file" 2>/dev/null || stat -f %Lp "$token_file" 2>/dev/null || echo "???")

        if [[ "$token_perms" == "600" || "$token_perms" == "640" ]]; then
            pro_issues+=("✓ Token permissions: $token_perms (secure)")
        else
            pro_issues+=("Token file has insecure permissions: $token_perms")
            pro_issues+=("FIX: sudo chmod 600 $token_file")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check token file ownership (must be root:root or root:nftban)
        local token_owner token_group
        token_owner=$(stat -c %U "$token_file" 2>/dev/null || stat -f %Su "$token_file" 2>/dev/null || echo "???")
        token_group=$(stat -c %G "$token_file" 2>/dev/null || stat -f %Sg "$token_file" 2>/dev/null || echo "???")

        if [[ "$token_owner" == "root" ]]; then
            if [[ "$token_group" == "root" || "$token_group" == "nftban" ]]; then
                pro_issues+=("✓ Token ownership: ${token_owner}:${token_group}")
            else
                pro_issues+=("Token file has incorrect group: $token_group (expected root or nftban)")
                pro_issues+=("FIX: sudo chown root:nftban $token_file")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            pro_issues+=("Token file has incorrect owner: $token_owner (expected root)")
            pro_issues+=("FIX: sudo chown root:root $token_file")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi

        # Check token is not empty
        if [[ ! -s "$token_file" ]]; then
            pro_issues+=("Token file is empty")
            pro_issues+=("FIX: Run 'nftban pro enroll' to configure token")
            [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
        fi
    fi

    # Check server ID file
    local server_id_file="${NFTBAN_PRO_SERVER_ID_FILE:-/etc/nftban/server_id}"
    if [[ -f "$server_id_file" ]]; then
        if [[ -s "$server_id_file" ]]; then
            local server_id
            server_id=$(head -1 "$server_id_file" 2>/dev/null || echo "")
            if [[ -n "$server_id" ]]; then
                pro_issues+=("✓ Server ID: ${server_id:0:8}...")
            else
                pro_issues+=("Server ID file exists but is empty")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        else
            pro_issues+=("Server ID file is empty")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        pro_issues+=("Server ID not generated")
        pro_issues+=("FIX: Server ID will be generated on next 'nftban pro enroll'")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check vmagent is running (Pro mode requires remote_write agent)
    if nftban_service_is_active "vmagent"; then
        pro_issues+=("✓ vmagent: Running")

        local vmagent_config="/etc/victoriametrics/vmagent.yml"
        if [[ -f "$vmagent_config" ]]; then
            if grep -q "pro.nftban.com" "$vmagent_config" 2>/dev/null; then
                pro_issues+=("✓ vmagent config: Pro endpoint configured")
            else
                pro_issues+=("vmagent config does not point to Pro endpoint")
                pro_issues+=("FIX: Run 'nftban metrics enable --pro' to reconfigure")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    elif nftban_service_exists "vmagent.service"; then
        pro_issues+=("vmagent installed but not running")
        pro_issues+=("FIX: sudo systemctl enable --now vmagent")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    else
        pro_issues+=("vmagent not installed (required for Pro metrics)")
        pro_issues+=("FIX: Run 'nftban metrics enable --pro' to install vmagent")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    fi

    # Check Pro timers are enabled
    local pro_timers=("nftban-pro-license.timer" "nftban-pro-inventory.timer")
    for timer in "${pro_timers[@]}"; do
        if nftban_timer_is_active "$timer"; then
            pro_issues+=("✓ ${timer}: Active")
        elif nftban_service_exists "$timer"; then
            pro_issues+=("${timer} exists but not active")
            pro_issues+=("FIX: sudo systemctl enable --now $timer")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        else
            pro_issues+=("${timer} not installed")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    done

    # Store results
    NFTBAN_HEALTH_RESULTS["pro"]=$status
    if [[ ${#pro_issues[@]} -gt 0 ]]; then
        local formatted_issues=""
        for issue in "${pro_issues[@]}"; do
            if [[ -z "$formatted_issues" ]]; then
                formatted_issues="$issue"
            else
                formatted_issues="${formatted_issues}
     ${issue}"
            fi
        done
        NFTBAN_HEALTH_ISSUES["pro"]="$formatted_issues"
    fi

    return $status
}

# =============================================================================
# GUI (WEB UI) CHECK (v0.6.0)
# =============================================================================

nftban_health_check_gui() {
    # Check NFTBan Web UI (nftban-ui) health and binary deployment
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL
    # Auto-heal: Rebuild binary if outdated, restart service if crashed

    local status=$HEALTH_OK
    local gui_issues=()
    local auto_heal="${1:-0}"

    # Check if GUI is installed
    local gui_binary="/usr/sbin/nftban-ui"
    local gui_source_dir="${NFTBAN_DEV_SOURCE_DIR:-}/cmd/nftban-ui"
    local build_binary="$gui_source_dir/nftban-ui"

    if [[ ! -f "$gui_binary" ]]; then
        # v1.25.0: GUI is optional — NOT_INSTALLED, not CRITICAL
        gui_issues+=("Web GUI not installed (optional)")
        gui_issues+=("ℹ️  To install: See nftban documentation for GUI setup")
        status=$HEALTH_NOT_INSTALLED
        NFTBAN_HEALTH_RESULTS["gui"]=$status
        NFTBAN_HEALTH_ISSUES["gui"]="${gui_issues[*]}"
        return 0
    else
        if [[ ! -x "$gui_binary" ]]; then
            gui_issues+=("GUI binary not executable")
            status=$HEALTH_ERROR

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Making GUI binary executable..."
                chmod +x "$gui_binary" && gui_issues+=("✓ Fixed GUI binary permissions")
            fi
        else
            gui_issues+=("✓ GUI binary: Installed and executable")
        fi

        if [[ -f "$build_binary" ]]; then
            local installed_md5 built_md5
            installed_md5=$(md5sum "$gui_binary" 2>/dev/null | awk '{print $1}')
            built_md5=$(md5sum "$build_binary" 2>/dev/null | awk '{print $1}')

            if [[ "$installed_md5" != "$built_md5" ]]; then
                gui_issues+=("Web UI binary outdated (needs reinstall)")
                gui_issues+=("ℹ️  To update: Rebuild with './build.sh' then restart service")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

                if [[ $auto_heal -eq 1 ]]; then
                    echo "  🔧 Auto-heal: Updating GUI binary from build directory..."
                    cp -f "$build_binary" "$gui_binary" 2>&1 && \
                    chmod +x "$gui_binary" 2>&1 && \
                    gui_issues+=("✓ GUI binary updated from build directory")
                fi
            else
                gui_issues+=("✓ GUI binary: Up-to-date")
            fi
        elif [[ -d "$gui_source_dir" ]]; then
            gui_issues+=("✓ GUI binary: Installed (build directory present but binary not built locally)")
        fi
    fi

    # Check if GUI service exists
    local service_exists=false
    if nftban_service_exists "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
        service_exists=true
    fi

    if [[ "$service_exists" == "false" ]]; then
        gui_issues+=("Web UI not enabled (OPTIONAL)")
        gui_issues+=("ℹ️  To enable: Run 'nftban ui init' then 'nftban ui start'")
        if [[ -f "$gui_binary" ]]; then
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        if nftban_service_is_enabled "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
            gui_issues+=("✓ GUI service: Enabled")
        else
            gui_issues+=("Web UI service not enabled (OPTIONAL)")
            gui_issues+=("ℹ️  To enable: Run 'systemctl enable nftban-ui'")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Enabling GUI service..."
                systemctl enable ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1 && gui_issues+=("✓ GUI service enabled")
            fi
        fi

        if nftban_service_is_active "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
            gui_issues+=("✓ GUI service: Running")

            local gui_addr="${NFTBAN_GUI_ADDR:-127.0.0.1:3940}"
            if command -v curl >/dev/null 2>&1; then
                if timeout "${NFTBAN_TIMEOUT_FAST}" curl -k -s "https://${gui_addr}/" >/dev/null 2>&1; then
                    gui_issues+=("✓ GUI: Accessible on https://${gui_addr}")
                else
                    gui_issues+=("GUI not responding on https://${gui_addr}")
                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                fi
            fi
        else
            gui_issues+=("Web UI service not running (OPTIONAL)")
            gui_issues+=("ℹ️  To start: Run 'nftban ui start'")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Starting GUI service..."
                systemctl start ${NFTBAN_SERVICE_UI:-nftban-ui.service} 2>&1 && \
                sleep 2 && \
                nftban_service_is_active "${NFTBAN_SERVICE_UI:-nftban-ui.service}" && \
                gui_issues+=("✓ GUI service started") || gui_issues+=("Failed to start GUI service")
            fi
        fi

        if systemctl is-failed --quiet "${NFTBAN_SERVICE_UI:-nftban-ui.service}" 2>/dev/null; then
            gui_issues+=("GUI service in failed state")
            [[ $status -lt $HEALTH_CRITICAL ]] && status=$HEALTH_CRITICAL

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Resetting failed GUI service..."
                systemctl reset-failed "${NFTBAN_SERVICE_UI:-nftban-ui.service}" 2>&1
                systemctl restart "${NFTBAN_SERVICE_UI:-nftban-ui.service}" 2>&1 && \
                sleep 2 && \
                nftban_service_is_active "${NFTBAN_SERVICE_UI:-nftban-ui.service}" && \
                gui_issues+=("✓ GUI service restarted") || gui_issues+=("Failed to restart GUI service")
            fi
        fi
    fi

    # GUI-AUTH: Check auth socket and directory permissions
    local auth_socket_dir="/run/nftban-ui"
    local auth_socket="${auth_socket_dir}/auth.sock"

    if [[ -d "$auth_socket_dir" ]]; then
        local dir_owner dir_group
        dir_owner=$(stat -c '%U' "$auth_socket_dir" 2>/dev/null || stat -f '%Su' "$auth_socket_dir" 2>/dev/null || echo "???")
        dir_group=$(stat -c '%G' "$auth_socket_dir" 2>/dev/null || stat -f '%Sg' "$auth_socket_dir" 2>/dev/null || echo "???")

        if [[ "$dir_group" != "nftban" ]]; then
            gui_issues+=("GUI-AUTH: Auth socket directory has wrong group: ${dir_owner}:${dir_group} (should be root:nftban)")
            # v1.26.2: Only ERROR when GUI service is active; WARNING when optional and not running
            if nftban_service_is_active "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
                [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
            else
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi

            if [[ $auto_heal -eq 1 ]]; then
                echo "  🔧 Auto-heal: Fixing auth socket directory permissions..."
                chown root:nftban "$auth_socket_dir" 2>&1 && \
                chmod 750 "$auth_socket_dir" 2>&1 && \
                gui_issues+=("✓ GUI-AUTH: Fixed directory permissions")
            fi
        else
            gui_issues+=("✓ GUI-AUTH: Socket directory permissions OK (${dir_owner}:${dir_group})")
        fi

        if [[ -S "$auth_socket" ]]; then
            local sock_owner sock_group
            sock_owner=$(stat -c '%U' "$auth_socket" 2>/dev/null || stat -f '%Su' "$auth_socket" 2>/dev/null || echo "???")
            sock_group=$(stat -c '%G' "$auth_socket" 2>/dev/null || stat -f '%Sg' "$auth_socket" 2>/dev/null || echo "???")

            if [[ "$sock_group" != "nftban" ]]; then
                gui_issues+=("GUI-AUTH: Auth socket has wrong group: ${sock_owner}:${sock_group} (should be root:nftban)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            else
                gui_issues+=("✓ GUI-AUTH: Socket permissions OK (${sock_owner}:${sock_group})")
            fi
        else
            if nftban_service_is_active "nftban-ui-auth.service"; then
                gui_issues+=("GUI-AUTH: Auth service running but socket missing")
                [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
            fi
        fi
    elif nftban_service_is_active "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
        gui_issues+=("GUI-AUTH: Auth socket directory missing (/run/nftban-ui)")
        gui_issues+=("ℹ️  Restart auth service: systemctl restart nftban-ui-auth")
        [[ $status -lt $HEALTH_ERROR ]] && status=$HEALTH_ERROR
    fi

    # Check GUI log file for recent errors
    if [[ -f "${NFTBAN_LOG_DIR}-ui.log" ]]; then
        local error_count
        error_count=$(tail -n 50 ${NFTBAN_LOG_DIR}-ui.log 2>/dev/null | grep -c "ERROR\|FATAL\|panic" || echo 0)

        if [[ $error_count -gt 0 ]]; then
            gui_issues+=("Found $error_count errors in recent GUI logs")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["gui"]=$status
    NFTBAN_HEALTH_ISSUES["gui"]="${gui_issues[*]}"

    return $status
}

# =============================================================================
# WATCHDOG TIMER CHECK (v1.10.0)
# =============================================================================

nftban_health_check_watchdog() {
    # Check watchdog timer health for system resource monitoring
    # Returns: 0=OK, 1=WARNING, 2=ERROR, 3=CRITICAL, 4=NOT_INSTALLED, 5=DISABLED

    local status=$HEALTH_OK
    local watchdog_timer="nftban-watchdog.timer"

    # Check if timer unit exists
    if ! systemctl list-unit-files "$watchdog_timer" --no-legend 2>/dev/null | grep -q "^$watchdog_timer"; then
        NFTBAN_HEALTH_ISSUES["watchdog"]="Timer not installed"
        NFTBAN_HEALTH_RESULTS["watchdog"]=$HEALTH_NOT_INSTALLED
        return $HEALTH_NOT_INSTALLED
    fi

    # Check if timer is enabled
    if ! systemctl is-enabled "$watchdog_timer" &>/dev/null; then
        NFTBAN_HEALTH_ISSUES["watchdog"]="Timer disabled (run: systemctl enable $watchdog_timer)"
        NFTBAN_HEALTH_RESULTS["watchdog"]=$HEALTH_DISABLED
        return $HEALTH_DISABLED
    fi

    # Check if timer is active
    if ! systemctl is-active "$watchdog_timer" &>/dev/null; then
        NFTBAN_HEALTH_ISSUES["watchdog"]="Timer not running (run: systemctl start $watchdog_timer)"
        NFTBAN_HEALTH_RESULTS["watchdog"]=$HEALTH_WARNING
        return $HEALTH_WARNING
    fi

    # Timer is running
    NFTBAN_HEALTH_RESULTS["watchdog"]=$HEALTH_OK
    return $HEALTH_OK
}

# Export functions
export -f nftban_health_check_metrics nftban_health_check_zabbix
export -f nftban_health_check_connectors nftban_health_check_pro
export -f nftban_health_check_gui nftban_health_check_watchdog
