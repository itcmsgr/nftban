#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.10 whitelist management tier (WL-MANAGEMENT / Scenario-A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_whitelist_management_v218_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-08"
# meta:description="Tests for v1.218.10 nftban whitelist management permanent tier. Asserts add writes whitelist.d/99-management.conf with NO EXPIRES_AT (durable — survives 00-session expiry because it is a different, never-reaped tier), re-adding refreshes (no dup), remove drops the durable line, invalid IP rejected, over-broad /0 (0.0.0.0/0 and ::/0) refused, v4+v6 parity, ensure-header never clobbers an existing file, list shows entries, and status reports PRESENT/MISSING drift (rc1 on missing). Never-ban exemption + session-reaper non-interference + live-apply are lab integration tests (the resolver/reaper are Go)."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. We extract the
# v1.218.10 management functions (+ shared helpers) from cmd_whitelist.sh by name,
# patch out the `[[ $EUID -ne 0 ]]` root guards, redirect $_NFTBAN_MGMT_WHITELIST_PATH
# to a tempfile, and stub the leaf helpers (validation, runtime remove, live-check).
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
WL_SRC="$NFTBAN_LIB_DIR/cli/cmd_whitelist.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
MGMT_FILE="$SANDBOX/99-management.conf"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [FAIL] %s\n         did NOT expect: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    else
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    fi
}
assert_rc() {
    local rc="$1" expected="$2" name="$3"
    if [[ "$rc" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected rc %s, got %s)\n" "$name" "$expected" "$rc"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# Harness: load the management functions in a subshell with stubs.
#   _STUB_LIVE_RC controls the stubbed _nftban_wl_static_is_live return code
#   (0=live/PRESENT, 1=not-live/MISSING, 2=unknown).
# ---------------------------------------------------------------------------
mgmt_env() {
    local live_rc="${1:-0}"
    cat <<STUBS
nftban_validate_ip()   { [[ "\$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}\$ ]] || { [[ "\$1" == *:* && "\$1" =~ ^[0-9a-fA-F:]+\$ ]]; }; }
nftban_validate_cidr() { [[ "\$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\$ ]] || { [[ "\$1" == *:* && "\$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}\$ ]]; }; }
nftban_whitelist_remove_ip() { return 0; }
_nftban_wl_static_is_live() { return ${live_rc}; }
STUBS
    # Extract the management block; the shared _NFTBAN_MGMT_WHITELIST_PATH..usage
    # functions live between the WL-MANAGEMENT banner and "# List whitelisted IPs".
    awk '/^# v1.218.10 — PERMANENT MANAGEMENT/{c=1} /^# List whitelisted IPs/{c=0} c{print}' "$WL_SRC" \
        | sed -E 's@\[\[ \$EUID -ne 0 \]\]@[[ 1 -eq 0 ]]@g'
    printf '_NFTBAN_MGMT_WHITELIST_PATH=%q\n' "$MGMT_FILE"
}

run_mgmt() {
    # $1 = live_rc for the stub; rest = args after `run_mgmt <rc> <func> ...`
    local live_rc="$1"; shift
    bash -c "$(mgmt_env "$live_rc"); set +e; \"\$@\"" _ "$@"
}

echo "=== v1.218.10 whitelist management tier tests ==="

# 1. add writes a permanent (no EXPIRES_AT) entry
rm -f "$MGMT_FILE"
out=$(run_mgmt 0 nftban_whitelist_mgmt_add_ip 203.0.113.10 2>&1) || true
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "203.0.113.10" "add: entry written to 99-management.conf"
assert_not_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "EXPIRES_AT" "add: NO EXPIRES_AT (permanent, survives session expiry)"
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "REASON=management" "add: tagged REASON=management"

# 2. idempotent re-add (no duplicate)
run_mgmt 0 nftban_whitelist_mgmt_add_ip 203.0.113.10 >/dev/null 2>&1 || true
cnt=$(grep -c '^203\.0\.113\.10' "$MGMT_FILE" 2>/dev/null || echo 0)
assert_rc "$cnt" "1" "add: idempotent (no duplicate line on re-add)"

# 3. v6 parity
run_mgmt 0 nftban_whitelist_mgmt_add_ip 2001:db8::1 >/dev/null 2>&1 || true
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "2001:db8::1" "add: IPv6 parity"

# 4. reject over-broad /0
rc=0; out=$(run_mgmt 0 nftban_whitelist_mgmt_add_ip 0.0.0.0/0 2>&1) || rc=$?
assert_rc "$rc" "1" "reject: 0.0.0.0/0 refused (rc1)"
assert_contains "$out" "over-broad" "reject: 0.0.0.0/0 message"
rc=0; out=$(run_mgmt 0 nftban_whitelist_mgmt_add_ip "::/0" 2>&1) || rc=$?
assert_rc "$rc" "1" "reject: ::/0 refused (rc1)"

# 5. reject invalid IP
rc=0; out=$(run_mgmt 0 nftban_whitelist_mgmt_add_ip "not-an-ip" 2>&1) || rc=$?
assert_rc "$rc" "1" "reject: invalid IP refused (rc1)"

# 6. list shows configured entries
out=$(run_mgmt 0 nftban_whitelist_mgmt_list 2>&1) || true
assert_contains "$out" "203.0.113.10" "list: shows v4 entry"
assert_contains "$out" "2001:db8::1" "list: shows v6 entry"

# 7. status PRESENT when live (stub rc 0)
rc=0; out=$(run_mgmt 0 nftban_whitelist_mgmt_status 2>&1) || rc=$?
assert_contains "$out" "PRESENT" "status: PRESENT when live"
assert_rc "$rc" "0" "status: rc0 when all present"

# 8. status MISSING + rc1 when not live (stub rc 1)
rc=0; out=$(run_mgmt 1 nftban_whitelist_mgmt_status 2>&1) || rc=$?
assert_contains "$out" "MISSING" "status: MISSING when not live"
assert_contains "$out" "DRIFT" "status: DRIFT summary when missing"
assert_rc "$rc" "1" "status: rc1 on drift (lockout risk surfaced)"

# 9. remove drops the durable line
run_mgmt 0 nftban_whitelist_mgmt_remove_ip 203.0.113.10 >/dev/null 2>&1 || true
assert_not_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "203.0.113.10" "remove: durable line dropped"
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "2001:db8::1" "remove: other entries preserved"

# 10. ensure-header never clobbers an existing file
printf 'PRE-EXISTING-OPERATOR-LINE\n' > "$MGMT_FILE"
run_mgmt 0 nftban_whitelist_mgmt_add_ip 198.51.100.5 >/dev/null 2>&1 || true
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "PRE-EXISTING-OPERATOR-LINE" "ensure-header: never clobbers existing content"
assert_contains "$(cat "$MGMT_FILE" 2>/dev/null)" "198.51.100.5" "ensure-header: appends alongside existing content"

# 11. dispatcher routes `whitelist management <sub>`
disp=$(bash -c '
  source "'"$WL_SRC"'" 2>/dev/null || true
  nftban_whitelist_mgmt_add_ip()    { echo "ROUTED:add:$1"; }
  nftban_whitelist_mgmt_status()    { echo "ROUTED:status"; }
  nftban_whitelist_mgmt_usage()     { echo "ROUTED:usage"; }
  nftban_cmd_whitelist management add 10.0.0.9
  nftban_cmd_whitelist management status
  nftban_cmd_whitelist management bogus 2>/dev/null || true
' 2>&1) || true
assert_contains "$disp" "ROUTED:add:10.0.0.9" "dispatch: management add routes with arg"
assert_contains "$disp" "ROUTED:status" "dispatch: management status routes"
assert_contains "$disp" "ROUTED:usage" "dispatch: unknown subcommand -> usage"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
