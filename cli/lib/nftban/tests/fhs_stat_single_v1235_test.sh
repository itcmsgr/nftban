#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - FHS audit: one stat per path, same checks and verdicts
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="fhs_stat_single_v1235_test"
# meta:type="test"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="Owner 2026-10-09 (latency, narrow): the FHS audit used three stat forks per path (about a third of nftban status --json on Ubuntu 26.04). nftban_fhs_get_attrs reads perms, owner and group with one stat and sets the caller's variables. Proves EQUIVALENCE, not speed, including the failure paths (owner review: a read from a here-string hides the getter's failure): the check and render functions are run as shipped and as the ORIGINAL three-getter code (rebuilt from the shipped bodies by replacing only the attrs call), under the production shell options (set -Eeuo pipefail; check via || true as nftban_fhs_check_all does), with a fake stat in eight modes (real, combined format rejected, every stat failing, empty output, owner lookup failing, path vanishing mid-check, a '|' inside owner/group names); NFTBAN_FHS_STATUS, NFTBAN_FHS_ACTUAL, render output and render exit status must be identical in every mode. Falsifiers: the first version of this change (here-string read of a printed 'perms|owner|group') must differ from the original in at least one mode, and an owner/group swap must change the verdicts. Hermetic: temp dirs; owner/group fixtures need root."
# meta:input="None"
# meta:output="PASS/FAIL per arm; exit 1 on any failure"
# meta:depends="bash,stat"
# meta:inventory.files="cli/lib/nftban/core/nftban_report_fhs.sh"
# meta:inventory.binaries="bash,stat,chown,chmod"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="fhs_stat_single_v1235_test"
# meta:ta.owner="health"
# meta:ta.module="fhs"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
F="$REPO/cli/lib/nftban/core/nftban_report_fhs.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
chmod 755 "$W"
ROOT=0; [[ $(id -u) -eq 0 ]] && ROOT=1

# Fixture: varied modes; owners/groups vary when root (nobody / a numeric id).
mkfix() {
    mkdir -p "$1/a" "$1/b" "$1/c" "$1/d" "$1/real"
    chmod 750 "$1/a"; chmod 2770 "$1/b"; chmod 700 "$1/c"; chmod 755 "$1/d"
    ln -s "$1/real" "$1/link"; : > "$1/file"
    if [[ $ROOT -eq 1 ]]; then chown nobody "$1/b" 2>/dev/null; chown 12345:23456 "$1/c" 2>/dev/null; fi
    return 0
}
mkfix "$W/base"
ME_U=$(stat -c %U "$W/base/a"); ME_G=$(stat -c %G "$W/base/a")
NAMES=(a b c d link file missing)
declare -A EXP=(
    [a]="750|$ME_U|$ME_G|ok"            [d]="0750|$ME_U|$ME_G|perms"
    [b]="2770|root|$ME_G|owner-or-ok"   [c]="700|$ME_U|nftban|group/owner"
    [link]="755|$ME_U|$ME_G|symlink"    [file]="644|$ME_U|$ME_G|not-dir"
    [missing]="755|root|root|missing"
)

# shellcheck source=/dev/null
source "$F" >/dev/null 2>&1 || { echo "[FAIL] cannot source $F"; exit 1; }
set +eu +o pipefail; IFS=$' \t\n'
declare -F nftban_fhs_get_attrs >/dev/null || { echo "[FAIL] nftban_fhs_get_attrs missing"; exit 1; }

echo "=== attrs equal the three original getters (real stat) ==="
for n in a b c d link file; do
    p="$W/base/$n"
    want="$(nftban_fhs_get_perms "$p")|$(nftban_fhs_get_owner "$p")|$(nftban_fhs_get_group "$p")"
    nftban_fhs_get_attrs "$p" ap ao ag; rc=$?
    [[ $rc -eq 0 && "$ap|$ao|$ag" == "$want" ]] && ok "$n: $want" || no "$n: attrs rc=$rc '$ap|$ao|$ag' != getters '$want'"
done
ap=x; ao=x; ag=x
# shellcheck disable=SC2218  # defined by the sourced library; the later definition is the falsifier
nftban_fhs_get_attrs "$W/base/missing" ap ao ag; rc=$?
[[ $rc -ne 0 && -z "$ap$ao$ag" ]] && ok "missing path: non-zero, variables emptied (as the getters)" \
    || no "missing path: rc=$rc vars='$ap|$ao|$ag'"

# ---------------------------------------------------------------------------
# Three implementations of the same two functions, differing ONLY in how the
# attributes are read: new (shipped), orig (the three getter assignments that
# the change replaced) and prev (the first version of this change, f8e34dfd).
# ---------------------------------------------------------------------------
CALL='nftban_fhs_get_attrs "$path" act_perms act_owner act_group'
ORIG_REPL='act_perms="$(nftban_fhs_get_perms "$path")"; act_owner="$(nftban_fhs_get_owner "$path")"; act_group="$(nftban_fhs_get_group "$path")"'
PREV_REPL="IFS='|' read -r act_perms act_owner act_group <<< \"\$(_prev_attrs \"\$path\")\""
NEW_DEFS="$(declare -f nftban_fhs_check_directory nftban_fhs_render_table)"
_prev_attrs() {  # f8e34dfd, verbatim
    local path="$1" out
    [[ ! -e "$path" ]] && return 1
    if out=$(stat -c "%a|%U|%G" "$path" 2>/dev/null); then
        printf '%s\n' "$out"
    else
        printf '%s|%s|%s\n' "$(nftban_fhs_get_perms "$path")" "$(nftban_fhs_get_owner "$path")" "$(nftban_fhs_get_group "$path")"
    fi
}
calls=$(grep -cF "$CALL" <<< "$NEW_DEFS")
[[ "$calls" -eq 3 ]] && ok "shipped check/render read attributes at exactly 3 sites (rebuild of the original is complete)" \
    || no "expected 3 attrs call sites in check/render, found $calls (the orig/prev rebuild would be partial)"
defs_for() {
    case "$1" in
        new)  printf '%s\n' "$NEW_DEFS" ;;
        orig) printf '%s\n' "${NEW_DEFS//"$CALL"/"$ORIG_REPL"}" ;;
        prev) printf '%s\n' "${NEW_DEFS//"$CALL"/"$PREV_REPL"}" ;;
    esac
}

# Fake stat (shadows the binary inside the arm). FAKE selects the failure mode.
stat() {
    local fmt="${2:-}" p="${*: -1}"
    case "$FAKE" in
        real)          command stat "$@" ;;
        combined_fail) [[ "$1" == "-c" && ( "$fmt" == *$'\n'* || "$fmt" == *"|"* ) ]] && return 1; command stat "$@" ;;
        all_fail)      return 1 ;;
        empty)         return 0 ;;
        owner_fail)    [[ "$fmt" == *%U* || "$fmt" == *%Su* ]] && return 1; command stat "$@" ;;
        vanish)        [[ "$p" == "$FAKE_ROOT/a" ]] && rmdir "$p" 2>/dev/null; command stat "$@" ;;
        pipe_names)    if [[ "$1" == "-c" ]]; then fmt="${fmt//%U/own|er}"; command stat -c "${fmt//%G/gr|oup}" "$p"
                       else command stat "$@"; fi ;;
    esac
}
MODES=(real combined_fail all_fail empty owner_fail vanish pipe_names)

# shellcheck disable=SC2034  # NFTBAN_FHS_* are read by the sourced check/render functions
run_arm() {  # $1 = new|orig|prev, $2 = mode -> check + render results, paths normalised
    local D; D="$W/run_${1}_$2"; rm -rf "$D" "$D.state" "$D.render"; mkfix "$D"
    (
        eval "$(defs_for "$1")"
        FAKE="$2"; FAKE_ROOT="$D"
        declare -gA NFTBAN_FHS_DIRECTORIES=() NFTBAN_FHS_STATUS=() NFTBAN_FHS_ACTUAL=()
        local n rc
        for n in "${NAMES[@]}"; do NFTBAN_FHS_DIRECTORIES["$D/$n"]="${EXP[$n]}"; done
        # Check as nftban_fhs_check_all runs it (|| true), under the CLI's shell options.
        ( set -Eeuo pipefail
          for n in "${NAMES[@]}"; do nftban_fhs_check_directory "$D/$n" >/dev/null 2>&1 || true; done
          declare -p NFTBAN_FHS_STATUS NFTBAN_FHS_ACTUAL | sed 's/^declare -A /declare -gA /' > "$D.state" )
        # shellcheck source=/dev/null
        source "$D.state"
        for n in "${NAMES[@]}"; do printf 'check %s=%s %s\n' "$n" "${NFTBAN_FHS_STATUS[$D/$n]:-}" "${NFTBAN_FHS_ACTUAL[$D/$n]:-}"; done
        # Render as nftban_fhs_report_status runs it: plain statement, errexit live.
        NFTBAN_FHS_OUTPUT_FORMAT=csv
        ( set -Eeuo pipefail; nftban_fhs_render_table ) > "$D.render" 2>&1; rc=$?
        printf 'render rc=%s\n' "$rc"; cat "$D.render"
    ) | sed "s|$D|<D>|g"
}

echo "=== shipped vs original under each stat mode (check verdicts, ACTUAL, render output and exit status) ==="
prev_differs=""
for m in "${MODES[@]}"; do
    new=$(run_arm new "$m"); orig=$(run_arm orig "$m"); prev=$(run_arm prev "$m")
    if [[ -n "$new" && "$new" == "$orig" ]]; then
        ok "$m: identical to the original ($(grep -o 'render rc=[0-9]*' <<< "$new"))"
    else
        no "$m: differs from the original"; diff <(echo "$orig") <(echo "$new") | sed 's/^/        /'
    fi
    [[ "$prev" != "$orig" ]] && prev_differs+=" $m"
done
real_new=$(run_arm new real)
grep -q "=OK " <<< "$real_new" && grep -q "=ERROR:" <<< "$real_new" \
    && grep -q "=MISSING" <<< "$real_new" && grep -q "=NOT_DIR" <<< "$real_new" \
    && ok "fixture covers OK, ERROR, MISSING and NOT_DIR" || no "fixture does not cover every verdict class"
grep -q "render rc=[1-9]" <<< "$(run_arm orig all_fail)" \
    && ok "failure mode is exercised: the original render stops (non-zero) when every stat fails" \
    || no "all_fail did not make the original render fail — the failure path is not exercised"

echo "=== falsifiers ==="
[[ -n "$prev_differs" ]] && ok "first version (here-string read) differs from the original in:$prev_differs" \
    || no "the here-string version matched the original in every mode — failure-path arms do not discriminate"
nftban_fhs_get_attrs() { local -n _p="$2" _o="$3" _g="$4"; _p=$(nftban_fhs_get_perms "$1"); _g=$(nftban_fhs_get_owner "$1"); _o=$(nftban_fhs_get_group "$1"); }
NEW_DEFS="$(declare -f nftban_fhs_check_directory nftban_fhs_render_table)"
bad=$(run_arm new real); good=$(run_arm orig real)
if [[ $ROOT -eq 1 || "$ME_U" != "$ME_G" ]]; then
    [[ "$bad" != "$good" ]] && ok "swapped owner/group changes the result (comparison discriminates)" \
        || no "swapped owner/group gave identical results — comparison is vacuous"
else
    echo "  [NOT_EXECUTED] owner/group swap: user and group names are equal here ($ME_U); needs root or distinct names"
fi

echo ""
echo "=== fhs_stat_single_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
