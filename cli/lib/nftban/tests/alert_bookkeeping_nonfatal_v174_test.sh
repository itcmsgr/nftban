#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.174 ALERT-THROTTLE-NONFATAL (alert bookkeeping best-effort)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="alert_bookkeeping_nonfatal_v174_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.174 ALERT-THROTTLE-NONFATAL fix in cli/sbin/nftban-service-alert: a state-write (throttle / diagnostics / failure-metric) permission failure must NOT fail/latch nftban-alert@*.service, but a real alert DELIVERY failure must still follow the rc contract. Root cause (monitor 2026-06-09): the alert unit runs User=nftban while the throttle/diag paths sit under root-owned 0750 /var/lib/nftban → EACCES → script exit 1 → systemd failed-state latch → installer DEGRADED. (1) data-dir read-only + no mail recipient => exit 0 (bookkeeping non-fatal); (2) WARN logged, raw error not fatal; (3) delivery failure (recipient set + mail module absent) => non-zero (contract preserved); (4) happy path writable => exit 0 + throttle persisted. Hermetic: temp dirs, no root, no systemd mutation."
# meta:input="None (temp NFTBAN_LOG_DIR/NFTBAN_DATA_DIR)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash"
# meta:inventory.files="cli/sbin/nftban-service-alert"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-alert@.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="alert_bookkeeping_nonfatal_v174_test"
# meta:ta.owner="health"
# meta:ta.module="alert"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
ALERT="$REPO_ROOT/cli/sbin/nftban-service-alert"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
[[ -f "$ALERT" ]] || { echo "alert script not found: $ALERT"; exit 1; }

WORK="$(mktemp -d)"
# Cleanup: the read-only (0500) test dir is intentionally empty (all writes to it
# fail by design), so rm -rf removes it via the writable parent. Restore that one
# dir's mode first (scoped, per-dir; no recursive permission change is used here).
cleanup(){ [[ -d "$WORK/ro_data" ]] && chmod u+rwx "$WORK/ro_data" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# run_alert <datadir> <recipient> <libdir> -> sets RC + LOG
run_alert() {
  local datadir="$1" recipient="$2" libdir="$3"
  local logdir="$WORK/log.$RANDOM"; mkdir -p "$logdir"
  set +e
  NFTBAN_LOG_DIR="$logdir" \
  NFTBAN_DATA_DIR="$datadir" \
  NFTBAN_CONFIG_DIR="$WORK/noconfig" \
  NFTBAN_LIB_DIR="$libdir" \
  NFTBAN_MAIL_RECIPIENT="$recipient" \
    bash "$ALERT" nftband.service >/dev/null 2>&1
  RC=$?
  set -e
  LOG="$logdir/service-alerts.log"
}

echo "== Test A: read-only data dir + no recipient => alert unit exits 0 (bookkeeping non-fatal) =="
ro="$WORK/ro_data"; mkdir -p "$ro"; chmod 0500 "$ro"   # owner r-x, no write -> EACCES on writes
run_alert "$ro" "" "$WORK/nolib"
[[ "$RC" -eq 0 ]] && ok "A exit 0 despite throttle/diag write EACCES (RC=$RC)" || no "A exit 0" "got RC=$RC"

echo "== Test B: WARN logged (not fatal) + throttle file NOT created under EACCES =="
if [[ -f "$LOG" ]] && grep -q "throttle state write failed" "$LOG"; then ok "B throttle WARN logged"; else no "B throttle WARN" "missing in $LOG"; fi
# v1.175 ALERT-THROTTLE-FHS: throttle relocated to <data>/alerts/throttle_<svc>.
[[ ! -e "$ro/alerts/throttle_nftband_service" ]] && ok "B throttle file not created (write was non-fatal)" || no "B throttle file" "unexpectedly created"

echo "== Test C: delivery contract — recipient set + mail module absent => non-zero =="
rw="$WORK/rw_data"; mkdir -p "$rw"
run_alert "$rw" "ops@example.test" "$WORK/nolib"   # nolib has no core/nftban_mail.sh -> send_email_alert returns 1
[[ "$RC" -ne 0 ]] && ok "C delivery failure still fails the unit (RC=$RC)" || no "C delivery contract" "expected non-zero, got 0"

echo "== Test D: happy path — writable data dir + no recipient => exit 0 + throttle persisted =="
rw2="$WORK/rw_data2"; mkdir -p "$rw2"
run_alert "$rw2" "" "$WORK/nolib"
[[ "$RC" -eq 0 ]] && ok "D exit 0 (RC=$RC)" || no "D exit 0" "got RC=$RC"
# v1.175 ALERT-THROTTLE-FHS: throttle persists under <data>/alerts/ (nftban-owned).
[[ -f "$rw2/alerts/throttle_nftband_service" ]] && ok "D throttle file persisted when writable (under alerts/)" || no "D throttle persisted" "file missing at alerts/throttle_nftband_service"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
