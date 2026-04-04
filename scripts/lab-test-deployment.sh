#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan Lab Deployment Gate Test
# =============================================================================
# meta:name="lab-test-deployment"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Runs G1-G6 deployment gates against real lab servers via SSH"
# meta:inventory.files="scripts/lab-test-deployment.sh,scripts/lab-deploy-servers.conf"
# meta:inventory.binaries="bash,ssh,scp,timeout,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files="scripts/lab-deploy-servers.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="ssh"
# meta:inventory.privileges="none"
# =============================================================================
# Runs G1-G6 deployment gates against real lab servers via SSH.
# Reads server list from lab-deploy-servers.conf and executes the gates
# assigned to each server.
#
# Usage:
#   ./scripts/lab-test-deployment.sh [OPTIONS]
#
# Options:
#   --config FILE       Server config file (default: scripts/lab-deploy-servers.conf)
#   --package-dir DIR   Directory containing .rpm/.deb packages (default: build/packages)
#   --gate G1,G4,...    Run only these gates (default: all assigned)
#   --dry-run           Show what would run without executing
#   --help              Show this help
#
# Exit codes:
#   0 = all gates passed
#   1 = one or more gates failed
#   2 = script error (bad args, missing config, etc.)
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/lab-deploy-servers.conf"
readonly DEFAULT_PKG_DIR="${SCRIPT_DIR}/../build/packages"
readonly SSH_CONNECT_TIMEOUT=15
readonly SSH_HARD_TIMEOUT=25
readonly INSTALL_TIMEOUT=120
readonly REMOTE_TMP_PREFIX="/tmp/nftban-test"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
CONFIG_FILE=""
PACKAGE_DIR=""
GATE_FILTER=""
DRY_RUN=0

# Results tracking: parallel indexed arrays
declare -a RESULT_SERVER=()
declare -a RESULT_GATE=()
declare -a RESULT_STATUS=()

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
pass()  { echo "[PASS]  $*"; }
fail()  { echo "[FAIL]  $*"; }
warn()  { echo "[WARN]  $*"; }
skip()  { echo "[SKIP]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 2; }

record_result() {
    local server="$1" gate="$2" status="$3"
    RESULT_SERVER+=("$server")
    RESULT_GATE+=("$gate")
    RESULT_STATUS+=("$status")
    case "$status" in
        PASS) TOTAL_PASS=$((TOTAL_PASS + 1)) ;;
        FAIL) TOTAL_FAIL=$((TOTAL_FAIL + 1)) ;;
        SKIP) TOTAL_SKIP=$((TOTAL_SKIP + 1)) ;;
    esac
}

# ---------------------------------------------------------------------------
# SSH / SCP wrappers
# ---------------------------------------------------------------------------
ssh_cmd() {
    local host="$1" port="$2"
    shift 2
    ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -p "$port" \
        "root@${host}" "$@"
}

scp_to() {
    local file="$1" host="$2" port="$3" dest="$4"
    scp -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -P "$port" \
        "$file" "root@${host}:${dest}"
}

check_ssh() {
    local alias="$1" host="$2" port="$3"
    info "Testing SSH to ${alias} (${host}:${port})..."
    if timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" "echo ok" >/dev/null 2>&1; then
        info "SSH OK: ${alias}"
        return 0
    else
        warn "SSH unreachable: ${alias} (${host}:${port}) — skipping"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Package detection
# ---------------------------------------------------------------------------
find_package() {
    local os_family="$1"
    local pkg_dir="$2"
    local pattern

    case "$os_family" in
        rpm) pattern="*.rpm" ;;
        deb) pattern="*.deb" ;;
        *)   die "Unknown OS family: $os_family" ;;
    esac

    # Find matching packages — prefer the most recently modified
    local found
    found=$(find "$pkg_dir" -maxdepth 2 -name "$pattern" -type f 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        die "No ${os_family} package found in ${pkg_dir}"
    fi
    echo "$found"
}

# ---------------------------------------------------------------------------
# Remote installation test runner
# ---------------------------------------------------------------------------
run_installation_test() {
    local alias="$1" host="$2" port="$3"
    local test_script="${SCRIPT_DIR}/test_installation.sh"

    if [[ ! -f "$test_script" ]]; then
        warn "test_installation.sh not found — skipping deep validation for ${alias}"
        return 0
    fi

    info "Running test_installation.sh on ${alias}..."
    local remote_script="${REMOTE_TMP_PREFIX}.$$.test.sh"

    scp_to "$test_script" "$host" "$port" "$remote_script"
    local rc=0
    timeout "${INSTALL_TIMEOUT}" ssh_cmd "$host" "$port" \
        "chmod +x '${remote_script}' && '${remote_script}'; rc=\$?; rm -f '${remote_script}'; exit \$rc" || rc=$?

    if [[ $rc -eq 0 ]]; then
        pass "test_installation.sh → 0 failures (${alias})"
    else
        fail "test_installation.sh → exit ${rc} (${alias})"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Gate implementations
# ---------------------------------------------------------------------------

gate_g1_deb_upgrade() {
    local alias="$1" host="$2" port="$3" pkg_file="$4"
    echo ""
    echo "=== G1: DEB Upgrade (${alias}) ==="

    local remote_pkg="${REMOTE_TMP_PREFIX}.$$.deb"
    info "Uploading $(basename "$pkg_file") to ${alias}..."
    scp_to "$pkg_file" "$host" "$port" "$remote_pkg"

    info "Installing via dpkg -i..."
    local rc=0
    timeout "${INSTALL_TIMEOUT}" ssh_cmd "$host" "$port" \
        "dpkg -i '${remote_pkg}'; rc=\$?; rm -f '${remote_pkg}'; exit \$rc" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "dpkg exit code ${rc} (${alias})"
        record_result "$alias" "G1" "FAIL"
        return 1
    fi
    pass "dpkg exit code 0 (${alias})"

    # Verify status
    local status_out
    status_out=$(timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "nftban status 2>&1 | head -5" || true)

    if echo "$status_out" | grep -q "PROTECTED"; then
        pass "nftban status → PROTECTED (${alias})"
    else
        fail "nftban status not PROTECTED (${alias}): ${status_out}"
        record_result "$alias" "G1" "FAIL"
        return 1
    fi

    # Deep validation
    local test_rc=0
    run_installation_test "$alias" "$host" "$port" || test_rc=$?
    if [[ $test_rc -ne 0 ]]; then
        record_result "$alias" "G1" "FAIL"
        return 1
    fi

    record_result "$alias" "G1" "PASS"
    return 0
}

gate_g2_deb_upgrade_apt() {
    local alias="$1" host="$2" port="$3" pkg_file="$4"
    echo ""
    echo "=== G2: DEB Upgrade via apt (${alias}) ==="

    local remote_pkg="${REMOTE_TMP_PREFIX}.$$.deb"
    info "Uploading $(basename "$pkg_file") to ${alias}..."
    scp_to "$pkg_file" "$host" "$port" "$remote_pkg"

    info "Installing via apt-get install..."
    local rc=0
    timeout "${INSTALL_TIMEOUT}" ssh_cmd "$host" "$port" \
        "apt-get install -y '${remote_pkg}'; rc=\$?; rm -f '${remote_pkg}'; exit \$rc" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "apt-get exit code ${rc} (${alias})"
        record_result "$alias" "G2" "FAIL"
        return 1
    fi
    pass "apt-get exit code 0 (${alias})"

    # Verify status
    local status_out
    status_out=$(timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "nftban status 2>&1 | head -5" || true)

    if echo "$status_out" | grep -q "PROTECTED"; then
        pass "nftban status → PROTECTED (${alias})"
    else
        fail "nftban status not PROTECTED (${alias}): ${status_out}"
        record_result "$alias" "G2" "FAIL"
        return 1
    fi

    # Deep validation
    local test_rc=0
    run_installation_test "$alias" "$host" "$port" || test_rc=$?
    if [[ $test_rc -ne 0 ]]; then
        record_result "$alias" "G2" "FAIL"
        return 1
    fi

    record_result "$alias" "G2" "PASS"
    return 0
}

gate_g3_deb_takeover() {
    local alias="$1" host="$2" port="$3" pkg_file="$4"
    echo ""
    echo "=== G3: DEB Takeover (${alias}) ==="

    local remote_pkg="${REMOTE_TMP_PREFIX}.$$.deb"
    info "Uploading $(basename "$pkg_file") to ${alias}..."
    scp_to "$pkg_file" "$host" "$port" "$remote_pkg"

    info "Installing with NFTBAN_TAKEOVER=1..."
    local rc=0
    timeout "${INSTALL_TIMEOUT}" ssh_cmd "$host" "$port" \
        "NFTBAN_TAKEOVER=1 dpkg -i '${remote_pkg}'; rc=\$?; rm -f '${remote_pkg}'; exit \$rc" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "takeover dpkg exit code ${rc} (${alias})"
        record_result "$alias" "G3" "FAIL"
        return 1
    fi
    pass "takeover dpkg exit code 0 (${alias})"

    # Verify status
    local status_out
    status_out=$(timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "nftban status 2>&1 | head -5" || true)

    if echo "$status_out" | grep -q "PROTECTED"; then
        pass "nftban status → PROTECTED (${alias})"
    else
        fail "nftban status not PROTECTED (${alias}): ${status_out}"
        record_result "$alias" "G3" "FAIL"
        return 1
    fi

    record_result "$alias" "G3" "PASS"
    return 0
}

gate_g4_rpm_noregress() {
    local alias="$1" host="$2" port="$3" pkg_file="$4"
    echo ""
    echo "=== G4: RPM No-Regression (${alias}) ==="

    local remote_pkg="${REMOTE_TMP_PREFIX}.$$.rpm"
    info "Uploading $(basename "$pkg_file") to ${alias}..."
    scp_to "$pkg_file" "$host" "$port" "$remote_pkg"

    info "Installing via dnf install..."
    local rc=0
    timeout "${INSTALL_TIMEOUT}" ssh_cmd "$host" "$port" \
        "dnf install -y '${remote_pkg}'; rc=\$?; rm -f '${remote_pkg}'; exit \$rc" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "dnf exit code ${rc} (${alias})"
        record_result "$alias" "G4" "FAIL"
        return 1
    fi
    pass "dnf exit code 0 (${alias})"

    # Verify status
    local status_out
    status_out=$(timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "nftban status 2>&1 | head -5" || true)

    if echo "$status_out" | grep -q "PROTECTED"; then
        pass "nftban status → PROTECTED (${alias})"
    else
        fail "nftban status not PROTECTED (${alias}): ${status_out}"
        record_result "$alias" "G4" "FAIL"
        return 1
    fi

    # Deep validation
    local test_rc=0
    run_installation_test "$alias" "$host" "$port" || test_rc=$?
    if [[ $test_rc -ne 0 ]]; then
        record_result "$alias" "G4" "FAIL"
        return 1
    fi

    record_result "$alias" "G4" "PASS"
    return 0
}

gate_g5_binary_present() {
    local alias="$1" host="$2" port="$3" os_family="$4"
    echo ""
    echo "=== G5: Installer Binary Present (${alias}) ==="

    # Check binary is executable
    local rc=0
    timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "test -x /usr/lib/nftban/bin/nftban-installer" || rc=$?

    if [[ $rc -ne 0 ]]; then
        fail "nftban-installer not executable (${alias})"
        record_result "$alias" "G5" "FAIL"
        return 1
    fi
    pass "nftban-installer is executable (${alias})"

    # Check package listing includes it
    local listing_rc=0
    case "$os_family" in
        rpm)
            timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
                "rpm -ql nftban-core 2>/dev/null | grep -q nftban-installer" || listing_rc=$?
            ;;
        deb)
            timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
                "dpkg -L nftban-core 2>/dev/null | grep -q nftban-installer" || listing_rc=$?
            ;;
    esac

    if [[ $listing_rc -eq 0 ]]; then
        pass "nftban-installer in package listing (${alias})"
    else
        warn "nftban-installer not in package listing (${alias}) — binary exists but not tracked"
    fi

    record_result "$alias" "G5" "PASS"
    return 0
}

gate_g6_installer_log() {
    local alias="$1" host="$2" port="$3"
    echo ""
    echo "=== G6: Installer Log Validation (${alias}) ==="

    # Check log file exists
    local has_log=0
    timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "test -f /var/log/nftban/installer.log" && has_log=1 || true

    if [[ $has_log -eq 0 ]]; then
        warn "No installer.log found (${alias})"
        record_result "$alias" "G6" "SKIP"
        return 0
    fi

    # Show last 5 lines
    info "Last 5 lines of installer.log:"
    timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "tail -5 /var/log/nftban/installer.log" || true

    # Check for RUN marker
    local run_marker=0
    timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "grep -q '\\[RUN\\]' /var/log/nftban/installer.log" && run_marker=1 || true

    if [[ $run_marker -eq 1 ]]; then
        pass "RUN marker present (${alias})"
    else
        warn "No RUN marker in installer.log (${alias})"
    fi

    # Check for state marker
    local state_marker=0
    timeout "${SSH_HARD_TIMEOUT}" ssh_cmd "$host" "$port" \
        "grep -q 'state=' /var/log/nftban/installer.log" && state_marker=1 || true

    if [[ $state_marker -eq 1 ]]; then
        pass "state= marker present (${alias})"
    else
        warn "No state= marker in installer.log (${alias})"
    fi

    record_result "$alias" "G6" "PASS"
    return 0
}

# ---------------------------------------------------------------------------
# Config parser
# ---------------------------------------------------------------------------
parse_config() {
    local config="$1"

    if [[ ! -f "$config" ]]; then
        die "Config file not found: $config"
    fi

    while IFS='|' read -r alias host port os_family gates enabled; do
        # Skip comments and blank lines
        [[ "$alias" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$alias" ]] && continue

        # Skip disabled
        if [[ "$enabled" != "1" ]]; then
            info "Skipping disabled server: ${alias}"
            continue
        fi

        process_server "$alias" "$host" "$port" "$os_family" "$gates"
    done < "$config"
}

# ---------------------------------------------------------------------------
# Gate filter check
# ---------------------------------------------------------------------------
gate_enabled() {
    local gate="$1"

    # No filter = all enabled
    if [[ -z "$GATE_FILTER" ]]; then
        return 0
    fi

    # Check if gate is in the filter list
    echo ",$GATE_FILTER," | grep -q ",$gate," && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Per-server orchestration
# ---------------------------------------------------------------------------
process_server() {
    local alias="$1" host="$2" port="$3" os_family="$4" gates="$5"

    echo ""
    echo "============================================================"
    echo "Server: ${alias} (${host}:${port}, ${os_family})"
    echo "Gates:  ${gates}"
    echo "============================================================"

    # SSH connectivity check
    if ! check_ssh "$alias" "$host" "$port"; then
        # Record SKIP for each gate
        IFS=',' read -ra gate_list <<< "$gates"
        for gate in "${gate_list[@]}"; do
            if gate_enabled "$gate"; then
                record_result "$alias" "$gate" "SKIP"
            fi
        done
        return 0
    fi

    # Find appropriate package
    local pkg_file=""
    if echo "$gates" | grep -qE "G[1-4]"; then
        pkg_file=$(find_package "$os_family" "$PACKAGE_DIR")
        info "Package: $(basename "$pkg_file")"
    fi

    # Run each gate
    IFS=',' read -ra gate_list <<< "$gates"
    for gate in "${gate_list[@]}"; do
        if ! gate_enabled "$gate"; then
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] Would run ${gate} on ${alias}"
            record_result "$alias" "$gate" "SKIP"
            continue
        fi

        case "$gate" in
            G1) gate_g1_deb_upgrade "$alias" "$host" "$port" "$pkg_file" || true ;;
            G2) gate_g2_deb_upgrade_apt "$alias" "$host" "$port" "$pkg_file" || true ;;
            G3) gate_g3_deb_takeover "$alias" "$host" "$port" "$pkg_file" || true ;;
            G4) gate_g4_rpm_noregress "$alias" "$host" "$port" "$pkg_file" || true ;;
            G5) gate_g5_binary_present "$alias" "$host" "$port" "$os_family" || true ;;
            G6) gate_g6_installer_log "$alias" "$host" "$port" || true ;;
            *)  warn "Unknown gate: ${gate}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================================"
    echo "DEPLOYMENT GATE SUMMARY"
    echo "============================================================"
    printf "%-12s %-6s %s\n" "SERVER" "GATE" "STATUS"
    printf "%-12s %-6s %s\n" "------" "----" "------"

    for i in "${!RESULT_SERVER[@]}"; do
        local status="${RESULT_STATUS[$i]}"
        printf "%-12s %-6s %s\n" "${RESULT_SERVER[$i]}" "${RESULT_GATE[$i]}" "$status"
    done

    echo ""
    echo "Total: ${TOTAL_PASS} PASS, ${TOTAL_FAIL} FAIL, ${TOTAL_SKIP} SKIP"
    echo "============================================================"

    if [[ $TOTAL_FAIL -gt 0 ]]; then
        echo "RESULT: FAILED"
        return 1
    else
        echo "RESULT: PASSED"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    CONFIG_FILE="$DEFAULT_CONFIG"
    PACKAGE_DIR="$DEFAULT_PKG_DIR"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                [[ $# -lt 2 ]] && die "--config requires a value"
                CONFIG_FILE="$2"
                shift 2
                ;;
            --package-dir)
                [[ $# -lt 2 ]] && die "--package-dir requires a value"
                PACKAGE_DIR="$2"
                shift 2
                ;;
            --gate)
                [[ $# -lt 2 ]] && die "--gate requires a value"
                GATE_FILTER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--config FILE] [--package-dir DIR] [--gate G1,G4,...] [--dry-run]"
                echo ""
                echo "Options:"
                echo "  --config FILE       Server config file (default: scripts/lab-deploy-servers.conf)"
                echo "  --package-dir DIR   Package directory (default: build/packages)"
                echo "  --gate G1,G4,...    Run only these gates"
                echo "  --dry-run           Show what would run"
                echo "  --help              Show this help"
                echo ""
                echo "Gates:"
                echo "  G1  DEB upgrade (dpkg -i)"
                echo "  G2  DEB upgrade (apt-get, panel server)"
                echo "  G3  DEB takeover (NFTBAN_TAKEOVER=1)"
                echo "  G4  RPM no-regression (dnf install)"
                echo "  G5  Installer binary present"
                echo "  G6  Installer log validation"
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    # Resolve relative paths
    PACKAGE_DIR="$(cd "$PACKAGE_DIR" 2>/dev/null && pwd)" || die "Package dir not found: $PACKAGE_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo "============================================================"
    echo "NFTBan Deployment Gate Test"
    echo "============================================================"
    echo "Config:      ${CONFIG_FILE}"
    echo "Packages:    ${PACKAGE_DIR}"
    echo "Gate filter: ${GATE_FILTER:-all}"
    echo "Dry run:     ${DRY_RUN}"
    echo ""

    parse_config "$CONFIG_FILE"
    print_summary
}

main "$@"
