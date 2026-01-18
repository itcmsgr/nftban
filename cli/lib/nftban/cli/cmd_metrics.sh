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

# Load metrics helpers (conflict detection, config helpers, validation)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh"
fi

# Load metrics modes (mode A/B/C1/C2/Pro handlers)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics_modes.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics_modes.sh"
fi

# ==============================================================================
# Command: nftban metrics enable [options]
# ==============================================================================
# New Agent/Storage Model (VictoriaMetrics integration):
#   --agent prometheus|vmagent|none       Collection agent
#   --storage prometheus-local|vm-local|remote  Storage target
#   --remote-write-url URL                Remote endpoint (required if storage=remote)
#   --retention DURATION                  Retention period (default: 60d)
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
    local retention="60d"       # Retention period for local storage
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
                echo "Unsupported agent/storage combination: ${agent}/${storage}"
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
        echo "Invalid backend: $backend"
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
        echo "Cannot enable Prometheus while VictoriaMetrics is running."
        echo ""
        return 1
    elif [[ "$backend" == "victoriametrics" ]] && [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]]; then
        # shellcheck disable=SC2034  # Reserved for conflict resolution
        conflict_detected=true
        _show_conflict_warning "victoriametrics"
        echo "Cannot enable VictoriaMetrics while Prometheus is running."
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
                echo "Prometheus metrics already enabled"
                echo ""
                echo "Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
                echo "Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
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

            # Show dual install warning if applicable
            if [[ "$dual_install" == "true" ]]; then
                _show_dual_install_warning "prometheus"
            fi
            ;;

        victoriametrics)
            # Check if already enabled
            if systemctl is-active victoriametrics &>/dev/null && \
               systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
                echo "VictoriaMetrics already enabled"
                echo ""
                echo "VictoriaMetrics:  http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
                echo "Metrics:          http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
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
                echo "  Failed to install VictoriaMetrics"
                return 1
            fi

            # Install node_exporter if not present
            local node_exporter_service
            node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")
            if ! systemctl list-unit-files 2>/dev/null | grep -q "${node_exporter_service}.service"; then
                echo "  Installing Node Exporter..."

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
                        bash "${NFTBAN_LIB_DIR}/setup/install_node_exporter.sh" --method binary || echo "    Node Exporter install failed (non-critical)"
                    fi
                fi
            fi

            # Step 2: Start metrics stack
            echo ""
            echo "Step 2/3: Starting VictoriaMetrics stack..."

            if ! nftban_metrics_start_stack_victoriametrics true; then
                echo "  Failed to start VictoriaMetrics stack"
                return 1
            fi

            # Update config
            _set_metrics_backend "victoriametrics"

            # Final output
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "VictoriaMetrics Enabled Successfully!"
            echo ""
            echo "VictoriaMetrics UI:  http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
            echo "API Endpoint:        http://${NFTBAN_METRICS_VICTORIA_ADDR}"
            echo "Node Exporter:       http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
            echo "NFTBan Metrics:      /var/lib/node_exporter/textfile_collector/nftban.prom"
            echo "Collection:          Every 60 seconds"
            echo "Retention:           12 months (vs Prometheus 30 days)"
            echo ""
            echo "VictoriaMetrics Benefits:"
            echo "   - 10x better compression (90% less disk)"
            echo "   - 20x faster queries"
            echo "   - Lower RAM/CPU usage"
            echo "   - Prometheus-compatible (same queries work)"
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
        echo "Metrics already disabled"
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
            echo "  - Prometheus:       Installed, Running"
        else
            echo "  - Prometheus:       Installed (stopped)"
        fi
    else
        echo "  - Prometheus:       Not installed"
    fi

    if [[ "$CONFLICT_VICTORIAMETRICS_INSTALLED" == "true" ]]; then
        if [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
            echo "  - VictoriaMetrics:  Installed, Running"
        else
            echo "  - VictoriaMetrics:  Installed (stopped)"
        fi
    else
        echo "  - VictoriaMetrics:  Not installed"
    fi
    echo ""

    # Warn if both are running
    if [[ "$CONFLICT_PROMETHEUS_RUNNING" == "true" ]] && [[ "$CONFLICT_VICTORIAMETRICS_RUNNING" == "true" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "WARNING: Both backends are running!"
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
        echo "CONFIGURATION MISMATCH DETECTED"
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
                echo "  Prometheus:        Running"
                echo "   URL:               http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
            else
                echo "  Prometheus:        Stopped"
                all_running=false
            fi
            ;;

        victoriametrics)
            # Check VictoriaMetrics
            if systemctl is-active victoriametrics &>/dev/null; then
                echo "  VictoriaMetrics:   Running"
                echo "   UI:                http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
                echo "   API:               http://${NFTBAN_METRICS_VICTORIA_ADDR}"

                # Check health endpoint
                if curl -sf "http://${NFTBAN_METRICS_VICTORIA_ADDR}/health" &>/dev/null; then
                    echo "   Health:            OK"
                fi
            else
                echo "  VictoriaMetrics:   Stopped"
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
        echo "  Node Exporter:     Running"
        echo "   URL:               http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    else
        echo "  Node Exporter:     Stopped"
        all_running=false
    fi

    echo ""

    # Check NFTBan metrics exporter (common for both)
    if systemctl is-active nftban-metrics-exporter.timer &>/dev/null; then
        echo "  NFTBan Exporter:   Running"
        local last_run
        last_run=$(systemctl show nftban-metrics-exporter.timer -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
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
                    echo "  No key provided"
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
                echo "Error: Backend required"
                echo ""
                echo "Usage: nftban metrics set-backend <backend>"
                echo ""
                echo "Available backends:"
                echo "  - prometheus"
                echo "  - victoriametrics"
                echo ""
                return 1
            fi

            if [[ "$new_backend" != "prometheus" ]] && [[ "$new_backend" != "victoriametrics" ]]; then
                echo "Invalid backend: $new_backend"
                echo "   Valid options: prometheus, victoriametrics"
                return 1
            fi

            # Update configuration
            _set_metrics_backend "$new_backend"

            echo "Metrics backend updated to: $new_backend"
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
