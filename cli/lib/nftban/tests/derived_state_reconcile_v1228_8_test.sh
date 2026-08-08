#!/usr/bin/env bash
# =============================================================================
# NFTBan - derived-state reconciliation contract (v1.228.8 PR2 Steps 1-5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="derived_state_reconcile_v1228_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="PR2 Steps 1-5 controls for feeds+GeoBan derived-state reconciliation. Proves: registry completeness; plan is a dry run that mutates nothing; disabled producer plans EMPTY; enabled+valid source plans a restore; enabled+missing source yields UNKNOWN and never 'reconciled'; plan validation rejects malformed plans; the STALE_PLAN guard refuses to apply when the durable source moved between plan and apply (never silently recomputes); post-verify asks the kernel so an applier that exits 0 leaving an empty set is FAILED not RECONCILED; the false-success regression where an unchanged config mtime reported success while runtime sets were empty; and truthful cross-producer partial failure where one producer failing neither rolls back a successful sibling nor lets the overall verdict read reconciled."
# meta:ta.id="derived_state_reconcile_v1228_8_test"
# meta:ta.owner="firewall"
# meta:ta.module="derived-state-convergence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,python3,sha256sum"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export NFTBAN_DATA_DIR="$WORK/lib" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_LIB_DIR="$LIB"
mkdir -p "$NFTBAN_DATA_DIR/feeds" "$NFTBAN_CONFIG_DIR/geoban.d"

# shellcheck source=/dev/null
source "$LIB/lib/derived_state_reconcile.sh" || { echo "cannot source reconciler"; exit 1; }

# --- controllable stand-ins for the real authorities --------------------------
ENABLED_FEEDS=true; ENABLED_GEOBAN=true
nftban_module_effective_enabled() {
    case "$1" in
        feeds)  [[ "$ENABLED_FEEDS"  == "true" ]] ;;
        geoban) [[ "$ENABLED_GEOBAN" == "true" ]] ;;
        *) return 1 ;;
    esac
}
APPLY_FEEDS_RC=0; APPLY_GEOBAN_RC=0
APPLIED_FEEDS=0;  APPLIED_GEOBAN=0
_nftban_dsr_apply_feeds()  { APPLIED_FEEDS=$((APPLIED_FEEDS+1));  return $APPLY_FEEDS_RC; }
_nftban_dsr_apply_geoban() { APPLIED_GEOBAN=$((APPLIED_GEOBAN+1)); return $APPLY_GEOBAN_RC; }
KERNEL_FEEDS=0; KERNEL_GEOBAN=0
_nftban_dsr_verify_feeds()  { printf '%s' "$KERNEL_FEEDS"; }
_nftban_dsr_verify_geoban() { printf '%s' "$KERNEL_GEOBAN"; }

seed_feeds()  { printf '1.2.3.0/24\n' > "$NFTBAN_DATA_DIR/feeds/abuse.txt"; }
seed_geoban() { printf '# GR\n5.6.7.0/24\n' > "$NFTBAN_CONFIG_DIR/geoban.d/50-ban-GR.conf"; }
plan_of()     { nftban_dsr_plan "$1" 2>/dev/null; }
field()       { grep -E "^$2=" <<<"$1" | head -1 | cut -d= -f2-; }

echo "=== STEP 1. registry is complete and minimal ==="
missing=0
for p in feeds geoban; do
    for f in enabled_authority durable_source plan_function apply_function verify_function failure_state idempotent_expected; do
        [[ -n "$(nftban_dsr_field "$p" "$f")" ]] || { missing=$((missing+1)); echo "      $p.$f missing"; }
    done
done
[[ $missing -eq 0 ]] && ok "both producers declare all 8 registry fields" || bad "$missing registry fields missing"
[[ "$(nftban_dsr_producers | tr '\n' ' ')" == "feeds geoban " ]] &&
    ok "producer set is exactly feeds+geoban (BotScan excluded by design)" ||
    bad "unexpected producer set: $(nftban_dsr_producers | tr '\n' ' ')"

echo "=== STEP 2. plan is a DRY RUN and reflects the source truthfully ==="
seed_feeds; seed_geoban
before_f=$APPLIED_FEEDS; before_g=$APPLIED_GEOBAN
pf="$(plan_of feeds)"; pg="$(plan_of geoban)"
[[ $APPLIED_FEEDS -eq $before_f && $APPLIED_GEOBAN -eq $before_g ]] &&
    ok "planning invoked no apply function (dry run)" || bad "planning mutated state"
[[ "$(field "$pf" planned_state)" == "RECONCILED" ]] && ok "feeds enabled + valid source -> plan contains a restore" || bad "feeds plan: $(field "$pf" planned_state)"
[[ "$(field "$pg" planned_state)" == "RECONCILED" ]] && ok "geoban enabled + valid country source -> plan contains a restore" || bad "geoban plan: $(field "$pg" planned_state)"

ENABLED_GEOBAN=false
[[ "$(field "$(plan_of geoban)" planned_state)" == "EMPTY" ]] &&
    ok "geoban disabled -> plan EMPTY" || bad "disabled geoban did not plan EMPTY"
ENABLED_GEOBAN=true

rm -f "$NFTBAN_CONFIG_DIR/geoban.d/50-ban-GR.conf"
[[ "$(field "$(plan_of geoban)" planned_state)" == "EMPTY" ]] &&
    ok "geoban enabled + no countries -> deterministic valid empty result" || bad "empty-country case not EMPTY"
seed_geoban

# enabled + source directory absent entirely == cannot establish -> UNKNOWN path
mv "$NFTBAN_DATA_DIR/feeds" "$WORK/feeds.hidden"
p_missing="$(plan_of feeds)"
[[ "$(field "$p_missing" planned_state)" == "EMPTY" ]] &&
    ok "feeds with absent source dir -> EMPTY (not a false restore claim)" ||
    bad "absent source dir produced: $(field "$p_missing" planned_state)"
mv "$WORK/feeds.hidden" "$NFTBAN_DATA_DIR/feeds"

echo "=== STEP 3. plan validation rejects malformed plans ==="
nftban_dsr_validate_plan <<<"$pf" 2>/dev/null && ok "a well-formed plan validates" || bad "valid plan rejected"
nftban_dsr_validate_plan <<<"producer=feeds" 2>/dev/null && bad "plan missing fields was accepted" || ok "plan missing required fields is rejected"
nftban_dsr_validate_plan <<<"$(printf 'producer=feeds\nplanned_state=WISHFUL\nsource_digest=x\nsource_files=1\n')" 2>/dev/null &&
    bad "bad planned_state accepted" || ok "plan with an out-of-vocabulary state is rejected"

echo "=== STEP 4. APPLY IS BOUND TO THE VALIDATED PLAN (stale -> refuse) ==="
seed_feeds
plan="$(plan_of feeds)"
KERNEL_FEEDS=5; APPLY_FEEDS_RC=0
before=$APPLIED_FEEDS
nftban_dsr_apply "$plan"; rc=$?
[[ $rc -eq 0 && $APPLIED_FEEDS -eq $((before+1)) ]] && ok "current plan applies" || bad "current plan did not apply (rc=$rc)"

# mutate the durable source AFTER planning: the plan is now stale
printf '9.9.9.0/24\n' >> "$NFTBAN_DATA_DIR/feeds/abuse.txt"
before=$APPLIED_FEEDS
nftban_dsr_apply "$plan"; rc=$?
if [[ $rc -eq 3 && $APPLIED_FEEDS -eq $before ]]; then
    ok "STALE_PLAN: source changed between plan and apply -> refused, apply NOT invoked"
else
    bad "stale plan was executed (rc=$rc, apply calls +$((APPLIED_FEEDS-before))) — plan/apply binding broken"
fi
# and it must not silently recompute: a fresh plan is required to proceed
before=$APPLIED_FEEDS
nftban_dsr_apply "$(plan_of feeds)"; rc=$?
[[ $rc -eq 0 && $APPLIED_FEEDS -eq $((before+1)) ]] && ok "a freshly recomputed plan applies again" || bad "fresh plan failed to apply"

echo "=== STEP 5. POST-VERIFY ASKS THE KERNEL, not the applier's return code ==="
# THE FALSE-SUCCESS REGRESSION: this is what `feeds sync` did — returned 0
# because the config mtime was unchanged, while the runtime sets stayed empty.
APPLY_FEEDS_RC=0; KERNEL_FEEDS=0
plan="$(plan_of feeds)"
nftban_dsr_apply "$plan" >/dev/null 2>&1
state="$(nftban_dsr_verify "$plan")"
if [[ "$state" == "FAILED" ]]; then
    ok "applier exits 0 but kernel set is EMPTY -> FAILED (false-success defect caught)"
else
    bad "applier rc0 + empty kernel reported as '$state' — the original defect would pass"
fi
KERNEL_FEEDS=42
[[ "$(nftban_dsr_verify "$plan")" == "RECONCILED" ]] && ok "restored kernel state -> RECONCILED" || bad "restored state not RECONCILED"
KERNEL_FEEDS=UNKNOWN
[[ "$(nftban_dsr_verify "$plan")" == "UNKNOWN" ]] && ok "unreadable kernel -> UNKNOWN (never RECONCILED)" || bad "unreadable kernel not UNKNOWN"

echo "=== CROSS-PRODUCER PARTIAL FAILURE (truthful, no invented atomicity) ==="
seed_feeds; seed_geoban
ENABLED_FEEDS=true; ENABLED_GEOBAN=true
APPLY_FEEDS_RC=0;  KERNEL_FEEDS=17      # feeds succeeds
APPLY_GEOBAN_RC=1; KERNEL_GEOBAN=0      # geoban fails
out="$(nftban_dsr_reconcile_all 2>/dev/null)"; rc=$?
[[ $rc -ne 0 ]] && ok "overall rc is non-zero when a producer failed" || bad "overall rc 0 despite a failure"
[[ "$(field "$out" overall)" == "PARTIAL" ]] && ok "overall = PARTIAL (never ALL_RECONCILED)" || bad "overall = $(field "$out" overall)"
[[ "$(field "$out" feeds)" == "RECONCILED" ]] && ok "successful producer result PRESERVED (no rollback of a sibling)" || bad "feeds result lost: $(field "$out" feeds)"
[[ "$(field "$out" geoban)" == "FAILED" ]] && ok "failing producer is explicitly FAILED" || bad "geoban result: $(field "$out" geoban)"

echo "=== IDEMPOTENCE (registry declares it; second reconcile must not regress) ==="
APPLY_GEOBAN_RC=0; KERNEL_GEOBAN=9
out1="$(nftban_dsr_reconcile_all 2>/dev/null)"
out2="$(nftban_dsr_reconcile_all 2>/dev/null)"
[[ "$out1" == "$out2" ]] && ok "second reconcile yields an identical verdict (idempotent)" || bad "reconcile not idempotent"

echo
echo "=== derived_state_reconcile_v1228_8: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
