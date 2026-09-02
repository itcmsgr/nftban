#!/usr/bin/env bash
# =============================================================================
# NFTBan — nftban_has_non_whitespace contract
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="shell-predicates-v1229-13-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-02"
# meta:description="Contract for nftban_has_non_whitespace, the bounded replacement for [[ -z \${var//[[:space:]]/} \]\]. Proves EQUIVALENCE with the idiom it replaces across every input class (unset, empty, spaces, tabs, newlines, mixed whitespace, single byte, padded content, embedded newline, large realistic payload) rather than merely asserting the predicate returns the expected boolean — the migration is only safe if old and new agree for every caller. Also proves the predicate is safe under set -u with no argument, that it does NOT allocate a transformed copy (asserted structurally, with a bounded timing corroboration), and pins the narrowness: it must not acquire input, know about command status, or express a third state."
# meta:inventory.files="cli/lib/nftban/lib/shell_predicates.sh"
# meta:inventory.privileges="none"
# meta:ta.id="shell_predicates_v1229_13_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="shell-predicates"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib/shell_predicates.sh"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# The idiom being replaced, isolated so equivalence is measured, not assumed.
legacy_has_content() { [[ -n "${1//[[:space:]]/}" ]]; }

echo "=== EQUIVALENCE with the replaced idiom, every input class ==="
check() { # $1=label $2=value $3=expected(yes|no)
    local lbl="$1" val="$2" want="$3" new legacy
    nftban_has_non_whitespace "$val" && new=yes || new=no
    legacy_has_content        "$val" && legacy=yes || legacy=no
    if [[ "$new" != "$legacy" ]]; then
        bad "$lbl: DIVERGES — new=$new legacy=$legacy (migration would change behaviour)"
    elif [[ "$new" != "$want" ]]; then
        bad "$lbl: both returned $new, expected $want"
    else
        ok "$lbl -> $new (new == legacy)"
    fi
}
check "empty string"          ""                      no
check "single space"          " "                     no
check "many spaces"           "          "            no
check "tabs"                  "$(printf '\t\t\t')"    no
check "newlines"              "$(printf '\n\n')"      no
check "carriage returns"      "$(printf '\r\r')"      no
check "vertical tab / formfeed" "$(printf '\v\f')"    no
check "mixed whitespace"      "$(printf ' \t\n\r ')"  no
check "single non-ws byte"    "x"                     yes
check "padded content"        "   hello   "           yes
check "content with newline"  "$(printf 'a\nb')"      yes
check "whitespace then byte"  "$(printf '\t\t\tz')"   yes
check "byte then whitespace"  "$(printf 'z\t\t\t')"   yes
check "punctuation only"      "..."                   yes
check "zero digit"            "0"                     yes

echo "=== set -u safety: called with NO argument ==="
( set -u; nftban_has_non_whitespace >/dev/null 2>&1 ) && r=yes || r=no
if [[ "$r" == "no" ]]; then
    ok "no-argument call is safe under set -u and reports 'no non-whitespace'"
else
    bad "no-argument call returned 'yes' — \${1-} default is wrong"
fi
( set -u; nftban_has_non_whitespace 2>/tmp/np.err >/dev/null ) || true
if [[ -s /tmp/np.err ]]; then
    bad "no-argument call emitted an error under set -u: $(head -1 /tmp/np.err)"
else
    ok "no-argument call emits no unbound-variable error"
fi
rm -f /tmp/np.err

echo "=== it does NOT allocate a transformed copy ==="
# STRUCTURAL first: the property under test is "builds no transformed copy". That is a
# fact about the body, not about a stopwatch, so assert it structurally — a timing
# assertion would be the flaky proxy for it.
if [[ "$(declare -f nftban_has_non_whitespace)" == *'//[[:space:]]'* ]]; then
    bad "predicate performs a whitespace REWRITE — that is the cost this helper exists to avoid"
else
    ok "predicate body performs no whitespace substitution (no transformed copy)"
fi

# BOUNDED corroboration. ⛔ An earlier revision of this test ran 50 iterations of the
# replaced idiom on a ~195 KB payload. At ~3.2 s per call that is ~158 s, which exceeded
# run-test-suite.sh's 120 s per-test budget and returned TIMEOUT — its own verdict class,
# neither PASS nor FAIL. Keep this arm small: 3 iterations on a ~60 KB payload.
# ⛔ THE PAYLOAD MUST RESEMBLE A REAL RULESET. A payload of one repeated non-whitespace
#    byte gives the rewrite nothing to substitute, so it short-circuits and the gap
#    collapses — the assertion would then fail for the wrong reason.
BIG="$(awk 'BEGIN{for(i=0;i<1500;i++) printf "\t\t  ip saddr 10.%d.%d.%d counter drop\n", i%256,(i*3)%256,(i*7)%256}')"
s=$(date +%s%N); for _ in 1 2 3; do nftban_has_non_whitespace "$BIG"; done; e=$(date +%s%N)
NEW_US=$(( (e-s)/1000 ))
s=$(date +%s%N); for _ in 1 2 3; do legacy_has_content "$BIG"; done; e=$(date +%s%N)
OLD_US=$(( (e-s)/1000 ))
echo "  [INFO] 3 iterations on ${#BIG} bytes: predicate ${NEW_US}us, replaced idiom ${OLD_US}us"
# Bound the CLAIM, not the number: absolute timings are environment-specific, so assert
# only an order-of-magnitude separation.
if (( OLD_US > NEW_US * 5 )); then
    ok "predicate is >5x cheaper than the rewrite idiom on a realistic payload"
else
    bad "no material improvement measured (predicate ${NEW_US}us vs idiom ${OLD_US}us)"
fi
# ...and it must still be CORRECT on that payload.
nftban_has_non_whitespace "$BIG" && ok "large payload correctly reports non-whitespace" \
                                 || bad "large payload misreported as whitespace-only"

echo "=== ⛔ NARROWNESS — the predicate must not grow semantics ==="
body="$(declare -f nftban_has_non_whitespace)"
for forbidden in 'nft ' '$(' 'UNKNOWN' 'return 2' 'command -v' 'read ' '</'; do
    if [[ "$body" == *"$forbidden"* ]]; then
        bad "predicate body contains '$forbidden' — it must not acquire input or express status"
    fi
done
ok "predicate body acquires nothing and expresses no third state"
lines=$(printf '%s\n' "$body" | grep -cvE '^\s*(\{|\}|\s*)$')
[[ "$lines" -le 3 ]] \
    && ok "predicate is $lines executable line(s) — still a primitive" \
    || bad "predicate has grown to $lines executable lines; re-review its contract"

echo
echo "=== shell_predicates: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
