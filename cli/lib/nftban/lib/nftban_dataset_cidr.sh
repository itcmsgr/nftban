#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.0 - Shared CIDR Merge Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_dataset_cidr"
# meta:type="library"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-02-23"
# meta:description="Shared CIDR merge/consolidation for feeds, geoban, and future modules"
# meta:input="CIDR list files"
# meta:output="Merged CIDR list files (no overlapping intervals)"
# meta:depends="nftban_feeds.sh (extracted from), nftban_geoban.sh (new caller)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# PURPOSE: Eliminates overlapping CIDRs that cause "conflicting intervals"
#          errors in nftables interval sets. Used by feeds AND geoban.
#
# USAGE:
#   source /usr/lib/nftban/lib/nftban_dataset_cidr.sh
#   nftban_cidr_merge <input_file> <output_file> <ip_version>
#
# METHODS (priority order):
#   1. aggregate6 (Python tool — best, handles all edge cases)
#   2. netmask (C tool — good for IPv4)
#   3. Pure bash fallback (removes contained CIDRs)
#
# =============================================================================

set -Eeuo pipefail

# Double-load prevention
[[ "${_NFTBAN_DATASET_CIDR_LOADED:-}" == "1" ]] && return 0
_NFTBAN_DATASET_CIDR_LOADED=1

# Internal logging — callers can override this function
_nftban_cidr_log() {
    local level="$1"; shift
    if declare -f nftban_feeds_log &>/dev/null; then
        nftban_feeds_log "$level" "$@"
    elif declare -f nftban_geoban_log &>/dev/null; then
        nftban_geoban_log "$level" "$@"
    else
        echo "[nftban-cidr] [$level] $*" >&2
    fi
}

# =============================================================================
# PUBLIC API: Merge overlapping CIDRs in a file
# Usage: nftban_cidr_merge <input_file> <output_file> <ip_version>
# ip_version: 4 or 6
#
# Returns: 0 = output_file holds a USABLE merged list (or the input was empty)
#          1 = no method produced a usable list. output_file is left EMPTY and
#              the caller MUST treat this as a CONVERSION FAILURE — never as
#              "this source legitimately has no ranges".
#
# ⛔ A converter handed non-empty input that emits nothing has FAILED. It has not
#    "merged everything away": two CIDR blocks are either disjoint or one contains
#    the other, so a non-empty input ALWAYS yields a non-empty output. Returning 0
#    on an empty result was the whole of the GeoBan self-zeroing defect —
#    `netmask -c < file` printed nothing (netmask parses ARGUMENTS and reads
#    nothing from stdin), the count became 0, the `-gt 0` apply gate went false,
#    nft_ipc_sync_or_apply was never called, and the module announced SUCCESS
#    having committed nothing to the kernel.
#
# The judgement "an empty result is unacceptable" lives HERE and only here, so a
# new merge method cannot reintroduce the defect by forgetting to make it.
# =============================================================================
nftban_cidr_merge() {
    local input_file="$1"
    local output_file="$2"
    local ip_version="${3:-4}"

    if [[ ! -f "$input_file" ]]; then
        : > "$output_file"
        _nftban_cidr_log ERROR "CIDR merge input does not exist: ${input_file}"
        return 1
    fi

    # Count records that carry at least one non-whitespace character. `wc -l`
    # would count a blank-padded file as non-empty and then compare that inflated
    # figure against a trimmed output.
    local input_count
    input_count=$(grep -cE '[^[:space:]]' "$input_file" 2>/dev/null) || input_count=0
    if [[ "${input_count:-0}" -eq 0 ]]; then
        : > "$output_file"          # genuinely empty source — not a failure
        return 0
    fi

    local method rc output_count
    for method in aggregate6 netmask bash; do
        : > "$output_file"
        "_nftban_cidr_try_${method}" "$input_file" "$output_file" "$ip_version"
        rc=$?
        [[ $rc -eq 2 ]] && continue      # not available / not applicable on this host
        if [[ $rc -ne 0 ]]; then
            _nftban_cidr_log WARN "CIDR merge method '${method}' FAILED (rc=${rc}) — trying next method"
            continue
        fi
        output_count=$(grep -cE '[^[:space:]]' "$output_file" 2>/dev/null) || output_count=0
        if [[ "${output_count:-0}" -eq 0 ]]; then
            _nftban_cidr_log WARN "CIDR merge method '${method}' produced 0 CIDRs from ${input_count} records — REJECTED (a merge cannot empty a non-empty list)"
            continue
        fi
        _nftban_cidr_log INFO "CIDR merge (${method}, IPv${ip_version}): ${input_count} -> ${output_count}"
        return 0
    done

    : > "$output_file"
    _nftban_cidr_log ERROR "CIDR merge FAILED (IPv${ip_version}): no method produced a usable list from ${input_count} records"
    return 1
}

# -----------------------------------------------------------------------------
# CONVERTER BUDGET
# -----------------------------------------------------------------------------
# The pure-bash fallback is O(n^2): every input CIDR is compared against every
# CIDR kept so far. MEASURED on lab4 (EL9, where BOTH netmask and aggregate6 are
# absent, so this fallback is the DEFAULT path):
#     10 -> 0.03s   100 -> 0.75s   250 -> 4.6s   500 -> 19.0s
#    750 -> 44.2s  1000 -> 76.5s  1500 -> exceeded 120s
# A real country zone (~3000 CIDRs) did not finish in 600s. Unbounded, that stalls
# a firewall rebuild for many minutes with no verdict — worse than a truthful
# failure, because the operator cannot tell a slow rebuild from a hung one.
#
# ⛔ THE BOUND IS NOT DERIVED FROM THE 600s FAILURE. It comes from an existing
#    authority: derived_state_reconcile.sh already governs a recovery apply with
#    `timeout 120s "$core" feeds load`. A producer performs AT MOST TWO converter
#    invocations per apply (one per family, each gated on a non-zero count), so a
#    60s per-converter budget makes the cumulative worst case exactly that same
#    120s. No new global timeout policy is introduced.
#
# ⛔ EXCEEDING THE BUDGET IS A CONVERSION FAILURE, NEVER A PARTIAL RESULT. Output
#    written so far is discarded: a half-converted country applied as if complete
#    is precisely the silent coverage loss this lane exists to remove.
#
# A host that genuinely needs country-scale conversion should install `netmask` or
# `aggregate6` (both are packaging Recommends); those paths are not O(n^2) and are
# not gated by this budget in practice.
# ⛔ THERE IS NO "UNLIMITED" SETTING. A value of 0, empty, or non-numeric falls
#    back to the default rather than disabling the deadline: an easy config path
#    back to an unbounded recovery conversion would reinstate the exact defect
#    this bounds. A deliberately long budget is still expressible — set a large
#    positive number — but it has to be an explicit, visible choice.
NFTBAN_CIDR_MERGE_BUDGET_SECONDS="${NFTBAN_CIDR_MERGE_BUDGET_SECONDS:-60}"
[[ "$NFTBAN_CIDR_MERGE_BUDGET_SECONDS" =~ ^[1-9][0-9]*$ ]] || NFTBAN_CIDR_MERGE_BUDGET_SECONDS=60

# ⛔ THIS IS A CONVERSION BUDGET, NOT A RECOVERY-STEP DEADLINE. Two invocations
#    per apply cap CONVERSION at 2x this value, but reading the durable source,
#    IPC, daemon reconciliation, the kernel replace and verification all fall
#    OUTSIDE it — so conversion alone can consume that whole span before the apply
#    begins. GeoBan recovery has no outer deadline governing the complete step
#    (feeds recovery does: `timeout 120s "$core" feeds load`). That asymmetry is a
#    real gap and is recorded as an owned boundedness finding; it is deliberately
#    NOT solved here by inventing a second timer framework.

# -----------------------------------------------------------------------------
# Method adapters.
# Contract for every _nftban_cidr_try_*:
#   rc 0 = ran and wrote output_file      rc 1 = ran and failed
#   rc 2 = not available / not applicable on this host
# None of them may decide that an empty result is acceptable; that judgement
# belongs to nftban_cidr_merge alone (see the banner above).
# -----------------------------------------------------------------------------

_nftban_cidr_try_aggregate6() {
    local in="$1" out="$2" v="$3"
    command -v aggregate6 &>/dev/null || return 2
    if [[ "$v" == "4" ]]; then
        aggregate6 -4 < "$in" > "$out" 2>/dev/null || return 1
    else
        aggregate6 -6 < "$in" > "$out" 2>/dev/null || return 1
    fi
    return 0
}

_nftban_cidr_try_netmask() {
    local in="$1" out="$2" v="$3"
    command -v netmask &>/dev/null || return 2
    [[ "$v" == "4" ]] || return 2      # only invoked for IPv4 here

    # netmask(1) SYNOPSIS is `netmask spec [spec ...]`: it parses ARGUMENTS and
    # reads NOTHING from stdin, so `netmask -c < file` exits 1 having printed only
    # a usage hint. Measured on netmask 2.4.4 (Ubuntu 24.04):
    #   netmask -c < file      -> rc=1, 0 lines, "Try `netmask --help'"
    #   netmask -c -n -f file  -> rc=0, correct aggregation, exact coverage
    #   -f  treat the arguments as input FILES (the supported way to pass a list)
    #   -n  never resolve DNS. Without it an unparseable record is handed to the
    #       resolver as a hostname, turning malformed data into network traffic.
    # netmask exits 0 even when it REJECTED records, reporting each on stderr, so
    # stderr is surfaced rather than discarded.
    # Output is RIGHT-ALIGNED with variable indent (measured: 6-9 leading spaces)
    # and always carries an explicit prefix — a bare `5.6.7.8` is normalised to
    # `5.6.7.8/32` — so trimming plus a prefix-requiring shape filter is exact and
    # drops no coverage.
    local err raw rc=0
    err=$(mktemp "${TMPDIR:-/tmp}/nftban_nm_err_XXXXXX") || return 1
    raw=$(mktemp "${TMPDIR:-/tmp}/nftban_nm_raw_XXXXXX") || { rm -f "$err"; return 1; }

    netmask -c -n -f "$in" > "$raw" 2>"$err" || rc=1

    if [[ -s "$err" ]]; then
        local rejected
        rejected=$(grep -c 'parse error' "$err" 2>/dev/null) || rejected=0
        _nftban_cidr_log WARN "netmask REJECTED ${rejected:-0} malformed record(s) — they are NOT in the applied set; first: $(head -1 "$err")"
    fi

    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$raw" \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' \
        | sort -u > "$out"

    rm -f "$err" "$raw"
    return $rc
}

_nftban_cidr_try_bash() {
    local in="$1" out="$2" v="$3"
    _nftban_cidr_log DEBUG "Using bash fallback for CIDR deduplication (IPv${v})"
    _nftban_cidr_merge_bash "$in" "$out" "$v" || return 1
    return 0
}

# =============================================================================
# INTERNAL: Pure bash CIDR overlap removal
# =============================================================================
_nftban_cidr_merge_bash() {
    local input_file="$1"
    local output_file="$2"
    local ip_version="${3:-4}"

    local temp_sorted="${input_file}.sorted"
    local temp_filtered="${input_file}.filtered"

    # Sort by prefix length (largest networks first)
    if [[ "$ip_version" == "4" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if [[ "$cidr" == */* ]]; then
                local prefix="${cidr##*/}"
                printf '%02d|%s\n' "$prefix" "$cidr"
            else
                printf '32|%s/32\n' "$cidr"
            fi
        done < "$input_file" | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2 > "$temp_sorted"
    else
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if [[ "$cidr" == */* ]]; then
                local prefix="${cidr##*/}"
                printf '%03d|%s\n' "$prefix" "$cidr"
            else
                printf '128|%s/128\n' "$cidr"
            fi
        done < "$input_file" | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2 > "$temp_sorted"
    fi

    # Filter: keep only CIDRs not contained in a larger one
    : > "$temp_filtered"
    declare -a kept_cidrs=()

    # Deadline for the quadratic section. EPOCHSECONDS avoids a subprocess per
    # check; the 64-iteration stride keeps even the `date` fallback negligible.
    local _budget="${NFTBAN_CIDR_MERGE_BUDGET_SECONDS:-60}"
    local _started _now _seen=0
    _started="${EPOCHSECONDS:-$(date +%s)}"

    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        _seen=$((_seen + 1))
        if [[ $((_seen % 64)) -eq 0 ]]; then
            _now="${EPOCHSECONDS:-$(date +%s)}"
            if [[ $((_now - _started)) -ge "$_budget" ]]; then
                _nftban_cidr_log ERROR "CIDR merge (bash) EXCEEDED its ${_budget}s budget after ${_seen} of $(grep -cE '[^[:space:]]' "$input_file" 2>/dev/null || echo '?') records — this fallback is O(n^2); install netmask or aggregate6 for country-scale input"
                rm -f "$temp_sorted" "$temp_filtered"
                : > "$output_file"     # ⛔ no partial conversion is ever applied
                return 1
            fi
        fi
        local dominated=false

        for kept in "${kept_cidrs[@]}"; do
            if _nftban_cidr_contains "$kept" "$cidr" "$ip_version"; then
                dominated=true
                break
            fi
        done

        if [[ "$dominated" == "false" ]]; then
            echo "$cidr" >> "$temp_filtered"
            kept_cidrs+=("$cidr")
        fi
    done < "$temp_sorted"

    mv "$temp_filtered" "$output_file"
    rm -f "$temp_sorted"

    local input_count output_count merged
    input_count=$(wc -l < "$input_file")
    output_count=$(wc -l < "$output_file")
    merged=$((input_count - output_count))
    [[ $merged -gt 0 ]] && _nftban_cidr_log INFO "CIDR merge (bash): ${input_count} -> ${output_count} (removed ${merged} contained CIDRs)"
    # ⛔ EXPLICIT SUCCESS. Without this the function returned the exit status of
    #    the `[[ $merged -gt 0 ]]` test above, so the NORMAL case — a list where
    #    nothing needed merging — returned 1. Under the calling module's `set -e`
    #    that aborted the apply mid-flight.
    return 0
}

# =============================================================================
# INTERNAL: Containment checks
# =============================================================================
_nftban_cidr_contains() {
    local cidr_a="$1"
    local cidr_b="$2"
    local ip_version="${3:-4}"

    if [[ "$ip_version" == "4" ]]; then
        _nftban_cidr_contains_ipv4 "$cidr_a" "$cidr_b"
    else
        _nftban_cidr_contains_ipv6 "$cidr_a" "$cidr_b"
    fi
}

_nftban_cidr_contains_ipv4() {
    local cidr_a="$1"
    local cidr_b="$2"

    local net_a="${cidr_a%/*}" prefix_a="${cidr_a##*/}"
    [[ "$prefix_a" == "$cidr_a" ]] && prefix_a=32
    local net_b="${cidr_b%/*}" prefix_b="${cidr_b##*/}"
    [[ "$prefix_b" == "$cidr_b" ]] && prefix_b=32

    [[ $prefix_a -gt $prefix_b ]] && return 1

    local -a octets_a octets_b
    IFS='.' read -ra octets_a <<< "$net_a"
    IFS='.' read -ra octets_b <<< "$net_b"

    local int_a=$(( (octets_a[0] << 24) + (octets_a[1] << 16) + (octets_a[2] << 8) + octets_a[3] ))
    local int_b=$(( (octets_b[0] << 24) + (octets_b[1] << 16) + (octets_b[2] << 8) + octets_b[3] ))
    local mask=$(( 0xFFFFFFFF << (32 - prefix_a) & 0xFFFFFFFF ))

    [[ $(( int_b & mask )) -eq $(( int_a & mask )) ]]
}

_nftban_cidr_contains_ipv6() {
    local cidr_a="$1"
    local cidr_b="$2"

    local prefix_a="${cidr_a##*/}" prefix_b="${cidr_b##*/}"
    [[ "$prefix_a" == "$cidr_a" ]] && prefix_a=128
    [[ "$prefix_b" == "$cidr_b" ]] && prefix_b=128

    [[ $prefix_a -gt $prefix_b ]] && return 1

    local net_a="${cidr_a%/*}" net_b="${cidr_b%/*}"
    local expanded_a expanded_b
    expanded_a=$(_nftban_expand_ipv6 "$net_a")
    expanded_b=$(_nftban_expand_ipv6 "$net_b")

    local chars_to_compare=$(( (prefix_a + 3) / 4 ))
    local prefix_str_a="${expanded_a:0:$chars_to_compare}"
    local prefix_str_b="${expanded_b:0:$chars_to_compare}"

    [[ "$prefix_str_a" == "$prefix_str_b" ]]
}

# Expand IPv6 address to full 32-char hex form (no colons)
_nftban_expand_ipv6() {
    local addr="$1"

    if [[ "$addr" == *"::"* ]]; then
        local left="${addr%%::*}"
        local right="${addr#*::}"
        local left_groups=0 right_groups=0

        [[ -n "$left" ]] && left_groups=$(echo "$left" | tr -cd ':' | wc -c)
        # v1.19.20 FIX
        [[ -n "$left" ]] && { ((left_groups++)) || true; }
        [[ -n "$right" ]] && right_groups=$(echo "$right" | tr -cd ':' | wc -c)
        # v1.19.20 FIX
        [[ -n "$right" ]] && { ((right_groups++)) || true; }

        local missing=$((8 - left_groups - right_groups))
        local zeros=""
        for ((i=0; i<missing; i++)); do
            zeros="${zeros}:0000"
        done

        if [[ -z "$left" ]]; then
            addr="${zeros#:}:$right"
        elif [[ -z "$right" ]]; then
            addr="$left$zeros"
        else
            addr="$left$zeros:$right"
        fi
    fi

    IFS=':' read -ra groups <<< "$addr"
    for group in "${groups[@]}"; do
        printf '%04x' "0x${group:-0}" 2>/dev/null || printf '0000'
    done
}
