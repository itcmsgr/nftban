#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="deploy_metrics"
# meta:type="setup"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Automated end-to-end metrics deployment"
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
source "$(dirname "${BASH_SOURCE[0]}")/../lib/setup_utils.sh" || return 1

# Configuration
readonly DEPLOYMENT_MODE="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Colors for header/step (unique to this script)
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NFTBan v1.0.0 - Metrics Deployment Automation           ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  STEP $1: $2${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

show_usage() {
    cat << EOF
Usage: $0 [MODE]

Automated NFTBan metrics deployment script.

MODES:
  local         Deploy with local Prometheus + Grafana (default)
  grafana-cloud Deploy with Grafana Cloud (remote write)
  minimal       Deploy only exporter + Node Exporter (no Prometheus/Grafana)

EXAMPLES:
  $0                    # Deploy with local Prometheus + Grafana
  $0 local              # Same as above
  $0 grafana-cloud      # Deploy with Grafana Cloud
  $0 minimal            # Minimal deployment

REQUIREMENTS:
  - Root privileges
  - NFTBan v1.0.0+ installed
  - Internet connection (for package downloads)

WHAT THIS SCRIPT DOES:
  1. Enables and starts NFTBan metrics exporter
  2. Installs and configures Node Exporter
  3. Installs and configures Prometheus (local mode)
  4. Installs Grafana (optional)
  5. Provisions Grafana dashboards
  6. Configures Prometheus datasource
  7. Validates entire stack
  8. Runs integration tests

EOF
}

# =============================================================================
# DEPLOYMENT STEPS
# =============================================================================

step1_enable_exporter() {
    print_step "1" "Enable NFTBan Metrics Exporter"

    # Check if exporter is installed
    if [[ ! -f "/usr/lib/nftban/exporters/nftban_prometheus_exporter.sh" ]]; then
        print_error "NFTBan metrics exporter not found"
        print_info "Install NFTBan v1.0.0+ first"
        exit 1
    fi

    print_info "Found NFTBan prometheus exporter"

    # Enable and start timer
    if systemctl list-unit-files | grep -q "nftban-unified-exporter.timer"; then
        systemctl enable nftban-unified-exporter.timer
        systemctl start nftban-unified-exporter.timer
        print_status "Unified exporter timer enabled and started"

        # Run exporter once to create initial metrics
        print_info "Running exporter to generate initial metrics..."
        /usr/lib/nftban/exporters/nftban_prometheus_exporter.sh || true
        print_status "Initial metrics generated"
    else
        print_error "Metrics exporter systemd units not found"
        exit 1
    fi

    # Verify metrics file created
    if [[ -f "/var/lib/node_exporter/textfile_collector/nftban.prom" ]]; then
        print_status "Metrics file created successfully"
    else
        print_warn "Metrics file not yet created (will be created on next run)"
    fi
}

step2_install_node_exporter() {
    print_step "2" "Install and Configure Node Exporter"

    if [[ -f "$SCRIPT_DIR/install_node_exporter.sh" ]]; then
        print_info "Running Node Exporter installation..."
        "$SCRIPT_DIR/install_node_exporter.sh"
        print_status "Node Exporter installation complete"
    else
        print_error "install_node_exporter.sh not found at: $SCRIPT_DIR"
        exit 1
    fi

    # Validate
    if [[ -f "$SCRIPT_DIR/validate_node_exporter.sh" ]]; then
        print_info "Validating Node Exporter..."
        if "$SCRIPT_DIR/validate_node_exporter.sh"; then
            print_status "Node Exporter validation passed"
        else
            print_warn "Node Exporter validation had warnings (may be OK)"
        fi
    fi
}

step3_install_prometheus() {
    print_step "3" "Install and Configure Prometheus"

    if [[ "$DEPLOYMENT_MODE" == "minimal" ]]; then
        print_info "Skipping Prometheus (minimal mode)"
        return 0
    fi

    if [[ "$DEPLOYMENT_MODE" == "grafana-cloud" ]]; then
        print_info "Skipping local Prometheus (using Grafana Cloud)"
        print_warn "You will need to configure remote_write in Prometheus config"
        print_info "See: /usr/share/doc/nftban/metrics/PROMETHEUS_SETUP.md"
        return 0
    fi

    # Local Prometheus installation
    if [[ -f "$SCRIPT_DIR/install_prometheus.sh" ]]; then
        print_info "Running Prometheus installation..."
        "$SCRIPT_DIR/install_prometheus.sh"
        print_status "Prometheus installation complete"
    else
        print_error "install_prometheus.sh not found at: $SCRIPT_DIR"
        exit 1
    fi

    # Validate
    if [[ -f "$SCRIPT_DIR/validate_prometheus.sh" ]]; then
        print_info "Validating Prometheus..."
        if "$SCRIPT_DIR/validate_prometheus.sh"; then
            print_status "Prometheus validation passed"
        else
            print_warn "Prometheus validation had warnings"
        fi
    fi
}

step4_install_grafana() {
    print_step "4" "Install Grafana (Optional)"

    if [[ "$DEPLOYMENT_MODE" == "minimal" ]]; then
        print_info "Skipping Grafana (minimal mode)"
        return 0
    fi

    # Check if Grafana already installed
    if command -v grafana-server >/dev/null 2>&1 || systemctl list-unit-files | grep -q "grafana-server"; then
        print_info "Grafana already installed"

        # Make sure it's running
        if ! systemctl is-active --quiet grafana-server; then
            print_info "Starting Grafana..."
            systemctl enable grafana-server
            systemctl start grafana-server
            sleep 3
        fi
        print_status "Grafana is running"
        return 0
    fi

    # Offer to install Grafana
    print_warn "Grafana not installed"
    print_info "Grafana is optional but recommended for visualization"
    print_info ""
    print_info "To install Grafana:"
    print_info "  Fedora/RHEL: sudo dnf install grafana"
    print_info "  Debian/Ubuntu: sudo apt install grafana"
    print_info ""
    print_info "Skipping Grafana setup for now..."
}

step5_provision_dashboards() {
    print_step "5" "Provision Grafana Dashboards"

    if [[ "$DEPLOYMENT_MODE" == "minimal" ]]; then
        print_info "Skipping Grafana dashboards (minimal mode)"
        return 0
    fi

    # Check if Grafana is installed
    if ! command -v grafana-server >/dev/null 2>&1 && ! systemctl list-unit-files | grep -q "grafana-server"; then
        print_warn "Grafana not installed, skipping dashboard provisioning"
        return 0
    fi

    if [[ -f "$SCRIPT_DIR/provision_grafana_dashboards.sh" ]]; then
        print_info "Provisioning NFTBan dashboards..."
        "$SCRIPT_DIR/provision_grafana_dashboards.sh"
        print_status "Dashboards provisioned successfully"
    else
        print_warn "provision_grafana_dashboards.sh not found, skipping"
    fi
}

step6_configure_datasource() {
    print_step "6" "Configure Prometheus Datasource in Grafana"

    if [[ "$DEPLOYMENT_MODE" == "minimal" ]]; then
        print_info "Skipping datasource configuration (minimal mode)"
        return 0
    fi

    # Check if Grafana is installed
    if ! command -v grafana-server >/dev/null 2>&1 && ! systemctl list-unit-files | grep -q "grafana-server"; then
        print_warn "Grafana not installed, skipping datasource configuration"
        return 0
    fi

    if [[ -f "$SCRIPT_DIR/configure_grafana_datasource.sh" ]]; then
        print_info "Configuring Prometheus datasource..."
        "$SCRIPT_DIR/configure_grafana_datasource.sh"
        print_status "Datasource configured successfully"
    else
        print_warn "configure_grafana_datasource.sh not found, skipping"
    fi
}

step7_verify_health() {
    print_step "7" "Verify System Health"

    if command -v nftban >/dev/null 2>&1; then
        print_info "Running NFTBan health check..."
        if nftban health; then
            print_status "NFTBan health check passed"
        else
            print_warn "NFTBan health check reported issues (review above)"
        fi
    else
        print_warn "nftban command not available, skipping health check"
    fi
}

step8_run_tests() {
    print_step "8" "Run Integration Tests"

    local test_script="/usr/share/nftban/tests/test_metrics_integration.sh"

    if [[ -f "$test_script" ]]; then
        print_info "Running integration tests..."
        if "$test_script"; then
            print_status "Integration tests passed"
        else
            print_warn "Some integration tests failed (review above)"
        fi
    else
        print_warn "Integration test script not found, skipping"
    fi
}

print_completion() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  NFTBan Metrics Deployment Complete!                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Deployment Summary:"
    echo "  Mode: $DEPLOYMENT_MODE"
    echo ""
    echo "Services Status:"
    systemctl is-active --quiet nftban-unified-exporter.timer && echo -e "  ${GREEN}✓${NC} NFTBan Unified Exporter: Running" || echo -e "  ${RED}✗${NC} NFTBan Unified Exporter: Not running"
    systemctl is-active --quiet node_exporter && echo -e "  ${GREEN}✓${NC} Node Exporter: Running" || echo -e "  ${YELLOW}⊘${NC} Node Exporter: Not running"

    if [[ "$DEPLOYMENT_MODE" != "minimal" ]]; then
        systemctl is-active --quiet prometheus && echo -e "  ${GREEN}✓${NC} Prometheus: Running" || echo -e "  ${YELLOW}⊘${NC} Prometheus: Not running"
        systemctl is-active --quiet grafana-server && echo -e "  ${GREEN}✓${NC} Grafana: Running" || echo -e "  ${YELLOW}⊘${NC} Grafana: Not running"
    fi

    echo ""
    echo "Access Points:"
    if systemctl is-active --quiet node_exporter 2>/dev/null; then
        echo "  Node Exporter: http://localhost:9100/metrics"
    fi
    if systemctl is-active --quiet prometheus 2>/dev/null; then
        echo "  Prometheus: http://localhost:9090"
    fi
    if systemctl is-active --quiet grafana-server 2>/dev/null; then
        echo "  Grafana: http://localhost:3000 (admin/admin)"
    fi

    echo ""
    echo "Next Steps:"
    echo "  1. Check metrics: curl http://localhost:9100/metrics | grep nftban_"

    if [[ "$DEPLOYMENT_MODE" == "local" ]] && systemctl is-active --quiet grafana-server 2>/dev/null; then
        echo "  2. Open Grafana: http://localhost:3000"
        echo "  3. Navigate to: Dashboards → Browse → NFTBan"
        echo "  4. Explore dashboards: Overview, Health, Geographic, Performance"
    fi

    echo ""
    echo "Documentation:"
    echo "  /usr/share/doc/nftban/metrics/NODE_EXPORTER_SETUP.md"
    echo "  /usr/share/doc/nftban/metrics/PROMETHEUS_SETUP.md"
    echo "  /usr/share/doc/nftban/metrics/GRAFANA_INTEGRATION.md"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    print_header

    # Validate mode
    case "$DEPLOYMENT_MODE" in
        local|grafana-cloud|minimal)
            print_info "Deployment mode: $DEPLOYMENT_MODE"
            ;;
        -h|--help|help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Invalid deployment mode: $DEPLOYMENT_MODE"
            echo ""
            show_usage
            exit 1
            ;;
    esac

    check_root

    # Execute deployment steps
    step1_enable_exporter
    step2_install_node_exporter
    step3_install_prometheus
    step4_install_grafana
    step5_provision_dashboards
    step6_configure_datasource
    step7_verify_health
    step8_run_tests

    print_completion
}

main "$@"
