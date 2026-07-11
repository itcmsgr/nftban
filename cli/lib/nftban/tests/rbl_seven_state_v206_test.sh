#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for the v1.206 RBL 7-state result model (TODO-1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_seven_state_v206_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-25"
# meta:description="Tests the v1.206 RBL 7-state model: LISTED/CLEAN/ERROR/RESOLVER_BLOCKED/TIMEOUT/SKIPPED_IPV4_ONLY_ZONE/UNSUPPORTED_IPV6_ZONE. Asserts Spamhaus block-codes 127.255.255.252/.253/.254 classify RESOLVER_BLOCKED (not LISTED, not CLEAN); dig status REFUSED→RESOLVER_BLOCKED and SERVFAIL→ERROR; authoritative NXDOMAIN→CLEAN; a 127/8 listing→LISTED; that non-CLEAN states NEVER increment clean_count (the P0 false-negative invariant); rbl check --json stays valid JSON and exposes per-state degraded counts; IPv6 un-reversible→UNSUPPORTED_IPV6_ZONE and IPv4-only-zone→SKIPPED_IPV4_ONLY_ZONE; and the v1.150 ERROR/RATE_LIMITED-degraded behavior still holds. Self-contained sandbox; no network."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,mktemp,jq"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,mktemp,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_IPV4_ONLY_ZONES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# This harness shadows resolver/provider leaf functions (nftban_rbl_resolver,
# dig, timeout, nftban_rbl_dns_lookup, nftban_rbl_load_providers, …) which are
# invoked INDIRECTLY by name from the sourced module under test — shellcheck's
# SC2329 ("never invoked") cannot see that. Disabled file-wide for the harness.
# shellcheck disable=SC2329
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
RBL_SRC="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export NFTBAN_CACHE_DIR="$SANDBOX/cache"
mkdir -p "$NFTBAN_CONFIG_DIR" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR"

PASS=0; FAIL=0; FAILED_TESTS=()
assert_eq() { local a="$1" e="$2" n="$3"
    if [[ "$a" == "$e" ]]; then printf "  [PASS] %s\n" "$n"; PASS=$((PASS+1))
    else printf "  [FAIL] %s (expected '%s', got '%s')\n" "$n" "$e" "$a"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$n"); fi; }
assert_ok() { if [[ "$1" -eq 0 ]]; then printf "  [PASS] %s\n" "$2"; PASS=$((PASS+1))
    else printf "  [FAIL] %s  %s\n" "$2" "${3:-}"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$2"); fi; }

# shellcheck source=/dev/null
source "$RBL_SRC"

echo "================================================="
echo "v1.206 RBL 7-state model test suite"
echo "================================================="

# A dig stub emitting a realistic `dig +noall +answer +comments` block. $1=status,
# $2=answer-ip (optional). The classifier parses the 'status:' line and the answer.
_dig_block() { local st="$1" ip="${2:-}"
    echo ";; ->>HEADER<<- opcode: QUERY, status: ${st}, id: 12345"
    [[ -n "$ip" ]] && echo "4.3.2.1.zen.example.test. 300 IN A ${ip}"; }

echo; echo "[T1] Spamhaus block-codes → RESOLVER_BLOCKED (not LISTED, not CLEAN)"
for code in 127.255.255.252 127.255.255.253 127.255.255.254; do
    R=$( nftban_rbl_resolver(){ echo dig; }; timeout(){ shift; "$@"; }
         dig(){ _dig_block NOERROR "$code"; return 0; }; _NFTBAN_RBL_QUERY_COUNT=0
         nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
    assert_eq "$R" "RESOLVER_BLOCKED" "T1 $code → RESOLVER_BLOCKED"
done

echo; echo "[T2] dig status REFUSED → RESOLVER_BLOCKED"
R=$( nftban_rbl_resolver(){ echo dig; }; timeout(){ shift; "$@"; }
     dig(){ _dig_block REFUSED; return 0; }; _NFTBAN_RBL_QUERY_COUNT=0
     nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "RESOLVER_BLOCKED" "T2 REFUSED → RESOLVER_BLOCKED"

echo; echo "[T3] dig status SERVFAIL → ERROR (never CLEAN)"
R=$( nftban_rbl_resolver(){ echo dig; }; timeout(){ shift; "$@"; }
     dig(){ _dig_block SERVFAIL; return 0; }; _NFTBAN_RBL_QUERY_COUNT=0
     nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "ERROR" "T3 SERVFAIL → ERROR"

echo; echo "[T4] authoritative NXDOMAIN → CLEAN"
R=$( nftban_rbl_resolver(){ echo dig; }; timeout(){ shift; "$@"; }
     dig(){ _dig_block NXDOMAIN; return 0; }; _NFTBAN_RBL_QUERY_COUNT=0
     nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "CLEAN" "T4 NXDOMAIN → CLEAN"

echo; echo "[T5] real 127/8 listing → LISTED"
R=$( nftban_rbl_resolver(){ echo dig; }; timeout(){ shift; "$@"; }
     dig(){ _dig_block NOERROR 127.0.0.2; return 0; }; _NFTBAN_RBL_QUERY_COUNT=0
     nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "LISTED" "T5 127.0.0.2 → LISTED"

echo; echo "[T6] aggregation: non-CLEAN NEVER counts clean + valid JSON (the P0 invariant)"
# 4 providers → listed / resolver_blocked / timeout / clean. clean MUST be 1.
T6=$(
    nftban_rbl_load_providers(){ printf '%s\n' "listed.test:u1" "blocked.test:u2" "tmo.test:u3" "clean.test:u4"; }
    nftban_rbl_dns_lookup(){
        # one case-branch per line — bash 5.1 (EL9) rejects multiple "pat) cmd ;;"
        # on a single physical line inside a function inside $(...).
        case "$2" in
            listed.test) echo LISTED ;;
            blocked.test) echo RESOLVER_BLOCKED ;;
            tmo.test) echo TIMEOUT ;;
            *) echo CLEAN ;;
        esac
    }
    nftban_rbl_get_txt_record(){ echo "test"; }
    nftban_rbl_check_ip "1.2.3.4" "json"
) || true
assert_ok "$(echo "$T6" | jq . >/dev/null 2>&1; echo $?)" "T6.1 --json is valid JSON"
assert_eq "$(echo "$T6" | jq -r '.summary.clean')" "1"            "T6.2 clean count = 1 (degraded NOT folded into clean)"
assert_eq "$(echo "$T6" | jq -r '.summary.listed')" "1"           "T6.3 listed = 1"
assert_eq "$(echo "$T6" | jq -r '.summary.resolver_blocked')" "1" "T6.4 resolver_blocked = 1"
assert_eq "$(echo "$T6" | jq -r '.summary.timeout')" "1"          "T6.5 timeout = 1"
assert_eq "$(echo "$T6" | jq -r '.summary.degraded')" "2"         "T6.6 degraded total = 2 (blocked+timeout)"

echo; echo "[T7] IPv6 un-reversible (no python3) → UNSUPPORTED_IPV6_ZONE (never CLEAN)"
T7=$(
    nftban_rbl_reverse_ip(){ echo ""; }   # simulate no-python3 IPv6 reverse
    nftban_rbl_load_providers(){ printf '%s\n' "zen.test:u1"; }
    nftban_rbl_dns_lookup(){ echo "SHOULD_NOT_BE_CALLED"; }
    nftban_rbl_check_ip "2a01:4f8:c014:5ee1::1" "json"
) || true
assert_eq "$(echo "$T7" | jq -r '.summary.unsupported_ipv6_zone')" "1" "T7.1 unsupported_ipv6_zone = 1"
assert_eq "$(echo "$T7" | jq -r '.summary.clean')" "0"                 "T7.2 clean = 0 (not a silent clean)"

echo; echo "[T8] IPv6 + IPv4-only zone → SKIPPED_IPV4_ONLY_ZONE (never CLEAN)"
T8=$(
    export NFTBAN_RBL_IPV4_ONLY_ZONES="v4only.test"
    nftban_rbl_reverse_ip(){ echo "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2"; }
    nftban_rbl_load_providers(){ printf '%s\n' "v4only.test:u1"; }
    nftban_rbl_dns_lookup(){ echo CLEAN; }   # would falsely say clean if not skipped
    nftban_rbl_check_ip "2a01:4f8:c014:5ee1::1" "json"
) || true
assert_eq "$(echo "$T8" | jq -r '.summary.skipped_ipv4_only_zone')" "1" "T8.1 skipped_ipv4_only_zone = 1"
assert_eq "$(echo "$T8" | jq -r '.summary.clean')" "0"                  "T8.2 clean = 0 (IPv4-only zone not counted clean for IPv6)"

echo; echo "[T9] v1.150 regression: ERROR + RATE_LIMITED still degraded, never CLEAN"
R=$( nftban_rbl_resolver(){ echo ""; }; _NFTBAN_RBL_QUERY_COUNT=0
     nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "ERROR" "T9.1 no resolver → ERROR"
R=$( nftban_rbl_resolver(){ echo dig; }; _NFTBAN_RBL_QUERY_COUNT=999999
     export NFTBAN_RBL_MAX_QUERIES_PER_RUN=1; nftban_rbl_dns_lookup "1.2.3.4" "zen.example.test" )
assert_eq "$R" "RATE_LIMITED" "T9.2 query cap → RATE_LIMITED"

echo
echo "================================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"; exit 1; fi
echo "ALL PASS"
