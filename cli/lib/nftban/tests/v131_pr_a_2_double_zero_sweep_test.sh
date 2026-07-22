#!/usr/bin/env bash
# =============================================================================
# V131 PR-A.2 — double-zero pattern sweep regression guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v131_pr_a_2_double_zero_sweep_test"
# meta:type="test"
# meta:version="1.131.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-25"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="V131 PR-A.2 regression guard. The bug class fixed in PR-A (CB-1/CB-3) is `VAR=$(... grep -c ... || echo \"0\")`: grep -c prints \"0\" AND exits 1 on no-match, so `|| echo \"0\"` appends a SECOND \"0\", producing \"0\\n0\" which breaks `$((... + VAR))` arithmetic and `printf %d`. PR-A.2 swept the remaining ~41 sites across 23 files, replacing `|| echo \"0\"` with `|| true` (grep -c's own \"0\" is preserved; errexit suppressed; no concat). This test asserts (a) ZERO `grep -c ... || echo \"0\"` sites remain in executable (non-comment) shell code under cli/lib/nftban/, and (b) every shell file under cli/lib/nftban/ still parses with `bash -n`. Comment lines are excluded from (a) because they legitimately DOCUMENT the old pattern."
# meta:ta.id="v131_pr_a_2_double_zero_sweep_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="shell-hygiene"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail

_repo_root=$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)
_scan_root="$_repo_root/cli/lib/nftban"

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

echo "==============================================================================="
echo "V131 PR-A.2 — double-zero pattern sweep regression guard"
echo "  Scan root: $_scan_root"
echo "==============================================================================="

# ----------------------------------------------------------------------------
# A: no `grep -c ... || echo "0"` double-zero site remains in EXECUTABLE code.
#    Strip shell comments before scanning so the explanatory comments that
#    document the old pattern (e.g. cmd_blacklist.sh CB-1 comment) do not trip.
# ----------------------------------------------------------------------------
# A1: catches ALL FOUR dangerous variants — grep -c AND grep -cv, with the
# fallback echo either QUOTED ("0") or UNQUOTED (0). The regex deliberately
# does NOT use `[^|]*` (which stops at the first '|' and so misses grep
# patterns that themselves contain a pipe, e.g. grep -cv '^\s*$\|^#').
# Comments are stripped first so docs/witness lines that mention the old
# pattern do not trip the scan.
_A1_RE='grep[[:space:]]+-c[a-zA-Z]*.*\|\|[[:space:]]*echo[[:space:]]+("0"|0)([[:space:]]|\)|;|\||$)'
_offenders=""
while IFS= read -r f; do
    if sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$f" \
        | grep -qE "$_A1_RE"; then
        _offenders+="$f"$'\n'
    fi
done < <(find "$_scan_root" -type f -name '*.sh' ! -name '*_test.sh')

if [[ -z "$_offenders" ]]; then
    _t_assert "A1: no grep -c/-cv '|| echo 0' or '|| echo \"0\"' double-zero site remains (both variants)" 0
else
    _t_assert "A1: no grep -c/-cv '|| echo 0' or '|| echo \"0\"' double-zero site remains (both variants)" 1 \
        "offending files:"$'\n'"$_offenders"
fi

# A2: semantic — no arithmetic expansion `$(( ... ))` directly embeds a
# `grep -c` command substitution. That shape feeds a possibly-multiline or
# empty count straight into arithmetic (crash), regardless of the fallback
# token; the safe form hoists the count into a variable first.
_a2=""
while IFS= read -r f; do
    if sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$f" \
        | grep -qE '\$\(\(.*\$\([^)]*grep[[:space:]]+-c'; then
        _a2+="$f"$'\n'
    fi
done < <(find "$_scan_root" -type f -name '*.sh' ! -name '*_test.sh')

if [[ -z "$_a2" ]]; then
    _t_assert "A2: no grep -c command-substitution embedded directly inside \$((...)) arithmetic" 0
else
    _t_assert "A2: no grep -c command-substitution embedded directly inside \$((...)) arithmetic" 1 \
        "offending files:"$'\n'"$_a2"
fi

# ----------------------------------------------------------------------------
# B: every shell file under the scan root still parses.
# ----------------------------------------------------------------------------
_broken=""
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || _broken+="$f"$'\n'
done < <(find "$_scan_root" -type f -name '*.sh')

if [[ -z "$_broken" ]]; then
    _t_assert "B1: every *.sh under cli/lib/nftban parses (bash -n)" 0
else
    _t_assert "B1: every *.sh under cli/lib/nftban parses (bash -n)" 1 \
        "broken files:"$'\n'"$_broken"
fi

# ----------------------------------------------------------------------------
# C: behavioral — prove the safe idiom yields a single integer (never 0\n0)
#    and that arithmetic on the result never crashes; and prove the OLD idiom
#    WOULD have produced the multiline value (witness the bug class).
# ----------------------------------------------------------------------------

# C1: no-match → single "0", arithmetic clean.
_c1=$(bash <<'BASH' 2>&1
set -Eeuo pipefail
c=$(printf 'a\nb\n' | grep -c 'ZZZ' || true); c=${c:-0}
[[ "$c" == *$'\n'* ]] && { echo "MULTILINE"; exit 1; }
echo $(( 1 + c ))
BASH
)
[[ "$_c1" == "1" ]] \
    && _t_assert "C1: safe idiom (|| true + \${c:-0}) no-match yields single int; arithmetic clean" 0 \
    || _t_assert "C1: safe idiom (|| true + \${c:-0}) no-match yields single int; arithmetic clean" 1 "got: $_c1"

# C2: error/file-not-found → empty coerced to 0, arithmetic clean.
_c2=$(bash <<'BASH' 2>&1
set -Eeuo pipefail
c=$(grep -c 'x' /nonexistent_path_xyz 2>/dev/null || true); c=${c:-0}
echo $(( 5 + c ))
BASH
)
[[ "$_c2" == "5" ]] \
    && _t_assert "C2: safe idiom error-case coerces empty to 0; arithmetic clean" 0 \
    || _t_assert "C2: safe idiom error-case coerces empty to 0; arithmetic clean" 1 "got: $_c2"

# C3: regression-witness — the OLD `|| echo "0"` idiom DID produce 0\n0 that
#     breaks arithmetic (proves these tests exercise the real bug class).
_c3=$(bash <<'BASH' 2>&1 || true
set -Eeuo pipefail
c=$(printf 'a\nb\n' | grep -c 'ZZZ' || echo "0")
echo $(( 1 + c ))
BASH
)
echo "$_c3" | grep -qE 'syntax error|operand' \
    && _t_assert "C3: regression-witness — OLD '|| echo \"0\"' idiom crashes arithmetic with 0\\n0" 0 \
    || _t_assert "C3: regression-witness — OLD '|| echo \"0\"' idiom crashes arithmetic with 0\\n0" 1 "old idiom did not crash; got: $_c3"

echo "-------------------------------------------------------------------------------"
echo "V131 PR-A.2 sweep test summary"
echo "  Passed:  $_pass"
echo "  Failed:  $_fail"
echo "-------------------------------------------------------------------------------"
[[ "$_fail" -eq 0 ]]
