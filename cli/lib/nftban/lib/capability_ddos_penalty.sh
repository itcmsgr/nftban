#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="capability_ddos_penalty" meta:type="lib" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="B03 adapter: classify the DDoS penalty ladder from structural and observational evidence"
# meta:inventory.files="/var/lib/nftban/state/ddos_penalty_counters"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

[[ -n "${_NFTBAN_CAP_DDOS_PENALTY_LOADED:-}" ]] && return 0
_NFTBAN_CAP_DDOS_PENALTY_LOADED=1

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/capability.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/observability_counters.sh" 2>/dev/null || true

# =============================================================================
# B03 FIRST ADAPTER — DDoS penalty ladder
# =============================================================================
# This is the mechanism that produced BOTH capability errors during the
# v1.229.12 audit, so it is the right first proof of the model:
#
#   the sets, timeouts and consumers existed -> "looks configured"  (false healthy)
#   the sets were empty on 9/9 hosts         -> "producer missing"  (false broken)
#
# Structural evidence (does the path exist?) plus observational evidence (has it
# ever run, and did placement succeed?) together answer what neither can alone.
# =============================================================================

# nftban_capability_ddos_penalty
# Emits: <CAPABILITY> <detail>
nftban_capability_ddos_penalty() {
    local t4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local s10s="${DDOS_PENALTY_SET_LIMIT_10S:-ddos_limit_10s}"

    # --- structural: is the projection present and readable? ------------------
    # ⛔ an unreadable ruleset is UNKNOWN, never "absent".
    local reachable="unknown" consumer="unknown" observation="yes"
    local dump
    if dump=$(nft -a list table ${t4} 2>/dev/null); then
        if nftban_has_non_whitespace "$dump" 2>/dev/null || [[ -n "${dump//[[:space:]]/}" ]]; then
            if printf '%s' "$dump" | grep -q "set ${s10s}"; then reachable="yes"; else reachable="no"; fi
            if printf '%s' "$dump" | grep -qE "ip saddr @${s10s}"; then consumer="yes"; else consumer="no"; fi
        else
            observation="no"   # rc=0 with no content is not an empty ruleset
        fi
    else
        observation="no"
    fi

    # --- structural: is the producer implementation reachable? ----------------
    local producer="no"
    if declare -f nftban_ddos_penalty_scan >/dev/null 2>&1; then
        producer="yes"
    elif [[ -r "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_ddos_classic.sh" ]] \
         && grep -q "nftban_ddos_penalty_scan()" "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_ddos_classic.sh" 2>/dev/null; then
        producer="yes"
    fi

    # --- observational: has the producer actually run, and did it place? ------
    local runs cands hits att succ failed
    runs=$(nftban_obs_get ddos_penalty penalty_scan_runs 2>/dev/null || printf 'UNKNOWN')
    cands=$(nftban_obs_get ddos_penalty candidate_sources_seen 2>/dev/null || printf 'UNKNOWN')
    hits=$(nftban_obs_get ddos_penalty promotion_threshold_hits 2>/dev/null || printf 'UNKNOWN')
    att=$(nftban_obs_get ddos_penalty placement_attempts 2>/dev/null || printf 'UNKNOWN')
    succ=$(nftban_obs_get ddos_penalty placement_success 2>/dev/null || printf 'UNKNOWN')
    failed=$(nftban_obs_get ddos_penalty placement_failure 2>/dev/null || printf 'UNKNOWN')

    # Activity is proven ONLY by an authoritative placement success.
    # ⛔ UNKNOWN counters mean "never established" — they must not read as 0,
    # and they must not read as activity either.
    local activity="no" detail=""
    if [[ "$succ" =~ ^[0-9]+$ ]] && [[ "$succ" -gt 0 ]]; then
        activity="yes"; detail="placements=${succ}"
    elif [[ "$runs" == "UNKNOWN" ]]; then
        # No counter evidence at all: the producer may be sound but nothing is
        # established. Structure still decides; activity stays unproven.
        activity="unknown"; detail="no telemetry recorded yet"
    else
        detail="scans=${runs} candidates=${cands} threshold_hits=${hits} attempts=${att} failures=${failed}"
    fi

    # Producer transition faults are DEGRADED, not INCAPABLE: the edge exists,
    # it is failing. Only a definitively absent edge is INCAPABLE.
    local cap
    if [[ "$hits" =~ ^[0-9]+$ ]] && [[ "$hits" -gt 0 ]] \
       && [[ "$att" =~ ^[0-9]+$ ]] && [[ "$att" -eq 0 ]]; then
        cap="DEGRADED"; detail="threshold reached ${hits}x but no placement attempted"
    elif [[ "$failed" =~ ^[0-9]+$ ]] && [[ "$failed" -gt 0 ]] \
         && { [[ ! "$succ" =~ ^[0-9]+$ ]] || [[ "$succ" -eq 0 ]]; }; then
        cap="DEGRADED"; detail="placement attempted but every attempt failed (failures=${failed})"
    else
        cap=$(nftban_capability_classify yes "$reachable" "$producer" "$consumer" "$observation" "$activity")
    fi

    printf '%s %s' "$cap" "$detail"
}

export -f nftban_capability_ddos_penalty 2>/dev/null || true
