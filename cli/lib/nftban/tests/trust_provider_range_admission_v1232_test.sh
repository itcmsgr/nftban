#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.232.0 trust provider range admission
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="trust_provider_range_admission_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-20"
# meta:description="v1.232.0 BUG-TRUST-WHITELIST-NO-CIDR-VALIDATION. Provider feed content reached the durable whitelist source by verbatim cat and the additive nft fragment by a comment/blank grep, so any line a provider (or a MITM of its feed) supplied became a whitelist element. A whitelist element is an exemption from banning, so 0.0.0.0/0 in a provider feed disables ALL blacklist enforcement. Asserts _trust_validate_cidr refuses /0 on both families, refuses malformed CIDRs and out-of-range prefixes, refuses ranges below the provider floor, accepts real provider ranges and bare hosts, and reads zero-padded prefixes as base 10 not octal; asserts _trust_filter_cache extracts the first token when a line carries an inline comment (the module sets IFS to newline/tab), counts SEEN/ACCEPTED/REJECTED, and returns 1 when a non-empty feed yields no admissible entry; asserts _trust_write_whitelist is FAIL CLOSED (a fully inadmissible feed leaves the previous whitelist byte-identical) and that an admissible feed writes the FILTERED content. Carries the pre-fix negative control proving the unfixed admission pipeline emits 0.0.0.0/0, so the arms above are discriminating and not merely non-regression."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,mktemp,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,mktemp,cmp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="trust_provider_range_admission_v1232_test"
# meta:ta.owner="trust"
# meta:ta.module="trust-provider-admission"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Self-contained sandbox; no host contact; no root. The admission functions are
# extracted from nftban_trust.sh BY NAME (the module itself declares readonly
# FHS paths and would bind the sandbox to /var and /etc), and the REAL
# validation.sh is sourced so the arms exercise production validation rather
# than a stub of it.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
TRUST_SRC="$NFTBAN_LIB_DIR/core/nftban_trust.sh"
VALIDATION_SRC="$NFTBAN_LIB_DIR/lib/validation.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

ok()   { printf "  [PASS] %s\n" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  [FAIL] %s\n         %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); }

assert_rc() {
    local rc="$1" expected="$2" name="$3"
    if [[ "$rc" == "$expected" ]]; then ok "$name"; else bad "$name" "expected rc $expected, got $rc"; fi
}
assert_eq() {
    local got="$1" want="$2" name="$3"
    if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "expected '$want', got '$got'"; fi
}
assert_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -F -q -- "$needle"; then ok "$name"; else bad "$name" "expected to contain: $needle"; fi
}
assert_not_contains() {
    local hay="$1" needle="$2" name="$3"
    if printf '%s' "$hay" | grep -F -q -- "$needle"; then bad "$name" "did NOT expect: $needle"; else ok "$name"; fi
}

# --- PRECONDITION: the subject must exist and be extractable -----------------
[[ -r "$TRUST_SRC" ]]      || { echo "NOT_EXECUTED: missing $TRUST_SRC" >&2; exit 2; }
[[ -r "$VALIDATION_SRC" ]] || { echo "NOT_EXECUTED: missing $VALIDATION_SRC" >&2; exit 2; }

# Extract a top-level function by name: from "name() {" to the matching "}" at
# column 0. Fails loudly if the function is absent, so a renamed/removed subject
# is NOT_EXECUTED rather than a silent pass.
extract_fn() {
    local fn="$1" src="$2"
    awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$src"
}

EXTRACT="$SANDBOX/subject.sh"
: > "$EXTRACT"
for fn in _trust_validate_cidr _trust_filter_cache _trust_write_whitelist; do
    body=$(extract_fn "$fn" "$TRUST_SRC")
    if [[ -z "$body" ]]; then
        echo "NOT_EXECUTED: function $fn not found in $TRUST_SRC" >&2
        exit 2
    fi
    printf '%s\n\n' "$body" >> "$EXTRACT"
done

# --- Harness ----------------------------------------------------------------
# shellcheck source=/dev/null
source "$VALIDATION_SRC"

TRUST_LOG="$SANDBOX/trust.log"
_trust_log() { printf '%s %s\n' "$1" "$2" >> "$TRUST_LOG"; }
# shellcheck disable=SC2034  # read by the EXTRACTED _trust_write_whitelist body,
# which shellcheck cannot see because it is sourced at runtime from $EXTRACT.
declare -A TRUST_PROVIDERS=([TESTP_NAME]="TestProvider")
_trust_get_whitelist_file() { printf '%s/30-trust-testp.conf' "$SANDBOX"; }
_trust_get_cache_file() { printf '%s/%s-%s.cache' "$SANDBOX" "$1" "$2"; }

: "${NFTBAN_TRUST_MIN_PREFIX_V4:=8}"
: "${NFTBAN_TRUST_MIN_PREFIX_V6:=16}"

# shellcheck source=/dev/null
source "$EXTRACT"

echo ""
echo "=== A. _trust_validate_cidr: admission policy ==="

# A helper that captures BOTH the reason and the rc without tripping errexit.
vc() { local out rc=0; out=$(_trust_validate_cidr "$1") || rc=$?; VC_REASON="$out"; return "$rc"; }

rc=0; vc "0.0.0.0/0" || rc=$?
assert_rc "$rc" 2 "A1 0.0.0.0/0 refused as over-broad"
assert_contains "$VC_REASON" "every source on the internet" "A2 0.0.0.0/0 reason names the real consequence"

rc=0; vc "::/0" || rc=$?
assert_rc "$rc" 2 "A3 ::/0 refused as over-broad"

rc=0; vc "999.1.1.1/24" || rc=$?
assert_rc "$rc" 1 "A4 malformed address in CIDR refused"

rc=0; vc "1.2.3.0/33" || rc=$?
assert_rc "$rc" 1 "A5 out-of-range IPv4 prefix refused"

rc=0; vc "10.0.0.0/7" || rc=$?
assert_rc "$rc" 2 "A6 IPv4 below the provider floor refused"

rc=0; vc "10.0.0.0/8" || rc=$?
assert_rc "$rc" 0 "A7 IPv4 exactly at the floor accepted (boundary, not off-by-one)"

rc=0; vc "104.16.0.0/13" || rc=$?
assert_rc "$rc" 0 "A8 real provider range accepted"

rc=0; vc "1.2.3.4" || rc=$?
assert_rc "$rc" 0 "A9 bare host address accepted"

rc=0; vc "not-an-ip" || rc=$?
assert_rc "$rc" 1 "A10 non-address token refused"

rc=0; vc "2400:cb00::/32" || rc=$?
assert_rc "$rc" 0 "A11 real IPv6 provider range accepted"

rc=0; vc "2400::/8" || rc=$?
assert_rc "$rc" 2 "A12 IPv6 below the v6 floor refused"

# A zero-padded prefix must be read base-10. Were it read as octal, /010 would
# become 8 and pass the floor while actually meaning /10.
rc=0; vc "1.2.3.0/024" || rc=$?
assert_rc "$rc" 0 "A13 zero-padded prefix read as base 10, not octal"

echo ""
echo "=== B. _trust_filter_cache: counting, tokenising, fail-closed ==="

cat > "$SANDBOX/mixed.cache" <<'EOF'
# TestProvider ranges
104.16.0.0/13
0.0.0.0/0

198.51.100.0/24 # inline comment after a valid range
999.9.9.9/24
10.0.0.0/7
EOF

rc=0; _trust_filter_cache "$SANDBOX/mixed.cache" "$SANDBOX/mixed.out" "TestProvider" || rc=$?
assert_rc "$rc" 0 "B1 mixed feed with survivors returns success"
assert_eq "${_TRUST_FILTER_SEEN}" "5" "B2 comments and blank lines are not counted as entries"
assert_eq "${_TRUST_FILTER_ACCEPTED}" "2" "B3 accepted count correct"
assert_eq "${_TRUST_FILTER_REJECTED}" "3" "B4 rejected count correct"

out=$(cat "$SANDBOX/mixed.out")
assert_not_contains "$out" "0.0.0.0/0" "B5 whole-internet range absent from admitted output"
assert_contains "$out" "104.16.0.0/13" "B6 valid range admitted"
# The module sets IFS=$'\n\t'; if the filter inherited it, "198.51.100.0/24 # x"
# would be taken as a single token and rejected as malformed.
assert_contains "$out" "198.51.100.0/24" "B7 first token extracted from a line with an inline comment"
assert_not_contains "$out" "#" "B8 no comment text leaks into the admitted output"

logged=$(cat "$TRUST_LOG")
assert_contains "$logged" "REJECTED '0.0.0.0/0'" "B9 rejection is logged, never silent"

# Hostile/unusable feed: entries supplied, none admissible.
printf '0.0.0.0/0\n::/0\n' > "$SANDBOX/hostile.cache"
rc=0; _trust_filter_cache "$SANDBOX/hostile.cache" "$SANDBOX/hostile.out" "TestProvider" || rc=$?
assert_rc "$rc" 1 "B10 feed with entries but no survivors reports failure"
assert_eq "$(wc -c < "$SANDBOX/hostile.out" | tr -d ' ')" "0" "B11 no admitted output from a hostile feed"

# Genuinely empty feed is NOT a failure — absence differs from inadmissibility.
: > "$SANDBOX/empty.cache"
rc=0; _trust_filter_cache "$SANDBOX/empty.cache" "$SANDBOX/empty.out" "TestProvider" || rc=$?
assert_rc "$rc" 0 "B12 empty feed is not treated as a hostile feed"

echo ""
echo "=== C. _trust_write_whitelist: fail-closed durable source ==="

WL="$SANDBOX/30-trust-testp.conf"

# Establish a good previous whitelist from an admissible feed.
printf '104.16.0.0/13\n' > "$(_trust_get_cache_file TESTP ipv4)"
printf '2400:cb00::/32\n' > "$(_trust_get_cache_file TESTP ipv6)"

rc=0; _trust_write_whitelist "TESTP" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 0 "C1 admissible feed writes the durable whitelist"
wl_content=$(cat "$WL")
assert_contains "$wl_content" "104.16.0.0/13" "C2 admitted IPv4 range present in durable source"
assert_contains "$wl_content" "2400:cb00::/32" "C3 admitted IPv6 range present in durable source"

before_sum=$(cksum < "$WL")

# Now the provider feed turns hostile: every entry inadmissible.
printf '0.0.0.0/0\n' > "$(_trust_get_cache_file TESTP ipv4)"
printf '::/0\n'      > "$(_trust_get_cache_file TESTP ipv6)"

rc=0; _trust_write_whitelist "TESTP" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 1 "C4 fully inadmissible feed reports failure"

after_sum=$(cksum < "$WL")
assert_eq "$after_sum" "$before_sum" "C5 FAIL CLOSED: previous whitelist left byte-identical"
assert_not_contains "$(cat "$WL")" "0.0.0.0/0" "C6 whole-internet range never reaches the durable source"

# A feed that is partly bad must still publish the good part, minus the bad.
printf '104.16.0.0/13\n0.0.0.0/0\n' > "$(_trust_get_cache_file TESTP ipv4)"
printf '2400:cb00::/32\n'           > "$(_trust_get_cache_file TESTP ipv6)"
rc=0; _trust_write_whitelist "TESTP" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 0 "C7 partly-admissible feed still publishes"
wl_content=$(cat "$WL")
assert_contains "$wl_content" "104.16.0.0/13" "C8 good range survives a partly-bad feed"
assert_not_contains "$wl_content" "0.0.0.0/0" "C9 bad range filtered out of a partly-bad feed"

echo ""
echo "=== D. NEGATIVE CONTROL: the pre-fix admission pipeline ==="
# Power check. These arms reproduce the admission EXACTLY as it stood before
# v1.232.0 and assert it DOES admit the whole-internet range. If these fail,
# the fixture no longer carries a hostile entry and every arm above is vacuous.

prefix_fragment_admit() { grep -v '^#' "$1" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//'; }
prefix_durable_admit()  { cat "$1"; }

printf '# ranges\n104.16.0.0/13\n0.0.0.0/0\n' > "$SANDBOX/control.cache"

ctrl_frag=$(prefix_fragment_admit "$SANDBOX/control.cache" || true)
assert_contains "$ctrl_frag" "0.0.0.0/0" \
    "D1 CONTROL: pre-fix fragment pipeline admits 0.0.0.0/0 (fixture is hostile)"

ctrl_dur=$(prefix_durable_admit "$SANDBOX/control.cache" || true)
assert_contains "$ctrl_dur" "0.0.0.0/0" \
    "D2 CONTROL: pre-fix durable writer admits 0.0.0.0/0 verbatim"

# And the fixed path, on the SAME fixture, must not.
rc=0; _trust_filter_cache "$SANDBOX/control.cache" "$SANDBOX/control.out" "TestProvider" || rc=$?
assert_rc "$rc" 0 "D3 fixed path still admits the good range from the same fixture"
assert_not_contains "$(cat "$SANDBOX/control.out")" "0.0.0.0/0" \
    "D4 fixed path refuses the entry the pre-fix path admitted"

echo ""
echo "============================================================"
printf "Passed: %d  Failed: %d\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf "Failed tests:\n"
    for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
    exit 1
fi
exit 0
