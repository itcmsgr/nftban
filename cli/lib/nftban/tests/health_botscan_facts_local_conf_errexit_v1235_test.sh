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
# meta:description="BUG-HEALTH-BOTSCAN-FACTS-ERREXIT-ON-LOCAL-CONF-WITHOUT-ACTION-MODE (v1.235 H1). Production (dns4, v1.234.0): a conf.d/botscan/main.conf.local holding only BOTSCAN_404_TRACKING=false made `lm=$(grep -m1 '^BOTSCAN_ACTION_MODE=' ... | cut | tr)` fail (grep no-match under pipefail), errexit killed the process substitution _nftban_health_render_botscan reads the facts from, and `nftban health` printed BotScan DISABLED with empty fields while BotScan was enabled. Drives the REAL _nftban_health_botscan_facts and _nftban_health_render_botscan, sourced from the subject tree, under the dispatcher's own strict mode (lib/strict.sh: set -Eeuo pipefail, IFS=$'\\n\\t', ERR trap) and its `main || exit` wrapper. Arms: L1 .local with only BOTSCAN_404_TRACKING=false; L2 .local setting the mode but not BOTSCAN_ENABLED; L3 .local overriding both (positive control: the override still wins); J1 malformed runstate.json; J2 malformed botscan_consumer_status.json. Each asserts the full 9-field facts line and that the renderer does not claim DISABLED. Set H1_SUBJECT_ROOT to an older tree (e.g. e79a1173): L1, L2 and J1/J2 must FAIL there."
# meta:inventory.files="health_botscan_facts_local_conf_errexit_v1235_test.sh"
# meta:inventory.binaries="bash,grep,cut,tr,jq,mktemp"
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
# module, and calls the renderer directly. The facts line is captured through the
# same `IFS='|' read ... < <(_nftban_health_botscan_facts)` shape both callers use.
run_case(){ # <case dir> -> writes facts/render/err files in the case dir
    local d="$1"
    env -i PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d" \
        NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$d/etc" NFTBAN_DATA_DIR="$d/var" \
        NFTBAN_LOG_DIR="$d/log" NFTBAN_ENABLE_ERROR_LOGGING=0 HMOD="$HMOD" OUT="$d" \
        bash -c '
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/strict.sh"
IFS=$'"'"'\n\t'"'"'
# shellcheck source=/dev/null
source "$HMOD"
main(){
    local enabled mode timer hs last bans spool handoff stale
    IFS="|" read -r enabled mode timer hs last bans spool handoff stale < <(_nftban_health_botscan_facts)
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$enabled" "$mode" "$timer" "$hs" "$last" "$bans" "$spool" "$handoff" "$stale" > "$OUT/facts"
    _nftban_health_render_botscan > "$OUT/render"
}
main "$@" || exit $?
' >"$d/stdout" 2>"$d/err"
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
        no "$arm facts line wrong" "rc=$rc fields=${#f[@]} line='${line}' stderr=$(head -c 300 "$d/err" | tr '\n' ' ')"
    fi
    local r; r="$(cat "$d/render" 2>/dev/null || true)"
    if [[ "$3" == "true" ]]; then
        if [[ -n "$r" && "$r" != *"DISABLED (not scanning"* ]]; then
            ok "$arm renderer does not claim DISABLED for an enabled scanner"
        else
            no "$arm renderer claims DISABLED (or rendered nothing) for an enabled scanner"
        fi
    fi
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
