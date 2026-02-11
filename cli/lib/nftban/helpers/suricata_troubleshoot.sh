#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_troubleshoot"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Diagnose Suricata issues and verify proper operation"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Source distro config for distribution-specific paths
_NFTBAN_LIB_DIR="${_NFTBAN_LIB_DIR:-/usr/lib/nftban}"
# shellcheck source=/dev/null
[[ -f "${_NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]] && source "${_NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Paths - use distro config (NO HARDCODED FALLBACKS)
readonly SURICATA_BIN="${DISTRO_PATHS[suricata]}"
readonly SURICATA_YAML="${DISTRO_PATHS[suricata_yaml]}"
readonly EVE_LOG="${DISTRO_PATHS[suricata_eve_log]}"
readonly SURICATA_LOG_DIR="${DISTRO_PATHS[suricata_log_dir]}"
readonly SURICATA_LOG="${SURICATA_LOG_DIR}/suricata.log"
readonly SURICATA_RULES_DIR="${DISTRO_PATHS[suricata_rules_dir]}"
readonly SURICATA_RUN_DIR="${SURICATA_RUN_DIR:-/run/suricata}"
readonly SURICATA_SOCKET="${SURICATA_RUN_DIR}/suricata-command.socket"

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_check() {
    echo -e "${BLUE}[CHECK]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[✓]${NC} $1"
    ((CHECKS_PASSED++))
}

print_fail() {
    echo -e "${RED}[✗]${NC} $1"
    ((CHECKS_FAILED++))
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    ((CHECKS_WARNING++))
}

print_info() {
    echo -e "    $1"
}

print_fix() {
    echo -e "${YELLOW}    FIX:${NC} $1"
}

# =============================================================================
# CHECK 1: Suricata Binary
# =============================================================================
check_binary() {
    print_header "1. Suricata Binary Check"

    print_check "Checking if Suricata is installed..."
    if [[ -x "$SURICATA_BIN" ]]; then
        local version
        version=$("$SURICATA_BIN" --build-info 2>&1 | grep -oP 'Suricata version \K[0-9.]+' | head -1 || echo "unknown")
        print_pass "Suricata found: $SURICATA_BIN (version: $version)"
    else
        print_fail "Suricata not found at $SURICATA_BIN"
        print_fix "Install Suricata: sudo ./cli/lib/nftban/setup/install_suricata.sh"
        return 1
    fi
}

# =============================================================================
# CHECK 2: Systemd Service
# =============================================================================
check_service() {
    print_header "2. Systemd Service Check"

    print_check "Checking if Suricata service exists..."
    if systemctl list-unit-files | grep -q suricata.service; then
        print_pass "Suricata service exists"
    else
        print_fail "Suricata service not found"
        print_fix "Create service: see /cli/lib/nftban/setup/install_suricata.sh"
        return 1
    fi

    print_check "Checking if Suricata is enabled..."
    if systemctl is-enabled --quiet suricata 2>/dev/null; then
        print_pass "Suricata service is enabled"
    else
        print_warn "Suricata service is NOT enabled (won't start on boot)"
        print_fix "Enable: sudo systemctl enable suricata"
    fi

    print_check "Checking if Suricata is running..."
    if systemctl is-active --quiet suricata 2>/dev/null; then
        print_pass "Suricata is running"

        # Check uptime
        local uptime
        uptime=$(systemctl show suricata -p ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
        print_info "Started: $uptime"
    else
        print_fail "Suricata is NOT running"
        print_fix "Start: sudo systemctl start suricata"
        print_fix "Check logs: sudo journalctl -xeu suricata -n 50"
        return 1
    fi
}

# =============================================================================
# CHECK 3: Configuration Files
# =============================================================================
check_config() {
    print_header "3. Configuration Files Check"

    print_check "Checking suricata.yaml..."
    if [[ -f "$SURICATA_YAML" ]]; then
        print_pass "Found: $SURICATA_YAML"

        # Test configuration syntax
        print_check "Testing configuration syntax..."
        if "$SURICATA_BIN" -T -c "$SURICATA_YAML" &>/dev/null; then
            print_pass "Configuration syntax is valid"
        else
            print_fail "Configuration syntax has errors"
            print_fix "Test manually: sudo suricata -T -c $SURICATA_YAML"
            return 1
        fi
    else
        print_fail "suricata.yaml not found at $SURICATA_YAML"
        print_fix "Copy template: sudo cp /install/templates/suricata.yaml.optimized $SURICATA_YAML"
        return 1
    fi

    print_check "Checking network interface configuration..."
    local interface
    interface=$(grep -A1 "^af-packet:" "$SURICATA_YAML" | grep "interface:" | awk '{print $3}' | head -1 || echo "")
    if [[ -n "$interface" ]]; then
        print_pass "Monitoring interface: $interface"

        # Check if interface exists
        if ip link show "$interface" &>/dev/null; then
            print_pass "Interface $interface exists"

            # Check if interface is UP
            if ip link show "$interface" | grep -q "state UP"; then
                print_pass "Interface $interface is UP"
            else
                print_warn "Interface $interface is DOWN"
                print_fix "Bring up: sudo ip link set $interface up"
            fi
        else
            print_fail "Interface $interface does NOT exist"
            print_fix "Check available interfaces: ip link show"
            print_fix "Update suricata.yaml with correct interface"
        fi
    else
        print_fail "No interface configured in af-packet section"
        print_fix "Edit $SURICATA_YAML and set interface under af-packet section"
    fi
}

# =============================================================================
# CHECK 4: Rules
# =============================================================================
check_rules() {
    print_header "4. Suricata Rules Check"

    print_check "Checking if rules are installed..."
    local rules_dir="${SURICATA_RULES_DIR}"
    if [[ -d "$rules_dir" ]]; then
        local rule_count
        rule_count=$(find "$rules_dir" -name "*.rules" -type f 2>/dev/null | wc -l)

        if [[ $rule_count -gt 0 ]]; then
            print_pass "Found $rule_count rule files in $rules_dir"

            # Count actual rules
            local total_rules
            total_rules=$(grep -h "^alert\|^drop\|^pass\|^reject" "$rules_dir"/*.rules 2>/dev/null | wc -l || echo 0)
            print_info "Total rules: $total_rules"

            if [[ $total_rules -lt 100 ]]; then
                print_warn "Very few rules loaded ($total_rules) - detection may be limited"
                print_fix "Update rules: sudo suricata-update"
            fi
        else
            print_fail "No rule files found in $rules_dir"
            print_fix "Download rules: sudo suricata-update"
            return 1
        fi
    else
        print_fail "Rules directory not found: $rules_dir"
        print_fix "Create and populate: sudo suricata-update"
        return 1
    fi

    print_check "Checking rule reload in logs..."
    if grep -q "rule reload complete" "$SURICATA_LOG" 2>/dev/null; then
        local loaded_rules
        loaded_rules=$(grep "rule reload complete" "$SURICATA_LOG" 2>/dev/null | tail -1 | grep -oP '\d+ rules' || echo "unknown")
        print_pass "Rules loaded: $loaded_rules"
    else
        print_warn "No 'rule reload complete' message found in logs"
        print_fix "Check: sudo journalctl -u suricata | grep -i rule"
    fi
}

# =============================================================================
# CHECK 5: Logging
# =============================================================================
check_logging() {
    print_header "5. Logging Check"

    print_check "Checking eve-alerts.json log file..."
    if [[ -f "$EVE_LOG" ]]; then
        local size
        size=$(du -h "$EVE_LOG" | awk '{print $1}')
        print_pass "Found: $EVE_LOG ($size)"

        # Check if file is growing (modified in last hour)
        if [[ $(find "$EVE_LOG" -mmin -60 2>/dev/null) ]]; then
            print_pass "Log file is actively being written (modified < 1 hour ago)"
        else
            print_warn "Log file hasn't been modified in over 1 hour"
            print_fix "Check if Suricata is receiving traffic"
        fi

        # Check permissions
        if [[ -r "$EVE_LOG" ]]; then
            print_pass "Log file is readable"
        else
            print_fail "Log file is NOT readable (permission denied)"
            print_fix "Fix permissions: sudo chmod 644 $EVE_LOG"
        fi

        # Parse event types
        print_check "Analyzing event types in eve-alerts.json..."
        if command -v jq &>/dev/null; then
            local event_summary
            event_summary=$(tail -1000 "$EVE_LOG" 2>/dev/null | jq -r '.event_type' 2>/dev/null | sort | uniq -c | sort -rn || echo "")

            if [[ -n "$event_summary" ]]; then
                print_pass "Event type distribution (last 1000 events):"
                echo "$event_summary" | while read -r line; do
                    print_info "$line"
                done

                # Check for alerts
                if echo "$event_summary" | grep -q "alert"; then
                    print_pass "Alerts are being generated"
                else
                    print_warn "No alerts found in recent logs (may be normal if no attacks)"
                    print_info "This is expected if there's no malicious traffic"
                fi
            else
                print_warn "Could not parse eve-alerts.json (may be empty or invalid JSON)"
            fi
        else
            print_warn "jq not installed - skipping JSON analysis"
            print_fix "Install jq: sudo yum install jq (RHEL) or sudo apt install jq (Debian)"
        fi
    else
        print_fail "eve-alerts.json not found at $EVE_LOG"
        print_fix "Check suricata.yaml eve-log configuration"
        print_fix "Verify Suricata has write permissions to /var/log/suricata/"
        return 1
    fi

    print_check "Checking suricata.log for errors..."
    if [[ -f "$SURICATA_LOG" ]]; then
        local error_count
        error_count=$(grep -i "error\|failed\|fatal" "$SURICATA_LOG" 2>/dev/null | tail -10 | wc -l)

        if [[ $error_count -gt 0 ]]; then
            print_warn "Found $error_count recent errors in $SURICATA_LOG"
            print_info "Last 5 errors:"
            grep -i "error\|failed\|fatal" "$SURICATA_LOG" | tail -5 | while read -r line; do
                print_info "  $line"
            done
            print_fix "Review full log: sudo tail -50 $SURICATA_LOG"
        else
            print_pass "No recent errors in suricata.log"
        fi
    fi
}

# =============================================================================
# CHECK 6: Resource Usage
# =============================================================================
check_resources() {
    print_header "6. Resource Usage Check"

    if systemctl is-active --quiet suricata 2>/dev/null; then
        print_check "Checking CPU and memory usage..."

        local pid
        pid=$(systemctl show suricata -p MainPID --value 2>/dev/null || echo "")

        if [[ -n "$pid" && "$pid" != "0" ]]; then
            # Get CPU and memory
            local cpu_mem
            cpu_mem=$(ps -p "$pid" -o %cpu,%mem,rss --no-headers 2>/dev/null || echo "")

            if [[ -n "$cpu_mem" ]]; then
                local cpu
                local mem_percent
                local mem_rss
                cpu=$(echo "$cpu_mem" | awk '{print $1}')
                mem_percent=$(echo "$cpu_mem" | awk '{print $2}')
                mem_rss=$(echo "$cpu_mem" | awk '{print $3}')
                mem_mb=$((mem_rss / 1024))

                print_pass "CPU: ${cpu}%  |  RAM: ${mem_mb}MB (${mem_percent}%)"

                # Check if within expected ranges
                if (( $(echo "$cpu > 50" | bc -l) )); then
                    print_warn "CPU usage is high (>50%) - may need optimization"
                    print_fix "Check /install/templates/suricata.yaml.optimized for tuning"
                fi

                if (( mem_mb > 1024 )); then
                    print_warn "Memory usage is high (>1GB) - may need optimization"
                    print_fix "Reduce flow timeouts or disable unused protocols"
                fi
            else
                print_warn "Could not retrieve CPU/memory stats"
            fi

            # Check packet stats
            print_check "Checking packet capture statistics..."
            if command -v suricatasc &>/dev/null && [[ -S "$SURICATA_SOCKET" ]]; then
                local stats
                stats=$(echo "dump-counters" | suricatasc 2>/dev/null | jq -r '.message.capture.kernel_packets' 2>/dev/null || echo "")

                if [[ -n "$stats" && "$stats" != "null" ]]; then
                    print_pass "Packets captured: $stats"
                fi
            fi
        fi
    else
        print_warn "Suricata not running - cannot check resource usage"
    fi
}

# =============================================================================
# CHECK 7: Network Connectivity Test
# =============================================================================
check_network_test() {
    print_header "7. Network Traffic Test"

    print_check "Sending test traffic to trigger detection..."
    print_info "Attempting SSH connection to trigger SSH detection rule..."

    # Try to connect to localhost SSH (will trigger SSH detection)
    timeout 2 ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no testuser@localhost 2>/dev/null || true

    sleep 3  # Wait for Suricata to process

    # Check if SSH events were logged
    if [[ -f "$EVE_LOG" ]]; then
        local ssh_events
        ssh_events=$(tail -100 "$EVE_LOG" 2>/dev/null | jq -r 'select(.event_type=="ssh")' 2>/dev/null | wc -l || echo 0)

        if [[ $ssh_events -gt 0 ]]; then
            print_pass "SSH events detected in eve-alerts.json (Suricata IS capturing traffic)"
        else
            print_warn "No SSH events found - Suricata may not be capturing traffic"
            print_fix "Check interface configuration in suricata.yaml"
            print_fix "Verify interface is correct: ip link show"
        fi
    fi
}

# =============================================================================
# CHECK 8: NFTBan Integration
# =============================================================================
check_nftban_integration() {
    print_header "8. NFTBan Integration Check"

    print_check "Checking NFTBan configuration..."
    local nftban_conf="${NFTBAN_CONFIG_DIR}/nftban.conf"

    if [[ -f "$nftban_conf" ]]; then
        if grep -q "NFTBAN_SURICATA_ENABLED" "$nftban_conf" 2>/dev/null; then
            local enabled
            enabled=$(grep "NFTBAN_SURICATA_ENABLED" "$nftban_conf" | cut -d= -f2 | tr -d '"' || echo "false")

            if [[ "$enabled" == "true" ]]; then
                print_pass "Suricata integration is ENABLED in nftban.conf"
            else
                print_warn "Suricata integration is DISABLED in nftban.conf"
                print_fix "Enable: Set NFTBAN_SURICATA_ENABLED=\"true\" in $nftban_conf"
            fi
        fi

        # Check eve-alerts.json path
        local eve_path
        eve_path=$(grep "NFTBAN_SURICATA_EVE_LOG" "$nftban_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        if [[ -n "$eve_path" ]]; then
            if [[ "$eve_path" == "$EVE_LOG" ]]; then
                print_pass "Eve.json path matches: $eve_path"
            else
                print_warn "Eve.json path mismatch:"
                print_info "  Config: $eve_path"
                print_info "  Actual: $EVE_LOG"
            fi
        fi
    else
        print_warn "NFTBan config not found at $nftban_conf"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    print_header "SUMMARY"

    echo ""
    echo -e "  ${GREEN}✓ Passed:${NC}  $CHECKS_PASSED"
    echo -e "  ${YELLOW}! Warnings:${NC} $CHECKS_WARNING"
    echo -e "  ${RED}✗ Failed:${NC}  $CHECKS_FAILED"
    echo ""

    if [[ $CHECKS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✓ Suricata is properly configured and operational!${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if [[ $CHECKS_WARNING -gt 0 ]]; then
            echo -e "${YELLOW}Note: There are $CHECKS_WARNING warnings to review above.${NC}"
        fi
    else
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}✗ Suricata has $CHECKS_FAILED critical issues that need attention!${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Review the failures above and apply the suggested fixes."
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   NFTBan v1.0 - Suricata Troubleshooting & Verification${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Run all checks
    check_binary || true
    check_service || true
    check_config || true
    check_rules || true
    check_logging || true
    check_resources || true
    check_network_test || true
    check_nftban_integration || true

    # Print summary
    print_summary

    # Exit code based on failures
    if [[ $CHECKS_FAILED -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
