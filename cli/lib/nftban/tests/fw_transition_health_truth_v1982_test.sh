#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.198.2 - FW-transition health truth: reset (A) + verdict aggregation (B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fw_transition_health_truth_v1982_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-22"
# meta:description="Hermetic tests for v1.198.2: (A) fth_reset_transition_health zeroes the cumulative counters ONLY when the live probe shows no current breach (refuses otherwise — no masking), preserves anomaly history, and touches only the state JSON (no ban/nft mutation); (B) nftban_render_operator_readiness raises the verdict (PASS->PASS_WITH_WARN, action WARN, + alarm note) when the FW-transition severity is CRITICAL/ERROR and never downgrades an existing FAIL. Live nft probe is stubbed via _fth_gather override."
# meta:input="None (synthetic fth-1 JSON + stubbed _fth_gather)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_firewall_transition_health.sh,cli/lib/nftban/core/nftban_output.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_STATE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"; export NFTBAN_LIB_DIR
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
ar(){ if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no match: $2)"; fi; }
nr(){ if grep -qE -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export NFTBAN_STATE_DIR="$WORK"
STATE="$WORK/firewall_transition_health.json"
export FTH_STATE_FILE="$STATE"

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_firewall_transition_health.sh"
# Both core modules `set -Eeuo pipefail` at source time; this test DELIBERATELY
# drives functions that return non-zero (fth_reset refusal = rc 2), so disable
# errexit here while keeping nounset + pipefail.
set +e

write_state() { # <floor> [anomaly_at] [reason]
    local floor="${1:-0}" at="${2:-2026-06-21T23:26:09Z}" reason="${3:-mgmt floor absent (ip)}"
    printf '{\n  "schema": "fth-1",\n  "service_port_breach_count": 0,\n  "floor_breach_count": %d,\n  "table_absent_while_committed_count": 0,\n  "blacklist_empty_during_refresh_count": 0,\n  "non_atomic_rebuild_count": 0,\n  "last_rebuild_atomic": true,\n  "last_trigger": "rebuild",\n  "last_duration_ms": 0,\n  "last_transition_anomaly_at": "%s",\n  "last_transition_anomaly_reason": "%s"\n}\n' "$floor" "$at" "$reason" > "$STATE"
}
floor_count() { grep -oE '"floor_breach_count": *[0-9]+' "$STATE" | grep -oE '[0-9]+$'; }

echo "== B. verdict aggregation (FW-transition CRITICAL/ERROR raises operator readiness) =="
# B1: clean validator + fth CRITICAL(3) -> NOT PASS/NONE; PASS_WITH_WARN + WARN + alarm note
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "" 0 "3")
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS_WITH_WARN$" "B1 fth CRITICAL -> readiness PASS_WITH_WARN (not clean PASS)"
ar "$OUT" "Action needed:[[:space:]]+WARN$"               "B1 fth CRITICAL -> action WARN"
ar "$OUT" "firewall-transition alarm"                     "B1 fth CRITICAL -> alarm note shown"
# B2: clean validator + fth OK(0) -> PASS / NONE, no alarm
OUT=$(nftban_render_operator_readiness '{"status":"protected","findings":[]}' "" 0 "0")
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS$"           "B2 fth OK -> readiness PASS"
ar "$OUT" "Action needed:[[:space:]]+NONE$"               "B2 fth OK -> action NONE"
nr "$OUT" "firewall-transition alarm"                     "B2 fth OK -> no alarm note"
# B3: fth ERROR(2) also raises
OUT=$(nftban_render_operator_readiness '{"status":"idle","findings":[]}' "" 0 "2")
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS_WITH_WARN$" "B3 fth ERROR -> PASS_WITH_WARN"
# B4: existing FAIL (down) NOT downgraded by fth alarm
OUT=$(nftban_render_operator_readiness '{"status":"down","findings":[]}' "" 2 "3")
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL$"           "B4 fth CRITICAL never downgrades an existing FAIL"

echo "== A. reset positive (clean live floor -> counters cleared, history kept) =="
write_state 1
# stub the live probe to report a CLEAN current state
# shellcheck disable=SC2034  # FTH_* are read by the sourced _fth_compute_breaches
_fth_gather() { FTH_FLOOR_4=Y; FTH_FLOOR_6=Y; FTH_TABLE_PRESENT=Y; FTH_COMMITTED=N; FTH_EFF_TCPIN=""; FTH_EFF_TCPOUT=""; FTH_EFF_UDPIN=""; FTH_EFF_UDPOUT=""; }
fth_reset_transition_health "test: floor restored"; RC=$?
[[ "$RC" -eq 0 ]] && ok "A+ reset returns 0 on clean live state" || bad "A+ reset rc=$RC (want 0)"
[[ "$(floor_count)" == "0" ]] && ok "A+ floor_breach_count cleared to 0" || bad "A+ floor_breach_count=$(floor_count) (want 0)"
grep -q '"last_transition_anomaly_at": "2026-06-21T23:26:09Z"' "$STATE" && ok "A+ prior anomaly timestamp retained as audit history" || bad "A+ anomaly history lost"
grep -q 'reset .*test: floor restored' "$STATE" && ok "A+ reset reason recorded" || bad "A+ reset reason missing"
RES=$(fth_eval_health); [[ "${RES%%|*}" == "0" ]] && ok "A+ fth_eval_health now OK (no CRITICAL)" || bad "A+ fth_eval_health=${RES} (want 0)"

echo "== A. reset negative (current live breach -> refuse, no masking) =="
write_state 1
# stub the live probe to report a CURRENT floor breach
# shellcheck disable=SC2034  # FTH_* are read by the sourced _fth_compute_breaches
_fth_gather() { FTH_FLOOR_4=N; FTH_FLOOR_6=Y; FTH_TABLE_PRESENT=Y; FTH_COMMITTED=N; FTH_EFF_TCPIN=""; FTH_EFF_TCPOUT=""; FTH_EFF_UDPIN=""; FTH_EFF_UDPOUT=""; }
fth_reset_transition_health "test: should refuse"; RC=$?
[[ "$RC" -eq 2 ]] && ok "A- reset REFUSES (rc 2) while a current breach exists" || bad "A- reset rc=$RC (want 2)"
[[ "$(floor_count)" == "1" ]] && ok "A- counters UNCHANGED on refusal (no masking)" || bad "A- floor_breach_count=$(floor_count) (want 1, unchanged)"

echo "== A. no ban loss / no nft mutation (structural) =="
# fth_reset_transition_health must touch ONLY the state JSON — never nft/ban sets.
BODY=$(declare -f fth_reset_transition_health)
if grep -qE 'nft (add|delete|flush)|nft -f|Service|blacklist' <<<"$BODY"; then
    bad "A no-ban-loss: reset function contains nft/ban mutation"
else
    ok "A no-ban-loss: reset touches only state JSON (no nft/ban mutation in function body)"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
