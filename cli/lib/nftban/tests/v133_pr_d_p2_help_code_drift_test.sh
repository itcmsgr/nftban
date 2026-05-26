#!/usr/bin/env bash
# =============================================================================
# V133 PR-D P2 — help/code drift regression guard (D-01, D-03..D-11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v133_pr_d_p2_help_code_drift_test"
# meta:type="test"
# meta:version="1.133.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V133 PR-D P2 targeted help/code-drift guard. Asserts the previously-undocumented dispatched subcommands are now documented in their command's help (D-05 status pending/queue; D-06 rbl config/stats/test; D-07 feeds config/stats/test; D-08 botscan stats/config + error fallback; D-09 geoban stats/test; D-10 login config/install; D-11 module duplicates) and that the stale references are gone tree-wide (D-01 'nftban gui', D-03 'emulate --out', D-04 'nftban profile select' — the latter allowed only in cmd_profile.sh which documents it as deprecated). NOT the comprehensive doctest guard or P3 alias allowlist (those are v1.134). D-02 was resolved in v1.132.0 PR-C and is not re-checked here."
# =============================================================================
set -Eeuo pipefail

_repo_root=$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)
_cli="$_repo_root/cli/lib/nftban/cli"
_scan="$_repo_root/cli/lib/nftban"

_pass=0; _fail=0
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then echo "  [PASS] $name"; _pass=$((_pass+1))
    else echo "  [FAIL] $name${detail:+ — $detail}"; _fail=$((_fail+1)); fi
}
_has()   { if grep -qF "$2" "$1"; then _t_assert "$3" 0; else _t_assert "$3" 1 "missing /$2/ in ${1##*/}"; fi; }

echo "==============================================================================="
echo "V133 PR-D P2 — help/code drift guard"
echo "==============================================================================="

echo "[D-05..D-11] dispatched subcommands now documented in help"
_has "$_cli/cmd_status.sh"  "pending, queue"                       "D-05 status: pending/queue documented"
_has "$_cli/cmd_rbl.sh"     "Show RBL configuration"               "D-06 rbl: config documented"
_has "$_cli/cmd_rbl.sh"     "Show RBL statistics"                  "D-06 rbl: stats documented"
_has "$_cli/cmd_rbl.sh"     "Test RBL configuration"               "D-06 rbl: test documented"
_has "$_cli/cmd_feeds.sh"   "Show feeds configuration"             "D-07 feeds: config documented"
_has "$_cli/cmd_feeds.sh"   "Show feeds statistics"                "D-07 feeds: stats documented"
_has "$_cli/cmd_feeds.sh"   "Test feed connectivity"               "D-07 feeds: test documented"
_has "$_cli/cmd_botscan.sh" "Show detection statistics"            "D-08 botscan: stats documented"
_has "$_cli/cmd_botscan.sh" "Show detection configuration"         "D-08 botscan: config documented"
_has "$_cli/cmd_botscan.sh" "status, stats, config"                "D-08 botscan: config in error fallback"
_has "$_cli/cmd_geoban.sh"  "Show GeoBan statistics"               "D-09 geoban: stats documented"
_has "$_cli/cmd_geoban.sh"  "Test GeoBan config"                   "D-09 geoban: test documented"
_has "$_cli/cmd_login.sh"   "Show login monitoring configuration"  "D-10 login: config documented"
_has "$_cli/cmd_login.sh"   "Install/provision login monitoring"   "D-10 login: install documented"
_has "$_cli/cmd_module.sh"  "Duplicate name/version conflict"      "D-11 module: duplicates documented"

echo "[D-01/D-03/D-04] stale references removed tree-wide"
# D-01: no dead 'nftban gui ...' command anywhere (outside tests)
if grep -rn 'nftban gui ' --include='*.sh' "$_scan" 2>/dev/null | grep -v '/tests/' | grep -q .; then
    _t_assert "D-01: no 'nftban gui' command reference" 1 "$(grep -rn 'nftban gui ' --include='*.sh' "$_scan" | grep -v '/tests/' | head -1)"
else _t_assert "D-01: no 'nftban gui' command reference" 0; fi
# D-03: no 'emulate --out' (nonexistent flag) anywhere (outside tests)
if grep -rn 'emulate --out' --include='*.sh' "$_scan" 2>/dev/null | grep -v '/tests/' | grep -q .; then
    _t_assert "D-03: no 'emulate --out' nonexistent flag" 1 "$(grep -rn 'emulate --out' --include='*.sh' "$_scan" | grep -v '/tests/' | head -1)"
else _t_assert "D-03: no 'emulate --out' nonexistent flag" 0; fi
# D-04: no 'nftban profile select' command (allowed only in cmd_profile.sh, which documents it deprecated)
if grep -rn 'nftban profile select' --include='*.sh' "$_scan" 2>/dev/null | grep -v '/tests/' | grep -v '/cmd_profile.sh:' | grep -q .; then
    _t_assert "D-04: no 'nftban profile select' outside cmd_profile.sh" 1 "$(grep -rn 'nftban profile select' --include='*.sh' "$_scan" | grep -v '/tests/' | grep -v '/cmd_profile.sh:' | head -1)"
else _t_assert "D-04: no 'nftban profile select' outside cmd_profile.sh" 0; fi

echo "[SYNTAX] touched files parse"
for f in cmd_wizard cmd_port cmd_egress cmd_ddos cmd_portscan cmd_menu cmd_status cmd_rbl cmd_feeds cmd_botscan cmd_geoban cmd_login cmd_module; do
    if bash -n "$_cli/$f.sh" 2>/dev/null; then _t_assert "bash -n $f.sh" 0; else _t_assert "bash -n $f.sh" 1; fi
done

echo "==============================================================================="
echo "Results: $_pass passed, $_fail failed"
echo "==============================================================================="
[[ "$_fail" -eq 0 ]]
