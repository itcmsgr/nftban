#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ddos_penalty_progression_v1229_12_test" meta:type="test" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="A08 penalty ladder tier progression: every boundary, both families, against the real selection authority"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# ⛔ This tests the SHIPPED selection function, not a re-implementation of the
# formula. Testing a copy would prove only that the copy is self-consistent.
set -uo pipefail
CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
# Extract the real function without executing the module's load-time side effects.
eval "$(sed -n '/^_nftban_ddos_penalty_target_tier()/,/^}/p' "$CORE/nftban_ddos_classic.sh")"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
# t <strikes> <threshold> <suffix> <expected_set> <expected_timeout>
t(){ local got want="$4 $5"
     got=$(_nftban_ddos_penalty_target_tier "$1" "$2" "$3")
     [[ "$got" == "$want" ]] && ok "strikes=$1 T=$2 sfx='$3' -> $want" \
                             || no "strikes=$1 T=$2 sfx='$3' expected '$want' got '$got'"; }

echo "== SHIPPED DEFAULT THRESHOLD T=3 — every boundary, IPv4 =="
t 0  3 "" "-" "-"
t 1  3 "" "-" "-"
t 2  3 "" "-" "-"                      # threshold-1: still no tier
t 3  3 "" ddos_limit_10s 10s           # threshold: tier 1
t 4  3 "" ddos_limit_10s 10s
t 5  3 "" ddos_limit_10s 10s           # next boundary-1: still tier 1
t 6  3 "" ddos_limit_5m  5m            # next boundary: tier 2
t 8  3 "" ddos_limit_5m  5m
t 9  3 "" ddos_drop_5m   5m            # tier 3
t 11 3 "" ddos_drop_5m   5m
t 12 3 "" ddos_ban_1h    1h            # tier 4
t 99 3 "" ddos_ban_1h    1h            # saturates at tier 4

echo "== IPv6 SUFFIX — family-correct set names, same boundaries =="
t 2  3 "6" "-" "-"
t 3  3 "6" ddos_limit_10s6 10s
t 6  3 "6" ddos_limit_5m6  5m
t 9  3 "6" ddos_drop_5m6   5m
t 12 3 "6" ddos_ban_1h6    1h

echo "== THRESHOLD IS CONFIGURABLE — boundaries scale with T =="
t 4  5 "" "-" "-"
t 5  5 "" ddos_limit_10s 10s
t 9  5 "" ddos_limit_10s 10s
t 10 5 "" ddos_limit_5m  5m
t 20 5 "" ddos_ban_1h    1h
t 1  1 "" ddos_limit_10s 10s
t 4  1 "" ddos_ban_1h    1h

echo "== NO CROSS-FAMILY CONTAMINATION =="
v4=$(_nftban_ddos_penalty_target_tier 3 3 "");  v6=$(_nftban_ddos_penalty_target_tier 3 3 "6")
[[ "$v4" != "$v6" ]] && ok "IPv4 and IPv6 select DIFFERENT sets at the same strike count" \
                     || no "IPv4 and IPv6 selected the same set: $v4"
[[ "$v6" == *6* ]] && ok "IPv6 target carries the 6 suffix" || no "IPv6 target lacks suffix: $v6"
[[ "$v4" != *6* ]] && ok "IPv4 target has no 6 suffix" || no "IPv4 target wrongly suffixed: $v4"

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
