#!/usr/bin/env bash
# shellcheck disable=SC2034  # verbose used in eval context
# SPDX-License-Identifier: MPL-2.0
# meta:name="validate_node_exporter"
# meta:type="setup"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Validate Node Exporter installation and NFTBan metrics integration"
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
readonly NODE_EXPORTER_PORT=9100
readonly TEXTFILE_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector"
readonly NFTBAN_METRICS_FILE="${TEXTFILE_COLLECTOR_DIR}/nftban.prom"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNING_TESTS=0

# =============================================================================
# FUNCTIONS
# =============================================================================

# Print colored message
print_color() {
    local color="$1"
    shift
    echo -e "${color}$*${NC}"
}

# Print test header
test_header() {
    echo ""
    print_color "$BLUE" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_color "$BLUE" "TEST: $*"
    print_color "$BLUE" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print test result
test_result() {
    local status="$1"
    local message="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    case "$status" in
        PASS)
            print_color "$GREEN" "✓ PASS: $message"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            ;;
        FAIL)
            print_color "$RED" "✗ FAIL: $message"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            ;;
        WARN)
            print_color "$YELLOW" "⚠ WARN: $message"
            WARNING_TESTS=$((WARNING_TESTS + 1))
            ;;
    esac
}

# Print usage
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Validate Node Exporter installation and NFTBan metrics integration.

OPTIONS:
    --verbose               Show detailed output
    --skip-nftban-metrics  Skip NFTBan metrics validation (test Node Exporter only)
    --help                  Show this help message

EXAMPLES:
    # Standard validation
    $SCRIPT_NAME

    # Verbose mode
    $SCRIPT_NAME --verbose

    # Test Node Exporter only (without NFTBan metrics)
    $SCRIPT_NAME --skip-nftban-metrics

EXIT CODES:
    0 - All tests passed
    1 - One or more tests failed
    2 - Critical failure (Node Exporter not running)

EOF
}

# Test 1: Service status
test_service_status() {
    test_header "Service Status"

    # Detect service name
    local service_name=""
    if systemctl list-unit-files | grep -q "^node_exporter.service"; then
        service_name="node_exporter.service"
    elif systemctl list-unit-files | grep -q "^prometheus-node-exporter.service"; then
        service_name="prometheus-node-exporter.service"
    else
        test_result "FAIL" "Node Exporter service not found"
        return 1
    fi

    test_result "PASS" "Service found: $service_name"

    # Check if enabled
    if systemctl is-enabled --quiet "$service_name"; then
        test_result "PASS" "Service is enabled (starts on boot)"
    else
        test_result "WARN" "Service is not enabled (won't start on boot)"
    fi

    # Check if active
    if systemctl is-active --quiet "$service_name"; then
        test_result "PASS" "Service is active (running)"
    else
        test_result "FAIL" "Service is not running"
        echo "Check logs: journalctl -u $service_name -n 50"
        return 1
    fi

    # Check uptime
    local start_time
    start_time=$(systemctl show "$service_name" -p ActiveEnterTimestamp --value)
    if [[ -n "$start_time" ]]; then
        test_result "PASS" "Service started: $start_time"
    fi

    return 0
}

# Test 2: Network binding
test_network_binding() {
    test_header "Network Binding"

    # Check if listening on port
    if command -v netstat &>/dev/null; then
        local binding
        binding=$(netstat -tulnp 2>/dev/null | grep ":${NODE_EXPORTER_PORT}" | awk '{print $4}')

        if [[ -z "$binding" ]]; then
            test_result "FAIL" "Not listening on port $NODE_EXPORTER_PORT"
            return 1
        fi

        test_result "PASS" "Listening on: $binding"

        # Check if localhost-only
        if echo "$binding" | grep -q "127.0.0.1"; then
            test_result "PASS" "Bound to localhost only (SECURE)"
        elif echo "$binding" | grep -q "0.0.0.0"; then
            test_result "FAIL" "Bound to all interfaces (SECURITY RISK!)"
        else
            test_result "WARN" "Bound to specific IP: $binding"
        fi
    elif command -v ss &>/dev/null; then
        local binding
        binding=$(ss -tlnp 2>/dev/null | grep ":${NODE_EXPORTER_PORT}" | awk '{print $4}')

        if [[ -z "$binding" ]]; then
            test_result "FAIL" "Not listening on port $NODE_EXPORTER_PORT"
            return 1
        fi

        test_result "PASS" "Listening on: $binding"

        if echo "$binding" | grep -q "127.0.0.1"; then
            test_result "PASS" "Bound to localhost only (SECURE)"
        else
            test_result "WARN" "Not bound to localhost"
        fi
    else
        test_result "WARN" "Cannot check binding (netstat/ss not available)"
    fi

    return 0
}

# Test 3: Metrics endpoint
test_metrics_endpoint() {
    test_header "Metrics Endpoint"

    # Test HTTP connection
    if curl -s --max-time 5 "http://localhost:${NODE_EXPORTER_PORT}/metrics" >/dev/null; then
        test_result "PASS" "Metrics endpoint is accessible"
    else
        test_result "FAIL" "Cannot access metrics endpoint"
        return 1
    fi

    # Check for Node Exporter metrics
    if curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics" | grep -q "node_exporter_build_info"; then
        test_result "PASS" "Node Exporter metrics are present"
    else
        test_result "FAIL" "Node Exporter metrics not found"
        return 1
    fi

    # Get version info
    local version
    version=$(curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics" | grep "node_exporter_build_info" | grep -o 'version="[^"]*"' | cut -d'"' -f2)
    if [[ -n "$version" ]]; then
        test_result "PASS" "Node Exporter version: $version"
    fi

    return 0
}

# Test 4: Textfile collector
test_textfile_collector() {
    test_header "Textfile Collector"

    # Check directory exists
    if [[ -d "$TEXTFILE_COLLECTOR_DIR" ]]; then
        test_result "PASS" "Textfile collector directory exists"
    else
        test_result "FAIL" "Textfile collector directory missing: $TEXTFILE_COLLECTOR_DIR"
        return 1
    fi

    # Check directory permissions
    local perms
    perms=$(stat -c "%a" "$TEXTFILE_COLLECTOR_DIR" 2>/dev/null || stat -f "%OLp" "$TEXTFILE_COLLECTOR_DIR" 2>/dev/null)
    if [[ "$perms" == "750" ]]; then
        test_result "PASS" "Directory permissions correct: $perms"
    else
        test_result "WARN" "Directory permissions: $perms (expected 750)"
    fi

    # Check directory ownership
    local owner
    owner=$(stat -c "%U:%G" "$TEXTFILE_COLLECTOR_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$TEXTFILE_COLLECTOR_DIR" 2>/dev/null)
    if [[ "$owner" == "nftban:nftban" ]]; then
        test_result "PASS" "Directory ownership correct: $owner"
    else
        test_result "WARN" "Directory ownership: $owner (expected nftban:nftban)"
    fi

    # Check textfile collector is enabled in metrics
    if curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics" | grep -q "node_textfile_scrape_error"; then
        test_result "PASS" "Textfile collector is enabled"
    else
        test_result "FAIL" "Textfile collector is not enabled"
        echo "Add --collector.textfile.directory to Node Exporter service"
        return 1
    fi

    # Check for scrape errors
    local scrape_error
    scrape_error=$(curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics" | grep "^node_textfile_scrape_error" | awk '{print $2}')
    if [[ "$scrape_error" == "0" ]]; then
        test_result "PASS" "No textfile collector errors"
    else
        test_result "FAIL" "Textfile collector has errors (value: $scrape_error)"
        return 1
    fi

    return 0
}

# Test 5: NFTBan metrics
test_nftban_metrics() {
    test_header "NFTBan Metrics Integration"

    # Check if nftban.prom file exists
    if [[ -f "$NFTBAN_METRICS_FILE" ]]; then
        test_result "PASS" "NFTBan metrics file exists"
    else
        test_result "WARN" "NFTBan metrics file not found: $NFTBAN_METRICS_FILE"
        echo "Run: systemctl start nftban-unified-exporter.service"
        return 1
    fi

    # Check file age
    local file_age
    file_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_METRICS_FILE" 2>/dev/null || stat -f %m "$NFTBAN_METRICS_FILE" 2>/dev/null) ))
    if [[ $file_age -lt 300 ]]; then
        test_result "PASS" "Metrics file is recent (${file_age}s ago)"
    else
        test_result "WARN" "Metrics file is old (${file_age}s ago)"
        echo "Check: systemctl status nftban-unified-exporter.timer"
    fi

    # Check for nftban metrics in endpoint
    local nftban_metrics
    nftban_metrics=$(curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics" | grep -c "^nftban_" || true)

    if [[ $nftban_metrics -gt 0 ]]; then
        test_result "PASS" "NFTBan metrics found in endpoint ($nftban_metrics metrics)"
    else
        test_result "FAIL" "No NFTBan metrics in endpoint"
        return 1
    fi

    # Check for specific expected metrics
    local metrics_to_check=(
        "nftban_blocks_total"
        "nftban_health_status"
        "nftban_exporter_duration_seconds"
        "nftban_last_update_timestamp"
    )

    local metrics_output
    metrics_output=$(curl -s "http://localhost:${NODE_EXPORTER_PORT}/metrics")

    for metric in "${metrics_to_check[@]}"; do
        if echo "$metrics_output" | grep -q "^${metric}"; then
            test_result "PASS" "Metric present: $metric"
        else
            test_result "WARN" "Metric missing: $metric"
        fi
    done

    return 0
}

# Test 6: Security configuration
test_security() {
    test_header "Security Configuration"

    # Check systemd security directives
    local service_name=""
    if systemctl list-unit-files | grep -q "^node_exporter.service"; then
        service_name="node_exporter.service"
    elif systemctl list-unit-files | grep -q "^prometheus-node-exporter.service"; then
        service_name="prometheus-node-exporter.service"
    fi

    if [[ -n "$service_name" ]]; then
        # Check for security directives
        if systemctl cat "$service_name" | grep -q "PrivateTmp=yes"; then
            test_result "PASS" "PrivateTmp enabled"
        else
            test_result "WARN" "PrivateTmp not enabled"
        fi

        if systemctl cat "$service_name" | grep -q "ProtectSystem"; then
            test_result "PASS" "ProtectSystem enabled"
        else
            test_result "WARN" "ProtectSystem not enabled"
        fi

        if systemctl cat "$service_name" | grep -q "NoNewPrivileges=yes"; then
            test_result "PASS" "NoNewPrivileges enabled"
        else
            test_result "WARN" "NoNewPrivileges not enabled"
        fi
    fi

    # Check if running as root (bad)
    local pid
    pid=$(systemctl show "$service_name" -p MainPID --value)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        local user
        user=$(ps -o user= -p "$pid" 2>/dev/null || true)
        if [[ "$user" != "root" ]]; then
            test_result "PASS" "Running as non-root user: $user"
        else
            test_result "FAIL" "Running as root (security risk!)"
        fi
    fi

    # Check firewall (if firewalld or nftables)
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "${NODE_EXPORTER_PORT}/tcp"; then
            test_result "WARN" "Port ${NODE_EXPORTER_PORT} is open in firewall (may be exposed)"
        else
            test_result "PASS" "Port ${NODE_EXPORTER_PORT} not exposed in firewall"
        fi
    fi

    return 0
}

# Print summary
print_summary() {
    echo ""
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
    print_color "$BLUE" " Validation Summary"
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
    echo ""

    print_color "$GREEN" "Passed:   $PASSED_TESTS/$TOTAL_TESTS tests"
    print_color "$RED" "Failed:   $FAILED_TESTS/$TOTAL_TESTS tests"
    print_color "$YELLOW" "Warnings: $WARNING_TESTS/$TOTAL_TESTS tests"

    echo ""

    if [[ $FAILED_TESTS -eq 0 ]]; then
        print_color "$GREEN" "✓ Node Exporter validation PASSED"

        if [[ $WARNING_TESTS -gt 0 ]]; then
            print_color "$YELLOW" "⚠ Review warnings above for optimization opportunities"
        fi

        echo ""
        print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
        echo "Next steps:"
        echo "1. Configure Prometheus to scrape metrics"
        echo "2. Create Grafana dashboards"
        echo "3. Set up alerting rules"
        echo ""
        print_color "$BLUE" "Metrics endpoint: http://localhost:${NODE_EXPORTER_PORT}/metrics"
        print_color "$BLUE" "═══════════════════════════════════════════════════════════════"

        return 0
    else
        print_color "$RED" "✗ Node Exporter validation FAILED"
        echo ""
        echo "Review failed tests above and fix issues before continuing."
        echo ""
        print_color "$BLUE" "═══════════════════════════════════════════════════════════════"

        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local verbose=false
    local skip_nftban=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)
                verbose=true
                shift
                ;;
            --skip-nftban-metrics)
                skip_nftban=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
    print_color "$BLUE" " NFTBan Node Exporter Validation"
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"

    # Run tests
    test_service_status || true
    test_network_binding || true
    test_metrics_endpoint || true
    test_textfile_collector || true

    if [[ "$skip_nftban" != "true" ]]; then
        test_nftban_metrics || true
    fi

    test_security || true

    # Print summary
    print_summary
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
