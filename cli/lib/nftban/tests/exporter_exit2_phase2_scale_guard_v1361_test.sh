#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.136.1 exporter exit-2 Phase 2 (scale-cache guard)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="exporter_exit2_phase2_scale_guard_v1361_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="v1.136.1 Phase-2 regression: the exporter's scale-level block reads the daemon-written /run/nftban/set_counts.json, which can be truncated/invalid mid-write. The pinned fatal site (collect.sh:642, monitor run #73565) was an unguarded jq assignment that aborted the run rc=2 under set -Eeuo pipefail. This test asserts (static) the production guard is present (jq -e validity gate + '|| _global_scale=NORMAL'; strict mode + ERR trap preserved) and (behavioral) that the guarded read pattern under strict mode does NOT exit non-zero on a truncated/empty cache and defaults global scale to NORMAL, while a valid cache still yields the correct scale. No host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,mktemp"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.binaries="bash,jq,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Lane:    V1_136_EXPORTER_EXIT2_PHASE2_SCOPE.md  (vehicle v1.136.1)
# Pinned:  V136_MONITOR_DEPLOY_AND_EXPORTER_BREADCRUMB_WATCH.md (run #73565)
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
COLLECT="${REPO_ROOT}/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
MAIN="${REPO_ROOT}/cli/lib/nftban/exporters/nftban_unified_exporter.sh"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0; FAILED_TESTS=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s (%s)\n" "$1" "$2"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
assert_eq(){ [[ "$1" == "$2" ]] && ok "$3" || no "$3" "expected '$2' got '$1'"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

echo "=========================================================="
echo "V1.136.1 exporter exit-2 Phase 2 — scale-cache guard test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# STATIC: production guard present + strict mode / ERR trap preserved
# ---------------------------------------------------------------------------
echo "--- static guards ---"
grep -q 'jq -e \. "\$_scale_cache"' "$COLLECT" && ok "static_validity_gate_present" || no "static_validity_gate_present" "jq -e gate missing"
grep -q '|| _global_scale="NORMAL"' "$COLLECT" && ok "static_global_scale_fallback_present" || no "static_global_scale_fallback_present" "fallback missing"
grep -q '^set -Eeuo pipefail' "$COLLECT" && ok "static_strict_mode_preserved_collect" || no "static_strict_mode_preserved_collect" "strict mode removed"
grep -q "trap '.*' ERR" "$MAIN" && ok "static_err_trap_preserved" || no "static_err_trap_preserved" "ERR trap removed"

# ---------------------------------------------------------------------------
# BEHAVIORAL: replicate the EXACT guarded scale-read pattern under strict mode
# and run it against fixtures. Mirrors collect.sh:642-651.
# ---------------------------------------------------------------------------
echo "--- guarded read behavior (strict mode) ---"
make_runner() {
    cat > "$SANDBOX/scaleread.sh" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
_scale_cache="$1"
_global_scale="NORMAL"
if jq -e . "$_scale_cache" >/dev/null 2>&1; then
    _global_scale=$(jq -r '.scale_mode // "NORMAL"' "$_scale_cache" 2>/dev/null) || _global_scale="NORMAL"
fi
_global_num=0
case "$_global_scale" in
    LARGE) _global_num=1 ;; VERY_LARGE) _global_num=2 ;; HUGE) _global_num=3 ;;
    EXTREME) _global_num=4 ;; CRITICAL_SCALE) _global_num=5 ;;
esac
echo "scale=$_global_scale num=$_global_num"
RUN
    chmod +x "$SANDBOX/scaleread.sh"
}
make_runner
run_case() { set +e; out=$(bash "$SANDBOX/scaleread.sh" "$1" 2>/dev/null); rc=$?; set -e; echo "$rc|$out"; }

# valid cache, scale_mode=LARGE → rc0, num=1
printf '{"scale_mode":"LARGE","sets":{}}' > "$SANDBOX/valid.json"
r=$(run_case "$SANDBOX/valid.json"); assert_eq "${r%%|*}" "0" "valid_rc0"; assert_eq "${r#*|}" "scale=LARGE num=1" "valid_scale_LARGE"

# truncated/invalid (mid-write race) → rc0 (NO abort), default NORMAL num=0
printf '{"scale_mode":"LAR' > "$SANDBOX/trunc.json"
r=$(run_case "$SANDBOX/trunc.json"); assert_eq "${r%%|*}" "0" "truncated_rc0_no_abort"; assert_eq "${r#*|}" "scale=NORMAL num=0" "truncated_defaults_NORMAL"

# empty file → rc0, NORMAL
: > "$SANDBOX/empty.json"
r=$(run_case "$SANDBOX/empty.json"); assert_eq "${r%%|*}" "0" "empty_rc0_no_abort"; assert_eq "${r#*|}" "scale=NORMAL num=0" "empty_defaults_NORMAL"

# valid JSON but scale_mode absent → in-jq default NORMAL, rc0
printf '{"sets":{}}' > "$SANDBOX/nofield.json"
r=$(run_case "$SANDBOX/nofield.json"); assert_eq "${r%%|*}" "0" "missing_field_rc0"; assert_eq "${r#*|}" "scale=NORMAL num=0" "missing_field_defaults_NORMAL"

# valid CRITICAL_SCALE → num=5
printf '{"scale_mode":"CRITICAL_SCALE","sets":{}}' > "$SANDBOX/crit.json"
r=$(run_case "$SANDBOX/crit.json"); assert_eq "${r#*|}" "scale=CRITICAL_SCALE num=5" "valid_critical_num5"

echo
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="
if (( FAIL > 0 )); then echo "Failed:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done; exit 1; fi
echo "All v1.136.1 exporter exit-2 Phase-2 scale-guard tests passed."
exit 0
