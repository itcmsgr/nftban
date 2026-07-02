#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Install/Update Observability (v1.215.0, PR-1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="install-update-observability-v215-test"
# meta:type="test"
# meta:header="Install/Update Observability v1.215.0 PR-1"
# meta:version="1.214.0"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Verify the structured final update summary (_update_final_summary) on success/degraded/failed paths + the 4 wired call sites + legacy line preserved + no JSON on console + run.jsonl untouched."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LOG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-07-03"
# meta:updated_date="2026-07-03"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
HELPERS="$REPO_ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
CMD_UPDATE="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"
PASS=0; FAIL=0
ok(){ echo "PASS $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL $1"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# stub systemctl so failed_units is deterministic (0 failed)
mkdir -p "$WORK/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/systemctl"; chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"

# source only the renderer (extract it to avoid pulling the whole update flow)
# — but the function is self-contained, so source the helpers file in a guarded subshell.
# shellcheck disable=SC1090
if ! source "$HELPERS" 2>/dev/null; then
    # fallback: extract the function body if full-source has unmet deps
    sed -n '/^_update_final_summary()/,/^}/p' "$HELPERS" > "$WORK/fn.sh"; source "$WORK/fn.sh"
fi

export _RUN_ID="20260703T101010Z-4242"
export FORENSIC_RUN_DIR="/var/log/nftban/update-runs/$_RUN_ID"
export UPDATE_LOG_FILE="/var/log/nftban/update.log"

# --- A: success path (validation passed explicitly as the arg the caller would compute) ---
outA=$(_update_final_summary "COMMITTED" "1.214.0" "1.215.0" "42" "0" "PASS")
grep -q "Result:.*COMMITTED"                 <<<"$outA" && ok "A result COMMITTED"           || no "A result"
grep -q "Version:.*v1.214.0 → v1.215.0 (42s)" <<<"$outA" && ok "A version before→after+dur"   || no "A version"
grep -q "Warnings:.*0"                        <<<"$outA" && ok "A warnings"                    || no "A warnings"
grep -q "Failed units:.*0"                    <<<"$outA" && ok "A failed-units"                || no "A failed-units"
grep -q "Validation:.*PASS"                   <<<"$outA" && ok "A validation"                 || no "A validation"
grep -q "Run ID:.*$_RUN_ID"                   <<<"$outA" && ok "A run_id shown"               || no "A run_id"
grep -q "Log dir:.*update-runs/$_RUN_ID"      <<<"$outA" && ok "A per-run log dir"            || no "A log dir"
grep -q "Log:.*update.log"                    <<<"$outA" && ok "A update.log path"            || no "A log path"
grep -q "{" <<<"$outA" && no "A NO JSON on console" || ok "A no JSON on console"

# --- B: degraded path ---
outB=$(_update_final_summary "DEGRADED" "1.214.0" "1.215.0" "9" "3" "DEGRADED")
grep -q "Result:.*DEGRADED" <<<"$outB" && ok "B result DEGRADED" || no "B result"
grep -q "Warnings:.*3"      <<<"$outB" && ok "B warnings=3"      || no "B warnings"
grep -q "Run ID:.*$_RUN_ID" <<<"$outB" && ok "B run_id shown"   || no "B run_id"
grep -q "Log:.*update.log"  <<<"$outB" && ok "B log path"       || no "B log path"

# --- C: failed path ---
outC=$(_update_final_summary "FAILED" "1.214.0" "1.215.0" "3" "1" "FAILED")
grep -q "Result:.*FAILED"   <<<"$outC" && ok "C result FAILED"  || no "C result"
grep -q "Log dir:.*update-runs" <<<"$outC" && ok "C log dir"    || no "C log dir"

# --- D: static — 4 call sites wired (COMMITTED/DEGRADED/FAILED/UNKNOWN) + legacy line preserved ---
grep -q '_update_final_summary "COMMITTED"' "$CMD_UPDATE" && ok "D COMMITTED call wired"  || no "D COMMITTED call"
grep -q '_update_final_summary "DEGRADED"'  "$CMD_UPDATE" && ok "D DEGRADED call wired"   || no "D DEGRADED call"
grep -q '_update_final_summary "FAILED"'    "$CMD_UPDATE" && ok "D FAILED call wired"     || no "D FAILED call"
grep -q '_update_final_summary "COMMITTED" .* "UNKNOWN"' "$CMD_UPDATE" && ok "D fallback call wired" || no "D fallback call"
grep -q 'Updated: v\$current_version → v\$new_version' "$CMD_UPDATE" && ok "D legacy 'Updated: vX → vY' preserved" || no "D legacy line"

# --- E: renderer emits no lifecycle-JSON routing (does not touch run.jsonl / FORENSIC_JSONL) ---
grep -q 'FORENSIC_JSONL\|run.jsonl' <<<"$(declare -f _update_final_summary)" && no "E summary must not touch run.jsonl" || ok "E run.jsonl untouched by summary"

# --- F: start banner (up-front progress contract: total phases + run_id + logs) ---
outF=$(_update_start_banner)
grep -q "6 phases expected"          <<<"$outF" && ok "F start banner shows total phases" || no "F total phases"
grep -q "run_id: *$_RUN_ID"          <<<"$outF" && ok "F start banner shows run_id"        || no "F run_id"
grep -q "Logs: *.*update-runs/$_RUN_ID" <<<"$outF" && ok "F start banner shows per-run log dir" || no "F logs dir"
grep -q "{" <<<"$outF" && no "F no JSON in start banner" || ok "F no JSON in start banner"

# --- G: completed-phases in summary (6/6 on a full run; N/6 on partial) ---
_NFTBAN_UPDATE_PHASE_DONE=6
grep -q "Completed phases:.*6/6" <<<"$(_update_final_summary "COMMITTED" "1.214.0" "1.215.0" "42" "0" "PASS")" && ok "G completed phases 6/6 on success" || no "G 6/6"
_NFTBAN_UPDATE_PHASE_DONE=4
grep -q "Completed phases:.*4/6" <<<"$(_update_final_summary "FAILED" "1.214.0" "1.215.0" "9" "1" "FAILED")" && ok "G completed phases 4/6 on partial/fail" || no "G 4/6"
_NFTBAN_UPDATE_PHASE_DONE=6

# --- H: RPM + DEB share the SAME phase flow (alignment) + start banner wired ---
grep -q '_update_start_banner' "$CMD_UPDATE" && ok "H start banner wired" || no "H start banner wired"
# phase 2 wraps both package managers (RPM+DEB aligned): both calls exist between phase 2 and phase 3
p2=$(grep -n '_update_phase 2 "Install"' "$CMD_UPDATE" | head -1 | cut -d: -f1)
p3=$(grep -n '_update_phase 3 "Restart services"' "$CMD_UPDATE" | head -1 | cut -d: -f1)
rpm=$(grep -n '_update_via_rpm' "$CMD_UPDATE" | head -1 | cut -d: -f1)
deb=$(grep -n '_update_via_deb' "$CMD_UPDATE" | head -1 | cut -d: -f1)
if [ -n "$p2" ] && [ -n "$p3" ] && [ "$rpm" -gt "$p2" ] && [ "$rpm" -lt "$p3" ] && [ "$deb" -gt "$p2" ] && [ "$deb" -lt "$p3" ]; then
    ok "H RPM+DEB both inside the shared phase-2..3 flow (aligned)"
else
    no "H RPM+DEB phase alignment (rpm=$rpm deb=$deb p2=$p2 p3=$p3)"
fi
# all 6 ordered phase markers wired (belt-and-suspenders with r1b3)
for _pn in 1 2 3 4 5 6; do grep -q "_update_phase $_pn " "$CMD_UPDATE" && ok "H phase $_pn wired" || no "H phase $_pn"; done

echo "=== install_update_observability_v215: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
