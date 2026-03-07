#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.0 - Shared CIDR Merge Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_dataset_cidr"
# meta:type="library"
# meta:version="1.19.0"
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
# Returns: 0 on success, merged count logged
# =============================================================================
nftban_cidr_merge() {
    local input_file="$1"
    local output_file="$2"
    local ip_version="${3:-4}"

    if [[ ! -s "$input_file" ]]; then
        : > "$output_file"
        return 0
    fi

    local input_count
    input_count=$(wc -l < "$input_file")

    # Method 1: aggregate6 (best — handles all edge cases)
    if command -v aggregate6 &>/dev/null; then
        _nftban_cidr_log DEBUG "Using aggregate6 for CIDR merging (IPv${ip_version})"
        if [[ "$ip_version" == "4" ]]; then
            aggregate6 -4 < "$input_file" > "$output_file" 2>/dev/null
        else
            aggregate6 -6 < "$input_file" > "$output_file" 2>/dev/null
        fi
        local output_count
        output_count=$(wc -l < "$output_file")
        local merged=$((input_count - output_count))
        [[ $merged -gt 0 ]] && _nftban_cidr_log INFO "CIDR merge (aggregate6): ${input_count} -> ${output_count} (merged ${merged} overlaps)"
        return 0
    fi

    # Method 2: netmask (good alternative, IPv4 only)
    if command -v netmask &>/dev/null && [[ "$ip_version" == "4" ]]; then
        _nftban_cidr_log DEBUG "Using netmask for CIDR merging (IPv4)"
        netmask -c < "$input_file" 2>/dev/null | sort -u > "$output_file"
        local output_count
        output_count=$(wc -l < "$output_file")
        local merged=$((input_count - output_count))
        [[ $merged -gt 0 ]] && _nftban_cidr_log INFO "CIDR merge (netmask): ${input_count} -> ${output_count} (merged ${merged} overlaps)"
        return 0
    fi

    # Method 3: Pure bash fallback — remove contained CIDRs
    _nftban_cidr_log DEBUG "Using bash fallback for CIDR deduplication (IPv${ip_version})"
    _nftban_cidr_merge_bash "$input_file" "$output_file" "$ip_version"
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

    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
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
