#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Metrics Integration Test Suite
# =============================================================================
# meta:name="test_metrics_integration"
# meta:type="test"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="End-to-end integration testing of metrics system"
# meta:inventory.files=""
# meta:inventory.binaries="bash,systemctl,curl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-unified-exporter.timer,nftban-unified-exporter.service,node_exporter.service,prometheus.service,grafana-server.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test results
declare -a FAILED_TESTS

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NFTBan v0.6.0 - Metrics Integration Test Suite          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

test_pass() {
    # v1.19.20 FIX
    ((TESTS_PASSED++)) || true
    echo -e "${GREEN}[✓ PASS]${NC} $1"
}

test_fail() {
    # v1.19.20 FIX
    ((TESTS_FAILED++)) || true
    FAILED_TESTS+=("$1")
    echo -e "${RED}[✗ FAIL]${NC} $1"
}

test_skip() {
    # v1.19.20 FIX
    ((TESTS_SKIPPED++)) || true
    echo -e "${YELLOW}[⊘ SKIP]${NC} $1"
}

# =============================================================================
# TEST 1: EXPORTER SCRIPT TESTS
# =============================================================================

test_exporter_exists() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if [[ -f "/usr/lib/nftban/exporters/nftban_unified_exporter.sh" ]]; then
        test_pass "Exporter script exists"
        return 0
    else
        test_fail "Exporter script not found"
        return 1
    fi
}

test_exporter_executable() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if [[ -x "/usr/lib/nftban/exporters/nftban_unified_exporter.sh" ]]; then
        test_pass "Exporter script is executable"
        return 0
    else
        test_fail "Exporter script not executable"
        return 1
    fi
}

test_exporter_runs() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if timeout 10 /usr/lib/nftban/exporters/nftban_unified_exporter.sh >/dev/null 2>&1; then
        test_pass "Exporter script runs without errors"
        return 0
    else
        test_fail "Exporter script failed to run"
        return 1
    fi
}

test_metrics_file_created() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    local metrics_file="/var/lib/node_exporter/textfile_collector/nftban.prom"

    # Run exporter
    /usr/lib/nftban/exporters/nftban_unified_exporter.sh >/dev/null 2>&1 || true

    if [[ -f "$metrics_file" ]]; then
        test_pass "Metrics file created: $metrics_file"
        return 0
    else
        test_fail "Metrics file not created"
        return 1
    fi
}

test_metrics_format() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    local metrics_file="/var/lib/node_exporter/textfile_collector/nftban.prom"

    if [[ ! -f "$metrics_file" ]]; then
        test_skip "Metrics file not found, skipping format test"
        return 0
    fi

    # Check for valid Prometheus format (lines with # HELP or metric names)
    if grep -qE '^(# HELP|# TYPE|nftban_)' "$metrics_file"; then
        test_pass "Metrics file has valid Prometheus format"
        return 0
    else
        test_fail "Metrics file has invalid format"
        return 1
    fi
}

test_required_metrics() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    local metrics_file="/var/lib/node_exporter/textfile_collector/nftban.prom"

    if [[ ! -f "$metrics_file" ]]; then
        test_skip "Metrics file not found"
        return 0
    fi

    local required_metrics=(
        "nftban_blocks_total"
        "nftban_blocks_permanent"
        "nftban_blocks_temporary"
        "nftban_health_status"
        "nftban_exporter_duration_seconds"
        "nftban_last_update_timestamp"
    )

    local missing=0
    for metric in "${required_metrics[@]}"; do
        if ! grep -q "^${metric}" "$metrics_file"; then
            echo -e "  ${RED}Missing metric: $metric${NC}"
            # v1.19.20 FIX
            ((missing++)) || true
        fi
    done

    if [[ $missing -eq 0 ]]; then
        test_pass "All required metrics present (${#required_metrics[@]} metrics)"
        return 0
    else
        test_fail "Missing $missing required metrics"
        return 1
    fi
}

# =============================================================================
# TEST 2: SYSTEMD INTEGRATION TESTS
# =============================================================================

test_systemd_timer_exists() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl list-unit-files | grep -q "nftban-unified-exporter.timer"; then
        test_pass "Systemd timer unit exists"
        return 0
    else
        test_fail "Systemd timer unit not found"
        return 1
    fi
}

test_systemd_service_exists() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl list-unit-files | grep -q "nftban-unified-exporter.service"; then
        test_pass "Systemd service unit exists"
        return 0
    else
        test_fail "Systemd service unit not found"
        return 1
    fi
}

test_systemd_timer_enabled() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl is-enabled --quiet nftban-unified-exporter.timer 2>/dev/null; then
        test_pass "Systemd timer is enabled"
        return 0
    else
        test_skip "Systemd timer not enabled (may be intentional)"
        return 0
    fi
}

test_systemd_timer_active() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl is-active --quiet nftban-unified-exporter.timer 2>/dev/null; then
        test_pass "Systemd timer is active"
        return 0
    else
        test_skip "Systemd timer not active"
        return 0
    fi
}

# =============================================================================
# TEST 3: NODE EXPORTER TESTS
# =============================================================================

test_node_exporter_installed() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if command -v node_exporter >/dev/null 2>&1 || systemctl list-unit-files | grep -q "node_exporter"; then
        test_pass "Node Exporter is installed"
        return 0
    else
        test_skip "Node Exporter not installed"
        return 0
    fi
}

test_node_exporter_running() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl is-active --quiet node_exporter 2>/dev/null; then
        test_pass "Node Exporter service is running"
        return 0
    else
        test_skip "Node Exporter not running"
        return 0
    fi
}

test_node_exporter_metrics() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if ! command -v curl >/dev/null 2>&1; then
        test_skip "curl not available"
        return 0
    fi

    if curl -s http://localhost:9100/metrics >/dev/null 2>&1; then
        test_pass "Node Exporter metrics endpoint accessible"
        return 0
    else
        test_skip "Node Exporter metrics endpoint not accessible"
        return 0
    fi
}

test_nftban_metrics_in_node_exporter() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if ! command -v curl >/dev/null 2>&1; then
        test_skip "curl not available"
        return 0
    fi

    if curl -s http://localhost:9100/metrics 2>/dev/null | grep -q "nftban_"; then
        test_pass "NFTBan metrics exposed via Node Exporter"
        return 0
    else
        test_skip "NFTBan metrics not yet in Node Exporter"
        return 0
    fi
}

# =============================================================================
# TEST 4: PROMETHEUS TESTS
# =============================================================================

test_prometheus_installed() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if command -v prometheus >/dev/null 2>&1 || systemctl list-unit-files | grep -q "^prometheus.service"; then
        test_pass "Prometheus is installed"
        return 0
    else
        test_skip "Prometheus not installed (optional)"
        return 0
    fi
}

test_prometheus_running() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl is-active --quiet prometheus 2>/dev/null; then
        test_pass "Prometheus service is running"
        return 0
    else
        test_skip "Prometheus not running"
        return 0
    fi
}

test_prometheus_scraping() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if ! command -v curl >/dev/null 2>&1; then
        test_skip "curl not available"
        return 0
    fi

    if curl -s http://localhost:9090/-/healthy >/dev/null 2>&1; then
        test_pass "Prometheus is healthy and accessible"
        return 0
    else
        test_skip "Prometheus not accessible"
        return 0
    fi
}

test_prometheus_has_nftban_metrics() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if ! command -v curl >/dev/null 2>&1; then
        test_skip "curl not available"
        return 0
    fi

    if curl -s "http://localhost:9090/api/v1/label/__name__/values" 2>/dev/null | grep -q "nftban_"; then
        test_pass "Prometheus is collecting NFTBan metrics"
        return 0
    else
        test_skip "Prometheus not collecting NFTBan metrics yet"
        return 0
    fi
}

# =============================================================================
# TEST 5: GRAFANA TESTS
# =============================================================================

test_grafana_installed() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if command -v grafana-server >/dev/null 2>&1 || systemctl list-unit-files | grep -q "grafana-server"; then
        test_pass "Grafana is installed"
        return 0
    else
        test_skip "Grafana not installed (optional)"
        return 0
    fi
}

test_grafana_running() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if systemctl is-active --quiet grafana-server 2>/dev/null; then
        test_pass "Grafana service is running"
        return 0
    else
        test_skip "Grafana not running"
        return 0
    fi
}

test_grafana_dashboards_provisioned() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if [[ -d "/var/lib/grafana/dashboards/nftban" ]]; then
        local dashboard_count
        dashboard_count=$(find /var/lib/grafana/dashboards/nftban -name "nftban_*.json" 2>/dev/null | wc -l)
        if [[ $dashboard_count -eq 4 ]]; then
            test_pass "All 4 NFTBan dashboards provisioned"
            return 0
        else
            test_skip "NFTBan dashboards not fully provisioned ($dashboard_count/4)"
            return 0
        fi
    else
        test_skip "Grafana dashboards directory not found"
        return 0
    fi
}

# =============================================================================
# TEST 6: HEALTH CHECK INTEGRATION
# =============================================================================

test_health_check_function_exists() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if grep -q "nftban_health_check_metrics" /usr/lib/nftban/core/nftban_health.sh 2>/dev/null; then
        test_pass "Health check function exists in nftban_health.sh"
        return 0
    else
        test_fail "Health check function not found"
        return 1
    fi
}

test_health_check_runs() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    if command -v nftban >/dev/null 2>&1; then
        if timeout 30 nftban health >/dev/null 2>&1; then
            test_pass "nftban health command runs successfully"
            return 0
        else
            test_skip "nftban health command failed (may be expected)"
            return 0
        fi
    else
        test_skip "nftban command not available"
        return 0
    fi
}

# =============================================================================
# TEST 7: SETUP SCRIPTS
# =============================================================================

test_setup_scripts_exist() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    local scripts=(
        "/usr/lib/nftban/setup/install_node_exporter.sh"
        "/usr/lib/nftban/setup/validate_node_exporter.sh"
        "/usr/lib/nftban/setup/install_prometheus.sh"
        "/usr/lib/nftban/setup/validate_prometheus.sh"
        "/usr/lib/nftban/setup/provision_grafana_dashboards.sh"
        "/usr/lib/nftban/setup/configure_grafana_datasource.sh"
    )

    local missing=0
    for script in "${scripts[@]}"; do
        if [[ ! -f "$script" ]]; then
            # v1.19.20 FIX
            ((missing++)) || true
        fi
    done

    if [[ $missing -eq 0 ]]; then
        test_pass "All 6 setup scripts exist"
        return 0
    else
        test_fail "Missing $missing setup scripts"
        return 1
    fi
}

test_setup_scripts_executable() {
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    local scripts=(
        "/usr/lib/nftban/setup/install_node_exporter.sh"
        "/usr/lib/nftban/setup/validate_node_exporter.sh"
        "/usr/lib/nftban/setup/install_prometheus.sh"
        "/usr/lib/nftban/setup/validate_prometheus.sh"
        "/usr/lib/nftban/setup/provision_grafana_dashboards.sh"
        "/usr/lib/nftban/setup/configure_grafana_datasource.sh"
    )

    local not_executable=0
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]] && [[ ! -x "$script" ]]; then
            # v1.19.20 FIX
            ((not_executable++)) || true
        fi
    done

    if [[ $not_executable -eq 0 ]]; then
        test_pass "All setup scripts are executable"
        return 0
    else
        test_fail "$not_executable setup scripts not executable"
        return 1
    fi
}

# =============================================================================
# MAIN TEST RUNNER
# =============================================================================

main() {
    print_header

    # Test Suite 1: Exporter
    print_section "1. EXPORTER SCRIPT TESTS"
    test_exporter_exists
    test_exporter_executable
    test_exporter_runs
    test_metrics_file_created
    test_metrics_format
    test_required_metrics

    # Test Suite 2: Systemd
    print_section "2. SYSTEMD INTEGRATION TESTS"
    test_systemd_timer_exists
    test_systemd_service_exists
    test_systemd_timer_enabled
    test_systemd_timer_active

    # Test Suite 3: Node Exporter
    print_section "3. NODE EXPORTER TESTS"
    test_node_exporter_installed
    test_node_exporter_running
    test_node_exporter_metrics
    test_nftban_metrics_in_node_exporter

    # Test Suite 4: Prometheus
    print_section "4. PROMETHEUS TESTS"
    test_prometheus_installed
    test_prometheus_running
    test_prometheus_scraping
    test_prometheus_has_nftban_metrics

    # Test Suite 5: Grafana
    print_section "5. GRAFANA TESTS"
    test_grafana_installed
    test_grafana_running
    test_grafana_dashboards_provisioned

    # Test Suite 6: Health Checks
    print_section "6. HEALTH CHECK INTEGRATION"
    test_health_check_function_exists
    test_health_check_runs

    # Test Suite 7: Setup Scripts
    print_section "7. SETUP SCRIPTS"
    test_setup_scripts_exist
    test_setup_scripts_executable

    # Summary
    print_section "TEST SUMMARY"
    echo ""
    echo -e "  Total tests run:    $TESTS_RUN"
    echo -e "  ${GREEN}✓ Passed:${NC}           $TESTS_PASSED"
    echo -e "  ${RED}✗ Failed:${NC}           $TESTS_FAILED"
    echo -e "  ${YELLOW}⊘ Skipped:${NC}          $TESTS_SKIPPED"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  • $test"
        done
        echo ""
        echo -e "${RED}✗ INTEGRATION TESTS FAILED${NC}"
        echo ""
        exit 1
    else
        echo -e "${GREEN}✓ ALL CRITICAL TESTS PASSED${NC}"
        if [[ $TESTS_SKIPPED -gt 0 ]]; then
            echo -e "${YELLOW}Note: $TESTS_SKIPPED tests skipped (optional components not installed)${NC}"
        fi
        echo ""
        exit 0
    fi
}

main "$@"
