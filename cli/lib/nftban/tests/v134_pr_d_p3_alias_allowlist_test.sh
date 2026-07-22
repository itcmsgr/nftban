#!/usr/bin/env bash
# =============================================================================
# V134 PR-D P3 (Lane 1) — alias allowlist + D-26 document + D-28 fix guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v134_pr_d_p3_alias_allowlist_test"
# meta:type="test"
# meta:version="1.134.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:inventory.files="cli/lib/nftban/tests/v134_help_code_alias_allowlist.tsv"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V134 PR-D P3 Lane 1 guard. (1) D-26: health 'rbl'/'fhs' are documented in cmd_health.sh help. (2) D-28: cmd_metrics.sh error-usage string now includes evidence/evidence-json. (3) The intentional-alias allowlist manifest (v134_help_code_alias_allowlist.tsv) is well-formed (4 tab fields, valid class) and every allowlisted (cmd_file, token) pair is actually PRESENT in that command file — so the allowlist (basis for the Lane-2 doctest guard) can never silently allowlist a phantom/removed token. The rigorous per-family help<->dispatch correlation is Lane 2's doctest guard; this guard locks the allowlist basis + the two Lane-1 code fixes."
# meta:ta.id="v134_pr_d_p3_alias_allowlist_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-alias-allowlist"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

_lib=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)   # .../cli/lib/nftban
_man="$_lib/tests/v134_help_code_alias_allowlist.tsv"

_pass=0; _fail=0
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then echo "  [PASS] $name"; _pass=$((_pass+1))
    else echo "  [FAIL] $name${detail:+ — $detail}"; _fail=$((_fail+1)); fi
}

echo "==============================================================================="
echo "V134 PR-D P3 (Lane 1) — alias allowlist + D-26/D-28 guard"
echo "==============================================================================="

echo "[D-26] health rbl/fhs documented in help"
if grep -qF "Check RBL (DNS blocklist) health" "$_lib/cli/cmd_health.sh"; then _t_assert "D-26: 'rbl' in health help" 0; else _t_assert "D-26: 'rbl' in health help" 1; fi
if grep -qF "Check FHS compliance" "$_lib/cli/cmd_health.sh"; then _t_assert "D-26: 'fhs' in health help" 0; else _t_assert "D-26: 'fhs' in health help" 1; fi

echo "[D-28] metrics error-usage includes evidence/evidence-json"
if grep -qF "{evidence|evidence-json|enable|disable|status|pipeline|help}" "$_lib/cli/cmd_metrics.sh"; then _t_assert "D-28: metrics error-usage completed" 0; else _t_assert "D-28: metrics error-usage completed" 1; fi

echo "[allowlist] manifest well-formed"
if [[ -f "$_man" ]]; then _t_assert "manifest file exists" 0; else _t_assert "manifest file exists" 1 "$_man"; fi
# data rows = non-comment, non-blank
_rows() { grep -vE '^[[:space:]]*#' "$_man" | grep -vE '^[[:space:]]*$'; }
badfields=$(_rows | awk -F'\t' 'NF!=4' | wc -l)
_t_assert "every row has exactly 4 tab-separated fields (bad=$badfields)" "$([[ "$badfields" -eq 0 ]] && echo 0 || echo 1)"
badclass=$(_rows | awk -F'\t' '$3 !~ /^(alias|internal|universal-flag|deprecated|undocumented-subcmd)$/' | wc -l)
_t_assert "every row has a valid class (bad=$badclass)" "$([[ "$badclass" -eq 0 ]] && echo 0 || echo 1)"

echo "[allowlist] D-26/D-28 are fixed, NOT allowlisted"
if _rows | awk -F'\t' '$1=="cli/cmd_health.sh" && ($2=="rbl"||$2=="fhs")' | grep -q .; then _t_assert "health rbl/fhs NOT in allowlist (documented instead)" 1; else _t_assert "health rbl/fhs NOT in allowlist (documented instead)" 0; fi
if _rows | awk -F'\t' '$1=="cli/cmd_metrics.sh"' | grep -q .; then _t_assert "metrics NOT in allowlist (fixed instead)" 1; else _t_assert "metrics NOT in allowlist (fixed instead)" 0; fi

echo "[allowlist] every allowlisted token is present in its command file (no phantoms)"
missing=0
while IFS=$'\t' read -r cf tok _cls _note; do
    [[ -z "${cf:-}" ]] && continue
    if [[ ! -f "$_lib/$cf" ]]; then echo "    MISSING FILE: $cf"; missing=$((missing+1)); continue; fi
    if ! grep -qF -- "$tok" "$_lib/$cf"; then echo "    token '$tok' not found in $cf"; missing=$((missing+1)); fi
done < <(_rows)
_t_assert "all allowlisted tokens present in their command files (missing=$missing)" "$([[ "$missing" -eq 0 ]] && echo 0 || echo 1)"

echo "[syntax] touched files parse"
for f in cli/cmd_health.sh cli/cmd_metrics.sh; do
    if bash -n "$_lib/$f" 2>/dev/null; then _t_assert "bash -n $f" 0; else _t_assert "bash -n $f" 1; fi
done

echo "allowlist rows: $(_rows | wc -l)"
echo "==============================================================================="
echo "Results: $_pass passed, $_fail failed"
echo "==============================================================================="
[[ "$_fail" -eq 0 ]]
