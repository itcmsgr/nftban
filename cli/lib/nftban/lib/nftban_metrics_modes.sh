#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics_modes" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Metrics mode handlers for different agent/storage combinations"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Prevent double-sourcing
[[ -n "${_NFTBAN_METRICS_MODES_LOADED:-}" ]] && return 0
_NFTBAN_METRICS_MODES_LOADED=1

# Bootstrap paths
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"

# =============================================================================
# CASE A: Remote submission to user's own backend
# =============================================================================
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
        echo "Error: Remote write URL required"
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
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" || return 1
        if ! install_vmagent_binary true; then
            echo "Failed to install vmagent"
            return 1
        fi
    else
        echo "vmagent installation script not found"
        return 1
    fi

    # Step 2: Ensure node_exporter is running (for metrics source)
    echo ""
    echo "Step 2/4: Ensuring Node Exporter is running..."
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            echo "  Node Exporter already running ($svc)"
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
    systemctl enable --now nftban-unified-exporter.timer &>/dev/null || true
    systemctl start nftban-unified-exporter.service &>/dev/null || true
    echo "  NFTBan metrics exporter enabled"

    # Step 3: Configure vmagent for user's backend
    echo ""
    echo "Step 3/4: Configuring vmagent for remote_write..."
    create_vmagent_config_user_backend "$remote_url" "$token_file" "$external_labels"

    # Step 4: Start vmagent
    echo ""
    echo "Step 4/4: Starting vmagent..."
    create_vmagent_systemd_service
    if ! start_vmagent; then
        echo "Failed to start vmagent"
        return 1
    fi

    # Validate pipeline
    echo ""
    echo "Validating metrics pipeline..."
    sleep 2  # Give vmagent time to start

    nftban_print_pipeline_report

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Remote Metrics Submission Enabled"
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

# =============================================================================
# CASE B: Remote submission to NFTBan Pro
# =============================================================================
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
    echo "  Server ID: $server_id"

    # Step 2: Check token exists
    echo ""
    echo "Step 2/6: Checking Pro token..."
    local token_file="${NFTBAN_PRO_TOKEN_FILE:-${NFTBAN_CONFIG_DIR}/pro.token}"

    if [[ ! -f "$token_file" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Pro Token Required"
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
    echo "  Token file exists: $token_file"

    # Step 3: Validate license
    echo ""
    echo "Step 3/6: Validating Pro subscription..."
    if nftban_pro_check_license; then
        echo "  Subscription valid"
    else
        echo "  Could not validate subscription (may work offline)"
        echo "      Will retry validation later via license timer"
    fi

    # Step 4: Install vmagent
    echo ""
    echo "Step 4/6: Installing vmagent..."
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" || return 1
        if ! install_vmagent_binary true; then
            echo "Failed to install vmagent"
            return 1
        fi
    else
        echo "vmagent installation script not found"
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
    systemctl enable --now nftban-unified-exporter.timer &>/dev/null || true
    systemctl start nftban-unified-exporter.service &>/dev/null || true

    # Step 5: Configure vmagent for Pro
    echo ""
    echo "Step 5/6: Configuring vmagent for NFTBan Pro..."
    create_vmagent_config_pro "$server_id" "$(hostname -f 2>/dev/null || hostname)"
    create_vmagent_systemd_service

    if ! start_vmagent; then
        echo "Failed to start vmagent"
        return 1
    fi

    # Step 6: Collect and submit inventory
    echo ""
    echo "Step 6/6: Collecting server inventory..."
    local inventory_hash
    inventory_hash=$(nftban_pro_save_inventory)
    echo "  Inventory collected (hash: ${inventory_hash:0:16}...)"

    # Try to submit inventory (don't fail if endpoint not reachable)
    echo "  Submitting inventory to Pro..."
    if nftban_pro_submit_inventory true; then
        echo "  Inventory submitted"
    else
        echo "  Inventory submission deferred (will retry via timer)"
    fi

    # Enable license timer
    echo ""
    echo "Enabling Pro license timer..."
    systemctl enable nftban-pro-license.timer &>/dev/null || true
    systemctl start nftban-pro-license.timer &>/dev/null || true
    echo "  License timer enabled (checks every 6 hours)"

    # Validate pipeline
    echo ""
    echo "Validating metrics pipeline..."
    sleep 2

    nftban_print_pipeline_report

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Pro Enabled Successfully"
    echo ""
    echo "   Server ID:         $server_id"
    echo "   Remote Write:      https://pro.nftban.com/api/v1/write"
    echo "   Inventory:         /var/lib/nftban/pro/inventory.json"
    echo ""
    echo "   vmagent Status:    http://localhost:8429/"
    echo "   vmagent Targets:   http://localhost:8429/targets"
    echo ""
    echo "   Pro Features:"
    echo "   - Metrics streaming to pro.nftban.com"
    echo "   - Server inventory and benchmarking"
    echo "   - Centralized recommendations (planned for v2.x)"
    echo "   - Centralized dashboard at https://pro.nftban.com"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# Mode A: Prometheus all-in-one (scrape + store locally)
# =============================================================================
_metrics_enable_mode_a() {
    local retention="${1:-60d}"

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
       systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "Prometheus metrics already enabled"
        echo ""
        echo "Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
        echo "Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
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

    # Step 3: Update config
    echo ""
    echo "Step 3/3: Updating configuration..."
    _set_metrics_backend "prometheus"
    _set_metrics_agent_storage "prometheus" "prometheus-local"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Mode A Enabled Successfully!"
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

# =============================================================================
# Mode B: Agent-only (vmagent -> remote_write)
# =============================================================================
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

# =============================================================================
# Mode C1: Prometheus scrapes -> remote_write to local VictoriaMetrics
# =============================================================================
_metrics_enable_mode_c1() {
    local retention="${1:-60d}"

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
        echo "  Failed to install VictoriaMetrics"
        return 1
    fi

    # Step 2: Install Prometheus if not present
    echo ""
    echo "Step 2/5: Checking Prometheus dependencies..."
    if ! nftban_metrics_check_deps; then
        echo "  Missing: ${NFTBAN_METRICS_MISSING[*]}"
        if ! nftban_metrics_install_deps; then
            return 1
        fi
    else
        echo "  All dependencies present"
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
        echo "  Failed to start VictoriaMetrics"
        return 1
    fi
    echo "  VictoriaMetrics running"

    # Step 5: Start Prometheus with remote_write
    echo ""
    echo "Step 5/5: Starting Prometheus (agent mode)..."
    if ! nftban_metrics_start_stack; then
        echo "  Failed to start Prometheus stack"
        return 1
    fi

    # Update config
    _set_metrics_backend "victoriametrics"
    _set_metrics_agent_storage "prometheus" "vm-local"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Mode C1 Enabled Successfully!"
    echo ""
    echo "Prometheus (scraper): http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    echo "VictoriaMetrics UI:   http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
    echo "Node Exporter:        http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "NFTBan Metrics:       /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "Retention:            ${retention}"
    echo ""
    echo "VictoriaMetrics Benefits:"
    echo "   - 10x better compression"
    echo "   - Faster queries"
    echo "   - Lower resource usage"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# Mode C2: vmagent scrapes -> writes to local VictoriaMetrics
# =============================================================================
_metrics_enable_mode_c2() {
    local retention="${1:-60d}"

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
        echo "  Failed to install VictoriaMetrics"
        return 1
    fi

    # Step 2: Install vmagent
    echo ""
    echo "Step 2/5: Installing vmagent..."
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/setup/install_vmagent.sh" || return 1
        if ! install_vmagent_binary true; then
            echo "  Failed to install vmagent"
            return 1
        fi
    else
        echo "  vmagent installation script not found"
        return 1
    fi

    # Step 3: Ensure node_exporter is running
    echo ""
    echo "Step 3/5: Ensuring Node Exporter is running..."
    local node_exporter_running=false
    for svc in node-exporter node_exporter prometheus-node-exporter; do
        if systemctl is-active "$svc" &>/dev/null; then
            node_exporter_running=true
            echo "  Node Exporter already running ($svc)"
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
    systemctl enable --now nftban-unified-exporter.timer &>/dev/null || true
    systemctl start nftban-unified-exporter.service &>/dev/null || true
    echo "  NFTBan metrics exporter enabled"

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
        echo "  Failed to start VictoriaMetrics"
        return 1
    fi
    echo "  VictoriaMetrics running"

    # Start vmagent
    if ! start_vmagent; then
        echo "  Failed to start vmagent"
        return 1
    fi
    echo "  vmagent running"

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
    echo "Mode C2 Enabled Successfully!"
    echo ""
    echo "VictoriaMetrics UI:   http://${NFTBAN_METRICS_VICTORIA_ADDR}/vmui"
    echo "vmagent Status:       http://localhost:8429/"
    echo "vmagent Targets:      http://localhost:8429/targets"
    echo "Node Exporter:        http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "NFTBan Metrics:       /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "Retention:            ${retention}"
    echo ""
    echo "VictoriaMetrics Benefits:"
    echo "   - 10x better compression"
    echo "   - Faster queries"
    echo "   - Lower resource usage"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# Exporters-only mode (external agent)
# =============================================================================
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
            echo "  Node Exporter already running ($svc)"
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
    systemctl enable --now nftban-unified-exporter.timer &>/dev/null || true
    systemctl start nftban-unified-exporter.service &>/dev/null || true
    echo "  NFTBan metrics exporter enabled"

    _set_metrics_agent_storage "none" "remote"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Exporters Enabled Successfully!"
    echo ""
    echo "Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo ""
    echo "Configure your external agent to scrape localhost:9100"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}
