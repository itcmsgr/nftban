#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 RBL false-CLEAN cluster (Lane A, items 11.1/11.3/
#          11.5/11.6 + 16.6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_false_clean_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for the v1.150 RBL false-CLEAN cluster. Asserts a simulated resolver timeout (rc 124) yields TIMEOUT not CLEAN; a host-absent-but-dig-present box really uses the dig fallback (not a silent empty CLEAN); no resolver at all yields ERROR not CLEAN; a TXT record with an embedded double-quote produces valid JSON (pipe through jq .); the per-run query cap bounds the number of providers dispatched on the parallel path; and the python3-absent IPv6 reverse path does not abort under set -u."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp,jq"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,mktemp,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rbl_false_clean_v150_test"
# meta:ta.owner="rbl"
# meta:ta.module="rbl-resolver-false-clean"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. We source the real
# nftban_rbl.sh core module into subshells, then override resolver-related
# leaf functions (nftban_rbl_resolver) and shadow `host`/`dig`/`nslookup`/
# `timeout`/`python3` with bash FUNCTIONS that emit scripted output / return
# scripted rc. No network is ever touched.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
RBL_SRC="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
# Point cache/config at the sandbox so nothing touches the host.
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export NFTBAN_CACHE_DIR="$SANDBOX/cache"
mkdir -p "$NFTBAN_CONFIG_DIR" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_ok() {
    # $1 = rc-from-test (0 = pass), $2 = name, $3 = detail (optional)
    if [[ "$1" -eq 0 ]]; then
        printf "  [PASS] %s\n" "$2"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s  %s\n" "$2" "${3:-}"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$2")
    fi
}

# Load the real core module into THIS shell (load guard makes it idempotent;
# the lib sources are guarded by [[ -f ]] and absent in the sandbox).
# shellcheck source=/dev/null
source "$RBL_SRC"

echo "================================================="
echo "v1.150 RBL false-CLEAN cluster test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1 (11.3): simulated timeout (rc 124) → TIMEOUT, never CLEAN
# ---------------------------------------------------------------------------
echo; echo "[T1] resolver timeout (rc 124) → TIMEOUT (not CLEAN)"
T1=$(
    nftban_rbl_resolver() { echo "host"; }
    # `timeout` returns 124 (its SIGTERM exit) and emits nothing.
    timeout() { return 124; }
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T1" "TIMEOUT" "T1.1 rc 124 maps to TIMEOUT"

# ---------------------------------------------------------------------------
# T2 (11.1): host ABSENT but dig PRESENT → dig fallback actually used
# ---------------------------------------------------------------------------
echo; echo "[T2] no host, dig present → dig fallback path"
# 2a: dig returns a 127/8 address → LISTED via dig.
T2A=$(
    # nftban_rbl_resolver picks the first available; force it to dig.
    nftban_rbl_resolver() { echo "dig"; }
    timeout() { shift; "$@"; }          # drop the timeout arg, run the rest
    dig()  { : > "$SANDBOX/dig_called"; echo "127.0.0.2"; }
    host() { echo "SHOULD_NOT_RUN"; }   # must NOT be used
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T2A" "LISTED" "T2.1 dig 127/8 answer → LISTED"
t2_dig_rc=0; [[ -f "$SANDBOX/dig_called" ]] || t2_dig_rc=1
assert_ok "$t2_dig_rc" "T2.2 dig was actually invoked"
# 2b: dig returns empty (NXDOMAIN) rc 0 → CLEAN (a real, observed clean result).
T2B=$(
    nftban_rbl_resolver() { echo "dig"; }
    timeout() { shift; "$@"; }
    dig() { echo ""; return 0; }
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T2B" "CLEAN" "T2.3 dig empty rc0 → CLEAN"

# ---------------------------------------------------------------------------
# T3 (11.1): NO resolver at all → ERROR, never CLEAN
# ---------------------------------------------------------------------------
echo; echo "[T3] no resolver binary → ERROR (not CLEAN)"
T3=$(
    nftban_rbl_resolver() { echo ""; }   # nothing available
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T3" "ERROR" "T3.1 missing resolver → ERROR"
# And a generic resolver failure (rc!=0, !=124, not 'not found') → ERROR.
T3B=$(
    nftban_rbl_resolver() { echo "host"; }
    timeout() { echo "connection timed out; no servers could be reached" >&2; return 1; }
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T3B" "ERROR" "T3.2 host rc1 non-NXDOMAIN failure → ERROR"
# host genuine NXDOMAIN (rc1 + 'not found' text) → CLEAN.
T3C=$(
    nftban_rbl_resolver() { echo "host"; }
    timeout() { shift; "$@"; }
    host() { echo "Host 4.3.2.1.zen.example.test not found: 3(NXDOMAIN)"; return 1; }
    _NFTBAN_RBL_QUERY_COUNT=0
    nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test"
)
assert_eq "$T3C" "CLEAN" "T3.3 host NXDOMAIN (rc1 + not-found text) → CLEAN"

# ---------------------------------------------------------------------------
# T4 (11.6): TXT record with embedded double-quote → VALID JSON
# ---------------------------------------------------------------------------
echo; echo "[T4] TXT with embedded \" → valid JSON (jq .)"
EVIL_TXT='Listed because "spam" \ and a newline
second line'
T4_OBJ=$(nftban_rbl_json_listed_obj "zen.example.test" "$EVIL_TXT" "https://example.test/why")
# Pipe through jq . — if the object were corrupt, jq exits non-zero.
if printf '%s' "$T4_OBJ" | jq . >/dev/null 2>&1; then
    assert_ok 0 "T4.1 listed object is valid JSON despite quotes/backslash/newline"
else
    assert_ok 1 "T4.1 listed object is valid JSON despite quotes/backslash/newline" "(jq rejected it)"
fi
# The reason field round-trips intact.
T4_REASON=$(printf '%s' "$T4_OBJ" | jq -r '.reason')
assert_eq "$T4_REASON" "$EVIL_TXT" "T4.2 reason round-trips through jq intact"
assert_contains "$T4_OBJ" '"status"' "T4.3 status field present"
# Status object (timeout/error) is also valid JSON.
T4S=$(nftban_rbl_json_status_obj "zen.example.test" "error" "https://example.test")
if printf '%s' "$T4S" | jq . >/dev/null 2>&1; then
    assert_ok 0 "T4.4 status object is valid JSON"
else
    assert_ok 1 "T4.4 status object is valid JSON" "(jq rejected it)"
fi
assert_eq "$(printf '%s' "$T4S" | jq -r '.status')" "error" "T4.5 status value = error"

# ---------------------------------------------------------------------------
# T5 (11.5): per-run query cap bounds providers dispatched on parallel path
# ---------------------------------------------------------------------------
echo; echo "[T5] MAX_QUERIES_PER_RUN caps the parallel fan-out"
# Provide 5 fake providers; cap at 2; count how many dns_lookups actually fire.
T5_DIR="$SANDBOX/t5"
mkdir -p "$T5_DIR"
T5=$(
    rm -f "$T5_DIR"/lookup.*
    nftban_rbl_load_providers() {
        printf '%s\n' \
            "rbl1.example.test:u1" \
            "rbl2.example.test:u2" \
            "rbl3.example.test:u3" \
            "rbl4.example.test:u4" \
            "rbl5.example.test:u5"
    }
    nftban_rbl_reverse_ip() { echo "4.3.2.1"; }
    # Each lookup drops a marker file so we can count actual dispatches.
    nftban_rbl_dns_lookup() {
        local d="$2"
        : > "$T5_DIR/lookup.$d"
        echo "CLEAN"
    }
    nftban_rbl_get_txt_record() { echo ""; }
    export NFTBAN_RBL_MAX_QUERIES_PER_RUN=2
    nftban_rbl_check_ip_parallel "1.2.3.4" text >/dev/null 2>&1 || true
    shopt -s nullglob; _m=("$T5_DIR"/lookup.*); echo "${#_m[@]}"
)
assert_eq "$T5" "2" "T5.1 only 2 of 5 providers dispatched when cap=2"
# Cap unset/0 → all providers dispatched (no false throttle).
T5B=$(
    rm -f "$T5_DIR"/lookup.*
    nftban_rbl_load_providers() {
        printf '%s\n' "a.test:u" "b.test:u" "c.test:u"
    }
    nftban_rbl_reverse_ip() { echo "4.3.2.1"; }
    nftban_rbl_dns_lookup() { : > "$T5_DIR/lookup.$2"; echo "CLEAN"; }
    nftban_rbl_get_txt_record() { echo ""; }
    unset NFTBAN_RBL_MAX_QUERIES_PER_RUN
    nftban_rbl_check_ip_parallel "1.2.3.4" text >/dev/null 2>&1 || true
    shopt -s nullglob; _m=("$T5_DIR"/lookup.*); echo "${#_m[@]}"
)
assert_eq "$T5B" "3" "T5.2 cap unset → all 3 providers dispatched"

# ---------------------------------------------------------------------------
# T6 (16.6): python3-absent IPv6 reverse path does not abort under set -u
# ---------------------------------------------------------------------------
echo; echo "[T6] no python3 → IPv6 reverse returns empty, no set -u abort"
T6_RC=0
T6_OUT=$(
    set -Eeuo pipefail
    # Shadow command so python3 looks absent; `command -v python3` → false.
    command() {
        if [[ "$1" == "-v" && "$2" == "python3" ]]; then return 1; fi
        builtin command "$@"
    }
    nftban_rbl_reverse_ip "2001:db8::1"
) || T6_RC=$?
assert_eq "$T6_RC" "0" "T6.1 IPv6 reverse with no python3 exits 0 (no unbound-var abort)"
assert_eq "$T6_OUT" "" "T6.2 IPv6 reverse with no python3 yields empty (skips lookup)"
# IPv4 reverse still works regardless.
T6_V4=$(nftban_rbl_reverse_ip "1.2.3.4")
assert_eq "$T6_V4" "4.3.2.1" "T6.3 IPv4 reverse unaffected"

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
