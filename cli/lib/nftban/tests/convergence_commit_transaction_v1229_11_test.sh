#!/usr/bin/env bash
# =============================================================================
# NFTBan - convergence commit transaction (v1.229.11 lane 6A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="convergence_commit_transaction_v1229_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-25"
# meta:description="Enforces the lane-6A invariant: generation N becomes authoritative ONLY AFTER the convergence work for N has completed. Proves the generation is not advanced by opening a transaction, that a transaction whose required plan set is incomplete refuses to commit (the exact shape a rebuild killed part-way through leaves behind), that a failure before commit leaves generation N fully readable, that readers select a coherent generation-addressed set, and that a disabled module's ABSENT plan is explicitly valid rather than missing state. The negative control is the pre-fix ordering itself: bump-then-republish is asserted to be observable as an incoherent read, which is what this lane removes."
# meta:ta.id="convergence_commit_transaction_v1229_11_test"
# meta:ta.owner="firewall"
# meta:ta.module="mode-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="90"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.binaries="bash,sed,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_PLAN_RECORD_DIR,NFTBAN_PLAN_GENERATION_FILE,NFTBAN_PLAN_TARGET_GENERATION"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (config and run dirs redirected to a temp dir)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
AUTH="$ROOT/cli/lib/nftban/lib/module_authority.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }

echo "=== convergence commit transaction (v1.229.11 lane 6A) ==="
[[ -f "$AUTH" ]] || { echo "::error::SUBJECT_NOT_FOUND: $AUTH"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d/ddos" "$TMP/conf.d/portscan" "$TMP/run"

export NFTBAN_CONFIG_DIR="$TMP"
export NFTBAN_PLAN_RECORD_DIR="$TMP/run"
# ⛔ The canonical convergence lock resolves from NFTBAN_RUN_DIR, NOT from
# NFTBAN_PLAN_RECORD_DIR. In production both are /run/nftban; in a test they
# diverge, and a suite that redirects only the record dir reaches the REAL
# /run/nftban for its lock — refusing every transaction (rc=7) for reasons that
# have nothing to do with the behaviour under test.
#   REDIRECTING ONE RUNTIME PATH IS NOT ISOLATING THE RUNTIME.
export NFTBAN_RUN_DIR="$TMP/run"
export NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation"
# shellcheck source=/dev/null
source "$AUTH"

setcfg() {  # setcfg <module> <enabled> <mode>
    local K; K="$( [[ $1 == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="%s"\n%s_MODE="%s"\n' "$K" "$2" "$K" "$3" > "$TMP/conf.d/$1/main.conf"
}
stage() {   # stage <module> <generation> [effective] [configured]
    printf 'NFTBAN_PLAN_MODULE=%s\nNFTBAN_PLAN_CONFIGURED_MODE=%s\nNFTBAN_PLAN_EFFECTIVE_MODE=%s\nNFTBAN_PLAN_BOUND_GENERATION=%s\n' \
        "$1" "${4:-auto}" "${3:-classic}" "$2" > "$(nftban_plan_record_path "$1" "$2")"
}
gen()  { nftban_plan_generation_current; }
# THE READ PATH under test is nftban_module_report_modes (NFTBAN_REPORT_* axes),
# NOT nftban_module_resolve_plan — the resolver DECIDES a mode, the reporter only
# reads what a completed transaction recorded.
#   RESOLVER != READER. THEY MUST NOT BE TESTED THROUGH EACH OTHER.
eff()  { nftban_module_report_modes "$1" | sed -n 's/^NFTBAN_REPORT_EFFECTIVE_MODE=//p'; }
basis(){ nftban_module_report_modes "$1" | sed -n 's/^NFTBAN_REPORT_EFFECTIVE_BASIS=//p'; }
reset_state() {
    rm -f "$TMP/run"/module-plan-* "$NFTBAN_PLAN_GENERATION_FILE" 2>/dev/null || true
    unset NFTBAN_PLAN_TARGET_GENERATION NFTBAN_PLAN_TXN_RERESOLVE
}

# -----------------------------------------------------------------------------
# T1 — ABSENT GENERATION FILE -> FIRST GENERATION CREATION
# An absent file is generation 0. The first transaction targets 1 and commits it
# only once the required set exists.
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
eq "T1.1 absent generation file reads as 0" "$(gen)" "0"
nftban_plan_txn_begin ddos portscan
eq "T1.2 opening a transaction does NOT advance the generation" "$(gen)" "0"
eq "T1.3 target is the uncommitted next generation" "${NFTBAN_PLAN_TARGET_GENERATION}" "1"
stage ddos 1; stage portscan 1
nftban_plan_txn_commit && rc=0 || rc=$?
eq "T1.4 commit with a complete required set succeeds" "$rc" "0"
eq "T1.5 generation advanced exactly once, at commit" "$(gen)" "1"

# -----------------------------------------------------------------------------
# T2 — EXISTING GENERATION -> NEXT GENERATION
# -----------------------------------------------------------------------------
nftban_plan_txn_begin ddos portscan
eq "T2.1 second transaction targets N+1" "${NFTBAN_PLAN_TARGET_GENERATION}" "2"
eq "T2.2 generation still N while the transaction is open" "$(gen)" "1"
stage ddos 2; stage portscan 2
nftban_plan_txn_commit
eq "T2.3 generation advanced to 2 on commit" "$(gen)" "2"
eq "T2.4 the committed generation-1 set is still on disk (readable history)" \
   "$([[ -r "$(nftban_plan_record_path ddos 1)" ]] && echo yes || echo no)" "yes"

# -----------------------------------------------------------------------------
# T3 — THE MOTIVATING DEFECT: TRUNCATED CONVERGENCE MUST NOT COMMIT
# This is srv3's exact shape — the generation advanced while the module re-apply
# that republishes plans never ran.
#   A TRUNCATED TRANSACTION MUST NOT BE COMMITTABLE.
# -----------------------------------------------------------------------------
nftban_plan_txn_begin ddos portscan
stage ddos 3                     # portscan's re-apply never happened
nftban_plan_txn_commit 2>/dev/null && rc=0 || rc=$?
eq "T3.1 commit REFUSES an incomplete required set" "$rc" "6"
eq "T3.2 generation NOT advanced by the refused commit" "$(gen)" "2"
eq "T3.3 the refused transaction left no generation-3 artifacts" \
   "$(find "$TMP/run" -maxdepth 1 -name 'module-plan-*.env.3' | wc -l)" "0"

# -----------------------------------------------------------------------------
# T4 — GENERATION N REMAINS FULLY READABLE AFTER A FAILED TRANSACTION
# -----------------------------------------------------------------------------
eq "T4.1 ddos still resolves from the committed generation" "$(eff ddos)" "classic"
eq "T4.2 basis is the current plan, not a failure state" "$(basis ddos)" "current_plan"
eq "T4.3 portscan still resolves from the committed generation" "$(eff portscan)" "classic"

# -----------------------------------------------------------------------------
# T5 — MODE=auto ON AN ENABLED MODULE RESOLVES FROM THE PLAN, NEVER THE READER
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
printf '1\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 1 suricata auto
eq "T5.1 auto + bound plan -> the plan's decision" "$(eff ddos)" "suricata"
eq "T5.2 the reader did not resolve auto itself" "$(basis ddos)" "current_plan"

# -----------------------------------------------------------------------------
# T6 — DISABLED MODULE: ABSENCE IS EXPLICITLY VALID, NOT MISSING STATE
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan false auto
printf '5\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 6
nftban_plan_txn_begin ddos
req="$(nftban_plan_txn_required_modules)"
eq "T6.1 a disabled module is NOT in the required set" "$req" "ddos"
stage ddos 6
nftban_plan_txn_commit && rc=0 || rc=$?
eq "T6.2 commit succeeds with the disabled module absent" "$rc" "0"
eq "T6.3 generation advanced" "$(gen)" "6"
eq "T6.4 disabled module reports inactive, not unknown" "$(eff portscan)" "inactive"
eq "T6.5 basis names the disablement" "$(basis portscan)" "module_disabled"

# -----------------------------------------------------------------------------
# T7 — CARRY-FORWARD: A SINGLE-MODULE TRANSACTION KEEPS THE SET COMPLETE
# A standalone `nftban ddos reload` must not drop portscan out of the generation.
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
printf '9\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 9; stage portscan 9 suricata auto
nftban_plan_txn_begin ddos
eq "T7.1 portscan was carried forward to the target" \
   "$([[ -r "$(nftban_plan_record_path portscan 10)" ]] && echo yes || echo no)" "yes"
eq "T7.2 carry-forward rebound the record to the target generation" \
   "$(sed -n 's/^NFTBAN_PLAN_BOUND_GENERATION=//p' "$(nftban_plan_record_path portscan 10)")" "10"
eq "T7.3 carry-forward preserved the resolved decision verbatim" \
   "$(sed -n 's/^NFTBAN_PLAN_EFFECTIVE_MODE=//p' "$(nftban_plan_record_path portscan 10)")" "suricata"
stage ddos 10
nftban_plan_txn_commit
eq "T7.4 both modules resolve from the new generation" "$(eff ddos)/$(eff portscan)" "classic/suricata"

# -----------------------------------------------------------------------------
# T8 — IN-TRANSACTION VERIFICATION READS THE STAGED SET; OUTSIDE READS COMMITTED
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
printf '20\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 20 classic auto
eq "T8.1 outside a transaction the committed set is read" "$(eff ddos)" "classic"
nftban_plan_txn_begin ddos portscan
stage ddos 21 suricata auto
eq "T8.2 the writer verifies its own STAGED set" "$(eff ddos)" "suricata"
eq "T8.3 the generation is still uncommitted during verification" "$(gen)" "20"
( unset NFTBAN_PLAN_TARGET_GENERATION NFTBAN_PLAN_TXN_RERESOLVE
  out="$(nftban_module_report_modes ddos | sed -n 's/^NFTBAN_REPORT_EFFECTIVE_MODE=//p')"
  [[ "$out" == "classic" ]] ) && rc=0 || rc=1
eq "T8.4 an EXTERNAL reader still sees the committed generation" "$rc" "0"
nftban_plan_txn_abort

# -----------------------------------------------------------------------------
# T9 — NEGATIVE CONTROL: THE PRE-FIX ORDERING IS OBSERVABLY INCOHERENT
# Bump first, republish later — the state this lane exists to make unreachable.
# A control that cannot reproduce the motivating defect proves nothing.
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
printf '30\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 30
eq "T9.1 coherent before the bump" "$(eff ddos)" "classic"
printf '31\n' > "$NFTBAN_PLAN_GENERATION_FILE"     # the OLD bump-first behaviour
eq "T9.2 bump-before-republish IS observable as incoherent" "$(eff ddos)" "unknown"
# ⛔ TWO DISTINCT FACTS, BOTH UNKNOWN, DELIBERATELY NOT COLLAPSED. Under
# generation-addressing a bump without republication means THERE IS NO RECORD
# FOR THIS GENERATION. A record that exists but names another generation is a
# different fact and keeps its own basis (T11.2).
#   NO RECORD FOR N != A RECORD BOUND TO SOMETHING ELSE.
eq "T9.3 and it is named, not silently degraded" "$(basis ddos)" "no_current_plan"

# -----------------------------------------------------------------------------
# T10 — REAPING RETAINS A BOUNDED HISTORY AND NEVER THE COMMITTED SET
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan false auto
printf '40\n' > "$NFTBAN_PLAN_GENERATION_FILE"
for g in 36 37 38 39 40; do stage ddos "$g"; done
NFTBAN_PLAN_RETAIN_GENERATIONS=3 nftban_plan_generation_reap 40
eq "T10.1 committed generation retained" \
   "$([[ -r "$(nftban_plan_record_path ddos 40)" ]] && echo yes || echo no)" "yes"
eq "T10.2 predecessor retained" \
   "$([[ -r "$(nftban_plan_record_path ddos 38)" ]] && echo yes || echo no)" "yes"
eq "T10.3 beyond the retention bound reaped" \
   "$([[ -r "$(nftban_plan_record_path ddos 37)" ]] && echo yes || echo no)" "no"

# -----------------------------------------------------------------------------
# T11 — LEGACY UNSUFFIXED RECORD IS READ, BUT THE BINDING CHECK IS NOT RELAXED
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan false auto
printf '50\n' > "$NFTBAN_PLAN_GENERATION_FILE"
printf 'NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\nNFTBAN_PLAN_EFFECTIVE_MODE=classic\nNFTBAN_PLAN_BOUND_GENERATION=50\n' \
    > "$TMP/run/module-plan-ddos.env"
eq "T11.1 a pre-v1.229.11 record still resolves after upgrade" "$(eff ddos)" "classic"
printf 'NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\nNFTBAN_PLAN_EFFECTIVE_MODE=classic\nNFTBAN_PLAN_BOUND_GENERATION=49\n' \
    > "$TMP/run/module-plan-ddos.env"
eq "T11.2 a legacy record bound to another generation is still rejected" "$(eff ddos)" "unknown"

# -----------------------------------------------------------------------------
# T12 — SIGKILL MID-TRANSACTION. The owner's first failure-path witness.
# A writer is KILLED after staging, before commit. Nothing rolls anything back:
# the point of commit-last is that there is nothing inconsistent to roll back.
#   THE PROCESS DIES. THE COMMITTED STATE DOES NOT MOVE.
# ⛔ This is the srv3 shape reproduced deliberately — the installer's 60s kill
# landed exactly here. Pre-v1.229.11 it left gen advanced with stale records; the
# assertion below is that the same kill is now inert.
# -----------------------------------------------------------------------------
reset_state; setcfg ddos true auto; setcfg portscan true auto
printf '60\n' > "$NFTBAN_PLAN_GENERATION_FILE"
stage ddos 60 classic auto; stage portscan 60 suricata auto
NFTBAN_CONFIG_DIR="$TMP" NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
NFTBAN_PLAN_GENERATION_FILE="$NFTBAN_PLAN_GENERATION_FILE" \
bash -c "
    source '$AUTH'
    nftban_plan_txn_begin ddos portscan
    printf 'NFTBAN_PLAN_MODULE=ddos\nNFTBAN_PLAN_CONFIGURED_MODE=auto\nNFTBAN_PLAN_EFFECTIVE_MODE=classic\nNFTBAN_PLAN_BOUND_GENERATION=61\n' \
        > '$TMP/run/module-plan-ddos.env.61'
    kill -9 \$\$
" >/dev/null 2>&1 || true
eq "T12.1 a killed writer did NOT advance the generation" "$(gen)" "60"
eq "T12.2 the committed generation-60 set is still readable" \
   "$([[ -r "$(nftban_plan_record_path ddos 60)" && -r "$(nftban_plan_record_path portscan 60)" ]] && echo yes || echo no)" "yes"
eq "T12.3 readers stay coherent after the kill (ddos)" "$(eff ddos)" "classic"
eq "T12.4 readers stay coherent after the kill (portscan)" "$(eff portscan)" "suricata"
eq "T12.5 no basis degradation — the committed generation is still current" "$(basis ddos)" "current_plan"
# The orphaned staged record is inert: it belongs to a generation nothing selects.
eq "T12.6 the orphaned staged record is unreachable, not authoritative" \
   "$([[ -r "$(nftban_plan_record_path ddos 61)" ]] && echo present || echo absent)/$(gen)" "present/60"
# ⛔ And the NEXT transaction must clear it rather than inherit it — an
# uncommitted artifact from a dead writer must never satisfy a later commit.
nftban_plan_txn_begin ddos portscan
eq "T12.7 the next transaction discards the dead writer's staged artifact" \
   "$([[ -r "$(nftban_plan_record_path ddos 61)" ]] && echo present || echo absent)" "absent"
nftban_plan_txn_abort

echo
if (( FAILURES == 0 )); then echo "PASS — convergence commit transaction"; exit 0; fi
echo "FAIL — $FAILURES assertion(s)"; exit 1
