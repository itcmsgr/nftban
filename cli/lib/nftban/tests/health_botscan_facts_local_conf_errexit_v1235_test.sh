#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - BotScan health facts survive a main.conf.local without the key
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="health_botscan_facts_local_conf_errexit_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BUG-HEALTH-BOTSCAN-FACTS-ERREXIT-ON-LOCAL-CONF-WITHOUT-ACTION-MODE (v1.235 H1). Production (dns4, v1.234.0): a conf.d/botscan/main.conf.local holding only BOTSCAN_404_TRACKING=false made `lm=$(grep -m1 '^BOTSCAN_ACTION_MODE=' ... | cut | tr)` fail (grep no-match under pipefail), errexit killed the process substitution _nftban_health_render_botscan reads the facts from, and `nftban health` printed BotScan DISABLED with empty fields while BotScan was enabled. Drives the REAL _nftban_health_botscan_facts and _nftban_health_render_botscan, sourced from the subject tree, under the dispatcher's own strict mode (lib/strict.sh: set -Eeuo pipefail, IFS=$'\\n\\t', ERR trap) and its `main || exit` wrapper. Also drives nftban_health_check_botscan. Arms: L1 .local with only BOTSCAN_404_TRACKING=false; L2 .local setting the mode but not BOTSCAN_ENABLED; L3 .local overriding both (positive control: the override still wins); J1 malformed runstate.json; J2 malformed botscan_consumer_status.json; F1 a collector that exits 1; F2 a collector emitting 5 fields. L/J assert the full 9-field facts line and that neither surface claims DISABLED; F assert State UNKNOWN (fact collection failed), the EVALUATION INCOMPLETE disclosure, NFTBAN_HEALTH_INCOMPLETE=botscan and a WARNING check verdict. Every arm asserts no ERR-trap banner and no empty key= field. Set H1_SUBJECT_ROOT to an older tree (e.g. e79a1173): L1, L2, J1, J2, F1 and F2 must FAIL there."
# meta:inventory.files="health_botscan_facts_local_conf_errexit_v1235_test.sh"
# meta:inventory.binaries="bash,grep,cut,tr,jq,mktemp,env"
# meta:inventory.env_vars="H1_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="health_botscan_facts_local_conf_errexit_v1235_test"
# meta:ta.owner="health"
# meta:ta.module="health-botscan"
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
ROOT="${H1_SUBJECT_ROOT:-$REPO}"
LIB="$ROOT/cli/lib/nftban"
HMOD="$LIB/core/nftban_health_checks_modules.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 H1: BotScan health facts vs a main.conf.local without the key ==="
[[ -f "$HMOD" && -f "$LIB/lib/strict.sh" ]] || { echo "  NOT_EXECUTED: subject files missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || HAVE_JQ=0

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
# Hermetic: no host timer state leaks in. "inactive" is the honest answer here.
printf '#!/bin/sh\nexit 3\n' > "$SB/bin/systemctl"; chmod 0755 "$SB/bin/systemctl"

# One sandbox per arm. main.conf mirrors the shipped default shape: enabled, mode both.
mk_case(){ # <name> -> prints the case dir
    local d="$SB/$1"
    mkdir -p "$d/etc/conf.d/botscan" "$d/var/botscan" "$d/var/botguard" "$d/log"
    printf 'BOTSCAN_ENABLED="true"\nBOTSCAN_ACTION_MODE="both"\nBOTSCAN_404_TRACKING=true\n' \
        > "$d/etc/conf.d/botscan/main.conf"
    printf '%s' "$d"
}

# The child reproduces the dispatcher's execution plane: cli/sbin/nftban runs
# `set -Eeuo pipefail` and `main "$@" || exit $?`; cmd_health.sh sources
# lib/strict.sh (errexit + pipefail + IFS=$'\n\t' + the ERR trap) and then this
# module, and calls the renderer directly. The diagnostics entrypoint
# nftban_health_check_botscan is driven too, with the globals nftban_health.sh
# declares (same names, same values). The facts line itself is captured through
# the `IFS='|' read ... < <(_nftban_health_botscan_facts)` shape v1.234.0 used.
# H1_STUB replaces the collector: fail = exits 1 with no output, short = 5 fields.
run_case(){ # <case dir> [stub]
    local d="$1"
    env -i PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d" \
        NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$d/etc" NFTBAN_DATA_DIR="$d/var" \
        NFTBAN_LOG_DIR="$d/log" NFTBAN_ENABLE_ERROR_LOGGING=0 HMOD="$HMOD" OUT="$d" \
        H1_STUB="${2:-}" \
        bash -c '
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/strict.sh"
IFS=$'"'"'\n\t'"'"'
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES
readonly HEALTH_OK=0 HEALTH_WARNING=1 HEALTH_ERROR=2
# shellcheck source=/dev/null
source "$HMOD"
case "$H1_STUB" in
    fail)  _nftban_health_botscan_facts(){ return 1; } ;;
    short) _nftban_health_botscan_facts(){ printf "%s\n" "true|both|active|OK_ALL|5s"; } ;;
esac
main(){
    local enabled mode timer hs last bans spool handoff stale st=0
    IFS="|" read -r enabled mode timer hs last bans spool handoff stale < <(_nftban_health_botscan_facts) || true
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$enabled" "$mode" "$timer" "$hs" "$last" "$bans" "$spool" "$handoff" "$stale" > "$OUT/facts"
    _nftban_health_render_botscan > "$OUT/render"
    nftban_health_check_botscan || st=$?
    printf "%s\n" "$st" > "$OUT/check_status"
    printf "%s\n" "${NFTBAN_HEALTH_ISSUES[botscan]:-}" > "$OUT/check_issue"
    printf "%s\n" "${NFTBAN_HEALTH_INCOMPLETE:-}" > "$OUT/incomplete"
}
main "$@" || exit $?
' >"$d/stdout" 2>"$d/err"
}

# Assertions common to every arm: the ERR-trap banner never appears, and no
# rendered `key=` is left empty.
common_asserts(){ # <arm> <case dir>
    local arm="$1" d="$2" empty
    if grep -q 'ERROR: Script failed' "$d/err" "$d/stdout" 2>/dev/null; then
        no "$arm ERR-trap banner printed" "$(grep -m1 'Command:' "$d/err" 2>/dev/null || true)"
    else
        ok "$arm no ERR-trap banner"
    fi
    empty="$(grep -nE '[a-z_]+=( |$)' "$d/render" 2>/dev/null || true)"
    if [[ -s "$d/render" && -z "$empty" ]]; then
        ok "$arm no empty key= field in the rendered block"
    else
        no "$arm empty key= field (or nothing rendered)" "${empty:0:200}"
    fi
}

# <arm> <case dir> <want enabled> <want mode> <want hs> <want handoff> <want stale>
check_case(){
    local arm="$1" d="$2" rc=0 line
    run_case "$d" || rc=$?
    line="$(cat "$d/facts" 2>/dev/null || true)"
    local -a f=()
    IFS='|' read -r -a f <<<"$line"
    if [[ "$rc" -eq 0 && "${#f[@]}" -eq 9 && "${f[0]}" == "$3" && "${f[1]}" == "$4" \
          && "${f[3]}" == "$5" && "${f[7]}" == "$6" && "${f[8]}" == "$7" ]]; then
        ok "$arm facts line complete: enabled=${f[0]} mode=${f[1]} hs=${f[3]} handoff=${f[7]} stale=${f[8]}"
    else
        no "$arm facts line wrong" "rc=$rc fields=${#f[@]} line='${line}'"
    fi
    local r issue; r="$(cat "$d/render" 2>/dev/null || true)"; issue="$(cat "$d/check_issue" 2>/dev/null || true)"
    if [[ "$3" == "true" ]]; then
        if [[ -n "$r" && "$r" != *"DISABLED (not scanning"* && "$issue" != *"(disabled)"* && -n "$issue" ]]; then
            ok "$arm neither renderer nor check claims DISABLED for an enabled scanner"
        else
            no "$arm DISABLED claimed (or nothing produced) for an enabled scanner" "issue='${issue}'"
        fi
    fi
    common_asserts "$arm" "$d"
}

# <arm> <case dir> <stub>: the collector fails or lies; the surfaces must say so.
check_failed_collection(){
    local arm="$1" d="$2" rc=0
    run_case "$d" "$3" || rc=$?
    local r st issue inc
    r="$(cat "$d/render" 2>/dev/null || true)"
    st="$(cat "$d/check_status" 2>/dev/null || true)"
    issue="$(cat "$d/check_issue" 2>/dev/null || true)"
    inc="$(cat "$d/incomplete" 2>/dev/null || true)"
    if [[ "$rc" -eq 0 && "$r" == *"State:"*"UNKNOWN (fact collection failed"* && "$r" != *DISABLED* ]]; then
        ok "$arm renderer: State UNKNOWN (fact collection failed), not DISABLED"
    else
        no "$arm renderer did not report UNKNOWN" "rc=$rc state='$(grep -m1 'State:' "$d/render" 2>/dev/null || true)'"
    fi
    if [[ "$r" == *"EVALUATION INCOMPLETE"* && " $inc " == *" botscan "* ]]; then
        ok "$arm evaluation disclosed INCOMPLETE (rendered + NFTBAN_HEALTH_INCOMPLETE=botscan)"
    else
        no "$arm incomplete evaluation not disclosed" "incomplete='${inc}'"
    fi
    if [[ "$st" == 1 && "$issue" == *"collection failed"* ]]; then
        ok "$arm check: WARNING, issue says collection failed"
    else
        no "$arm check verdict wrong" "status='${st}' issue='${issue}'"
    fi
    common_asserts "$arm" "$d"
}

# ---- L1 · the production trigger: .local holds only BOTSCAN_404_TRACKING=false --------
d="$(mk_case l1)"
printf 'BOTSCAN_404_TRACKING=false\n' > "$d/etc/conf.d/botscan/main.conf.local"
check_case L1 "$d" true both UNKNOWN UNKNOWN UNKNOWN

# ---- L2 · .local sets the mode but not BOTSCAN_ENABLED ----------------------------------
d="$(mk_case l2)"
printf 'BOTSCAN_ACTION_MODE="alert"\n' > "$d/etc/conf.d/botscan/main.conf.local"
check_case L2 "$d" true alert UNKNOWN UNKNOWN UNKNOWN

# ---- L3 · positive control: a .local that sets both keys still wins ---------------------
d="$(mk_case l3)"
printf 'BOTSCAN_ENABLED="false"\nBOTSCAN_ACTION_MODE="alert"\n' > "$d/etc/conf.d/botscan/main.conf.local"
check_case L3 "$d" false alert UNKNOWN UNKNOWN UNKNOWN
if grep -q 'DISABLED (not scanning' "$d/render" 2>/dev/null; then
    ok "L3 renderer reports DISABLED when the .local really disables it"
else
    no "L3 renderer did not report DISABLED for BOTSCAN_ENABLED=false"
fi

# ---- J1/J2 · malformed JSON must not abort the facts line either ------------------------
if [[ "$HAVE_JQ" -eq 1 ]]; then
    d="$(mk_case j1)"
    printf '{"health_state":"OK","last_run_ts":' > "$d/var/botscan/runstate.json"
    check_case J1 "$d" true both UNKNOWN UNKNOWN UNKNOWN
    d="$(mk_case j2)"
    printf '{"batch_handoff_errors":' > "$d/var/botguard/botscan_consumer_status.json"
    check_case J2 "$d" true both UNKNOWN UNKNOWN UNKNOWN
else
    echo "  - J1/J2 not run: jq missing (the facts layer skips both JSON reads without jq)"
fi

# ---- F1/F2 · a collector that fails, or emits a malformed line --------------------------
check_failed_collection F1 "$(mk_case f1)" fail
check_failed_collection F2 "$(mk_case f2)" short

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
