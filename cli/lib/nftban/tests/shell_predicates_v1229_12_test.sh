#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="shell_predicates_v1229_12_test" meta:type="test" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="P0-2 semantic contract, old/new equivalence, and large-payload performance sentinel for nftban_has_non_whitespace"
# meta:inventory.files="" 
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB/shell_predicates.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

echo "== GATE 1: SEMANTIC CONTRACT =="
t(){ local d="$1" v="$2" want="$3" got
     if nftban_has_non_whitespace "$v"; then got=true; else got=false; fi
     [[ "$got" == "$want" ]] && ok "$d -> $want" || no "$d expected=$want got=$got"; }
t "empty"             ""                      false
t "single space"      " "                     false
t "spaces"            "   "                   false
t "tab"               "$(printf '\t')"        false
t "newline"           "$(printf '\n')"        false
t "mixed whitespace"  "$(printf ' \t\n\r ')"  false
t "x"                 "x"                     true
t "leading space"     " x"                    true
t "trailing space"    "x "                    true
t "wrapped"           "$(printf ' \n\t x \t\n ')" true

echo "== GATE 2: OLD/NEW EQUIVALENCE (must agree on every case) =="
for v in "" " " "   " "$(printf '\t')" "$(printf '\n')" "$(printf ' \t\n ')" "x" " x" "x " "$(printf '\n\t x \r')" "0" "false"; do
    old=$([[ -n "${v//[[:space:]]/}" ]] && echo true || echo false)
    new=$(nftban_has_non_whitespace "$v" && echo true || echo false)
    [[ "$old" == "$new" ]] && ok "equivalence [${v//[$'\n\t']/·}]" || no "DIVERGENCE [$v] old=$old new=$new"
done

echo "== GATE 3: LARGE-PAYLOAD SEMANTICS =="
ws=$(head -c 500000 /dev/zero | tr '\0' ' ')
nftban_has_non_whitespace "$ws"       && no "500KB whitespace -> should be false" || ok "500KB whitespace -> false"
nftban_has_non_whitespace "${ws}x"    && ok "500KB whitespace + trailing x -> true" || no "trailing x -> should be true"
nftban_has_non_whitespace "x${ws}"    && ok "leading x + 500KB whitespace -> true" || no "leading x -> should be true"
mid="${ws:0:250000}x${ws:250000}"
nftban_has_non_whitespace "$mid"      && ok "x in the middle of 500KB -> true" || no "middle x -> should be true"

echo "== GATE 4: PERFORMANCE SENTINEL (loose bound; catches catastrophic regression) =="
BOUND_MS="${NFTBAN_PREDICATE_BOUND_MS:-500}"
for n in 10000 100000 500000; do
    p=$(head -c "$n" /dev/zero | tr '\0' ' ')
    s=$(date +%s%N); nftban_has_non_whitespace "$p"; e=$(date +%s%N)
    ms=$(( (e-s)/1000000 ))
    [[ $ms -le $BOUND_MS ]] && ok "${n}B in ${ms}ms (bound ${BOUND_MS}ms)" || no "${n}B took ${ms}ms > ${BOUND_MS}ms"
done

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
