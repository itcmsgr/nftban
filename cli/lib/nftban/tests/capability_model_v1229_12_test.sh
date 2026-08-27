#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="capability_model_v1229_12_test" meta:type="test" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="B03 capability model: positive, negative and epistemic witnesses including both A08 failure directions"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB/capability.sh"
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_CRITICAL=3; HEALTH_DISABLED=5
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
# t <label> <expected> <configured> <reachable> <producer> <consumer> <observation> <activity> [converging]
t(){ local l="$1" want="$2"; shift 2
     local got; got=$(nftban_capability_classify "$@")
     [[ "$got" == "$want" ]] && ok "$l -> $want" || no "$l expected=$want got=$got"; }

echo "== WITNESS 1 (POSITIVE): A08 penalty ladder — producer + scheduler reachable, no traffic =="
t "ladder idle, no qualifying traffic" CAPABLE_IDLE   yes yes yes yes yes no
t "ladder with observed placements"    CAPABLE_ACTIVE yes yes yes yes yes yes

echo "== WITNESS 2 (NEGATIVE): state + consumer exist, producer edge unavailable =="
t "producer absent"                    INCAPABLE      yes yes no  yes yes no
t "consumer absent"                    INCAPABLE      yes yes yes no  yes no
t "projection unreachable"             INCAPABLE      yes no  yes yes yes no

echo "== WITNESS 3 (EPISTEMIC): observation failure is UNKNOWN, never zero/idle =="
t "observation unreadable"             UNKNOWN        yes yes yes yes unknown no
t "observation read failed"            UNKNOWN        yes yes yes yes no      no
t "producer edge unprovable"           UNKNOWN        yes yes unknown yes yes no
t "consumer edge unprovable"           UNKNOWN        yes yes yes unknown yes no
t "configured state unprovable"        UNKNOWN        unknown yes yes yes yes no

echo "== ORDERING / REMAINING STATES =="
t "converging outranks everything"     CONVERGING     yes yes no  no  no  no yes
t "not configured"                     DISABLED       no  yes yes yes yes no
t "activity unprovable, structure ok"  CAPABLE_IDLE   yes yes yes yes yes unknown

echo "== THE TWO A08 ERRORS — the pair this model exists to prevent =="
c=$(nftban_capability_classify yes yes no yes yes no)
[[ "$c" == "INCAPABLE" ]] && ok "FALSE HEALTHY blocked: sets+consumer present, producer absent -> INCAPABLE" \
                          || no "FALSE HEALTHY not blocked: got $c"
c=$(nftban_capability_classify yes yes yes yes yes no)
[[ "$c" == "CAPABLE_IDLE" ]] && ok "FALSE BROKEN blocked: producer reachable, state empty -> CAPABLE_IDLE" \
                             || no "FALSE BROKEN not blocked: got $c"

echo "== HEALTH MAPPING (must feed the shipped vocabulary, not replace it) =="
m(){ local got; got=$(nftban_capability_to_health "$1" "${3:-yes}")
     [[ "$got" == "$2" ]] && ok "$1 -> health $2" || no "$1 expected health $2 got $got"; }
m CAPABLE_ACTIVE 0
m CAPABLE_IDLE   0
m CONVERGING     1
m DEGRADED       1
m UNKNOWN        1
m DISABLED       5
m INCAPABLE      3 yes
m INCAPABLE      1 no
c=$(nftban_capability_to_health UNKNOWN yes)
[[ "$c" != "0" ]] && ok "UNKNOWN never maps to OK (cannot-prove is not a pass)" \
                  || no "UNKNOWN mapped to OK — an unproven mechanism would report healthy"

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
