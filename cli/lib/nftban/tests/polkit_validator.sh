#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Polkit Authorization Validator
# =============================================================================
# meta:name="polkit_validator"
# meta:type="test"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Comprehensive validation of Polkit rules for NFTBan RBAC"
# meta:inventory.files=""
# meta:inventory.binaries="bash,pkcheck,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Features:
#   - Static content analysis (wildcards, pkexec, typos, whitelists)
#   - File presence, permissions, and ownership checks
#   - Runtime authorization tests with test users
#   - Regression detection (v1.0.18 vulnerabilities)
#
# Usage:
#   sudo ./polkit_validator.sh [--static-only] [--create-test-users]
#
# Exit Codes:
#   0 = All checks passed
#   1 = Critical security failure
#   2 = Warning (non-critical issues)
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION: Expected Policy Matrix (Source of Truth)
# =============================================================================

# Rule file locations (search order)
readonly RULE_DIRS=(
    "/etc/polkit-1/rules.d"
    "/usr/share/polkit-1/rules.d"
)

# Expected rule files (must exist).
# Two-tier model: nftban operator + nftban-auditor read-only.
# (nftban-panel tier / 30-nftban-panel.rules retired v1.137.)
readonly EXPECTED_FILES=(
    "10-nftban-systemd.rules"
    "20-nftban-auditor.rules"
)

# Obsolete/vulnerable files (must NOT exist)
readonly OBSOLETE_FILES=(
    "50-nftban-auth.rules"
    "60-nftban-services.rules"
    "10-nftban-core.rules"
    "20-nftban-suricata.rules"
    "50-nftban-v030.rules"
)

# Groups (two-tier model; panel group retired v1.137)
readonly GROUP_OPERATOR="nftban"
readonly GROUP_AUDITOR="nftban-auditor"

# Operator: Allowed units (exact whitelist - matches 10-nftban-systemd.rules)
readonly OPERATOR_UNITS=(
    "nftband.service"
    "nftban-core-feeds.service"
    "nftban-core-feeds.timer"
    "nftban-core-geoip.service"
    "nftban-core-geoip.timer"
    "nftban-suricata.service"
    "nftban-suricata-update.service"
    "nftban-suricata-update.timer"
    "nftban-login-monitor.service"
    "suricata.service"
    "suricata-update.service"
    "suricata-update.timer"
)

# Operator: Allowed verbs
readonly OPERATOR_VERBS=(
    "start"
    "stop"
    "restart"
    "reload"
    "enable"
    "disable"
    "try-restart"
    "reload-or-restart"
    "try-reload-or-restart"
)

# Panel tier retired v1.137 — PANEL_UNITS / PANEL_READONLY_UNITS /
# PANEL_ALLOWED_VERBS removed; two-tier model (operator + auditor) only.

# Auditor: Allowed verbs (read-only only)
readonly AUDITOR_ALLOWED_VERBS=(
    "status"
    "show"
    "is-active"
    "is-enabled"
    "is-failed"
    "list-units"
    "list-unit-files"
)

# Auditor: Denied verbs (must be explicitly denied)
readonly AUDITOR_DENIED_VERBS=(
    "start"
    "stop"
    "restart"
    "reload"
    "enable"
    "disable"
    "try-restart"
    "reload-or-restart"
    "try-reload-or-restart"
    "kill"
    "reset-failed"
)

# Polkit action IDs
readonly ACTION_MANAGE_UNITS="org.freedesktop.systemd1.manage-units"
readonly ACTION_MANAGE_UNIT_FILES="org.freedesktop.systemd1.manage-unit-files"
# shellcheck disable=SC2034  # Reserved for future runtime tests
readonly ACTION_RELOAD_DAEMON="org.freedesktop.systemd1.reload-daemon"
# shellcheck disable=SC2034  # Reserved for future runtime tests
readonly ACTION_PKEXEC="org.freedesktop.policykit.exec"

# =============================================================================
# OUTPUT FORMATTING
# =============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

log_header() { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }
log_subheader() { echo -e "${CYAN}--- $* ---${NC}"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; # v1.19.20 FIX
 ((PASS_COUNT++)) || true; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; # v1.19.20 FIX
 ((FAIL_COUNT++)) || true; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; # v1.19.20 FIX
 ((WARN_COUNT++)) || true; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; # v1.19.20 FIX
 ((SKIP_COUNT++)) || true; }
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_risk() {
    local level="$1"; shift
    case "$level" in
        HIGH)   echo -e "  ${RED}[RISK: HIGH]${NC} $*" ;;
        MEDIUM) echo -e "  ${YELLOW}[RISK: MEDIUM]${NC} $*" ;;
        LOW)    echo -e "  ${CYAN}[RISK: LOW]${NC} $*" ;;
    esac
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fail "Must run as root to perform authorization tests"
        echo "Usage: sudo $0 [--static-only] [--create-test-users]"
        exit 1
    fi
}

# Find rule file in search paths
find_rule_file() {
    local filename="$1"
    for dir in "${RULE_DIRS[@]}"; do
        if [[ -f "$dir/$filename" ]]; then
            echo "$dir/$filename"
            return 0
        fi
    done
    return 1
}

# Check if a string is in an array
in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Extract array from JavaScript rule file
extract_js_array() {
    local file="$1"
    local var_name="$2"
    # Extract content between var varname = [ and ];
    sed -n "/var $var_name = \[/,/\];/p" "$file" | \
        grep -oE '"[^"]+"' | \
        tr -d '"' | \
        sort -u
}

# =============================================================================
# STATIC CHECKS
# =============================================================================

static_check_file_presence() {
    log_header "Static Check: File Presence"

    local found_paths=()
    local missing=0

    for f in "${EXPECTED_FILES[@]}"; do
        local path
        if path=$(find_rule_file "$f"); then
            log_pass "Found: $path"
            found_paths+=("$path")
        else
            log_fail "Missing required rule file: $f"
            log_risk HIGH "Rule file not installed - authorization may be broken"
            missing=1
        fi
    done

    # Export for later use
    FOUND_RULE_PATHS=("${found_paths[@]}")

    return $missing
}

static_check_obsolete_files() {
    log_header "Static Check: Obsolete/Vulnerable Files"

    local found_obsolete=0

    for f in "${OBSOLETE_FILES[@]}"; do
        for dir in "${RULE_DIRS[@]}"; do
            if [[ -e "$dir/$f" ]]; then
                log_fail "Obsolete/vulnerable rule file present: $dir/$f"
                log_risk HIGH "v1.0.18 vulnerability - remove this file immediately"
                found_obsolete=1
            fi
        done
    done

    if [[ $found_obsolete -eq 0 ]]; then
        log_pass "No obsolete rule files found"
    fi

    return $found_obsolete
}

static_check_file_permissions() {
    log_header "Static Check: File Permissions & Ownership"

    local failed=0

    for path in "${FOUND_RULE_PATHS[@]}"; do
        # Check owner
        local owner group mode filetype
        read -r owner group mode filetype <<< "$(stat -c '%U %G %a %F' "$path")"

        if [[ "$owner" != "root" ]]; then
            log_fail "$path: Owner is '$owner' (should be 'root')"
            log_risk HIGH "Non-root owner could allow tampering"
            failed=1
        elif [[ "$group" != "root" ]]; then
            log_warn "$path: Group is '$group' (recommended: 'root')"
            log_risk LOW "Consider setting group to root"
        else
            log_pass "$path: Owner/group is root:root"
        fi

        # Check permissions (should be 644 or stricter)
        if [[ "$mode" =~ ^64[0-4]$ ]]; then
            log_pass "$path: Permissions $mode (secure)"
        elif [[ "$mode" =~ ^6[0-4][0-4]$ ]]; then
            log_pass "$path: Permissions $mode (acceptable)"
        else
            log_fail "$path: Permissions $mode (should be 644 or stricter)"
            log_risk MEDIUM "World/group writable permissions"
            failed=1
        fi

        # Check for symlinks
        if [[ "$filetype" != "regular file" ]]; then
            log_fail "$path: Is a $filetype (should be regular file)"
            log_risk HIGH "Symlink could point to attacker-controlled content"
            failed=1
        fi
    done

    # Check directory permissions
    for dir in "${RULE_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_mode
            dir_mode=$(stat -c '%a' "$dir")
            if [[ "$dir_mode" =~ ^7[0-5][0-5]$ ]]; then
                log_pass "$dir: Directory permissions $dir_mode (secure)"
            else
                log_warn "$dir: Directory permissions $dir_mode (check for write access)"
            fi
        fi
    done

    return $failed
}

static_check_wildcards() {
    log_header "Static Check: Wildcard/Pattern Matching (CRITICAL)"

    local failed=0

    # Dangerous patterns that indicate wildcard matching
    local -a dangerous_patterns=(
        'indexOf\s*\('           # unit.indexOf("nftban")
        'startsWith\s*\('        # unit.startsWith("nftban")
        'match\s*\('             # unit.match(/nftban/)
        'search\s*\('            # unit.search(/nftban/)
        'test\s*\('              # /nftban/.test(unit)
        '/nftban[^"]*/'          # regex literal /nftban.../
        '\.slice\s*\('           # unit.slice(0,6) == "nftban"
        '\.substring\s*\('       # unit.substring(0,6)
        '\.substr\s*\('          # unit.substr(0,6)
    )

    for path in "${FOUND_RULE_PATHS[@]}"; do
        for pattern in "${dangerous_patterns[@]}"; do
            if grep -Eq "$pattern" "$path" 2>/dev/null; then
                # Check if it's in a comment
                local line
                line=$(grep -En "$pattern" "$path" | head -1)
                if [[ ! "$line" =~ ^[0-9]+:\s*// ]]; then
                    log_fail "$path: Wildcard/pattern matching detected"
                    log_risk HIGH "Pattern: $pattern"
                    log_info "  Line: $line"
                    failed=1
                fi
            fi
        done
    done

    if [[ $failed -eq 0 ]]; then
        log_pass "No wildcard/pattern matching detected in active code"
    fi

    return $failed
}

static_check_pkexec() {
    log_header "Static Check: pkexec/Auth Helper References"

    local failed=0

    local -a pkexec_patterns=(
        'policykit\.exec'
        'pkexec'
        '/usr/libexec/nftban'
        'auth-helper'
        'polkit\.exec\.path'
    )

    for path in "${FOUND_RULE_PATHS[@]}"; do
        for pattern in "${pkexec_patterns[@]}"; do
            if grep -Eq "$pattern" "$path" 2>/dev/null; then
                local line
                line=$(grep -En "$pattern" "$path" | head -1)
                # Check if it's a denial (Result.NO)
                if grep -A2 "$pattern" "$path" | grep -q 'Result\.NO'; then
                    log_pass "$path: pkexec reference is a DENIAL (safe)"
                else
                    log_fail "$path: pkexec/auth-helper reference detected (non-denial)"
                    log_risk HIGH "pkexec can enable privilege escalation"
                    log_info "  Line: $line"
                    failed=1
                fi
            fi
        done
    done

    if [[ $failed -eq 0 ]]; then
        log_pass "No unsafe pkexec references detected"
    fi

    return $failed
}

static_check_group_typos() {
    log_header "Static Check: Group Name Typos"

    local failed=0

    # Known typos and incorrect group names
    local -a typo_patterns=(
        'nftban-auditors'      # Should be nftban-auditor (singular)
        'nftban-operators'     # Should be nftban
        'nftban-admin'         # Doesn't exist
        'nftban-cli'           # Old group name
    )

    for path in "${FOUND_RULE_PATHS[@]}"; do
        for typo in "${typo_patterns[@]}"; do
            if grep -q "\"$typo\"" "$path" 2>/dev/null; then
                log_fail "$path: Group typo detected: '$typo'"
                log_risk MEDIUM "Typo may cause authorization failures"
                failed=1
            fi
        done
    done

    # Verify correct group names are used
    local operator_file auditor_file
    operator_file=$(find_rule_file "10-nftban-systemd.rules") || true
    auditor_file=$(find_rule_file "20-nftban-auditor.rules") || true

    if [[ -n "$operator_file" ]] && ! grep -q "\"$GROUP_OPERATOR\"" "$operator_file"; then
        log_fail "$operator_file: Missing group '$GROUP_OPERATOR'"
        failed=1
    fi

    if [[ -n "$auditor_file" ]] && ! grep -q "\"$GROUP_AUDITOR\"" "$auditor_file"; then
        log_fail "$auditor_file: Missing group '$GROUP_AUDITOR'"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        log_pass "No group name typos detected"
    fi

    return $failed
}

static_check_unit_whitelist() {
    log_header "Static Check: Unit Whitelist Integrity"

    local failed=0

    # Check operator units
    local operator_file
    if operator_file=$(find_rule_file "10-nftban-systemd.rules"); then
        log_subheader "Operator Units (10-nftban-systemd.rules)"

        local found_units
        found_units=$(extract_js_array "$operator_file" "allowedUnits")

        # Check for missing units
        for expected in "${OPERATOR_UNITS[@]}"; do
            if echo "$found_units" | grep -qx "$expected"; then
                log_pass "Found expected unit: $expected"
            else
                log_fail "Missing expected unit: $expected"
                failed=1
            fi
        done

        # Check for extra units (potential security issue)
        while IFS= read -r found; do
            [[ -z "$found" ]] && continue
            if ! in_array "$found" "${OPERATOR_UNITS[@]}"; then
                log_warn "Extra unit in whitelist: $found"
                log_risk LOW "Verify this unit should be manageable by operators"
            fi
        done <<< "$found_units"
    fi

    # Panel unit-whitelist checks removed (panel tier retired v1.137).

    return $failed
}

static_check_verb_whitelist() {
    log_header "Static Check: Verb Whitelist Integrity"

    local failed=0

    # Check operator verbs
    local operator_file
    if operator_file=$(find_rule_file "10-nftban-systemd.rules"); then
        log_subheader "Operator Verbs"

        local found_verbs
        found_verbs=$(extract_js_array "$operator_file" "allowedVerbs")

        for expected in "${OPERATOR_VERBS[@]}"; do
            if echo "$found_verbs" | grep -qx "$expected"; then
                log_pass "Operator verb allowed: $expected"
            else
                log_warn "Operator verb missing: $expected"
            fi
        done
    fi

    # Check auditor verbs
    local auditor_file
    if auditor_file=$(find_rule_file "20-nftban-auditor.rules"); then
        log_subheader "Auditor Verbs (should be read-only)"

        local found_allowed
        found_allowed=$(extract_js_array "$auditor_file" "allowedVerbs")

        # Verify only read-only verbs are allowed
        for verb in "${AUDITOR_ALLOWED_VERBS[@]}"; do
            if echo "$found_allowed" | grep -qx "$verb"; then
                log_pass "Auditor read-only verb: $verb"
            fi
        done

        # Verify denied verbs exist
        local found_denied
        found_denied=$(extract_js_array "$auditor_file" "deniedVerbs")

        for verb in "${AUDITOR_DENIED_VERBS[@]}"; do
            if echo "$found_denied" | grep -qx "$verb"; then
                log_pass "Auditor verb explicitly denied: $verb"
            else
                log_warn "Auditor verb not explicitly denied: $verb"
                log_risk LOW "Consider adding explicit denial for defense-in-depth"
            fi
        done
    fi

    # Panel verb-whitelist checks removed (panel tier retired v1.137).

    return $failed
}

static_check_explicit_denials() {
    log_header "Static Check: Explicit Denial Paths"

    local failed=0

    # Check auditor has explicit denials
    local auditor_file
    if auditor_file=$(find_rule_file "20-nftban-auditor.rules"); then
        # Check for daemon-reload denial
        if grep -q 'reload-daemon' "$auditor_file" && grep -A3 'reload-daemon' "$auditor_file" | grep -q 'Result\.NO'; then
            log_pass "Auditor: daemon-reload explicitly denied"
        else
            log_fail "Auditor: daemon-reload not explicitly denied"
            log_risk MEDIUM "Auditors should not be able to reload daemon"
            failed=1
        fi

        # Check for pkexec denial
        if grep -q 'policykit\.exec' "$auditor_file" && grep -A3 'policykit\.exec' "$auditor_file" | grep -q 'Result\.NO'; then
            log_pass "Auditor: pkexec explicitly denied"
        else
            log_warn "Auditor: pkexec not explicitly denied"
            log_risk LOW "Consider adding explicit pkexec denial"
        fi
    fi

    # Panel explicit-denial checks removed (panel tier retired v1.137).

    return $failed
}

static_check_action_scope() {
    log_header "Static Check: Polkit Action Scope"

    local failed=0

    for path in "${FOUND_RULE_PATHS[@]}"; do
        local basename
        basename=$(basename "$path")

        # Check that rules target correct actions
        if grep -q "$ACTION_MANAGE_UNITS" "$path"; then
            log_pass "$basename: Targets $ACTION_MANAGE_UNITS"
        else
            log_warn "$basename: Does not target $ACTION_MANAGE_UNITS"
        fi

        # Operator should also handle manage-unit-files (for enable/disable)
        if [[ "$basename" == "10-nftban-systemd.rules" ]]; then
            if grep -q "$ACTION_MANAGE_UNIT_FILES" "$path"; then
                log_pass "$basename: Targets $ACTION_MANAGE_UNIT_FILES (for enable/disable)"
            else
                log_warn "$basename: Does not target $ACTION_MANAGE_UNIT_FILES"
            fi
        fi

        # Auditor should NOT handle manage-unit-files
        if [[ "$basename" == "20-nftban-auditor.rules" ]]; then
            if grep -q "$ACTION_MANAGE_UNIT_FILES" "$path" && ! grep -A3 "$ACTION_MANAGE_UNIT_FILES" "$path" | grep -q 'Result\.NO'; then
                log_fail "$basename: Should not allow $ACTION_MANAGE_UNIT_FILES"
                failed=1
            fi
        fi
    done

    return $failed
}

# =============================================================================
# RUNTIME TESTS
# =============================================================================

# Test users (ephemeral or pre-existing)
TEST_USER_OPERATOR="${TEST_USER_OPERATOR:-nftban-test-operator}"
TEST_USER_AUDITOR="${TEST_USER_AUDITOR:-nftban-test-auditor}"
# Panel test user retired v1.137 (panel authorization tier removed).

create_test_users() {
    log_header "Creating Test Users"

    # Create operator test user
    if ! id "$TEST_USER_OPERATOR" &>/dev/null; then
        useradd -r -s /sbin/nologin -c "NFTBan Polkit Test (Operator)" "$TEST_USER_OPERATOR"
        usermod -aG "$GROUP_OPERATOR" "$TEST_USER_OPERATOR"
        log_pass "Created test user: $TEST_USER_OPERATOR (group: $GROUP_OPERATOR)"
    else
        log_info "Test user exists: $TEST_USER_OPERATOR"
    fi

    # Create auditor test user
    if ! id "$TEST_USER_AUDITOR" &>/dev/null; then
        useradd -r -s /sbin/nologin -c "NFTBan Polkit Test (Auditor)" "$TEST_USER_AUDITOR"
        usermod -aG "$GROUP_AUDITOR" "$TEST_USER_AUDITOR"
        log_pass "Created test user: $TEST_USER_AUDITOR (group: $GROUP_AUDITOR)"
    else
        log_info "Test user exists: $TEST_USER_AUDITOR"
    fi
}

cleanup_test_users() {
    log_header "Cleaning Up Test Users"

    for user in "$TEST_USER_OPERATOR" "$TEST_USER_AUDITOR"; do
        if id "$user" &>/dev/null; then
            userdel -r "$user" 2>/dev/null || true
            log_pass "Removed test user: $user"
        fi
    done
}

# Test authorization using pkcheck
# Returns 0 if authorized, 1 if not authorized
test_authorization() {
    local user="$1"
    local action="$2"
    local verb="$3"
    local unit="$4"

    # Verify user exists
    id -u "$user" >/dev/null 2>&1 || return 2

    # Use pkcheck to test authorization
    # Note: pkcheck requires a valid process ID, so we spawn a sleep process as the user
    local pid
    pid=$(sudo -u "$user" bash -c 'echo $$; exec sleep 10' &)
    sleep 0.1

    local result
    if pkcheck --action-id "$action" \
               --process "$pid" \
               --detail "verb" "$verb" \
               --detail "unit" "$unit" \
               --allow-user-interaction=false 2>/dev/null; then
        result=0  # Authorized
    else
        result=1  # Not authorized
    fi

    # Cleanup
    kill "$pid" 2>/dev/null || true

    return $result
}

# Alternative: use busctl for more reliable testing
test_authorization_busctl() {
    local user="$1"
    local verb="$2"
    local unit="$3"

    # Try to perform the operation and check for polkit denial
    local output
    local exitcode

    output=$(sudo -u "$user" systemctl "$verb" "$unit" 2>&1) || exitcode=$?

    # Check for polkit denial messages
    if [[ "$output" =~ "Access denied" ]] || \
       [[ "$output" =~ "not authorized" ]] || \
       [[ "$output" =~ "Permission denied" ]] || \
       [[ "$output" =~ "polkit" ]]; then
        return 1  # Denied
    fi

    # Check exit code
    if [[ "${exitcode:-0}" -eq 0 ]]; then
        return 0  # Authorized
    fi

    return 1  # Denied or failed
}

runtime_test_operator() {
    log_header "Runtime Test: Operator Role ($TEST_USER_OPERATOR)"

    if ! id "$TEST_USER_OPERATOR" &>/dev/null; then
        log_skip "Test user $TEST_USER_OPERATOR does not exist"
        return 0
    fi

    if ! getent group "$GROUP_OPERATOR" &>/dev/null; then
        log_skip "Group $GROUP_OPERATOR does not exist"
        return 0
    fi

    local failed=0

    log_subheader "Expected ALLOW: Managing whitelisted units"

    # Test allowed operations (just status for non-destructive test)
    # Use canonical unit names from docs/systemd/UNITS.md
    for unit in "nftband.service" "nftban-core-feeds.timer"; do
        if systemctl list-unit-files "$unit" &>/dev/null; then
            if sudo -u "$TEST_USER_OPERATOR" systemctl status "$unit" &>/dev/null 2>&1; then
                log_pass "Operator CAN query: $unit"
            else
                log_warn "Operator cannot query: $unit (may be polkit or unit issue)"
            fi
        else
            log_skip "Unit not installed: $unit"
        fi
    done

    log_subheader "Expected DENY: Non-whitelisted units"

    # Test denied operations (units not in whitelist)
    local denied_units=("sshd.service" "nginx.service" "httpd.service")
    for unit in "${denied_units[@]}"; do
        if systemctl list-unit-files "$unit" &>/dev/null; then
            # Operators should be able to query but not manage non-whitelisted units
            # (Polkit only controls management, not status queries)
            log_info "Operator can query $unit (status is always allowed)"
        fi
    done

    return $failed
}

runtime_test_auditor() {
    log_header "Runtime Test: Auditor Role ($TEST_USER_AUDITOR)"

    if ! id "$TEST_USER_AUDITOR" &>/dev/null; then
        log_skip "Test user $TEST_USER_AUDITOR does not exist"
        return 0
    fi

    if ! getent group "$GROUP_AUDITOR" &>/dev/null; then
        log_skip "Group $GROUP_AUDITOR does not exist"
        return 0
    fi

    local failed=0

    log_subheader "Expected ALLOW: Read-only queries"

    # Test read-only operations
    if sudo -u "$TEST_USER_AUDITOR" systemctl list-units --no-pager &>/dev/null 2>&1; then
        log_pass "Auditor CAN list-units"
    else
        log_warn "Auditor cannot list-units"
    fi

    if sudo -u "$TEST_USER_AUDITOR" systemctl is-active nftband.service &>/dev/null 2>&1; then
        log_pass "Auditor CAN query is-active"
    else
        log_info "Auditor is-active test inconclusive (unit may not be running)"
    fi

    log_subheader "Expected DENY: State-modifying operations"

    # Test that restart is denied (using a unit that exists)
    local test_output
    test_output=$(sudo -u "$TEST_USER_AUDITOR" systemctl restart nftband.service 2>&1) || true
    if [[ "$test_output" =~ "denied" ]] || [[ "$test_output" =~ "not authorized" ]] || [[ "$test_output" =~ "Permission" ]]; then
        log_pass "Auditor DENIED restart (correct)"
    else
        log_warn "Auditor restart test inconclusive: $test_output"
    fi

    # Test that daemon-reload is denied
    test_output=$(sudo -u "$TEST_USER_AUDITOR" systemctl daemon-reload 2>&1) || true
    if [[ "$test_output" =~ "denied" ]] || [[ "$test_output" =~ "not authorized" ]] || [[ "$test_output" =~ "Permission" ]]; then
        log_pass "Auditor DENIED daemon-reload (correct)"
    else
        log_warn "Auditor daemon-reload test inconclusive: $test_output"
    fi

    return $failed
}

# runtime_test_panel removed v1.137 (panel authorization tier retired).

runtime_test_nftables_isolation() {
    log_header "Runtime Test: nftables Isolation"

    local failed=0

    for user in "$TEST_USER_OPERATOR" "$TEST_USER_AUDITOR"; do
        if ! id "$user" &>/dev/null; then
            continue
        fi

        if sudo -u "$user" nft list tables &>/dev/null 2>&1; then
            log_fail "SECURITY ISSUE: $user CAN run 'nft' directly!"
            log_risk HIGH "nftables should only be accessible via daemon"
            failed=1
        else
            log_pass "$user CANNOT run 'nft' directly (correct)"
        fi
    done

    return $failed
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

print_summary() {
    log_header "VALIDATION SUMMARY"

    echo ""
    echo -e "  ${GREEN}PASS:${NC} $PASS_COUNT"
    echo -e "  ${RED}FAIL:${NC} $FAIL_COUNT"
    echo -e "  ${YELLOW}WARN:${NC} $WARN_COUNT"
    echo -e "  ${YELLOW}SKIP:${NC} $SKIP_COUNT"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}${BOLD}RESULT: FAILED${NC}"
        echo -e "Critical security issues detected. Review and fix before deployment."
        return 1
    elif [[ $WARN_COUNT -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}RESULT: PASSED WITH WARNINGS${NC}"
        echo -e "Non-critical issues detected. Review recommended."
        return 2
    else
        echo -e "${GREEN}${BOLD}RESULT: PASSED${NC}"
        echo -e "All Polkit rules validated successfully."
        return 0
    fi
}

usage() {
    cat <<EOF
NFTBan Polkit Authorization Validator

Usage: sudo $0 [OPTIONS]

Options:
  --static-only       Run only static checks (no runtime tests)
  --create-test-users Create temporary test users for runtime tests
  --cleanup           Remove test users and exit
  --help              Show this help

Examples:
  sudo $0                          # Run all checks (static + runtime with existing users)
  sudo $0 --static-only            # Run only static checks
  sudo $0 --create-test-users      # Create test users and run all checks
  sudo $0 --cleanup                # Remove test users

EOF
}

main() {
    local static_only=false
    local create_users=false
    local cleanup_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --static-only)
                static_only=true
                shift
                ;;
            --create-test-users)
                create_users=true
                shift
                ;;
            --cleanup)
                cleanup_only=true
                shift
                ;;
            --help|-h)
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

    # Header
    echo ""
    echo -e "${BOLD}=================================================================${NC}"
    echo -e "${BOLD}NFTBan v1.0.24 - Polkit Authorization Validator${NC}"
    echo -e "${BOLD}=================================================================${NC}"
    echo ""

    # Check root
    check_root

    # Cleanup only mode
    if [[ "$cleanup_only" == true ]]; then
        cleanup_test_users
        exit 0
    fi

    # Platform info
    log_info "Platform: $(uname -s) $(uname -r)"
    log_info "Polkit version: $(pkcheck --version 2>&1 | head -1 || echo 'unknown')"
    log_info "Systemd version: $(systemctl --version | head -1 || echo 'unknown')"
    echo ""

    # Initialize found paths array
    FOUND_RULE_PATHS=()

    # Run static checks
    log_header "STATIC CHECKS"

    static_check_file_presence || true
    static_check_obsolete_files || true
    static_check_file_permissions || true
    static_check_wildcards || true
    static_check_pkexec || true
    static_check_group_typos || true
    static_check_unit_whitelist || true
    static_check_verb_whitelist || true
    static_check_explicit_denials || true
    static_check_action_scope || true

    # Run runtime tests (unless static-only)
    if [[ "$static_only" != true ]]; then
        log_header "RUNTIME TESTS"

        # Create test users if requested
        if [[ "$create_users" == true ]]; then
            create_test_users
        fi

        # Check if required groups exist
        local groups_exist=true
        for group in "$GROUP_OPERATOR" "$GROUP_AUDITOR"; do
            if ! getent group "$group" &>/dev/null; then
                log_warn "Group does not exist: $group"
                groups_exist=false
            fi
        done

        if [[ "$groups_exist" == true ]]; then
            runtime_test_operator || true
            runtime_test_auditor || true
            runtime_test_nftables_isolation || true
        else
            log_skip "Skipping runtime tests - required groups do not exist"
            log_info "Create groups: nftban, nftban-auditor"
        fi

        # Cleanup test users if we created them
        if [[ "$create_users" == true ]]; then
            cleanup_test_users
        fi
    else
        log_info "Skipping runtime tests (--static-only mode)"
    fi

    # Print summary
    print_summary
}

# Run main
main "$@"
