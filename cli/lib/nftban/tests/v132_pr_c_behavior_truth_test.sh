#!/usr/bin/env bash
# =============================================================================
# V132 PR-C — behavior-truth regression guard (C1/C2/C3/C5/C7/C8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v132_pr_c_behavior_truth_test"
# meta:type="test"
# meta:version="1.132.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V132 PR-C behavior-truth regression guard. Static assertions that the displayed CLI text matches actual code behavior after the PR-C truth-alignment fixes: C1 (version --json emits no raw sentinel line), C2 (flush no longer advertises an unimplemented --json), C3 (flush returns rc=2 for invalid target/option and help no longer documents a non-existent rc=3 polkit branch), C5 (stale fail2ban-era 'jails' top-type replaced by 'filters' backed by the real nftban_stats_top_sources; no dead top_jails key; no bogus 'nftban migrate fail2ban' command; no 'Protected with fail2ban' claim), C7 (firewall validate --strict help documents the reachable exit codes 1 and 40), C8 (validate shim returns 3 — not 2 — for a missing/unreachable validator so rc=2 means DOWN only). Pure static + bash -n; no host contact, no build, no privileges."
# meta:ta.id="v132_pr_c_behavior_truth_test"
# meta:ta.owner="cli"
# meta:ta.module="cli"
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

_repo_root=$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)
_cli="$_repo_root/cli/lib/nftban/cli"
_core="$_repo_root/cli/lib/nftban/core"
_scan="$_repo_root/cli/lib/nftban"

_pass=0
_fail=0
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then
        echo "  [PASS] $name"; _pass=$((_pass+1))
    else
        echo "  [FAIL] $name${detail:+ — $detail}"; _fail=$((_fail+1))
    fi
}
# _match PATH PATTERN — grep -E; recurses over *.sh when PATH is a directory
_match() { if [[ -d "$1" ]]; then grep -rqE --include='*.sh' --exclude-dir=tests "$2" "$1"; else grep -qE "$2" "$1"; fi; }
# pass when pattern IS present
_has()   { if _match "$1" "$2"; then _t_assert "$3" 0; else _t_assert "$3" 1 "missing /$2/ in ${1##*/}"; fi; }
# pass when pattern is ABSENT
_lacks() { if _match "$1" "$2"; then _t_assert "$3" 1 "unexpected /$2/ in ${1##*/}"; else _t_assert "$3" 0; fi; }

echo "==============================================================================="
echo "V132 PR-C — behavior-truth regression guard"
echo "  Scan root: $_scan"
echo "==============================================================================="

echo "[C1] version --json emits valid JSON (no raw completion sentinel)"
_lacks "$_cli/cmd_version.sh" 'echo "# NFTBAN_CMD_EXIT: version"' "C1: raw sentinel echo removed"
_has  "$_cli/cmd_version.sh" 'nftban_cmd_exit "version"'          "C1: uses debug-gated nftban_cmd_exit helper"

echo "[C2] flush no longer advertises an unimplemented --json"
_lacks "$_cli/cmd_flush.sh" '[-][-]json' "C2: --json advertisement removed from flush"
_lacks "$_cli/cmd_flush.sh" 'json_mode=' "C2: dead json_mode variable removed"

echo "[C3] flush exit-code truth (rc=2 for invalid input; no false rc=3)"
_has  "$_cli/cmd_flush.sh" 'Unknown target: \$target'            "C3: unknown-target path present"
_has  "$_cli/cmd_flush.sh" 'return 2'                            "C3: returns rc=2 for invalid target/option"
_has  "$_cli/cmd_flush.sh" 'Unsupported target / invalid argument' "C3: help retains rc=2 documentation"
_lacks "$_cli/cmd_flush.sh" 'PolicyKit/polkit authorization failed' "C3: false rc=3 polkit line removed (flush has no polkit branch)"

echo "[C5] stale fail2ban 'jails' replaced by working 'filters'"
_lacks "$_cli/cmd_stats.sh" 'nftban_stats_top_jails' "C5: undefined nftban_stats_top_jails reference gone"
_has  "$_cli/cmd_stats.sh" 'nftban_stats_top_sources' "C5: filters backed by real nftban_stats_top_sources"
_has  "$_cli/cmd_stats.sh" 'filters\|filter\)'        "C5: 'filters' top-type dispatch present"
_lacks "$_cli/cmd_stats.sh" 'top_jails'               "C5: dead top_jails JSON key removed"
_lacks "$_cli/cmd_stats.sh" 'Valid types: ips, countries, jails' "C5: help/errors no longer advertise jails"
_lacks "$_scan" 'nftban migrate fail2ban'            "C5: bogus 'nftban migrate fail2ban' remediation removed (tree-wide)"
_lacks "$_scan" 'Protected with fail2ban'            "C5: false 'Protected with fail2ban' claim removed (tree-wide)"

echo "[C7] firewall validate --strict documents reachable exit codes 1 and 40"
_has "$_cli/cmd_firewall.sh" 'Structural validation failed'              "C7: strict help documents rc=1 (structural)"
_has "$_cli/cmd_firewall.sh" 'Validator binary missing or environment error' "C7: strict help documents rc=40 (env)"

echo "[C8] validate shim: missing/unreachable validator returns 3 (not 2=DOWN)"
_has "$_core/nftban_ip_and_stats.sh" 'return 3'        "C8: shim returns 3 for missing/empty validator"
_has "$_core/nftban_ip_and_stats.sh" 'case "\$go_rc" in' "C8: passthrough clamp normalizes unexpected validator rc"
_has "$_cli/cmd_validate.sh" 'Validator binary crashed or was unreachable' "C8: help documents rc=3 contract"

echo "[SYNTAX] touched files parse with bash -n"
for f in cmd_version.sh cmd_flush.sh cmd_stats.sh cmd_firewall.sh cmd_validate.sh cmd_test.sh cmd_services.sh; do
    if bash -n "$_cli/$f" 2>/dev/null; then _t_assert "bash -n cli/$f" 0; else _t_assert "bash -n cli/$f" 1; fi
done
for f in nftban_ip_and_stats.sh nftban_firewall_conflicts.sh; do
    if bash -n "$_core/$f" 2>/dev/null; then _t_assert "bash -n core/$f" 0; else _t_assert "bash -n core/$f" 1; fi
done

echo "==============================================================================="
echo "Results: $_pass passed, $_fail failed"
echo "==============================================================================="
[[ "$_fail" -eq 0 ]]
