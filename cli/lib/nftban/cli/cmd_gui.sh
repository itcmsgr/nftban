#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Web GUI Management CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_gui"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Enable/disable Web GUI + Prometheus + Go binaries"
# meta:input="Subcommand (enable, disable, status, restart, recompile)"
# meta:output="GUI status and management results"
# meta:depends="systemd, golang, prometheus, node_exporter"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-ui, nftban-core"
# meta:inventory.env_vars="NFTBAN_GUI_MODE"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-ui.service"
# meta:inventory.network="port 3940"
# meta:inventory.privileges="root"
# =============================================================================
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================

# shellcheck disable=SC2034  # Variables used by framework

set -Eeuo pipefail

# Simple config functions (no external dependencies)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Load distro configuration
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" || return 1
fi

# Load IPC library for single-writer architecture
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# Load shared metrics library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" || return 1
fi

# GUI-specific config helpers (local to this module to avoid conflicts with nftban_config.sh)
_gui_config_get() {
    local key="$1"
    local conf_file="${NFTBAN_CONFIG_DIR}/nftban.conf"

    if [[ -f "$conf_file" ]]; then
        local value
        value=$(grep "^${key}=" "$conf_file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"' || echo "")
        echo "$value"
    fi
}

_gui_config_set() {
    local key="$1"
    local value="$2"
    local conf_file="${NFTBAN_CONFIG_DIR}/nftban.conf"

    mkdir -p "${NFTBAN_CONFIG_DIR}" || return 1

    if [[ ! -f "$conf_file" ]]; then
        cat > "$conf_file" << 'EOF'
# NFTBan Global Configuration
NFTBAN_GUI_MODE="false"
EOF
    fi

    if grep -q "^${key}=" "$conf_file"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$conf_file"
    else
        echo "${key}=\"${value}\"" >> "$conf_file"
    fi
}

# ==============================================================================
# Cleanup Functions
# ==============================================================================
nftban_gui_cleanup_old_state() {
    echo "Step 1/5: Cleaning old state..."

    # Stop any running services (don't fail if not running)
    systemctl stop nftban-ui &>/dev/null || true
    systemctl stop prometheus &>/dev/null || true
    systemctl stop node_exporter &>/dev/null || true
    systemctl stop nftban-unified-exporter.timer &>/dev/null || true
    systemctl stop "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}" &>/dev/null || true

    # Clean old metrics files
    if [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
        rm -f /var/lib/node_exporter/textfile_collector/*.prom 2>/dev/null || true
        echo "  ✓ Cleaned old metrics files"
    fi

    # Remove old placeholder stubs from .real/ directory
    if [[ -d "${NFTBAN_LIB_DIR}/bin/.real" ]]; then
        for stub in "${NFTBAN_LIB_DIR}"/bin/.real/*; do
            if [[ -f "$stub" ]] && [[ $(stat -c%s "$stub") -lt 200 ]]; then
                rm -f "$stub" 2>/dev/null || true
            fi
        done
        echo "  ✓ Removed placeholder stubs"
    fi

    echo "  ✓ Old state cleaned"
}

nftban_gui_cleanup_disable() {
    echo "Step 3/4: Cleaning up data..."

    # Remove metrics files
    if [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
        rm -f /var/lib/node_exporter/textfile_collector/nftban*.prom 2>/dev/null || true
        rm -f /var/lib/node_exporter/textfile_collector/fail2ban.prom 2>/dev/null || true
        echo "  ✓ Removed metrics files"
    fi

    # Ask about Prometheus data (can be large)
    local prom_data="/var/lib/prometheus/data"
    if [[ -d "$prom_data" ]]; then
        local size
        size=$(du -sh "$prom_data" 2>/dev/null | awk '{print $1}')
        echo ""
        echo "  Prometheus has $size of time-series data"
        read -r -p "  Remove Prometheus data? [y/N]: " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$prom_data" 2>/dev/null || true
            echo "  ✓ Removed Prometheus data"
        else
            echo "  ℹ️  Keeping Prometheus data (will be reused if re-enabled)"
        fi
    fi

    # Clean temp compilation files
    rm -f "${NFTBAN_RUN_DIR:-/run/nftban}"/nftban_gui_*.tmp 2>/dev/null || true

    # Keep Go binaries for fast re-enable
    echo "  ℹ️  Keeping compiled Go binaries for fast re-enable"
}

# ==============================================================================
# Command: nftban gui enable
# ==============================================================================
nftban_gui_enable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling NFTBan Web GUI"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already enabled
    if [[ "$(_gui_config_get NFTBAN_GUI_MODE)" == "true" ]]; then
        echo "✅ GUI mode already enabled"
        echo ""
        echo "Web GUI:    https://$(hostname -I | awk '{print $1}'):3940/"
        echo "Status:     systemctl status nftban-ui"
        echo ""
        echo "Note: Port 3940 accessible from whitelist IPs ONLY"
        echo "      Add your IP: nftban whitelist add <your-ip>"
        return 0
    fi

    # Cleanup old state
    nftban_gui_cleanup_old_state
    echo ""

    # Step 2: Check dependencies
    echo "Step 2/6: Checking dependencies..."
    local missing_deps=()
    local missing_packages=()

    # Check golang
    if ! command -v go &>/dev/null; then
        missing_deps+=("golang")
        missing_packages+=("$(nftban_distro_get_package golang)")
    fi

    # Check prometheus service
    local prom_service
    prom_service=$(nftban_distro_get_service prometheus)
    if [[ -n "$prom_service" ]]; then
        set +o pipefail
        systemctl list-unit-files 2>/dev/null | grep -q "^${prom_service}.service"
        local prom_found=$?
        set -o pipefail
        if [[ $prom_found -ne 0 ]]; then
            missing_deps+=("prometheus")
            missing_packages+=("$(nftban_distro_get_package prometheus)")
        fi
    fi

    # Check node_exporter service
    local node_service
    node_service=$(nftban_distro_get_service node_exporter)
    if [[ -n "$node_service" ]]; then
        set +o pipefail
        systemctl list-unit-files 2>/dev/null | grep -q "^${node_service}.service"
        local node_found=$?
        set -o pipefail
        if [[ $node_found -ne 0 ]]; then
            missing_deps+=("node-exporter")
            missing_packages+=("$(nftban_distro_get_package node_exporter)")
        fi
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "  ⚠️  Missing dependencies: ${missing_deps[*]}"
        echo ""

        # Get install command from distro config
        local install_cmd
        install_cmd=$(nftban_distro_get_pkgmgr_cmd install_cmd)

        if [[ -z "$install_cmd" ]]; then
            echo "  ❌ Package manager not configured. Please install manually:"
            for dep in "${missing_deps[@]}"; do
                echo "     - $dep"
            done
            return 1
        fi

        # Auto-install dependencies
        echo "  🔧 Auto-installing dependencies..."
        echo "  Packages: ${missing_packages[*]}"
        echo "  Running: $install_cmd ${missing_packages[*]}"
        echo ""

        if $install_cmd "${missing_packages[@]}"; then
            echo ""
            echo "  ✅ Dependencies installed successfully"
        else
            echo ""
            echo "  ❌ Failed to install dependencies"
            echo "  Try manually: $install_cmd ${missing_packages[*]}"
            return 1
        fi
    else
        echo "  ✓ All dependencies present"
    fi

    # Step 3: Compile Go binaries
    echo ""
    echo "Step 3/6: Compiling Go binaries..."

    # Try multiple source directories
    local src_dir=""
    for dir in "/root/nftban-dev" "/root/nftban" "/home/gituser/github/nftban-dev" "/home/gituser/github/nftban" "/usr/share/nftban/src"; do
        if [[ -d "$dir/cmd" ]]; then
            src_dir="$dir"
            break
        fi
    done

    if [[ -z "$src_dir" ]]; then
        echo "  ❌ Source code not found"
        echo "     Searched: /root/nftban-dev, /root/nftban, /home/gituser/github/nftban-dev,"
        echo "               /home/gituser/github/nftban, /usr/share/nftban/src"
        return 1
    fi

    echo "  Using source: $src_dir"

    local bin_dir="${NFTBAN_LIB_DIR}/bin"
    mkdir -p "$bin_dir" || return 1

    # Compile nftban-core (consolidated binary)
    echo "  [1/2] nftban-core..."
    if [[ -d "$src_dir/cmd/nftban-core" ]]; then
        (
            cd "$src_dir" || exit 1
            go mod tidy &>/dev/null || true
            CGO_ENABLED=1 go build -o "$bin_dir/nftban-core" ./cmd/nftban-core 2>&1 | head -10
        )
        if [[ -x "$bin_dir/nftban-core" ]]; then
            local size
            size=$(du -h "$bin_dir/nftban-core" | awk '{print $1}')
            echo "        ✓ Built and installed ($size)"
        else
            echo "        ❌ Build failed"
            return 1
        fi
    else
        echo "        ⚠️  Source not found at $src_dir/cmd/nftban-core"
        return 1
    fi

    # Compile nftban-ui (Web GUI)
    echo "  [2/2] nftban-ui..."
    if [[ -d "$src_dir/cmd/nftban-ui" ]]; then
        (
            cd "$src_dir/cmd/nftban-ui" || exit 1
            go mod tidy &>/dev/null || true
            CGO_ENABLED=1 go build -o /usr/sbin/nftban-ui . 2>&1 | head -10
        )
        if [[ -x "/usr/sbin/nftban-ui" ]]; then
            local size
            size=$(du -h "/usr/sbin/nftban-ui" | awk '{print $1}')
            echo "        ✓ Built and installed ($size)"
        else
            echo "        ❌ Build failed"
            return 1
        fi
    else
        echo "        ⚠️  Source not found (using existing binary)"
    fi

    # Step 4: Configure Prometheus
    echo ""
    echo "Step 4/6: Configuring Prometheus stack..."

    # Use shared metrics library to start stack
    nftban_metrics_start_stack

    # Step 5: Start GUI service
    echo ""
    echo "Step 5/6: Starting GUI service..."

    # Enable and start GUI
    set +o pipefail  # Temporarily disable pipefail for service check
    systemctl list-unit-files 2>/dev/null | grep -q "${NFTBAN_SERVICE_UI:-nftban-ui.service}" 2>/dev/null
    local gui_found=$?
    set -o pipefail  # Re-enable pipefail
    if [[ $gui_found -eq 0 ]]; then
        systemctl enable nftban-ui &>/dev/null || true
        systemctl restart nftban-ui &>/dev/null || true
        sleep 2
        if systemctl is-active nftban-ui &>/dev/null; then
            echo "  ✓ Web GUI service running"
        else
            echo "  ❌ Web GUI service failed to start"
            echo ""
            echo "Check logs: journalctl -u nftban-ui -n 20"
            return 1
        fi
    else
        echo "  ⚠️  ${NFTBAN_SERVICE_UI:-nftban-ui.service} not installed"
        echo "     GUI service file missing - reinstall package"
        return 1
    fi

    # Step 6: Open firewall port for GUI (whitelist only)
    echo ""
    echo "Step 6/6: Configuring firewall for GUI access..."

    # Security: Ensure port 3940 is NOT in public tcp_ports_in
    # Port 3940 should only be accessible from whitelisted IPs
    if timeout 10s nft list set "${NFTBAN_TABLE_IPV4}" tcp_ports_in 2>/dev/null | grep -q "3940"; then
        echo "  Removing port 3940 from public access (security fix)"
        nft_ipc_delete_element "${NFTBAN_TABLE_IPV4}" "tcp_ports_in" "3940" 2>/dev/null || true
    fi
    if timeout 10s nft list set "${NFTBAN_TABLE_IPV6}" tcp_ports_in 2>/dev/null | grep -q "3940"; then
        nft_ipc_delete_element "${NFTBAN_TABLE_IPV6}" "tcp_ports_in" "3940" 2>/dev/null || true
    fi

    echo "  ✓ Port 3940: Whitelist-only access (secure configuration)"
    echo "    Access from: Whitelisted IPs only"
    echo "    Add whitelist IP: nftban whitelist add <your-ip>"

    # Update config
    _gui_config_set "NFTBAN_GUI_MODE" "true"

    # Final output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan GUI Enabled Successfully!"
    echo ""
    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo "🌐 Web GUI:        https://$ip:3940/"
    echo "📊 Prometheus:     http://localhost:9090/"
    echo "📈 Metrics:        http://localhost:9100/metrics"
    echo "⚡ Go Binaries:    ACTIVE (high performance mode)"
    echo ""
    echo "🔒 ACCESS CONTROL: Port 3940 accessible from whitelist IPs only"
    echo "   To allow your IP: nftban whitelist add <your-ip>"
    echo "   Check whitelist:  nftban whitelist show"
    echo ""
    echo "Test: nftban status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Command: nftban gui disable
# ==============================================================================
nftban_gui_disable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling NFTBan Web GUI"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already disabled
    if [[ "$(_gui_config_get NFTBAN_GUI_MODE)" != "true" ]]; then
        echo "ℹ️  GUI mode already disabled"
        return 0
    fi

    # Step 1: Stop services
    echo "Step 1/4: Stopping services..."

    # Stop GUI
    if systemctl list-unit-files | grep -q "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
        systemctl stop nftban-ui &>/dev/null || true
        echo "  ✓ Web GUI stopped"
    fi

    # Stop metrics stack (shared function)
    nftban_metrics_stop_stack

    # Step 2: Disable services
    echo ""
    echo "Step 2/4: Disabling services..."

    systemctl disable nftban-ui &>/dev/null || true
    systemctl disable prometheus &>/dev/null || true
    systemctl disable node_exporter &>/dev/null || true
    systemctl disable nftban-unified-exporter.timer &>/dev/null || true
    echo "  ✓ All services disabled (won't auto-start)"

    # Step 3: Cleanup
    echo ""
    nftban_gui_cleanup_disable

    # Step 4: Revert config
    echo ""
    echo "Step 4/4: Reverting to bash mode..."

    # Update config
    _gui_config_set "NFTBAN_GUI_MODE" "false"
    echo "  ✓ Configuration updated (NFTBAN_GUI_MODE=false)"
    echo "  ✓ Bash implementation active"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Reverted to CLI-only mode"
    echo ""
    echo "Note: Go binaries remain in .real/ for future use"
    echo "      Re-enable with: nftban gui enable"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Command: nftban gui status
# ==============================================================================
nftban_gui_status() {
    local gui_mode
    gui_mode=$(_gui_config_get NFTBAN_GUI_MODE)

    echo ""
    echo "NFTBan GUI Status"
    echo "================="
    echo ""

    if [[ "$gui_mode" == "true" ]]; then
        echo "Mode:             Full (GUI + Prometheus + Go)"
        echo ""

        # Check GUI service
        if systemctl is-active nftban-ui &>/dev/null; then
            local ip
            ip=$(hostname -I | awk '{print $1}')
            echo "Web GUI:          https://$ip:3940/ [RUNNING]"
        else
            echo "Web GUI:          [STOPPED]"
        fi

        # Check Prometheus
        if systemctl is-active prometheus &>/dev/null; then
            echo "Prometheus:       http://localhost:9090/ [RUNNING]"
        else
            echo "Prometheus:       [STOPPED]"
        fi

        # Check metrics
        if systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
            local last_run
            last_run=$(systemctl show nftban-unified-exporter.timer -p LastTriggerUSec --value)
            if [[ -n "$last_run" ]] && [[ "$last_run" != "n/a" ]]; then
                echo "Metrics:          Collecting (last: $(date -d "$last_run" '+%H:%M:%S'))"
            else
                echo "Metrics:          Enabled"
            fi
        else
            echo "Metrics:          [DISABLED]"
        fi

        # Check Go binaries
        echo ""
        echo "Performance:      Go binaries"
        local bin_dir="${NFTBAN_LIB_DIR}/bin"

        # Check nftban-core (consolidated binary)
        if [[ -x "$bin_dir/nftban-core" ]]; then
            local size
            size=$(du -h "$bin_dir/nftban-core" | awk '{print $1}')
            echo "  • nftban-core: ✓ ($size)"
        else
            echo "  • nftban-core: ❌ (not found)"
        fi

        # Check nftban-ui
        if [[ -x "/usr/sbin/nftban-ui" ]]; then
            local size
            size=$(du -h "/usr/sbin/nftban-ui" | awk '{print $1}')
            echo "  • nftban-ui: ✓ ($size)"
        else
            echo "  • nftban-ui: ❌ (not found)"
        fi
    else
        echo "Mode:             CLI-only (no GUI binaries)"
        echo ""
        echo "Web GUI:          [DISABLED]"
        echo "Metrics:          [DISABLED]"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "To enable GUI with metrics:"
        echo ""
        echo "  Option 1: With Prometheus (industry standard)"
        echo "    nftban gui enable"
        echo ""
        echo "  Option 2: With VictoriaMetrics (recommended)"
        echo "    nftban metrics enable --backend victoriametrics"
        echo "    nftban gui enable"
        echo ""
        echo "  For metrics only (no GUI):"
        echo "    nftban metrics enable --backend prometheus"
        echo "    nftban metrics enable --backend victoriametrics"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    echo ""
}

# ==============================================================================
# Command: nftban gui recompile
# ==============================================================================
nftban_gui_recompile() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Recompiling Go Binaries"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Try multiple source directories
    local src_dir=""
    for dir in "/root/nftban-dev" "/root/nftban" "/home/gituser/github/nftban-dev" "/home/gituser/github/nftban" "/usr/share/nftban/src"; do
        if [[ -d "$dir/cmd" ]]; then
            src_dir="$dir"
            break
        fi
    done

    if [[ -z "$src_dir" ]]; then
        echo "  ❌ Source code not found"
        echo "     Searched: /root/nftban-dev, /root/nftban, /home/gituser/github/nftban-dev,"
        echo "               /home/gituser/github/nftban, /usr/share/nftban/src"
        return 1
    fi

    echo "  Using source: $src_dir"
    echo ""

    local bin_dir="${NFTBAN_LIB_DIR}/bin"
    mkdir -p "$bin_dir" || return 1

    # Compile nftban-core (consolidated binary)
    echo "  [1/2] Compiling nftban-core..."
    if [[ -d "$src_dir/cmd/nftban-core" ]]; then
        (
            cd "$src_dir" || exit 1
            go mod tidy &>/dev/null || true
            CGO_ENABLED=1 go build -o "$bin_dir/nftban-core" ./cmd/nftban-core 2>&1 | head -10
        )
        if [[ -x "$bin_dir/nftban-core" ]]; then
            local size
            size=$(du -h "$bin_dir/nftban-core" | awk '{print $1}')
            echo "        ✓ Compiled and installed ($size)"
        else
            echo "        ❌ Build failed"
            return 1
        fi
    else
        echo "        ⚠️  Source not found at $src_dir/cmd/nftban-core"
        return 1
    fi

    # Compile nftban-ui (Web GUI)
    echo "  [2/2] Compiling nftban-ui..."
    if [[ -d "$src_dir/cmd/nftban-ui" ]]; then
        (
            cd "$src_dir/cmd/nftban-ui" || exit 1
            go mod tidy &>/dev/null || true
            CGO_ENABLED=1 go build -o /usr/sbin/nftban-ui . 2>&1 | head -10
        )
        if [[ -x "/usr/sbin/nftban-ui" ]]; then
            local size
            size=$(du -h "/usr/sbin/nftban-ui" | awk '{print $1}')
            echo "        ✓ Compiled and installed ($size)"
        else
            echo "        ❌ Build failed"
            return 1
        fi
    else
        echo "        ⚠️  Source not found (keeping existing binary)"
    fi

    echo ""
    echo "✅ Recompilation complete"
    echo ""
}

# ==============================================================================
# Command: nftban gui restart
# ==============================================================================
nftban_gui_restart() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Restarting Prometheus Stack & Web GUI"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local services_restarted=0
    local services_failed=0

    # Restart Node Exporter
    if systemctl list-unit-files | grep -q "node_exporter.service"; then
        echo "  [1/4] Restarting Node Exporter..."
        if systemctl restart node_exporter &>/dev/null; then
            if systemctl is-active node_exporter &>/dev/null; then
                echo "        ✓ Node Exporter running"
                # v1.19.20 FIX
                ((services_restarted++)) || true
            else
                echo "        ❌ Failed to start"
                # v1.19.20 FIX
                ((services_failed++)) || true
            fi
        else
            echo "        ❌ Restart failed"
            # v1.19.20 FIX
            ((services_failed++)) || true
        fi
    else
        echo "  [1/4] Node Exporter: Not installed"
    fi

    # Restart Prometheus
    if systemctl list-unit-files | grep -q "prometheus.service"; then
        echo "  [2/4] Restarting Prometheus..."
        if systemctl restart prometheus &>/dev/null; then
            if systemctl is-active prometheus &>/dev/null; then
                echo "        ✓ Prometheus running"
                # v1.19.20 FIX
                ((services_restarted++)) || true
            else
                echo "        ❌ Failed to start"
                # v1.19.20 FIX
                ((services_failed++)) || true
            fi
        else
            echo "        ❌ Restart failed"
            # v1.19.20 FIX
            ((services_failed++)) || true
        fi
    else
        echo "  [2/4] Prometheus: Not installed"
    fi

    # Restart metrics exporter
    if systemctl list-unit-files | grep -q "nftban-unified-exporter.timer"; then
        echo "  [3/4] Restarting Metrics Exporter..."
        systemctl restart nftban-unified-exporter.timer &>/dev/null
        systemctl start "${NFTBAN_SERVICE_METRICS_EXPORTER:-nftban-unified-exporter.service}" &>/dev/null
        echo "        ✓ Metrics collection restarted"
        # v1.19.20 FIX
        ((services_restarted++)) || true
    else
        echo "  [3/4] Metrics Exporter: Not installed"
    fi

    # Restart Web GUI
    if systemctl list-unit-files | grep -q "${NFTBAN_SERVICE_UI:-nftban-ui.service}"; then
        echo "  [4/4] Restarting Web GUI..."
        if systemctl restart nftban-ui &>/dev/null; then
            sleep 2
            if systemctl is-active nftban-ui &>/dev/null; then
                echo "        ✓ Web GUI running"
                # v1.19.20 FIX
                ((services_restarted++)) || true
            else
                echo "        ❌ Failed to start"
                # v1.19.20 FIX
                ((services_failed++)) || true
            fi
        else
            echo "        ❌ Restart failed"
            # v1.19.20 FIX
            ((services_failed++)) || true
        fi
    else
        echo "  [4/4] Web GUI: Not installed"
    fi

    echo ""
    if [[ $services_failed -eq 0 ]]; then
        echo "✅ All services restarted successfully ($services_restarted services)"
    else
        echo "⚠️  Restart completed with errors ($services_restarted ok, $services_failed failed)"
    fi

    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo ""
    echo "Web GUI:        https://$ip:3940/"
    echo "Prometheus:     http://localhost:9090/"
    echo ""
}

# ==============================================================================
# Help
# ==============================================================================

nftban_cmd_gui_help() {
    echo "Usage: nftban gui {enable|disable|status|restart|recompile|--fix}"
    echo ""
    echo "Commands:"
    echo "  enable      Enable Web GUI with metrics monitoring"
    echo "  disable     Disable Web GUI (revert to CLI only)"
    echo "  status      Show current GUI and services status"
    echo "  restart     Restart metrics exporters & Web GUI"
    echo "  recompile   Rebuild Go binaries from source"
    echo "  --fix       Auto-fix and enable GUI (alias for enable)"
    echo ""
    echo "What Gets Installed:"
    echo "  • Web GUI (HTTPS on port 3940)"
    echo "  • Metrics monitoring (Prometheus format)"
    echo "  • Go binaries (nftban-core for feeds/geoip/sync)"
    echo "  • Auto-installs: golang, prometheus, node-exporter (if missing)"
    echo ""
    echo "Examples:"
    echo "  nftban gui enable       # Enable full stack with auto-install"
    echo "  nftban gui status       # Check what's running"
    echo "  nftban gui restart      # Restart all services"
    echo "  nftban gui disable      # Disable and cleanup"
}

# ==============================================================================
# Main command router
# ==============================================================================

nftban_cmd_gui() {
    local subcommand="${1:-status}"

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        enable|--fix|fix)
            nftban_gui_enable
            ;;
        disable)
            nftban_gui_disable
            ;;
        status)
            nftban_gui_status
            ;;
        recompile|rebuild)
            nftban_gui_recompile
            ;;
        restart)
            nftban_gui_restart
            ;;
        help|--help|-h)
            nftban_cmd_gui_help
            ;;
        *)
            echo "Usage: nftban gui {enable|disable|status|restart|recompile|--fix}"
            echo ""
            echo "Run 'nftban gui help' for more information"
            return 1
            ;;
    esac
}

# Alias for backwards compatibility
nftban_gui_main() {
    nftban_cmd_gui "$@"
}

# Export functions
export -f nftban_cmd_gui
export -f nftban_gui_main
export -f nftban_gui_enable
export -f nftban_gui_disable
export -f nftban_gui_status
export -f nftban_gui_restart
export -f nftban_gui_recompile

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_gui "$@"
fi
