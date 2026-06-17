#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.192.1 — firewall transition health CLI/status wiring test (PR-B)
# =============================================================================
# meta:name="firewall_transition_health_cli_v1921_test"
# meta:type="test"
# meta:version="1.192.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="health check fn sets RESULTS/ISSUES on breach + stays OK when healthy; render+status+json surfaces wired for firewall_transition"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,FTH_STATE_FILE,FTH_SKIP_GATHER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# NOTE: the health checks file enables set -e on source, and the engine always
# calls checks guarded by `|| { ((errors++)); }`. We `set +e` after sourcing and
# mirror the engine (call with `&& rc=0 || rc=$?`).
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEC="$NFTBAN_LIB_DIR/core/nftban_health_checks_security.sh"
RENDER="$NFTBAN_LIB_DIR/core/nftban_health_render.sh"
ORCH="$NFTBAN_LIB_DIR/core/nftban_health.sh"
STATUS="$NFTBAN_LIB_DIR/cli/cmd_status.sh"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export FTH_STATE_FILE="$SB/fth.json"
export FTH_SKIP_GATHER=1

# Health status constants + arrays (the engine's nftban_health_init seeds these).
HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2; HEALTH_CRITICAL=3
declare -A NFTBAN_HEALTH_RESULTS=() NFTBAN_HEALTH_ISSUES=()
declare -a NFTBAN_HEALTH_ERRORS=() NFTBAN_HEALTH_WARNINGS=()
# shellcheck source=/dev/null
source "$SEC" 2>/dev/null
set +e   # the sourced file turns on set -e; the engine never runs checks under it

inject_common() {
    export FTH_EFF_TCPOUT="25,80" FTH_LIVE_TCPOUT_4="25,80" FTH_LIVE_TCPOUT_6="25,80"
    export FTH_EFF_UDPIN="53" FTH_LIVE_UDPIN_4="53" FTH_LIVE_UDPIN_6="53"
    export FTH_EFF_UDPOUT="53,123" FTH_LIVE_UDPOUT_4="53,123" FTH_LIVE_UDPOUT_6="53,123"
    export FTH_FLOOR_4=Y FTH_FLOOR_6=Y FTH_TABLE_PRESENT=Y FTH_COMMITTED=Y FTH_IN_RECOVERY=N
    export FTH_EFF_TCPIN="22,80,443,993"
}

echo "=== T1: healthy => check OK, no error, no alarm ==="
inject_common
export FTH_LIVE_TCPIN_4="22,80,443,993" FTH_LIVE_TCPIN_6="22,80,443,993"
NFTBAN_HEALTH_ERRORS=(); NFTBAN_HEALTH_WARNINGS=()
nftban_health_check_firewall_transition && rc=0 || rc=$?
[[ "$rc" -eq 0 && "${NFTBAN_HEALTH_RESULTS[firewall_transition]}" -eq 0 ]] && ok "healthy => RESULT=0" || bad "healthy not OK (rc=$rc res=${NFTBAN_HEALTH_RESULTS[firewall_transition]:-?})"
[[ "${#NFTBAN_HEALTH_ERRORS[@]}" -eq 0 ]] && ok "healthy => no health error (no cadence/false alarm)" || bad "healthy raised an error"

echo "=== T2: service-port breach => DEGRADED + issue names set/family/port ==="
export FTH_LIVE_TCPIN_4="22,80,443" FTH_LIVE_TCPIN_6="22,80,443"
NFTBAN_HEALTH_ERRORS=()
nftban_health_check_firewall_transition && rc=0 || rc=$?
[[ "$rc" -eq "$HEALTH_ERROR" && "${NFTBAN_HEALTH_RESULTS[firewall_transition]}" -eq "$HEALTH_ERROR" ]] && ok "breach => RESULT=DEGRADED(2)" || bad "breach not DEGRADED (rc=$rc)"
[[ "${#NFTBAN_HEALTH_ERRORS[@]}" -ge 1 ]] && ok "breach => health error registered" || bad "breach did not register error"
echo "${NFTBAN_HEALTH_ISSUES[firewall_transition]:-}" | grep -q 'tcp_ports_in' \
    && echo "${NFTBAN_HEALTH_ISSUES[firewall_transition]:-}" | grep -q '993' \
    && ok "issue names tcp_ports_in + 993" || bad "issue lacks set/port: ${NFTBAN_HEALTH_ISSUES[firewall_transition]:-none}"

echo "=== T3: floor breach => CRITICAL ==="
inject_common
export FTH_LIVE_TCPIN_4="22,80,443,993" FTH_LIVE_TCPIN_6="22,80,443,993" FTH_FLOOR_4=N
nftban_health_check_firewall_transition && rc=0 || rc=$?
[[ "$rc" -eq "$HEALTH_CRITICAL" ]] && ok "floor breach => CRITICAL(3)" || bad "floor not CRITICAL (rc=$rc)"

echo "=== T4: render surface wired ==="
grep -q '\[firewall_transition\]=' "$RENDER" && ok "render has firewall_transition label" || bad "render label missing"
grep -qE 'for check in .*firewall_transition' "$RENDER" && ok "render loop iterates firewall_transition" || bad "render loop missing firewall_transition"

echo "=== T5: orchestrator runs the check ==="
grep -q 'nftban_health_check_firewall_transition' "$ORCH" && ok "orchestrator registers the check" || bad "orchestrator missing the check"

echo "=== T6: status surfaces wired (text + json) ==="
grep -q 'FW Transition' "$STATUS" && ok "status has FW Transition line" || bad "status text line missing"
grep -q 'firewall_transition' "$STATUS" && ok "status --json emits firewall_transition" || bad "status json field missing"

echo ""
echo "=== firewall_transition_health CLI/status wiring: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
