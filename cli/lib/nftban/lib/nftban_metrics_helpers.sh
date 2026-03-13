#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics_helpers" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Metrics conflict detection and configuration helpers"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_METRICS_HELPERS_LOADED:-}" ]] && return 0
_NFTBAN_METRICS_HELPERS_LOADED=1

# =============================================================================
# CONFLICT DETECTION FUNCTIONS
# =============================================================================

# Check if Prometheus is installed (service exists)
_is_prometheus_installed() {
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")

    # Check if service file exists
    if systemctl list-unit-files 2>/dev/null | grep -q "^${prometheus_service}.service"; then
        return 0
    fi

    # Check if binary exists
    if [[ -f "/usr/bin/prometheus" ]] || [[ -f "/usr/local/bin/prometheus" ]]; then
        return 0
    fi

    return 1
}

# Check if VictoriaMetrics is installed (service exists)
_is_victoriametrics_installed() {
    # Check if service file exists
    if systemctl list-unit-files 2>/dev/null | grep -q "^victoriametrics.service"; then
        return 0
    fi

    # Check if binary exists
    if [[ -f "/usr/local/bin/victoria-metrics-prod" ]] || [[ -f "/usr/bin/victoria-metrics-prod" ]]; then
        return 0
    fi

    return 1
}

# Check if Prometheus is running
_is_prometheus_running() {
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    systemctl is-active "$prometheus_service" &>/dev/null
}

# Check if VictoriaMetrics is running
_is_victoriametrics_running() {
    systemctl is-active victoriametrics &>/dev/null
}

# Display conflict warning and instructions
_show_conflict_warning() {
    local requested_backend="$1"
    local other_backend=""
    local other_service=""

    if [[ "$requested_backend" == "prometheus" ]]; then
        other_backend="VictoriaMetrics"
        other_service="victoriametrics"
    else
        other_backend="Prometheus"
        other_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  METRICS BACKEND CONFLICT DETECTED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  You requested: $requested_backend"
    echo "  Already running: $other_backend"
    echo ""
    echo "  NFTBan supports only ONE metrics backend at a time."
    echo "  Running both wastes resources and causes confusion."
    echo ""
    echo "  To switch to $requested_backend, first disable $other_backend:"
    echo ""
    echo "    # Stop $other_backend"
    echo "    sudo systemctl stop $other_service"
    echo "    sudo systemctl disable $other_service"
    echo ""
    echo "    # Then enable $requested_backend"
    echo "    nftban metrics enable --backend $requested_backend"
    echo ""
    echo "  Or use 'nftban metrics disable' to stop all metrics first."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Show warning when both backends are installed (even if not both running)
_show_dual_install_warning() {
    local requested_backend="$1"
    local other_backend=""
    local other_service=""

    if [[ "$requested_backend" == "prometheus" ]]; then
        other_backend="VictoriaMetrics"
        other_service="victoriametrics"
    else
        other_backend="Prometheus"
        other_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NOTE: Both metrics backends are installed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Installed:"
    echo "    - Prometheus"
    echo "    - VictoriaMetrics"
    echo ""
    echo "  Using: $requested_backend"
    echo ""
    echo "  You only need one metrics database. Consider removing the other:"
    echo ""
    if [[ "$requested_backend" == "prometheus" ]]; then
        echo "    # Remove VictoriaMetrics (optional)"
        echo "    sudo systemctl stop victoriametrics"
        echo "    sudo systemctl disable victoriametrics"
        echo "    sudo rm /etc/systemd/system/victoriametrics.service"
        echo "    sudo rm /usr/local/bin/victoria-metrics-prod"
    else
        echo "    # Remove Prometheus (optional)"
        echo "    sudo systemctl stop $other_service"
        echo "    sudo systemctl disable $other_service"
        echo "    # Then use package manager: dnf remove prometheus2 / apt remove prometheus"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# CONFIG HELPERS
# =============================================================================

# Get current backend from config
_get_metrics_backend() {
    # Returns: "prometheus" or "victoriametrics" (defaults to prometheus)
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        local backend
        backend=$(grep "^NFTBAN_METRICS_BACKEND=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        if [[ -n "$backend" ]]; then
            echo "$backend"
            return
        fi
    fi
    echo "prometheus"  # Default
}

# Set backend in config
_set_metrics_backend() {
    local backend="$1"
    local local_conf="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

    mkdir -p "${NFTBAN_CONFIG_DIR}" || return 1
    touch "$local_conf"

    if grep -q "^NFTBAN_METRICS_BACKEND=" "$local_conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_BACKEND=.*|NFTBAN_METRICS_BACKEND=\"${backend}\"|" "$local_conf"
    else
        echo "NFTBAN_METRICS_BACKEND=\"${backend}\"" >> "$local_conf"
    fi

    # Also set metrics mode to true
    if grep -q "^NFTBAN_METRICS_MODE=" "$local_conf" 2>/dev/null; then
        sed -i 's|^NFTBAN_METRICS_MODE=.*|NFTBAN_METRICS_MODE="true"|' "$local_conf"
    else
        echo 'NFTBAN_METRICS_MODE="true"' >> "$local_conf"
    fi
}

# Set agent/storage in config (writes to nftban.conf.local — user overrides)
_set_metrics_agent_storage() {
    local agent="$1"
    local storage="$2"
    local local_conf="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

    mkdir -p "${NFTBAN_CONFIG_DIR}" || return 1
    touch "$local_conf"

    # Update or add NFTBAN_METRICS_AGENT
    if grep -q "^NFTBAN_METRICS_AGENT=" "$local_conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_AGENT=.*|NFTBAN_METRICS_AGENT=\"${agent}\"|" "$local_conf"
    else
        echo "NFTBAN_METRICS_AGENT=\"${agent}\"" >> "$local_conf"
    fi

    # Update or add NFTBAN_METRICS_STORAGE
    if grep -q "^NFTBAN_METRICS_STORAGE=" "$local_conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_STORAGE=.*|NFTBAN_METRICS_STORAGE=\"${storage}\"|" "$local_conf"
    else
        echo "NFTBAN_METRICS_STORAGE=\"${storage}\"" >> "$local_conf"
    fi
}

# =============================================================================
# AGENT/STORAGE VALIDATION
# =============================================================================

# Validate agent/storage combination
_validate_agent_storage() {
    local agent="$1"
    local storage="$2"
    local remote_url="$3"

    # Set defaults if not specified
    if [[ -z "$agent" ]]; then
        agent="prometheus"
    fi
    if [[ -z "$storage" ]]; then
        storage="prometheus-local"
    fi

    # Validate agent value
    case "$agent" in
        prometheus|vmagent|none) ;;
        *)
            echo "Invalid agent: $agent"
            echo "   Valid options: prometheus, vmagent, none"
            return 1
            ;;
    esac

    # Validate storage value
    case "$storage" in
        prometheus-local|vm-local|remote) ;;
        *)
            echo "Invalid storage: $storage"
            echo "   Valid options: prometheus-local, vm-local, remote"
            return 1
            ;;
    esac

    # Validate combination
    case "${agent}:${storage}" in
        "prometheus:prometheus-local") ;; # Mode A
        "prometheus:vm-local") ;;          # Mode C1
        "vmagent:remote") ;;               # Mode B
        "vmagent:vm-local") ;;             # Mode C2
        "none:remote") ;;                  # External agent
        *)
            echo "Invalid agent/storage combination: ${agent}/${storage}"
            echo ""
            echo "   Valid combinations:"
            echo "   - --agent=prometheus --storage=prometheus-local  (Mode A)"
            echo "   - --agent=prometheus --storage=vm-local          (Mode C1)"
            echo "   - --agent=vmagent --storage=remote               (Mode B)"
            echo "   - --agent=vmagent --storage=vm-local             (Mode C2)"
            echo "   - --agent=none --storage=remote                  (External agent)"
            return 1
            ;;
    esac

    # Validate remote_url is provided when storage=remote
    if [[ "$storage" == "remote" ]] && [[ -z "$remote_url" ]]; then
        echo "--remote-write-url is required when --storage=remote"
        return 1
    fi

    return 0
}

# Configure Prometheus for remote_write (Mode C1)
_configure_prometheus_remote_write() {
    local remote_url="$1"
    local prom_config="/etc/prometheus/prometheus.yml"

    # Backup existing config
    if [[ -f "$prom_config" ]]; then
        cp "$prom_config" "${prom_config}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # Create prometheus config with remote_write
    mkdir -p "$(dirname "$prom_config")" || return 1
    cat > "$prom_config" << EOF
# Prometheus Configuration - Mode C1 (remote_write to local VictoriaMetrics)
# Generated by NFTBan on $(date -Iseconds)

global:
  scrape_interval: 60s
  evaluation_interval: 60s
  external_labels:
    service: 'nftban'

scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*|node_.*'
        action: keep

remote_write:
  - url: '${remote_url}'
    queue_config:
      max_samples_per_send: 10000
      batch_send_deadline: 10s
      capacity: 100000
EOF

    echo "  Prometheus configured with remote_write to ${remote_url}"
}
