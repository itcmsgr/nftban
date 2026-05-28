#!/usr/bin/env bash
# =============================================================================
# NFTBan - feeds --json jq-construction (no string concat) test (v1.141 PR-B F-FEEDS-JSON)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_feeds_json_jq_construction_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-B F-FEEDS-JSON — asserts that `nftban feeds list --json` survives feed metadata that carries JSON-special characters (double quotes, backslashes, newlines, unicode). Pre-v1.141 the per-feed object was built by string concatenation with only-partial escape; the output broke as soon as a description carried a control char or unicode. This test stubs nftban_feeds_get_property to return adversarial DESCRIPTION strings and asserts: (a) rc=0; (b) first non-space char is '{' or '['; (c) jq -e parses cleanly; (d) the embedded description survives a round-trip through jq -r (proves the escaping is correct)."
# meta:input="cli/lib/nftban/cli/cmd_feeds.sh nftban_feeds_list"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,jq"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Run nftban_feeds_list --json with an adversarial DESCRIPTION value via env.
# The bash subshell stubs the upstream feed-property accessor to return the
# adversarial string for DESCRIPTION; the test then jq-parses the result and
# round-trips the description back to confirm character-faithful escaping.
run_with_desc() {
    local desc="$1"
    DESC="$desc" bash -c "
        set +e
        export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
        export NFTBAN_NO_BANNER=1
        nftban_feeds_get_categories()  { echo 'ssh'; }
        nftban_feeds_get_by_category() { echo 'TEST_FEED'; }
        nftban_feeds_get_property()    { case \"\$2\" in
                                            ENABLED)     echo 'true';;
                                            DESCRIPTION) printf '%s' \"\$DESC\";;
                                            INTERVAL)    echo 'DAILY';;
                                          esac; }
        nftban_feeds_discover_all()    { echo 'TEST_FEED'; }
        nftban_feeds_get_stats()       { echo '1/1 feeds enabled'; }
        nftban_banner()                { :; }
        json_output()                  { printf '%s' \"\$2\"; }
        source '$NFTBAN_LIB_DIR/cli/cmd_feeds.sh' 2>/dev/null || true
        nftban_feeds_list --json
    "
}

assert_round_trip() {
    local label="$1" expected_desc="$2" out="$3" rc="$4"
    if (( rc != 0 )); then no "$label" "rc=$rc"; return; fi
    local first; first="${out:0:1}"
    if [[ "$first" != "{" && "$first" != "[" ]]; then
        no "$label" "first char '$first' not JSON; head: ${out:0:100}"; return
    fi
    if ! echo "$out" | jq -e '.' >/dev/null 2>&1; then
        no "$label" "jq parse failed; head: ${out:0:200}"; return
    fi
    local got
    got=$(echo "$out" | jq -r '.feeds[0].description // empty' 2>/dev/null || true)
    if [[ "$got" != "$expected_desc" ]]; then
        no "$label" "round-trip mismatch: want='$expected_desc' got='$got'"
        return
    fi
    ok "$label"
}

echo "=========================================================="
echo "v1.141 PR-B — F-FEEDS-JSON jq-construction round-trip"
echo "=========================================================="

# T1 — plain ASCII
echo "--- T1: plain ASCII description ---"
out=$(run_with_desc 'Standard feed description'); rc=$?
assert_round_trip "T1 plain ASCII" 'Standard feed description' "$out" "$rc"

# T2 — embedded double-quotes (would break naïve "\"$desc\"" concat)
echo "--- T2: embedded double-quotes ---"
out=$(run_with_desc 'feed with "quotes" inside'); rc=$?
assert_round_trip "T2 embedded double-quotes" 'feed with "quotes" inside' "$out" "$rc"

# T3 — embedded backslash. Note: bash single-quote literal preserves the
# backslash verbatim (no shell escaping), so both `desc` and `expected_desc`
# below carry the SAME single literal backslash.
echo "--- T3: embedded backslash ---"
out=$(run_with_desc 'feed with \ literal backslash'); rc=$?
assert_round_trip "T3 embedded backslash" 'feed with \ literal backslash' "$out" "$rc"

# T4 — unicode
echo "--- T4: unicode description ---"
out=$(run_with_desc 'feed with unicode: αβγ 🛡️ Ω'); rc=$?
assert_round_trip "T4 unicode" 'feed with unicode: αβγ 🛡️ Ω' "$out" "$rc"

# T5 — control char (tab) — jq must escape as \t
echo "--- T5: tab inside description ---"
out=$(run_with_desc $'feed\twith\ttabs'); rc=$?
assert_round_trip "T5 embedded tabs" $'feed\twith\ttabs' "$out" "$rc"

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
