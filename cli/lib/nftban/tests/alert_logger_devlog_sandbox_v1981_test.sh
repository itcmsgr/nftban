#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.198.1 PR-A: alert handler survives /dev/log denied under sandbox
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="alert_logger_devlog_sandbox_v1981_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-22"
# meta:description="D-NFTBAN-ALERT-LOGGER-DEVLOG-PERMISSION: under the nftban-alert@ sandbox (PrivateDevices=yes + User=nftban) `logger` hits /dev/log EACCES. PR-A makes log_alert deliver to the journal (stderr, the unit's StandardError=journal) + the file log and treat `logger` as best-effort, so the OnFailure oneshot exits 0 instead of latching failed (which tripped the post-install failed-unit assertion → install_state DEGRADED). Hermetic: a failing `logger` stub on PATH simulates the EACCES; no host, no real systemd."
# meta:input="None (failing logger stub + temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/sbin/nftban-service-alert"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_MAIL_RECIPIENT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-alert@.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
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

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A `logger` stub that fails exactly like the sandbox does: EACCES on /dev/log.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/logger" <<'STUB'
#!/usr/bin/env bash
# Drop a sentinel proving we ran, then fail like the sandbox /dev/log EACCES.
# (PR-A pipes our stderr to /dev/null, so a sentinel — not stderr — proves it fired.)
d="$(dirname "$0")"; : > "$d/fired" 2>/dev/null || true
echo "logger: socket /dev/log: Permission denied" >&2
exit 1
STUB
chmod +x "$FAKEBIN/logger"

# run_alert_failing_logger -> sets RC, LOG, ERROUT (stderr captured)
run_alert_failing_logger() {
  local logdir="$WORK/log.$RANDOM"; mkdir -p "$logdir"
  local datadir="$WORK/data.$RANDOM"; mkdir -p "$datadir"
  ERRFILE="$logdir/stderr.txt"
  set +e
  PATH="$FAKEBIN:$PATH" \
  NFTBAN_LOG_DIR="$logdir" \
  NFTBAN_DATA_DIR="$datadir" \
  NFTBAN_CONFIG_DIR="$WORK/noconfig" \
  NFTBAN_LIB_DIR="$WORK/nolib" \
  NFTBAN_MAIL_RECIPIENT="" \
    bash "$ALERT" nftband.service >/dev/null 2>"$ERRFILE"
  RC=$?
  set -e
  LOG="$logdir/service-alerts.log"
  ERROUT="$(cat "$ERRFILE" 2>/dev/null || true)"
}

echo "== Test A: logger fails (/dev/log EACCES) => alert oneshot STILL exits 0 (PR-A) =="
run_alert_failing_logger
[[ "$RC" -eq 0 ]] && ok "A exit 0 despite logger /dev/log EACCES (RC=$RC)" \
  || no "A exit 0 under failing logger" "got RC=$RC — log_alert's unguarded logger latched the unit failed (pre-PR-A regression)"

echo "== Test B: the failing logger DID run (sentinel proves the EACCES path was exercised; PR-A pipes its stderr to /dev/null) =="
if [[ -f "$FAKEBIN/fired" ]]; then ok "B logger stub fired (EACCES path exercised; its stderr correctly suppressed by PR-A)"; else no "B logger stub fired" "sentinel not created — logger was not invoked"; fi

echo "== Test C: alert still DELIVERED to the file log (durable sink) =="
if [[ -f "$LOG" ]] && grep -q "Service failure detected: nftband.service" "$LOG"; then ok "C alert persisted to file log"; else no "C file-log delivery" "ALERT line missing in $LOG"; fi

echo "== Test D: alert ALSO delivered to the journal path (stderr; unit StandardError=journal) =="
# PR-A prints '[ts] [LEVEL] msg' to stderr so it reaches the journal WITHOUT /dev/log.
if grep -q "\[ALERT\] Service failure detected: nftband.service" <<<"$ERROUT"; then ok "D alert on stderr (journal-native) without /dev/log"; else no "D journal-native delivery" "ALERT line missing on stderr"; fi

echo "== Test E: source guard — log_alert is journal-safe (best-effort logger + return 0) =="
if grep -Eq 'logger -t nftban-alert .* 2>/dev/null \|\| true' "$ALERT"; then ok "E logger call is best-effort (2>/dev/null || true)"; else no "E best-effort logger" "unguarded logger remains in $ALERT"; fi
if awk '/^log_alert\(\)/{f=1} f&&/^}/{print last; exit} f{last=$0}' "$ALERT" | grep -q 'return 0'; then ok "E log_alert returns 0 (never propagates logger failure)"; else no "E log_alert return 0" "log_alert does not end with 'return 0'"; fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
