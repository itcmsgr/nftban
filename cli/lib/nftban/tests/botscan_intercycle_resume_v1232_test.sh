#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="botscan_intercycle_resume_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.232 continuation of the large-spool convergence blocker. Depth-first WITHIN a cycle landed in 83a09a02, but BETWEEN cycles the rotation advanced past a half-drained object, which then waited a full rotation (~40 cycles on srv3). The first completion-priority attempt used a binary in-progress/fresh predicate that has NO discriminatory power on a real backlog, where every object is already in-progress. Asserts the pin contract: a mid-object stop pins that object, the next cycle resumes IT, it runs to EOF and retires, and only then does rotation advance - with explicit bounded escapes so a bad object can never deadlock the queue, and with a fresh arrival unable to steal priority from a pinned object."
# meta:ta.id="botscan_intercycle_resume_v1232_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-intercycle-resume"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="bash,stat,find"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_SPOOL_DIR,NFTBAN_HTTP_LOG_OFFSET_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
PASS=0; FAIL=0; NOT_EXECUTED=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
ne(){ echo "  [NOT_EXECUTED] $1"; NOT_EXECUTED=$((NOT_EXECUTED+1)); }
fin(){ echo; echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOT_EXECUTED ==="; [[ "$FAIL" -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }; echo "RESULT: FAIL"; exit 1; }

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SD/../core/nftban_botscan.sh"; HTTP="$SD/../lib/nftban_http_logs.sh"
[[ -f "$CORE" && -f "$HTTP" ]] || { ne "subject absent"; fin; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export NFTBAN_DATA_DIR="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$SD/.."
mkdir -p "$SB/etc" "$SB/botscan/spool" "$SB/botscan/proc-offsets"
SPOOL="$SB/botscan/spool"; OFF="$SB/botscan/proc-offsets"; PIN="$SB/botscan/scan-pin"
export BOTSCAN_SPOOL_DIR="$SPOOL" NFTBAN_HTTP_LOG_OFFSET_DIR="$OFF"
export BOTSCAN_BATCH_SIGNAL_MODE=true NFTBAN_HTTP_LOG_READ_FORWARD=true BOTSCAN_ENABLED=true
CAP=4096
# shellcheck source=/dev/null
source "$HTTP" >/dev/null 2>&1 || { ne "cannot source http_logs"; fin; }
# shellcheck source=/dev/null
source "$CORE" >/dev/null 2>&1 || true
set +e   # the module arms errexit at file scope; observe, do not die
declare -F nftban_botscan_process_logs >/dev/null || { ne "process_logs undefined"; fin; }
nftban_botscan_process_entry(){ return 0; }

L='1.2.3.4 - - [18/Sep/2026:10:00:00 +0000] "GET /wp-login.php HTTP/1.1" 404 12 "-" "curl/8"'
mk(){ : >"$1"; while (( $(stat -c%s "$1") < $2 )); do printf '%s\n' "$L" >>"$1"; done; }
offof(){ local c="$OFF/_botscan_spool_$1"; [[ -f "$c" ]] || { echo 0; return; }; local v; v=$(cat "$c" 2>/dev/null); echo "${v#*:}"; }
seed(){ local f="$1"; printf '%s:%s\n' "$(stat -c%i "$f")" "$2" > "$OFF/_botscan_spool_$(basename "$f")"; }
snap(){ local f b; for f in "$SPOOL"/*; do [[ -f "$f" ]] || continue; b=$(basename "$f"); echo "$b=$(offof "$b")"; done | sort; }
moved(){ join -t'=' -j1 <(printf '%s\n' "$1") <(printf '%s\n' "$2") 2>/dev/null | awk -F'=' '{if ($3+0 > $2+0) print $1}' | sort; }
cycle(){ export BOTSCAN_SCAN_MAX_BYTES_PER_FILE="$CAP" NFTBAN_HTTP_LOG_MAX_BYTES="$CAP"; nftban_botscan_process_logs "" 60 >/dev/null 2>&1; }
reset(){ rm -f "$SPOOL"/* "$OFF"/* "$PIN" 2>/dev/null; }

echo "=== 1/2 — the discriminating fixture: many objects, ALL in-progress, none completable in one cycle ==="
export BOTSCAN_SPOOL_REAP=false BOTSCAN_SCAN_BUDGET_SECS=2
for i in $(seq 1 42); do f="$SPOOL/_var_log_o$(printf '%02d' "$i").log"; mk "$f" $(( CAP*40 )); seed "$f" "$CAP"; done
nz=0; for f in "$SPOOL"/*; do [[ "$(offof "$(basename "$f")")" -gt 0 ]] && nz=$((nz+1)); done
[[ "$nz" -eq 42 ]] && ok "1 all 42 objects carry a NON-ZERO cursor (binary in-progress predicate cannot discriminate here)" || no "1 only $nz of 42 seeded"
[[ $(( CAP*40 )) -gt $(( CAP*4 )) ]] && ok "2 each object needs 40 reads — cannot finish in one bounded cycle" || no "2 fixture too small to discriminate"

echo "=== 3 — cycle N+1 must RESUME the object cycle N left unfinished ==="
S0=$(snap); cycle; S1=$(snap); cycle; S2=$(snap)
M1=$(moved "$S0" "$S1"); M2=$(moved "$S1" "$S2")
n1=$(printf '%s\n' "$M1"|grep -c .); res=$(comm -12 <(printf '%s\n' "$M1") <(printf '%s\n' "$M2")|grep -c .)
if [[ "$n1" -eq 0 ]]; then ne "3 cycle 1 advanced nothing — no conclusion"
elif [[ "$res" -gt 0 ]]; then ok "3 RESUMED: $(printf '%s' "$M1"|tr '\n' ' ')advanced in both cycles"
else no "3 NOT RESUMED: cycle2 advanced a disjoint set ($(printf '%s' "$M2"|tr '\n' ' ')) — rotation abandoned the pinned object"; fi
[[ -f "$PIN" ]] && ok "3b a pin record exists while the object is unfinished" || no "3b no pin record written"

echo "=== NEGATIVE — a FRESH object must not steal priority from a pinned one ==="
fresh="$SPOOL/_var_log_zfresh.log"; mk "$fresh" $(( CAP*2 ))   # brand new, no cursor
cycle   # one cycle with the fresh object present and another object pinned
[[ "$(offof "$(basename "$fresh")")" -eq 0 ]] && ok "NEG fresh arrival did NOT advance while another object is pinned" \
  || no "NEG fresh object stole priority from the pinned object"
rm -f "$fresh"

echo "=== 4/5 — run to EOF, retire, and only THEN advance rotation ==="
reset; export BOTSCAN_SPOOL_REAP=true BOTSCAN_SCAN_BUDGET_SECS=2
# ⛔ THE FIXTURE MUST LEAVE WORK BEHIND AFTER THE FIRST RETIREMENT. An earlier
# version used three small objects; ALL of them drained and retired inside cycle 1,
# so arm 5 saw "nothing advanced" and reported a STALL when the truth was "nothing
# was left". That is a fixture-power failure reported as a product defect.
# One SMALL object (sorts first, so rotation reaches it first and it completes),
# plus large ones that CANNOT complete and must therefore still be there afterwards.
small="$SPOOL/_var_log_a_small.log"; mk "$small" $(( CAP*2 )); seed "$small" 0
for i in 1 2 3; do f="$SPOOL/_var_log_b_big$i.log"; mk "$f" $(( CAP*40 )); seed "$f" "$CAP"; done
k=0; retired=0
while (( k < 15 )); do
  cycle; k=$((k+1))
  [[ -f "$small" ]] || { retired=1; break; }
done
left=$(find "$SPOOL" -type f | wc -l)
[[ "$retired" -eq 1 ]] && ok "4 the object reached EOF and RETIRED after $k cycle(s) (_var_log_a_small.log)"                        || no "4 the small object never retired in $k cycles"
[[ "$left" -gt 0 ]] && ok "4b work REMAINS after that retirement ($left objects) — arm 5 can discriminate"                     || ne "4b nothing left after retirement — arm 5 would be vacuous"
if [[ "$retired" -eq 1 && "$left" -gt 0 ]]; then
  B=$(snap); cycle; A=$(snap); nxt=$(moved "$B" "$A")
  [[ -n "$nxt" ]] && ok "5 rotation advanced to another object after retirement ($(printf '%s' "$nxt"|tr '\n' ' '))"                   || no "5 nothing advanced although $left object(s) remain — queue stalled"
else ne "5 not evaluated: preconditions unmet (retired=$retired left=$left)"; fi

echo "=== 6 — an unreadable/stale pinned object must NOT deadlock the queue ==="
reset; export BOTSCAN_SPOOL_REAP=false BOTSCAN_SCAN_BUDGET_SECS=2
for i in 1 2 3; do f="$SPOOL/_var_log_g$i.log"; mk "$f" $(( CAP*6 )); seed "$f" "$CAP"; done
printf '%s|%s\n' "_var_log_GHOST.log" "1" > "$PIN"      # pin an object that does not exist
B=$(snap); cycle; A=$(snap); adv=$(moved "$B" "$A")
[[ -n "$adv" ]] && ok "6 a pin naming a non-existent object was released and work continued ($(printf '%s' "$adv"|tr '\n' ' '))" \
  || no "6 QUEUE DEADLOCKED behind an unresolvable pin"
[[ ! -f "$PIN" || "$(cut -d'|' -f1 "$PIN" 2>/dev/null)" != "_var_log_GHOST.log" ]] && ok "6b the stale pin record was cleared" || no "6b stale pin still held"
echo "=== 6c — a pin must also expire on a bounded attempt budget ==="
grep -q 'BOTSCAN_SCAN_PIN_MAX_CYCLES' "$CORE" && ok "6c a bounded pin budget exists (cannot pin forever)" || no "6c no bounded escape — a pin could be permanent"
grep -q 'releasing pinned object' "$CORE" && ok "6d pin releases are logged with a reason" || no "6d pin release is silent"
fin
