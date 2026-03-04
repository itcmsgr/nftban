#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="install_vmagent"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Install vmagent for remote metrics submission"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# vmagent version (update periodically)
VMAGENT_VERSION="${VMAGENT_VERSION:-1.96.0}"

# Paths
VMAGENT_BIN="/usr/local/bin/vmagent"
VMAGENT_CONFIG_DIR="/etc/victoriametrics"
VMAGENT_DATA_DIR="/var/lib/vmagent"
VMAGENT_USER="nftban"
VMAGENT_GROUP="nftban"

# Defaults
VMAGENT_LISTEN_ADDR="${NFTBAN_METRICS_VMAGENT_ADDR:-localhost:8429}"

# Load nftban config if available
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
fi
# v1.19.0: Source .local override (user customizations survive package updates)
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "[OK] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# =============================================================================
# INSTALLATION
# =============================================================================

install_vmagent_binary() {
    # Install vmagent from official GitHub releases
    #
    # Returns: 0 on success, 1 on failure

    local verbose="${1:-true}"

    # Check if already installed
    if [[ -f "$VMAGENT_BIN" ]]; then
        local installed_version
        installed_version=$("$VMAGENT_BIN" -version 2>&1 | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown")
        [[ "$verbose" == "true" ]] && log_info "vmagent already installed: $installed_version"
        return 0
    fi

    [[ "$verbose" == "true" ]] && log_info "Installing vmagent v${VMAGENT_VERSION}..."

    local tmp_dir
    tmp_dir="$(mktemp -d -t vmagent-XXXXXX)"
    cd "$tmp_dir" || return 1

    # Detect architecture
    local arch="amd64"
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="arm" ;;
    esac

    # Download
    local url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/vmutils-linux-${arch}-v${VMAGENT_VERSION}.tar.gz"
    [[ "$verbose" == "true" ]] && log_info "Downloading from: $url"

    if ! wget -q "$url" -O vmutils.tar.gz; then
        log_error "Failed to download vmagent"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Extract
    tar xzf vmutils.tar.gz

    # Install binary
    if [[ -f "vmagent-prod" ]]; then
        install -m 0755 vmagent-prod "$VMAGENT_BIN"
    else
        log_error "vmagent-prod not found in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Cleanup
    cd / || return 1
    rm -rf "$tmp_dir"

    [[ "$verbose" == "true" ]] && log_success "vmagent installed to $VMAGENT_BIN"
    return 0
}

# =============================================================================
# CONFIGURATION TEMPLATES
# =============================================================================

# =============================================================================
# IDEMPOTENT CONFIG MANAGEMENT
# =============================================================================

_vmagent_backup_config() {
    # Backup existing config if it exists and is not managed by nftban
    local config_file="$1"

    if [[ -f "$config_file" ]]; then
        # Check if already managed by nftban
        local backup_file
        if grep -q "^# Managed by nftban" "$config_file" 2>/dev/null; then
            # Already managed - create timestamped backup
            backup_file="${config_file}.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$config_file" "$backup_file"
            log_info "Backed up existing config to: $backup_file"
        else
            # Not managed - warn and backup
            backup_file="${config_file}.pre-nftban.$(date +%Y%m%d_%H%M%S)"
            cp "$config_file" "$backup_file"
            log_info "WARNING: Existing config not managed by nftban"
            log_info "Backed up to: $backup_file"
        fi
    fi
}

_vmagent_write_config() {
    # Atomically write config with proper header
    local config_file="$1"
    local content="$2"

    local tmp_file="${config_file}.tmp.$$"

    # Write with managed header
    {
        echo "# Managed by nftban"
        echo "# Do not edit manually - changes will be overwritten"
        echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "#"
        echo "$content"
    } > "$tmp_file"

    # Atomic move
    mv "$tmp_file" "$config_file"
    chmod 640 "$config_file"
    chown root:nftban "$config_file" 2>/dev/null || true
}

create_vmagent_config_user_backend() {
    # Create vmagent config for user's own backend (Case A)
    #
    # Args:
    #   $1 - remote_write URL
    #   $2 - token file path (optional)
    #   $3 - external labels (optional, format: key1=value1,key2=value2)

    local remote_url="$1"
    local token_file="${2:-}"
    local external_labels="${3:-}"

    mkdir -p "$VMAGENT_CONFIG_DIR"
    # Create data directory with correct ownership (no -R needed)
    install -d -o "$VMAGENT_USER" -g "$VMAGENT_GROUP" -m 0755 "$VMAGENT_DATA_DIR"

    # Backup existing config
    _vmagent_backup_config "$VMAGENT_CONFIG_DIR/vmagent.yml"

    # Build external labels section
    local labels_yaml=""
    if [[ -n "$external_labels" ]]; then
        labels_yaml="global:
  external_labels:"
        IFS=',' read -ra PAIRS <<< "$external_labels"
        for pair in "${PAIRS[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            labels_yaml+="
    $key: \"$value\""
        done
        labels_yaml+="
"
    fi

    # Build auth section
    local auth_yaml=""
    if [[ -n "$token_file" ]] && [[ -f "$token_file" ]]; then
        auth_yaml="    bearer_token_file: $token_file"
    fi

    # Build config content
    local config_content
    config_content=$(cat << EOF
# vmagent Configuration - User Backend (Case A)
# Remote Write Target: User's own Grafana/Prometheus/VictoriaMetrics

${labels_yaml}
scrape_configs:
  # NFTBan metrics via node_exporter textfile collector
  - job_name: 'nftban'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*'
        action: keep

  # Node exporter system metrics (optional, for full system visibility)
  - job_name: 'node'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_.*'
        action: keep

remoteWrite:
  - url: "${remote_url}"
${auth_yaml}
    queue_config:
      max_samples_per_send: 10000
      batch_send_deadline: 10s
      capacity: 100000
      max_shards: 10
EOF
)

    _vmagent_write_config "$VMAGENT_CONFIG_DIR/vmagent.yml" "$config_content"

    log_success "Created vmagent config: $VMAGENT_CONFIG_DIR/vmagent.yml"
    log_info "Remote write target: $remote_url"
}

create_vmagent_config_pro() {
    # Create vmagent config for NFTBan Pro (Case B)
    #
    # Args:
    #   $1 - server_id
    #   $2 - hostname (optional, auto-detected)

    local server_id="$1"
    local hostname="${2:-$(hostname -f 2>/dev/null || hostname)}"

    # Use configurable URLs (from nftban.conf or defaults)
    local pro_url="${NFTBAN_PRO_REMOTE_WRITE_URL:-https://pro.nftban.com/api/v1/write}"
    local token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"

    mkdir -p "$VMAGENT_CONFIG_DIR"
    # Create data directory with correct ownership (no -R needed)
    install -d -o "$VMAGENT_USER" -g "$VMAGENT_GROUP" -m 0755 "$VMAGENT_DATA_DIR"

    # Backup existing config
    _vmagent_backup_config "$VMAGENT_CONFIG_DIR/vmagent.yml"

    # Build config content
    local config_content
    config_content=$(cat << EOF
# vmagent Configuration - NFTBan Pro (Case B)
# Remote Write Target: pro.nftban.com
# Server ID: ${server_id}

global:
  external_labels:
    server_id: "${server_id}"
    hostname: "${hostname}"
    service: "nftban"

scrape_configs:
  # NFTBan metrics via node_exporter textfile collector
  - job_name: 'nftban'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*'
        action: keep

  # Watchdog metrics
  - job_name: 'nftban-watchdog'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_watchdog_.*'
        action: keep

  # Node exporter system metrics (for Pro benchmarking)
  - job_name: 'node'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_(cpu|memory|disk|filesystem|network)_.*'
        action: keep

remoteWrite:
  - url: "${pro_url}"
    bearer_token_file: ${token_file}
    queue_config:
      max_samples_per_send: 10000
      batch_send_deadline: 10s
      capacity: 100000
      max_shards: 10
EOF
)

    _vmagent_write_config "$VMAGENT_CONFIG_DIR/vmagent.yml" "$config_content"

    log_success "Created vmagent config for NFTBan Pro"
    log_info "Server ID: $server_id"
    log_info "Remote write target: $pro_url"
}

# =============================================================================
# MODE C2: vmagent -> Local VictoriaMetrics
# =============================================================================

create_vmagent_config_local_vm() {
    # Create vmagent config for local VictoriaMetrics (Mode C2)
    # VictoriaMetrics integration - Mode C2
    #
    # Args:
    #   $1 - local VM URL (default: http://localhost:8428/api/v1/write)

    local vm_url="${1:-http://localhost:8428/api/v1/write}"

    mkdir -p "$VMAGENT_CONFIG_DIR"
    # Create data directory with correct ownership (no -R needed)
    install -d -o "$VMAGENT_USER" -g "$VMAGENT_GROUP" -m 0755 "$VMAGENT_DATA_DIR"

    # Backup existing config
    _vmagent_backup_config "$VMAGENT_CONFIG_DIR/vmagent.yml"

    # Build config content
    local config_content
    config_content=$(cat << EOF
# vmagent Configuration - Mode C2: Local VictoriaMetrics
# VictoriaMetrics integration - Mode C2
# Storage Target: Local VictoriaMetrics at ${vm_url}
#
# Architecture:
#   Node Exporter -> vmagent -> VictoriaMetrics (local)

global:
  external_labels:
    service: "nftban"
    hostname: "$(hostname -f 2>/dev/null || hostname)"

scrape_configs:
  # NFTBan metrics via node_exporter textfile collector
  - job_name: 'nftban'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*'
        action: keep

  # Node exporter system metrics
  - job_name: 'node'
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'node_.*'
        action: keep

remoteWrite:
  - url: "${vm_url}"
    queue_config:
      max_samples_per_send: 10000
      batch_send_deadline: 10s
      capacity: 100000
      max_shards: 10
EOF
)

    _vmagent_write_config "$VMAGENT_CONFIG_DIR/vmagent.yml" "$config_content"

    log_success "Created vmagent config for local VictoriaMetrics (Mode C2)"
    log_info "Storage target: $vm_url"
}

# =============================================================================
# SYSTEMD SERVICE
# =============================================================================

create_vmagent_systemd_service() {
    # Create systemd service for vmagent

    cat > /etc/systemd/system/vmagent.service << EOF
[Unit]
Description=VictoriaMetrics vmagent
Documentation=https://docs.victoriametrics.com/vmagent.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VMAGENT_USER}
Group=${VMAGENT_GROUP}
ExecStart=${VMAGENT_BIN} \\
    -promscrape.config=${VMAGENT_CONFIG_DIR}/vmagent.yml \\
    -remoteWrite.tmpDataPath=${VMAGENT_DATA_DIR} \\
    -httpListenAddr=${VMAGENT_LISTEN_ADDR}

Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${VMAGENT_DATA_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_success "Created systemd service: vmagent.service"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

start_vmagent() {
    # Start and enable vmagent service

    systemctl enable vmagent 2>/dev/null || true
    systemctl restart vmagent

    if systemctl is-active vmagent &>/dev/null; then
        log_success "vmagent started successfully"
        return 0
    else
        log_error "vmagent failed to start"
        return 1
    fi
}

stop_vmagent() {
    # Stop and disable vmagent service

    systemctl stop vmagent 2>/dev/null || true
    systemctl disable vmagent 2>/dev/null || true
    log_info "vmagent stopped"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_vmagent() {
    # Validate vmagent is running and healthy
    #
    # Returns: 0 if healthy, 1 if unhealthy

    # Check service is running
    if ! systemctl is-active vmagent &>/dev/null; then
        log_error "vmagent service not running"
        return 1
    fi

    # Check HTTP endpoint responds
    if ! curl -sf --connect-timeout 5 "http://${VMAGENT_LISTEN_ADDR}/-/ready" &>/dev/null; then
        log_error "vmagent HTTP endpoint not responding"
        return 1
    fi

    # Check targets are being scraped
    local targets_response
    targets_response=$(curl -sf "http://${VMAGENT_LISTEN_ADDR}/targets" 2>/dev/null || echo "")

    if [[ -z "$targets_response" ]]; then
        log_error "vmagent targets endpoint not responding"
        return 1
    fi

    log_success "vmagent is healthy"
    return 0
}

# =============================================================================
# MAIN (for standalone execution)
# =============================================================================

main() {
    local action="${1:-install}"
    shift || true

    case "$action" in
        install)
            install_vmagent_binary true
            create_vmagent_systemd_service
            ;;
        config-user)
            # Args: remote_url [token_file] [external_labels]
            local url="${1:-}"
            local token="${2:-}"
            local labels="${3:-}"

            if [[ -z "$url" ]]; then
                log_error "Usage: $0 config-user <remote_write_url> [token_file] [labels]"
                exit 1
            fi

            create_vmagent_config_user_backend "$url" "$token" "$labels"
            ;;
        config-pro)
            # Args: server_id [hostname]
            local server_id="${1:-}"
            local hostname="${2:-}"

            if [[ -z "$server_id" ]]; then
                log_error "Usage: $0 config-pro <server_id> [hostname]"
                exit 1
            fi

            create_vmagent_config_pro "$server_id" "$hostname"
            ;;
        start)
            start_vmagent
            ;;
        stop)
            stop_vmagent
            ;;
        validate)
            validate_vmagent
            ;;
        *)
            echo "Usage: $0 {install|config-user|config-pro|start|stop|validate}"
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
