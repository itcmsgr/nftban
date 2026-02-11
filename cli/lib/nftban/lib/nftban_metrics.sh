#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Shared helper functions for metrics stack (Prometheus or VictoriaMetrics)"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,curl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="prometheus.service,node_exporter.service,nftban-unified-exporter.timer"
# meta:inventory.network="localhost:9090,localhost:9100,localhost:8428"
# meta:inventory.privileges="root"

set -Eeuo pipefail

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
fi

# Load distro helpers if not already loaded
if ! command -v nftban_distro_get_service &>/dev/null; then
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh"
    fi
fi

# ==============================================================================
# Shared: Start Prometheus Stack (used by both gui and metrics commands)
# ==============================================================================
nftban_metrics_start_stack() {
    # Start Node Exporter, Prometheus, and NFTBan metrics exporter
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"  # Show output by default

    # Create textfile collector directory with correct ownership (no -R needed)
    install -d -o nftban -g nftban -m 0755 /var/lib/node_exporter/textfile_collector 2>/dev/null || \
        mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector 2>/dev/null || true

    # Start Node Exporter (get service name from distro config, fallback to common names)
    local node_exporter_started=false
    local node_exporter_service=""

    # First try distro config
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "")

    # Build list of services to try (distro config first, then common fallbacks)
    local services_to_try=()
    [[ -n "$node_exporter_service" ]] && services_to_try+=("$node_exporter_service")
    services_to_try+=("prometheus-node-exporter" "node_exporter" "node-exporter")

    for svc in "${services_to_try[@]}"; do
        # Check if service exists (avoid pipefail issues with grep)
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            node_exporter_service="$svc"
            systemctl enable "$svc" &>/dev/null || true
            systemctl restart "$svc" &>/dev/null || true
            sleep 1  # Give service time to start
            if systemctl is-active "$svc" &>/dev/null; then
                node_exporter_started=true
                break
            fi
        fi
    done

    if [[ "$node_exporter_started" == "true" ]]; then
        [[ "$verbose" == "true" ]] && echo "  ✓ Node Exporter running ($node_exporter_service)"
    else
        [[ "$verbose" == "true" ]] && echo "  ❌ Node Exporter service not found"
        return 1
    fi

    # Start Prometheus (get service name from distro config)
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")

    # Check if service exists (avoid pipefail issues with grep)
    if systemctl list-unit-files "${prometheus_service}.service" &>/dev/null; then
        systemctl enable "$prometheus_service" &>/dev/null || true
        systemctl restart "$prometheus_service" &>/dev/null || true
        sleep 1  # Give service time to start
        if systemctl is-active "$prometheus_service" &>/dev/null; then
            [[ "$verbose" == "true" ]] && echo "  ✓ Prometheus running ($prometheus_service)"
        else
            [[ "$verbose" == "true" ]] && echo "  ❌ Prometheus failed to start"
            return 1
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  ❌ Prometheus service not found"
        return 1
    fi

    # Start NFTBan metrics exporter timer
    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    local metrics_svc="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    # Use systemctl list-unit-files with specific unit name (avoids pipefail issues with grep)
    if systemctl list-unit-files "$metrics_timer" &>/dev/null; then
        # Enable and start timer (use start, not restart for timers)
        systemctl enable "$metrics_timer" 2>/dev/null || true
        systemctl start "$metrics_timer" 2>/dev/null || true
        # Trigger one immediate collection
        systemctl start "$metrics_svc" 2>/dev/null || true
        if systemctl is-active --quiet "$metrics_timer" 2>/dev/null; then
            [[ "$verbose" == "true" ]] && echo "  ✓ Metrics collection timer enabled (60s interval)"
        else
            [[ "$verbose" == "true" ]] && echo "  ⚠️  Timer failed to start - check: systemctl status $metrics_timer"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  ⚠️  $metrics_timer not installed"
    fi

    return 0
}

# ==============================================================================
# Shared: Stop Prometheus Stack
# ==============================================================================
nftban_metrics_stop_stack() {
    # Stop Node Exporter, Prometheus, and NFTBan metrics exporter
    # Returns: 0 on success

    local verbose="${1:-true}"  # Show output by default

    # Stop NFTBan metrics exporter
    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    local metrics_svc="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    if systemctl list-unit-files 2>/dev/null | grep -q "$metrics_timer"; then
        systemctl stop "$metrics_timer" &>/dev/null || true
        systemctl stop "$metrics_svc" &>/dev/null || true
        systemctl disable "$metrics_timer" &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ NFTBan metrics exporter stopped"
    fi

    # Stop Prometheus
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    if systemctl list-unit-files "${prometheus_service}.service"; then
        systemctl stop "$prometheus_service" &>/dev/null || true
        systemctl disable "$prometheus_service" &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ Prometheus stopped"
    fi

    # Stop Node Exporter
    local node_exporter_service
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")
    if systemctl list-unit-files "${node_exporter_service}.service"; then
        systemctl stop "$node_exporter_service" &>/dev/null || true
        systemctl disable "$node_exporter_service" &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ Node Exporter stopped"
    fi

    return 0
}

# ==============================================================================
# Shared: Check if metrics stack is running
# ==============================================================================
nftban_metrics_is_running() {
    # Check if all 3 services are running
    # Returns: 0 if all running, 1 if any stopped

    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")

    local node_exporter_service
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")

    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    if systemctl is-active "$prometheus_service" &>/dev/null && \
       systemctl is-active "$node_exporter_service" &>/dev/null && \
       systemctl is-active "$metrics_timer" &>/dev/null; then
        return 0  # All running
    else
        return 1  # Some stopped
    fi
}

# ==============================================================================
# Shared: Check if metrics dependencies are installed
# ==============================================================================
nftban_metrics_check_deps() {
    # Check if Prometheus and Node Exporter are installed
    # Returns: 0 if all present, 1 if missing
    # Sets global: NFTBAN_METRICS_MISSING array with missing packages

    NFTBAN_METRICS_MISSING=()

    # Check Prometheus
    if ! command -v prometheus &>/dev/null; then
        NFTBAN_METRICS_MISSING+=("prometheus")
    fi

    # Check Node Exporter
    local node_exporter_service
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")
    if ! systemctl list-unit-files "${node_exporter_service}.service"; then
        NFTBAN_METRICS_MISSING+=("node-exporter")
    fi

    if [[ ${#NFTBAN_METRICS_MISSING[@]} -gt 0 ]]; then
        return 1  # Missing packages
    else
        return 0  # All present
    fi
}

# ==============================================================================
# Shared: Install metrics dependencies
# ==============================================================================
nftban_metrics_install_deps() {
    # Install Prometheus and Node Exporter based on distro
    # Auto-detects if packages available in repos, falls back to binaries
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"

    # Detect distro
    local distro_id distro_version
    distro_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    distro_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

    [[ "$verbose" == "true" ]] && echo "  📦 Installing dependencies..."

    case "$distro_id" in
        debian|ubuntu)
            # Debian/Ubuntu have Prometheus in repos
            apt-get update -qq &>/dev/null || true
            if apt-get install -y prometheus prometheus-node-exporter &>/dev/null; then
                [[ "$verbose" == "true" ]] && echo "  ✓ Dependencies installed from APT repositories"
                return 0
            else
                [[ "$verbose" == "true" ]] && echo "  ⚠️  APT install failed, trying binary installation..."
                nftban_metrics_install_from_binaries "$verbose"
                return $?
            fi
            ;;
        centos|rhel|rocky|almalinux)
            # RHEL-family: Check if Prometheus available in repos
            if dnf search prometheus 2>/dev/null | grep -q "^prometheus\."; then
                # Available in repos (Fedora or custom repos)
                if dnf install -y prometheus golang-github-prometheus-node-exporter &>/dev/null || \
                   dnf install -y prometheus node-exporter &>/dev/null; then
                    [[ "$verbose" == "true" ]] && echo "  ✓ Dependencies installed from DNF repositories"
                    return 0
                fi
            fi

            # Not available in repos - install from binaries
            [[ "$verbose" == "true" ]] && echo "  ℹ️  Prometheus not available in $distro_id $distro_version repositories"
            [[ "$verbose" == "true" ]] && echo "  📥 Installing from official GitHub releases..."
            nftban_metrics_install_from_binaries "$verbose"
            return $?
            ;;
        fedora)
            # Fedora has Prometheus in repos
            if dnf install -y prometheus golang-github-prometheus-node-exporter &>/dev/null; then
                [[ "$verbose" == "true" ]] && echo "  ✓ Dependencies installed from DNF repositories"
                return 0
            else
                [[ "$verbose" == "true" ]] && echo "  ⚠️  DNF install failed, trying binary installation..."
                nftban_metrics_install_from_binaries "$verbose"
                return $?
            fi
            ;;
        *)
            [[ "$verbose" == "true" ]] && echo "  ⚠️  Unknown distribution: $distro_id"
            [[ "$verbose" == "true" ]] && echo "  📥 Attempting binary installation..."
            nftban_metrics_install_from_binaries "$verbose"
            return $?
            ;;
    esac
}

# ==============================================================================
# Shared: Install Prometheus from official binaries
# ==============================================================================
nftban_metrics_install_from_binaries() {
    # Install Prometheus and Node Exporter from official GitHub releases
    # Used when packages not available in distribution repositories
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"

    # Latest stable versions (update periodically)
    local prom_ver="2.54.1"
    local node_ver="1.8.2"
    local tmp_dir="/tmp/nftban-metrics-install-$$"

    [[ "$verbose" == "true" ]] && echo ""
    [[ "$verbose" == "true" ]] && echo "  📦 Binary Installation Details:"
    [[ "$verbose" == "true" ]] && echo "     Prometheus: v${prom_ver}"
    [[ "$verbose" == "true" ]] && echo "     Node Exporter: v${node_ver}"
    [[ "$verbose" == "true" ]] && echo ""

    # Create temp directory
    mkdir -p "$tmp_dir"
    cd "$tmp_dir" || return 1

    # Download Prometheus
    [[ "$verbose" == "true" ]] && echo "  ⬇️  Downloading Prometheus..."
    if ! wget -q "https://github.com/prometheus/prometheus/releases/download/v${prom_ver}/prometheus-${prom_ver}.linux-amd64.tar.gz"; then
        [[ "$verbose" == "true" ]] && echo "  ❌ Failed to download Prometheus"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Download Node Exporter
    [[ "$verbose" == "true" ]] && echo "  ⬇️  Downloading Node Exporter..."
    if ! wget -q "https://github.com/prometheus/node_exporter/releases/download/v${node_ver}/node_exporter-${node_ver}.linux-amd64.tar.gz"; then
        [[ "$verbose" == "true" ]] && echo "  ❌ Failed to download Node Exporter"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Extract archives
    [[ "$verbose" == "true" ]] && echo "  📦 Extracting archives..."
    tar xzf "prometheus-${prom_ver}.linux-amd64.tar.gz" || return 1
    tar xzf "node_exporter-${node_ver}.linux-amd64.tar.gz" || return 1

    # Install Prometheus binaries
    [[ "$verbose" == "true" ]] && echo "  📂 Installing binaries..."
    install -m 0755 "prometheus-${prom_ver}.linux-amd64/prometheus" /usr/local/bin/prometheus
    install -m 0755 "prometheus-${prom_ver}.linux-amd64/promtool" /usr/local/bin/promtool
    install -m 0755 "node_exporter-${node_ver}.linux-amd64/node_exporter" /usr/local/bin/node_exporter

    # Create Prometheus user if doesn't exist
    if ! id prometheus &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true
    fi

    # Create directories with correct ownership (no -R needed for fresh dirs)
    install -d -o prometheus -g prometheus -m 0755 /etc/prometheus 2>/dev/null || mkdir -p /etc/prometheus
    install -d -o prometheus -g prometheus -m 0755 /var/lib/prometheus 2>/dev/null || mkdir -p /var/lib/prometheus
    install -d -o nftban -g nftban -m 0755 /var/lib/node_exporter/textfile_collector 2>/dev/null || \
        mkdir -p /var/lib/node_exporter/textfile_collector

    chown prometheus:prometheus /etc/prometheus /var/lib/prometheus 2>/dev/null || true
    chown nftban:nftban /var/lib/node_exporter /var/lib/node_exporter/textfile_collector 2>/dev/null || true

    # Create minimal Prometheus config if doesn't exist
    if [[ ! -f /etc/prometheus/prometheus.yml ]]; then
        cat > /etc/prometheus/prometheus.yml << 'PROMCONFIG'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*'
        action: keep
PROMCONFIG
        chown prometheus:prometheus /etc/prometheus/prometheus.yml
    fi

    # Create systemd services
    nftban_metrics_create_systemd_services "$verbose"

    # Cleanup
    cd /
    rm -rf "$tmp_dir"

    [[ "$verbose" == "true" ]] && echo "  ✅ Binary installation complete"
    [[ "$verbose" == "true" ]] && echo ""
    [[ "$verbose" == "true" ]] && echo "  ℹ️  Installed to /usr/local/bin/"
    [[ "$verbose" == "true" ]] && echo "     prometheus --version: $(prometheus --version 2>&1 | head -1)"
    [[ "$verbose" == "true" ]] && echo "     node_exporter --version: $(node_exporter --version 2>&1 | head -1)"

    return 0
}

# ==============================================================================
# Shared: Create systemd services for binary installation
# ==============================================================================
nftban_metrics_create_systemd_services() {
    # Create systemd service files for manually installed binaries
    # Called by nftban_metrics_install_from_binaries()

    local verbose="${1:-true}"

    [[ "$verbose" == "true" ]] && echo "  ⚙️  Creating systemd services..."

    # Prometheus service
    cat > /etc/systemd/system/prometheus.service << 'PROMSERVICE'
[Unit]
Description=Prometheus Time Series Database
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090

Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
PROMSERVICE

    # Node Exporter service (HLD: upstream name is node_exporter.service)
    cat > /etc/systemd/system/node_exporter.service << 'NODESERVICE'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nftban
Group=nftban
ExecStart=/usr/local/bin/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
NODESERVICE

    # Reload systemd
    systemctl daemon-reload

    [[ "$verbose" == "true" ]] && echo "  ✓ Systemd services created"
}

# ==============================================================================
# VictoriaMetrics: Start Stack
# ==============================================================================
nftban_metrics_start_stack_victoriametrics() {
    # Start Node Exporter, VictoriaMetrics, and NFTBan metrics exporter
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"  # Show output by default

    # Create textfile collector directory with correct ownership (no -R needed)
    install -d -o nftban -g nftban -m 0755 /var/lib/node_exporter/textfile_collector 2>/dev/null || \
        mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector 2>/dev/null || true

    # Start Node Exporter (get service name from distro config, fallback to common names)
    local node_exporter_started=false
    local node_exporter_service=""

    # First try distro config
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "")

    # Build list of services to try (distro config first, then common fallbacks)
    local services_to_try=()
    [[ -n "$node_exporter_service" ]] && services_to_try+=("$node_exporter_service")
    services_to_try+=("prometheus-node-exporter" "node_exporter" "node-exporter")

    for svc in "${services_to_try[@]}"; do
        # Check if service exists (avoid pipefail issues with grep)
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            node_exporter_service="$svc"
            systemctl enable "$svc" &>/dev/null || true
            systemctl restart "$svc" &>/dev/null || true
            sleep 1  # Give service time to start
            if systemctl is-active "$svc" &>/dev/null; then
                node_exporter_started=true
                break
            fi
        fi
    done

    if [[ "$node_exporter_started" == "true" ]]; then
        [[ "$verbose" == "true" ]] && echo "  ✓ Node Exporter running ($node_exporter_service)"
    else
        [[ "$verbose" == "true" ]] && echo "  ❌ Node Exporter service not found"
        return 1
    fi

    # Start VictoriaMetrics
    if systemctl list-unit-files "victoriametrics.service" &>/dev/null; then
        systemctl enable victoriametrics &>/dev/null || true
        systemctl restart victoriametrics &>/dev/null || true
        if systemctl is-active victoriametrics &>/dev/null; then
            [[ "$verbose" == "true" ]] && echo "  ✓ VictoriaMetrics running"
        else
            [[ "$verbose" == "true" ]] && echo "  ❌ VictoriaMetrics failed to start"
            return 1
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  ❌ VictoriaMetrics service not found"
        return 1
    fi

    # Start NFTBan metrics exporter timer
    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    local metrics_svc="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    # Use systemctl list-unit-files with specific unit name (avoids pipefail issues with grep)
    if systemctl list-unit-files "$metrics_timer" &>/dev/null; then
        # Enable and start timer (use start, not restart for timers)
        systemctl enable "$metrics_timer" 2>/dev/null || true
        systemctl start "$metrics_timer" 2>/dev/null || true
        # Trigger one immediate collection
        systemctl start "$metrics_svc" 2>/dev/null || true
        if systemctl is-active --quiet "$metrics_timer" 2>/dev/null; then
            [[ "$verbose" == "true" ]] && echo "  ✓ Metrics collection timer enabled (60s interval)"
        else
            [[ "$verbose" == "true" ]] && echo "  ⚠️  Timer failed to start - check: systemctl status $metrics_timer"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  ⚠️  $metrics_timer not installed"
    fi

    return 0
}

# ==============================================================================
# VictoriaMetrics: Stop Stack
# ==============================================================================
nftban_metrics_stop_stack_victoriametrics() {
    # Stop VictoriaMetrics, Node Exporter, and NFTBan metrics exporter
    # Returns: 0 on success

    local verbose="${1:-true}"  # Show output by default

    # Stop NFTBan metrics exporter
    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    local metrics_svc="${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}"
    if systemctl list-unit-files 2>/dev/null | grep -q "$metrics_timer"; then
        systemctl stop "$metrics_timer" &>/dev/null || true
        systemctl stop "$metrics_svc" &>/dev/null || true
        systemctl disable "$metrics_timer" &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ NFTBan metrics exporter stopped"
    fi

    # Stop VictoriaMetrics
    if systemctl list-unit-files "victoriametrics.service" &>/dev/null; then
        systemctl stop victoriametrics &>/dev/null || true
        systemctl disable victoriametrics &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ VictoriaMetrics stopped"
    fi

    # Stop Node Exporter
    local node_exporter_service
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")
    if systemctl list-unit-files "${node_exporter_service}.service"; then
        systemctl stop "$node_exporter_service" &>/dev/null || true
        systemctl disable "$node_exporter_service" &>/dev/null || true
        [[ "$verbose" == "true" ]] && echo "  ✓ Node Exporter stopped"
    fi

    return 0
}

# ==============================================================================
# VictoriaMetrics: Check if stack is running
# ==============================================================================
nftban_metrics_is_running_victoriametrics() {
    # Check if all 3 services are running
    # Returns: 0 if all running, 1 if any stopped

    local node_exporter_service
    node_exporter_service=$(nftban_distro_get_service node_exporter 2>/dev/null || echo "prometheus-node-exporter")

    local metrics_timer="${NFTBAN_TIMER_METRICS_EXPORTER:-nftban-unified-exporter.timer}"
    if systemctl is-active victoriametrics &>/dev/null && \
       systemctl is-active "$node_exporter_service" &>/dev/null && \
       systemctl is-active "$metrics_timer" &>/dev/null; then
        return 0  # All running
    else
        return 1  # Some stopped
    fi
}

# ==============================================================================
# VictoriaMetrics: Install VictoriaMetrics binary
# ==============================================================================
nftban_metrics_install_victoriametrics() {
    # Install VictoriaMetrics from official binary releases
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"

    [[ "$verbose" == "true" ]] && echo "  📥 Installing VictoriaMetrics..."

    # Check if already installed
    if [[ -f /usr/local/bin/victoria-metrics-prod ]]; then
        [[ "$verbose" == "true" ]] && echo "  ✓ VictoriaMetrics already installed"
        return 0
    fi

    # Run installation script
    if [[ -f "${NFTBAN_LIB_DIR}/setup/install_victoriametrics.sh" ]]; then
        if bash "${NFTBAN_LIB_DIR}/setup/install_victoriametrics.sh"; then
            [[ "$verbose" == "true" ]] && echo "  ✅ VictoriaMetrics installed successfully"
            return 0
        else
            [[ "$verbose" == "true" ]] && echo "  ❌ VictoriaMetrics installation failed"
            return 1
        fi
    else
        [[ "$verbose" == "true" ]] && echo "  ❌ VictoriaMetrics installation script not found"
        [[ "$verbose" == "true" ]] && echo "     Expected: ${NFTBAN_LIB_DIR}/setup/install_victoriametrics.sh"
        return 1
    fi
}

# ==============================================================================
# VictoriaMetrics: Check health
# ==============================================================================
nftban_metrics_check_victoriametrics_health() {
    # Check if VictoriaMetrics is responding
    # Returns: 0 if healthy, 1 if not

    local vm_url="${NFTBAN_VICTORIAMETRICS_URL:-http://127.0.0.1:8428}"

    if curl -sf "${vm_url}/health" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Export all functions
export -f nftban_metrics_start_stack
export -f nftban_metrics_stop_stack
export -f nftban_metrics_is_running
export -f nftban_metrics_check_deps
export -f nftban_metrics_install_deps
export -f nftban_metrics_install_from_binaries
export -f nftban_metrics_create_systemd_services
export -f nftban_metrics_start_stack_victoriametrics
export -f nftban_metrics_stop_stack_victoriametrics
export -f nftban_metrics_is_running_victoriametrics
export -f nftban_metrics_install_victoriametrics
export -f nftban_metrics_check_victoriametrics_health
