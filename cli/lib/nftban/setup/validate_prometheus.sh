#!/usr/bin/env bash
# shellcheck disable=SC2034  # verbose used in eval context
# SPDX-License-Identifier: MPL-2.0
# meta:name="validate_prometheus"
# meta:type="setup"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Validate Prometheus installation and NFTBan metrics collection"
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
readonly PROMETHEUS_PORT=9090

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

Validate Prometheus installation and NFTBan metrics integration.

OPTIONS:
    --verbose               Show detailed output
    --skip-metrics         Skip metrics validation (test Prometheus only)
    --help                 Show this help message

EXAMPLES:
    # Standard validation
    $SCRIPT_NAME

    # Verbose mode
    $SCRIPT_NAME --verbose

    # Test Prometheus only
    $SCRIPT_NAME --skip-metrics

EXIT CODES:
    0 - All tests passed
    1 - One or more tests failed
    2 - Critical failure (Prometheus not running)

EOF
}

# Test 1: Service status
test_service_status() {
    test_header "Service Status"

    # Check if service exists
    if ! systemctl list-unit-files | grep -q "prometheus.service"; then
        test_result "FAIL" "Prometheus service not found"
        return 1
    fi
    test_result "PASS" "Service found: prometheus.service"

    # Check if enabled
    if systemctl is-enabled --quiet prometheus; then
        test_result "PASS" "Service is enabled (starts on boot)"
    else
        test_result "WARN" "Service is not enabled (won't start on boot)"
    fi

    # Check if active
    if systemctl is-active --quiet prometheus; then
        test_result "PASS" "Service is active (running)"
    else
        test_result "FAIL" "Service is not running"
        echo "Check logs: journalctl -u prometheus -n 50"
        return 1
    fi

    # Check uptime
    local start_time
    start_time=$(systemctl show prometheus -p ActiveEnterTimestamp --value)
    if [[ -n "$start_time" ]]; then
        test_result "PASS" "Service started: $start_time"
    fi

    return 0
}

# Test 2: Web UI access
test_web_ui() {
    test_header "Web UI Access"

    # Check if web UI is accessible
    if curl -s --max-time 5 "http://localhost:${PROMETHEUS_PORT}/-/healthy" >/dev/null; then
        test_result "PASS" "Web UI is accessible"
    else
        test_result "FAIL" "Cannot access Web UI"
        return 1
    fi

    # Check health endpoint
    local health
    health=$(curl -s "http://localhost:${PROMETHEUS_PORT}/-/healthy")
    if echo "$health" | grep -q "Prometheus is Healthy"; then
        test_result "PASS" "Health check passed"
    else
        test_result "FAIL" "Health check failed: $health"
        return 1
    fi

    # Check ready endpoint
    if curl -s "http://localhost:${PROMETHEUS_PORT}/-/ready" | grep -q "Prometheus is Ready"; then
        test_result "PASS" "Prometheus is ready"
    else
        test_result "WARN" "Prometheus not ready yet"
    fi

    # Get version
    local version
    version=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/status/buildinfo" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$version" ]]; then
        test_result "PASS" "Prometheus version: $version"
    fi

    return 0
}

# Test 3: Configuration
test_configuration() {
    test_header "Configuration"

    # Check config file exists
    if [[ -f /etc/prometheus/prometheus.yml ]]; then
        test_result "PASS" "Configuration file exists"
    else
        test_result "FAIL" "Configuration file missing: /etc/prometheus/prometheus.yml"
        return 1
    fi

    # Check config is valid
    if promtool check config /etc/prometheus/prometheus.yml &>/dev/null; then
        test_result "PASS" "Configuration is valid"
    else
        test_result "FAIL" "Configuration has errors"
        echo "Run: promtool check config /etc/prometheus/prometheus.yml"
        return 1
    fi

    # Check for nftban job
    if grep -q "job_name.*nftban" /etc/prometheus/prometheus.yml; then
        test_result "PASS" "NFTBan scrape job configured"
    else
        test_result "FAIL" "NFTBan scrape job not found in config"
        return 1
    fi

    # Check scrape interval
    local scrape_interval
    scrape_interval=$(grep "scrape_interval" /etc/prometheus/prometheus.yml | head -1 | grep -o "[0-9]*s")
    if [[ -n "$scrape_interval" ]]; then
        test_result "PASS" "Scrape interval: $scrape_interval"
    fi

    return 0
}

# Test 4: Targets
test_targets() {
    test_header "Scrape Targets"

    # Get targets from API
    local targets_json
    targets_json=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets")

    # Check if we can parse JSON (jq optional)
    if command -v jq &>/dev/null; then
        # Count active targets
        local active_targets
        active_targets=$(echo "$targets_json" | jq -r '.data.activeTargets | length')

        if [[ $active_targets -gt 0 ]]; then
            test_result "PASS" "$active_targets active target(s) found"
        else
            test_result "FAIL" "No active targets found"
            return 1
        fi

        # Check nftban target
        local nftban_health
        nftban_health=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job=="nftban") | .health')

        if [[ "$nftban_health" == "up" ]]; then
            test_result "PASS" "NFTBan target is up"
        elif [[ "$nftban_health" == "down" ]]; then
            test_result "FAIL" "NFTBan target is down"
            return 1
        else
            test_result "WARN" "NFTBan target status unknown"
        fi

        # Get last scrape time
        local last_scrape
        last_scrape=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job=="nftban") | .lastScrape')
        if [[ -n "$last_scrape" && "$last_scrape" != "null" ]]; then
            test_result "PASS" "Last scrape: $last_scrape"
        fi

    else
        # Fallback without jq
        if echo "$targets_json" | grep -q '"health":"up"'; then
            test_result "PASS" "At least one target is up"
        else
            test_result "WARN" "Cannot verify targets (jq not installed)"
        fi
    fi

    return 0
}

# Test 5: NFTBan metrics
test_nftban_metrics() {
    test_header "NFTBan Metrics Collection"

    # Wait a bit for metrics to be scraped
    sleep 2

    # Query for nftban metrics
    local query_result
    query_result=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/query?query=nftban_blocks_total")

    if echo "$query_result" | grep -q '"status":"success"'; then
        test_result "PASS" "Successfully queried NFTBan metrics"
    else
        test_result "FAIL" "Failed to query NFTBan metrics"
        return 1
    fi

    # Check if data exists
    if echo "$query_result" | grep -q '"result":\[\]'; then
        test_result "WARN" "No data returned for nftban_blocks_total (may need to wait 60s for first scrape)"
    elif echo "$query_result" | grep -q '"value"'; then
        test_result "PASS" "NFTBan metrics data found"

        # Get the value if jq available
        if command -v jq &>/dev/null; then
            local blocks_total
            blocks_total=$(echo "$query_result" | jq -r '.data.result[0].value[1]')
            if [[ -n "$blocks_total" && "$blocks_total" != "null" ]]; then
                test_result "PASS" "Current blocked IPs: $blocks_total"
            fi
        fi
    fi

    # Check for other key metrics
    local metrics_to_check=(
        "nftban_health_status"
        "nftban_exporter_duration_seconds"
        "nftban_last_update_timestamp"
    )

    for metric in "${metrics_to_check[@]}"; do
        if curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/query?query=${metric}" | grep -q '"status":"success"'; then
            test_result "PASS" "Metric available: $metric"
        else
            test_result "WARN" "Metric not available: $metric"
        fi
    done

    return 0
}

# Test 6: Alert rules
test_alert_rules() {
    test_header "Alert Rules"

    # Check if rules file exists
    if [[ -f /etc/prometheus/alerts/nftban-metrics.yml ]]; then
        test_result "PASS" "Alert rules file exists"
    else
        test_result "WARN" "Alert rules file not found"
        return 0
    fi

    # Validate rules file
    if promtool check rules /etc/prometheus/alerts/nftban-metrics.yml &>/dev/null; then
        test_result "PASS" "Alert rules are valid"
    else
        test_result "FAIL" "Alert rules have errors"
        echo "Run: promtool check rules /etc/prometheus/alerts/nftban-metrics.yml"
        return 1
    fi

    # Get loaded rules from API
    local rules_json
    rules_json=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/rules")

    if echo "$rules_json" | grep -q "NFTBan"; then
        test_result "PASS" "NFTBan alert rules are loaded"
    else
        test_result "WARN" "NFTBan alert rules may not be loaded"
    fi

    # Count rules if jq available
    if command -v jq &>/dev/null; then
        local rule_count
        rule_count=$(echo "$rules_json" | jq -r '.data.groups[].rules | length' | awk '{s+=$1} END {print s}')
        if [[ -n "$rule_count" && "$rule_count" -gt 0 ]]; then
            test_result "PASS" "$rule_count alert rule(s) loaded"
        fi
    fi

    return 0
}

# Test 7: Storage
test_storage() {
    test_header "Storage & Retention"

    # Check data directory exists
    if [[ -d /var/lib/prometheus ]]; then
        test_result "PASS" "Data directory exists"
    else
        test_result "FAIL" "Data directory missing: /var/lib/prometheus"
        return 1
    fi

    # Check permissions
    local owner
    owner=$(stat -c "%U:%G" /var/lib/prometheus 2>/dev/null || stat -f "%Su:%Sg" /var/lib/prometheus 2>/dev/null)
    if [[ "$owner" == "prometheus:prometheus" ]]; then
        test_result "PASS" "Data directory ownership correct: $owner"
    else
        test_result "WARN" "Data directory ownership: $owner (expected prometheus:prometheus)"
    fi

    # Check disk usage
    local disk_usage
    disk_usage=$(du -sh /var/lib/prometheus 2>/dev/null | awk '{print $1}')
    if [[ -n "$disk_usage" ]]; then
        test_result "PASS" "Current storage usage: $disk_usage"
    fi

    # Check for TSDB
    if [[ -d /var/lib/prometheus/wal ]]; then
        test_result "PASS" "TSDB WAL directory found"
    else
        test_result "WARN" "TSDB WAL directory not found (may be new installation)"
    fi

    return 0
}

# Test 8: Security
test_security() {
    test_header "Security Configuration"

    # Check if running as root (bad)
    local pid
    pid=$(systemctl show prometheus -p MainPID --value)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        local user
        user=$(ps -o user= -p "$pid" 2>/dev/null || true)
        if [[ "$user" != "root" ]]; then
            test_result "PASS" "Running as non-root user: $user"
        else
            test_result "FAIL" "Running as root (security risk!)"
        fi
    fi

    # Check binding address
    if netstat -tulnp 2>/dev/null | grep ":${PROMETHEUS_PORT}" | grep -q "127.0.0.1"; then
        test_result "PASS" "Bound to localhost only (SECURE)"
    elif netstat -tulnp 2>/dev/null | grep ":${PROMETHEUS_PORT}" | grep -q "0.0.0.0"; then
        test_result "WARN" "Bound to all interfaces (consider localhost-only for security)"
    fi

    # Check for authentication
    if [[ -f /etc/prometheus/web.yml ]]; then
        test_result "PASS" "Web authentication config exists"
    else
        test_result "WARN" "No web authentication configured (consider adding for production)"
    fi

    # Check systemd security directives
    if systemctl cat prometheus | grep -q "PrivateTmp=yes"; then
        test_result "PASS" "PrivateTmp enabled"
    else
        test_result "WARN" "PrivateTmp not enabled"
    fi

    if systemctl cat prometheus | grep -q "ProtectSystem"; then
        test_result "PASS" "ProtectSystem enabled"
    else
        test_result "WARN" "ProtectSystem not enabled"
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
        print_color "$GREEN" "✓ Prometheus validation PASSED"

        if [[ $WARNING_TESTS -gt 0 ]]; then
            print_color "$YELLOW" "⚠ Review warnings above for optimization opportunities"
        fi

        echo ""
        print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
        echo "Prometheus is ready to collect NFTBan metrics!"
        echo ""
        echo "Web UI:    http://localhost:${PROMETHEUS_PORT}"
        echo "Targets:   http://localhost:${PROMETHEUS_PORT}/targets"
        echo "Graphs:    http://localhost:${PROMETHEUS_PORT}/graph"
        echo ""
        echo "Example queries:"
        echo "  nftban_blocks_total"
        echo "  rate(nftban_bans_total[5m])"
        echo "  nftban_health_status{component=\"nftables\"}"
        echo ""
        print_color "$BLUE" "═══════════════════════════════════════════════════════════════"

        return 0
    else
        print_color "$RED" "✗ Prometheus validation FAILED"
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
    # shellcheck disable=SC2034  # verbose reserved for future use
    local verbose=false
    local skip_metrics=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)
                verbose=true
                shift
                ;;
            --skip-metrics)
                skip_metrics=true
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
    print_color "$BLUE" " NFTBan Prometheus Validation"
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"

    # Run tests
    test_service_status || true
    test_web_ui || true
    test_configuration || true
    test_targets || true

    if [[ "$skip_metrics" != "true" ]]; then
        test_nftban_metrics || true
    fi

    test_alert_rules || true
    test_storage || true
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
