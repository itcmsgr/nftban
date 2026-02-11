#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="install_suricata"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Install and configure Suricata IDS from source"
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
    detect_distro() { [[ -f /etc/os-release ]] && { . /etc/os-release; echo "${ID:-unknown}"; } || echo "unknown"; }
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Suricata configuration
readonly SURICATA_VERSION="${SURICATA_VERSION:-7.0.7}"
readonly SURICATA_URL="https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VERSION}.tar.gz"
readonly SURICATA_USER="suricata"
readonly SURICATA_GROUP="suricata"
readonly SURICATA_BIN="/usr/bin/suricata"
readonly SURICATA_CONF_DIR="/etc/suricata"
readonly SURICATA_DATA_DIR="/var/lib/suricata"
readonly SURICATA_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"  # NFTBan HFS
readonly SURICATA_RUN_DIR="/run/suricata"
readonly NFTBAN_TEMPLATES="${NFTBAN_SHARE_DIR:-/usr/share/nftban}/templates"

# Note: print_status, print_error, print_info, detect_distro are now
# loaded from setup_utils.sh library

detect_pkg_manager() {
    local distro="$1"

    case "$distro" in
        centos|rhel|fedora|rocky|alma*)
            echo "dnf"
            ;;
        debian|ubuntu)
            echo "apt"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

install_build_deps() {
    local pkg_mgr="$1"

    print_info "Installing build dependencies..."

    case "$pkg_mgr" in
        dnf)
            dnf install -y \
                gcc gcc-c++ make automake autoconf libtool \
                pcre2-devel libyaml-devel zlib-devel libcap-ng-devel \
                jansson-devel file-devel nss-devel libnetfilter_queue-devel \
                libnet-devel rust cargo python3-pip \
                libpcap-devel libnfnetlink-devel \
                ethtool || {
                print_error "Failed to install build dependencies"
                return 1
            }
            ;;
        apt)
            apt-get update
            apt-get install -y \
                build-essential autoconf automake libtool \
                libpcre2-dev libyaml-dev zlib1g-dev libcap-ng-dev \
                libjansson-dev libmagic-dev libnss3-dev libnetfilter-queue-dev \
                libnet1-dev rustc cargo python3-pip \
                libpcap-dev libnfnetlink-dev \
                ethtool || {
                print_error "Failed to install build dependencies"
                return 1
            }
            ;;
        *)
            print_error "Unknown package manager"
            return 1
            ;;
    esac

    print_status "Build dependencies installed"
}

download_suricata() {
    local version="$1"
    local tmp_dir="/tmp/suricata-install-$$"

    print_info "Downloading Suricata ${version}..."

    mkdir -p "$tmp_dir"
    cd "$tmp_dir"

    curl -L "$SURICATA_URL" -o suricata.tar.gz || {
        print_error "Download failed from $SURICATA_URL"
        return 1
    }

    tar xzf suricata.tar.gz || {
        print_error "Failed to extract tarball"
        return 1
    }

    cd "suricata-${version}"

    print_status "Suricata source downloaded and extracted"
    pwd
}

compile_suricata() {
    local source_dir="$1"

    print_info "Configuring Suricata..."
    cd "$source_dir"

    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --enable-nfqueue \
        --enable-af-packet || {
        print_error "Configuration failed"
        return 1
    }

    print_status "Configuration complete"

    print_info "Building Suricata (this may take several minutes)..."
    make -j"$(nproc)" || {
        print_error "Build failed"
        return 1
    }

    print_status "Build complete"
}

install_suricata() {
    local source_dir="$1"

    print_info "Installing Suricata binaries..."
    cd "$source_dir"

    make install || {
        print_error "Installation failed"
        return 1
    }

    print_status "Binaries installed"

    print_info "Installing default configuration..."
    make install-conf || {
        print_error "Config installation failed"
        return 1
    }

    print_status "Configuration files installed"
}

create_user() {
    print_info "Creating Suricata user and group..."

    # Create group if doesn't exist
    if ! getent group "$SURICATA_GROUP" >/dev/null 2>&1; then
        groupadd --system "$SURICATA_GROUP"
        print_status "Created group: $SURICATA_GROUP"
    else
        print_info "Group already exists: $SURICATA_GROUP"
    fi

    # Create user if doesn't exist
    if ! getent passwd "$SURICATA_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                --gid "$SURICATA_GROUP" "$SURICATA_USER"
        print_status "Created user: $SURICATA_USER"
    else
        print_info "User already exists: $SURICATA_USER"
    fi
}

create_directories() {
    print_info "Creating Suricata directories (NFTBan HFS)..."

    # NFTBan-controlled directories
    mkdir -p "$SURICATA_CONF_DIR"
    mkdir -p "$SURICATA_DATA_DIR/rules"
    # Create directories with correct ownership/permissions (no -R needed for fresh dirs)
    # Parent log directory (nftban-owned per FHS spec)
    install -d -o nftban -g nftban -m 0750 /var/log/nftban
    # Suricata-specific directories
    install -d -o "$SURICATA_USER" -g "$SURICATA_GROUP" -m 0750 "$SURICATA_DATA_DIR"
    install -d -o "$SURICATA_USER" -g "$SURICATA_GROUP" -m 0755 "$SURICATA_RUN_DIR"

    # EVE log directory: suricata:nftban with 770 permissions
    # Suricata writes logs, nftban reads them for IDS integration
    install -d -o "$SURICATA_USER" -g nftban -m 0770 "$SURICATA_LOG_DIR"

    # Add suricata user to nftban group (traverse /var/log/nftban/)
    if ! id -nG "$SURICATA_USER" 2>/dev/null | grep -qw nftban; then
        print_info "Adding suricata user to nftban group..."
        usermod -aG nftban "$SURICATA_USER" 2>/dev/null || true
        print_status "suricata user added to nftban group"
    fi

    # Config directory
    chmod 755 "$SURICATA_CONF_DIR"

    print_status "Directories created (logs under NFTBan control)"
}

create_systemd_service() {
    print_info "Creating systemd service with resource limits..."

    # Detect CPU count for affinity
    local cpu_count
    cpu_count=$(nproc)
    local cpu_limit="150%"  # Default: allow 1.5 cores

    if [[ $cpu_count -ge 4 ]]; then
        cpu_limit="200%"  # 4+ cores: allow 2 cores
    fi

    cat > /etc/systemd/system/suricata.service << EOF
[Unit]
Description=Suricata Intrusion Detection Service
Documentation=https://suricata.io/documentation/
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml --af-packet
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure
RestartSec=5

# Resource limits (optimized for NFTBan use-case)
MemoryMax=1G
MemoryHigh=800M
CPUQuota=$cpu_limit
CPUAccounting=yes
MemoryAccounting=yes

# Security hardening
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/log/nftban/suricata /var/lib/suricata /run/suricata
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_IPC_LOCK

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_status "Systemd service created (CPU: $cpu_limit, RAM: max 1GB)"
}

install_suricata_update() {
    print_info "Installing suricata-update..."

    pip3 install --upgrade suricata-update || {
        print_error "Failed to install suricata-update"
        return 1
    }

    print_status "suricata-update installed"
}

apply_sysctl_tuning() {
    print_info "Applying network buffer tuning..."

    # Increase network buffers for AF_PACKET capture
    cat > /etc/sysctl.d/90-suricata.conf << 'EOF'
# =============================================================================
# Suricata Network Buffer Tuning
# =============================================================================
# Increase receive buffer size for AF_PACKET capture
# Prevents packet drops under burst traffic

# Default: 212992 (208 KB)
# Optimized: 67108864 (64 MB)
net.core.rmem_max = 67108864

# Default: 1000
# Optimized: 10000 (handle burst better)
net.core.netdev_max_backlog = 10000

# Optional: Increase send buffer (if Suricata forwards traffic)
net.core.wmem_max = 67108864
EOF

    sysctl -p /etc/sysctl.d/90-suricata.conf >/dev/null 2>&1
    print_status "Network buffers increased (rmem_max: 64MB, backlog: 10k)"
}

tune_nic_for_ids() {
    print_info "Tuning NIC for optimal Suricata capture..."

    # Detect primary interface (used by Suricata)
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

    if [[ -z "$iface" ]]; then
        print_info "Could not detect primary interface, skipping NIC tuning"
        return 0
    fi

    print_info "Primary interface: $iface"

    # Check if ethtool is available
    if ! command -v ethtool &>/dev/null; then
        print_info "ethtool not installed, skipping NIC tuning"
        return 0
    fi

    # 1. Disable NIC offloads (CRITICAL for accurate DPI)
    # GRO/LRO merge packets - Suricata needs to see original packets
    # TSO/GSO segment packets - same issue
    print_info "Disabling NIC offloads for accurate packet inspection..."

    # Disable each individually (some may not be supported)
    ethtool -K "$iface" gro off 2>/dev/null || true   # Generic Receive Offload
    ethtool -K "$iface" lro off 2>/dev/null || true   # Large Receive Offload
    ethtool -K "$iface" gso off 2>/dev/null || true   # Generic Segmentation Offload
    ethtool -K "$iface" tso off 2>/dev/null || true   # TCP Segmentation Offload

    # 2. Increase NIC ring buffers (handle burst traffic)
    print_info "Increasing NIC ring buffers..."

    # Get max supported values
    local rx_max tx_max
    rx_max=$(ethtool -g "$iface" 2>/dev/null | grep -A4 "Pre-set maximums" | awk '/^RX:/ {print $2}')
    tx_max=$(ethtool -g "$iface" 2>/dev/null | grep -A4 "Pre-set maximums" | awk '/^TX:/ {print $2}')

    # Set to max (or 4096 if smaller)
    if [[ -n "$rx_max" ]]; then
        local rx_set=$((rx_max < 4096 ? rx_max : 4096))
        local tx_set=$((tx_max < 4096 ? tx_max : 4096))
        ethtool -G "$iface" rx "$rx_set" tx "$tx_set" 2>/dev/null || true
        print_info "Ring buffers set: RX=$rx_set TX=$tx_set"
    fi

    # 3. Create persistent script for reboot
    cat > /etc/NetworkManager/dispatcher.d/99-suricata-nic-tune << EOF
#!/bin/bash
# NFTBan: Suricata NIC tuning (applied on interface up)
# Location: /etc/NetworkManager/dispatcher.d/99-suricata-nic-tune

IFACE="\$1"
ACTION="\$2"

# Only apply for primary interface on "up" event
if [[ "\$ACTION" != "up" ]] || [[ "\$IFACE" != "$iface" ]]; then
    exit 0
fi

# Disable offloads for Suricata DPI accuracy
ethtool -K "\$IFACE" gro off lro off gso off tso off 2>/dev/null || true

# Increase ring buffers if supported
ethtool -G "\$IFACE" rx 4096 tx 4096 2>/dev/null || true

logger "NFTBan: Suricata NIC tuning applied to \$IFACE"
EOF
    chmod +x /etc/NetworkManager/dispatcher.d/99-suricata-nic-tune 2>/dev/null || true

    # Alternative: create systemd oneshot for non-NetworkManager systems
    cat > /etc/systemd/system/suricata-nic-tune.service << EOF
[Unit]
Description=Tune NIC for Suricata IDS
After=network.target
Before=suricata.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ethtool -K $iface gro off lro off gso off tso off 2>/dev/null || true; ethtool -G $iface rx 4096 tx 4096 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable suricata-nic-tune.service 2>/dev/null || true

    print_status "NIC tuning applied: offloads disabled, ring buffers increased"
    print_info "Tuning will persist across reboots"
}

configure_suricata() {
    print_info "Applying optimized Suricata configuration..."

    # 1. Apply Suricata configuration - prefer profile system, fallback to template
    local profiles_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/profiles"
    local default_profile="standard"

    if [[ -f "$profiles_dir/${default_profile}.yaml" ]]; then
        # Use profile system (preferred)
        cp "$profiles_dir/${default_profile}.yaml" "$SURICATA_CONF_DIR/suricata.yaml"
        print_status "Applied $default_profile profile from NFTBan profiles"
    elif [[ -f "$NFTBAN_TEMPLATES/suricata.yaml.optimized" ]]; then
        # Fallback to legacy template
        cp "$NFTBAN_TEMPLATES/suricata.yaml.optimized" "$SURICATA_CONF_DIR/suricata.yaml"
        print_status "Applied optimized suricata.yaml (legacy template)"
    else
        print_error "No Suricata config found in profiles ($profiles_dir) or templates ($NFTBAN_TEMPLATES)"
        return 1
    fi

    # 2. Copy rule enable/disable/filters configs from nftban config directory
    local etc_suricata_src="${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/config"

    if [[ -d "$etc_suricata_src" ]]; then
        for conf_file in enable.conf disable.conf filters.conf; do
            if [[ -f "$etc_suricata_src/$conf_file" ]]; then
                cp "$etc_suricata_src/$conf_file" "$SURICATA_CONF_DIR/"
            fi
        done
        # Copy README if exists
        [[ -f "$etc_suricata_src/README.md" ]] && cp "$etc_suricata_src/README.md" "$SURICATA_CONF_DIR/"

        # Copy .local.example files if they exist (users will create .local themselves)
        for example_file in "$etc_suricata_src"/*.local.example; do
            [[ -f "$example_file" ]] && cp "$example_file" "$SURICATA_CONF_DIR/"
        done

        print_status "Copied rule management configs (enable/disable/filters)"
    else
        print_info "Rule configs not found at $etc_suricata_src (optional)"
    fi

    # 3. Apply sysctl tuning
    apply_sysctl_tuning || return 1

    # 4. Apply NIC tuning (offloads + ring buffers)
    tune_nic_for_ids || return 1

    # 5. Update Suricata rules
    print_info "Updating Suricata rules with enable/disable configs..."
    if command -v suricata-update &>/dev/null; then
        cd "$SURICATA_CONF_DIR"
        suricata-update \
            --suricata "$SURICATA_BIN" \
            --suricata-conf "$SURICATA_CONF_DIR/suricata.yaml" || {
            print_error "suricata-update failed"
            return 1
        }
        print_status "Rules updated and optimized"
    else
        print_error "suricata-update not found"
        return 1
    fi

    # 5. Verify configuration
    print_info "Verifying Suricata configuration..."
    if "$SURICATA_BIN" -T -c "$SURICATA_CONF_DIR/suricata.yaml" >/dev/null 2>&1; then
        print_status "Configuration validated successfully"
    else
        print_error "Configuration validation failed"
        "$SURICATA_BIN" -T -c "$SURICATA_CONF_DIR/suricata.yaml"
        return 1
    fi

    print_status "Suricata fully optimized for NFTBan"
    echo ""
    print_info "Optimization Summary:"
    echo "  - AF_PACKET: ring-size 300k, cluster_flow"
    echo "  - HTTP body inspection: DISABLED (40-60% CPU savings)"
    echo "  - Flow timeouts: 60s (was 300s, RAM savings)"
    echo "  - Protocols: SSH, HTTP, DNS, TLS enabled"
    echo "  - Protocols: SMB, FTP, SMTP disabled by default"
    echo "  - Eve alerts: $SURICATA_LOG_DIR/eve-alerts.json"
    echo "  - Network buffers: rmem_max 64MB, backlog 10k"
    echo "  - NIC offloads: GRO/LRO/GSO/TSO disabled"
    echo "  - NIC ring buffers: Increased (up to 4096)"
    echo "  - Expected: 10-30% CPU, 300-600MB RAM"
}

cleanup() {
    local tmp_dir="$1"

    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
        print_info "Cleaning up temporary files..."
        cd /
        rm -rf "$tmp_dir"
        print_status "Cleanup complete"
    fi
}

main() {
    print_info "NFTBan Suricata Installation (From Source)"
    echo ""

    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi

    # Check if already installed
    if [[ -f "$SURICATA_BIN" ]]; then
        local current_version
        current_version=$("$SURICATA_BIN" --build-info 2>&1 | grep -oP 'Suricata version \K[0-9.]+' | head -1 || echo "unknown")
        print_info "Suricata already installed: $current_version"

        read -p "Reinstall? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi

    # Detect distribution
    local distro
    distro=$(detect_distro)
    print_info "Detected distribution: $distro"

    # Detect package manager
    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager "$distro")
    if [[ "$pkg_mgr" == "unknown" ]]; then
        print_error "Unsupported distribution: $distro"
        exit 1
    fi
    print_info "Package manager: $pkg_mgr"
    echo ""

    # Install build dependencies
    install_build_deps "$pkg_mgr" || exit 1
    echo ""

    # Download Suricata
    local source_dir
    source_dir=$(download_suricata "$SURICATA_VERSION") || exit 1
    echo ""

    # Compile Suricata
    compile_suricata "$source_dir" || {
        cleanup "$(dirname "$source_dir")"
        exit 1
    }
    echo ""

    # Create user and directories
    create_user || exit 1
    create_directories || exit 1
    echo ""

    # Install Suricata
    install_suricata "$source_dir" || {
        cleanup "$(dirname "$source_dir")"
        exit 1
    }
    echo ""

    # Create systemd service
    create_systemd_service || exit 1
    echo ""

    # Install suricata-update
    install_suricata_update || exit 1
    echo ""

    # Configure Suricata
    configure_suricata || exit 1
    echo ""

    # Cleanup
    cleanup "$(dirname "$source_dir")"
    echo ""

    # Enable and start
    print_info "Enabling and starting Suricata..."
    systemctl enable suricata
    systemctl start suricata

    # Wait and check
    sleep 3
    if systemctl is-active --quiet suricata; then
        print_status "Suricata is running"
        echo ""
        print_info "Installation Details:"
        echo "  Binary:       $SURICATA_BIN"
        echo "  Config:       $SURICATA_CONF_DIR/suricata.yaml"
        echo "  Eve alerts:   $SURICATA_LOG_DIR/eve-alerts.json (NFTBan HFS)"
        echo "  Rules:        $SURICATA_DATA_DIR/rules"
        echo "  Version:      $SURICATA_VERSION"
        echo ""
        print_info "Performance Expectations:"
        echo "  CPU Usage:    10-30% of 1 core (medium traffic)"
        echo "  RAM Usage:    300-600 MB typical, 600-800 MB peaks"
        echo "  Optimization: 40-60% CPU reduction vs unoptimized"
        echo ""
        print_info "Next Steps:"
        echo "  1. Check eve alerts: tail -f $SURICATA_LOG_DIR/eve-alerts.json"
        echo "  2. Monitor stats: journalctl -u suricata -f"
        echo "  3. Customize rules: edit $SURICATA_CONF_DIR/*.conf.local"
        echo "  4. Enable in NFTBan: edit /etc/nftban/nftban.conf"
        echo "     Set: NFTBAN_SURICATA_ENABLED=\"true\""
        echo ""
        print_info "Rule Management:"
        echo "  - See: $SURICATA_CONF_DIR/README.md"
        echo "  - Enable optional rules: $SURICATA_CONF_DIR/enable.conf.local"
        echo "  - Disable noisy rules: $SURICATA_CONF_DIR/disable.conf.local"
        echo ""
    else
        print_error "Suricata failed to start"
        systemctl status suricata --no-pager -l
        exit 1
    fi

    echo ""
    print_status "Suricata installation complete!"
    echo ""
}

main "$@"
