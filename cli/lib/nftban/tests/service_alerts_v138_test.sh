#!/usr/bin/env bash
# =============================================================================
# NFTBan - SEC-BYPASS-ALERT service-alerts.log emitter test (v1.138 PR-B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="service_alerts_v138_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.138 PR-B SEC-BYPASS-ALERT emitter test. Asserts nftban_emit_firewall_conflict_alerts: emits one [FW-CONFLICT] line per primary detector entry to service-alerts.log when severity is WARNING/CRITICAL; emits nothing for NONE/INFO; per-service throttling suppresses duplicates within the window; ignores indented sub-entries; respects NFTBAN_ALERT_THROTTLE_SECONDS override. Runs hermetically (scratch dirs, no root, no nft, no host mutation)."
# meta:input="None (uses scratch dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,wc,date"
# meta:inventory.files="cli/lib/nftban/core/nftban_firewall_conflicts.sh"
# meta:inventory.binaries="bash,grep,wc,date,mkdir,rm,cat"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_ALERT_THROTTLE_SECONDS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SRC="$REPO/cli/lib/nftban/core/nftban_firewall_conflicts.sh"

[[ -f "$SRC" ]] || { echo "FAIL: cannot find $SRC" >&2; exit 1; }

# Hermetic scratch
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export NFTBAN_LOG_DIR="$SCRATCH/log"
export NFTBAN_DATA_DIR="$SCRATCH/data"
mkdir -p "$NFTBAN_LOG_DIR" "$NFTBAN_DATA_DIR"
ALERT_LOG="$NFTBAN_LOG_DIR/service-alerts.log"

# Source the library. Detectors are not invoked; we drive globals directly.
# shellcheck source=/dev/null
source "$SRC"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

reset_scratch() {
    rm -f "$ALERT_LOG"
    rm -f "$NFTBAN_DATA_DIR"/alert_throttle_firewall_*
    # shellcheck disable=SC2034  # consumed by sourced library via the for-loop iterator
    NFTBAN_FIREWALL_CONFLICTS=()
    # shellcheck disable=SC2034  # populated by detectors; cleared here for hermetic test
    NFTBAN_FIREWALL_FIXES=()
    # shellcheck disable=SC2034  # consumed by sourced library guard at function entry
    NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE
}

count_fw_lines() {
    [[ -f "$ALERT_LOG" ]] || { echo 0; return; }
    grep -c '\[FW-CONFLICT\]' "$ALERT_LOG" 2>/dev/null || echo 0
}

echo "=========================================================="
echo "V1.138 PR-B SEC-BYPASS-ALERT emitter test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# T1: NONE severity → no file written, no lines
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE
nftban_emit_firewall_conflict_alerts
if [[ ! -f "$ALERT_LOG" ]] && [[ "$(count_fw_lines)" -eq 0 ]]; then
    ok "T1 severity=NONE emits nothing"
else
    no "T1 severity=NONE emits nothing" "alert_log exists or lines>0"
fi

# -----------------------------------------------------------------------------
# T2: INFO severity (cPHulk coexists) → no emission
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_INFO
NFTBAN_FIREWALL_CONFLICTS=("CPHULK: Active (cPanel brute-force protection)")
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 0 ]]; then
    ok "T2 severity=INFO emits nothing"
else
    no "T2 severity=INFO emits nothing" "got $(count_fw_lines) line(s)"
fi

# -----------------------------------------------------------------------------
# T3: WARNING severity, one primary entry → exactly one [FW-CONFLICT] line
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
NFTBAN_FIREWALL_CONFLICTS=("FAIL2BAN: Active with 3 jail(s), backend=nftables")
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 1 ]]; then
    ok "T3 WARNING + 1 primary entry → 1 line"
else
    no "T3 WARNING + 1 primary entry → 1 line" "got $(count_fw_lines)"
fi

# T3a: line shape is deterministic and grep-testable
if grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[WARNING\] \[FW-CONFLICT\] service=fail2ban detail=Active with 3 jail\(s\), backend=nftables$' "$ALERT_LOG"; then
    ok "T3a line shape matches contract"
else
    no "T3a line shape matches contract" "line: $(tail -1 "$ALERT_LOG" 2>/dev/null)"
fi

# -----------------------------------------------------------------------------
# T4: CRITICAL severity, multiple primary entries → one line per primary
#     Indented sub-entries are ignored (do not contribute lines or throttle keys)
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
NFTBAN_FIREWALL_CONFLICTS=(
    "FIREWALLD: ACTIVE - Critical conflict with nftban"
    "  └─ FIX: systemctl stop firewalld && systemctl disable firewalld"
    "UFW: ACTIVE - Critical conflict with nftban"
    "CSF: ACTIVE (production mode)"
    "  └─ CSF uses iptables which conflicts with nftban"
)
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 3 ]]; then
    ok "T4 CRITICAL + 3 primary + 2 indented → 3 lines"
else
    no "T4 CRITICAL + 3 primary + 2 indented → 3 lines" "got $(count_fw_lines)"
fi
# T4a: each primary service appears exactly once
for svc in firewalld ufw csf; do
    n=$(grep -c "service=$svc " "$ALERT_LOG" 2>/dev/null || echo 0)
    if [[ "$n" -eq 1 ]]; then
        ok "T4a service=$svc emitted once"
    else
        no "T4a service=$svc emitted once" "count=$n"
    fi
done
# T4b: severity label is CRITICAL on all three lines
if [[ "$(grep -c '\[CRITICAL\] \[FW-CONFLICT\]' "$ALERT_LOG" 2>/dev/null || echo 0)" -eq 3 ]]; then
    ok "T4b all three lines tagged CRITICAL"
else
    no "T4b all three lines tagged CRITICAL" "got $(grep -c '\[CRITICAL\] \[FW-CONFLICT\]' "$ALERT_LOG" 2>/dev/null || echo 0)"
fi
# T4c: no sub-entry leaked (no "service=└─" or empty service)
if ! grep -qE 'service=(└|$| )' "$ALERT_LOG" 2>/dev/null; then
    ok "T4c indented sub-entries are not emitted"
else
    no "T4c indented sub-entries are not emitted" "leak detected"
fi

# -----------------------------------------------------------------------------
# T5: re-run within throttle window → no duplicate lines
# -----------------------------------------------------------------------------
# Same arrays as T4; throttle files are in place from T4.
before=$(count_fw_lines)
nftban_emit_firewall_conflict_alerts
after=$(count_fw_lines)
if [[ "$before" -eq "$after" ]]; then
    ok "T5 re-run within window → no duplicate (lines stayed at $after)"
else
    no "T5 re-run within window → no duplicate" "lines $before -> $after"
fi

# -----------------------------------------------------------------------------
# T6: expire throttle (backdate timestamps) → re-emission allowed
# -----------------------------------------------------------------------------
# Backdate each *timestamp* throttle file by 7200s (2h, > default 3600s).
# Skip the sibling .sev (severity) and .lock files added for R1/R3 — those
# are not timestamp stores.
old_ts=$(( $(date +%s) - 7200 ))
for f in "$NFTBAN_DATA_DIR"/alert_throttle_firewall_*; do
    [[ -f "$f" ]] || continue
    case "$f" in
        *.sev|*.lock) continue ;;
    esac
    echo "$old_ts" > "$f"
done
before=$(count_fw_lines)
nftban_emit_firewall_conflict_alerts
after=$(count_fw_lines)
if [[ "$after" -eq $((before + 3)) ]]; then
    ok "T6 after throttle expiry → 3 new lines (was $before, now $after)"
else
    no "T6 after throttle expiry → 3 new lines" "delta=$((after - before))"
fi

# -----------------------------------------------------------------------------
# T7: NFTBAN_ALERT_THROTTLE_SECONDS=0 → every call re-emits
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
NFTBAN_FIREWALL_CONFLICTS=("IPTABLES: iptables.service is ACTIVE")
NFTBAN_ALERT_THROTTLE_SECONDS=0 nftban_emit_firewall_conflict_alerts
NFTBAN_ALERT_THROTTLE_SECONDS=0 nftban_emit_firewall_conflict_alerts
NFTBAN_ALERT_THROTTLE_SECONDS=0 nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 3 ]]; then
    ok "T7 THROTTLE_SECONDS=0 → every call emits (got 3)"
else
    no "T7 THROTTLE_SECONDS=0 → every call emits" "got $(count_fw_lines)"
fi

# -----------------------------------------------------------------------------
# T8: empty conflicts array even at WARNING → no emission
# -----------------------------------------------------------------------------
reset_scratch
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
NFTBAN_FIREWALL_CONFLICTS=()
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 0 ]]; then
    ok "T8 WARNING but empty array → no emission"
else
    no "T8 WARNING but empty array → no emission" "got $(count_fw_lines)"
fi

# -----------------------------------------------------------------------------
# T9: hyphenated tag (IPTABLES-NFT) is preserved through lowercase mapping
# -----------------------------------------------------------------------------
reset_scratch
# shellcheck disable=SC2034  # consumed by sourced library
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034  # consumed by sourced library
NFTBAN_FIREWALL_CONFLICTS=("IPTABLES-NFT: 12 rules (priority check determines safety)")
nftban_emit_firewall_conflict_alerts
if grep -q 'service=iptables-nft ' "$ALERT_LOG" 2>/dev/null; then
    ok "T9 hyphenated tag → lowercase service token preserved"
else
    no "T9 hyphenated tag → lowercase service token preserved" "no match"
fi
# T9a: throttle key must be sanitized (hyphen → underscore) and file must exist
if [[ -f "$NFTBAN_DATA_DIR/alert_throttle_firewall_iptables_nft" ]]; then
    ok "T9a throttle key sanitized (hyphen→underscore)"
else
    no "T9a throttle key sanitized (hyphen→underscore)" "throttle file missing"
fi

# =============================================================================
# Audit residuals R1–R6 (third-audit closure — operator
# OPEN_V1_138_PR_B_ALERT_RESIDUALS_CLOSE_NOW = GO)
# =============================================================================

# -----------------------------------------------------------------------------
# T10 (R1): per-service flock prevents duplicate concurrent emit.
# Five emitters fired in parallel against the SAME single-service array →
# exactly ONE alert line lands (one wins the lock + stamps throttle; the
# others either lock-skip or hit fresh throttle). Skipped on hosts without
# `flock`, where lock-free best-effort is the documented fallback.
# -----------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
    reset_scratch
    # shellcheck disable=SC2034
    NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
    # shellcheck disable=SC2034
    NFTBAN_FIREWALL_CONFLICTS=("FAIL2BAN: parallel race test")
    pids=()
    for _ in 1 2 3 4 5; do
        ( nftban_emit_firewall_conflict_alerts ) &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done
    n=$(count_fw_lines)
    if [[ "$n" -eq 1 ]]; then
        ok "T10 (R1) parallel x5 emit on one service → exactly 1 line"
    else
        no "T10 (R1) parallel x5 emit on one service → exactly 1 line" "got $n"
    fi
else
    ok "T10 (R1) SKIP — flock not installed; lock-free best-effort is documented"
fi

# -----------------------------------------------------------------------------
# T11 (R2): corrupt (non-numeric) throttle file → treated as stale → emit.
# -----------------------------------------------------------------------------
reset_scratch
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034
NFTBAN_FIREWALL_CONFLICTS=("UFW: corrupt-timestamp test")
echo "garbage-not-a-number" > "$NFTBAN_DATA_DIR/alert_throttle_firewall_ufw"
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 1 ]]; then
    ok "T11 (R2) corrupt throttle file → treated as stale, 1 line emitted"
else
    no "T11 (R2) corrupt throttle file → treated as stale, 1 line emitted" "got $(count_fw_lines)"
fi
# T11a: the corrupt file should have been overwritten with a valid timestamp.
if [[ -s "$NFTBAN_DATA_DIR/alert_throttle_firewall_ufw" ]] \
   && grep -qE '^[0-9]+$' "$NFTBAN_DATA_DIR/alert_throttle_firewall_ufw"; then
    ok "T11a corrupt throttle file replaced with valid numeric timestamp"
else
    no "T11a corrupt throttle file replaced with valid numeric timestamp" "still corrupt"
fi

# -----------------------------------------------------------------------------
# T12 (R3): severity escalation WARNING→CRITICAL inside throttle window
# must re-emit exactly once (not silently suppressed). The reverse path
# (CRITICAL stays CRITICAL) must stay throttled.
# -----------------------------------------------------------------------------
reset_scratch
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034
NFTBAN_FIREWALL_CONFLICTS=("FIREWALLD: escalation-test")
nftban_emit_firewall_conflict_alerts            # 1st: WARNING → 1 line
# Now escalate within the throttle window (no time advance).
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_CRITICAL
nftban_emit_firewall_conflict_alerts            # 2nd: CRITICAL → +1 line (escalation)
nftban_emit_firewall_conflict_alerts            # 3rd: CRITICAL → 0 (no further escalation)
n=$(count_fw_lines)
if [[ "$n" -eq 2 ]]; then
    ok "T12 (R3) WARNING→CRITICAL in window → escalation re-emits once (2 lines total)"
else
    no "T12 (R3) WARNING→CRITICAL in window → escalation re-emits once" "got $n"
fi
# T12a: severity ordering on the two lines must be WARNING then CRITICAL.
if [[ "$(grep -c '\[WARNING\] \[FW-CONFLICT\] service=firewalld' "$ALERT_LOG" 2>/dev/null || echo 0)" -eq 1 ]] \
   && [[ "$(grep -c '\[CRITICAL\] \[FW-CONFLICT\] service=firewalld' "$ALERT_LOG" 2>/dev/null || echo 0)" -eq 1 ]]; then
    ok "T12a (R3) emitted lines tagged WARNING + CRITICAL exactly once each"
else
    no "T12a (R3) emitted lines tagged WARNING + CRITICAL exactly once each" "tag mismatch"
fi
# T12b: .sev file now records CRITICAL (3).
sev=$(cat "$NFTBAN_DATA_DIR/alert_throttle_firewall_firewalld.sev" 2>/dev/null || echo 0)
if [[ "$sev" -eq 3 ]]; then
    ok "T12b (R3) .sev metadata stamped with last severity (CRITICAL=3)"
else
    no "T12b (R3) .sev metadata stamped with last severity (CRITICAL=3)" "sev=$sev"
fi

# -----------------------------------------------------------------------------
# T13 (R4): future-dated throttle (clock skew) → clamped to stale → emit.
# -----------------------------------------------------------------------------
reset_scratch
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034
NFTBAN_FIREWALL_CONFLICTS=("CSF: future-clamp test")
future_ts=$(( $(date +%s) + 86400 ))  # +1 day
echo "$future_ts" > "$NFTBAN_DATA_DIR/alert_throttle_firewall_csf"
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 1 ]]; then
    ok "T13 (R4) future-dated throttle clamped → 1 line emitted"
else
    no "T13 (R4) future-dated throttle clamped → 1 line emitted" "got $(count_fw_lines)"
fi
# T13a: throttle file overwritten with current (non-future) timestamp.
new_ts=$(cat "$NFTBAN_DATA_DIR/alert_throttle_firewall_csf" 2>/dev/null || echo 0)
if (( new_ts > 0 )) && (( new_ts < future_ts )); then
    ok "T13a (R4) throttle re-stamped with current time (no longer future)"
else
    no "T13a (R4) throttle re-stamped with current time (no longer future)" "ts=$new_ts"
fi

# -----------------------------------------------------------------------------
# T14 (R5): same TAG appearing twice in one array → exactly ONE alert line
# (the first stamps throttle; the second hits fresh throttle, no escalation).
# -----------------------------------------------------------------------------
reset_scratch
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034
NFTBAN_FIREWALL_CONFLICTS=("FAIL2BAN: first occurrence" "FAIL2BAN: second occurrence")
nftban_emit_firewall_conflict_alerts
if [[ "$(count_fw_lines)" -eq 1 ]]; then
    ok "T14 (R5) same TAG twice in one array → exactly 1 line (intra-run dedup)"
else
    no "T14 (R5) same TAG twice in one array → exactly 1 line (intra-run dedup)" "got $(count_fw_lines)"
fi

# -----------------------------------------------------------------------------
# T15 (R6): non-writable log dir (mkdir -p fails) → function returns 0,
# no emission, no host abort. Uses /proc/sys (read-only fs, even for root)
# to model the failure hermetically without permission games.
# -----------------------------------------------------------------------------
reset_scratch
saved_log_dir="$NFTBAN_LOG_DIR"
export NFTBAN_LOG_DIR=/proc/sys/kernel/nftban-v138-prb-test-readonly
# shellcheck disable=SC2034
NFTBAN_FIREWALL_SEVERITY=$CONFLICT_WARNING
# shellcheck disable=SC2034
NFTBAN_FIREWALL_CONFLICTS=("FIREWALLD: readonly-dir test")
nftban_emit_firewall_conflict_alerts; rc=$?
export NFTBAN_LOG_DIR="$saved_log_dir"
if [[ "$rc" -eq 0 ]]; then
    ok "T15 (R6) non-writable log dir → emitter returns 0 (best-effort)"
else
    no "T15 (R6) non-writable log dir → emitter returns 0 (best-effort)" "rc=$rc"
fi
# T15a: nothing was emitted to the saved scratch log either.
if [[ "$(count_fw_lines)" -eq 0 ]]; then
    ok "T15a (R6) no line emitted to scratch log when target dir was unwritable"
else
    no "T15a (R6) no line emitted to scratch log when target dir was unwritable" "got $(count_fw_lines)"
fi

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------
echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
