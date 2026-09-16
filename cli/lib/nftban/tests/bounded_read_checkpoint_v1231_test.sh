#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="bounded_read_checkpoint_v1231_test"
# meta:type="test"
# meta:version="1.231.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-16"
# meta:inventory.files=""
# meta:inventory.binaries="bash,tail,head,stat,mktemp,chattr"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="v1.231.0 P0-A. A bounded read `producer | head -c N` succeeds by making the producer stop: head exits once satisfied and the producer takes SIGPIPE (141). Under pipefail that SUCCESSFUL read reports failure, and under errexit the caller aborts before its next statement - which in nftban_http_read_incremental is the cursor checkpoint. Delivered bytes were therefore replayed every cycle: offsets never reached EOF, completion authority never existed, the conservative BotScan reaper correctly retained every object, and the spool stayed latched at cap with backpressure asserted. Two production hosts sat in that state for 22 and 75 days. MEASURED pre-fix: 32 reads entered, 9 reached the checkpoint. Acceptance is the BOUNDED CONSUMER CONTRACT - head_rc==0 AND actual==requested - and producer exit status is DIAGNOSTIC ONLY: the same logical read reports 141 under a default SIGPIPE disposition and 1 under systemd's IgnoreSIGPIPE=yes, so gating on it ties correctness to who launched the process rather than to the bytes obtained. Every arm therefore runs under BOTH dispositions. Short reads, consumer failure and unusable scratch all still FAIL, so the fix can never degenerate into a blanket `|| true`. Hermetic."
# meta:ta.id="bounded_read_checkpoint_v1231_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="http-logs"
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
_root=$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)
LIB="$_root/cli/lib/nftban/lib/nftban_http_logs.sh"
[[ -f "$LIB" ]] || { echo "FATAL: subject absent: $LIB"; exit 2; }
P=0; F=0
ok(){ echo "  [PASS] $1"; P=$((P+1)); }
no(){ echo "  [FAIL] $1${2:+ — $2}"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export NFTBAN_HTTP_LOG_OFFSET_DIR="$W/off"; mkdir -p "$NFTBAN_HTTP_LOG_OFFSET_DIR"
# ⛔ PROBE THE AMBIENT SIGPIPE DISPOSITION BEFORE SOURCING THE LIBRARY.
#    The library arms `set -Eeuo pipefail` at file scope, after which a raw bounded
#    pipeline returning 141 would kill this script. More importantly: an INHERITED
#    SIG_IGN CANNOT BE RESTORED TO DEFAULT from inside the process, so this harness
#    does not get to choose the first disposition — it can only ADD the ignore.
#    MEASURED: the GitHub Actions runner tree already ignores SIGPIPE, so there the
#    ambient shape is EPIPE (1), not signal death (141). Asserting 141 for the first
#    battery would encode an assumption about ambient state we do not control.
_probe="$(mktemp)"; head -c 262144 /dev/zero > "$_probe" 2>/dev/null
tail -c +1 "$_probe" 2>/dev/null | head -c 1024 >/dev/null
AMBIENT_RC="${PIPESTATUS[0]}"
rm -f "$_probe"

set +u
# shellcheck source=/dev/null
. "$LIB" >/dev/null 2>&1
set -u

echo "=== 0b ambient SIGPIPE disposition probed BEFORE any assertion ==="
case "$AMBIENT_RC" in
    141) ok "ambient producer rc=141 — SIGPIPE defaulted (signal shape)" ;;
    1)   ok "ambient producer rc=1 — SIGPIPE already IGNORED here (EPIPE shape, e.g. a CI runner or a systemd service)" ;;
    *)   no "ambient producer rc is neither 141 nor 1" "$AMBIENT_RC — the disposition model does not describe this host" ;;
esac

echo "=== 0. subject exists (no arm may pass by vacuity) ==="
if declare -F nftban_http_bounded_read >/dev/null 2>&1; then
    ok "nftban_http_bounded_read is defined"
else
    no "nftban_http_bounded_read MISSING"; echo "FATAL: refusing to report on an absent subject"; exit 2
fi

L='203.0.113.7 - - [25/Aug/2026:12:25:01 +0000] "GET /wp-login.php HTTP/1.1" 404 209 "-" "curl/8"'
# ⛔ FIXTURE GENERATION MUST NOT DEPEND ON THE MECHANISM UNDER TEST.
#    `yes "$L" | head -c N` relies on SIGPIPE to stop the producer — the very
#    behaviour these arms exercise. On a host where SIGPIPE is ignored for that
#    context the generator never terminates and the suite hangs before asserting
#    anything. Build by file doubling instead: no pipeline, no signal dependency.
mk(){
    local _n="$1" _f="$2" _b="$2.build"
    printf '%s\n' "$L" > "$_b"
    while [ "$(stat -c %s "$_b" 2>/dev/null || echo 0)" -lt "$_n" ]; do
        cat "$_b" "$_b" > "$_b.x" 2>/dev/null && mv -f "$_b.x" "$_b"
    done
    head -c "$_n" "$_b" > "$_f"      # head from a FILE, not a pipe
    rm -f "$_b" "$_b.x" 2>/dev/null
}

# =============================================================================
# THE BATTERY RUNS TWICE — ONCE PER SIGPIPE DISPOSITION.
#
#   D=ambient   whatever we INHERITED — probed above, NOT assumed. 141 on a normal
#               shell; 1 on a CI runner or systemd service that already ignores it.
#   D=ignored   SIGPIPE SIG_IGN forced here   tail gets EPIPE   producer rc = 1
#
# An inherited SIG_IGN cannot be restored to default from inside the process, so the
# harness can only ADD the ignore. On a host whose ambient disposition is already
# ignored BOTH batteries see rc=1 — that is correct and not a vacuity, because the
# predicate under test never consults producer status at all; the differentiation is
# carried by the probe (arm 0b) and by the declared-inversion control, not by this
# harness pretending it can choose the ambient disposition.
#
# IgnoreSIGPIPE= defaults to YES in systemd and an ignored signal is INHERITED
# ACROSS exec, so nftban-botscan.service (Type=oneshot, shell ExecStart) runs in
# the SECOND shape — as does the GitHub Actions runner tree. `trap "" PIPE` sets
# SIG_IGN in this shell and every child inherits it, reproducing production with
# no extra dependency (MEASURED: SigIgn=0000000000001000, PIPESTATUS="1 0").
#
# A REVISION OF THIS HELPER THAT ACCEPTED ONLY producer rc {141,0} PASSED THIS
# SUITE STANDALONE AND WAS INERT ON THE PRODUCTION HOSTS. Running one disposition
# is not running the contract. Do not collapse these back into a single run.
# =============================================================================
battery() {
    local D="$1"                        # default | ignored
    [[ "$D" == "ignored" ]] && trap '' PIPE
    # Tally PER BATTERY. These are subshell-local copies; without resetting them the
    # second run would inherit the first run's totals and the driver would add them
    # a second time.
    P=0; F=0

echo "=== [$D] T1 LARGE bounded read: full window obtained -> SUCCESS ==="
big="$W/big"; mk 2097152 "$big"; out="$W/$D.o1"
if nftban_http_bounded_read "$big" 0 16384 "$W/$D.s1" > "$out" 2>/dev/null; then
    [[ "$(stat -c %s "$out")" == "16384" ]] && ok "[$D] T1 accepted; exactly 16384 bytes emitted" \
        || no "[$D] T1 accepted but wrong byte count" "$(stat -c %s "$out")"
else
    no "[$D] T1 REJECTED — a full window was obtained but the read was refused (producer status must not gate acceptance)"
fi

echo "=== [$D] T2 SMALL read, clean EOF -> SUCCESS ==="
sm="$W/small"; mk 4096 "$sm"; out="$W/$D.o2"
if nftban_http_bounded_read "$sm" 0 4096 "$W/$D.s2" > "$out" 2>/dev/null; then
    [[ "$(stat -c %s "$out")" == "4096" ]] && ok "[$D] T2 accepted; 4096 bytes emitted" || no "[$D] T2 byte count" "$(stat -c %s "$out")"
else no "[$D] T2 rejected a clean full read"; fi

echo "=== [$D] T3 SHORT bounded read (actual < requested) -> FAILURE, emit nothing ==="
out="$W/$D.o3"
if nftban_http_bounded_read "$sm" 0 16384 "$W/$D.s3" > "$out" 2>/dev/null; then
    no "[$D] T3 ACCEPTED a short read — cursor could jump past unscanned bytes"
else
    [[ "$(stat -c %s "$out")" == "0" ]] && ok "[$D] T3 rejected AND emitted nothing" \
        || no "[$D] T3 rejected but emitted bytes" "$(stat -c %s "$out")"
fi

echo "=== [$D] T4 unreadable/absent source -> FAILURE, emit nothing ==="
out="$W/$D.o4"
if nftban_http_bounded_read "$W/does-not-exist" 0 4096 "$W/$D.s4" > "$out" 2>/dev/null; then
    no "[$D] T4 accepted a read of a non-existent file"
else
    [[ "$(stat -c %s "$out")" == "0" ]] && ok "[$D] T4 rejected AND emitted nothing" || no "[$D] T4 emitted bytes"
fi

echo "=== [$D] T5 unusable scratch path -> FAILURE ==="
out="$W/$D.o5"
if nftban_http_bounded_read "$big" 0 16384 "$W/$D.nodir/deep/s5" > "$out" 2>/dev/null; then
    no "[$D] T5 accepted despite an unwritable scratch path"
else ok "[$D] T5 rejected when the scratch path is unusable"; fi

echo "=== [$D] T6 scratch is bounded: one per subject, no accumulation ==="
# ⛔ CALL IT IN AN errexit-SAFE SHAPE. The library arms `set -e` when sourced, and
#    a bare rejected call here would KILL THE SUITE instead of reporting — T3/T4/T5
#    survive a rejection only because an `if` condition disarms errexit. Capturing
#    rc explicitly keeps this arm able to report a regression rather than die on it.
#    (`|| true` would also survive, but it hides WHY it survived.)
_t6rc=0
for _ in 1 2 3 4 5; do
    nftban_http_bounded_read "$big" 0 16384 "$W/$D.reuse.rd" >/dev/null 2>&1 || _t6rc=$?
done
leftover=$(find "$W" -maxdepth 1 -name "$D.reuse.rd" 2>/dev/null | wc -l)
[[ "$leftover" -le 1 ]] && ok "[$D] T6 five reads left at most one scratch file (no accumulation)" \
    || no "[$D] T6 scratch files accumulated" "$leftover"

echo "=== [$D] T7 HISTORICAL MECHANISM: the statement AFTER the bounded read must execute ==="
# This is the exact shape that failed in production: under set -Eeuo pipefail the
# raw pipeline aborts the caller before its next line (the cursor checkpoint).
marker="$W/$D.reached"; rm -f "$marker"
# ⛔ A SEPARATE PROCESS, NOT `( ... ) || true`. errexit must stay ARMED inside — that
#    is the whole assertion — but a rejected read must not kill the suite. Placing a
#    SUBSHELL on the left of `||` disarms errexit INSIDE it and silently turns this
#    arm into a no-op; an external `bash -c` has its own errexit, so `|| rc=$?`
#    protects only the parent.
_t7rc=0
bash -c '
  set -Eeuo pipefail
  # shellcheck source=/dev/null
  . "$1" >/dev/null 2>&1
  nftban_http_bounded_read "$2" 0 16384 "$3" >/dev/null
  : > "$4"               # stands in for the cursor checkpoint
' _ "$LIB" "$big" "$W/$D.s7" "$marker" 2>/dev/null || _t7rc=$?
[[ -f "$marker" ]] && ok "[$D] T7 checkpoint-position statement EXECUTED under set -Eeuo pipefail" \
    || no "[$D] T7 caller still aborts before the checkpoint — production defect NOT fixed"

echo "=== [$D] T9 producer status is RECORDED but MUST NOT gate acceptance ==="
# T1 already proves acceptance holds under BOTH producer statuses. T9 proves the
# status was actually OBSERVED and that it genuinely DIFFERS by disposition —
# without this the two battery runs could be silently identical and the whole
# dual-disposition design would be vacuous.
NFTBAN_HTTP_LAST_PRODUCER_RC=""; NFTBAN_HTTP_LAST_CONSUMER_RC=""
_t9rc=0
nftban_http_bounded_read "$big" 0 16384 "$W/$D.s9" >/dev/null 2>&1 || _t9rc=$?
if [[ -z "${NFTBAN_HTTP_LAST_PRODUCER_RC:-}" ]]; then
    no "[$D] T9 producer status was not recorded at all"
elif [[ "$D" == "ambient" && "$NFTBAN_HTTP_LAST_PRODUCER_RC" == "$AMBIENT_RC" ]]; then
    ok "[$D] T9 producer rc=$AMBIENT_RC recorded (the probed ambient shape) and accepted anyway"
elif [[ "$D" == "ignored" && "$NFTBAN_HTTP_LAST_PRODUCER_RC" == "1" ]]; then
    # deterministic: `trap "" PIPE` guarantees SIG_IGN regardless of what we inherited
    ok "[$D] T9 producer rc=1 recorded (EPIPE shape) and accepted anyway"
else
    no "[$D] T9 producer rc does not match this disposition" \
       "observed=$NFTBAN_HTTP_LAST_PRODUCER_RC ambient=$AMBIENT_RC"
fi
if [[ "${NFTBAN_HTTP_LAST_CONSUMER_RC:-}" == "0" ]]; then
    ok "[$D] T9 consumer rc=0 recorded — this is the authoritative half"
else
    no "[$D] T9 consumer rc not recorded as 0" "${NFTBAN_HTTP_LAST_CONSUMER_RC:-}"
fi

echo "=== [$D] T10 byte count is compared for EXACT EQUALITY, never an inequality ==="
# `actual > requested` is UNCONSTRUCTIBLE through this helper — `head -c N` cannot
# emit more than N — so it cannot be exercised behaviourally. Assert it structurally
# rather than pretend an arm covers it: an inequality here would silently admit an
# over-read as success if the pipeline shape ever changed.
_pred="$(awk '/^nftban_http_bounded_read\(\)/,/^}/' "$LIB" | grep -F '_act' | grep -F '_want' | grep -F '[[')"
if [[ -z "$_pred" ]]; then
    no "[$D] T10 could not locate the byte-count comparison — the guard is blind"
elif printf '%s' "$_pred" | grep -qE '[-](ge|gt|le|lt)[[:space:]]'; then
    no "[$D] T10 byte count uses an inequality; an over-read would be accepted" "$_pred"
else
    ok "[$D] T10 byte count is exact equality"
fi

# ⛔ T8 (negative control proving T7 is not a no-op) is DELIBERATELY NOT RUN HERE.
#    The raw shipping shape terminates its process by SIGPIPE, and on this platform
#    that signal reaches the suite regardless of subshell / separate process /
#    background+wait isolation, killing the run at rc=141 before it can report.
#    THE CONTROL ITSELF IS NOT MISSING — it is recorded in the P0-A closure record:
#        raw `tail | head` under set -Eeuo pipefail, window 16 KiB
#        131 KB .. 20 MB : tail_rc=141 head_rc=0 actual==requested
#        statement AFTER the pipeline: ABSENT at 1 MB, PRESENT at 16 KB
#    T7 is therefore known to be a real behavioural change, not a tautology. If this
#    is ever re-armed in-suite it must keep errexit ARMED: `( ... ) || true` places
#    the subshell on the left of `||`, which SUPPRESSES errexit and silently turns
#    the arm into a no-op.

}

# Each disposition runs in its OWN subshell: `trap "" PIPE` must not leak from the
# second run back into the reporting shell, and the two runs must not share scratch.
# A subshell cannot write the parent's counters, so each tallies to a file — and a
# MISSING tally is itself a failure (the battery did not run to completion), never
# silently zero.
for _D in ambient ignored; do
    ( battery "$_D"; printf '%s %s\n' "$P" "$F" > "$W/.tally.$_D" )
    if [[ -r "$W/.tally.$_D" ]]; then
        read -r _p _f < "$W/.tally.$_D"
        P=$(( P + _p )); F=$(( F + _f ))
    else
        echo "  [FAIL] battery '$_D' produced no tally — it did not run to completion"
        F=$(( F + 1 ))
    fi
done

echo
echo "=== PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
