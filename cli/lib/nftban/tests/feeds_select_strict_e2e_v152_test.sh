#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.152 BUG-FEEDS-SELECT-NONFUNCTIONAL: strict-mode IFS regression
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="feeds_select_strict_e2e_v152_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks the v1.152 fix for BUG-FEEDS-SELECT-NONFUNCTIONAL under the EXACT runtime condition the prior stub (cli_feeds_select_input_contract_test.sh) skipped: strict.sh's IFS=\$'\\n\\t' (no space). Proves (a) the bug condition — a bare 'read -ra <<<' does NOT split space/comma input under that IFS; (b) the fix mechanism — 'IFS=\$' \\t\\n' read -ra' splits correctly; (c) the SHIPPED cmd_feeds.sh parse line carries the IFS fix; (d) the real parse fixture (feed_array 1..14, _v142_cat_re) enables the correct feed SET for single/multi-space/comma/mixed/range/category/empty input. Real-function menu->parse flow was separately proven on lab4 (live trace); this is the always-runnable regression lock. Hermetic: no host/nft/IPC/root."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sort,paste"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh,cli/lib/nftban/lib/strict.sh"
# meta:inventory.binaries="bash,grep,sort,paste"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CMD_FEEDS="$REPO_ROOT/cli/lib/nftban/cli/cmd_feeds.sh"
STRICT="$REPO_ROOT/cli/lib/nftban/lib/strict.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== strict.sh really sets a space-free IFS (the root condition) ==="
if grep -qE "^IFS=\\\$'\\\\n\\\\t'" "$STRICT"; then ok "strict.sh sets IFS=\$'\\\\n\\\\t' (no space) — sourced by the whole CLI"; \
else no "expected strict.sh IFS=\$'\\n\\t'" "$(grep -nE '^IFS=' "$STRICT" | head -1)"; fi

echo "=== bug condition vs fix mechanism, under strict IFS ==="
( IFS=$'\n\t'; read -ra a <<< "4 12 11 10 3"; [[ "${#a[@]}" -eq 1 ]] ) \
  && ok "bug condition reproduced: bare 'read -ra' under IFS=\$'\\\\n\\\\t' → 1 token" || no "bug condition not reproduced"
( IFS=$'\n\t'; IFS=$' \t\n' read -ra a <<< "4 12 11 10 3"; [[ "${#a[@]}" -eq 5 ]] ) \
  && ok "fix mechanism: 'IFS=\$' \\\\t\\\\n' read -ra' → 5 tokens despite contaminated outer IFS" || no "fix mechanism failed"

echo "=== the SHIPPED parse line carries the IFS fix (ties test to real code) ==="
if grep -qE "IFS=\\\$' \\\\t\\\\n' read -ra parts <<< \"\\\$\{selection//,/ \}\"" "$CMD_FEEDS"; then \
  ok "cmd_feeds.sh parse uses 'IFS=\$' \\\\t\\\\n' read -ra parts'"; \
else no "shipped parse line missing the IFS fix" "$(grep -nE 'read -ra parts' "$CMD_FEEDS" | head -1)"; fi
grep -qE "^[[:space:]]*read -ra parts <<<" "$CMD_FEEDS" && no "an UNFIXED bare 'read -ra parts' still present" || ok "no unfixed bare 'read -ra parts' remains"

# ---- parse fixture: mirrors cmd_feeds.sh selection-processing under strict IFS ----
# feed_array 1..14 = FEED01..FEED14; category 'test' = all; same per-part branches.
_v142_cat_re='^(anonymity|email|protection|ssh|web|test)$'
declare -a feed_array=(); for i in $(seq -w 1 14); do feed_array[10#$i]="FEED$i"; done
cat_feeds_for() { [[ "$1" == "test" ]] && { local j; for j in $(seq -w 1 14); do printf 'FEED%s\n' "$j"; done; }; }

parse() { # mirrors the shipped selection->feeds_to_enable logic; echoes sorted-unique csv
    local selection="$1" part start end i feed
    local -a feeds_to_enable=() parts=()
    if [[ "$selection" == "all" ]]; then
        feeds_to_enable=("${feed_array[@]}")
    elif [[ "$selection" =~ $_v142_cat_re ]]; then
        while IFS= read -r feed; do [[ -n "$feed" ]] && feeds_to_enable+=("$feed"); done < <(cat_feeds_for "$selection")
    else
        IFS=$' \t\n' read -ra parts <<< "${selection//,/ }"   # the shipped fix
        for part in "${parts[@]}"; do
            if [[ "$part" =~ $_v142_cat_re ]]; then
                while IFS= read -r feed; do [[ -n "$feed" ]] && feeds_to_enable+=("$feed"); done < <(cat_feeds_for "$part")
            elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
                for ((i=start; i<=end; i++)); do [[ -n "${feed_array[i]:-}" ]] && feeds_to_enable+=("${feed_array[i]}"); done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                [[ -n "${feed_array[10#$part]:-}" ]] && feeds_to_enable+=("${feed_array[10#$part]}")
            fi
        done
    fi
    ((${#feeds_to_enable[@]})) && printf '%s\n' "${feeds_to_enable[@]}" | sort -u | paste -sd, -
}

echo "=== parse fixture under strict IFS (the regression the stub missed) ==="
[[ "$(parse '3')" == "FEED03" ]]                                     && ok "single '3' → FEED03" || no "single" "$(parse '3')"
[[ "$(parse '4 12 11 10 3')" == "FEED03,FEED04,FEED10,FEED11,FEED12" ]] && ok "multi-space '4 12 11 10 3' → 5 feeds" || no "multi-space" "$(parse '4 12 11 10 3')"
[[ "$(parse '14,3')" == "FEED03,FEED14" ]]                           && ok "comma '14,3' → 2 feeds" || no "comma" "$(parse '14,3')"
[[ "$(parse '1, 3, 6')" == "FEED01,FEED03,FEED06" ]]                 && ok "mixed '1, 3, 6' → 3 feeds" || no "mixed" "$(parse '1, 3, 6')"
[[ "$(parse '1-3')" == "FEED01,FEED02,FEED03" ]]                     && ok "range '1-3' → 3 feeds" || no "range" "$(parse '1-3')"
[[ "$(parse 'test')" == "FEED01,FEED02,FEED03,FEED04,FEED05,FEED06,FEED07,FEED08,FEED09,FEED10,FEED11,FEED12,FEED13,FEED14" ]] \
    && ok "category 'test' → all 14" || no "category" "$(parse 'test')"
[[ "$(parse '3 99 4')" == "FEED03,FEED04" ]]                         && ok "'3 99 4' → out-of-range 99 ignored" || no "oob" "$(parse '3 99 4')"
[[ -z "$(parse '')" ]]                                               && ok "empty → no feeds" || no "empty" "$(parse '')"

echo ""
echo "================================================================"
echo "feeds_select_strict_e2e_v152: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
