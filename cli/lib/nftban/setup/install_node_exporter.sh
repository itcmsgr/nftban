#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="install_node_exporter"
# meta:type="setup"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Install and configure Node Exporter with textfile collector for NFTBan metrics"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly NODE_EXPORTER_VERSION="1.7.0"
readonly NODE_EXPORTER_PORT=9100
readonly TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector"

# =============================================================================
# FUNCTIONS
# =============================================================================

# Print informational message
info() {
    echo "[INFO] $*" >&2
}

# Print error message
error() {
    echo "[ERROR] $*" >&2
}

# Print success message
success() {
    echo "[SUCCESS] $*" >&2
}

# Print usage
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Install and configure Prometheus Node Exporter for NFTBan metrics.

OPTIONS:
    --method <method>       Installation method: package or binary (auto-detect)
    --version <version>     Node Exporter version for binary install (default: $NODE_EXPORTER_VERSION)
    --help                  Show this help message

INSTALLATION METHODS:
    package                 Use distribution package manager (recommended)
    binary                  Download and install official binary

EXAMPLES:
    # Auto-detect and install
    $SCRIPT_NAME

    # Use package manager
    $SCRIPT_NAME --method package

    # Use binary installation
    $SCRIPT_NAME --method binary --version 1.7.0

EOF
}

# Detect OS distribution
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        error "Cannot detect OS distribution"
        exit 1
    fi
}

# Check if Node Exporter is already installed
check_existing() {
    if systemctl is-active --quiet node_exporter || \
       systemctl is-active --quiet prometheus-node-exporter; then
        info "Node Exporter is already running"

        # Ask user if they want to reconfigure
        read -p "Reconfigure existing installation? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Exiting without changes"
            exit 0
        fi
    fi
}

# Install via package manager
install_package() {
    local distro="$1"

    info "Installing Node Exporter via package manager..."

    case "$distro" in
        fedora|rhel|centos|rocky|almalinux)
            # Check if EPEL is needed (RHEL derivatives)
            if [[ "$distro" != "fedora" ]]; then
                if ! rpm -q epel-release &>/dev/null; then
                    info "Installing EPEL repository..."
                    dnf install -y epel-release
                fi
            fi

            # Install Node Exporter
            info "Installing golang-github-prometheus-node-exporter..."
            dnf install -y golang-github-prometheus-node-exporter
            ;;

        debian|ubuntu)
            info "Updating package list..."
            apt-get update

            info "Installing prometheus-node-exporter..."
            apt-get install -y prometheus-node-exporter
            ;;

        *)
            error "Unsupported distribution: $distro"
            error "Please use --method binary for manual installation"
            exit 1
            ;;
    esac

    success "Node Exporter package installed"
}

# Install from binary
install_binary() {
    local version="$1"

    info "Installing Node Exporter from official binary..."
    info "Version: $version"

    # Download
    local download_url="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.linux-amd64.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d -t node-exporter-XXXXXX)"
    cd "$tmpdir" || return 1

    info "Downloading Node Exporter..."
    if command -v wget &>/dev/null; then
        wget -q "$download_url"
    elif command -v curl &>/dev/null; then
        curl -sL -O "$download_url"
    else
        error "Neither wget nor curl is available"
        exit 1
    fi

    # Extract
    info "Extracting archive..."
    tar xzf "node_exporter-${version}.linux-amd64.tar.gz"

    # Install binary
    info "Installing binary to /usr/local/bin..."
    cp "node_exporter-${version}.linux-amd64/node_exporter" /usr/local/bin/
    chmod 755 /usr/local/bin/node_exporter

    # Create user if doesn't exist
    if ! id node_exporter &>/dev/null; then
        info "Creating node_exporter user..."
        useradd --no-create-home --shell /usr/sbin/nologin node_exporter
    fi

    # Create systemd service
    info "Creating systemd service..."
    cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter

ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=on-failure
RestartSec=5s

# Security hardening
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
ReadOnlyPaths=/var/lib/node_exporter/textfile_collector

# Kernel protections
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

# Resource limits
CPUQuota=20%
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

    # Cleanup
    cd / || return 1
    rm -rf "$tmpdir"

    success "Node Exporter binary installed"
}

# Configure textfile collector
configure_textfile_collector() {
    info "Configuring textfile collector..."

    # Create directory
    if [[ ! -d "$TEXTFILE_COLLECTOR_DIR" ]]; then
        info "Creating textfile collector directory..."
        mkdir -p "$TEXTFILE_COLLECTOR_DIR" || return 1
    fi

    # Set ownership to nftban user
    if id nftban &>/dev/null; then
        info "Setting ownership to nftban:nftban..."
        chown nftban:nftban "$TEXTFILE_COLLECTOR_DIR"
    else
        error "nftban user does not exist - run NFTBan installation first"
        error "Setting ownership to root for now..."
        chown root:root "$TEXTFILE_COLLECTOR_DIR"
    fi

    # Set permissions
    chmod 750 "$TEXTFILE_COLLECTOR_DIR"

    # Add node_exporter to nftban group
    if id nftban &>/dev/null && id node_exporter &>/dev/null; then
        info "Adding node_exporter to nftban group..."
        usermod -a -G nftban node_exporter
    fi

    success "Textfile collector configured"
}

# Configure Node Exporter service
configure_service() {
    info "Configuring Node Exporter service..."

    # Create systemd override directory
    mkdir -p /etc/systemd/system/node_exporter.service.d || return 1

    # Detect service name
    local service_name="node_exporter.service"
    if systemctl list-unit-files | grep -q prometheus-node-exporter.service; then
        service_name="prometheus-node-exporter.service"
        mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d || return 1
    fi

    # Create override configuration
    info "Creating systemd override for textfile collector..."
    cat > "/etc/systemd/system/${service_name}.d/textfile-collector.conf" <<EOF
[Service]
# Clear existing ExecStart
ExecStart=

# Set new ExecStart with textfile collector and localhost binding
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=127.0.0.1:${NODE_EXPORTER_PORT} \\
  --collector.textfile.directory=${TEXTFILE_COLLECTOR_DIR}
EOF

    # Create security hardening override
    info "Creating systemd security hardening override..."
    cat > "/etc/systemd/system/${service_name}.d/hardening.conf" <<'EOF'
[Service]
# Additional security hardening
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
PrivateDevices=yes

# Restrict capabilities
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# System call filtering
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
EOF

    # Reload systemd
    info "Reloading systemd..."
    systemctl daemon-reload

    success "Service configured"
}

# Enable and start service
enable_service() {
    local service_name="node_exporter.service"

    # Detect service name
    if systemctl list-unit-files | grep -q prometheus-node-exporter.service; then
        service_name="prometheus-node-exporter.service"
    fi

    info "Enabling and starting $service_name..."

    # Enable on boot
    systemctl enable "$service_name"

    # Start service
    systemctl restart "$service_name"

    # Wait for service to start
    sleep 2

    # Check status
    if systemctl is-active --quiet "$service_name"; then
        success "Node Exporter is running"
    else
        error "Node Exporter failed to start"
        error "Check logs: journalctl -u $service_name -n 50"
        exit 1
    fi
}

# Verify installation
verify_installation() {
    info "Verifying installation..."

    # Check service is running
    if ! systemctl is-active --quiet node_exporter && \
       ! systemctl is-active --quiet prometheus-node-exporter; then
        error "Node Exporter service is not running"
        return 1
    fi
    success "✓ Service is running"

    # Check localhost binding
    if netstat -tulnp 2>/dev/null | grep "$NODE_EXPORTER_PORT" | grep -q "127.0.0.1"; then
        success "✓ Bound to localhost only (secure)"
    else
        error "⚠ Not bound to localhost - security risk!"
    fi

    # Check metrics endpoint
    if curl -s "http://localhost:$NODE_EXPORTER_PORT/metrics" | grep -q "node_exporter_build_info"; then
        success "✓ Metrics endpoint is accessible"
    else
        error "✗ Metrics endpoint is not accessible"
        return 1
    fi

    # Check textfile collector
    if curl -s "http://localhost:$NODE_EXPORTER_PORT/metrics" | grep -q "node_textfile_scrape_error"; then
        success "✓ Textfile collector is enabled"
    else
        error "✗ Textfile collector is not enabled"
        return 1
    fi

    # Check directory permissions
    if [[ -d "$TEXTFILE_COLLECTOR_DIR" ]]; then
        success "✓ Textfile collector directory exists"
    else
        error "✗ Textfile collector directory missing"
        return 1
    fi

    success "✅ Installation verified successfully!"
}

# Print next steps
print_next_steps() {
    cat <<EOF

═══════════════════════════════════════════════════════════════
 Node Exporter Installation Complete!
═══════════════════════════════════════════════════════════════

📊 Metrics endpoint: http://localhost:9100/metrics
📁 Textfile collector: $TEXTFILE_COLLECTOR_DIR

Next Steps:

1. Deploy NFTBan unified exporter:
   sudo systemctl enable --now nftban-unified-exporter.timer

2. Verify metrics are being collected:
   curl -s http://localhost:9100/metrics | grep nftban_

3. Configure Prometheus to scrape metrics:
   Add job to /etc/prometheus/prometheus.yml

4. Configure firewall (if not already done):
   /usr/lib/nftban/setup/metrics-firewall-rules.sh --mode local-only

📚 Documentation:
   - Setup guide: /usr/share/doc/nftban/metrics/NODE_EXPORTER_SETUP.md
   - Security guide: https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide

═══════════════════════════════════════════════════════════════

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local method=""
    local version="$NODE_EXPORTER_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method)
                method="$2"
                shift 2
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi

    info "NFTBan Node Exporter Installation"
    info "════════════════════════════════════"

    # Check for existing installation
    check_existing

    # Detect OS
    local distro
    distro=$(detect_os)
    info "Detected OS: $distro"

    # Determine installation method
    if [[ -z "$method" ]]; then
        case "$distro" in
            fedora|rhel|centos|rocky|almalinux|debian|ubuntu)
                method="package"
                info "Using package installation (recommended)"
                ;;
            *)
                method="binary"
                info "Using binary installation (distro not supported by packages)"
                ;;
        esac
    fi

    # Install Node Exporter
    case "$method" in
        package)
            install_package "$distro"
            ;;
        binary)
            install_binary "$version"
            ;;
        *)
            error "Invalid installation method: $method"
            exit 1
            ;;
    esac

    # Configure textfile collector
    configure_textfile_collector

    # Configure service
    configure_service

    # Enable and start service
    enable_service

    # Verify installation
    verify_installation

    # Print next steps
    print_next_steps
}

# Run main function
main "$@"

# =============================================================================
# LICENSE
# =============================================================================
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
# =============================================================================
