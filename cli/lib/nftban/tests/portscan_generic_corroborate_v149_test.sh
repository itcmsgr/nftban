#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.149.0 portscan "generic" corroboration (PORTSCAN-RATE)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="portscan_generic_corroborate_v149_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.149.0 classic-mode portscan generic-scan corroboration. A non-rapid, single-target, 5..(vertical-1) distinct-port detection (bursty/NAT/admin multi-service profile) is downgraded to generic-observe (log/alert, NEVER banned); a diversity-corroborated detection (>= corroboration floor) still classifies generic and bans; corroboration can be disabled to restore legacy banning; vertical/horizontal/block/strobe paths are unchanged. Classic-mode only — suricata mode (IDS score-based) and DDoS are intentionally NOT touched."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sort,tr"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,grep,sort,tr"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained sandbox; no host contact; no root. Extracts the classify +
# corroboration + handler functions from nftban_portscan_classic.sh by name,
# populates the per-IP tracking globals, and asserts the classification + that
# an uncorroborated generic detection never reaches a ban call.
# =============================================================================

set -Eeuo pipefail
# PARITY-GUARD-EXEMPT: ipv4-only test coverage. Port-scan detection is kernel-inline
# nft and present in BOTH table ip nftban and table ip6 nftban; this test corroborates
# the family-neutral classifier logic. Dual-family TEST coverage is recorded debt for
# v1.197. See scripts/ci/check-ipv4-ipv6-parity.sh.
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SRC="$REPO_ROOT/cli/lib/nftban/core/nftban_portscan_classic.sh"

PASS=0; FAIL=0; FAILED_TESTS=()
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then printf "  [PASS] %s\n" "$name"; PASS=$((PASS+1))
    else printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); fi
}
assert_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -F -q -- "$needle"; then printf "  [PASS] %s\n" "$name"; PASS=$((PASS+1))
    else printf "  [FAIL] %s (missing '%s')\n" "$name" "$needle"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); fi
}
assert_not_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -F -q -- "$needle"; then printf "  [FAIL] %s (unexpected '%s')\n" "$name" "$needle"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
    else printf "  [PASS] %s\n" "$name"; PASS=$((PASS+1)); fi
}

# Extract the three functions under test by name (header line ends with '{',
# body closes with a column-0 '}').
extract_funcs() {
    awk '
      /^(nftban_portscan_classic_detect_scan_type|_nftban_portscan_classic_generic_corroborated|nftban_portscan_classic_handle_detection)\(\) \{/ { cap=1 }
      cap { print }
      cap && /^\}/ { cap=0 }
    ' "$SRC"
}

# Build a subshell environment: config + tracking globals + stubs + the funcs.
classic_env() {
    cat <<'STUBS'
# Config (defaults from classic.conf)
PORTSCAN_CLASSIC_MIN_PORTS=5
PORTSCAN_CLASSIC_VERTICAL_PORTS=10
PORTSCAN_CLASSIC_HORIZONTAL_TARGETS=5
PORTSCAN_CLASSIC_BLOCK_RANGE=20
PORTSCAN_CLASSIC_STROBE_PORTS=5
PORTSCAN_SENSITIVE_PORTS=""
PORTSCAN_CLASSIC_ACTION="block"
PORTSCAN_CLASSIC_GENERIC_CORROBORATE="true"
PORTSCAN_CLASSIC_GENERIC_CORROBORATE_PORTS=""
declare -gA _PORTSCAN_CLASSIC_IP_PORTS=()
declare -gA _PORTSCAN_CLASSIC_IP_TARGETS=()
declare -gA _PORTSCAN_CLASSIC_IP_TIMESTAMPS=()
declare -gA _PORTSCAN_CLASSIC_IP_BAN_COUNT=()
# Stubs: record ban attempts; quiet logger; alert recorder.
_nftban_portscan_classic_log() { :; }
nftban_portscan_classic_send_alert() { echo "ALERT $1 $2"; }
nftban_portscan_classic_block_ip() { echo "BAN_CALLED $1 $2"; }
nftban_ban() { echo "BAN_CALLED $1"; }
nft_ipc_ban() { echo "BAN_CALLED $1"; }
STUBS
    extract_funcs
}

# classify <ip> "<ports>" "<targets>" "<timestamps>" [corroborate] [floor]
classify() {
    ( set +e
      eval "$(classic_env)"
      # These are read by the eval'd functions at call time (dynamic use).
      # shellcheck disable=SC2034
      [[ -n "${5:-}" ]] && PORTSCAN_CLASSIC_GENERIC_CORROBORATE="$5"
      # shellcheck disable=SC2034
      [[ -n "${6:-}" ]] && PORTSCAN_CLASSIC_GENERIC_CORROBORATE_PORTS="$6"
      _PORTSCAN_CLASSIC_IP_PORTS["$1"]="$2"
      _PORTSCAN_CLASSIC_IP_TARGETS["$1"]="$3"
      _PORTSCAN_CLASSIC_IP_TIMESTAMPS["$1"]="$4"
      nftban_portscan_classic_detect_scan_type "$1" )
}
# handle <ip> <scan_type>
handle() {
    ( set +e
      eval "$(classic_env)"
      nftban_portscan_classic_handle_detection "$1" "$2" )
}

echo "================================================="
echo "v1.149.0 portscan generic-corroboration test suite"
echo "================================================="

# Timestamps spanning 20s so the strobe path (port>=5 within 10s) does NOT fire.
TS_SLOW="1000 1020"

# T1: 6 distinct ports, 1 target, non-rapid → generic-observe (the admin/NAT profile)
echo; echo "[T1] 6 ports / 1 target / non-rapid → generic-observe (not banned)"
T1=$(classify 192.0.2.122 "22 80 443 25 110 143" "10.0.0.1" "$TS_SLOW")
assert_eq "$T1" "generic-observe" "T1.1 uncorroborated generic downgraded to observe"

# T2: 12 distinct ports across 2 targets, non-rapid → corroborated generic (bans)
#     (not vertical: target_count>1; not block: <20; not horizontal: ports>3)
echo; echo "[T2] 12 ports / 2 targets → corroborated generic"
T2=$(classify 9.9.9.9 "1 2 3 4 5 6 7 8 9 10 11 12" "10.0.0.1 10.0.0.2" "$TS_SLOW")
assert_eq "$T2" "generic" "T2.1 diversity >= floor → still classifies generic (bannable)"

# T3: corroboration disabled → legacy behavior (6 ports → generic)
echo; echo "[T3] corroboration disabled → legacy generic ban"
T3=$(classify 8.8.8.8 "22 80 443 25 110 143" "10.0.0.1" "$TS_SLOW" "false")
assert_eq "$T3" "generic" "T3.1 GENERIC_CORROBORATE=false restores legacy generic at MIN_PORTS"

# T4: custom corroboration floor of 6 → 6 ports now corroborates
echo; echo "[T4] custom corroboration floor (6) → 6 ports corroborates"
T4=$(classify 7.7.7.7 "22 80 443 25 110 143" "10.0.0.1" "$TS_SLOW" "true" "6")
assert_eq "$T4" "generic" "T4.1 floor honored (port_count>=floor)"

# T5: vertical path unchanged (10 ports, single target → vertical)
echo; echo "[T5] vertical path unchanged"
T5=$(classify 6.6.6.6 "1 2 3 4 5 6 7 8 9 10" "10.0.0.1" "$TS_SLOW")
assert_eq "$T5" "vertical" "T5.1 >=10 ports single target still vertical"

# T6: block path unchanged (>=20 ports → block)
echo; echo "[T6] block path unchanged"
T6=$(classify 5.5.5.5 "$(seq 1 22 | tr '\n' ' ')" "10.0.0.1" "$TS_SLOW")
assert_eq "$T6" "block" "T6.1 >=20 ports still block"

# T7: below MIN_PORTS → no detection at all (return non-zero, empty output)
echo; echo "[T7] below MIN_PORTS → no detection"
T7=$(classify 4.4.4.4 "22 80 443" "10.0.0.1" "$TS_SLOW" || true)
assert_eq "$T7" "" "T7.1 <5 ports → no scan type emitted"

# T8: handler NEVER bans on generic-observe (even with ACTION=block)
echo; echo "[T8] handle_detection(generic-observe) does not ban"
T8=$(handle 192.0.2.122 "generic-observe")
assert_not_contains "$T8" "BAN_CALLED" "T8.1 generic-observe is never banned (ACTION=block)"

# T9: handler DOES ban on corroborated generic (regression guard)
echo; echo "[T9] handle_detection(generic) bans (corroborated path intact)"
T9=$(handle 9.9.9.9 "generic")
assert_contains "$T9" "BAN_CALLED 9.9.9.9" "T9.1 corroborated generic still bans"

echo; echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
