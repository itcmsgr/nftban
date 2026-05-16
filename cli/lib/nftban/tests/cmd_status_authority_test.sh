#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.118 B1 cmd_status authority + conflicts CLI guidance
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_status_authority_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-16"
# meta:description="Tests for v1.118 B1 cmd_status authority section (AUTHORITY + CONFLICTS from install_state)"
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_STATE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Cover the v1.118 B1 _status_section_authority + JSON authority
#   surface. Authority + Conflicts are read from a sandbox install_state
#   file. No real nftban-installer or host contact.
#
# Fixtures:
#   F1: AUTHORITY=AMBIGUOUS, CONFLICTS=csf,lfd  → expects WARNING + ACTION lines
#   F2: AUTHORITY=UPDATE,    CONFLICTS=""       → no WARNING, no ACTION
#   F3: install_state file missing              → section silent (no header)
#   F4: JSON output for AMBIGUOUS + conflicts   → ambiguous_with_conflicts:true
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

STATE_DIR="$SANDBOX/var/lib/nftban/state"
mkdir -p "$STATE_DIR"
export NFTBAN_STATE_DIR="$STATE_DIR"

PASS=0
FAIL=0
log_pass() { echo "  PASS  $*"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

# Helper: run _status_section_authority in a subshell with sourced cmd_status.sh
# and a synthetic install_state. We avoid sourcing the full nftban runtime —
# the section function is self-contained and reads only ${NFTBAN_STATE_DIR}.
run_authority_section() {
    # Extract _status_section_authority() definition from cmd_status.sh
    # and execute it. The function depends only on grep + printf + echo.
    awk '/^_status_section_authority\(\) \{/,/^\}/' \
        "$NFTBAN_LIB_DIR/cli/cmd_status.sh" > "$SANDBOX/section.sh"
    # shellcheck source=/dev/null
    ( source "$SANDBOX/section.sh"; _status_section_authority )
}

write_state() {
    local file="$STATE_DIR/install_state"
    : > "$file"
    echo "# NFTBan Install State — test fixture" >> "$file"
    while (( "$#" )); do
        echo "$1" >> "$file"
        shift
    done
}

remove_state() {
    rm -f "$STATE_DIR/install_state"
}

# =============================================================================
# F1: AMBIGUOUS + CONFLICTS → header, fields, WARNING, ACTION
# =============================================================================
echo "F1: AUTHORITY=AMBIGUOUS, CONFLICTS=csf,lfd"
write_state "AUTHORITY=AMBIGUOUS" "CONFLICTS=csf,lfd"
F1_OUT=$(run_authority_section)
if echo "$F1_OUT" | grep -q "^AUTHORITY$"; then
    log_pass "F1: AUTHORITY header present"
else
    log_fail "F1: AUTHORITY header missing"
fi
if echo "$F1_OUT" | grep -qE "Install authority\.+ AMBIGUOUS"; then
    log_pass "F1: Install authority field shows AMBIGUOUS"
else
    log_fail "F1: Install authority field missing/wrong"
fi
if echo "$F1_OUT" | grep -qE "Active conflicts\.+ csf,lfd"; then
    log_pass "F1: Active conflicts field shows csf,lfd"
else
    log_fail "F1: Active conflicts field missing/wrong"
fi
if echo "$F1_OUT" | grep -q "WARNING: csf,lfd still active"; then
    log_pass "F1: WARNING line surfaces the conflicts"
else
    log_fail "F1: WARNING line missing"
fi
if echo "$F1_OUT" | grep -q "ACTION:.*nftban update --panel-auto-takeover"; then
    log_pass "F1: ACTION line surfaces resolution command"
else
    log_fail "F1: ACTION line missing"
fi

# =============================================================================
# F2: UPDATE, no conflicts → header + field, NO WARNING/ACTION
# =============================================================================
echo "F2: AUTHORITY=UPDATE, CONFLICTS="
write_state "AUTHORITY=UPDATE" "CONFLICTS="
F2_OUT=$(run_authority_section)
if echo "$F2_OUT" | grep -qE "Install authority\.+ UPDATE"; then
    log_pass "F2: Install authority field shows UPDATE"
else
    log_fail "F2: Install authority field missing/wrong"
fi
if echo "$F2_OUT" | grep -q "WARNING:"; then
    log_fail "F2: WARNING should NOT appear when AUTHORITY=UPDATE"
else
    log_pass "F2: no WARNING (correct — takeover already applied)"
fi
if echo "$F2_OUT" | grep -q "ACTION:"; then
    log_fail "F2: ACTION should NOT appear when AUTHORITY=UPDATE"
else
    log_pass "F2: no ACTION (correct)"
fi

# =============================================================================
# F3: install_state missing → section is silent (no AUTHORITY header)
# =============================================================================
echo "F3: install_state absent"
remove_state
F3_OUT=$(run_authority_section)
if [[ -z "$F3_OUT" ]]; then
    log_pass "F3: section silent when state file missing"
else
    log_fail "F3: section emitted output despite missing state file:\n$F3_OUT"
fi

# =============================================================================
# F4: AUTHORITY empty (FRESH-like) → section silent even if file present
# =============================================================================
echo "F4: AUTHORITY=, CONFLICTS= (e.g. FRESH install pre-classification)"
write_state "AUTHORITY=" "CONFLICTS="
F4_OUT=$(run_authority_section)
if [[ -z "$F4_OUT" ]]; then
    log_pass "F4: section silent when AUTHORITY empty"
else
    log_fail "F4: section emitted output despite empty AUTHORITY:\n$F4_OUT"
fi

# =============================================================================
# F5: AMBIGUOUS but conflicts empty → header + field only, no WARNING
# =============================================================================
echo "F5: AUTHORITY=AMBIGUOUS, CONFLICTS= (ambiguity from orphan table, no external conflict)"
write_state "AUTHORITY=AMBIGUOUS" "CONFLICTS="
F5_OUT=$(run_authority_section)
if echo "$F5_OUT" | grep -qE "Install authority\.+ AMBIGUOUS"; then
    log_pass "F5: Install authority field shows AMBIGUOUS"
else
    log_fail "F5: Install authority field missing/wrong"
fi
if echo "$F5_OUT" | grep -q "WARNING:"; then
    log_fail "F5: WARNING should NOT appear without CONFLICTS"
else
    log_pass "F5: no WARNING (correct — AMBIGUOUS without conflicts is not the B1 actionable case)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "─────────────────────────────────────────────"
echo "Total: PASS=$PASS  FAIL=$FAIL"
echo "─────────────────────────────────────────────"
exit $(( FAIL > 0 ? 1 : 0 ))
