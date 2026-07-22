#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.149.0 whitelist --static (permanent tier, WL-STATIC)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_whitelist_static_v149_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-04"
# meta:description="Tests for v1.149.0 nftban whitelist --static permanent tier. Asserts add --static writes whitelist.d/99-manual.conf with NO EXPIRES_AT (durable — the loader keeps no-EXPIRES_AT entries across rebuild), re-adding refreshes (no dup), remove --static drops the durable line, invalid IP rejected, ensure-header never clobbers an existing file, and the dispatcher routes --static/--ttl/default + the runtime-only warning correctly. Live-apply + survives-rebuild are lab integration tests."
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
# meta:ta.id="cmd_whitelist_static_v149_test"
# meta:ta.owner="whitelist"
# meta:ta.module="whitelist-static"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="deferred"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:ta.exclusion_reason="known-failing: a stale real-IP grep pattern is privacy-scrub residue that the added synthetic documentation-range IP never matches, so the duplicate-count assertion fails"
# meta:ta.activation_condition="re-enable after PR-E corrects the stale grep pattern to the synthetic fixture IP, then wire to ci-bash"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. We extract the
# v1.149 --static functions (+ dispatcher) from cmd_whitelist.sh by name, patch
# out the `[[ $EUID -ne 0 ]]` root guards, redirect $_NFTBAN_MANUAL_WHITELIST_PATH
# to a tempfile, and stub the leaf helpers (validation, runtime remove, nftban CLI).
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
MANUAL_FILE="$SANDBOX/99-manual.conf"

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
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# Harness: load the --static functions in a subshell with stubs.
# ---------------------------------------------------------------------------
static_env() {
    # Stubs (defined BEFORE eval so the real funcs call them):
    #  - validation: accept obvious IPv4/IPv6/CIDR, reject garbage.
    #  - runtime remove: no-op success (no nft/daemon in sandbox).
    #  - nftban CLI: absent (command -v nftban → false → reload skipped).
    cat <<'STUBS'
nftban_validate_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+$ ]]; }; }
nftban_validate_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; }; }
nftban_whitelist_remove_ip() { return 0; }
STUBS
    # Extract the v1.149 --static block (path var + 3 functions), patch the EUID guard.
    awk '/^_NFTBAN_MANUAL_WHITELIST_PATH=/{c=1} /^# List whitelisted IPs/{c=0} c{print}' "$WL_SRC" \
        | sed -E 's@\[\[ \$EUID -ne 0 \]\]@[[ 1 -eq 0 ]]@g'
    printf '_NFTBAN_MANUAL_WHITELIST_PATH=%q\n' "$MANUAL_FILE"
}

call_add_static()    { ( set +e; eval "$(static_env)"; nftban_whitelist_add_static_ip "$@" ); }
call_remove_static() { ( set +e; eval "$(static_env)"; nftban_whitelist_remove_static_ip "$@" ); }

echo "================================================="
echo "v1.149.0 whitelist --static (WL-STATIC) test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1: add --static creates 99-manual.conf with header + entry, NO EXPIRES_AT
# ---------------------------------------------------------------------------
echo; echo "[T1] add --static creates durable file with NO EXPIRES_AT"
rm -f "$MANUAL_FILE"
T1_OUT=$(call_add_static 192.0.2.122 2>&1)
assert_contains "$T1_OUT" "PERMANENT whitelist"                       "T1.1 stdout confirms permanent"
assert_contains "$T1_OUT" "applied it live"                          "T1.2 live-apply stated"
assert_contains "$T1_OUT" "survives firewall reload"                 "T1.2b durability stated (BUG-2: survives reload)"
[[ -f "$MANUAL_FILE" ]] && { printf "  [PASS] %s\n" "T1.3 file created"; PASS=$((PASS+1)); } \
                        || { printf "  [FAIL] %s\n" "T1.3 file created"; FAIL=$((FAIL+1)); FAILED_TESTS+=("T1.3"); }
T1C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
assert_contains "$T1C" "Permanent Whitelist (99-manual.conf)"         "T1.4 header present"
assert_contains "$T1C" "192.0.2.122"                               "T1.5 IP present"
assert_contains "$T1C" "ADDED_BY=nftban-whitelist-static"            "T1.6 traceability tag"
assert_not_contains "$T1C" "EXPIRES_AT"                              "T1.7 NO EXPIRES_AT (durable — loader keeps it across rebuild)"

# ---------------------------------------------------------------------------
# T2: re-add same IP → refresh (exactly one entry, no duplicate)
# ---------------------------------------------------------------------------
echo; echo "[T2] re-add same IP → refresh (no duplicate)"
call_add_static 192.0.2.122 >/dev/null 2>&1 || true
T2C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
T2N=$(printf '%s\n' "$T2C" | grep -c "^192\.0\.2\.250" || true)
assert_eq "$T2N" "1"                                                 "T2.1 exactly one entry for IP"

# ---------------------------------------------------------------------------
# T3: IPv6 + CIDR accepted as durable entries
# ---------------------------------------------------------------------------
echo; echo "[T3] IPv6 + CIDR durable entries"
call_add_static 2001:db8::1 >/dev/null 2>&1 || true
call_add_static 10.0.0.0/24 >/dev/null 2>&1 || true
T3C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
assert_contains "$T3C" "2001:db8::1"                                 "T3.1 IPv6 entry present"
assert_contains "$T3C" "10.0.0.0/24"                                 "T3.2 CIDR entry present"
assert_not_contains "$T3C" "EXPIRES_AT"                              "T3.3 still no EXPIRES_AT anywhere"

# ---------------------------------------------------------------------------
# T4: invalid IP rejected (no write)
# ---------------------------------------------------------------------------
echo; echo "[T4] invalid IP rejected"
T4_OUT=$(call_add_static not-an-ip 2>&1 || true)
assert_contains "$T4_OUT" "Invalid IP/CIDR"                          "T4.1 invalid IP rejected"
T4C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
assert_not_contains "$T4C" "not-an-ip"                               "T4.2 garbage not written"

# ---------------------------------------------------------------------------
# T5: remove --static drops the durable line (not resurrected on reload)
# ---------------------------------------------------------------------------
echo; echo "[T5] remove --static drops the durable entry"
T5_OUT=$(call_remove_static 192.0.2.122 2>&1)
assert_contains "$T5_OUT" "Removed 192.0.2.122 from the PERMANENT" "T5.1 stdout confirms removal"
T5C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
assert_not_contains "$T5C" "192.0.2.122"                          "T5.2 durable line gone (won't resurrect on rebuild)"
assert_contains "$T5C" "2001:db8::1"                                "T5.3 other entries untouched"

# ---------------------------------------------------------------------------
# T6: remove --static on absent IP → INFO not-found (idempotent)
# ---------------------------------------------------------------------------
echo; echo "[T6] remove --static on absent IP → INFO"
T6_OUT=$(call_remove_static 203.0.113.9 2>&1)
assert_contains "$T6_OUT" "not found"                               "T6.1 absent IP reported, no error"

# ---------------------------------------------------------------------------
# T7: ensure-header NEVER clobbers an existing (operator/shipped) file
# ---------------------------------------------------------------------------
echo; echo "[T7] ensure-header preserves an existing file"
rm -f "$MANUAL_FILE"
printf '# operator hand-written\n198.51.100.7  # ADDED_BY=operator\n' > "$MANUAL_FILE"
call_add_static 192.0.2.50 >/dev/null 2>&1 || true
T7C=$(cat "$MANUAL_FILE" 2>/dev/null || true)
assert_contains "$T7C" "198.51.100.7"                              "T7.1 pre-existing operator entry preserved"
assert_contains "$T7C" "192.0.2.50"                               "T7.2 new entry appended"
assert_not_contains "$T7C" "Permanent Whitelist (99-manual.conf)"  "T7.3 canonical header NOT injected over existing file"

# ---------------------------------------------------------------------------
# T8: dispatcher routing — --static / --ttl / default / remove --static
# ---------------------------------------------------------------------------
echo; echo "[T8] dispatcher routes flags correctly"
dispatch_env() {
    cat <<'DSTUBS'
nftban_whitelist_add_ip()         { echo "ROUTE_ADD_RUNTIME $1"; return 0; }
nftban_whitelist_add_static_ip()  { echo "ROUTE_ADD_STATIC $1"; return 0; }
nftban_whitelist_remove_ip()      { echo "ROUTE_REMOVE_RUNTIME $1"; return 0; }
nftban_whitelist_remove_static_ip(){ echo "ROUTE_REMOVE_STATIC $1"; return 0; }
nftban_whitelist_usage()          { echo "ROUTE_USAGE"; return 0; }
nftban_whitelist_list()           { echo "ROUTE_LIST"; return 0; }
DSTUBS
    awk '/^nftban_cmd_whitelist\(\)/{c=1} c{print} /^}/{if(c){c=0}}' "$WL_SRC"
}
call_dispatch() { ( set +e; eval "$(dispatch_env)"; nftban_cmd_whitelist "$@" ); }

T8A=$(call_dispatch add --static 1.2.3.4 2>&1)
assert_contains "$T8A" "ROUTE_ADD_STATIC 1.2.3.4"                  "T8.1 add --static → static writer"
T8B=$(call_dispatch add 1.2.3.4 2>&1)
assert_contains "$T8B" "ROUTE_ADD_RUNTIME 1.2.3.4"                "T8.2 default add → runtime writer"
assert_contains "$T8B" "RUNTIME whitelist only"                   "T8.3 default add prints honest runtime-only warning"
T8C=$(call_dispatch remove --static 1.2.3.4 2>&1)
assert_contains "$T8C" "ROUTE_REMOVE_STATIC 1.2.3.4"             "T8.4 remove --static → static remover"
T8D=$(call_dispatch remove 1.2.3.4 2>&1)
assert_contains "$T8D" "ROUTE_REMOVE_RUNTIME 1.2.3.4"            "T8.5 default remove → runtime remover"
T8E=$(call_dispatch add --static --ttl 30m 1.2.3.4 2>&1 || true)
assert_contains "$T8E" "mutually exclusive"                       "T8.6 --static + --ttl rejected"
T8F=$(call_dispatch add 2>&1 || true)
assert_contains "$T8F" "Usage: nftban whitelist add"             "T8.7 add with no IP shows usage"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo; echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
