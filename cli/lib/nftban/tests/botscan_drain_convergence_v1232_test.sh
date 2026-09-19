#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="botscan_drain_convergence_v1232_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.232 BotScan large-spool convergence. The scan loop performed EXACTLY ONE bounded read per object per cycle, so an object of K chunks needed at least K cycles to reach EOF - unconditionally, independent of SURVIVAL and of the deadline. Nothing ever retired, so the spool never fell and backpressure never cleared (srv3: 47 objects / 1.09 GB, at_EOF=0 for 24 days). Asserts the FIXED contract: an object is drained across consecutive reads within one cycle, bounded by the EXISTING deadline; EOF leads to retirement and a real spool decrease; a deadline stop leaves a durable offset and the SAME object resumes with no replay; and SURVIVAL still bounds the cycle while converging. Carries a BEHAVIOURAL INVERSION arm that replays the old one-read-per-cycle shape and proves it cannot reach EOF."
# meta:ta.id="botscan_drain_convergence_v1232_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-drain-convergence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/lib/nftban_http_logs.sh"
# meta:inventory.binaries="bash,stat,du,find"
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
[[ -f "$CORE" && -f "$HTTP" ]] || { ne "subject files absent"; fin; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export NFTBAN_DATA_DIR="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$SD/.."
mkdir -p "$SB/etc" "$SB/botscan/spool" "$SB/botscan/proc-offsets"
SPOOL="$SB/botscan/spool"; OFF="$SB/botscan/proc-offsets"
export BOTSCAN_SPOOL_DIR="$SPOOL" NFTBAN_HTTP_LOG_OFFSET_DIR="$OFF"
export BOTSCAN_BATCH_SIGNAL_MODE=true NFTBAN_HTTP_LOG_READ_FORWARD=true BOTSCAN_ENABLED=true
CAP=4096; export NFTBAN_HTTP_LOG_MAX_BYTES="$CAP" BOTSCAN_SCAN_MAX_BYTES_PER_FILE="$CAP"

# shellcheck source=/dev/null
source "$HTTP" >/dev/null 2>&1 || { ne "cannot source http_logs"; fin; }
# shellcheck source=/dev/null
source "$CORE" >/dev/null 2>&1 || true
# ⛔ The module sets `set -Eeuo pipefail` at file scope, which arms errexit in THIS
# shell. Disarm so the harness OBSERVES outcomes instead of dying on the first
# normal non-zero return (the reaper returns 1 for KEPT, which is normal).
set +e
declare -F nftban_botscan_process_logs >/dev/null || { ne "process_logs undefined"; fin; }

# ⛔ EACH CALL MODELS ONE PRODUCTION CYCLE, WHICH IS A FRESH PROCESS.
# nftban-botscan.service is Type=oneshot, so every cycle starts a new shell and the
# adaptive block divides the per-file cap exactly ONCE from its configured value:
#     FAIR_SHARE) BOTSCAN_SCAN_MAX_BYTES_PER_FILE=$(( <current> / 2 ))
#     SURVIVAL)   BOTSCAN_SCAN_MAX_BYTES_PER_FILE=$(( <current> / 4 ))
# This harness drives many cycles inside ONE process, so without this reset the
# division COMPOUNDS (4096 -> 1024 -> 256 -> ... -> 0) and the cap collapses — an
# artefact of the harness, not of the product. Restore the configured cap before
# every cycle so each call sees the same starting state a real cycle would.
cycle(){ export BOTSCAN_SCAN_MAX_BYTES_PER_FILE="$CAP" NFTBAN_HTTP_LOG_MAX_BYTES="$CAP"
         nftban_botscan_process_logs "$@" ; }

SEEN="$SB/seen.txt"; : >"$SEEN"
nftban_botscan_process_entry(){ printf '%s\n' "$2" >> "$SEEN"; return 0; }   # instrumentation

mkuniq(){ : >"$1"; local i; for ((i=1;i<=$2;i++)); do
    printf '1.2.3.4 - - [18/Sep/2026:10:00:00 +0000] "GET /seq-%06d HTTP/1.1" 404 12 "-" "curl/8"\n' "$i" >>"$1"; done; }
offof(){ local c v; c="$OFF/_botscan_spool_$(basename "$1")"; [[ -f "$c" ]] || { echo 0; return; }; v=$(cat "$c" 2>/dev/null); echo "${v#*:}"; }
reset(){ rm -f "$SPOOL"/* "$OFF"/* 2>/dev/null; : >"$SEEN"; }

echo "=== A — DEPTH: one object drains to EOF within ONE cycle ==="
export BOTSCAN_SPOOL_REAP=false BOTSCAN_SCAN_BUDGET_SECS=0    # 0 = UNLIMITED budget
f="$SPOOL/_var_log_a.log"; mkuniq "$f" 460; SZ=$(stat -c%s "$f")
[[ "$SZ" -gt $(( CAP * 4 )) ]] || ne "fixture too small to need multiple chunks"
cycle "" 60 >/dev/null 2>&1
A=$(offof "$f")
[[ "$A" == "$SZ" ]] && ok "A object reached EOF in one cycle ($A/$SZ B, $(( SZ / CAP + 1 )) chunks)" \
                    || no "A stopped at $A of $SZ B (one-read-per-cycle defect present)"

echo "=== A-INV — the OLD one-read-per-cycle shape must NOT reach EOF (arm has power) ==="
reset; g="$SPOOL/_var_log_inv.log"; mkuniq "$g" 460; GZ=$(stat -c%s "$g")
# Replays the pre-v1.232 body: a SINGLE bounded read, then move on.
while IFS= read -r _l; do :; done < <(
  NFTBAN_HTTP_CURSOR_NS="${BOTSCAN_SPOOL_CURSOR_NS:-_botscan_spool_}" nftban_http_read_incremental "$g" )
I=$(offof "$g")
if [[ "$I" -gt 0 && "$I" -lt "$GZ" ]]; then
  ok "A-INV old shape advanced only $I of $GZ B — the fixed arm discriminates"
else
  no "A-INV old shape reached $I of $GZ — inversion has NO POWER, arm A proves nothing"
fi

echo "=== B — EOF leads to RETIREMENT and a real spool decrease, in-cycle ==="
reset; export BOTSCAN_SPOOL_REAP=true
for i in 1 2 3 4 5 6; do mkuniq "$SPOOL/_var_log_b$i.log" 120; done
B0=$(du -sb "$SPOOL"|cut -f1); N0=$(find "$SPOOL" -type f|wc -l)
cycle "" 60 >/dev/null 2>&1
B1=$(du -sb "$SPOOL"|cut -f1); N1=$(find "$SPOOL" -type f|wc -l)
[[ "$N1" -lt "$N0" ]] && ok "B objects retired in-cycle ($N0 -> $N1)" || no "B nothing retired ($N0 -> $N1)"
[[ "$B1" -lt "$B0" ]] && ok "B spool bytes DECREASED ($B0 -> $B1, reclaimed $(( B0 - B1 )) B)" || no "B spool unchanged at $B0 B"

echo "=== C — resume from a durable mid-object offset, with NO REPLAY ==="
# ⛔ THIS ARM MUST NOT DEPEND ON WHEN THE DEADLINE FIRES. A previous version asserted
# "cycle 1 stopped mid-object", produced by setting a 1s budget. That is a TIMING
# PROPERTY, not a contract: on a 2-core lab the deadline bit mid-object, on the faster
# CI runner the same cycle drained all 79200 B and the assertion failed. Whether a
# deadline lands mid-object is a property of host speed.
# The CONTRACT being tested is "a durable mid-object offset is resumed, not replayed".
# So the mid-object state is CONSTRUCTED directly by seeding the cursor, which is
# deterministic on any host, and the deadline is left out of it entirely.
reset; export BOTSCAN_SPOOL_REAP=false BOTSCAN_SCAN_BUDGET_SECS=0
h="$SPOOL/_var_log_c.log"; NL=900; mkuniq "$h" "$NL"; HZ=$(stat -c%s "$h")
# Seed a durable cursor part-way in, exactly as a deadline-interrupted cycle would leave it.
SEED=$(( CAP * 3 )); HINO=$(stat -c%i "$h")
printf '%s:%s\n' "$HINO" "$SEED" > "$OFF/_botscan_spool__var_log_c.log"
[[ "$(offof "$h")" == "$SEED" ]] && ok "C seeded a durable mid-object offset ($SEED of $HZ B)" || no "C could not seed the cursor"
c=0; prev=$SEED; back=0
while (( c < 40 )); do
  cycle "" 60 >/dev/null 2>&1; c=$((c+1)); cur=$(offof "$h")
  (( cur < prev )) && { back=1; break; }
  prev=$cur; (( cur >= HZ )) && break
done
[[ "$back" -eq 0 ]] && ok "C cursor never moved backwards across $c cycles" || no "C cursor REGRESSED (replay)"
[[ "$prev" == "$HZ" ]] && ok "C resumed from the seeded offset and reached EOF ($c cycles)" || no "C never reached EOF (offset $prev of $HZ)"
tot=$(wc -l < "$SEEN"); uq=$(sort -u "$SEEN" | wc -l); dup=$(( tot - uq ))
[[ "$dup" -eq 0 ]] && ok "C ZERO duplicate examinations — the drain introduces no replay" || no "C $dup duplicate examinations (replay introduced)"
# ⛔ THE SHARPEST NO-REPLAY CHECK: nothing BEFORE the seeded offset may be re-read.
# A resume that restarted at 0 would re-examine those lines and still show no
# duplicates within this run, so counting duplicates alone cannot catch it.
pre=$(( SEED / (HZ / NL) ))
early=$(awk -F'seq-' 'NF>1{n=$2+0; if (n < '"$pre"'-2) c++} END{print c+0}' "$SEEN")
[[ "$early" -eq 0 ]] && ok "C nothing before the seeded offset was re-examined (true resume, not a restart)" \
                     || no "C $early line(s) before the seed were re-read — the cursor was not honoured"
# ⛔ RELATIVE loss rule (owner 2026-09-18). A PRE-EXISTING reader defect drops data at
# chunk boundaries — tracked as OPEN-BOTSCAN-BOUNDED-READ-DROPS-A-LINE-AT-EVERY-CHUNK-BOUNDARY
# and NOT this lane's to fix. This lane must only prove it adds NO FURTHER loss, so the
# bound is per-boundary, using the WORST-CASE effective cap (mode may divide it by 4).
bnd=$(( HZ / (CAP / 4) + 1 )); seen_expected=$(( NL - pre )); miss=$(( seen_expected - uq ))
[[ "$miss" -le "$bnd" ]] && ok "C loss stays within the PRE-EXISTING per-boundary rate ($miss over <=$bnd worst-case boundaries)" \
                         || no "C loss $miss EXCEEDS ~$bnd boundaries — the drain ADDED loss"

echo "=== D — SURVIVAL: deadline still authoritative AND convergence occurs ==="
reset; export BOTSCAN_SPOOL_REAP=true BOTSCAN_SCAN_BUDGET_SECS=8
nftban_botscan_pressure_state(){ echo "CRITICAL"; }
nftban_botscan_backlog_state(){ echo "STARVED"; }
for i in 1 2 3 4 5 6; do mkuniq "$SPOOL/_var_log_d$i.log" 40; done
mkuniq "$SPOOL/_var_log_dBIG.log" 3000
D0=$(du -sb "$SPOOL"|cut -f1); M0=$(find "$SPOOL" -type f|wc -l); t0=$SECONDS
out=$(cycle "" 60 2>&1); el=$(( SECONDS - t0 ))
D1=$(du -sb "$SPOOL"|cut -f1); M1=$(find "$SPOOL" -type f|wc -l)
printf '%s\n' "$out" | grep -qa 'mode=SURVIVAL' && ok "D SURVIVAL actually engaged (arm has power)" || no "D SURVIVAL not engaged"
[[ "$el" -le 40 ]] && ok "D deadline remains AUTHORITATIVE (${el}s; a large object cannot monopolise the cycle)" || no "D cycle ran ${el}s — host protection lost"
[[ "$M1" -lt "$M0" ]] && ok "D converged under SURVIVAL ($((M0-M1)) of $M0 objects retired)" || no "D nothing retired under SURVIVAL"
[[ "$D1" -lt "$D0" ]] && ok "D spool decreased under SURVIVAL ($((D0-D1)) B)" || no "D spool unchanged under SURVIVAL"

echo "=== E — a KEPT reaper result must never abort the cycle ==="
grep -q 'nftban_botscan_reap_consumed_spool "\$f" \\' "$CORE" && \
  grep -A3 'nftban_botscan_reap_consumed_spool "\$f" \\' "$CORE" | grep -q '|| true' \
  && ok "E the in-loop reap call is guarded (KEPT=1 is a normal outcome, not an abort)" \
  || no "E the in-loop reap call is UNGUARDED — a KEPT object aborts the cycle under errexit"
fin
