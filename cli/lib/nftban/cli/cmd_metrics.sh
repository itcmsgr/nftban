#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Metrics Management (Prometheus)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable Prometheus metrics collection
#
# meta:name="cmd_metrics"
# meta:type="cli"
# meta:header="Metrics Management"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Manage Prometheus metrics collection independently from Web GUI"
# meta:inventory.files=""
# meta:inventory.binaries="prometheus,node_exporter"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="prometheus.service,node_exporter.service"
# meta:inventory.network="127.0.0.1:9090,127.0.0.1:9100"
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-28"
# meta:updated_date="2026-01-25"
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main config (sets readonly paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Metrics endpoint defaults (use config or fallback)
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"

# Load helper functions
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" || return 1
fi

# Load shared metrics library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" || return 1
fi

# Load pipeline validation library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" || return 1
fi

# Load Pro library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" || return 1
fi

# Load metrics helpers (config helpers, validation)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh" || return 1
fi

# ==============================================================================
# Command: nftban metrics enable [options]
# ==============================================================================
# Options:
#   --pro                                 Enable NFTBan Pro submission
#   --remote                              Enable remote submission to user's backend
#   --url URL                             Remote write URL (for --remote)
#   --token FILE                          Token file path (optional)
#   --labels KEY=VAL,KEY=VAL              External labels (optional)
#   --force|-f                            Force enable even if already running
# ==============================================================================
nftban_metrics_enable() {
    local force=false
    local remote_mode=""        # "user" or "pro" or ""
    local remote_url=""
    local token_file=""
    local external_labels=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote)
                remote_mode="user"
                shift
                ;;
            --pro)
                remote_mode="pro"
                shift
                ;;
            --url)
                remote_url="$2"
                shift 2
                ;;
            --token)
                token_file="$2"
                shift 2
                ;;
            --token=*)
                token_file="${1#*=}"
                shift
                ;;
            --labels)
                external_labels="$2"
                shift 2
                ;;
            --labels=*)
                external_labels="${1#*=}"
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # ============================================================================
    # Remote: User's own backend (--remote)
    # ============================================================================
    if [[ "$remote_mode" == "user" ]]; then
        _metrics_enable_remote_user "$remote_url" "$token_file" "$external_labels"
        return $?
    fi

    # ============================================================================
    # Remote: NFTBan Pro (--pro)
    # ============================================================================
    if [[ "$remote_mode" == "pro" ]]; then
        _metrics_enable_pro
        return $?
    fi

    # ============================================================================
    # LOCAL MODE: Prometheus metrics
    # ============================================================================

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling NFTBan Metrics Collection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already enabled
    if [[ "$force" != "true" ]] && \
       systemctl is-active prometheus &>/dev/null && \
       systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "Prometheus metrics already enabled"
        echo ""
        echo "Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
        echo "Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
        echo ""
        return 0
    fi

    # Step 1: Check and install dependencies
    echo "Step 1/3: Checking Prometheus dependencies..."

    if ! nftban_metrics_check_deps; then
        echo "  Missing: ${NFTBAN_METRICS_MISSING[*]}"
        if ! nftban_metrics_install_deps; then
            return 1
        fi
    else
        echo "  All dependencies present"
    fi

    # Step 2: Start metrics stack
    echo ""
    echo "Step 2/3: Starting Prometheus stack..."

    if ! nftban_metrics_start_stack; then
        echo "  Failed to start Prometheus stack"
        return 1
    fi

    # Update config
    _set_metrics_backend "prometheus"

    # Final output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Prometheus Metrics Enabled Successfully!"
    echo ""
    echo "Prometheus UI:   http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    echo "Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "Collection:      Every 60 seconds"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Command: nftban metrics disable
# ==============================================================================
nftban_metrics_disable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling NFTBan Metrics Collection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already disabled
    if ! systemctl is-active prometheus &>/dev/null; then
        echo "Metrics already disabled"
        return 0
    fi

    # Stop metrics stack
    echo "Stopping metrics services..."
    nftban_metrics_stop_stack true

    # Update config - disable metrics via ENABLED flag in nftban.conf.local
    # User overrides go to .conf.local — package defaults (.conf) are never modified
    local local_conf="${NFTBAN_CONFIG_DIR}/nftban.conf.local"
    touch "$local_conf"
    chown root:nftban "$local_conf" 2>/dev/null || true
    chmod 640 "$local_conf"
    if grep -q "^NFTBAN_METRICS_ENABLED=" "$local_conf"; then
        sed -i 's/^NFTBAN_METRICS_ENABLED=.*/NFTBAN_METRICS_ENABLED="false"/' "$local_conf" 2>/dev/null || true
    else
        echo 'NFTBAN_METRICS_ENABLED="false"' >> "$local_conf"
    fi

    echo ""
    echo "Metrics collection disabled"
    echo ""
}

# ==============================================================================
# Command: nftban metrics status
# ==============================================================================
nftban_metrics_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show export configuration
    local local_export="OpenMetrics format (node_exporter textfile)"
    local remote_export="None"

    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" == "true" ]]; then
        remote_export="Zabbix trapper (${NFTBAN_ZABBIX_SERVER:-not configured})"
    fi

    echo "Local:  $local_export"
    echo "Remote: $remote_export"
    echo ""

    # ============================================================================
    # STATUS DISPLAY
    # ============================================================================
    local all_running=true

    echo "Service Status:"

    # Check Prometheus
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    if systemctl is-active "$prometheus_service" &>/dev/null; then
        echo "  Prometheus:        Running"
        echo "   URL:               http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    else
        echo "  Prometheus:        Stopped"
        all_running=false
    fi

    echo ""

    # Check Node Exporter
    # Service name varies: node_exporter, node-exporter, prometheus-node-exporter
    local node_exporter_running=false
    if systemctl is-active node_exporter &>/dev/null || \
       systemctl is-active node-exporter &>/dev/null || \
       systemctl is-active prometheus-node-exporter &>/dev/null; then
        node_exporter_running=true
    fi

    if [[ "$node_exporter_running" == "true" ]]; then
        echo "  Node Exporter:     Running"
        echo "   URL:               http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    else
        echo "  Node Exporter:     Stopped"
        all_running=false
    fi

    echo ""

    # Check NFTBan metrics exporter
    if systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "  NFTBan Exporter:   Running"
        local last_run
        last_run=$(systemctl show nftban-unified-exporter.timer -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
        if [[ -n "$last_run" ]] && [[ "$last_run" != "n/a" ]]; then
            echo "   Last run:          $(date -d "$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_run")"
        fi
        echo "   Interval:          60 seconds"
        echo "   Output:            /var/lib/node_exporter/textfile_collector/nftban.prom"
    else
        echo "  NFTBan Exporter:   Stopped"
        all_running=false
    fi

    echo ""

    if [[ "$all_running" == true ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "All metrics services running"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Some services stopped"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "To enable metrics collection:"
        echo ""
        echo "  nftban metrics enable"
        echo ""
    fi

    echo ""
}

# ==============================================================================
# Main Command Handler
# ==============================================================================

nftban_cmd_metrics() {
    local subcommand="${1:-status}"
    shift || true

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        enable)
            nftban_metrics_enable "$@"
            ;;
        disable)
            nftban_metrics_disable
            ;;
        status)
            nftban_metrics_status
            ;;
        pipeline)
            # Show pipeline validation report
            local json_flag=""
            [[ "${1:-}" == "--json" ]] && json_flag="--json"
            nftban_print_pipeline_report $json_flag
            ;;
        help|--help|-h)
            echo "Usage: nftban metrics {enable|disable|status|pipeline} [options]"
            echo ""
            echo "Commands:"
            echo "  enable          Enable Prometheus metrics collection"
            echo "  disable         Disable metrics collection"
            echo "  status          Show metrics services status"
            echo "  pipeline        Show pipeline validation report"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ENABLE OPTIONS"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  --pro                     Enable NFTBan Pro metrics submission"
            echo "  --remote                  Enable remote submission to your backend"
            echo "  --url URL                 Remote write URL (for --remote)"
            echo "  --token FILE              Token file path (optional)"
            echo "  --labels KEY=VAL,...      External labels (optional)"
            echo "  --force                   Force enable even if already running"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  EXAMPLES"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  # Enable local Prometheus metrics"
            echo "  nftban metrics enable"
            echo ""
            echo "  # Enable NFTBan Pro subscription"
            echo "  nftban metrics enable --pro"
            echo ""
            echo "  # Send to remote backend (Grafana Cloud, Mimir, etc.)"
            echo "  nftban metrics enable --remote --url https://your-backend/api/v1/write"
            echo ""
            echo "  # Check status"
            echo "  nftban metrics status"
            echo ""
            echo "  # Show pipeline validation"
            echo "  nftban metrics pipeline --json"
            echo ""
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo "Usage: nftban metrics {enable|disable|status|pipeline|help}"
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_cmd_metrics
