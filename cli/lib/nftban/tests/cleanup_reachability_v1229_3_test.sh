#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P1-6 — CLEANUP AUTHORITY REACHABILITY (cross-language)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cleanup-reachability-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-16"
# meta:description="Proves every governed cleanup class is reachable from a PRODUCTION scheduler/maintenance/lifecycle authority, not merely referenced somewhere: stats/snapshot retention from maintenance, CleanupReports from the collector lifecycle beside its siblings, and watchdog cleanup_old from the watchdog timer chain. Also proves the removed dead divergent duplicate authority (cleanup_all: hardcoded 30-day history exceeding the Go hard max, unbounded profiles) stays removed — by BEHAVIOR, not name. Cross-language by construction: shell AND Go are inspected, because a shell-only sweep previously misclassified two existing reapers as absent."
# meta:inventory.files="cli/lib/nftban/cron/maintenance.sh,cli/lib/nftban/core/nftban_stats_format.sh,cli/lib/nftban/core/nftban_watchdog.sh,internal/stats/collector.go,internal/stats/cleanup.go,internal/stats/config.go,install/systemd/nftban-watchdog.service"
# meta:inventory.privileges="none"
# meta:ta.id="cleanup_reachability_v1229_3_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   CALL_GRAPH_EDGE   != SCHEDULED_REACHABILITY
#   HAS CALLER        != PRODUCTION REACHABLE
#   SHELL SEARCH      != PRODUCT SEARCH
#   COMPONENT NAME    != CANONICAL IMPLEMENTATION LOCATION
#
# These four predicates are the corrections from the P1-6 reconciliation, where a
# shell-only, caller-exists sweep misclassified two existing reapers as absent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../../../.."
MAINT="$SCRIPT_DIR/../cron/maintenance.sh"
STATS_SH="$SCRIPT_DIR/../core/nftban_stats_format.sh"
WD="$SCRIPT_DIR/../core/nftban_watchdog.sh"
COLL="$ROOT/internal/stats/collector.go"
CLEAN="$ROOT/internal/stats/cleanup.go"
CFG="$ROOT/internal/stats/config.go"
UNIT="$ROOT/install/systemd/nftban-watchdog.service"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== cleanup authority reachability (v1.229.3 P1-6) ==="
for f in "$MAINT" "$STATS_SH" "$WD" "$COLL" "$CLEAN" "$CFG" "$UNIT"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }
done
pass "all seven subjects located (shell + Go + systemd unit — cross-language by construction)"

code_of(){ grep -vE '^\s*(#|//)' "$1"; }

# --- P1/P2 · stats/snapshot retention reached from MAINTENANCE -----------------
if code_of "$MAINT" | grep -q 'nftban_stats_cleanup_logs'; then
    pass "P1 maintenance production path reaches nftban_stats_cleanup_logs"
else
    fail "P1 maintenance does not call nftban_stats_cleanup_logs — manual CLI is the only authority again"
fi
if code_of "$MAINT" | grep -q 'nftban_stats_format.sh'; then
    pass "P2 maintenance sources the implementation before calling it (call can bind)"
else
    fail "P2 maintenance never loads nftban_stats_format.sh — the call could not resolve"
fi
awk '/^nftban_stats_cleanup_logs\(\) \{/,/^\}/' "$STATS_SH" | grep -q 'STATS_RETENTION_DAYS' \
    && pass "P8a policy authority unchanged (STATS_RETENTION_DAYS governs)" \
    || fail "P8a stats cleanup no longer governed by STATS_RETENTION_DAYS"

# --- P3/P4/P5 · CleanupReports wired beside siblings ---------------------------
RUNCLEAN="$(awk '/func \(c \*Collector\) runCleanup\(\)/,/^}/' "$COLL")"
[[ -n "$RUNCLEAN" ]] || { fail "P3 SUBJECT_NOT_FOUND: runCleanup"; RUNCLEAN=""; }
grep -q 'CleanupReports(c.config.ReportsDir, c.config.ReportsRetentionDays)' <<<"$RUNCLEAN" \
    && pass "P3 collector lifecycle reaches CleanupReports with the EXISTING policy fields" \
    || fail "P3 CleanupReports not wired into runCleanup with ReportsDir/ReportsRetentionDays"
grep -q 'CleanupHistory(' <<<"$RUNCLEAN" && grep -q 'CleanupProfiles(' <<<"$RUNCLEAN" \
    && pass "P4 CleanupHistory + CleanupProfiles remain wired" \
    || fail "P4 a sibling cleanup lost its wiring"
if grep -A2 'CleanupReports(' <<<"$RUNCLEAN" | grep -q 'log.Printf'; then
    pass "P5 CleanupReports failure handled non-fatally (log.Printf), matching sibling convention"
else
    fail "P5 CleanupReports error handling diverges from the collector convention"
fi
grep -q 'ReportsRetentionDays' "$CFG" \
    && pass "P8b ReportsRetentionDays policy field exists and is the value consumed" \
    || fail "P8b reports policy field missing"

# --- P6 · watchdog chain intact: timer -> run -> cleanup_old -------------------
grep -qE 'ExecStart=.*nftban watchdog run' "$UNIT" \
    && pass "P6a systemd unit executes 'nftban watchdog run'" \
    || fail "P6a watchdog unit no longer runs the watchdog entrypoint"
RUNBODY="$(awk '/^nftban_watchdog_run\(\) \{/,/^\}/' "$WD")"
grep -q 'nftban_watchdog_cleanup_old' <<<"$RUNBODY" \
    && pass "P6b nftban_watchdog_run reaches cleanup_old (scheduled chain intact)" \
    || fail "P6b cleanup_old fell out of the scheduled run path"

# --- P7/P11 · duplicate authority stays removed — by BEHAVIOR ------------------
if grep -qE '^nftban_watchdog_cleanup_all\(\) *\{' "$WD"; then
    fail "P7 dead duplicate cleanup_all is BACK as a definition"
else
    pass "P7 cleanup_all definition absent"
fi
if grep -q 'export -f nftban_watchdog_cleanup_all' "$WD"; then
    fail "P7 cleanup_all still exported"
else
    pass "P7 cleanup_all export absent"
fi
# BEHAVIOR guard: no SHELL cleanup may govern stats/history or stats/profiles —
# those classes belong to the wired Go authorities. Name changes cannot evade this.
SHELL_DUP=0
for shf in "$WD" "$MAINT" "$STATS_SH"; do
    if code_of "$shf" | grep -E 'stats/(history|profiles)' | grep -qE 'mtime|-delete|rm -f|rm -rf'; then
        fail "P11 $(basename "$shf") contains shell retention over stats/history|profiles — duplicate authority over Go-governed classes"
        SHELL_DUP=1
    fi
done
[[ $SHELL_DUP -eq 0 ]] && pass "P11 no shell retention governs stats/history or stats/profiles (Go authorities own them)"
code_of "$WD" | grep -qE 'mtime \+30' \
    && fail "P11 hardcoded 30-day retention survives (exceeds the Go hard max of 28)" \
    || pass "P11 divergent 30-day constant absent"

# --- P1b · BEHAVIORAL witness: the 9d block actually INVOKES the cleanup -------
# A token grep passes even when the call is dead ("if false && ..."), proven while
# building this test. So the real maintenance block is EXECUTED with a stubbed
# implementation, and invocation is asserted — reachability, not presence.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BLOCK="$(awk '/# 9d\. Stats\/snapshot retention/,/^$/' "$MAINT" | sed '1d')"
[[ -n "$BLOCK" ]] || fail "P1b SUBJECT_NOT_FOUND: 9d block not extracted"
export NFTBAN_LIB_DIR="$TMP/lib"
mkdir -p "$NFTBAN_LIB_DIR/core"
cat > "$NFTBAN_LIB_DIR/core/nftban_stats_format.sh" <<'STUB'
nftban_stats_cleanup_logs() { echo invoked > "${P1B_WITNESS:?}"; return 0; }
STUB
export P1B_WITNESS="$TMP/witness"
log(){ :; }
rm -f "$P1B_WITNESS"
eval "$BLOCK" >/dev/null 2>&1 || true
if [[ -f "$P1B_WITNESS" ]]; then
    pass "P1b BEHAVIORAL: the real 9d block, executed, INVOKES nftban_stats_cleanup_logs"
else
    fail "P1b the 9d block ran but never invoked the cleanup — call is present yet dead"
fi
unset NFTBAN_LIB_DIR P1B_WITNESS

# --- P9 · INVERSION: remove the maintenance call -> P1 must fail ---------------
sed 's/nftban_stats_cleanup_logs/nftban_stats_cleanup_logs_DISABLED/' "$MAINT" > "$TMP/maint_inv.sh"
if code_of "$TMP/maint_inv.sh" | grep -q 'nftban_stats_cleanup_logs\b'; then
    fail "P9 inversion ineffective — mutated maintenance still matches"
else
    pass "P9 INVERSION: removing the maintenance call is detected (P1 is falsifiable)"
fi

# --- P10 · INVERSION: remove the CleanupReports call -> P3 must fail -----------
sed 's/CleanupReports(/CleanupReportsDISABLED(/' "$COLL" > "$TMP/coll_inv.go"
if awk '/func \(c \*Collector\) runCleanup\(\)/,/^}/' "$TMP/coll_inv.go" | grep -q 'CleanupReports(c.config'; then
    fail "P10 inversion ineffective — mutated collector still matches"
else
    pass "P10 INVERSION: removing the collector call is detected (P3 is falsifiable)"
fi

# --- P11-INV · restore a synthetic divergent cleanup_all -> guard must fail ----
cat "$WD" > "$TMP/wd_inv.sh"
cat >> "$TMP/wd_inv.sh" <<'SYN'
_watchdog_tidy_everything() {
    find "${NFTBAN_DATA_DIR:-/var/lib/nftban}/stats/history" -name "*.json" -mtime +30 -delete
}
SYN
if grep -vE '^\s*(#|//)' "$TMP/wd_inv.sh" | grep -E 'stats/(history|profiles)' | grep -qE 'mtime|-delete'; then
    pass "P11 INVERSION: a synthetic divergent cleanup (different NAME) is caught by the behavior guard"
else
    fail "P11 inversion not caught — the guard is name-bound, not behavior-bound"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
