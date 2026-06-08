#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_feed_counters" meta:type="lib" meta:version="1.167.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Shared feed-counter helpers: unified IP-total and enabled-file-count across feed files"
# meta:inventory.files="/usr/lib/nftban/lib/nftban_feed_counters.sh"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# USAGE:
#   source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_feed_counters.sh"
#
#   # Sum of IP lines across all ENABLED feed files
#   total=$(nftban_feed_ips_total)
#
#   # Count of ENABLED feed files that exist on disk
#   files=$(nftban_feed_file_count)
#
# v1.167 PR-1 (BUG-CtCount-feeds): three independent feed-count computations
# (cmd_status.sh feeds.count, nftban_stats_collect.sh cat-all `wc -l`,
# cmd_feeds.sh per-feed aggregate) previously disagreed because each rolled
# its own resolution. These helpers are the single source of truth for the
# enabled-feed → lowercase → "<data>/feeds/<feed>.txt" mapping (the v1.141
# PR-C resolution) and the two distinct surfaces it feeds:
#   - IP total   : sum of non-empty lines across enabled feed files
#   - file count : number of enabled feed files that exist
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_FEED_COUNTERS_LOADED:-}" ]] && return 0
_NFTBAN_FEED_COUNTERS_LOADED=1

# Ensure the dynamic feed-discovery primitives are available. These live in
# core/nftban_feeds.sh; consuming commands that already source it pay no cost
# (it is idempotent). Best-effort: if it cannot be located, the helpers below
# degrade to 0 rather than crashing.
_nftban_feed_counters_ensure_feeds_lib() {
    if declare -f nftban_feeds_discover_all >/dev/null 2>&1 \
        && declare -f nftban_feeds_get_property >/dev/null 2>&1; then
        return 0
    fi
    local _lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    local _candidate
    for _candidate in \
        "${_lib_dir}/core/nftban_feeds.sh" \
        "$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")/core/nftban_feeds.sh"; do
        if [[ -f "$_candidate" ]]; then
            # shellcheck source=/dev/null
            source "$_candidate" 2>/dev/null || true
            declare -f nftban_feeds_discover_all >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# Resolve the list of ENABLED feed files that exist on disk (one absolute path
# per line). Mirrors the cmd_feeds.sh v1.141 PR-C resolution exactly:
#   discover all feeds → keep ENABLED==true → lowercase → <data>/feeds/<feed>.txt
# Emits nothing when the feeds dir is absent or no enabled feed file exists.
_nftban_feed_counters_enabled_files() {
    local _feed_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
    [[ -d "$_feed_dir" ]] || return 0
    _nftban_feed_counters_ensure_feeds_lib || return 0

    local _all _feed _on _ff
    _all=$(nftban_feeds_discover_all 2>/dev/null || true)
    for _feed in $_all; do
        _on=$(nftban_feeds_get_property "$_feed" "ENABLED" 2>/dev/null || echo false)
        [[ "$_on" == "true" ]] || continue
        _ff="${_feed_dir}/$(echo "$_feed" | tr '[:upper:]' '[:lower:]').txt"
        [[ -f "$_ff" ]] && printf '%s\n' "$_ff"
    done
}

# nftban_feed_ips_total — sum of non-empty IP lines across all ENABLED feed
# files. Missing files contribute 0. Always prints an integer (0 on any error).
nftban_feed_ips_total() {
    local _total=0 _ff _n
    while IFS= read -r _ff; do
        [[ -n "$_ff" ]] || continue
        # Count non-empty lines (robust to a missing trailing newline).
        _n=$(grep -cve '^[[:space:]]*$' "$_ff" 2>/dev/null || true)
        [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
        _total=$((_total + _n))
    done < <(_nftban_feed_counters_enabled_files)
    printf '%s\n' "$_total"
}

# nftban_feed_file_count — number of ENABLED feed files that exist on disk.
# Always prints an integer (0 on any error).
nftban_feed_file_count() {
    local _count=0 _ff
    while IFS= read -r _ff; do
        [[ -n "$_ff" ]] && _count=$((_count + 1))
    done < <(_nftban_feed_counters_enabled_files)
    printf '%s\n' "$_count"
}

# Export so subshells / sourced command modules see the helpers.
export -f nftban_feed_ips_total nftban_feed_file_count \
    _nftban_feed_counters_enabled_files _nftban_feed_counters_ensure_feeds_lib 2>/dev/null || true
