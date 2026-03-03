#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="install_prometheus"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Install and configure Prometheus for NFTBan metrics"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# LIBRARY LOADING
# =============================================================================

# Determine library path
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# Source common setup utilities
if [[ -f "${NFTBAN_LIB_DIR}/lib/setup_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/setup_utils.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/setup_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/setup_utils.sh"
else
    # Fallback: define functions inline if library not found
    echo "[WARN] setup_utils.sh not found, using inline definitions" >&2
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly NC='\033[0m'
    print_status() { echo -e "${GREEN}[✓]${NC} $1" >&2; }
    print_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
    print_info() { echo -e "${YELLOW}[i]${NC} $1" >&2; }
    detect_distro() { [[ -f /etc/os-release ]] && { . /etc/os-release; echo "${ID}"; } || echo "unknown"; }
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Prometheus configuration
readonly PROM_VERSION="${PROM_VERSION:-2.48.0}"
readonly PROM_USER="prometheus"
readonly PROM_GROUP="prometheus"
readonly PROM_DIR="/etc/prometheus"
readonly PROM_DATA_DIR="/var/lib/prometheus"
readonly PROM_BIN="/usr/local/bin/prometheus"
readonly PROMTOOL_BIN="/usr/local/bin/promtool"

install_via_package() {
    local distro="$1"
    
    case "$distro" in
        fedora|centos|rhel|rocky|almalinux)
            print_info "Installing Prometheus via dnf..."
            dnf install -y prometheus2 || {
                print_error "Package installation failed"
                return 1
            }
            ;;
        debian|ubuntu)
            print_info "Installing Prometheus via apt..."
            apt-get update
            apt-get install -y prometheus || {
                print_error "Package installation failed"
                return 1
            }
            ;;
        *)
            print_error "Package installation not available for $distro"
            return 1
            ;;
    esac
    
    print_status "Prometheus installed via package manager"
}

# shellcheck disable=SC2120  # Function designed to accept optional version argument
install_via_binary() {
    local version="${1:-$PROM_VERSION}"
    
    print_info "Installing Prometheus ${version} from binary..."
    
    # Create user/group
    if ! id "$PROM_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PROM_USER"
        print_status "Created prometheus user"
    fi
    
    # Download and extract
    local tmp_dir="/tmp/prometheus-install"
    mkdir -p "$tmp_dir"
    cd "$tmp_dir" || return 1

    local arch="amd64"
    local url="https://github.com/prometheus/prometheus/releases/download/v${version}/prometheus-${version}.linux-${arch}.tar.gz"
    
    print_info "Downloading from: $url"
    curl -sL "$url" -o prometheus.tar.gz || {
        print_error "Download failed"
        return 1
    }
    
    tar xzf prometheus.tar.gz
    cd "prometheus-${version}.linux-${arch}" || return 1

    # Install binaries
    install -m 0755 prometheus "${PROM_BIN}"
    install -m 0755 promtool "${PROMTOOL_BIN}"
    
    # Create directories
    mkdir -p "$PROM_DIR" "$PROM_DIR/rules" "$PROM_DIR/rules.d"
    # Create data directory with correct ownership (no -R, fresh directory)
    install -d -o "$PROM_USER" -g "$PROM_GROUP" -m 0755 "$PROM_DATA_DIR"

    # Install console templates and libraries
    cp -r consoles console_libraries "$PROM_DIR/"

    # Set ownership on top-level directories (avoid recursive -R)
    chown "$PROM_USER:$PROM_GROUP" "$PROM_DIR" "$PROM_DATA_DIR"
    # Set ownership on copied subdirectories explicitly
    chown "$PROM_USER:$PROM_GROUP" "$PROM_DIR/consoles" "$PROM_DIR/console_libraries" 2>/dev/null || true
    find "$PROM_DIR/consoles" "$PROM_DIR/console_libraries" -maxdepth 1 -exec chown "$PROM_USER:$PROM_GROUP" {} \; 2>/dev/null || true
    
    # Cleanup
    cd / || return 1
    rm -rf "$tmp_dir"

    print_status "Prometheus binary installed"
}

create_systemd_service() {
    print_info "Creating systemd service..."

    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=${PROM_BIN} \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus/ \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.listen-address=127.0.0.1:9090 \\
  --storage.tsdb.retention.time=60d

SyslogIdentifier=prometheus
Restart=always
RestartSec=5

# Security
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
ReadWritePaths=/var/lib/prometheus

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    print_status "Systemd service created"
}

configure_prometheus() {
    print_info "Configuring Prometheus for NFTBan..."
    
    # Backup existing config
    if [[ -f "$PROM_DIR/prometheus.yml" ]]; then
        cp "$PROM_DIR/prometheus.yml" "$PROM_DIR/prometheus.yml.backup"
    fi
    
    # Install NFTBan configuration
    if [[ -f /usr/share/doc/nftban/metrics/prometheus.yml.example ]]; then
        cp /usr/share/doc/nftban/metrics/prometheus.yml.example "$PROM_DIR/prometheus.yml"
    else
        # Create basic config
        cat > "$PROM_DIR/prometheus.yml" << 'EOF'
global:
  scrape_interval: 60s
  evaluation_interval: 60s

scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'nftban_.*'
        action: keep
EOF
    fi
    
    chown "$PROM_USER:$PROM_GROUP" "$PROM_DIR/prometheus.yml"
    print_status "Prometheus configured for NFTBan"
}

main() {
    print_info "NFTBan Prometheus Installation"
    echo ""
    
    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
    
    # Detect distro
    local distro
    distro=$(detect_distro)
    print_info "Detected distribution: $distro"
    
    # Try package install first, fall back to binary
    if ! install_via_package "$distro" 2>/dev/null; then
        print_info "Package not available, using binary installation"
        install_via_binary
        create_systemd_service
    fi
    
    # Configure
    configure_prometheus
    
    # Enable and start
    systemctl enable prometheus
    systemctl start prometheus
    
    # Wait and check
    sleep 3
    if systemctl is-active --quiet prometheus; then
        print_status "Prometheus is running"
        print_info "Web UI: http://127.0.0.1:9090"
        print_info "Config: $PROM_DIR/prometheus.yml"
        print_info "Data: $PROM_DATA_DIR"
    else
        print_error "Prometheus failed to start"
        systemctl status prometheus
        exit 1
    fi
    
    echo ""
    print_status "Prometheus installation complete!"
}

main "$@"
