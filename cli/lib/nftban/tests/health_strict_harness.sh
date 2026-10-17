#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.235 - shared strict harness for the health-module BotScan tests
# =============================================================================
# meta:name="health_strict_harness"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Sourced by the BotScan health tests. Runs a REAL function of core/nftban_health_checks_modules.sh in a child that reproduces the dispatcher's execution plane (set -Eeuo pipefail, lib/strict.sh, IFS=$'\\n\\t', `main || exit`), the same plane health_botscan_facts_local_conf_errexit_v1235_test.sh proves faithful. Replaces the awk-extracted function bodies run under `set +e`, which hid the H1 errexit class (an aborted facts read rendered as DISABLED and still passed)."
# meta:inventory.files="health_strict_harness.sh"
# meta:inventory.binaries="bash,mktemp,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,HS_TIMER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
# Usage (from a test, after REPO is set):
#   source "$TEST_DIR/health_strict_harness.sh"; hs_init "$SB"
#   out=$(NFTBAN_CONFIG_DIR=... NFTBAN_DATA_DIR=... HS_TIMER=active hs_call _nftban_health_render_botscan)
#   hs_err_banner && no "ERR-trap banner" "$(hs_err_first)"
#   hs_call _hs_check_botscan   -> prints "rc|<NFTBAN_HEALTH_ISSUES[botscan]>"
#   hs_fn_source <fn>...         -> the REAL definitions (declare -f), for source-text scans
# HS_TIMER: active -> systemctl exits 0; anything else -> exits 3 (inactive).
# The child's stderr goes to $HS_ERR (overwritten per call). hs_call returns the
# child's exit status; under the dispatcher's plane a non-zero status is data.

HS_HMOD=""; HS_LIB=""; HS_DIR=""; HS_ERR=""
# The cheap-read BotScan facts + render chain (what the old awk range covered).
# shellcheck disable=SC2034  # read by the sourcing tests
HS_BOTSCAN_READERS=(_nftban_health_botscan_facts _nftban_health_botscan_stale_threshold
    _nftban_health_botscan_run_staleness _nftban_health_botscan_age_human
    _nftban_health_botscan_collect _nftban_health_render_botscan)

hs_init(){ # <sandbox dir>
    HS_LIB="$REPO/cli/lib/nftban"
    HS_HMOD="$HS_LIB/core/nftban_health_checks_modules.sh"
    HS_DIR="$1/hs"; HS_ERR="$HS_DIR/stderr"
    mkdir -p "$HS_DIR/bin" "$HS_DIR/log"
    # Hermetic: no host timer state leaks in.
    printf '#!/bin/sh\n[ "${HS_TIMER:-inactive}" = active ] && exit 0\nexit 3\n' > "$HS_DIR/bin/systemctl"
    chmod 0755 "$HS_DIR/bin/systemctl"
    [[ -f "$HS_HMOD" && -f "$HS_LIB/lib/strict.sh" ]]
}

hs_call(){ # <function> [args...]
    PATH="$HS_DIR/bin:$PATH" NFTBAN_LIB_DIR="$HS_LIB" NFTBAN_LOG_DIR="$HS_DIR/log" \
        NFTBAN_ENABLE_ERROR_LOGGING=0 HS_HMOD="$HS_HMOD" HS_TIMER="${HS_TIMER:-inactive}" \
        bash -c '
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/strict.sh"
IFS=$'"'"'\n\t'"'"'
# The globals nftban_health.sh declares (same names, same values).
declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES
readonly HEALTH_OK=0 HEALTH_WARNING=1 HEALTH_ERROR=2
# shellcheck source=/dev/null
source "$HS_HMOD"
_hs_check_botscan(){
    local st=0
    nftban_health_check_botscan >/dev/null || st=$?
    printf "%s|%s\n" "$st" "${NFTBAN_HEALTH_ISSUES[botscan]:-}"
}
main(){ "$@"; }
main "$@" || exit $?
' _ "$@" 2>"$HS_ERR"
}

hs_err_banner(){ grep -q 'ERROR: Script failed' "$HS_ERR" 2>/dev/null; }
hs_err_first(){ grep -m1 'Command:' "$HS_ERR" 2>/dev/null || true; }

hs_fn_source(){ # <function>... -> the definitions as the module defines them
    NFTBAN_LIB_DIR="$HS_LIB" NFTBAN_LOG_DIR="$HS_DIR/log" NFTBAN_ENABLE_ERROR_LOGGING=0 \
        HS_HMOD="$HS_HMOD" bash -c '
# shellcheck source=/dev/null
source "$HS_HMOD" >/dev/null 2>&1 || exit 2
declare -f "$@"
' _ "$@"
}
