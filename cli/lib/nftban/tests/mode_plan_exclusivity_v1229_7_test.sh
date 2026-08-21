#!/usr/bin/env bash
# =============================================================================
# NFTBan - mode plan / exclusivity contract (v1.229.7 PR-3A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="mode_plan_exclusivity_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Enforces the v1.229.7 PR-3A mode-control contract for BOTH ddos and portscan: one operator intent, one mode resolution, one effective mode, one reconciliation path, zero cross-mode full-pipeline calls. Structural arm asserts the prohibited edges (cross-mode full apply, cross-mode config source, consumer calling the resolver, reload reaching a CLI orchestrator). Behavioural arm runs the real resolver: PLAN-N0 proves hybrid never aliases auto/classic/suricata, PLAN-N1 proves the resolver REFUSES a second resolution inside an open transaction (an earlier revision only proved a duplicate was DETECTABLE -- DETECTABLE != REFUSED), PLAN-N2 proves the provenance gate rejects both mixed and missing resolution_id while still accepting matching provenance. Written because CONFIG_EXCLUSIVITY != RUNTIME_EXCLUSIVITY: the defect that started this lane had config saying suricata while runtime ran both pipelines, so the structural arm alone cannot close it -- runtime classic-XOR-suricata is a LAB obligation, declared here and not faked."
# meta:ta.id="mode_plan_exclusivity_v1229_7_test"
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
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh,cli/lib/nftban/core/nftban_ddos_suricata.sh,cli/lib/nftban/core/nftban_portscan_suricata.sh,cli/lib/nftban/cli/cmd_ddos.sh,cli/lib/nftban/cli/cmd_portscan.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only; resolver run against a temp config dir)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

# Strip comments before matching: a comment RECORDING a removed call must not be
# mistaken for the call. SECURITY_GUARD_SOURCE_TEXT_CAN_MATCH_ITS_OWN_POLICY.
code_of() { [[ -f "$1" ]] && sed 's/#.*$//' "$1"; }

# ⛔ NEVER `code_of ... | grep -q`. Under `set -o pipefail`, grep -q exits as soon
# as it matches, sed can die on SIGPIPE (141), and the PIPELINE reports non-zero --
# so a REAL violation reads as "no match" and the guard prints ok. That is the
# failure direction that matters: the check goes quiet exactly when it fires.
#
# Whether it triggers is SIZE-DEPENDENT: on the ~600-line module files sed drains
# before grep exits and the raw pipe happened to work, but on cmd_firewall.sh
# (~4k lines) it did NOT -- section 9 reported ok for a violation that was
# demonstrably present. A check that works only below some file size is not a
# check. Capture first, then match.
#   SIGPIPE + pipefail + grep -q = FALSE "NOT FOUND"
code_has() { local body; body="$(code_of "$1")"; grep -qE "$2" <<<"$body"; }

echo "=== mode plan / exclusivity contract (v1.229.7 PR-3A) ==="

AUTH="$ROOT/cli/lib/nftban/lib/module_authority.sh"
for f in "$AUTH" "$ROOT/cli/lib/nftban/core/nftban_ddos.sh" "$ROOT/cli/lib/nftban/core/nftban_portscan.sh"; do
    [[ -f "$f" ]] || fail "SUBJECT_NOT_FOUND: $f"
done
[[ $FAILURES -eq 0 ]] || { echo "::error::subjects unresolved"; exit 1; }

# --- STRUCTURAL: no cross-mode full apply ------------------------------------
echo ""
echo "1. no cross-mode full apply..."
for spec in "core/nftban_ddos_suricata.sh:nftban_ddos_classic_(enable|disable)" \
            "core/nftban_portscan_suricata.sh:nftban_portscan_classic_(enable|disable)"; do
    rel="cli/lib/nftban/${spec%%:*}"; pat="${spec##*:}"
    if [[ ! -f "$ROOT/$rel" ]]; then ok "$rel absent (nothing to assert)"; continue; fi
    if code_has "$ROOT/$rel" "$pat"; then
        fail "$rel invokes the OTHER mode's full pipeline — CLASSIC_ACTIVE + SURICATA_ACTIVE = INVALID"
    else
        ok "$rel does not invoke the other mode's full pipeline"
    fi
done

# --- STRUCTURAL: no cross-mode config source ---------------------------------
echo ""
echo "2. no cross-mode config source..."
for spec in "core/nftban_ddos_suricata.sh:ddos/classic\.conf" \
            "core/nftban_portscan_suricata.sh:portscan/classic\.conf" \
            "core/nftban_ddos_classic.sh:ddos/suricata\.conf" \
            "core/nftban_portscan_classic.sh:portscan/suricata\.conf"; do
    rel="cli/lib/nftban/${spec%%:*}"; pat="${spec##*:}"
    if [[ ! -f "$ROOT/$rel" ]]; then ok "$rel absent (nothing to assert)"; continue; fi
    if code_has "$ROOT/$rel" "$pat"; then
        fail "$rel sources the OTHER mode's config — CLASSIC CONFIG IS READ ONLY BY CLASSIC MODE"
    else
        ok "$rel does not source the other mode's config"
    fi
done

# --- STRUCTURAL: only the transaction root may resolve -----------------------
echo ""
echo "3. only the reconcile root calls the resolver..."
for mod in ddos portscan; do
    rel="cli/lib/nftban/core/nftban_${mod}.sh"
    body="$(awk -v fn="nftban_${mod}_reconcile" '$0 ~ "^"fn"\\(\\) \\{"{i=1;next} i&&/^\}/{exit} i{print}' "$ROOT/$rel")"
    if [[ -z "$body" ]]; then fail "nftban_${mod}_reconcile not found"; continue; fi
    grep -q "nftban_module_resolve_plan" <<<"$body" \
        && ok "nftban_${mod}_reconcile resolves (it is the root)" \
        || fail "nftban_${mod}_reconcile does not resolve — the root must own resolution"
    # Any OTHER function in the file calling the resolver is a second authority.
    # Count INVOCATIONS only: the guard-source block references the name inside a
    # `declare -F` existence check, which is not a call. An earlier revision
    # counted it and reported a false positive against correct code --
    # A MENTION IS NOT AN INVOCATION.
    others="$(code_of "$ROOT/$rel" | grep "nftban_module_resolve_plan" | grep -vc "declare -F")"
    if [[ "$others" -gt 1 ]]; then
        fail "$rel invokes nftban_module_resolve_plan $others times — only the root may resolve"
    else
        ok "$rel invokes the resolver in exactly one place"
    fi
done

# --- STRUCTURAL: reload/rebuild must not reach a CLI orchestrator ------------
echo ""
echo "4. reload/restart arms use reconcile, not the CLI orchestrators..."
for spec in "cli/cmd_ddos.sh:nftban_ddos" "cli/cmd_portscan.sh:nftban_portscan"; do
    rel="cli/lib/nftban/${spec%%:*}"; pre="${spec##*:}"
    arm="$(awk '/^ *reload\)|^ *reload\|restart\)/{i=1} i{print} i&&/;;/{exit}' "$ROOT/$rel")"
    if [[ -z "$arm" ]]; then fail "$rel reload arm not found"; continue; fi
    if grep -qE "${pre}_(enable|disable)\b" <<<"$arm"; then
        fail "$rel reload calls ${pre}_enable/${pre}_disable — RELOAD != CONFIG MUTATION"
    else
        ok "$rel reload does not reach a CLI orchestrator"
    fi
done

# --- BEHAVIOURAL: run the REAL resolver --------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d/ddos" "$TMP/conf.d/portscan"

plan_field() {  # <module> <field> <MODE value> <available 0|1>
    local mod="$1" field="$2" modeval="$3" avail="$4" key
    key="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="true"\n%s_MODE="%s"\n' "$key" "$key" "$modeval" > "$TMP/conf.d/$mod/main.conf"
    NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return $avail; }
        nftban_module_resolve_plan $mod" | grep "^NFTBAN_PLAN_${field}=" | cut -d= -f2-
}

echo ""
echo "5. PLAN-N0 — hybrid never aliases auto/classic/suricata..."
for mod in ddos portscan; do
    for avail in 0 1; do
        got="$(plan_field "$mod" EFFECTIVE_MODE hybrid "$avail")"
        if [[ "$got" == "unknown" ]]; then
            ok "$mod hybrid -> unknown (suricata_available=$([[ $avail == 0 ]] && echo yes || echo no))"
        else
            fail "$mod hybrid resolved to '$got' — LEGACY VALUE != AUTHORITY TO CHOOSE ITS REPLACEMENT"
        fi
    done
done

echo ""
echo "6. PLAN-N1 — the resolver REFUSES a second resolution inside a transaction..."
# ⛔ The earlier revision of this section asserted only that two resolutions
# produced DIFFERENT ids -- i.e. that a duplicate would be *detectable*.
# DETECTABLE != REFUSED. A mechanism that can tell two resolutions apart but
# still performs both leaves the second-authority defect fully open. This
# section now exercises the enforcement path and requires a non-zero status.
for mod in ddos portscan; do
    printf '%s_ENABLED="true"\n%s_MODE="auto"\n' \
        "$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )" \
        "$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )" > "$TMP/conf.d/$mod/main.conf"
    out="$(NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return 1; }
        # First resolution: the transaction root.
        eval \"\$(nftban_module_resolve_plan $mod)\"
        export NFTBAN_PLAN_TXN_ID=\"\$NFTBAN_PLAN_RESOLUTION_ID\"
        # Second resolution inside the SAME open transaction -- must be refused.
        if nftban_module_resolve_plan $mod >/dev/null 2>&1; then
            echo ACCEPTED_SECOND_RESOLUTION
        else
            echo \"REFUSED rc=\$?\"
        fi" 2>&1 || true)"
    if grep -q "ACCEPTED_SECOND_RESOLUTION" <<<"$out"; then
        fail "$mod resolver PERFORMED a second resolution inside an open transaction — ONE TRANSACTION, ONE RESOLUTION"
    elif grep -q "REFUSED" <<<"$out"; then
        ok "$mod second resolution REFUSED inside an open transaction ($(grep -o 'rc=[0-9]*' <<<"$out" | head -1))"
    else
        fail "$mod PLAN-N1 inconclusive — neither acceptance nor refusal observed: $out"
    fi
done

echo ""
echo "7. PLAN-N2 — a consumer carrying foreign provenance is REJECTED..."
# Same correction: proving ids differ is not proving the system rejects the
# mismatch. This calls the real provenance gate and requires refusal, then runs
# a POSITIVE control so the section cannot pass by rejecting everything.
for mod in ddos portscan; do
    out="$(NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return 1; }
        eval \"\$(nftban_module_resolve_plan $mod)\"
        export NFTBAN_PLAN_TXN_ID=\"\$NFTBAN_PLAN_RESOLUTION_ID\"
        # NEGATIVE: consumer carries a foreign resolution_id, same effective_mode.
        NFTBAN_PLAN_RESOLUTION_ID=00000000
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo MIXED_ACCEPTED || echo MIXED_REJECTED
        # NEGATIVE: provenance absent entirely (distinct failure class).
        NFTBAN_PLAN_RESOLUTION_ID=
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo EMPTY_ACCEPTED || echo EMPTY_REJECTED
        # POSITIVE control: matching provenance must be ACCEPTED.
        NFTBAN_PLAN_RESOLUTION_ID=\"\$NFTBAN_PLAN_TXN_ID\"
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo MATCH_ACCEPTED || echo MATCH_REJECTED" 2>&1 || true)"
    if ! grep -q "MIXED_REJECTED" <<<"$out"; then
        fail "$mod mixed resolution_id was ACCEPTED — a consumer may run under another transaction's plan"
    elif ! grep -q "EMPTY_REJECTED" <<<"$out"; then
        fail "$mod missing provenance was ACCEPTED — MISSING PROVENANCE != PASS"
    elif ! grep -q "MATCH_ACCEPTED" <<<"$out"; then
        fail "$mod matching provenance was REJECTED — the gate refuses everything and proves nothing"
    else
        ok "$mod provenance gate: mixed REJECTED, missing REJECTED, matching ACCEPTED"
    fi
done

echo ""
echo "9. every convergence root bumps the plan binding..."
# ⛔ The binding only has teeth if EVERY root that re-renders advances it. A root
# that converges without bumping leaves a superseded plan record looking current,
# which is precisely the failure the binding exists to catch:
#   A PLAN RECORD IS USABLE ONLY IF ITS BINDING IS CURRENT.
FW="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
if [[ ! -f "$FW" ]]; then
    fail "SUBJECT_NOT_FOUND: $FW"
else
    for fn in firewall_reload _firewall_rebuild_core firewall_reset; do
        body="$(awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{"{i=1;next} i&&/^\}/{exit} i{print}' "$FW")"
        if [[ -z "$body" ]]; then
            fail "convergence root $fn NOT FOUND — cannot prove it advances the binding"
        elif grep -q "nftban_plan_generation_bump" <<<"$body"; then
            ok "$fn bumps the convergence generation"
        else
            fail "$fn converges WITHOUT bumping the generation — a superseded plan would still read as current"
        fi
    done
    # A convergence path must never rewrite durable operator intent. `enable`
    # persists MODULE_ENABLED and restarts the daemon; reload does neither.
    #   RELOAD != CONFIG MUTATION
    # Match INVOCATIONS only. `Run: nftban ddos enable` inside an operator-facing
    # message is advice, not a call, and an earlier revision failed on it.
    #   A MENTION IS NOT AN INVOCATION.
    if code_has "$FW" '(^|[;&|]|then |else |do )[[:space:]]*nftban (ddos|portscan) (enable|disable)\b'; then
        fail "$(basename "$FW") drives a module through enable/disable — a convergence path must not rewrite durable intent"
    else
        ok "$(basename "$FW") drives modules through reload only"
    fi
fi

# --- LAB OBLIGATION, declared not faked --------------------------------------
echo ""
echo "8. runtime classic XOR suricata..."
echo "  LAB   CONFIG_EXCLUSIVITY != RUNTIME_EXCLUSIVITY — this arm CANNOT be proven here."
echo "  LAB   required per module, independently: effective_mode=classic  => suricata path ABSENT"
echo "  LAB                                       effective_mode=suricata => classic  path ABSENT"
echo "  LAB   observed in live nft state, across restart / reload / rebuild / reboot."

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::mode plan / exclusivity contract FAILED: $FAILURES"
    exit 1
fi
echo "mode plan / exclusivity contract PASSED (structural + PLAN-N0/N1/N2; runtime XOR is a LAB obligation)"
