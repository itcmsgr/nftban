#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="provision_grafana_dashboards"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Automatically provision NFTBan dashboards to Grafana"
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

# Configuration
readonly GRAFANA_PROVISIONING_DIR="/etc/grafana/provisioning/dashboards"
readonly GRAFANA_DASHBOARDS_DIR="/var/lib/grafana/dashboards/nftban"
readonly NFTBAN_DASHBOARDS_SOURCE="/usr/share/nftban/grafana/dashboards"
readonly GRAFANA_USER="${GRAFANA_USER:-grafana}"
readonly GRAFANA_GROUP="${GRAFANA_GROUP:-grafana}"

check_grafana_installed() {
    if ! command -v grafana-server >/dev/null 2>&1 && ! systemctl list-unit-files | grep -q "grafana-server"; then
        print_error "Grafana is not installed"
        print_info "Install Grafana first:"
        print_info "  Fedora/RHEL: dnf install grafana"
        print_info "  Debian/Ubuntu: apt install grafana"
        print_info "  Or visit: https://grafana.com/grafana/download"
        exit 1
    fi
    print_status "Grafana is installed"
}

check_dashboards_exist() {
    if [[ ! -d "$NFTBAN_DASHBOARDS_SOURCE" ]]; then
        print_error "NFTBan dashboard files not found at: $NFTBAN_DASHBOARDS_SOURCE"
        print_info "Install NFTBan package first or ensure dashboards are copied to:"
        print_info "  $NFTBAN_DASHBOARDS_SOURCE"
        exit 1
    fi

    local dashboard_count
    dashboard_count=$(find "$NFTBAN_DASHBOARDS_SOURCE" -name "nftban_*.json" | wc -l)

    if [[ $dashboard_count -eq 0 ]]; then
        print_error "No NFTBan dashboard JSON files found"
        exit 1
    fi

    print_status "Found $dashboard_count NFTBan dashboard(s)"
}

create_provisioning_config() {
    print_info "Creating Grafana provisioning configuration..."

    # Create provisioning directory if it doesn't exist
    mkdir -p "$GRAFANA_PROVISIONING_DIR"

    # Create NFTBan dashboard provider configuration
    cat > "$GRAFANA_PROVISIONING_DIR/nftban.yaml" <<'EOF'
apiVersion: 1

providers:
  - name: 'NFTBan'
    orgId: 1
    folder: 'NFTBan'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards/nftban
EOF

    if [[ -f "$GRAFANA_PROVISIONING_DIR/nftban.yaml" ]]; then
        print_status "Created provisioning configuration: $GRAFANA_PROVISIONING_DIR/nftban.yaml"
    else
        print_error "Failed to create provisioning configuration"
        exit 1
    fi
}

copy_dashboards() {
    print_info "Copying NFTBan dashboards to Grafana..."

    # Create dashboard directory
    mkdir -p "$GRAFANA_DASHBOARDS_DIR"

    # Copy all NFTBan dashboard JSON files
    local copied=0
    for dashboard in "$NFTBAN_DASHBOARDS_SOURCE"/nftban_*.json; do
        if [[ -f "$dashboard" ]]; then
            cp "$dashboard" "$GRAFANA_DASHBOARDS_DIR/"
            local dashboard_name
            dashboard_name=$(basename "$dashboard")
            print_status "Copied: $dashboard_name"
            # v1.19.20 FIX
            ((copied++)) || true
        fi
    done

    if [[ $copied -eq 0 ]]; then
        print_error "No dashboards were copied"
        exit 1
    fi

    print_status "Copied $copied dashboard(s) to $GRAFANA_DASHBOARDS_DIR"
}

set_permissions() {
    print_info "Setting permissions..."

    local target_user="root"
    local target_group="root"

    # Check if grafana user exists
    if id "$GRAFANA_USER" &>/dev/null; then
        target_user="$GRAFANA_USER"
        target_group="$GRAFANA_GROUP"
        print_status "Set ownership to $GRAFANA_USER:$GRAFANA_GROUP"
    else
        print_warn "Grafana user '$GRAFANA_USER' not found, using root ownership"
    fi

    # Set directory permissions (no -R, explicit operations)
    chown "$target_user:$target_group" "$GRAFANA_DASHBOARDS_DIR"
    chmod 755 "$GRAFANA_DASHBOARDS_DIR"

    # Set file permissions explicitly (only JSON files in this directory)
    find "$GRAFANA_DASHBOARDS_DIR" -maxdepth 1 -name "*.json" -exec chown "$target_user:$target_group" {} \;
    find "$GRAFANA_DASHBOARDS_DIR" -maxdepth 1 -name "*.json" -exec chmod 644 {} \;

    print_status "Set permissions (755 for directory, 644 for JSON files)"
}

restart_grafana() {
    print_info "Restarting Grafana to load dashboards..."

    if systemctl is-active --quiet grafana-server; then
        if systemctl restart grafana-server; then
            print_status "Grafana restarted successfully"
            sleep 3  # Give Grafana time to start
        else
            print_error "Failed to restart Grafana"
            print_info "Check status: systemctl status grafana-server"
            exit 1
        fi
    else
        print_warn "Grafana is not running, attempting to start..."
        if systemctl start grafana-server; then
            print_status "Grafana started successfully"
            sleep 3
        else
            print_error "Failed to start Grafana"
            exit 1
        fi
    fi
}

verify_provisioning() {
    print_info "Verifying dashboard provisioning..."

    # Wait for Grafana to fully start
    local retries=10
    local count=0

    while [[ $count -lt $retries ]]; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health 2>/dev/null | grep -q "200"; then
            print_status "Grafana is responding"
            break
        fi
        # v1.19.20 FIX
        ((count++)) || true
        sleep 1
    done

    if [[ $count -eq $retries ]]; then
        print_warn "Could not verify Grafana health endpoint (may still be starting)"
    fi

    # Check if dashboards directory is accessible
    if [[ -d "$GRAFANA_DASHBOARDS_DIR" ]]; then
        local dashboard_count
        dashboard_count=$(find "$GRAFANA_DASHBOARDS_DIR" -name "nftban_*.json" | wc -l)
        print_info "Dashboards in place: $dashboard_count"
    fi
}

print_next_steps() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  NFTBan Dashboards Provisioned Successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Access Grafana:"
    echo "   http://localhost:3000"
    echo "   Default credentials: admin / admin"
    echo ""
    echo "2. Configure Prometheus datasource if not already done:"
    echo "   - Go to: Configuration → Data Sources → Add data source"
    echo "   - Select: Prometheus"
    echo "   - URL: http://localhost:9090"
    echo "   - Click: Save & Test"
    echo ""
    echo "3. Access NFTBan dashboards:"
    echo "   - Go to: Dashboards → Browse"
    echo "   - Look for: NFTBan folder"
    echo "   - Available dashboards:"
    echo "     • NFTBan Overview"
    echo "     • NFTBan System Health"
    echo "     • NFTBan Geographic Analysis"
    echo "     • NFTBan Performance"
    echo ""
    echo "4. Verify metrics are flowing:"
    echo "   - Check if panels show data"
    echo "   - If not, verify:"
    echo "     • Prometheus is running: systemctl status prometheus"
    echo "     • Node Exporter is running: systemctl status node_exporter"
    echo "     • Unified exporter is running: systemctl status nftban-unified-exporter.timer"
    echo ""
    echo "Configuration files:"
    echo "  Provisioning: $GRAFANA_PROVISIONING_DIR/nftban.yaml"
    echo "  Dashboards: $GRAFANA_DASHBOARDS_DIR/"
    echo ""
}

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NFTBan v1.0.0 - Grafana Dashboard Provisioning          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_grafana_installed
    check_dashboards_exist
    create_provisioning_config
    copy_dashboards
    set_permissions
    restart_grafana
    verify_provisioning
    print_next_steps
}

main "$@"
