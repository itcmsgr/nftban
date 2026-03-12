#!/usr/bin/env bash
# shellcheck disable=SC2120  # Function designed to accept optional args
# SPDX-License-Identifier: MPL-2.0
# meta:name="install_victoriametrics"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Install and configure VictoriaMetrics from official GitHub releases"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Source shared utilities (provides print_status, print_error, print_warn, print_info, check_root)
# shellcheck source=../lib/setup_utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/setup_utils.sh"

# VictoriaMetrics configuration
readonly VM_VERSION="${VM_VERSION:-v1.99.0}"
readonly VM_USER="victoriametrics"
readonly VM_GROUP="victoriametrics"
readonly VM_DIR="/etc/victoriametrics"
readonly VM_DATA_DIR="/var/lib/victoriametrics"
readonly VM_BIN="/usr/local/bin/victoria-metrics-prod"

detect_arch() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

install_via_binary() {
    local version="${1:-$VM_VERSION}"
    local arch
    arch=$(detect_arch)

    print_info "Installing VictoriaMetrics ${version} for ${arch}..."

    # Create user/group if doesn't exist
    if ! id "$VM_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$VM_USER"
        print_status "Created victoriametrics user"
    fi

    # Download and extract
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/victoriametrics-install.XXXXXX)
    cd "$tmp_dir" || return 1

    local url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${version}/victoria-metrics-linux-${arch}-${version}.tar.gz"

    print_info "Downloading from: $url"
    curl -sL "$url" -o victoriametrics.tar.gz || {
        print_error "Download failed"
        return 1
    }

    tar xzf victoriametrics.tar.gz

    # Install binary
    cp victoria-metrics-prod /usr/local/bin/
    chmod +x /usr/local/bin/victoria-metrics-prod

    # Create directories with correct ownership (no -R needed for fresh directories)
    install -d -o "$VM_USER" -g "$VM_GROUP" -m 0755 "$VM_DIR"
    install -d -o "$VM_USER" -g "$VM_GROUP" -m 0755 "$VM_DATA_DIR"

    # Cleanup
    cd / || return 1
    rm -rf "$tmp_dir"

    print_status "VictoriaMetrics binary installed"
}

create_systemd_service() {
    print_info "Creating systemd service..."

    # Check if enterprise key is configured
    local license_line=""
    local env_line=""

    if [[ -f "/etc/nftban/metrics/enterprise.key" ]] && [[ -s "/etc/nftban/metrics/enterprise.key" ]]; then
        # Enterprise mode: include license file configuration
        print_info "Enterprise key detected - configuring enterprise mode"
        env_line="EnvironmentFile=-/etc/nftban/metrics/enterprise.env"
        license_line="  -license.file=\${VM_LICENSE_FILE}"
    else
        # Community mode: no license configuration
        print_info "No enterprise key - configuring community edition"
        env_line="# Enterprise mode not configured (community edition)"
        license_line=""
    fi

    cat > /etc/systemd/system/victoriametrics.service << EOF
[Unit]
Description=VictoriaMetrics - High-Performance Time Series Database
Documentation=https://docs.victoriametrics.com/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=victoriametrics
Group=victoriametrics

# Enterprise key support (HLD Section 7.4)
${env_line}

ExecStart=/usr/local/bin/victoria-metrics-prod \\
  -storageDataPath=/var/lib/victoriametrics \\
  -retentionPeriod=2 \\
  -httpListenAddr=127.0.0.1:8428 \\
  -promscrape.config=/etc/victoriametrics/scrape.yml${license_line:+ \\
${license_line}}

SyslogIdentifier=victoriametrics
Restart=always
RestartSec=5

# Security hardening
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
ReadWritePaths=/var/lib/victoriametrics

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_status "Systemd service created"
}

configure_victoriametrics() {
    print_info "Configuring VictoriaMetrics for NFTBan..."

    # Backup existing config
    if [[ -f "$VM_DIR/scrape.yml" ]]; then
        cp "$VM_DIR/scrape.yml" "$VM_DIR/scrape.yml.backup"
    fi

    # Create scrape configuration (VictoriaMetrics format - no evaluation_interval)
    cat > "$VM_DIR/scrape.yml" << 'EOF'
global:
  scrape_interval: 60s

scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      # Keep NFTBan metrics and essential node_exporter metrics
      - source_labels: [__name__]
        regex: '(nftban_.*|node_(cpu|memory|disk|network).*)'
        action: keep
EOF

    chown "$VM_USER:$VM_GROUP" "$VM_DIR/scrape.yml"
    print_status "VictoriaMetrics configured for NFTBan"
}

main() {
    print_info "NFTBan VictoriaMetrics Installation"
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi

    # Check if already installed
    if [[ -f "$VM_BIN" ]]; then
        local current_version
        current_version=$($VM_BIN -version 2>&1 | grep -oP 'victoria-metrics-\d{8}-.*' | head -1 || echo "unknown")
        print_info "VictoriaMetrics already installed: $current_version"

        read -p "Reinstall? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi

    # Install binary
    install_via_binary

    # Create systemd service
    create_systemd_service

    # Configure
    configure_victoriametrics

    # Enable and start
    systemctl enable victoriametrics
    systemctl start victoriametrics

    # Wait and check
    sleep 3
    if systemctl is-active --quiet victoriametrics; then
        print_status "VictoriaMetrics is running"
        print_info "Web UI: http://127.0.0.1:8428/vmui"
        print_info "API: http://127.0.0.1:8428"
        print_info "Config: $VM_DIR/scrape.yml"
        print_info "Data: $VM_DATA_DIR"
        print_info "Retention: 12 months"
    else
        print_error "VictoriaMetrics failed to start"
        systemctl status victoriametrics
        exit 1
    fi

    echo ""
    print_status "VictoriaMetrics installation complete!"
    echo ""
    print_info "Next steps:"
    echo "  1. Ensure node_exporter is running: systemctl start prometheus-node-exporter"
    echo "  2. Enable NFTBan metrics: nftban metrics enable --backend victoriametrics"
    echo "  3. Access UI: http://127.0.0.1:8428/vmui"
    echo ""
}

main "$@"
