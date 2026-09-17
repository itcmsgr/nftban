#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotGuard counts: "I could not look" must not become the number 0
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="botguard-count-truth-v1231-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="botguard_count_truth_v1231_test"
# meta:ta.owner="botguard"
# meta:ta.module="botguard-count-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.231.0 FU-5. count_unknown_propagation_v1231_test governs the blacklist/whitelist counters; the BotGuard counter family was ungoverned and laundered an unreadable nftables set into the integer 0 at six sites: the counting primitive _botguard_kernel_set_count (unreadable arm echoed 0), _nftban_botguard_status (twelve counters pre-seeded 0 and overwritten only on a successful existence probe, published with a constant source=\\\"kernel\\\" and a freshly stamped freshness_at so a reading that never happened shipped labelled as the freshest possible one), _nftban_botguard_stats (same pre-seed, plus a grep -c 'timeout' that also counted the set's own flags/timeout header lines), the cmd_status human row (only the IPv4 set was probed, so an absent http_bot_suspect6 reported 0v6), the cmd_status JSON row (NO existence probe at all on the MACHINE-READABLE surface), and the unified exporter (six '// 0' jq defaults plus unconditional metrics+= emission and \\\${bg_X:-0} in the JSON cache, where :- does not fire for the non-empty string UNKNOWN). This proves, with nft and the counts document stubbed, that each surface now keeps UNKNOWN distinguishable from 0 — machine-readable paths emit JSON null or WITHHOLD the Prometheus sample, human paths print UNKNOWN with a FIX hint — while a set that IS readable and empty still reports a legitimate 0 and a populated set still reports its real count. Every arm is paired with a NEGATIVE CONTROL synthesised by DECLARED INVERSION of the current code (never by reading origin/main, which inverts the moment this merges): the pre-fix shape is rebuilt inline and must reproduce the fabricated zero, otherwise the arm is decorative and the suite aborts with exit 2 rather than reporting a pass. THE HARNESS IS PART OF THE SUBJECT (arm 0b). The first lab4 run of this file reported 12 FAILs that were not product defects at all: the function extractor counted brace CHARACTERS, so a \`{\` inside the single-quoted grep pattern at cmd_botguard.sh:200 and one inside a comment at :214 left depth permanently positive and the walk ran to end of file (MEASURED 673 lines captured instead of 34), dragging in the file-scope export -f statements at :843-857; export -f on an undefined name killed the sandbox before any assertion ran, so six arms reported out= rc=1 as if the product had regressed. A second instance of the same class was then found here: block anchors were passed through awk -v, which applies escape-sequence processing, so the \\\" in the cmd_status JSON end anchor was eaten, the anchor never matched and that range also ran to EOF (283 lines instead of 18). Depth is now counted over a quote- and comment-aware CODE-ONLY projection, anchors travel by ENVIRON (no escape processing), and every capture is validated by asking BASH what it defines rather than by trusting the scanner. NOT_EXECUTED is a distinct verdict class with its own exit code 2: a sandbox that cannot construct its subject reports NOT_EXECUTED, never FAIL. Arm 0b reproduces both historical defects against the REAL shipped files by declared inversion and asserts the validators reject each with a NAMED diagnostic, plus that a missing subject yields rc=2 rather than an assertion failure over empty output."
# meta:inventory.files="cli/lib/nftban/cli/cmd_botguard.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh,cli/lib/nftban/lib/nft_schema.sh"
# meta:inventory.binaries="bash,awk,jq"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0; NOTEXEC=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
# ⊘ NOT_EXECUTED is its own verdict class, distinct from FAIL. A harness that
#   could not construct its subject has proved NOTHING about the product; the
#   two must never be conflated. MEASURED on lab4 (Rocky Linux 9.8): a silent
#   over-run in the extractor killed the sandbox before any assertion ran, and
#   six arms reported out='' rc=1 — six phantom PRODUCT regressions whose single
#   cause was the harness. The suite now exits 2 when this count is non-zero.
nx(){ NOTEXEC=$((NOTEXEC+1)); echo "  ⊘ NOT_EXECUTED: $1${2:+ — $2}"; }
echo "=== botguard_count_truth_v1231 ==="

BG="$ROOT/cli/lib/nftban/cli/cmd_botguard.sh"
ST="$ROOT/cli/lib/nftban/cli/cmd_status.sh"
EX="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
NS="$ROOT/cli/lib/nftban/lib/nft_schema.sh"
for f in "$BG" "$ST" "$EX" "$NS"; do
    [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "  FATAL: jq required for the JSON arms"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Subject extraction. Every arm runs the REAL shipped code, never a paraphrase.
# ---------------------------------------------------------------------------
# The obvious extractor counts `{` and `}` characters per line. That counts
# braces which are not block delimiters, and cmd_botguard.sh has two inside
# _botguard_kernel_set_count:
#
#     cmd_botguard.sh:200   if ! echo "$output" | grep -q 'elements = {'; then
#     cmd_botguard.sh:214   # ... an `elements = {` block with no
#
# - one inside a SINGLE-QUOTED grep pattern, one inside a COMMENT. Each pushes
# depth +1 with nothing to close it, so depth never returns to 0, the `exit`
# never fires, and the walk runs to end of file. MEASURED against this very
# file: 673 lines captured instead of 34, dragging in the 14 file-scope
# `export -f` statements at cmd_botguard.sh:843-857. `export -f` on a name the
# capture did not define is a hard error, so the sandbox died during subject
# construction and six arms reported out='' rc=1 as if the PRODUCT had
# regressed. Braces inside quotes or comments are never block delimiters, so
# skipping them is not a heuristic - it is the language.
#
# SCOPE LIMIT, stated rather than hidden: quote state resets at each newline,
# so a string or heredoc spanning several lines is not tracked. fnv() below is
# what makes that safe: it asks bash, not this scanner, what was captured.
cat > "$WORK/fn.awk" <<'FNAWK'
function code_of(s,   i, c, p, out, q, esc, n) {
    out = ""; q = ""; esc = 0; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (esc) { esc = 0; continue }
        if (q == SQ) { if (c == SQ) q = ""; continue }
        if (q == DQ) { if (c == BS) { esc = 1; continue } if (c == DQ) q = ""; continue }
        if (c == BS) { esc = 1; continue }
        if (c == SQ) { q = SQ; continue }
        if (c == DQ) { q = DQ; continue }
        if (c == "#") {
            p = (i == 1) ? " " : substr(s, i - 1, 1)
            if (p == " " || p == "\t" || p == ";" || p == "&" || p == "|" || p == "(") break
        }
        out = out c
    }
    return out
}
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); BS = sprintf("%c", 92)
        found = 0; started = 0; depth = 0 }
!started && $0 ~ "^[[:space:]]*" f "\\(\\)[[:space:]]*\\{" { started = 1; found = 1 }
started {
    print
    line = code_of($0)
    n = gsub(/\{/, "{", line)
    m = gsub(/\}/, "}", line)
    depth += n - m
    if (depth <= 0) exit
}
END { if (!found) exit 3 }
FNAWK
fn(){ awk -v f="$2" -f "$WORK/fn.awk" "$1"; }

# fnv - EXTRACTION VALIDATOR. The scanner is the mechanism; this is the
# guarantee. It does not re-assert the scanner's own rules - it asks BASH what
# the captured text actually is, so the set of functions the sandbox relies on
# is DERIVED from the capture instead of being a hand-kept list that can drift
# out of agreement with it. Prints a NAMED diagnostic and returns non-zero;
# it never silently skips a subject.
fnv(){ # $1=name  $2=captured text
    local _n="$1" _t="$2"
    [[ -n "$_t" ]] || { echo "EXTRACT_EMPTY: $_n - no definition matched"; return 1; }
    # An over-run past the closing brace drags file-scope statements in with it.
    # These two are the exact markers of the lab4 failure, named so that a
    # recurrence is DIAGNOSED rather than merely detected.
    if grep -qE '^[[:space:]]*export -f ' <<<"$_t"; then
        echo "EXTRACT_OVERRAN: $_n - captured file-scope 'export -f' (walk ran past the function)"; return 1
    fi
    if grep -qF 'BASH_SOURCE[0]' <<<"$_t"; then
        echo "EXTRACT_OVERRAN: $_n - captured the file's entrypoint guard"; return 1
    fi
    [[ "$(tail -n1 <<<"$_t")" == "}" ]] || {
        echo "EXTRACT_UNCLOSED: $_n - last captured line is not the closing brace"; return 1; }
    printf '%s\n' "$_t" > "$WORK/fnv.sh"
    bash -n "$WORK/fnv.sh" 2>"$WORK/fnv.err" || {
        echo "EXTRACT_UNPARSEABLE: $_n - $(head -1 "$WORK/fnv.err")"; return 1; }
    # DERIVED, not declared: sourcing only DEFINES; bash then reports what exists.
    bash -c '. "$1" >/dev/null 2>&1; declare -F "$2" >/dev/null 2>&1' _ "$WORK/fnv.sh" "$_n" || {
        echo "EXTRACT_DEFINES_NOTHING: $_n - the captured text defines no such function"; return 1; }
    return 0
}

# Extract an INLINE block (the two cmd_status sites and the exporter site are
# not functions — they live inside multi-hundred-line report builders). Anchored
# on distinctive TEXT, never on line numbers, which drift under any edit.
#
# ⛔ ANCHORS TRAVEL BY ENVIRONMENT, NOT BY `awk -v`. awk applies ESCAPE-SEQUENCE
#    processing to a -v assignment, so a `-v b='\"botguard\": {\"enabled\":'`
#    anchor arrives inside awk as `"botguard": {"enabled":` — the backslashes
#    eaten — and can never match a source line that really does contain them.
#    MEASURED here: the end anchor silently failed to match, `blk` ran to end of
#    file, and the S5 capture was 283 lines instead of 20, dragging in
#    cmd_status.sh's file-scope `export -f` and its entrypoint guard. ENVIRON
#    performs no escape processing, so the anchor arrives verbatim.
#
#    This defect hid behind a verification that used a DIFFERENT quoting path
#    from the test: the anchor was checked with the pattern inline in the awk
#    PROGRAM (where `\"` survives) while the test passes it through -v (where it
#    does not). Verifying a mechanism through a path the subject does not take
#    proves nothing about the subject. Hence blkv() below.
blk(){ NFB_A="$2" NFB_B="$3" awk '
    index($0, ENVIRON["NFB_A"]) { p = 1 }
    p { print }
    p && index($0, ENVIRON["NFB_B"]) { exit }' "$1"; }

# blkv — the same guarantee fn/fnv gives a function capture. The decisive check
# is that the END anchor actually matched: if it did not, the range ran to end
# of file, and the capture is the rest of the file rather than the block.
blkv(){ # $1=label  $2=end-anchor  $3=captured text
    local _l="$1" _b="$2" _t="$3"
    [[ -n "$_t" ]] || { echo "BLOCK_EMPTY: $_l — start anchor never matched"; return 1; }
    if ! grep -qF -- "$_b" <<<"$(tail -n1 <<<"$_t")"; then
        echo "BLOCK_RAN_TO_EOF: $_l — end anchor '$_b' never matched; captured $(wc -l <<<"$_t") lines"
        return 1
    fi
    if grep -qE '^[[:space:]]*export -f ' <<<"$_t"; then
        echo "BLOCK_OVERRAN: $_l — captured file-scope 'export -f'"; return 1
    fi
    if grep -qF 'BASH_SOURCE[0]' <<<"$_t"; then
        echo "BLOCK_OVERRAN: $_l — captured the file's entrypoint guard"; return 1
    fi
    return 0
}

HELPERS="$(fn "$NS" nftban_count_is_known)
$(fn "$NS" nftban_count_sum)
$(fn "$NS" nftban_count_json)"

# nft stubs. The BotGuard CLI runs under `set -Eeuo pipefail`, so each harness
# arms errexit too: a three-valued count that aborts the caller under -e is not
# a fix, and only a REAL CHILD PROCESS keeps errexit armed inside the subject.
NFT_FAIL='return 1;'
NFT_EMPTY='printf "%s\n" "table ip nftban {" "  set x {" "    type ipv4_addr" "    flags timeout" "  }" "}"; return 0;'
NFT_TWO='printf "%s\n" "table ip nftban {" "  set x {" "    type ipv4_addr" "    flags timeout" "    elements = { 10.0.0.1 timeout 1h expires 59m," "                 10.0.0.2 timeout 1h expires 58m }" "  }" "}"; return 0;'

# build <nft-body> <extra-defs> <driver> [required-fn ...]  -> $WORK/h.sh
#
# The sandbox opens with a PRECONDITION that every function the driver is about
# to call is actually defined. Without it an arm cannot tell "the product
# printed nothing" from "the subject was never constructed", and on lab4 that
# ambiguity turned one extractor defect into six phantom product regressions.
# The required set is passed per arm and checked with `declare -F`, so it is
# derived from what the sandbox HAS, never from a list asserting what it should.
build(){
    local _nft="$1" _defs="$2" _drv="$3"; shift 3
    {   echo 'set -Eeuo pipefail'
        echo "nft() { $_nft }"
        echo 'systemctl() { return 1; }'
        cat <<'PRECOND'
__require() {
    local _m="" _f
    for _f in "$@"; do declare -F "$_f" >/dev/null 2>&1 || _m="$_m $_f"; done
    [[ -z "$_m" ]] || {
        printf 'HARNESS_NOT_EXECUTED: undefined subject function(s):%s\n' "$_m" >&2
        exit 2
    }
}
PRECOND
        printf '%s\n' "$HELPERS"
        printf '%s\n' "$_defs"
        [[ $# -eq 0 ]] || printf '__require %s\n' "$*"
        printf '%s\n' "$_drv"
    } > "$WORK/h.sh"
    # A subject that dragged file-scope statements in with it must never be
    # EXECUTED: `export -f` on an undefined name aborts the sandbox before the
    # precondition can report anything useful. Refuse at BUILD time instead.
    if grep -qE '^[[:space:]]*export -f ' "$WORK/h.sh"; then
        printf 'HARNESS_NOT_EXECUTED: sandbox contains file-scope export -f\n' > "$WORK/err"
        HARNESS_POISONED=1
    else
        HARNESS_POISONED=0
    fi
}
# run the harness, capturing rc EXPLICITLY. A bare call under this file's own
# options must never decide the suite's fate.
#
# HARNESS_OK distinguishes "the sandbox could not be constructed" (verdict
# NOT_EXECUTED) from "the subject ran and produced the wrong answer" (FAIL).
run(){
    HARNESS_OK=1
    if [[ "${HARNESS_POISONED:-0}" -eq 1 ]]; then RC=2; OUT=""; HARNESS_OK=0; return 0; fi
    RC=0; OUT="$(bash "$WORK/h.sh" 2>"$WORK/err")" || RC=$?
    if [[ "$RC" -eq 2 ]] && grep -q 'HARNESS_NOT_EXECUTED' "$WORK/err" 2>/dev/null; then
        HARNESS_OK=0
    fi
}
# bad — the failure reporter for every SANDBOX-DRIVEN assertion. Routes to
# NOT_EXECUTED when the sandbox never ran, so a harness defect can never be
# reported as a product defect.
bad(){
    if [[ "${HARNESS_OK:-1}" -eq 0 ]]; then
        nx "$1" "$(head -1 "$WORK/err" 2>/dev/null)"
    else
        no "$1" "${2-}"
    fi
}

# ⛔ SUBJECT-EXECUTION GUARD. Every arm asserts on captured stdout, and a subject
#    that was never extracted also produces empty stdout. Without this, a harness
#    that silently failed to find its subject looks exactly like a subject that
#    printed nothing — and the whole file would pass while testing NOTHING.
#    This distinguishes NOT_EXECUTED (exit 2) from PASS and FAIL.
echo "--- 0. the harness can actually extract its subjects ---"
S1="$(fn "$BG" _botguard_kernel_set_count)"
S2="$(fn "$BG" _nftban_botguard_status)"
S3="$(fn "$BG" _nftban_botguard_stats)"
# S4 ends at the UNREADABLE arm; the block's own trailing `fi` is re-attached by
# the driver below (the range's natural `fi` terminators are nested).
S4="$(blk "$ST" 'local v4_suspects=UNKNOWN' 'botguard_status="ENABLED (suspect sets UNREADABLE')"
S5="$(blk "$ST" 'local json_bg_v4=' '\"botguard\": {\"enabled\":')"
S6EMIT="$(awk '/^        _emit_count\(\) \{/,/^        \}/' "$EX")"
S6="$(blk "$EX" '--- Botguard Metrics (LIVE' 'nftban_count_sum "$bg_suspect"')"

_missing=""
# Each captured FUNCTION is validated by asking bash what it actually is. The
# bare `-n` emptiness tests that follow are necessary but nowhere near
# sufficient: the lab4 over-run captured 673 NON-EMPTY lines and would have
# sailed through an emptiness check while poisoning every arm downstream.
for _pair in "_botguard_kernel_set_count:$S1" \
             "_nftban_botguard_status:$S2" \
             "_nftban_botguard_stats:$S3"; do
    _fname="${_pair%%:*}"
    _diag="$(fnv "$_fname" "${_pair#*:}")" || _missing="$_missing [$_diag]"
done
for _h in nftban_count_is_known nftban_count_sum nftban_count_json; do
    _diag="$(fnv "$_h" "$(fn "$NS" "$_h")")" || _missing="$_missing [$_diag]"
done
# Each captured INLINE BLOCK is validated the same way — above all, that its
# END anchor really matched, which is the falsifier for a range that ran to EOF.
_diag="$(blkv "S4:cmd_status-human-botguard-row" 'botguard_status="ENABLED (suspect sets UNREADABLE' "$S4")" \
    || _missing="$_missing [$_diag]"
_diag="$(blkv "S5:cmd_status-json-botguard-row" '\"botguard\": {\"enabled\":' "$S5")" \
    || _missing="$_missing [$_diag]"
_diag="$(blkv "S6:exporter-botguard-block" 'nftban_count_sum "$bg_suspect"' "$S6")" \
    || _missing="$_missing [$_diag]"
[[ -n "$S6EMIT" ]] || _missing="$_missing S6:_emit_count-extraction-empty"
# The extracted S4/S5/S6 blocks must contain their DECISION, not just their head.
[[ "$S4" == *'ACTIVE ('* ]] || _missing="$_missing S4:decision-missing"
[[ "$S5" == *'nftban_count_json'* ]] || _missing="$_missing S5:render-missing"
[[ "$S6" == *'_emit_count'* ]] || _missing="$_missing S6:emission-missing"
if [[ -z "$_missing" ]]; then
    ok "all subjects extracted AND validated by bash (no arm can pass by vacuity)"
else
    nx "subject extraction" "$_missing"
    echo "  FATAL: refusing to report on subjects that never executed"
    echo "  This is a HARNESS defect, not a product result. Exit 2 = NOT_EXECUTED."
    exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 0b. the extraction validators detect the defects that actually occurred ---"
# -----------------------------------------------------------------------------
# THE HARNESS IS PART OF THE SUBJECT. Both failures below really happened on
# lab4 (Rocky Linux 9.8) and both were silent: the capture was non-empty and
# plausible, so every emptiness check passed while the sandbox was already
# poisoned. A validator that cannot reproduce its own motivating defect is
# decorative, so each is reproduced here by DECLARED INVERSION against the REAL
# shipped file — not against origin/main, which stops being the pre-fix subject
# the moment this merges.

# INVERSION 1 — the brace-counting extractor, quote- and comment-blind. It is
# reproduced verbatim, then pointed at the real cmd_botguard.sh.
_naive="$(awk -v f=_botguard_kernel_set_count \
    '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
     d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$BG")"
_naive_lines=$(wc -l <<<"$_naive")
_real_lines=$(wc -l <<<"$S1")
if [[ "$_naive_lines" -gt $(( _real_lines * 4 )) ]]; then
    ok "inversion reproduces the over-run: quote-blind walk captured $_naive_lines lines vs $_real_lines"
else
    no "the over-run could not be reproduced — arm 0b proves nothing" \
       "naive=$_naive_lines real=$_real_lines"
    echo "  FATAL: a control that cannot see its own defect must not report a pass"; exit 2
fi
if _diag="$(fnv _botguard_kernel_set_count "$_naive")"; then
    no "fnv ACCEPTED a 'capture' that ran to end of file — the validator is blind"
    echo "  FATAL: an undetecting validator must not be reported as coverage"; exit 2
else
    case "$_diag" in
        EXTRACT_OVERRAN:*) ok "fnv rejects the over-run and NAMES it: ${_diag%% -*}" ;;
        *) no "fnv rejected the over-run but with the wrong diagnosis" "$_diag" ;;
    esac
fi

# INVERSION 2 — the anchor passed through `awk -v`, whose escape processing eats
# the backslashes the source line really contains, so the end anchor can never
# match and the range runs to end of file.
_blkv(){ awk -v a="$2" -v b="$3" 'index($0,a){p=1} p{print} p&&index($0,b){exit}' "$1"; }
_naive5="$(_blkv "$ST" 'local json_bg_v4=' '\"botguard\": {\"enabled\":')"
_naive5_lines=$(wc -l <<<"$_naive5")
_real5_lines=$(wc -l <<<"$S5")
if [[ "$_naive5_lines" -gt $(( _real5_lines * 4 )) ]]; then
    ok "inversion reproduces the anchor miss: -v anchor captured $_naive5_lines lines vs $_real5_lines"
else
    no "the anchor miss could not be reproduced — arm 0b proves nothing" \
       "naive=$_naive5_lines real=$_real5_lines"
    echo "  FATAL: a control that cannot see its own defect must not report a pass"; exit 2
fi
if _diag="$(blkv "S5-inverted" '\"botguard\": {\"enabled\":' "$_naive5")"; then
    no "blkv ACCEPTED a range that ran to end of file — the validator is blind"
    echo "  FATAL: an undetecting validator must not be reported as coverage"; exit 2
else
    case "$_diag" in
        BLOCK_RAN_TO_EOF:*|BLOCK_OVERRAN:*) ok "blkv rejects the anchor miss and NAMES it: ${_diag%% -*}" ;;
        *) no "blkv rejected the anchor miss but with the wrong diagnosis" "$_diag" ;;
    esac
fi

# INVERSION 3 — the sandbox precondition. A driver that calls a function the
# capture never defined must report NOT_EXECUTED (rc=2), never an assertion
# failure over empty output.
build "$NFT_FAIL" 'true' '_function_that_was_never_extracted' _function_that_was_never_extracted
run
if [[ "$RC" -eq 2 && "${HARNESS_OK:-1}" -eq 0 ]]; then
    ok "sandbox precondition turns a missing subject into NOT_EXECUTED (rc=2), not FAIL"
else
    no "a missing subject would still be reported as a product failure" "rc=$RC out='$OUT'"
    echo "  FATAL: NOT_EXECUTED and FAIL must not be conflated"; exit 2
fi


# -----------------------------------------------------------------------------
echo "--- 1. S1 the counting primitive separates 'could not read' from 'empty' ---"
# -----------------------------------------------------------------------------
build "$NFT_FAIL" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"' _botguard_kernel_set_count
run
if [[ "$OUT" == "UNKNOWN" && "$RC" -eq 0 ]]; then
    ok "unreadable set -> UNKNOWN (rc=0, caller not aborted)"
else
    bad "unreadable set did not report UNKNOWN" "out='$OUT' rc=$RC"
fi

build "$NFT_EMPTY" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"' _botguard_kernel_set_count
run
if [[ "$OUT" == "0" && "$RC" -eq 0 ]]; then
    ok "readable but EMPTY set -> 0 (a legitimate known zero, not UNKNOWN)"
else
    bad "an empty-but-readable set stopped reporting a legitimate 0" "out='$OUT' rc=$RC"
fi

build "$NFT_TWO" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"' _botguard_kernel_set_count
run
if [[ "$OUT" == "2" && "$RC" -eq 0 ]]; then
    ok "populated set -> 2 (the HEALTHY path is numerically unchanged)"
else
    bad "the healthy counting path regressed" "out='$OUT' rc=$RC"
fi

# NEGATIVE CONTROL — DECLARED INVERSION of the line above. Not read from
# origin/main: that ref inverts the moment this change merges, so it can never
# serve as an immutable pre-fix subject.
cat > "$WORK/nc1.sh" <<'NC1'
_prefix_kernel_set_count() {
    local table="$1" set_name="$2" output
    output=$(nft list set $table "$set_name" 2>/dev/null) || { echo "0"; return; }
    echo "readable"
}
NC1
build "$NFT_FAIL" "$(cat "$WORK/nc1.sh")" '_prefix_kernel_set_count "ip nftban" "http_bot_suspect"' _prefix_kernel_set_count
run
if [[ "$OUT" == "0" ]]; then
    ok "negative control: the PRE-FIX primitive DOES fabricate 0 (arm 1 discriminates)"
else
    bad "negative control FAILED — the pre-fix shape did not reproduce the defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 2. S2 'nftban botguard status' — JSON nulls, and no fake authority ---"
# -----------------------------------------------------------------------------
S2DEFS="_botguard_config_get() { echo \"\${2:-}\"; }
_BOTGUARD_CONF=/dev/null
_BOTGUARD_CONF_LOCAL=/dev/null
$S1
$S2"

build "$NFT_FAIL" "$S2DEFS" '_nftban_botguard_status true' \
    _nftban_botguard_status _botguard_kernel_set_count _botguard_config_get nftban_count_json
run
printf '%s' "$OUT" > "$WORK/s2_bad.json"
if [[ "$RC" -ne 0 ]]; then
    bad "status aborted under errexit on an unreadable kernel" "rc=$RC $(head -1 "$WORK/err")"
elif ! jq -e . "$WORK/s2_bad.json" >/dev/null 2>&1; then
    bad "status emitted UNPARSEABLE JSON on the unreadable path" "$(head -c 200 "$WORK/s2_bad.json")"
else
    ok "unreadable kernel: status still emits VALID JSON (rc=0)"
    _nulls=$(jq '[.sets[][]] | map(select(. == null)) | length' "$WORK/s2_bad.json")
    _zeros=$(jq '[.sets[][]] | map(select(. == 0)) | length' "$WORK/s2_bad.json")
    if [[ "$_nulls" == "12" && "$_zeros" == "0" ]]; then
        ok "all 12 set counts are null; ZERO of them were fabricated as 0"
    else
        bad "the JSON surface published a number nobody measured" "nulls=$_nulls zeros=$_zeros"
    fi
    if [[ "$(jq -r '.source' "$WORK/s2_bad.json")" == "unavailable" ]]; then
        ok "source='unavailable' — the reading is no longer labelled 'kernel'"
    else
        bad "an unperformed reading still claims a source" "source=$(jq -c '.source' "$WORK/s2_bad.json")"
    fi
    if [[ "$(jq -r '.freshness_at' "$WORK/s2_bad.json")" == "null" ]]; then
        ok "freshness_at=null — no authority timestamp on an unmeasured value"
    else
        bad "an unmeasured value acquired a fresh authority timestamp" \
           "freshness_at=$(jq -c '.freshness_at' "$WORK/s2_bad.json")"
    fi
fi

build "$NFT_TWO" "$S2DEFS" '_nftban_botguard_status true' \
    _nftban_botguard_status _botguard_kernel_set_count _botguard_config_get nftban_count_json
run
printf '%s' "$OUT" > "$WORK/s2_ok.json"
if jq -e . "$WORK/s2_ok.json" >/dev/null 2>&1 \
   && [[ "$(jq -r '.sets.suspect.v4' "$WORK/s2_ok.json")" == "2" ]] \
   && [[ "$(jq -r '.source' "$WORK/s2_ok.json")" == "kernel" ]] \
   && [[ "$(jq -r '.freshness_at' "$WORK/s2_ok.json")" =~ ^[0-9]{4}- ]]; then
    ok "readable kernel UNCHANGED: counts numeric, source=kernel, freshness stamped"
else
    bad "the healthy status path regressed" "$(head -c 200 "$WORK/s2_ok.json")"
fi

build "$NFT_FAIL" "$S2DEFS" '_nftban_botguard_status false' \
    _nftban_botguard_status _botguard_kernel_set_count _botguard_config_get nftban_count_is_known
run
if [[ "$OUT" == *"UNKNOWN"* ]] && [[ "$OUT" == *"FIX: systemctl restart nftband"* ]]; then
    ok "human renderer says UNKNOWN and offers the FIX hint"
else
    bad "the human renderer did not name the unknown" "$(printf '%s' "$OUT" | head -c 200)"
fi
if [[ "$OUT" == *"source: unavailable"* ]]; then
    ok "human header reports source: unavailable (not 'kernel')"
else
    bad "the human header still asserts a kernel reading" "$(printf '%s' "$OUT" | grep -F 'Kernel Sets' || true)"
fi

# -----------------------------------------------------------------------------
echo "--- 3. S3 'nftban botguard stats' ---"
# -----------------------------------------------------------------------------
S3DEFS="$S1
$S3"
build "$NFT_FAIL" "$S3DEFS" '_nftban_botguard_stats true' \
    _nftban_botguard_stats _botguard_kernel_set_count nftban_count_json
run
printf '%s' "$OUT" > "$WORK/s3_bad.json"
if [[ "$RC" -eq 0 ]] && jq -e . "$WORK/s3_bad.json" >/dev/null 2>&1; then
    _nulls=$(jq '[.sets[][]] | map(select(. == null)) | length' "$WORK/s3_bad.json")
    _zeros=$(jq '[.sets[][]] | map(select(. == 0)) | length' "$WORK/s3_bad.json")
    if [[ "$_nulls" == "12" && "$_zeros" == "0" ]]; then
        ok "stats JSON: 12 nulls, 0 fabricated zeros"
    else
        bad "stats JSON fabricated a count" "nulls=$_nulls zeros=$_zeros"
    fi
else
    bad "stats aborted or emitted unparseable JSON on the unreadable path" \
       "rc=$RC $(head -c 160 "$WORK/s3_bad.json")"
fi

build "$NFT_TWO" "$S3DEFS" '_nftban_botguard_stats true' \
    _nftban_botguard_stats _botguard_kernel_set_count nftban_count_json
run
printf '%s' "$OUT" > "$WORK/s3_ok.json"
if [[ "$(jq -r '.sets.suspect.v4' "$WORK/s3_ok.json" 2>/dev/null)" == "2" ]]; then
    ok "stats JSON healthy path: suspect.v4=2 (elements only, not header lines)"
else
    bad "the healthy stats path regressed" "$(head -c 160 "$WORK/s3_ok.json")"
fi

# -----------------------------------------------------------------------------
echo "--- 4. S4 'nftban status' human row probes BOTH families ---"
# -----------------------------------------------------------------------------
# The extracted range stops on the UNREADABLE arm; re-attach the `fi` and wrap in
# a function because the block legitimately uses `local`.
S4DEFS="_s4() {
$S4
fi
printf '%s\n' \"\$botguard_status\"
}"
build "$NFT_FAIL" "$S4DEFS" 'botguard_status=DISABLED; _s4' _s4 nftban_count_is_known
run
if [[ "$OUT" == *"UNREADABLE"* ]] && [[ "$OUT" != *"0v4"* ]] && [[ "$OUT" != *"0v6"* ]]; then
    ok "both families unreadable -> UNREADABLE, no fabricated 0v4/0v6"
else
    bad "the human row fabricated a suspect count" "out='$OUT' rc=$RC"
fi

# v4 readable and empty, v6 unreadable: the v6 read must NOT inherit v4's success.
NFT_V4ONLY='if [[ "$*" == *ip6* ]]; then return 1; fi; '"$NFT_EMPTY"
build "$NFT_V4ONLY" "$S4DEFS" 'botguard_status=DISABLED; _s4' _s4 nftban_count_is_known
run
if [[ "$OUT" == *"0v4"* && "$OUT" == *"UNKNOWNv6"* ]]; then
    ok "v4 readable+empty -> 0v4; v6 unreadable -> UNKNOWNv6 (families independent)"
else
    bad "an unread IPv6 set was reported as a measured 0" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: the pre-fix shape gated the v6 read on
# the v4 probe and pre-seeded both to 0.
cat > "$WORK/nc4.sh" <<'NC4'
_prefix_s4() {
    local botguard_status="DISABLED"
    if nft list set ip nftban http_bot_suspect &>/dev/null 2>&1; then
        local v4_suspects=0 v6_suspects=0
        botguard_status="ACTIVE (${v4_suspects}v4+${v6_suspects}v6 suspects)"
    else
        botguard_status="ENABLED (sets not loaded)"
    fi
    printf '%s\n' "$botguard_status"
}
NC4
build "$NFT_V4ONLY" "$(cat "$WORK/nc4.sh")" '_prefix_s4' _prefix_s4
run
if [[ "$OUT" == *"0v6"* ]]; then
    ok "negative control: the PRE-FIX row DOES report 0v6 for an unread set"
else
    bad "negative control FAILED — pre-fix shape did not reproduce the v6 defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 5. S5 'nftban status --json' preserves unknown as null ---"
# -----------------------------------------------------------------------------
S5DEFS="_s5() {
$S5
}"
build "$NFT_FAIL" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5' \
    _s5 nftban_count_json
run
# The site emits one object member with a trailing comma; wrap it to parse.
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_bad.json"
if [[ "$RC" -eq 0 ]] && jq -e . "$WORK/s5_bad.json" >/dev/null 2>&1; then
    if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_bad.json")" == "null" ]] \
    && [[ "$(jq -r '.botguard.ipv6_suspects' "$WORK/s5_bad.json")" == "null" ]]; then
        ok "machine-readable surface: both suspect counts null, neither 0"
    else
        bad "the JSON surface published a zero nobody measured" "$OUT"
    fi
else
    bad "the JSON row aborted or emitted unparseable output" "rc=$RC out='$OUT'"
fi

build "$NFT_TWO" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5' \
    _s5 nftban_count_json
run
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_ok.json"
if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_ok.json" 2>/dev/null)" == "2" ]]; then
    ok "readable kernel still renders the real number (2)"
else
    bad "the healthy JSON path regressed" "out='$OUT'"
fi

build "$NFT_EMPTY" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5' \
    _s5 nftban_count_json
run
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_empty.json"
if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_empty.json" 2>/dev/null)" == "0" ]]; then
    ok "readable-but-empty set still renders a legitimate 0 (not over-converted)"
else
    bad "a legitimate zero was converted into UNKNOWN" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: no existence probe, pre-seeded 0.
cat > "$WORK/nc5.sh" <<'NC5'
_prefix_s5() {
    local json_bg_v4=0 json_bg_v6=0
    local _o4 _o6
    _o4=$(nft list set ip nftban http_bot_suspect 2>/dev/null)
    _o6=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null)
    if echo "$_o4" | grep -q 'elements = {'; then json_bg_v4=1; fi
    if echo "$_o6" | grep -q 'elements = {'; then json_bg_v6=1; fi
    echo "    \"botguard\": {\"ipv4_suspects\": $json_bg_v4, \"ipv6_suspects\": $json_bg_v6},"
}
NC5
build "$NFT_FAIL" "$(cat "$WORK/nc5.sh")" 'set +e; _prefix_s5' _prefix_s5
run
if [[ "$OUT" == *'"ipv4_suspects": 0'* ]]; then
    ok "negative control: the PRE-FIX JSON row DOES publish a fabricated 0"
else
    bad "negative control FAILED — pre-fix shape did not reproduce the JSON defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 6. S6 the exporter WITHHOLDS botguard samples it could not measure ---"
# -----------------------------------------------------------------------------
# An absent series is a state Prometheus and Zabbix both model and alert on; a 0
# asserts a measurement. This matches the established blacklist/whitelist
# precedent already governed by count_unknown_propagation_v1231_test.
# _emit_count is hoisted to SANDBOX TOP LEVEL rather than left nested inside
# _s6. In the shipped exporter it is defined inside the LIVE block, so a nested
# copy is faithful — but a function that only comes into existence once _s6 runs
# cannot be checked by a precondition that runs before it. Hoisting makes the
# publication gate a first-class sandbox subject that __require can verify.
S6DEFS="$S6EMIT
_s6() {
$S6
}"
_metrics_of(){ # $1 = counts_json ; sets OUT to the rendered metric block
    build "$NFT_FAIL" "$S6DEFS" \
        "metrics=''; counts_json='$1'; _s6; printf %b \"\$metrics\"" \
        _s6 _emit_count nftban_count_is_known nftban_count_sum
    run
}

_metrics_of ''
if [[ "$RC" -eq 0 && "$OUT" != *nftban_botguard_set_count* && "$OUT" != *nftban_botguard_total_tracked* ]]; then
    ok "no counts document -> NO botguard samples at all (rc=0)"
else
    bad "the exporter published botguard samples with nothing to measure" "rc=$RC out='$OUT'"
fi

_metrics_of '{"sets":{}}'
if [[ "$RC" -eq 0 && "$OUT" != *nftban_botguard_set_count* ]]; then
    ok "daemon-cache shape present but botguard fields absent -> samples withheld"
else
    bad "missing botguard fields were published as measurements" "rc=$RC out='$OUT'"
fi

_metrics_of '{"sets":{"http_bot_suspect":{"count":3},"http_bot_suspect6":{"count":4},"http_bot_pending":{"count":1},"http_bot_pending6":{"count":0}}}'
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 7'* ]] \
&& [[ "$OUT" == *'nftban_botguard_set_count{category="pending"} 1'* ]]; then
    ok "established counts still publish normally (suspect=7, pending=1)"
else
    bad "the healthy exporter path regressed" "out='$OUT'"
fi
if [[ "$OUT" != *nftban_botguard_total_tracked* ]] && [[ "$OUT" != *'category="allow"'* ]]; then
    ok "UNKNOWN is ABSORBING: the partial total is withheld, not published short"
else
    bad "a total was published that silently omits unreadable components" "out='$OUT'"
fi

_metrics_of '{"botguard":{"suspect":{"ipv4":3,"ipv6":2},"pending":{"ipv4":1,"ipv6":0},"allow":{"ipv4":0,"ipv6":0},"grey":{"ipv4":0,"ipv6":0},"ban":{"ipv4":12,"ipv6":3},"emergency":{"ipv4":0,"ipv6":0}}}'
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 5'* ]] \
&& [[ "$OUT" == *'nftban_botguard_total_tracked 21'* ]]; then
    ok "legacy-kernel shape: suspect=5 and a COMPLETE total publishes (21)"
else
    bad "the legacy-kernel exporter path regressed" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: 0-init plus unconditional emission.
cat > "$WORK/nc6.sh" <<'NC6'
_prefix_s6() {
    local bg_suspect=0 bg_pending=0
    if [[ -n "${counts_json:-}" ]] && command -v jq &>/dev/null; then
        if echo "$counts_json" | jq -e '.sets' &>/dev/null; then
            bg_suspect=$(echo "$counts_json" | jq -r '((.sets.http_bot_suspect.count // 0) + (.sets.http_bot_suspect6.count // 0))')
        fi
    fi
    metrics+="nftban_botguard_set_count{category=\"suspect\"} $bg_suspect\n"
}
NC6
build "$NFT_FAIL" "$(cat "$WORK/nc6.sh")" \
    "metrics=''; counts_json='{\"sets\":{}}'; _prefix_s6; printf %b \"\$metrics\"" _prefix_s6
run
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 0'* ]]; then
    ok "negative control: the PRE-FIX exporter DOES publish a fabricated 0 sample"
else
    bad "negative control FAILED — pre-fix shape did not reproduce the exporter defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 7. the exporter's JSON cache keeps the document PARSEABLE ---"
# -----------------------------------------------------------------------------
# `${x:-0}` substitutes only when x is unset or EMPTY, so it does NOT fire for
# the non-empty string UNKNOWN: the bare word would reach the cache document and
# make the WHOLE file unparseable, after which every downstream `// 0` would
# manufacture the same zero by a longer route.
_n=$(grep -cE '\$\{(bg_[a-z]+|elements_total):-0\}' "$EX") || _n=0
if [[ "$_n" -eq 0 ]]; then
    ok "no '\${x:-0}' laundering over a three-valued count in the cache heredoc"
else
    no "a ':-0' default over a three-valued count survives in the cache heredoc" "$_n occurrence(s)"
fi
_n=$(grep -cE '\$\(\([^)]*\bbg_[a-z]+' "$EX") || _n=0
if [[ "$_n" -eq 0 ]]; then
    ok "no raw \$(( )) arithmetic over a botguard count"
else
    no "raw arithmetic over a botguard count was reintroduced" "$_n occurrence(s)"
fi

echo
echo "=== PASS=$PASS FAIL=$FAIL NOT_EXECUTED=$NOTEXEC ==="
# Verdict precedence: a harness that did not run cannot be said to have passed
# OR failed, so NOT_EXECUTED is reported first and with its own exit code.
[[ "$NOTEXEC" -eq 0 ]] || { echo "VERDICT: NOT_EXECUTED — the harness could not construct its subject"; exit 2; }
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
