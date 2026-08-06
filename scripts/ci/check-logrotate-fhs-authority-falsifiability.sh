#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability control for the logrotate FHS authority guard (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-logrotate-fhs-authority-falsifiability"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-06"
# meta:description="Proves check-logrotate-fhs-authority.sh is DISCRIMINATING. Injects each defect class the guard claims to catch and requires a FAIL, then injects a known-good line the guard previously rejected and requires a PASS. A guard that cannot fail is not protection, and v1.228.5 shipped two such guards: R-4 returned PASS after extracting zero patterns, and R-5 was blind to Go, systemd, packaging and JSON. Every mutation is restored immediately and the tree is verified byte-identical afterwards. Static only - mutates files in place, invokes no host."
# meta:input="scripts/ci/check-logrotate-fhs-authority.sh and the sources it reads"
# meta:output="PASS/FAIL per injection; exit 0 when the guard discriminates on every case"
# meta:depends="bash,grep,sed,cmp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,cmp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

GUARD="scripts/ci/check-logrotate-fhs-authority.sh"
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

BACKUP="$(mktemp -d)"
declare -a CREATED=()
declare -A BACKED=()

_key() { printf '%s' "$1" | tr '/' '_'; }
backup()  { cp -a "$1" "$BACKUP/$(_key "$1")"; BACKED["$1"]=1; }
created() { CREATED+=("$1"); }

restore_all() {
    local f
    for f in "${!BACKED[@]}"; do
        [[ -f "$BACKUP/$(_key "$f")" ]] && cp -a "$BACKUP/$(_key "$f")" "$f"
    done
    for f in "${CREATED[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
    BACKED=(); CREATED=()
}
# Restore runs on EVERY exit path, including interrupt. A falsifiability harness that
# leaves the repository mutated is worse than no harness at all.
trap 'restore_all; rm -rf "$BACKUP"' EXIT INT TERM

guard_rc() { bash "$GUARD" >/dev/null 2>&1; echo $?; }

# ---------------------------------------------------------------------------
# STAGE 0 — BASELINE. The unmutated tree must PASS, otherwise every "injection
# caused a FAIL" result below is unattributable.
# ---------------------------------------------------------------------------
echo "=== falsifiability control for $GUARD ==="
echo ""
echo "--- STAGE 0: baseline ---"
BASE_RC="$(guard_rc)"
if [[ "$BASE_RC" -eq 0 ]]; then
    ok "BASELINE_PASSES (rc=0) — injections below are attributable"
else
    bad "BASELINE_ALREADY_FAILS (rc=$BASE_RC) — cannot attribute any injection result"
    echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
    exit 1
fi

# ---------------------------------------------------------------------------
# expect_fail <name> <evidence-ERE> <mutation…>  guard MUST reject the injected defect
# expect_pass <name> <mutation…>                 guard MUST accept the correct construct
# ---------------------------------------------------------------------------
#
# A non-zero exit is NOT sufficient evidence that the injection was caught: any unrelated
# failure would satisfy it, and the harness would report a green matrix while proving
# nothing. The guard's own OUTPUT must name the injected construct.
#
# This assertion also closes the staleness question raised against the corpus optimisation.
# R5_CORPUS is a shell variable built during each guard PROCESS (no temp file, no cache
# directory, nothing persisted between runs), so a fresh `bash "$GUARD"` per case cannot
# reuse a pre-mutation snapshot — and requiring the injected artifact to appear in that
# run's output proves it empirically rather than by inspection.
#     INJECTION_VISIBLE_TO_GUARD = YES, asserted per case.
expect_fail() {
    local name="$1" evidence="$2"; shift 2
    "$@"
    local out rc
    out="$(bash "$GUARD" 2>&1)"; rc=$?
    restore_all
    if [[ "$rc" -eq 0 ]]; then
        bad "BLIND TO: $name (guard returned PASS)"
    elif grep -qE "$evidence" <<<"$out"; then
        ok "DETECTS: $name"
    else
        bad "MISATTRIBUTED: $name (guard failed, but its output never names the injection)"
    fi
}
expect_pass() {
    local name="$1"; shift
    "$@"
    local rc; rc="$(guard_rc)"
    restore_all
    if [[ "$rc" -eq 0 ]]; then ok "ACCEPTS: $name"; else bad "FALSE POSITIVE: $name (guard returned FAIL)"; fi
}

# ---------------------------------------------------------------------------
# STAGE 1 — R-4 injections
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 1: R-4 (migration classes have a retention owner) ---"

m_new_ext_deb() {
    backup packaging/deb/postinst
    sed -i 's|"\$_o"/\*\.json|"$_o"/*.json "$_o"/*.csv|' packaging/deb/postinst
}
# THE measured blind spot: adding *.csv to the migration previously yielded RESULT: PASS,
# so a newly migrated class silently acquired no retention owner.
expect_fail "a NEW migrated extension (*.csv) with no retention owner" '\*\.csv' m_new_ext_deb

m_rename_fn() {
    backup packaging/deb/postinst
    sed -i 's|_nftban_migrate_reports_to_log()|_nftban_migrate_reports_to_log_RENAMED()|' packaging/deb/postinst
}
expect_fail "the migration function renamed (subject extraction goes empty)" 'ABSENT or RENAMED' m_rename_fn

m_diverge() {
    backup packaging/build_nftban.sh
    sed -i 's|"\\\$_o"/\*\.json|"\\$_o"/*.json "\\$_o"/*.csv|' packaging/build_nftban.sh
}
expect_fail "DEB and RPM migrations moving DIFFERENT classes" 'DIFFERENT classes' m_diverge

m_drop_stanza() {
    backup install/config/nftban.logrotate
    sed -i 's|/var/log/nftban/reports/daily/\*\.json|/var/log/nftban/reports/daily/DROPPED.json|' install/config/nftban.logrotate
}
expect_fail "a migrated pattern losing its stanza in the shipped template" 'NO stanza' m_drop_stanza

# ---------------------------------------------------------------------------
# STAGE 2 — R-5 injections, one per surface the rule was previously blind to
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 2: R-5 (no operational writer resolves back under /var/lib) ---"

m_go_const() {
    created cmd/nftban-core/zz_falsify_const.go
    printf 'package main\n\nconst FalsifyReportsDir = "/var/lib/nftban/reports"\n' \
        > cmd/nftban-core/zz_falsify_const.go
}
expect_fail "a Go const naming the pre-migration path (*.go was never scanned)" 'zz_falsify_const\.go' m_go_const

m_systemd_env() {
    created install/systemd/zz-falsify.service
    printf '[Service]\nEnvironment=NFTBAN_REPORTS_DIR=/var/lib/nftban/reports\n' \
        > install/systemd/zz-falsify.service
}
expect_fail "a systemd Environment= override (install/systemd/ was never scanned)" 'zz-falsify\.service' m_systemd_env

m_json_default() {
    created install/config/zz-falsify.json
    printf '{ "reports_dir": "/var/lib/nftban/reports" }\n' > install/config/zz-falsify.json
}
expect_fail "a JSON schema default (*.json was never scanned)" 'zz-falsify\.json' m_json_default

m_indirection() {
    created install/config/zz-falsify.conf
    printf 'NFTBAN_REPORTS_DIR="${NFTBAN_DATA_DIR}/reports"\n' > install/config/zz-falsify.conf
}
expect_fail "pure indirection with NO literal old path in the line" 'zz-falsify\.conf' m_indirection

m_analytics_init() {
    backup cmd/nftban-core/cmd_suricata_status.go
    sed -i 's|analytics\.Init(dataDir, logDir+"/reports")|analytics.Init(dataDir, dataDir+"/reports")|' \
        cmd/nftban-core/cmd_suricata_status.go
}
# The exact BLOCKER-2 defect. R-5 exists to catch DEFAULT != EFFECTIVE and could not see
# this one, because it lives in a language the rule did not read.
expect_fail "analytics.Init reports argument rebuilt from dataDir (the BLOCKER-2 shape)" 'cmd_suricata_status\.go' m_analytics_init

# ---------------------------------------------------------------------------
# STAGE 3 — THE OTHER DIRECTION
# A guard that fails on correct code is as damaging as one that passes defects, and it is
# the failure that was one character away from firing on the shipped tree.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 3: correct constructs must NOT be rejected ---"

m_correct_with_comment() {
    created install/config/zz-falsify-ok.conf
    printf 'STATS_REPORTS_DIR="/var/log/nftban/reports"   # v1.228.5: moved from /var/lib/nftban/reports\n' \
        > install/config/zz-falsify-ok.conf
}
expect_pass "a CORRECT assignment carrying an ACCURATE trailing comment naming the old path" m_correct_with_comment

m_state_class() {
    created install/config/zz-falsify-state.conf
    printf 'NFTBAN_WATCHDOG_REPORT_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/reports/watchdog"\n' \
        > install/config/zz-falsify-state.conf
}
expect_pass "a state-class destination that legitimately stays under /var/lib (reports/watchdog)" m_state_class

m_dereference_only() {
    created install/config/zz-falsify-msg.sh
    printf 'echo "[INFO] Approved: ${NFTBAN_REPORTS_DIR} (reports), ${NFTBAN_DATA_DIR:-/var/lib/nftban}/* (exports)"\n' \
        > install/config/zz-falsify-msg.sh
}
# REGRESSION CONTROL. R-5a once matched any line carrying a reports-dir token and a
# /var/lib path, so an operator MESSAGE that merely dereferences the variable was reported
# as a misplaced declaration. The rule now requires an assignment operator. A guard that
# fires on correct code trains people to ignore it.
expect_pass "an operator message that DEREFERENCES the variable beside a /var/lib path" m_dereference_only

# ---------------------------------------------------------------------------
# STAGE 4 — RESTORATION PROOF. Every mutation must be gone.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 4: restoration ---"
FINAL_RC="$(guard_rc)"
if [[ "$FINAL_RC" -eq "$BASE_RC" ]]; then
    ok "TREE_RESTORED (guard rc back to baseline $BASE_RC)"
else
    bad "TREE_NOT_RESTORED (rc=$FINAL_RC, baseline=$BASE_RC) — INSPECT THE WORKING TREE"
fi
leftovers="$(ls -1 cmd/nftban-core/zz_falsify_*.go install/systemd/zz-falsify* \
                   install/config/zz-falsify* 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$leftovers" -eq 0 ]]; then
    ok "NO_INJECTED_FILES_LEFT"
else
    bad "INJECTED FILES REMAIN ($leftovers) — INSPECT THE WORKING TREE"
fi

echo ""
echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
