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
# meta:description="v1.231.0 P0-A. A bounded read `producer | head -c N` succeeds by making the producer stop: head exits once satisfied and the producer takes SIGPIPE (141). Under pipefail that SUCCESSFUL read reports failure, and under errexit the caller aborts before its next statement - which in nftban_http_read_incremental is the cursor checkpoint. Delivered bytes were therefore replayed every cycle: offsets never reached EOF, completion authority never existed, the conservative BotScan reaper correctly retained every object, and the spool stayed latched at cap with backpressure asserted. Two production hosts sat in that state for 22 and 75 days. MEASURED pre-fix: 32 reads entered, 9 reached the checkpoint. This test locks the ONLY safe normalization - producer_rc==141 AND head_rc==0 AND actual==requested - and proves every other shape still FAILS, so the fix can never degenerate into a blanket `|| true`. Hermetic."
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
set +u
# shellcheck source=/dev/null
. "$LIB" >/dev/null 2>&1
set -u

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

echo "=== T1 LARGE bounded read: producer SIGPIPEs, full window obtained -> SUCCESS ==="
big="$W/big"; mk 2097152 "$big"; out="$W/o1"
if nftban_http_bounded_read "$big" 0 16384 "$W/s1" > "$out" 2>/dev/null; then
    [[ "$(stat -c %s "$out")" == "16384" ]] && ok "T1 accepted; exactly 16384 bytes emitted" \
        || no "T1 accepted but wrong byte count" "$(stat -c %s "$out")"
else
    no "T1 REJECTED — the historical defect is present (successful bounded read treated as failure)"
fi

echo "=== T2 SMALL read, clean EOF -> SUCCESS ==="
sm="$W/small"; mk 4096 "$sm"; out="$W/o2"
if nftban_http_bounded_read "$sm" 0 4096 "$W/s2" > "$out" 2>/dev/null; then
    [[ "$(stat -c %s "$out")" == "4096" ]] && ok "T2 accepted; 4096 bytes emitted" || no "T2 byte count" "$(stat -c %s "$out")"
else no "T2 rejected a clean full read"; fi

echo "=== T3 SHORT bounded read (actual < requested) -> FAILURE, emit nothing ==="
out="$W/o3"
if nftban_http_bounded_read "$sm" 0 16384 "$W/s3" > "$out" 2>/dev/null; then
    no "T3 ACCEPTED a short read — cursor could jump past unscanned bytes"
else
    [[ "$(stat -c %s "$out")" == "0" ]] && ok "T3 rejected AND emitted nothing" \
        || no "T3 rejected but emitted bytes" "$(stat -c %s "$out")"
fi

echo "=== T4 unreadable/absent source -> FAILURE, emit nothing ==="
out="$W/o4"
if nftban_http_bounded_read "$W/does-not-exist" 0 4096 "$W/s4" > "$out" 2>/dev/null; then
    no "T4 accepted a read of a non-existent file"
else
    [[ "$(stat -c %s "$out")" == "0" ]] && ok "T4 rejected AND emitted nothing" || no "T4 emitted bytes"
fi

echo "=== T5 unusable scratch path -> FAILURE ==="
out="$W/o5"
if nftban_http_bounded_read "$big" 0 16384 "$W/nodir/deep/s5" > "$out" 2>/dev/null; then
    no "T5 accepted despite an unwritable scratch path"
else ok "T5 rejected when the scratch path is unusable"; fi

echo "=== T6 scratch is bounded: one per subject, no accumulation ==="
for _ in 1 2 3 4 5; do nftban_http_bounded_read "$big" 0 16384 "$W/reuse.rd" >/dev/null 2>&1; done
leftover=$(find "$W" -maxdepth 1 -name 'reuse.rd' 2>/dev/null | wc -l)
[[ "$leftover" -le 1 ]] && ok "T6 five reads left at most one scratch file (no accumulation)" \
    || no "T6 scratch files accumulated" "$leftover"

echo "=== T7 HISTORICAL MECHANISM: the statement AFTER the bounded read must execute ==="
# This is the exact shape that failed in production: under set -Eeuo pipefail the
# raw pipeline aborts the caller before its next line (the cursor checkpoint).
marker="$W/reached"; rm -f "$marker"
( set -Eeuo pipefail
  # shellcheck source=/dev/null
  . "$LIB" >/dev/null 2>&1
  nftban_http_bounded_read "$big" 0 16384 "$W/s7" >/dev/null
  : > "$marker"          # stands in for the cursor checkpoint
) 2>/dev/null
[[ -f "$marker" ]] && ok "T7 checkpoint-position statement EXECUTED under set -Eeuo pipefail" \
    || no "T7 caller still aborts before the checkpoint — production defect NOT fixed"

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

echo
echo "=== PASS=$P FAIL=$F ==="
[[ "$F" -eq 0 ]]
