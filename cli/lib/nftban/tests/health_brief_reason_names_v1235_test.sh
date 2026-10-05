#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - `nftban health brief` names the checks that actually warned
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="health_brief_reason_names_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BUG-HEALTH-BRIEF-NAMES-METRICS-INACTIVE-FROM-A-RETIRED-UNIT (v1.235). brief labelled every warning set 'metrics-inactive' whenever nftban-prometheus-exporter.timer was not active; that unit is no longer shipped, so every brief with warnings blamed metrics (measured: lab3 v1.234.0, 4 warnings from auditor ACLs / CLI errors / limiter capacity printed as '4 info (metrics-inactive)'). Drives the REAL _nftban_health_derive_counts (core/nftban_health.sh) and the REAL nftban_health_cmd_brief (cli/cmd_health_core.sh), extracted by name, against a fixed NFTBAN_HEALTH_RESULTS. Arms: B1 three warnings -> reason lists exactly those check names, never 'metrics-inactive' (systemctl stubbed to say the retired unit is inactive); B2 no warnings -> '0 info'; B3 an error -> ERROR line with counts; B4 derived names are sorted and exported. Set BRIEF_SUBJECT_ROOT to an older tree (e.g. e79a1173): B1 must FAIL there."
# meta:inventory.files="health_brief_reason_names_v1235_test.sh"
# meta:inventory.binaries="bash,awk,sort,tr,mktemp"
# meta:inventory.env_vars="BRIEF_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="health_brief_reason_names_v1235_test"
# meta:ta.owner="health"
# meta:ta.module="health-brief"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
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
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${BRIEF_SUBJECT_ROOT:-$REPO}"
HEALTH="$ROOT/cli/lib/nftban/core/nftban_health.sh"
CORE="$ROOT/cli/lib/nftban/cli/cmd_health_core.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: health brief names the checks that warned ==="
[[ -f "$HEALTH" && -f "$CORE" ]] || { echo "  NOT_EXECUTED: subject files missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# The retired unit is "not active" here, exactly as on every current host.
printf '#!/bin/sh\nexit 3\n' > "$W/bin/systemctl"; chmod 0755 "$W/bin/systemctl"

# Extract one function body by name (from "name() {" to the first "^}").
fn(){ awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f{print} f && /^}/{exit}' "$2"; }
fn _nftban_health_derive_counts "$HEALTH" > "$W/derive.sh"
fn nftban_health_cmd_brief "$CORE" > "$W/brief.sh"
[[ -s "$W/brief.sh" ]] || { echo "  NOT_EXECUTED: nftban_health_cmd_brief not found"; echo "RESULT: NOT_EXECUTED"; exit 3; }

# run_brief <results as k=v...> -> stdout of brief; rc in $W/rc
run_brief(){
    env -i PATH="$W/bin:/usr/bin:/bin" W="$W" bash -c '
set -Eeuo pipefail
declare -A NFTBAN_HEALTH_RESULTS=()
for kv in "$@"; do NFTBAN_HEALTH_RESULTS["${kv%%=*}"]="${kv#*=}"; done
# shellcheck source=/dev/null
[[ -s "$W/derive.sh" ]] && . "$W/derive.sh"
# shellcheck source=/dev/null
. "$W/brief.sh"
# Stand-in for the full check run: the results are fixed, the derivation is
# the real one when the subject has it; otherwise the v1.24.1 counts only.
nftban_health_check_all(){
    if declare -F _nftban_health_derive_counts >/dev/null; then _nftban_health_derive_counts; return 0; fi
    local e=0 w=0 t=0 k
    for k in "${!NFTBAN_HEALTH_RESULTS[@]}"; do t=$((t+1)); case "${NFTBAN_HEALTH_RESULTS[$k]}" in 2|3) e=$((e+1));; 1) w=$((w+1));; esac; done
    export NFTBAN_HEALTH_ERROR_COUNT=$e NFTBAN_HEALTH_WARNING_COUNT=$w NFTBAN_HEALTH_TOTAL_CHECKS=$t
}
rc=0; nftban_health_cmd_brief || rc=$?
printf "%s\n" "$rc" > "$W/rc"
printf "%s\n" "${NFTBAN_HEALTH_WARNING_NAMES:-<unset>}" > "$W/names"
' _ "$@"
}

# ---- B1 · three warnings: the reason is their names, not a guess -------------------
out="$(run_brief limiter_capacity=1 auditor_acls=1 cli_errors=1 nftables=0 geoip=0 2>&1 || true)"
want="OK | 2 checks passed | 3 info (auditor_acls, cli_errors, limiter_capacity)"
if [[ "$out" == "$want" ]]; then
    ok "B1 brief names the three checks that warned"
else
    no "B1 brief reason wrong" "got '$out' want '$want'"
fi
[[ "$out" != *metrics-inactive* ]] && ok "B1 no 'metrics-inactive' guess from the retired unit" \
                                    || no "B1 still blames metrics (retired nftban-prometheus-exporter.timer probe)"

# ---- B2 · no warnings ---------------------------------------------------------------
out="$(run_brief nftables=0 geoip=0 2>&1 || true)"
[[ "$out" == "OK | 2 checks passed | 0 info" && "$(cat "$W/rc")" == 0 ]] && ok "B2 clean run: '0 info', rc 0" \
                                                                          || no "B2 clean run wrong" "got '$out' rc=$(cat "$W/rc")"

# ---- B3 · an error ------------------------------------------------------------------
out="$(run_brief nftables=2 geoip=1 paths=0 2>&1 || true)"
[[ "$out" == "ERROR | 1 checks passed | 1 errors, 1 warnings" && "$(cat "$W/rc")" == 2 ]] && ok "B3 error run: ERROR line, rc 2" \
                                                                                          || no "B3 error run wrong" "got '$out' rc=$(cat "$W/rc")"

# ---- B4 · names are sorted and exported --------------------------------------------
run_brief zeta=1 alpha=1 mid=0 >/dev/null 2>&1 || true
[[ "$(cat "$W/names")" == "alpha zeta" ]] && ok "B4 NFTBAN_HEALTH_WARNING_NAMES sorted and exported" \
                                          || no "B4 warning names not derived" "got '$(cat "$W/names")'"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
