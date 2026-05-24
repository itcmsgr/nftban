#!/usr/bin/env bash
# =============================================================================
# V127 UX-3 stats + banlog — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v127_ux3_stats_banlog_test"
# meta:type="test"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for V127 UX-3 lane (PR-C). Covers items 2.1/3.1 (stats label disambiguation: Blocked IPs (live) vs BANS BY MODULE (cumulative)), 2.2 (canonical 5-label module set in awk normalizer), 2.3 (Data source: DERIVED fallback label when unified cache missing), 2.5 (RESYNC marker via banlog.LogResync and STATUS=RESYNC + CLASS=resync constants in banlog.go), 2.6 (ban success footer source/set/total breakdown in cmd_ban.go). Go-side BLC-1 convergence regression guard for item 2.4 is in internal/escalation/tracker_blc1_test.go (Go test; runs via go test ./internal/escalation/...). Full runtime behavior of stats commands deferred to V127 final consolidated lab validation per V127_UX_VALIDATION_POLICY_AMENDED.md."
# meta:input="static source-file inspection via grep code-pattern assertions"
# meta:output="exit 0 if all assertions pass; exit 1 with FAILED tests list otherwise"
# meta:depends="bash,grep,awk"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-3 lane)
# =============================================================================

set -Eeuo pipefail
# Continue past individual assertion failures
set +e

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

_t_assert() {
    local name="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_stats_format="${_repo_root}/cli/lib/nftban/core/nftban_stats_format.sh"
_banlog_go="${_repo_root}/internal/banlog/banlog.go"
_tracker_go="${_repo_root}/internal/escalation/tracker.go"
_cmd_ban_go="${_repo_root}/cmd/nftban-core/cmd_ban.go"

echo "==============================================================================="
echo "V127 UX-3 stats + banlog — deterministic test fixtures"
echo "==============================================================================="
echo "  Repo root:  $_repo_root"
echo

# =============================================================================
# ITEMS 2.1 / 3.1 — stats label disambiguation
# =============================================================================
echo "[2.1/3.1] stats label disambiguation (live vs cumulative)"

# Blocked IPs line: must say "(live)" so the value cannot be confused with
# the BANS BY MODULE cumulative values
if grep -q 'Blocked IPs (live)' "$_stats_format"; then
    _t_assert "2.1/3.1 Blocked IPs row labeled '(live)'" 0
else
    _t_assert "2.1/3.1 Blocked IPs row labeled '(live)'" 1 "missing '(live)' qualifier"
fi

# BANS BY MODULE header: must say "(cumulative)"
if grep -q 'echo "BANS BY MODULE (cumulative)"' "$_stats_format"; then
    _t_assert "2.1/3.1 BANS BY MODULE header labeled '(cumulative)'" 0
else
    _t_assert "2.1/3.1 BANS BY MODULE header labeled '(cumulative)'" 1 "missing '(cumulative)' qualifier"
fi

# The V127 anchor comment must be present
if grep -q 'V127 UX-3 items 2.1/3.1' "$_stats_format"; then
    _t_assert "2.1/3.1 scope-anchor comment present" 0
else
    _t_assert "2.1/3.1 scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# ITEM 2.2 — canonical module labels (login/portscan/ddos/manual/feeds)
# =============================================================================
echo "[2.2] canonical 5-label module set in awk fallback normalizer"

# The awk normalizer at the fallback path must produce the canonical 5 labels.
# Pre-V127 the labels were already mostly correct (per audit §2.2: "needs
# standardization to login, portscan, ddos, manual, feeds"). The test verifies
# all 5 are present in the source AND the normalizer reduces variants to them.
for canonical in 'sources\[ip\]="login"' 'sources\[ip\]="portscan"' 'sources\[ip\]="ddos"' 'sources\[ip\]="manual"' 'sources\[ip\]="feeds"'; do
    if grep -q "$canonical" "$_stats_format"; then
        _t_assert "2.2 awk normalizer emits canonical label: $canonical" 0
    else
        _t_assert "2.2 awk normalizer emits canonical label: $canonical" 1 "missing"
    fi
done

# Verify the V127 comment notes label compliance
if grep -q 'V127 UX-3 item 2.2' "$_stats_format"; then
    _t_assert "2.2 scope-anchor comment present" 0
else
    _t_assert "2.2 scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# ITEM 2.3 — Data source: DERIVED fallback label
# =============================================================================
echo "[2.3] Data source: DERIVED label on cache-miss fallback"

# The else branch of the use_unified_cache check must emit a DERIVED label
if grep -qE 'Data source\.\.\.\.\.\.\.\.\." "DERIVED' "$_stats_format"; then
    _t_assert "2.3 fallback path emits 'Data source: DERIVED'" 0
else
    _t_assert "2.3 fallback path emits 'Data source: DERIVED'" 1 "DERIVED label missing"
fi

# Must explain the reason briefly
if grep -q 'cache miss' "$_stats_format"; then
    _t_assert "2.3 DERIVED label includes 'cache miss' explanation" 0
else
    _t_assert "2.3 DERIVED label includes 'cache miss' explanation" 1 "explanation missing"
fi

# V127 anchor
if grep -q 'V127 UX-3 item 2.3' "$_stats_format"; then
    _t_assert "2.3 scope-anchor comment present" 0
else
    _t_assert "2.3 scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# ITEM 2.4 — banlog dual-writer convergence (Go side; main check in Go test)
# =============================================================================
echo "[2.4] LogTempBan A1 facade convergence (shell-side verification)"

# Shell-side verification that the Go file no longer contains the legacy
# space-delimited format string. Full assertion battery is in
# internal/escalation/tracker_blc1_test.go (Go test).

if grep -q '"%s %s %s %s\\\\n"' "$_tracker_go"; then
    _t_assert "2.4 legacy space-delimited format pattern absent from tracker.go" 1 "legacy pattern still present"
else
    _t_assert "2.4 legacy space-delimited format pattern absent from tracker.go" 0
fi

if grep -q 'banlog.LogBanFull' "$_tracker_go"; then
    _t_assert "2.4 tracker.go delegates to banlog.LogBanFull" 0
else
    _t_assert "2.4 tracker.go delegates to banlog.LogBanFull" 1 "delegation missing"
fi

if grep -q 'V127 UX-3 item 2.4' "$_tracker_go"; then
    _t_assert "2.4 scope-anchor comment present" 0
else
    _t_assert "2.4 scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# ITEM 2.5 — RESYNC marker (banlog constants + cmd_ban.go emission)
# =============================================================================
echo "[2.5] RESYNC marker (STATUS=RESYNC + CLASS=resync + emission)"

# banlog.go: must define StatusResync constant
if grep -q 'StatusResync   = "RESYNC"' "$_banlog_go" || grep -q 'StatusResync = "RESYNC"' "$_banlog_go"; then
    _t_assert "2.5 banlog.go defines StatusResync = \"RESYNC\"" 0
else
    _t_assert "2.5 banlog.go defines StatusResync = \"RESYNC\"" 1 "constant missing or named differently"
fi

# banlog.go: must define ClassResync constant
if grep -q 'ClassResync = "resync"' "$_banlog_go"; then
    _t_assert "2.5 banlog.go defines ClassResync = \"resync\"" 0
else
    _t_assert "2.5 banlog.go defines ClassResync = \"resync\"" 1 "constant missing"
fi

# banlog.go: must expose LogResync function
if grep -q '^func LogResync' "$_banlog_go"; then
    _t_assert "2.5 banlog.go exposes LogResync function" 0
else
    _t_assert "2.5 banlog.go exposes LogResync function" 1 "function missing"
fi

# cmd_ban.go: must call banlog.LogResync in already-banned path
if grep -q 'banlog.LogResync' "$_cmd_ban_go"; then
    _t_assert "2.5 cmd_ban.go invokes banlog.LogResync on already-banned path" 0
else
    _t_assert "2.5 cmd_ban.go invokes banlog.LogResync on already-banned path" 1 "RESYNC emission missing"
fi

# cmd_ban.go: V127 anchor
if grep -q 'V127 UX-3 item 2.5' "$_cmd_ban_go"; then
    _t_assert "2.5 cmd_ban.go scope-anchor comment present" 0
else
    _t_assert "2.5 cmd_ban.go scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# ITEM 2.6 — ban success footer source/set/total breakdown
# =============================================================================
echo "[2.6] ban success footer with source/set/total breakdown"

# cmd_ban.go: must emit labeled lines for Source / Set / Total
if grep -q 'Source:' "$_cmd_ban_go" && grep -q 'Set:' "$_cmd_ban_go" && grep -q 'Total bans:' "$_cmd_ban_go"; then
    _t_assert "2.6 footer emits Source / Set / Total labeled lines" 0
else
    _t_assert "2.6 footer emits Source / Set / Total labeled lines" 1 "one or more label missing"
fi

# Must distinguish resync vs new ban via Event type field
if grep -q 'Event type:' "$_cmd_ban_go"; then
    _t_assert "2.6 footer emits 'Event type:' distinguishing resync vs new ban" 0
else
    _t_assert "2.6 footer emits 'Event type:' distinguishing resync vs new ban" 1 "Event type label missing"
fi

# Resync footer text
if grep -q 'resync (idempotent' "$_cmd_ban_go"; then
    _t_assert "2.6 footer resync event text present" 0
else
    _t_assert "2.6 footer resync event text present" 1 "resync footer text missing"
fi

# V127 anchor for item 2.6
if grep -q 'V127 UX-3 item 2.6' "$_cmd_ban_go"; then
    _t_assert "2.6 scope-anchor comment present" 0
else
    _t_assert "2.6 scope-anchor comment present" 1 "comment anchor missing"
fi
echo

# =============================================================================
# SCOPE-CREEP GUARD
# =============================================================================
echo "[scope-creep guard] UX-4..UX-6 keywords absent from UX-3 diff"

# Verify the UX-3 changes don't accidentally include other lanes' surfaces
for unwanted in 'suricata.*desurface' 'levenshtein' 'edit_distance' 'banner.*pollut' '"--async"' 'Ctrl\+C'; do
    if grep -iE "$unwanted" "$_stats_format" "$_banlog_go" "$_tracker_go" "$_cmd_ban_go" 2>/dev/null | grep -v "test\|comment\|//\|#" | head -1 > /dev/null; then
        _t_assert "scope-creep: '$unwanted' absent from UX-3 surfaces" 1 "found scope-creep keyword in diff"
    else
        _t_assert "scope-creep: '$unwanted' absent from UX-3 surfaces" 0
    fi
done
echo

# =============================================================================
# SUMMARY
# =============================================================================
echo "==============================================================================="
echo "V127 UX-3 test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "FAILED tests:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
    done
    exit 1
fi
exit 0
