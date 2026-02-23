#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="configure_grafana_datasource"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Configure Prometheus datasource in Grafana"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
readonly GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"
readonly GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"
readonly PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
readonly GRAFANA_PROVISIONING_DIR="/etc/grafana/provisioning/datasources"

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_grafana_running() {
    if ! systemctl is-active --quiet grafana-server; then
        print_error "Grafana is not running"
        print_info "Start Grafana: systemctl start grafana-server"
        exit 1
    fi
    print_status "Grafana is running"
}

check_prometheus_running() {
    if ! curl -s "$PROMETHEUS_URL/-/healthy" >/dev/null 2>&1; then
        print_warn "Prometheus may not be running at $PROMETHEUS_URL"
        print_info "Datasource will be created but may not work until Prometheus starts"
    else
        print_status "Prometheus is accessible at $PROMETHEUS_URL"
    fi
}

create_provisioning_config() {
    print_info "Creating Prometheus datasource provisioning config..."

    mkdir -p "$GRAFANA_PROVISIONING_DIR"

    cat > "$GRAFANA_PROVISIONING_DIR/prometheus.yaml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: ${PROMETHEUS_URL}
    isDefault: true
    editable: true
    jsonData:
      timeInterval: 60s
      queryTimeout: 60s
      httpMethod: POST
    version: 1
EOF

    if [[ -f "$GRAFANA_PROVISIONING_DIR/prometheus.yaml" ]]; then
        print_status "Created datasource config: $GRAFANA_PROVISIONING_DIR/prometheus.yaml"
    else
        print_error "Failed to create datasource configuration"
        exit 1
    fi
}

restart_grafana() {
    print_info "Restarting Grafana to load datasource..."

    if systemctl restart grafana-server; then
        print_status "Grafana restarted"
        sleep 3
    else
        print_error "Failed to restart Grafana"
        exit 1
    fi
}

verify_datasource() {
    print_info "Verifying datasource configuration..."

    local retries=10
    local count=0

    while [[ $count -lt $retries ]]; do
        # v1.19.0: Use .netrc to avoid credential exposure in process args (R23)
        local _grafana_netrc
        _grafana_netrc=$(mktemp /tmp/nftban-grafana.XXXXXX)
        chmod 600 "$_grafana_netrc"
        local _grafana_host
        _grafana_host=$(echo "$GRAFANA_URL" | sed -E 's|https?://([^/:]+).*|\1|')
        echo "machine $_grafana_host login $GRAFANA_USER password $GRAFANA_PASS" > "$_grafana_netrc"
        if curl -s --netrc-file "$_grafana_netrc" "$GRAFANA_URL/api/datasources" 2>/dev/null | grep -q "Prometheus"; then
            rm -f "$_grafana_netrc"
            print_status "Prometheus datasource configured successfully"
            return 0
        fi
        rm -f "$_grafana_netrc"
        ((count++))
        sleep 1
    done

    print_warn "Could not verify datasource via API (may require manual check)"
    return 1
}

print_next_steps() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Prometheus Datasource Configured!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Datasource Details:"
    echo "  Name: Prometheus"
    echo "  Type: Prometheus"
    echo "  URL: $PROMETHEUS_URL"
    echo "  Default: Yes"
    echo ""
    echo "Verify in Grafana:"
    echo "  1. Go to: $GRAFANA_URL"
    echo "  2. Navigate to: Configuration → Data Sources"
    echo "  3. Click on: Prometheus"
    echo "  4. Click: Save & Test"
    echo ""
    echo "Expected result: 'Data source is working'"
    echo ""
    echo "Configuration file:"
    echo "  $GRAFANA_PROVISIONING_DIR/prometheus.yaml"
    echo ""
}

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NFTBan v1.0.0 - Grafana Datasource Configuration        ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_grafana_running
    check_prometheus_running
    create_provisioning_config
    restart_grafana
    verify_datasource || true
    print_next_steps
}

main "$@"
