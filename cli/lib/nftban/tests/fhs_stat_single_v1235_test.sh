#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - FHS audit: one stat per path, same checks and verdicts
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="fhs_stat_single_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="Owner 2026-10-09 (latency, narrow): the FHS audit used three stat forks per path (about a third of nftban status --json on Ubuntu 26.04). nftban_fhs_get_attrs reads perms|owner|group with one stat. Proves EQUIVALENCE, not speed: on a fixture of directories with differing modes, owners and groups (a symlink, setgid and a missing path included) the attrs equal the three original getters field by field; nftban_fhs_check_directory gives the SAME NFTBAN_FHS_STATUS and NFTBAN_FHS_ACTUAL with the new reader as with the original three getters (OK, perms/owner/group mismatches, MISSING, NOT_DIR); a non-GNU stat falls back to the original getters; a falsifier (owner and group swapped) changes the verdicts, so the comparison discriminates. Hermetic: temp dirs; owner/group fixtures need root and are reported NOT_EXECUTED otherwise."
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

# Fixture: varied modes; owners/groups vary when root (nobody / nogroup or a numeric id).
mkdir -p "$W/a" "$W/b" "$W/c" "$W/d" "$W/real"
chmod 750 "$W/a"; chmod 2770 "$W/b"; chmod 700 "$W/c"; chmod 755 "$W/d"
ln -s "$W/real" "$W/link"; : > "$W/file"
ROOT=0; [[ $(id -u) -eq 0 ]] && ROOT=1
if [[ $ROOT -eq 1 ]]; then
    chown nobody "$W/b" 2>/dev/null; chown 12345:23456 "$W/c" 2>/dev/null
fi
ME_U=$(stat -c %U "$W/a"); ME_G=$(stat -c %G "$W/a")

# shellcheck source=/dev/null
source "$F" >/dev/null 2>&1 || { echo "[FAIL] cannot source $F"; exit 1; }
set +eu +o pipefail; IFS=$' \t\n'
declare -F nftban_fhs_get_attrs >/dev/null || { echo "[FAIL] nftban_fhs_get_attrs missing"; exit 1; }

echo "=== attrs equal the three original getters ==="
for p in "$W/a" "$W/b" "$W/c" "$W/d" "$W/link" "$W/file"; do
    want="$(nftban_fhs_get_perms "$p")|$(nftban_fhs_get_owner "$p")|$(nftban_fhs_get_group "$p")"
    got="$(nftban_fhs_get_attrs "$p")"
    [[ "$got" == "$want" ]] && ok "${p#"$W"/}: $got" || no "${p#"$W"/}: attrs '$got' != getters '$want'"
done
nftban_fhs_get_attrs "$W/missing" >/dev/null 2>&1 && no "missing path returned success" || ok "missing path returns 1 (as the getters)"

# Fallback: a stat that rejects the combined GNU format falls back to the original getters.
stat() { if [[ "$1" == "-c" && "$2" == *"|"* ]]; then return 1; fi; command stat "$@"; }
want="$(nftban_fhs_get_perms "$W/a")|$(nftban_fhs_get_owner "$W/a")|$(nftban_fhs_get_group "$W/a")"
[[ "$(nftban_fhs_get_attrs "$W/a")" == "$want" ]] && ok "non-GNU stat: falls back to the original getters" \
    || no "fallback differs: '$(nftban_fhs_get_attrs "$W/a")' vs '$want'"
unset -f stat

echo "=== same verdicts as the original three-getter reader ==="
declare -A FIX=(
    ["$W/a"]="750|$ME_U|$ME_G|ok"
    ["$W/d"]="0750|$ME_U|$ME_G|perms-mismatch"
    ["$W/b"]="2770|root|$ME_G|owner-or-ok"
    ["$W/c"]="700|$ME_U|nftban|group/owner"
    ["$W/missing"]="755|root|root|missing"
    ["$W/file"]="644|$ME_U|$ME_G|not-dir"
)
# shellcheck disable=SC2034  # NFTBAN_FHS_* are read by nftban_fhs_check_directory (sourced library)
run_checks() {  # -> "path=STATUS ACTUAL" lines, sorted
    NFTBAN_FHS_DIRECTORIES=(); NFTBAN_FHS_STATUS=(); NFTBAN_FHS_ACTUAL=()
    local k; for k in "${!FIX[@]}"; do NFTBAN_FHS_DIRECTORIES["$k"]="${FIX[$k]}"; done
    for k in "${!FIX[@]}"; do nftban_fhs_check_directory "$k" >/dev/null 2>&1 || true; done
    for k in "${!FIX[@]}"; do printf '%s=%s %s\n' "${k#"$W"/}" "${NFTBAN_FHS_STATUS[$k]:-}" "${NFTBAN_FHS_ACTUAL[$k]:-}"; done | sort
}
new=$(run_checks)
eval "orig_attrs() $(declare -f nftban_fhs_get_attrs | tail -n +2)"
nftban_fhs_get_attrs() {  # the reader before this change: three getters
    printf '%s|%s|%s\n' "$(nftban_fhs_get_perms "$1")" "$(nftban_fhs_get_owner "$1")" "$(nftban_fhs_get_group "$1")"
}
old=$(run_checks)
if [[ "$new" == "$old" ]]; then ok "NFTBAN_FHS_STATUS + NFTBAN_FHS_ACTUAL identical (${#FIX[@]} paths)"; else no "verdicts differ"; diff <(echo "$old") <(echo "$new") | sed 's/^/        /'; fi
printf '%s\n' "$new" | sed 's/^/        /'
grep -q "=OK " <<<"$new" && grep -q "=ERROR:" <<<"$new" && grep -q "=MISSING" <<<"$new" && grep -q "=NOT_DIR" <<<"$new" \
    && ok "fixture covers OK, ERROR, MISSING and NOT_DIR" || no "fixture does not cover every verdict class"

echo "=== falsifier: a reader that swaps owner and group must change the verdicts ==="
nftban_fhs_get_attrs() { local p o g; IFS='|' read -r p o g <<< "$(orig_attrs "$1")"; printf '%s|%s|%s\n' "$p" "$g" "$o"; }
bad=$(run_checks)
if [[ $ROOT -eq 1 || "$ME_U" != "$ME_G" ]]; then
    [[ "$bad" != "$new" ]] && ok "swapped owner/group changes the result (comparison discriminates)" \
        || no "swapped owner/group gave identical verdicts — comparison is vacuous"
else
    echo "  [NOT_EXECUTED] falsifier: user and group names are equal here ($ME_U); needs root or distinct names"
fi

echo ""
echo "=== fhs_stat_single_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
