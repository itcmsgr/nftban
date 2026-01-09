#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Metrics Management (Prometheus or VictoriaMetrics)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable metrics collection with choice of backend
#
# meta:name=cmd_metrics
# meta:type=cli
# meta:header=Metrics Management
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Manage Prometheus or VictoriaMetrics collection independently from Web GUI
# meta:input=Subcommands (enable, disable, status) with optional --backend flag
# meta:output=Metrics stack status and configuration
#
# **Inventory & Requirements**
# meta:depends=systemd,prometheus|victoriametrics,node-exporter,nftban-metrics-exporter
#
# meta:created_date=2025-11-28
# meta:updated_date=2026-01-09
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

# Load main config for metrics endpoint addresses
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# Metrics endpoint defaults (use config or fallback)
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"
: "${NFTBAN_METRICS_VICTORIA_ADDR:=localhost:8428}"

# Load helper functions
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh"
fi

# Load shared metrics library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh"
fi

# Load pipeline validation library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh"
fi

# Load Pro library for Case B
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh"
fi

# Load VM Enterprise key library (VictoriaMetrics integration)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_vm_enterprise.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_vm_enterprise.sh"
fi

# ==============================================================================
# CONFLICT DETECTION FUNCTIONS
# ==============================================================================

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

# Detect conflict: both backends installed
_check_backend_conflict() {
    local prometheus_installed=false
    local victoriametrics_installed=false
    local prometheus_running=false
    local victoriametrics_running=false

    if _is_prometheus_installed; then
        prometheus_installed=true
        if _is_prometheus_running; then
            prometheus_running=true
        fi
    fi

    if _is_victoriametrics_installed; then
        victoriametrics_installed=true
        if _is_victoriametrics_running; then
            victoriametrics_running=true
        fi
    fi

    # Return status via global variables
    CONFLICT_PROMETHEUS_INSTALLED="$prometheus_installed"
    CONFLICT_VICTORIAMETRICS_INSTALLED="$victoriametrics_installed"
    CONFLICT_PROMETHEUS_RUNNING="$prometheus_running"
    CONFLICT_VICTORIAMETRICS_RUNNING="$victoriametrics_running"

    # Check for actual conflict (both running)
    if [[ "$prometheus_running" == "true" ]] && [[ "$victoriametrics_running" == "true" ]]; then
        return 1  # Conflict: both running
    fi

    return 0
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
    echo "  ⚠️  METRICS BACKEND CONFLICT DETECTED"
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
    echo "  ℹ️  NOTE: Both metrics backends are installed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Installed:"
    echo "    • Prometheus"
    echo "    • VictoriaMetrics"
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

# ==============================================================================
# Helper: Get current backend from config
# ==============================================================================
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

# ==============================================================================
# Helper: Set backend in config
# ==============================================================================
_set_metrics_backend() {
    local backend="$1"

    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        mkdir -p "${NFTBAN_CONFIG_DIR}"
        touch "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi

    if grep -q "^NFTBAN_METRICS_BACKEND=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_BACKEND=.*|NFTBAN_METRICS_BACKEND=\"${backend}\"|" "${NFTBAN_CONFIG_DIR}/nftban.conf"
    else
        echo "NFTBAN_METRICS_BACKEND=\"${backend}\"" >> "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi

    # Also set metrics mode to true
    if grep -q "^NFTBAN_METRICS_MODE=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null; then
        sed -i 's|^NFTBAN_METRICS_MODE=.*|NFTBAN_METRICS_MODE="true"|' "${NFTBAN_CONFIG_DIR}/nftban.conf"
    else
        echo 'NFTBAN_METRICS_MODE="true"' >> "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi
}

# ==============================================================================
# CASE A: Remote submission to user's own backend
# ==============================================================================
_metrics_enable_remote_user() {
    local remote_url="${1:-}"
    local token_file="${2:-}"
    local external_labels="${3:-}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Remote Submission (Case A: Your Backend)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Validate remote_write URL is provided
    if [[ -z "$remote_url" ]]; then
        echo "❌ Error: Remote write URL required"
        echo ""
        echo "Usage: nftban metrics enable --remote --url <remote_write_url> [--token <file>] [--labels key=val,...]"
        echo ""
        echo "Examples:"
        echo "  nftban metrics enable --remote --url https://mimir.example.com/api/v1/push"
        echo "  nftban metrics enable --remote --url https://vm.example.com/api/v1/write --token /etc/nftban/grafana.token"
        echo "  nftban metrics enable --remote --url https://grafana-cloud.example.com/api/prom/push --labels site=prod,env=production"
        echo ""
        return 1
    fi

    # Step 1: Install vmagent
    echo "Step 1/4: Installing vmagent..."
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh"
        if ! install_vmagent_binary true; then
            echo "❌ Failed to install vmagent"
            return 1
        fi
    else
        echo "❌ vmagent installation script not found"
        return 1
    fi

    # Step 2: Ensure node_exporter is running (for metrics source)
    echo ""
    echo "Step 2/4: Ensuring Node Exporter is running..."
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            echo "  ✓ Node Exporter already running ($svc)"
            break
        fi
    done

    if [[ "$node_exporter_running" == "false" ]]; then
        echo "  Installing Node Exporter..."
        if [[ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]]; then
            bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary 2>/dev/null || true
        fi
        # Try to start node_exporter
        for svc in node-exporter node_exporter prometheus-node-exporter; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
                systemctl enable --now "$svc" &>/dev/null && break
            fi
        done
    fi

    # Ensure metrics exporter timer is enabled
    systemctl enable --now nftban-metrics-exporter.timer &>/dev/null || true
    systemctl start nftban-metrics-exporter.service &>/dev/null || true
    echo "  ✓ NFTBan metrics exporter enabled"

    # Step 3: Configure vmagent for user's backend
    echo ""
    echo "Step 3/4: Configuring vmagent for remote_write..."
    create_vmagent_config_user_backend "$remote_url" "$token_file" "$external_labels"

    # Step 4: Start vmagent
    echo ""
    echo "Step 4/4: Starting vmagent..."
    create_vmagent_systemd_service
    if ! start_vmagent; then
        echo "❌ Failed to start vmagent"
        return 1
    fi

    # Validate pipeline
    echo ""
    echo "Validating metrics pipeline..."
    sleep 2  # Give vmagent time to start

    nftban_print_pipeline_report

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Remote Metrics Submission Enabled"
    echo ""
    echo "   Remote Write URL:  $remote_url"
    [[ -n "$token_file" ]] && echo "   Token File:        $token_file"
    [[ -n "$external_labels" ]] && echo "   External Labels:   $external_labels"
    echo ""
    echo "   vmagent Status:    http://localhost:8429/"
    echo "   vmagent Targets:   http://localhost:8429/targets"
    echo ""
    echo "   NOTE: Inventory submission is NOT enabled for user backends."
    echo "         Use --pro for NFTBan Pro features."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# CASE B: Remote submission to NFTBan Pro
# ==============================================================================
_metrics_enable_pro() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Pro Subscription (Case B)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 1: Check/create server_id
    echo "Step 1/6: Ensuring server identity..."
    local server_id
    server_id=$(nftban_pro_ensure_server_id)
    echo "  ✓ Server ID: $server_id"

    # Step 2: Check token exists
    echo ""
    echo "Step 2/6: Checking Pro token..."
    local token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"

    if [[ ! -f "$token_file" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚠️  Pro Token Required"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  To enable NFTBan Pro, you need a subscription token."
        echo ""
        echo "  1. Visit https://pro.nftban.com to get your token"
        echo "  2. Save it to: $token_file"
        echo ""
        echo "     echo 'YOUR_TOKEN_HERE' | sudo tee $token_file"
        echo "     sudo chmod 640 $token_file"
        echo "     sudo chown root:nftban $token_file"
        echo ""
        echo "  3. Re-run: nftban metrics enable --pro"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 1
    fi
    echo "  ✓ Token file exists: $token_file"

    # Step 3: Validate license
    echo ""
    echo "Step 3/6: Validating Pro subscription..."
    if nftban_pro_check_license; then
        echo "  ✓ Subscription valid"
    else
        echo "  ⚠️  Could not validate subscription (may work offline)"
        echo "      Will retry validation later via license timer"
    fi

    # Step 4: Install vmagent
    echo ""
    echo "Step 4/6: Installing vmagent..."
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh"
        if ! install_vmagent_binary true; then
            echo "❌ Failed to install vmagent"
            return 1
        fi
    else
        echo "❌ vmagent installation script not found"
        return 1
    fi

    # Ensure node_exporter is running
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            break
        fi
    done

    if [[ "$node_exporter_running" == "false" ]]; then
        echo "  Installing Node Exporter..."
        if [[ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]]; then
            bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary 2>/dev/null || true
        fi
        for svc in node-exporter node_exporter prometheus-node-exporter; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
                systemctl enable --now "$svc" &>/dev/null && break
            fi
        done
    fi

    # Ensure metrics exporter timer is enabled
    systemctl enable --now nftban-metrics-exporter.timer &>/dev/null || true
    systemctl start nftban-metrics-exporter.service &>/dev/null || true

    # Step 5: Configure vmagent for Pro
    echo ""
    echo "Step 5/6: Configuring vmagent for NFTBan Pro..."
    create_vmagent_config_pro "$server_id" "$(hostname -f 2>/dev/null || hostname)"
    create_vmagent_systemd_service

    if ! start_vmagent; then
        echo "❌ Failed to start vmagent"
        return 1
    fi

    # Step 6: Collect and submit inventory
    echo ""
    echo "Step 6/6: Collecting server inventory..."
    local inventory_hash
    inventory_hash=$(nftban_pro_save_inventory)
    echo "  ✓ Inventory collected (hash: ${inventory_hash:0:16}...)"

    # Try to submit inventory (don't fail if endpoint not reachable)
    echo "  Submitting inventory to Pro..."
    if nftban_pro_submit_inventory true; then
        echo "  ✓ Inventory submitted"
    else
        echo "  ⚠️  Inventory submission deferred (will retry via timer)"
    fi

    # Enable license timer
    echo ""
    echo "Enabling Pro license timer..."
    systemctl enable nftban-pro-license.timer &>/dev/null || true
    systemctl start nftban-pro-license.timer &>/dev/null || true
    echo "  ✓ License timer enabled (checks every 6 hours)"

    # Validate pipeline
    echo ""
    echo "Validating metrics pipeline..."
    sleep 2

    nftban_print_pipeline_report

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan Pro Enabled Successfully"
    echo ""
    echo "   Server ID:         $server_id"
    echo "   Remote Write:      https://pro.nftban.com/api/v1/write"
    echo "   Inventory:         /var/lib/nftban/pro/inventory.json"
    echo ""
    echo "   vmagent Status:    http://localhost:8429/"
    echo "   vmagent Targets:   http://localhost:8429/targets"
    echo ""
    echo "   Pro Features:"
    echo "   • Metrics streaming to pro.nftban.com"
    echo "   • Server inventory and benchmarking"
    echo "   • AI-powered recommendations (coming soon)"
    echo "   • Centralized dashboard at https://pro.nftban.com"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# AGENT/STORAGE MODEL FUNCTIONS (VictoriaMetrics integration)
# ==============================================================================

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
            echo "❌ Invalid agent: $agent"
            echo "   Valid options: prometheus, vmagent, none"
            return 1
            ;;
    esac

    # Validate storage value
    case "$storage" in
        prometheus-local|vm-local|remote) ;;
        *)
            echo "❌ Invalid storage: $storage"
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
            echo "❌ Invalid agent/storage combination: ${agent}/${storage}"
            echo ""
            echo "   Valid combinations:"
            echo "   • --agent=prometheus --storage=prometheus-local  (Mode A)"
            echo "   • --agent=prometheus --storage=vm-local          (Mode C1)"
            echo "   • --agent=vmagent --storage=remote               (Mode B)"
            echo "   • --agent=vmagent --storage=vm-local             (Mode C2)"
            echo "   • --agent=none --storage=remote                  (External agent)"
            return 1
            ;;
    esac

    # Validate remote_url is provided when storage=remote
    if [[ "$storage" == "remote" ]] && [[ -z "$remote_url" ]]; then
        echo "❌ --remote-write-url is required when --storage=remote"
        return 1
    fi

    return 0
}

# ==============================================================================
# Mode A: Prometheus all-in-one (scrape + store locally)
# ==============================================================================
_metrics_enable_mode_a() {
    local retention="${1:-90d}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Mode A: Prometheus All-in-One"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Agent:     Prometheus (scrape)"
    echo "  Storage:   Prometheus TSDB (local)"
    echo "  Retention: ${retention}"
    echo ""

    # Check if already enabled
    if systemctl is-active prometheus &>/dev/null && \
       systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
        echo "✅ Prometheus metrics already enabled"
        echo ""
        echo "📊 Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
        echo "📈 Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
        return 0
    fi

    # Step 1: Check and install dependencies
    echo "Step 1/3: Checking Prometheus dependencies..."

    if ! nftban_metrics_check_deps; then
        echo "  ⚠️  Missing: ${NFTBAN_METRICS_MISSING[*]}"
        if ! nftban_metrics_install_deps; then
            return 1
        fi
    else
        echo "  ✓ All dependencies present"
    fi

    # Step 2: Start metrics stack
    echo ""
    echo "Step 2/3: Starting Prometheus stack..."

    if ! nftban_metrics_start_stack; then
        echo "  ❌ Failed to start Prometheus stack"
        return 1
    fi

    # Step 3: Update config
    echo ""
    echo "Step 3/3: Updating configuration..."
    _set_metrics_backend "prometheus"
    _set_metrics_agent_storage "prometheus" "prometheus-local"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Mode A Enabled Successfully!"
    echo ""
    echo "📊 Prometheus UI:   http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    echo "📈 Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "📁 NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "⏱️  Collection:      Every 60 seconds"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Mode B: Agent-only (vmagent -> remote_write)
# ==============================================================================
_metrics_enable_mode_b() {
    local remote_url="$1"
    local token_file="$2"
    local external_labels="$3"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Mode B: Agent-Only (vmagent -> remote)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Agent:     vmagent (scrape + ship)"
    echo "  Storage:   Remote backend"
    echo "  URL:       ${remote_url}"
    echo ""

    # Delegate to existing remote user function
    _metrics_enable_remote_user "$remote_url" "$token_file" "$external_labels"
    local result=$?

    if [[ $result -eq 0 ]]; then
        _set_metrics_agent_storage "vmagent" "remote"
    fi

    return $result
}

# ==============================================================================
# Mode C1: Prometheus scrapes -> remote_write to local VictoriaMetrics
# ==============================================================================
_metrics_enable_mode_c1() {
    local retention="${1:-90d}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Mode C1: Prometheus -> Local VictoriaMetrics"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Agent:     Prometheus (scrape + remote_write)"
    echo "  Storage:   VictoriaMetrics (local)"
    echo "  Retention: ${retention}"
    echo ""

    # Step 1: Install VictoriaMetrics storage
    echo "Step 1/5: Installing VictoriaMetrics storage..."
    if ! nftban_metrics_install_victoriametrics true; then
        echo "  ❌ Failed to install VictoriaMetrics"
        return 1
    fi

    # Step 2: Install Prometheus if not present
    echo ""
    echo "Step 2/5: Checking Prometheus dependencies..."
    if ! nftban_metrics_check_deps; then
        echo "  ⚠️  Missing: ${NFTBAN_METRICS_MISSING[*]}"
        if ! nftban_metrics_install_deps; then
            return 1
        fi
    else
        echo "  ✓ All dependencies present"
    fi

    # Step 3: Configure Prometheus for remote_write to local VM
    echo ""
    echo "Step 3/5: Configuring Prometheus for remote_write to local VM..."
    _configure_prometheus_remote_write "http://localhost:8428/api/v1/write"

    # Step 4: Start VictoriaMetrics
    echo ""
    echo "Step 4/5: Starting VictoriaMetrics storage..."
    systemctl enable victoriametrics &>/dev/null || true
    systemctl start victoriametrics &>/dev/null || true

    # Wait for VM to be ready
    local retries=10
    while ! curl -sf "http://localhost:8428/health" &>/dev/null && [[ $retries -gt 0 ]]; do
        sleep 1
        ((retries--))
    done

    if ! systemctl is-active victoriametrics &>/dev/null; then
        echo "  ❌ Failed to start VictoriaMetrics"
        return 1
    fi
    echo "  ✓ VictoriaMetrics running"

    # Step 5: Start Prometheus with remote_write
    echo ""
    echo "Step 5/5: Starting Prometheus (agent mode)..."
    if ! nftban_metrics_start_stack; then
        echo "  ❌ Failed to start Prometheus stack"
        return 1
    fi

    # Update config
    _set_metrics_backend "victoriametrics"
    _set_metrics_agent_storage "prometheus" "vm-local"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Mode C1 Enabled Successfully!"
    echo ""
    echo "📊 Prometheus (scraper): http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    echo "📊 VictoriaMetrics UI:   http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
    echo "📈 Node Exporter:        http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "📁 NFTBan Metrics:       /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "💾 Retention:            ${retention}"
    echo ""
    echo "💡 VictoriaMetrics Benefits:"
    echo "   • 10x better compression"
    echo "   • Faster queries"
    echo "   • Lower resource usage"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Mode C2: vmagent scrapes -> writes to local VictoriaMetrics
# ==============================================================================
_metrics_enable_mode_c2() {
    local retention="${1:-90d}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Mode C2: vmagent -> Local VictoriaMetrics"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Agent:     vmagent (scrape + write)"
    echo "  Storage:   VictoriaMetrics (local)"
    echo "  Retention: ${retention}"
    echo ""

    # Step 1: Install VictoriaMetrics storage
    echo "Step 1/5: Installing VictoriaMetrics storage..."
    if ! nftban_metrics_install_victoriametrics true; then
        echo "  ❌ Failed to install VictoriaMetrics"
        return 1
    fi

    # Step 2: Install vmagent
    echo ""
    echo "Step 2/5: Installing vmagent..."
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh"
        if ! install_vmagent_binary true; then
            echo "  ❌ Failed to install vmagent"
            return 1
        fi
    else
        echo "  ❌ vmagent installation script not found"
        return 1
    fi

    # Step 3: Ensure node_exporter is running
    echo ""
    echo "Step 3/5: Ensuring Node Exporter is running..."
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            echo "  ✓ Node Exporter already running ($svc)"
            break
        fi
    done

    if [[ "$node_exporter_running" == "false" ]]; then
        echo "  Installing Node Exporter..."
        if [[ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]]; then
            bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary 2>/dev/null || true
        fi
        for svc in node-exporter node_exporter prometheus-node-exporter; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
                systemctl enable --now "$svc" &>/dev/null && break
            fi
        done
    fi

    # Ensure metrics exporter timer is enabled
    systemctl enable --now nftban-metrics-exporter.timer &>/dev/null || true
    systemctl start nftban-metrics-exporter.service &>/dev/null || true
    echo "  ✓ NFTBan metrics exporter enabled"

    # Step 4: Configure vmagent for local VM
    echo ""
    echo "Step 4/5: Configuring vmagent for local VictoriaMetrics..."
    create_vmagent_config_local_vm "http://localhost:8428/api/v1/write"
    create_vmagent_systemd_service

    # Step 5: Start services
    echo ""
    echo "Step 5/5: Starting services..."

    # Start VictoriaMetrics
    systemctl enable victoriametrics &>/dev/null || true
    systemctl start victoriametrics &>/dev/null || true

    # Wait for VM to be ready
    local retries=10
    while ! curl -sf "http://localhost:8428/health" &>/dev/null && [[ $retries -gt 0 ]]; do
        sleep 1
        ((retries--))
    done

    if ! systemctl is-active victoriametrics &>/dev/null; then
        echo "  ❌ Failed to start VictoriaMetrics"
        return 1
    fi
    echo "  ✓ VictoriaMetrics running"

    # Start vmagent
    if ! start_vmagent; then
        echo "  ❌ Failed to start vmagent"
        return 1
    fi
    echo "  ✓ vmagent running"

    # Update config
    _set_metrics_backend "victoriametrics"
    _set_metrics_agent_storage "vmagent" "vm-local"

    # Validate pipeline
    echo ""
    echo "Validating metrics pipeline..."
    sleep 2
    nftban_print_pipeline_report

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Mode C2 Enabled Successfully!"
    echo ""
    echo "📊 VictoriaMetrics UI:   http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
    echo "📊 vmagent Status:       http://localhost:8429/"
    echo "📊 vmagent Targets:      http://localhost:8429/targets"
    echo "📈 Node Exporter:        http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "📁 NFTBan Metrics:       /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "💾 Retention:            ${retention}"
    echo ""
    echo "💡 VictoriaMetrics Benefits:"
    echo "   • 10x better compression"
    echo "   • Faster queries"
    echo "   • Lower resource usage"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Exporters-only mode (external agent)
# ==============================================================================
_metrics_enable_exporters_only() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics - Exporters Only (External Agent)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Agent:     External (not managed by NFTBan)"
    echo "  Storage:   Remote"
    echo ""

    # Ensure node_exporter is running
    echo "Step 1/2: Ensuring Node Exporter is running..."
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            echo "  ✓ Node Exporter already running ($svc)"
            break
        fi
    done

    if [[ "$node_exporter_running" == "false" ]]; then
        echo "  Installing Node Exporter..."
        if [[ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]]; then
            bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary 2>/dev/null || true
        fi
        for svc in node-exporter node_exporter prometheus-node-exporter; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
                systemctl enable --now "$svc" &>/dev/null && break
            fi
        done
    fi

    # Ensure metrics exporter timer is enabled
    echo ""
    echo "Step 2/2: Enabling NFTBan metrics exporter..."
    systemctl enable --now nftban-metrics-exporter.timer &>/dev/null || true
    systemctl start nftban-metrics-exporter.service &>/dev/null || true
    echo "  ✓ NFTBan metrics exporter enabled"

    _set_metrics_agent_storage "none" "remote"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Exporters Enabled Successfully!"
    echo ""
    echo "📈 Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "📁 NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo ""
    echo "Configure your external agent to scrape localhost:9100"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Helper: Configure Prometheus for remote_write (Mode C1)
# ==============================================================================
_configure_prometheus_remote_write() {
    local remote_url="$1"
    local prom_config="/etc/prometheus/prometheus.yml"

    # Backup existing config
    if [[ -f "$prom_config" ]]; then
        cp "$prom_config" "${prom_config}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # Create prometheus config with remote_write
    mkdir -p "$(dirname "$prom_config")"
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

    echo "  ✓ Prometheus configured with remote_write to ${remote_url}"
}

# ==============================================================================
# Helper: Set agent/storage in config
# ==============================================================================
_set_metrics_agent_storage() {
    local agent="$1"
    local storage="$2"

    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        mkdir -p "${NFTBAN_CONFIG_DIR}"
        touch "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi

    # Update or add NFTBAN_METRICS_AGENT
    if grep -q "^NFTBAN_METRICS_AGENT=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_AGENT=.*|NFTBAN_METRICS_AGENT=\"${agent}\"|" "${NFTBAN_CONFIG_DIR}/nftban.conf"
    else
        echo "NFTBAN_METRICS_AGENT=\"${agent}\"" >> "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi

    # Update or add NFTBAN_METRICS_STORAGE
    if grep -q "^NFTBAN_METRICS_STORAGE=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null; then
        sed -i "s|^NFTBAN_METRICS_STORAGE=.*|NFTBAN_METRICS_STORAGE=\"${storage}\"|" "${NFTBAN_CONFIG_DIR}/nftban.conf"
    else
        echo "NFTBAN_METRICS_STORAGE=\"${storage}\"" >> "${NFTBAN_CONFIG_DIR}/nftban.conf"
    fi
}

# ==============================================================================
# Command: nftban metrics enable [options]
# ==============================================================================
# New Agent/Storage Model (VictoriaMetrics integration):
#   --agent prometheus|vmagent|none       Collection agent
#   --storage prometheus-local|vm-local|remote  Storage target
#   --remote-write-url URL                Remote endpoint (required if storage=remote)
#   --retention DURATION                  Retention period (default: 90d)
#   --vm-version VERSION                  VictoriaMetrics version override
#
# Legacy Options (deprecated, use --agent/--storage instead):
#   --backend prometheus|victoriametrics  DEPRECATED: maps to agent/storage
#   --remote                              Enable remote submission to user's backend
#   --pro                                 Enable NFTBan Pro submission
#   --url URL                             Remote write URL (for --remote)
#   --token FILE                          Token file path (optional)
#   --labels KEY=VAL,KEY=VAL              External labels (optional)
#
# Mode Reference:
#   Mode A: --agent=prometheus --storage=prometheus-local (Prometheus all-in-one)
#   Mode B: --agent=vmagent --storage=remote (Agent-only to remote)
#   Mode C1: --agent=prometheus --storage=vm-local (Prometheus -> local VM)
#   Mode C2: --agent=vmagent --storage=vm-local (vmagent -> local VM)
# ==============================================================================
nftban_metrics_enable() {
    # New agent/storage model (VictoriaMetrics integration)
    local agent=""              # prometheus | vmagent | none
    local storage=""            # prometheus-local | vm-local | remote
    local retention="90d"       # Retention period for local storage
    local vm_version=""         # VictoriaMetrics version override

    # Legacy/existing flags
    local backend=""            # DEPRECATED: use --agent/--storage instead
    local force=false
    local remote_mode=""        # "user" or "pro" or ""
    local remote_url=""
    local token_file=""
    local external_labels=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # New agent/storage model flags
            --agent)
                agent="$2"
                shift 2
                ;;
            --agent=*)
                agent="${1#*=}"
                shift
                ;;
            --storage)
                storage="$2"
                shift 2
                ;;
            --storage=*)
                storage="${1#*=}"
                shift
                ;;
            --retention)
                retention="$2"
                shift 2
                ;;
            --retention=*)
                retention="${1#*=}"
                shift
                ;;
            --vm-version)
                vm_version="$2"
                shift 2
                ;;
            --vm-version=*)
                vm_version="${1#*=}"
                shift
                ;;
            --remote-write-url)
                remote_url="$2"
                storage="remote"
                shift 2
                ;;
            --remote-write-url=*)
                remote_url="${1#*=}"
                storage="remote"
                shift
                ;;
            # Legacy flags (backward compatibility)
            --backend)
                backend="$2"
                shift 2
                ;;
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
                # shellcheck disable=SC2034  # Reserved for force flag
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # ============================================================================
    # BACKWARD COMPATIBILITY: Map legacy --backend flag to new model
    # ============================================================================
    if [[ -n "$backend" ]] && [[ -z "$agent" ]] && [[ -z "$storage" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  DEPRECATION WARNING: --backend flag"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  The --backend flag is deprecated. Use --agent and --storage instead."
        echo ""
        case "$backend" in
            prometheus)
                echo "  Mapping: --backend prometheus"
                echo "       to: --agent=prometheus --storage=prometheus-local"
                agent="prometheus"
                storage="prometheus-local"
                ;;
            victoriametrics)
                echo "  Mapping: --backend victoriametrics"
                echo "       to: --agent=vmagent --storage=vm-local"
                agent="vmagent"
                storage="vm-local"
                ;;
            *)
                echo "  Unknown backend: $backend"
                return 1
                ;;
        esac
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi

    # Export VM version if specified
    if [[ -n "$vm_version" ]]; then
        export NFTBAN_VM_VERSION="$vm_version"
    fi

    # Export retention for use by install scripts
    export NFTBAN_METRICS_RETENTION="$retention"

    # ============================================================================
    # NEW AGENT/STORAGE MODEL ROUTING (VictoriaMetrics integration)
    # ============================================================================
    if [[ -n "$agent" ]] || [[ -n "$storage" ]]; then
        # Validate agent/storage combination
        if ! _validate_agent_storage "$agent" "$storage" "$remote_url"; then
            return 1
        fi

        # Route to appropriate mode handler
        case "${agent}:${storage}" in
            "prometheus:prometheus-local")
                # Mode A: Prometheus all-in-one
                _metrics_enable_mode_a "$retention"
                return $?
                ;;
            "vmagent:remote")
                # Mode B: Agent-only to remote
                _metrics_enable_mode_b "$remote_url" "$token_file" "$external_labels"
                return $?
                ;;
            "prometheus:vm-local")
                # Mode C1: Prometheus -> local VictoriaMetrics
                _metrics_enable_mode_c1 "$retention"
                return $?
                ;;
            "vmagent:vm-local")
                # Mode C2: vmagent -> local VictoriaMetrics
                _metrics_enable_mode_c2 "$retention"
                return $?
                ;;
            "none:remote")
                # External agent mode - just ensure exporters are running
                _metrics_enable_exporters_only
                return $?
                ;;
            *)
                echo "❌ Unsupported agent/storage combination: ${agent}/${storage}"
                return 1
                ;;
        esac
    fi

    # ============================================================================
    # LEGACY: User's own backend (--remote)
    # ============================================================================
    if [[ "$remote_mode" == "user" ]]; then
        _metrics_enable_remote_user "$remote_url" "$token_file" "$external_labels"
        return $?
    fi

    # ============================================================================
    # LEGACY: NFTBan Pro (--pro)
    # ============================================================================
    if [[ "$remote_mode" == "pro" ]]; then
        _metrics_enable_pro
        return $?
    fi

    # ============================================================================
    # LEGACY LOCAL MODE: Standard local metrics backend
    # ============================================================================

    # Default to prometheus if no agent/storage specified
    if [[ -z "$backend" ]]; then
        backend="prometheus"
    fi

    # Validate backend
    if [[ "$backend" != "prometheus" ]] && [[ "$backend" != "victoriametrics" ]]; then
        echo "❌ Invalid backend: $backend"
        echo "   Valid options: prometheus, victoriametrics"
        return 1
    fi

    # ============================================================================
    # CONFLICT DETECTION: Check for existing installations
    # ============================================================================
    _check_backend_conflict

    # Check if the OTHER backend is running (not the one being requested)
    local conflict_detected=false
    if [[ "$backend" == "prometheus" ]] && [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
        conflict_detected=true
        _show_conflict_warning "prometheus"
        echo "❌ Cannot enable Prometheus while VictoriaMetrics is running."
        echo ""
        return 1
    elif [[ "$backend" == "victoriametrics" ]] && [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]]; then
        # shellcheck disable=SC2034  # Reserved for conflict resolution
        conflict_detected=true
        _show_conflict_warning "victoriametrics"
        echo "❌ Cannot enable VictoriaMetrics while Prometheus is running."
        echo ""
        return 1
    fi

    # Warn if both backends are installed (but only one running)
    local dual_install=false
    if [[ "$CONFLICT_PROMETHEUS_INSTALLED" == "true" ]] && [[ "$CONFLICT_VICTORIAMETRICS_INSTALLED" == "true" ]]; then
        dual_install=true
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling NFTBan Metrics Collection"
    echo "  Backend: $backend"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    case "$backend" in
        prometheus)
            # Check if already enabled
            if systemctl is-active prometheus &>/dev/null && \
               systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
                echo "✅ Prometheus metrics already enabled"
                echo ""
                echo "📊 Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
                echo "📈 Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
                echo ""

                # Show dual install warning if applicable
                if [[ "$dual_install" == "true" ]]; then
                    _show_dual_install_warning "prometheus"
                fi

                return 0
            fi

            # Step 1: Check and install dependencies
            echo "Step 1/3: Checking Prometheus dependencies..."

            if ! nftban_metrics_check_deps; then
                echo "  ⚠️  Missing: ${NFTBAN_METRICS_MISSING[*]}"
                if ! nftban_metrics_install_deps; then
                    return 1
                fi
            else
                echo "  ✓ All dependencies present"
            fi

            # Step 2: Start metrics stack
            echo ""
            echo "Step 2/3: Starting Prometheus stack..."

            if ! nftban_metrics_start_stack; then
                echo "  ❌ Failed to start Prometheus stack"
                return 1
            fi

            # Update config
            _set_metrics_backend "prometheus"

            # Final output
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "✅ Prometheus Metrics Enabled Successfully!"
            echo ""
            echo "📊 Prometheus UI:   http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
            echo "📈 Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
            echo "📁 NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
            echo "⏱️  Collection:      Every 60 seconds"
            echo ""
            echo "Test: nftban metrics status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Show dual install warning if applicable
            if [[ "$dual_install" == "true" ]]; then
                _show_dual_install_warning "prometheus"
            fi
            ;;

        victoriametrics)
            # Check if already enabled
            if systemctl is-active victoriametrics &>/dev/null && \
               systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
                echo "✅ VictoriaMetrics already enabled"
                echo ""
                echo "📊 VictoriaMetrics:  http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
                echo "📈 Metrics:          http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
                echo ""

                # Show dual install warning if applicable
                if [[ "$dual_install" == "true" ]]; then
                    _show_dual_install_warning "victoriametrics"
                fi

                return 0
            fi

            # Step 1: Install VictoriaMetrics
            echo "Step 1/3: Installing VictoriaMetrics..."

            if ! nftban_metrics_install_victoriametrics true; then
                echo "  ❌ Failed to install VictoriaMetrics"
                return 1
            fi

            # Install node_exporter if not present
            local node_exporter_service
            node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")
            if ! systemctl list-unit-files 2>/dev/null | grep -q "${node_exporter_service}.service"; then
                echo "  📦 Installing Node Exporter..."

                # Get package name from distro config (central config system)
                local node_exporter_pkg
                node_exporter_pkg=$(nftban_distro_get_package "node_exporter" 2>/dev/null || echo "prometheus-node-exporter")

                # Try package manager first
                local pkg_installed=false
                if command -v apt-get &>/dev/null; then
                    if apt-get update -qq && apt-get install -y "$node_exporter_pkg" &>/dev/null; then
                        pkg_installed=true
                    fi
                elif command -v dnf &>/dev/null; then
                    if dnf install -y "$node_exporter_pkg" &>/dev/null; then
                        pkg_installed=true
                    fi
                fi

                # Fallback to binary installation if package not available
                if [ "$pkg_installed" = false ]; then
                    echo "    Package not available in repos, installing from GitHub..."
                    if [ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]; then
                        bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary || echo "    ⚠️  Node Exporter install failed (non-critical)"
                    fi
                fi
            fi

            # Step 2: Start metrics stack
            echo ""
            echo "Step 2/3: Starting VictoriaMetrics stack..."

            if ! nftban_metrics_start_stack_victoriametrics true; then
                echo "  ❌ Failed to start VictoriaMetrics stack"
                return 1
            fi

            # Update config
            _set_metrics_backend "victoriametrics"

            # Final output
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "✅ VictoriaMetrics Enabled Successfully!"
            echo ""
            echo "📊 VictoriaMetrics UI:  http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
            echo "📊 API Endpoint:        http://${NFTBAN_METRICS_VICTORIA_ADDR}"
            echo "📈 Node Exporter:       http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
            echo "📁 NFTBan Metrics:      /var/lib/node_exporter/textfile_collector/nftban.prom"
            echo "⏱️  Collection:          Every 60 seconds"
            echo "💾 Retention:           12 months (vs Prometheus 30 days)"
            echo ""
            echo "💡 VictoriaMetrics Benefits:"
            echo "   • 10x better compression (90% less disk)"
            echo "   • 20x faster queries"
            echo "   • Lower RAM/CPU usage"
            echo "   • Prometheus-compatible (same queries work)"
            echo ""
            echo "Test: nftban metrics status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Show dual install warning if applicable
            if [[ "$dual_install" == "true" ]]; then
                _show_dual_install_warning "victoriametrics"
            fi
            ;;
    esac
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

    # Detect current backend
    local backend
    backend=$(_get_metrics_backend)

    echo "Current backend: $backend"
    echo ""

    # Check if already disabled
    local is_running=false
    case "$backend" in
        prometheus)
            if systemctl is-active prometheus &>/dev/null; then
                is_running=true
            fi
            ;;
        victoriametrics)
            if systemctl is-active victoriametrics &>/dev/null; then
                is_running=true
            fi
            ;;
    esac

    if [[ "$is_running" == false ]]; then
        echo "ℹ️  Metrics already disabled"
        return 0
    fi

    # Stop metrics stack
    echo "Stopping metrics services..."

    case "$backend" in
        prometheus)
            nftban_metrics_stop_stack true
            ;;
        victoriametrics)
            nftban_metrics_stop_stack_victoriametrics true
            ;;
    esac

    # Update config
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        sed -i 's/^NFTBAN_METRICS_MODE=.*/NFTBAN_METRICS_MODE="false"/' "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true
    fi

    echo ""
    echo "✅ Metrics collection disabled"
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

    # Check for conflicts first (ignore return code, we handle conflicts in display)
    _check_backend_conflict || true

    # Detect configured backend
    local backend
    backend=$(_get_metrics_backend)

    echo "Configured Backend: $backend"
    echo ""

    # Show installation status
    echo "Installation Status:"
    if [[ "$CONFLICT_PROMETHEUS_INSTALLED" == "true" ]]; then
        if [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]]; then
            echo "  • Prometheus:       Installed ✅ Running"
        else
            echo "  • Prometheus:       Installed (stopped)"
        fi
    else
        echo "  • Prometheus:       Not installed"
    fi

    if [[ "$CONFLICT_VICTORIAMETRICS_INSTALLED" == "true" ]]; then
        if [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
            echo "  • VictoriaMetrics:  Installed ✅ Running"
        else
            echo "  • VictoriaMetrics:  Installed (stopped)"
        fi
    else
        echo "  • VictoriaMetrics:  Not installed"
    fi
    echo ""

    # Warn if both are running
    if [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]] && [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  WARNING: Both backends are running!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "This wastes resources. Stop one of them:"
        echo "  nftban metrics disable"
        echo ""
    fi

    # ============================================================================
    # CONFIGURATION MISMATCH DETECTION
    # ============================================================================
    # Detect if wrong backend is running (configured != actual)
    local config_mismatch=false
    local wrong_backend=""
    local correct_backend=""

    if [[ "$backend" == "prometheus" ]] && [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
        config_mismatch=true
        wrong_backend="VictoriaMetrics"
        correct_backend="victoriametrics"
    elif [[ "$backend" == "victoriametrics" ]] && [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]]; then
        config_mismatch=true
        wrong_backend="Prometheus"
        correct_backend="prometheus"
    fi

    if [[ "$config_mismatch" == "true" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  CONFIGURATION MISMATCH DETECTED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Configured backend:  $backend"
        echo "  Actually running:    $correct_backend ($wrong_backend)"
        echo ""
        echo "  Your $wrong_backend is working fine, but the configuration"
        echo "  file points to the wrong backend."
        echo ""
        echo "  FIX: Update the configuration to match reality:"
        echo ""
        echo "    sed -i 's/NFTBAN_METRICS_BACKEND=\"$backend\"/NFTBAN_METRICS_BACKEND=\"$correct_backend\"/' /etc/nftban/nftban.conf"
        echo ""
        echo "  Then verify: nftban metrics status"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 0
    fi

    # ============================================================================
    # NORMAL STATUS DISPLAY
    # ============================================================================
    local all_running=true

    echo "Active Backend Details:"
    case "$backend" in
        prometheus)
            # Check Prometheus
            local prometheus_service
            prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
            if systemctl is-active "$prometheus_service" &>/dev/null; then
                echo "✅ Prometheus:        Running"
                echo "   URL:               http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
            else
                echo "❌ Prometheus:        Stopped"
                all_running=false
            fi
            ;;

        victoriametrics)
            # Check VictoriaMetrics
            if systemctl is-active victoriametrics &>/dev/null; then
                echo "✅ VictoriaMetrics:   Running"
                echo "   UI:                http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
                echo "   API:               http://${NFTBAN_METRICS_VICTORIA_ADDR}"

                # Check health endpoint
                if curl -sf "http://${NFTBAN_METRICS_VICTORIA_ADDR}/health" &>/dev/null; then
                    echo "   Health:            OK"
                fi
            else
                echo "❌ VictoriaMetrics:   Stopped"
                all_running=false
            fi
            ;;
    esac

    echo ""

    # Check Node Exporter (common for both)
    # Service name varies: node_exporter, node-exporter, prometheus-node-exporter
    local node_exporter_running=false
    if systemctl is-active node_exporter &>/dev/null || \
       systemctl is-active node-exporter &>/dev/null || \
       systemctl is-active prometheus-node-exporter &>/dev/null; then
        node_exporter_running=true
    fi

    if [[ "$node_exporter_running" == "true" ]]; then
        echo "✅ Node Exporter:     Running"
        echo "   URL:               http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    else
        echo "❌ Node Exporter:     Stopped"
        all_running=false
    fi

    echo ""

    # Check NFTBan metrics exporter (common for both)
    if systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
        echo "✅ NFTBan Exporter:   Running"
        local last_run
        last_run=$(systemctl show nftban-metrics-exporter.timer -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
        if [[ -n "$last_run" ]] && [[ "$last_run" != "n/a" ]]; then
            echo "   Last run:          $(date -d "$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_run")"
        fi
        echo "   Interval:          60 seconds"
        echo "   Output:            /var/lib/node_exporter/textfile_collector/nftban.prom"
    else
        echo "❌ NFTBan Exporter:   Stopped"
        all_running=false
    fi

    echo ""

    if [[ "$all_running" == true ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ All metrics services running"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  Some services stopped"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "To enable metrics collection, choose a setup:"
        echo ""
        echo "  # Simplest (Prometheus all-in-one)"
        echo "  nftban metrics enable"
        echo ""
        echo "  # Recommended (VictoriaMetrics - 10x compression)"
        echo "  nftban metrics enable --agent=vmagent --storage=vm-local"
        echo ""
        echo "  # See all options"
        echo "  nftban metrics help"
        echo ""
    fi

    echo ""
}

# ==============================================================================
# ==============================================================================
# VictoriaMetrics Enterprise Key Management
# ==============================================================================

nftban_metrics_enterprise_key() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        set)
            # Set enterprise key
            local key=""
            local from_file=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --file|-f)
                        from_file="$2"
                        shift 2
                        ;;
                    --file=*)
                        from_file="${1#*=}"
                        shift
                        ;;
                    *)
                        key="$1"
                        shift
                        ;;
                esac
            done

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  VictoriaMetrics Enterprise Trial Key"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            if [[ -n "$from_file" ]]; then
                # Read key from file
                if nftban_vm_enterprise_write_key_from_file "$from_file"; then
                    echo ""
                    nftban_vm_enterprise_reload_services
                else
                    return 1
                fi
            elif [[ -n "$key" ]]; then
                # Use provided key
                if nftban_vm_enterprise_write_key "$key"; then
                    echo ""
                    nftban_vm_enterprise_reload_services
                else
                    return 1
                fi
            else
                # Interactive prompt
                echo "  Enter your VictoriaMetrics Enterprise trial key."
                echo "  Get a trial key from: https://victoriametrics.com/products/enterprise/"
                echo ""
                echo -n "  Key: "
                read -rs key
                echo ""

                if [[ -z "$key" ]]; then
                    echo ""
                    echo "  ❌ No key provided"
                    return 1
                fi

                if nftban_vm_enterprise_write_key "$key"; then
                    echo ""
                    nftban_vm_enterprise_reload_services
                else
                    return 1
                fi
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  NOTE: NFTBan does not intermediate VictoriaMetrics licensing."
            echo "  Enterprise support is provided directly by VictoriaMetrics Inc."
            echo "  https://victoriametrics.com/products/enterprise/"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            ;;

        remove)
            # Remove enterprise key
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Removing VictoriaMetrics Enterprise Key"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            nftban_vm_enterprise_remove_key

            echo ""
            nftban_vm_enterprise_reload_services
            echo ""
            ;;

        status)
            # Show status
            local json_flag=""
            [[ "${1:-}" == "--json" ]] && json_flag="json"

            nftban_vm_enterprise_status "$json_flag"
            ;;

        validate)
            # Validate permissions
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Validating Enterprise Key Permissions"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            nftban_vm_enterprise_validate_permissions
            echo ""
            ;;

        fix-permissions)
            # Fix permissions
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Fixing Enterprise Key Permissions"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            nftban_vm_enterprise_fix_permissions
            echo ""
            ;;

        help|--help|-h)
            echo "Usage: nftban metrics enterprise-key {set|remove|status|validate|fix-permissions}"
            echo ""
            echo "VictoriaMetrics Enterprise trial key management."
            echo ""
            echo "Commands:"
            echo "  set [KEY]          Set enterprise trial key (interactive if no key provided)"
            echo "  set --file FILE    Set key from file"
            echo "  remove             Remove enterprise key"
            echo "  status [--json]    Show enterprise key status"
            echo "  validate           Validate key file permissions"
            echo "  fix-permissions    Fix key file permissions"
            echo ""
            echo "Examples:"
            echo "  nftban metrics enterprise-key set                    # Interactive"
            echo "  nftban metrics enterprise-key set YOUR_KEY_HERE      # Direct"
            echo "  nftban metrics enterprise-key set --file /tmp/key    # From file"
            echo "  nftban metrics enterprise-key status"
            echo "  nftban metrics enterprise-key remove"
            echo ""
            echo "Get a trial key from: https://victoriametrics.com/products/enterprise/"
            echo ""
            echo "NOTE: NFTBan does not ship Enterprise binaries."
            echo "      Enterprise support is provided directly by VictoriaMetrics Inc."
            echo ""
            ;;

        *)
            echo "Unknown enterprise-key command: $action"
            echo "Usage: nftban metrics enterprise-key {set|remove|status|validate|fix-permissions|help}"
            return 1
            ;;
    esac
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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
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
        set-backend)
            # Quick command to update backend configuration
            local new_backend="${1:-}"

            if [[ -z "$new_backend" ]]; then
                echo "❌ Error: Backend required"
                echo ""
                echo "Usage: nftban metrics set-backend <backend>"
                echo ""
                echo "Available backends:"
                echo "  • prometheus"
                echo "  • victoriametrics"
                echo ""
                return 1
            fi

            if [[ "$new_backend" != "prometheus" ]] && [[ "$new_backend" != "victoriametrics" ]]; then
                echo "❌ Invalid backend: $new_backend"
                echo "   Valid options: prometheus, victoriametrics"
                return 1
            fi

            # Update configuration
            _set_metrics_backend "$new_backend"

            echo "✅ Metrics backend updated to: $new_backend"
            echo ""
            echo "Verify: nftban metrics status"
            echo ""
            ;;
        enterprise-key)
            # VictoriaMetrics Enterprise trial key management
            nftban_metrics_enterprise_key "$@"
            ;;
        help|--help|-h)
            echo "Usage: nftban metrics {enable|disable|status|pipeline|enterprise-key} [options]"
            echo ""
            echo "Commands:"
            echo "  enable          Enable metrics collection"
            echo "  disable         Disable metrics collection"
            echo "  status          Show metrics services status"
            echo "  pipeline        Show pipeline validation report"
            echo "  enterprise-key  Manage VictoriaMetrics Enterprise trial keys"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  SETUP OPTIONS (choose your stack)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  --agent=<agent>       Metrics collection agent"
            echo "                        prometheus  (default) - CNCF standard"
            echo "                        vmagent     - Lightweight, drop-in replacement"
            echo "                        none        - Use external scraper"
            echo ""
            echo "  --storage=<storage>   Where metrics are stored"
            echo "                        prometheus-local  (default) - Prometheus TSDB"
            echo "                        vm-local          - VictoriaMetrics (10x compression)"
            echo "                        remote            - Ship to external backend"
            echo ""
            echo "  --retention=<period>  Data retention (default: 90d)"
            echo "  --vm-version=<ver>    VictoriaMetrics version (default: v1.99.0)"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  PROMETHEUS SETUPS (Prometheus as scraper)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  Mode A - Prometheus All-in-One (simplest)"
            echo "    Agent: Prometheus | Storage: Prometheus TSDB"
            echo "    Best for: Standard setups, existing Prometheus users"
            echo "    Command: nftban metrics enable --agent=prometheus --storage=prometheus-local"
            echo ""
            echo "  Mode C1 - Prometheus + VictoriaMetrics (best storage)"
            echo "    Agent: Prometheus | Storage: VictoriaMetrics"
            echo "    Best for: Long retention, resource-constrained systems"
            echo "    Command: nftban metrics enable --agent=prometheus --storage=vm-local"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  VICTORIAMETRICS SETUPS (vmagent as scraper)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  Mode B - vmagent to Remote Backend"
            echo "    Agent: vmagent | Storage: Your remote (Grafana Cloud, Mimir, etc.)"
            echo "    Best for: Centralized monitoring, cloud dashboards"
            echo "    Command: nftban metrics enable --agent=vmagent --storage=remote \\"
            echo "             --remote-write-url=https://your-backend/api/v1/write"
            echo ""
            echo "  Mode C2 - vmagent + VictoriaMetrics (full VM stack)"
            echo "    Agent: vmagent | Storage: VictoriaMetrics"
            echo "    Best for: Maximum efficiency, lowest resource usage"
            echo "    Command: nftban metrics enable --agent=vmagent --storage=vm-local"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  SPECIAL SETUPS"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  NFTBan Pro (managed metrics + insights)"
            echo "    Agent: vmagent | Storage: pro.nftban.com"
            echo "    Features: Central dashboard, inventory, AI recommendations"
            echo "    Command: nftban metrics enable --pro"
            echo "    Requires: Subscription token at /etc/nftban/pro.token"
            echo ""
            echo "  External Agent (BYO scraper)"
            echo "    Agent: none | Storage: remote"
            echo "    Best for: Existing monitoring infrastructure"
            echo "    Command: nftban metrics enable --agent=none --storage=remote"
            echo "    (Only exposes exporters, you provide the scraper)"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  REMOTE OPTIONS (for --storage=remote or Mode B)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  --remote-write-url=<URL>  Remote write endpoint (REQUIRED)"
            echo "  --token=<FILE>            Bearer token file for authentication"
            echo "  --labels=<KEY=VAL,...>    External labels (site=prod,env=live)"
            echo ""
            echo "  Supported Remote Backends:"
            echo "    - Grafana Cloud:    https://<stack>.grafana.net/api/prom/push"
            echo "    - VictoriaMetrics:  https://your-vm/api/v1/write"
            echo "    - Mimir/Cortex:     https://your-mimir/api/v1/push"
            echo "    - Thanos Receive:   https://your-thanos/api/v1/receive"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  QUICK START EXAMPLES"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  # Simplest setup - Prometheus all-in-one"
            echo "  nftban metrics enable"
            echo ""
            echo "  # Best compression - VictoriaMetrics storage"
            echo "  nftban metrics enable --agent=vmagent --storage=vm-local"
            echo ""
            echo "  # Send to Grafana Cloud"
            echo "  nftban metrics enable --agent=vmagent --storage=remote \\"
            echo "    --remote-write-url=https://12345.grafana.net/api/prom/push \\"
            echo "    --token=/etc/nftban/grafana.token --labels=site=prod"
            echo ""
            echo "  # NFTBan Pro subscription"
            echo "  nftban metrics enable --pro"
            echo ""
            echo "  # Status and validation"
            echo "  nftban metrics status"
            echo "  nftban metrics pipeline --json"
            echo ""
            echo "  # Enterprise key (for VictoriaMetrics Enterprise)"
            echo "  nftban metrics enterprise-key status"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  DEPRECATED FLAGS (still work, but use new style)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  --backend prometheus       -> --agent=prometheus --storage=prometheus-local"
            echo "  --backend victoriametrics  -> --agent=vmagent --storage=vm-local"
            echo "  --remote --url <URL>       -> --agent=vmagent --storage=remote --remote-write-url=<URL>"
            echo ""
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo "Usage: nftban metrics {enable|disable|status|pipeline|enterprise-key|help}"
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_cmd_metrics
