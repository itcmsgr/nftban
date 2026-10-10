#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - BotScan pattern migration: unedited old shipped definitions
# are upgraded silently; only real edits are reported; DEB status lists migrated files
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_pattern_migration_legacy_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BUG-BOTSCAN-PATTERN-MIGRATION-NOT-APPLIED-DEFINITIONS-SILENT + BUG-BOTSCAN-STATUS-MISSES-DEB-MIGRATED-PATTERN-FILES (v1.235). The v1.234 migration compared a legacy record only with the v1.234 default, so every definition v1.234 itself changed (url-* -> distinct-*, regex hardening) was reported as an operator edit ('82 edited definition(s) NOT applied' on every rollout host; legacy files untouched since install), and the report printed the LEGACY line under 'differs from the v1.234 default (X)'. The DEB status glob missed <cat>.patterns.nftban-saved.migrated-v1234. Drives the REAL nftban_botscan_migrate_legacy_patterns with the shipped v1.234 rules and the shipped data/botscan_legacy_shipped.list. Arms: L1 a pristine legacy file built from released definitions that differ from v1.234 -> 0 NOT APPLIED, all counted as upgraded, no override.local entry; L2 a truly edited definition (threshold) is still reported NOT APPLIED and the v1.234 definition is loaded; L3 a state-only edit of a pristine definition keeps the decision in override.local and is not 'NOT APPLIED'; L4 the NOT APPLIED line labels the operator's line and the v1.234 default separately; L5 without the records file the report says so (visible fallback); M1 nftban_botscan_pattern_sidecars all lists the DEB and RPM .migrated-v1234 names; R1 every records line parses as name|pattern|type|thr|win|ban|enabled. Set PMIG_SUBJECT_ROOT to an older tree (e.g. e79a1173): L1, L4 and M1 must FAIL there."
# meta:inventory.files="botscan_pattern_migration_legacy_v1235_test.sh"
# meta:inventory.binaries="bash,awk,grep,cp,mktemp"
# meta:inventory.env_vars="PMIG_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_pattern_migration_legacy_v1235_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-patterns"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SUBJECT_ROOT="${PMIG_SUBJECT_ROOT:-$REPO_ROOT}"
SUBJ_LIB="$SUBJECT_ROOT/cli/lib/nftban"
SHIP="$REPO_ROOT/cli/lib/nftban/data"
REC="$SHIP/botscan_legacy_shipped.list"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: BotScan legacy pattern migration ==="
[[ -r "$SUBJ_LIB/core/nftban_botscan.sh" && -r "$REC" ]] || { echo "  NOT_EXECUTED: module or records file missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
compgen -G "$SHIP/botscan_*.patterns" >/dev/null || { echo "  NOT_EXECUTED: shipped rules missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/ship" "$W/ship_norec"
cp "$SHIP"/botscan_*.patterns "$W/ship/"; cp "$REC" "$W/ship/"
cp "$SHIP"/botscan_*.patterns "$W/ship_norec/"

# run_mod <operator dir> <shipped dir> <data dir> <commands>
run_mod(){
    bash -c '
        export LC_ALL=C NFTBAN_LIB_DIR="$1" BOTSCAN_PATTERNS_DIR="$2" BOTSCAN_SHIPPED_PATTERNS_DIR="$3" \
               NFTBAN_DATA_DIR="$4" NFTBAN_CONFIG_DIR="$5" BOTSCAN_CUSTOM_PATTERNS_TEMPLATE=/nonexistent
        source "$1/core/nftban_botscan.sh" >/dev/null 2>&1
        set +e
        eval "$6"
    ' _ "$SUBJ_LIB" "$1" "$2" "$3" "$W/noetc" "$4"
}
# def <shipped file> <name> -> "pattern|type|thr|win|ban|enabled" from a pattern file record
shipped_def(){ awk -F'|' -v n="$2" '$1==n{ printf "%s", $0; exit }' "$1"; }

# ---- R1: records file shape --------------------------------------------------------
bad_lines="$(awk -F'|' '!/^#/ && (NF<7 || $(NF)!~/^(true|false)$/ || $(NF-1)!~/^[0-9]+$/)' "$REC")"
[[ -z "$bad_lines" ]] && ok "R1 every records line is name|pattern|type|thr|win|ban|enabled" || no "R1 malformed records" "$bad_lines"

# ---- build a PRISTINE legacy exploit file: released definitions that differ from v1.234
exp="$W/ship/botscan_exploit.patterns"
: > "$W/pristine.list"
while IFS= read -r l; do
    [[ -z "$l" || "$l" == \#* ]] && continue
    nm="${l%%|*}"
    cur="$(shipped_def "$exp" "$nm")"; [[ -n "$cur" ]] || continue          # exploit names only
    old_def="${l%|*}"                                                          # without enabled
    cur_def="$(printf '%s' "$cur" | awk -F'|' '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')"
    [[ "$old_def" != "$cur_def" ]] || continue
    grep -qx -- "$nm" "$W/pristine.list" 2>/dev/null && continue               # one record per name
    echo "$nm" >> "$W/pristine.list"
    printf '%s|released definition\n' "$l" >> "$W/pristine.patterns"
    [[ "$(wc -l < "$W/pristine.list")" -ge 5 ]] && break
done < "$REC"
npr="$(wc -l < "$W/pristine.list")"
if (( npr == 0 )); then echo "  NOT_EXECUTED: no released exploit definition differs from v1.234"; echo "RESULT: NOT_EXECUTED"; exit 3; fi

# ---- L1 pristine legacy file (DEB shape) -------------------------------------------
od="$W/l1"; mkdir -p "$od" "$W/d1"
cp "$W/pristine.patterns" "$od/exploit.patterns.nftban-saved"
out="$(run_mod "$od" "$W/ship" "$W/d1" 'nftban_botscan_migrate_legacy_patterns' 2>&1 || true)"
rep="$W/d1/botscan/pattern-migration.report"
na="$(grep -c 'NOT APPLIED' "$rep" 2>/dev/null || true)"
up="$(grep -c '  upgraded ' "$rep" 2>/dev/null || true)"
if [[ "${na:-0}" == 0 && "${up:-0}" == "$npr" ]]; then
    ok "L1 $npr unedited released definitions -> 0 NOT APPLIED, $up upgraded"
else
    no "L1 unedited released definitions reported as edits" "NOT_APPLIED=${na:-0} upgraded=${up:-0} of $npr; summary: ${out:0:200}"
fi
[[ ! -s "$od/override.local" ]] && ok "L1 no override.local entry for unedited records" || no "L1 override.local written for unedited records" "$(head -2 "$od/override.local")"
[[ "$out" == *"0 edited definition(s) NOT applied"* ]] && ok "L1 summary line: 0 edited definition(s) NOT applied" || no "L1 summary line wrong" "${out:0:200}"

# ---- L2/L4 a true edit (threshold changed) ----------------------------------------
first="$(head -1 "$W/pristine.list")"
rec="$(grep -m1 "^${first}|" "$W/pristine.patterns")"
IFS='|' read -r n p t thr win ban en desc <<<"$rec"
od="$W/l2"; mkdir -p "$od" "$W/d2"
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$n" "$p" "$t" "$((thr + 7))" "$win" "$ban" "$en" "$desc" > "$od/exploit.patterns.nftban-saved"
run_mod "$od" "$W/ship" "$W/d2" 'nftban_botscan_migrate_legacy_patterns' >/dev/null 2>&1 || true
rep="$W/d2/botscan/pattern-migration.report"
grep -q "NOT APPLIED ${n}" "$rep" 2>/dev/null && ok "L2 a truly edited definition (threshold) is still reported NOT APPLIED" || no "L2 real edit not reported"
newdef="$(shipped_def "$exp" "$n" | awk -F'|' '{print $2"|"$3"|"$4"|"$5"|"$6}')"
line="$(grep -m1 "NOT APPLIED ${n}" "$rep" 2>/dev/null || true)"
if [[ "$line" == *"your edited definition (${p}|${t}|$((thr + 7))|"* && "$line" == *"v1.234 default (${newdef})"* ]]; then
    ok "L4 the report labels the operator's line and the v1.234 default separately"
else
    no "L4 report labels" "${line:0:220}"
fi

# ---- L3 state-only edit of a pristine definition ------------------------------------
flip=false; [[ "$en" == false ]] && flip=true
od="$W/l3"; mkdir -p "$od" "$W/d3"
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$n" "$p" "$t" "$thr" "$win" "$ban" "$flip" "$desc" > "$od/exploit.patterns.nftban-saved"
run_mod "$od" "$W/ship" "$W/d3" 'nftban_botscan_migrate_legacy_patterns' >/dev/null 2>&1 || true
rep="$W/d3/botscan/pattern-migration.report"
cur_en="$(shipped_def "$exp" "$n" | awk -F'|' '{print $7}')"
if [[ "$flip" != "$cur_en" ]]; then
    grep -q "^${n}|${flip}|" "$od/override.local" 2>/dev/null && ok "L3 the operator's enable/disable decision is kept in override.local" || no "L3 state decision lost"
else
    ok "L3 (state flip equals the v1.234 default: nothing to keep)"
fi
! grep -q "NOT APPLIED ${n}" "$rep" 2>/dev/null && ok "L3 a state-only edit is not reported as a definition edit" || no "L3 state-only edit reported NOT APPLIED"

# ---- L5 records file missing: visible fallback --------------------------------------
od="$W/l5"; mkdir -p "$od" "$W/d5"
cp "$W/pristine.patterns" "$od/exploit.patterns.nftban-saved"
run_mod "$od" "$W/ship_norec" "$W/d5" 'nftban_botscan_migrate_legacy_patterns' >/dev/null 2>&1 || true
grep -q 'WARNING: .*botscan_legacy_shipped.list missing' "$W/d5/botscan/pattern-migration.report" 2>/dev/null \
    && ok "L5 without the records file the report says so" || no "L5 missing records file not disclosed"

# ---- M1 status lists DEB/RPM migrated files ---------------------------------------------
od="$W/m1"; mkdir -p "$od"
: > "$od/exploit.patterns.nftban-saved.migrated-v1234"; : > "$od/scanner.patterns.rpmsave.migrated-v1234"; : > "$od/badbots.patterns.migrated-v1234"
lst="$(run_mod "$od" "$W/ship" "$W/d1" 'nftban_botscan_pattern_sidecars all' 2>/dev/null || true)"
if [[ "$lst" == *"exploit.patterns.nftban-saved.migrated-v1234"* && "$lst" == *"scanner.patterns.rpmsave.migrated-v1234"* && "$lst" == *"badbots.patterns.migrated-v1234"* ]]; then
    ok "M1 status lists DEB, RPM and file-drop .migrated-v1234 files"
else
    no "M1 migrated files missing from status" "$(tr '\n' ' ' <<<"$lst")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
