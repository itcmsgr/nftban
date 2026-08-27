#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="observability_counters" meta:type="lib" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Best-effort persistent cumulative counters and last-event timestamps for capability evidence"
# meta:inventory.files="/var/lib/nftban/state/*_counters"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

[[ -n "${_NFTBAN_OBS_COUNTERS_LOADED:-}" ]] && return 0
_NFTBAN_OBS_COUNTERS_LOADED=1

# =============================================================================
# OBSERVABILITY COUNTERS (B03 evidence source)
# =============================================================================
# ⛔ LOAD-BEARING INVARIANT: COUNTERS OBSERVE, COUNTERS DO NOT DECIDE.
#
#   - Strike and promotion authority is unchanged; nothing here participates in
#     an enforcement decision.
#   - A counter failure must NEVER prevent or trigger enforcement. Every entry
#     point below swallows its own errors and returns 0.
#   - But health must not pretend telemetry is available: a read that fails is
#     reported as UNKNOWN by the consumer, never as zero. Absence of a counter
#     file is "not established", not "nothing happened".
#
# ⛔ PROVISIONAL (owner ruling 2026-08-27). This primitive and the A08 producer
# instrumentation that feeds it are retained because the B03/A09b adapter will
# consume the same evidence model — NOT because they were already written. If
# that adapter does not materialise in v1.229.12, revisit whether they ship.
# `WE ALREADY WROTE IT` IS NOT A JUSTIFICATION.
#
# Deliberately NOT wired into the DDoS readiness report (nftban_ddos_classic.sh
# :928-944). Structural readiness ("can it operate?") and operational history
# ("has it operated recently, with what result?") are different questions, and
# fusing them casually would produce bad semantics — e.g. "no recent placement"
# rendering as STARVED when there has simply been no qualifying traffic.
#
# Format is flat `key=value`, one per line — no jq dependency on the write path,
# so instrumentation cannot fail because a JSON tool is missing.
#
# Cumulative counters answer "did this ever work"; the paired last_*_at
# timestamps answer "did it work RECENTLY", which a bare total cannot
# (placement_success=200 says nothing about today).
# =============================================================================

_nftban_obs_file() {
    printf '%s/state/%s_counters' "${NFTBAN_DATA_DIR:-/var/lib/nftban}" "${1:-unknown}"
}

# nftban_obs_bump <namespace> <key> [increment]
# Adds to a cumulative counter and stamps <key>_at. Best-effort by contract.
nftban_obs_bump() {
    local ns="${1:-}" key="${2:-}" inc="${3:-1}"
    [[ -z "$ns" || -z "$key" ]] && return 0
    {
        local f tmp cur now
        f=$(_nftban_obs_file "$ns")
        mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
        cur=$(grep -m1 "^${key}=" "$f" 2>/dev/null | cut -d= -f2)
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
        now=$(date -u +%s 2>/dev/null || echo 0)
        tmp="${f}.$$.tmp"
        {
            grep -vE "^(${key}|${key}_at)=" "$f" 2>/dev/null
            printf '%s=%s\n' "$key" "$((cur + inc))"
            printf '%s_at=%s\n' "$key" "$now"
        } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    } 2>/dev/null
    return 0
}

# nftban_obs_set <namespace> <key> <value>
# Records a non-cumulative fact (e.g. last_scan_rc). Best-effort by contract.
nftban_obs_set() {
    local ns="${1:-}" key="${2:-}" val="${3:-}"
    [[ -z "$ns" || -z "$key" ]] && return 0
    {
        local f tmp
        f=$(_nftban_obs_file "$ns")
        mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
        tmp="${f}.$$.tmp"
        {
            grep -vE "^${key}=" "$f" 2>/dev/null
            printf '%s=%s\n' "$key" "$val"
        } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    } 2>/dev/null
    return 0
}

# nftban_obs_get <namespace> <key>
# Emits the value, or the literal UNKNOWN when it cannot be established.
# ⛔ A missing file, unreadable file or absent key is UNKNOWN — NEVER 0.
# "Nothing was recorded" and "nothing happened" are different facts.
nftban_obs_get() {
    local ns="${1:-}" key="${2:-}" f v
    f=$(_nftban_obs_file "$ns")
    [[ -r "$f" ]] || { printf 'UNKNOWN'; return 0; }
    v=$(grep -m1 "^${key}=" "$f" 2>/dev/null | cut -d= -f2)
    [[ -n "$v" ]] || { printf 'UNKNOWN'; return 0; }
    printf '%s' "$v"
}

export -f nftban_obs_bump nftban_obs_set nftban_obs_get _nftban_obs_file 2>/dev/null || true
