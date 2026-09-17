#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.231.0 - BotScan emission-count truth (P0-B) behavioral regression
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_emission_count_truth_v1231_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-16"
# meta:description="BEHAVIORAL (not source-text) regression guard for the v1.231.0 P0-B emission-count truth defect. Two counters crossed one execution boundary and both arrived dead: (B1) _BOTSCAN_SIGNALS_EMITTED is incremented only inside nftban_botscan_write_signal, every caller of which runs inside the fork created by the command substitution that invoked nftban_botscan_analyze, so 100% of increments were discarded (shell variable propagation is parent-to-child only) and signals_emitted_total was permanently 0; (B2) nftban_botscan_analyze encoded its ban COUNT as its EXIT STATUS while the caller captured STDOUT, so count greater than 0 gave rc != 0 which tripped the '|| banned=0' fallback and count == 0 gave an empty stdout on the batch-signal path -- 'banned' was ALWAYS empty or 0, the rendered ban line was malformed on a clean cycle, bans_emitted_total was permanently 0, and the OK_SCANNED_BOTS_FOUND health state was unreachable in production. This test drives the real process_logs pipeline over a PINNED fixture log (an explicit first argument gates off forward-cursor consumption, per-file spool reap, spool reclamation and prefilter-engine variance, each of which is guarded by its own empty-log_file test) and asserts the parent observes real numeric counts, that runstate.json carries them, that a second cycle over a second distinct fixture strictly increases both totals, and -- the actual operator-truth contract -- that the per-cycle delta of signals_emitted_total EQUALS the number of batch-signal lines appended that cycle. Closes with a DECLARED INVERSION negative control that neutralizes this fix's own cross-boundary counter sink in a child process and proves the assertions then fail."
#
# meta:input="Synthetic access-log fixtures + threshold-1 patterns in a mktemp sandbox"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/core/nftban_botscan_adaptive.sh"
# meta:inventory.binaries="bash,awk,grep,jq"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,BOTSCAN_PATTERNS_DIR,BOTSCAN_BATCH_SIGNAL_MODE,BOTSCAN_BATCH_SIGNAL_FILE,BOTSCAN_LOG_FILE,BOTSCAN_SPOOL_DIR,BOTSCAN_404_THRESHOLD,BOTSCAN_SCAN_PREFILTER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botscan_emission_count_truth_v1231_0_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-emission-count-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export NFTBAN_LIB_DIR

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# A missing declared dependency is a PRECONDITION failure, never a silent pass.
for _b in jq awk grep; do
  command -v "$_b" >/dev/null 2>&1 || { echo "PRECONDITION_MISSING: $_b (declared in meta:depends)" >&2; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Sandbox. NFTBAN_DATA_DIR must be exported BEFORE sourcing: nftban_botscan_adaptive.sh
# binds _BS_RUNSTATE / _BS_TREND as `readonly` at source time.
# ---------------------------------------------------------------------------
export NFTBAN_DATA_DIR="$tmp/data" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" \
       BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/state.db" \
       BOTSCAN_LOG_FILE="$tmp/botscan.log" \
       BOTSCAN_SPOOL_DIR="$tmp/spool" \
       BOTSCAN_BATCH_SIGNAL_FILE="$tmp/data/botguard/batch_signals.jsonl" \
       BOTSCAN_ENABLED=true \
       BOTSCAN_ACTION_MODE=both \
       BOTSCAN_BATCH_SIGNAL_MODE=true \
       BOTSCAN_SCAN_PREFILTER=false \
       BOTSCAN_SCAN_BUDGET_SECS=0 \
       BOTSCAN_404_THRESHOLD=999 \
       BOTSCAN_ENDPOINT_FLOOD_ENABLED=false
mkdir -p "$NFTBAN_DATA_DIR/botguard" "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR" "$BOTSCAN_SPOOL_DIR"

SIGFILE="$BOTSCAN_BATCH_SIGNAL_FILE"
RUNSTATE="$NFTBAN_DATA_DIR/botscan/runstate.json"

# Threshold-1 UA pattern: one matching request == one ban == one batch signal.
# Fixture/pattern shape proven in botscan_pattern_ban_ifs_v1861_test.sh.
printf 'BADUA|BadCrawler|useragent|1|60|3600|true|UA pattern\n' > "$BOTSCAN_PATTERNS_DIR/test.patterns"

mkfixture() { # $1=path  $2..=last octet of each distinct client IP
  local p="$1"; shift
  : > "$p"
  local o
  for o in "$@"; do
    printf '198.51.100.%s - - [16/Sep/2026:10:00:00 +0000] "GET /a HTTP/1.1" 200 9 "-" "BadCrawler/1.0"\n' \
      "$o" >> "$p"
  done
}
FIX_A="$tmp/a.log"; mkfixture "$FIX_A" 11 12 13          # 3 distinct IPs -> 3 bans
FIX_B="$tmp/b.log"; mkfixture "$FIX_B" 21 22             # 2 distinct IPs -> 2 bans

# The BACKLOG axis short-circuits health_state ahead of the bots axis, and the
# PINNED-log path deliberately never advances a forward cursor, so without this
# seed nftban_botscan_backlog always reports the whole fixture as "behind" and
# DEGRADED_BACKLOG_GROWING masks every other health verdict. Seeding the cursor to
# the file size states the truth for a pinned read (the tail read consumed it) and
# keeps A5 measuring the ban-count axis instead of the backlog axis.
seed_cursor() { # $1 = fixture path
  local d="$NFTBAN_DATA_DIR/botscan/proc-offsets" base
  mkdir -p "$d"
  base="$(printf '%s' "$1" | tr '/' '_')"
  stat -c %s "$1" > "$d/$base"
}

jqi() { # $1=file $2=jq filter -> integer (0 on any failure)
  local v; v="$(jq -r "$2 // 0" "$1" 2>/dev/null)" || v=0
  [[ "$v" =~ ^-?[0-9]+$ ]] || v=0
  printf '%s' "$v"
}
# grep -c exits 1 on zero matches while printing 0 -- capture rc explicitly.
sigcount() { local n; n="$(grep -c '' "$SIGFILE" 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"
nftban_botscan_load_config

echo "=== v1.231.0 P0-B BotScan emission-count truth (behavioral) ==="

# ---------------------------------------------------------------------------
# CYCLE 1 -- PINNED log file. process_logs is invoked in THIS shell (never inside
# a command substitution) so the parent-visible state after it returns is the
# real subject of the assertion.
# ---------------------------------------------------------------------------
seed_cursor "$FIX_A"
sig_before_1="$(sigcount)"
rc=0; nftban_botscan_process_logs "$FIX_A" 60 > "$tmp/out1.txt" 2>"$tmp/err1.txt" || rc=$?
[[ "$rc" -eq 0 ]] && ok "cycle1: process_logs rc=0" || no "cycle1: process_logs rc=$rc (stderr: $tmp/err1.txt)"

# A1 -- parent observes the per-cycle signal counter (B1: survives the fork boundary).
sig_var="${_BOTSCAN_SIGNALS_EMITTED:-unset}"
if [[ "$sig_var" =~ ^[0-9]+$ ]] && [[ "$sig_var" -gt 0 ]]; then
  ok "A1 B1: parent observes _BOTSCAN_SIGNALS_EMITTED=$sig_var (>0) after process_logs"
else
  no "A1 B1: parent observes _BOTSCAN_SIGNALS_EMITTED='$sig_var' -- child-shell increment did not cross the execution boundary"
fi

# A2 -- the rendered ban line is a well-formed integer > 0 (B2: explicit data channel).
banline="$(grep -m1 '^Banned: ' "$tmp/out1.txt" 2>/dev/null || true)"
banned_n="${banline#Banned: }"; banned_n="${banned_n% IPs}"
if [[ "$banned_n" =~ ^[0-9]+$ ]] && [[ "$banned_n" -gt 0 ]]; then
  ok "A2 B2: rendered '$banline' parses as integer $banned_n (>0)"
else
  no "A2 B2: rendered '${banline:-<absent>}' -- ban count is not a positive integer (exit-status channel)"
fi

# A3 -- durable runstate carries both totals.
rs_sig1="$(jqi "$RUNSTATE" '.signals_emitted_total')"
rs_ban1="$(jqi "$RUNSTATE" '.bans_emitted_total')"
[[ "$rs_ban1" -gt 0 ]] && ok "A3 B3: runstate.json .bans_emitted_total=$rs_ban1 (>0)" \
  || no "A3 B3: runstate.json .bans_emitted_total=$rs_ban1 -- durable surface reports no bans"
[[ "$rs_sig1" -gt 0 ]] && ok "A3 B3: runstate.json .signals_emitted_total=$rs_sig1 (>0)" \
  || no "A3 B3: runstate.json .signals_emitted_total=$rs_sig1 -- durable surface reports no signals"

# A4 -- THE OPERATOR-TRUTH CONTRACT, stated RELATIVELY: the per-cycle delta of
# signals_emitted_total must equal the number of batch-signal records appended
# this cycle. Holds regardless of how much of the fixture was consumed.
sig_after_1="$(sigcount)"
d_jsonl_1=$(( sig_after_1 - sig_before_1 ))
if [[ "$rs_sig1" -eq "$d_jsonl_1" ]]; then
  ok "A4: delta signals_emitted_total ($rs_sig1) == batch_signals.jsonl lines appended ($d_jsonl_1)"
else
  no "A4: delta signals_emitted_total ($rs_sig1) != batch_signals.jsonl lines appended ($d_jsonl_1)"
fi

# A5 -- health input truth: with bans > 0 and lines scanned > 0 the recorded
# health_state must be OK_SCANNED_BOTS_FOUND, which was unreachable while the
# ban count was structurally 0.
hs1="$(jq -r '.health_state // "ABSENT"' "$RUNSTATE" 2>/dev/null || echo ABSENT)"
[[ "$hs1" == "OK_SCANNED_BOTS_FOUND" ]] \
  && ok "A5 B3: health_state=OK_SCANNED_BOTS_FOUND (classifier received a real ban count)" \
  || no "A5 B3: health_state=$hs1 -- expected OK_SCANNED_BOTS_FOUND"

# A6 -- trend JSONL records the real ban count for this cycle.
tr_ban1="$(tail -n 1 "$NFTBAN_DATA_DIR/botscan/trend.jsonl" 2>/dev/null | jq -r '.bans_emitted // -1' 2>/dev/null || echo -1)"
if [[ "$tr_ban1" =~ ^[0-9]+$ ]] && [[ "$tr_ban1" -gt 0 ]]; then
  ok "A6 B3: trend.jsonl last record .bans_emitted=$tr_ban1 (>0)"
else
  no "A6 B3: trend.jsonl last record .bans_emitted=$tr_ban1 -- trend surface reports no bans"
fi

# ---------------------------------------------------------------------------
# CYCLE 2 -- a SECOND DISTINCT fixture. Pins the accumulate path in
# nftban_botscan_record_runstate (prior totals are read back with jq and added).
# ---------------------------------------------------------------------------
seed_cursor "$FIX_B"
sig_before_2="$(sigcount)"
rc=0; nftban_botscan_process_logs "$FIX_B" 60 > "$tmp/out2.txt" 2>"$tmp/err2.txt" || rc=$?
[[ "$rc" -eq 0 ]] && ok "cycle2: process_logs rc=0" || no "cycle2: process_logs rc=$rc"

rs_sig2="$(jqi "$RUNSTATE" '.signals_emitted_total')"
rs_ban2="$(jqi "$RUNSTATE" '.bans_emitted_total')"
[[ "$rs_sig2" -gt "$rs_sig1" ]] \
  && ok "A7: signals_emitted_total strictly increased across cycles ($rs_sig1 -> $rs_sig2)" \
  || no "A7: signals_emitted_total did not increase ($rs_sig1 -> $rs_sig2)"
[[ "$rs_ban2" -gt "$rs_ban1" ]] \
  && ok "A7: bans_emitted_total strictly increased across cycles ($rs_ban1 -> $rs_ban2)" \
  || no "A7: bans_emitted_total did not increase ($rs_ban1 -> $rs_ban2)"

sig_after_2="$(sigcount)"
d_jsonl_2=$(( sig_after_2 - sig_before_2 ))
d_rs_2=$(( rs_sig2 - rs_sig1 ))
if [[ "$d_rs_2" -eq "$d_jsonl_2" ]]; then
  ok "A8: cycle2 delta signals_emitted_total ($d_rs_2) == batch_signals.jsonl lines appended ($d_jsonl_2)"
else
  no "A8: cycle2 delta signals_emitted_total ($d_rs_2) != batch_signals.jsonl lines appended ($d_jsonl_2)"
fi

# A9 -- per-cycle scope: the counter sink is reset by init_state, so the value the
# parent reads after cycle 2 must be cycle 2's count, never a running total.
sig_var2="${_BOTSCAN_SIGNALS_EMITTED:-unset}"
if [[ "$sig_var2" =~ ^[0-9]+$ ]] && [[ "$sig_var2" -eq "$d_jsonl_2" ]]; then
  ok "A9: _BOTSCAN_SIGNALS_EMITTED=$sig_var2 is CYCLE-scoped (== cycle2 appends), not cumulative"
else
  no "A9: _BOTSCAN_SIGNALS_EMITTED='$sig_var2' != cycle2 appends ($d_jsonl_2) -- per-cycle reset broken"
fi

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL -- DECLARED INVERSION of THIS fix (never a historical
# checkout: origin/main inverts the moment this merges).
#
# INVERSION DECLARED: neutralize the cross-boundary counter sink introduced by
# P0-B -- nftban_botscan_counter_add becomes a no-op and nftban_botscan_counter_get
# always answers 0. That reproduces the pre-fix arithmetic exactly: the only
# surviving channel for either counter is a shell variable mutated inside the
# fork, so the parent observes 0 for signals AND for bans while detection itself
# (batch-signal emission) still happens.
#
# Run in a REAL child process (bash -c) so errexit stays armed inside it; rc is
# captured explicitly rather than swallowed by a `( ... ) || true` subshell.
# ---------------------------------------------------------------------------
FIX_C="$tmp/c.log"; mkfixture "$FIX_C" 31 32
inv_rc=0
inv_out="$(bash -c '
  set -Eeuo pipefail
  export NFTBAN_DATA_DIR="$1/inv" NFTBAN_CONFIG_DIR="$1/noetc" \
         BOTSCAN_PATTERNS_DIR="$2" BOTSCAN_STATE_FILE="$1/inv-state.db" \
         BOTSCAN_LOG_FILE="$1/inv-botscan.log" BOTSCAN_SPOOL_DIR="$1/inv-spool" \
         BOTSCAN_BATCH_SIGNAL_FILE="$1/inv/botguard/batch_signals.jsonl" \
         BOTSCAN_ENABLED=true BOTSCAN_ACTION_MODE=both BOTSCAN_BATCH_SIGNAL_MODE=true \
         BOTSCAN_SCAN_PREFILTER=false BOTSCAN_SCAN_BUDGET_SECS=0 \
         BOTSCAN_404_THRESHOLD=999 BOTSCAN_ENDPOINT_FLOOD_ENABLED=false
  mkdir -p "$NFTBAN_DATA_DIR/botguard" "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_SPOOL_DIR"
  # shellcheck source=/dev/null
  source "$4/core/nftban_botscan.sh"
  nftban_botscan_load_config
  # --- DECLARED INVERSION of our own v1.231.0 P0-B code ---
  nftban_botscan_counter_add() { return 0; }
  nftban_botscan_counter_get() { printf 0; }
  prc=0
  nftban_botscan_process_logs "$3" 60 >/dev/null 2>&1 || prc=$?
  printf "%s %s %s %s\n" \
    "${_BOTSCAN_SIGNALS_EMITTED:-0}" \
    "$(jq -r ".signals_emitted_total // 0" "$NFTBAN_DATA_DIR/botscan/runstate.json" 2>/dev/null || echo 0)" \
    "$(jq -r ".bans_emitted_total // 0"    "$NFTBAN_DATA_DIR/botscan/runstate.json" 2>/dev/null || echo 0)" \
    "$prc"
' _ "$tmp" "$BOTSCAN_PATTERNS_DIR" "$FIX_C" "$NFTBAN_LIB_DIR" 2>/dev/null)" || inv_rc=$?

if [[ "$inv_rc" -ne 0 ]]; then
  # A child that never reached its printf is UNMEASURED, not a pass and not a fail-proof.
  no "A10 negative control: inverted child exited rc=$inv_rc -- UNMEASURED, not a proof"
else
  # IFS=' ' is REQUIRED: nftban_botscan.sh sets a global IFS=$'\n\t' (no space) at
  # source time, so a bare `read` would yield ONE token (v1.186.1 defect class).
  IFS=' ' read -r inv_var inv_sig inv_ban inv_prc <<< "$inv_out"
  inv_batch="$(grep -c '' "$tmp/inv/botguard/batch_signals.jsonl" 2>/dev/null)" || inv_batch=0
  [[ "$inv_batch" =~ ^[0-9]+$ ]] || inv_batch=0
  if [[ "$inv_batch" -gt 0 ]]; then
    ok "A10a negative control: inverted build still EMITTED $inv_batch batch signal(s) -- the control reached the counted path (the defect is the COUNT, not the detection)"
  else
    no "A10a negative control: inverted build emitted 0 batch signals -- the control never reached the counted path, so it proves nothing"
  fi
  if [[ "$inv_var" == "0" && "$inv_sig" == "0" && "$inv_ban" == "0" ]]; then
    ok "A10b negative control: with the P0-B sink inverted, parent var=$inv_var signals_total=$inv_sig bans_total=$inv_ban (all 0; inner process_logs rc=$inv_prc) -- A1-A9 are bound to the fix"
  else
    no "A10b negative control: inverted build still reported var=$inv_var signals_total=$inv_sig bans_total=$inv_ban -- the assertions are NOT bound to the sink"
  fi
fi

echo "=== A11 CONCURRENCY: the sink claims LOST-UPDATE-IMPOSSIBLE-BY-CONSTRUCTION ==="
# The design claim must be EXERCISED, not asserted. This sink was chosen over
# repairing an unlocked read-modify-write primitive precisely because appending
# "<name> <delta>" and summing on read makes a lost update structurally impossible.
# An unexercised "impossible by construction" is indistinguishable from a bug nobody
# has triggered yet. N concurrent writers must sum EXACTLY — no tolerance.
_A11_DIR="$(mktemp -d)"
_A11_WRITERS=8; _A11_EACH=50; _A11_WANT=$(( _A11_WRITERS * _A11_EACH ))
_a11_run() {                       # $1 = PATH for the writers, $2 = sink file
    local _p="$1" _f="$2"
    : > "$_f"
    for _ in $(seq 1 "$_A11_WRITERS"); do
        (
            PATH="$_p"
            for _ in $(seq 1 "$_A11_EACH"); do
                _nftban_counter_file_add "$_f" "sig" 1
            done
        ) &
    done
    wait
    _nftban_counter_file_get "$_f" "sig"
}
_A11_GOT="$(_a11_run "$PATH" "$_A11_DIR/counters")"
if [[ "$_A11_GOT" == "$_A11_WANT" ]]; then
    ok "A11 $_A11_WRITERS concurrent writers x $_A11_EACH increments summed EXACTLY to $_A11_WANT"
else
    no "A11 concurrent sum is $_A11_GOT, expected $_A11_WANT" "LOST UPDATE — the sink is not append-atomic here"
fi

echo "=== A11b CONCURRENCY WITHOUT flock: the degraded path must ALSO be exact ==="
# The claim is BY CONSTRUCTION, not by locking. Removing flock must not change the
# result. If this arm needs flock to pass, the sink is merely "locked" — which is
# exactly what _ptf_state_incr was rejected for.
_A11_BIN="$_A11_DIR/nolock"; mkdir -p "$_A11_BIN"
for _t in awk stat cat seq mktemp rm; do
    _src="$(command -v "$_t" 2>/dev/null)"
    [[ -n "$_src" ]] && ln -sf "$_src" "$_A11_BIN/$_t" 2>/dev/null
done
if PATH="$_A11_BIN" command -v flock >/dev/null 2>&1; then
    no "A11b precondition: flock is still resolvable on the stripped PATH" "arm would be vacuous"
else
    _A11B_GOT="$(_a11_run "$_A11_BIN" "$_A11_DIR/counters_nolock")"
    if [[ "$_A11B_GOT" == "$_A11_WANT" ]]; then
        ok "A11b without flock, $_A11_WRITERS concurrent writers still summed EXACTLY to $_A11_WANT"
    else
        no "A11b no-flock concurrent sum is $_A11B_GOT, expected $_A11_WANT" \
           "the sink depends on LOCKING, not on append atomicity — the stated design claim is FALSE"
    fi
fi
rm -rf "$_A11_DIR" 2>/dev/null

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
