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
# meta:updated_date=2025-12-04
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
# Command: nftban metrics enable [--backend prometheus|victoriametrics]
# ==============================================================================
nftban_metrics_enable() {
    local backend="prometheus"  # Default
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                backend="$2"
                shift 2
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
                # Try package manager first
                local pkg_installed=false
                if command -v apt-get &>/dev/null; then
                    if apt-get update -qq && apt-get install -y prometheus-node-exporter &>/dev/null; then
                        pkg_installed=true
                    fi
                elif command -v dnf &>/dev/null; then
                    # Try multiple package names (different distros use different names)
                    for pkg in golang-github-prometheus-node-exporter node_exporter prometheus-node-exporter node-exporter; do
                        if dnf install -y "$pkg" &>/dev/null; then
                            pkg_installed=true
                            break
                        fi
                    done
                fi

                # Fallback to binary installation if package not available
                if [ "$pkg_installed" = false ]; then
                    echo "    Package not available in repos, installing from GitHub..."
                    if [ -f "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" ]; then
                        bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --yes || echo "    ⚠️  Node Exporter install failed (non-critical)"
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
        echo "To enable: nftban metrics enable --backend $backend"
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
        help|--help|-h)
            echo "Usage: nftban metrics {enable|disable|status|set-backend} [options]"
            echo ""
            echo "Commands:"
            echo "  enable          Enable metrics collection"
            echo "  disable         Disable metrics collection"
            echo "  status          Show metrics services status"
            echo "  set-backend     Update configured backend (prometheus|victoriametrics)"
            echo ""
            echo "Options for 'enable':"
            echo "  --backend prometheus        Use Prometheus (default)"
            echo "  --backend victoriametrics   Use VictoriaMetrics (recommended)"
            echo ""
            echo "Backend Comparison:"
            echo ""
            echo "  Prometheus (Default):"
            echo "    • Industry standard, widely adopted"
            echo "    • 30 days retention"
            echo "    • Higher resource usage"
            echo "    • Web UI: http://\${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
            echo ""
            echo "  VictoriaMetrics (Recommended):"
            echo "    • 10x better compression (90% less disk)"
            echo "    • 20x faster queries"
            echo "    • 12 months retention"
            echo "    • Lower RAM/CPU usage"
            echo "    • 100% Prometheus-compatible"
            echo "    • Web UI: http://\${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
            echo ""
            echo "What Gets Enabled:"
            echo "  • Metrics database (Prometheus or VictoriaMetrics)"
            echo "  • Node Exporter (system metrics: CPU, RAM, disk)"
            echo "  • NFTBan Exporter (firewall metrics: bans, rules, traffic)"
            echo ""
            echo "Examples:"
            echo "  nftban metrics enable                              # Use Prometheus"
            echo "  nftban metrics enable --backend victoriametrics    # Use VictoriaMetrics"
            echo "  nftban metrics status                              # Check status"
            echo "  nftban metrics set-backend victoriametrics         # Switch to VictoriaMetrics"
            echo "  nftban metrics disable                             # Stop collection"
            echo ""
            echo "Grafana Integration:"
            echo "  Both backends work with Grafana using Prometheus datasource"
            echo "  No dashboard changes needed when switching backends"
            echo ""
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo "Usage: nftban metrics {enable|disable|status|set-backend|help}"
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_cmd_metrics
