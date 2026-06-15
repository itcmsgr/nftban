#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="version" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized version management for all NFTBan components"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

[[ -n "${NFTBAN_VERSION_LOADED:-}" ]] && return 0

# =============================================================================
# VERSION CONSTANTS
# =============================================================================

# Read version from VERSION file (single source of truth)
_nftban_read_version() {
    # Initialize to empty so `set -u` at line-39 [[ -f "$version_file" ]]
    # does not crash when none of the lookup paths match (which would otherwise
    # break every CLI subcommand — version.sh is sourced by all of them).
    local version_file=""
    # Try multiple possible locations (package path first, then source tree)
    for path in \
        "/usr/lib/nftban/VERSION" \
        "${BASH_SOURCE[0]%/*}/../../../../../VERSION" \
        "${NFTBAN_ROOT:-}/VERSION" \
        "$PWD/VERSION"; do
        if [[ -f "$path" ]]; then
            version_file="$path"
            break
        fi
    done

    if [[ -n "$version_file" && -f "$version_file" ]]; then
        cat "$version_file" | tr -d '[:space:]'
    else
        echo "unknown"  # Fallback if VERSION file not found
    fi
}

# Main NFTBan version (read from VERSION file)
NFTBAN_VERSION=$(_nftban_read_version)
readonly NFTBAN_VERSION

# Parse version components (safely handle non-standard formats)
# Use subshell to avoid IFS contamination from strict.sh
if [[ "$NFTBAN_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    NFTBAN_VERSION_MAJOR="${BASH_REMATCH[1]}"
    NFTBAN_VERSION_MINOR="${BASH_REMATCH[2]}"
    NFTBAN_VERSION_PATCH="${BASH_REMATCH[3]}"
else
    # Fallback for non-standard versions (e.g., "unknown", "dev")
    NFTBAN_VERSION_MAJOR="0"
    NFTBAN_VERSION_MINOR="0"
    NFTBAN_VERSION_PATCH="0"
fi
readonly NFTBAN_VERSION_MAJOR
readonly NFTBAN_VERSION_MINOR
readonly NFTBAN_VERSION_PATCH

# Version details
readonly NFTBAN_VERSION_NAME="Linux Firewall & IPS for nftables"
readonly NFTBAN_VERSION_DATE="2026-03-18"

# v1.151 BUG-VERSION-BUILD-DATE-RUNTIME: "Build Date" must reflect the PACKAGE
# build, not the current clock. The old `$(date)` here made `nftban version`
# print the run-second on every invocation (useless for support / CVE-patch
# tracking). Resolution order — NEVER the current clock:
#   1. a build-written stamp file (forward-compat; future packaging may write it)
#   2. the package manager's recorded BUILD time (rpm) — real on RPM hosts
#   3. "unknown" — honest fallback (source builds / DEB without a stamp)
_nftban_resolve_build_date() {
    local _stamp="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/.build_date" _d _t
    if [[ -r "$_stamp" ]]; then
        _d=$(head -n1 "$_stamp" 2>/dev/null | tr -d '\r')
        [[ -n "$_d" ]] && { printf '%s' "$_d"; return 0; }
    fi
    if command -v rpm >/dev/null 2>&1; then
        _t=$(rpm -q --qf '%{BUILDTIME}' nftban-core 2>/dev/null) || _t=""
        if [[ "$_t" =~ ^[0-9]+$ ]]; then
            _d=$(date -u -d "@${_t}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null) || _d=""
            [[ -n "$_d" ]] && { printf '%s' "$_d"; return 0; }
        fi
    fi
    printf 'unknown'
}
NFTBAN_BUILD_DATE="$(_nftban_resolve_build_date)"
readonly NFTBAN_BUILD_DATE

# Component versions (kept in sync with main version)
# V127 UX-1 item 1.3: GUI/API component slots are NOT shipped in v1.127+ —
# they were advertised in prior output but never resolved to real binaries.
# Removed to prevent operator-inventory queries returning ghost components.
# (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-1 item 1.3)
readonly NFTBAN_CLI_VERSION="$NFTBAN_VERSION"
readonly NFTBAN_CORE_VERSION="$NFTBAN_VERSION"

# Compatibility
readonly NFTBAN_MIN_BASH_VERSION="4.0"
readonly NFTBAN_MIN_NFT_VERSION="0.9.3"

# Export all version variables (required for subshells/child processes)
export NFTBAN_VERSION NFTBAN_VERSION_MAJOR NFTBAN_VERSION_MINOR NFTBAN_VERSION_PATCH
export NFTBAN_VERSION_NAME NFTBAN_VERSION_DATE NFTBAN_BUILD_DATE
export NFTBAN_CLI_VERSION NFTBAN_CORE_VERSION
export NFTBAN_MIN_BASH_VERSION NFTBAN_MIN_NFT_VERSION

# =============================================================================
# VERSION INFORMATION FUNCTIONS
# =============================================================================

nftban_version_full() {
    # Get full version string
    # Returns: "NFTBan v0.6.5 (Strict Mode) - 2025-11-24"
    echo "NFTBan v${NFTBAN_VERSION} (${NFTBAN_VERSION_NAME}) - ${NFTBAN_VERSION_DATE}"
}

nftban_version_short() {
    # Get short version string
    # Returns: "0.6.5"
    echo "$NFTBAN_VERSION"
}

nftban_version_numeric() {
    # Get numeric version for comparison
    # Returns: 605 (for 0.6.5)
    echo "$((NFTBAN_VERSION_MAJOR * 10000 + NFTBAN_VERSION_MINOR * 100 + NFTBAN_VERSION_PATCH))"
}

nftban_version_check() {
    # Check if a version requirement is met
    # Args: $1 = required version (e.g., "0.6.0")
    # Returns: 0 if current version >= required, 1 otherwise

    local required="$1"
    local required_major required_minor required_patch

    IFS='.' read -r required_major required_minor required_patch <<< "$required"

    local required_numeric=$((required_major * 10000 + required_minor * 100 + required_patch))
    local current_numeric
    current_numeric=$(nftban_version_numeric)

    [[ $current_numeric -ge $required_numeric ]]
}

nftban_version_info() {
    # Print detailed version information
    # V127 UX-1 item 1.3: GUI/API rows removed (ghost components — see header note above NFTBAN_CLI_VERSION).
    # V127 UX-1 item 1.4: Adds Update Status block (Installed / Latest / Last checked) so the operator
    # gets upgrade-eligibility status without running `nftban update check` separately.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-1 items 1.3 + 1.4)

    # Read update-check cache (populated by `nftban update check`).
    # Defaults if cache absent: Latest = "not checked yet", Last checked = "never".
    local _cache_file="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/update_available.json"
    local _latest="not checked yet"
    local _last_checked="never (run: nftban update check)"
    if [[ -f "$_cache_file" ]]; then
        # Prefer jq; fall back to grep if jq absent
        if command -v jq &>/dev/null; then
            local _v
            _v=$(jq -r '.latest_version // empty' "$_cache_file" 2>/dev/null)
            [[ -n "$_v" && "$_v" != "null" ]] && _latest="v${_v}"
        else
            local _v
            _v=$(grep -oP '"latest_version":\s*"\K[^"]+' "$_cache_file" 2>/dev/null | head -1)
            [[ -n "$_v" ]] && _latest="v${_v}"
        fi
        # Last-checked = cache file mtime (more reliable than parsing JSON timestamp)
        local _mtime
        _mtime=$(stat -c %Y "$_cache_file" 2>/dev/null || echo "0")
        if [[ "$_mtime" -gt 0 ]]; then
            _last_checked=$(date -d "@${_mtime}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -r "$_cache_file" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown")
        fi
    fi

    # v1.141 PR-B (E-NO-BANNER): split decorative ━━━ frame + heading from
    # data lines so `nftban version 2>/dev/null | grep ^Version` works when
    # NFTBAN_NO_BANNER=1 / --no-banner / --json is set.
    if [[ "${NFTBAN_NO_BANNER:-0}" != "1" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "NFTBan Version Information"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi
    cat <<EOF
Version:        ${NFTBAN_VERSION}
Name:           ${NFTBAN_VERSION_NAME}
Release Date:   ${NFTBAN_VERSION_DATE}
Build Date:     ${NFTBAN_BUILD_DATE}

Components:
  CLI:          ${NFTBAN_CLI_VERSION}
  Core:         ${NFTBAN_CORE_VERSION}

Update Status:
  Installed:    v${NFTBAN_VERSION}
  Latest:       ${_latest}
  Last checked: ${_last_checked}

Requirements:
  Bash:         >= ${NFTBAN_MIN_BASH_VERSION}
  nftables:     >= ${NFTBAN_MIN_NFT_VERSION}
EOF
    # v1.141 PR-B (E-NO-BANNER): suppress trailing decorative frame too.
    if [[ "${NFTBAN_NO_BANNER:-0}" != "1" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# =============================================================================
# COMPATIBILITY CHECK
# =============================================================================

nftban_version_check_requirements() {
    # Check if system meets minimum requirements
    # Returns: 0 if all requirements met, 1 otherwise

    local status=0

    # Check bash version
    if [[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" < "$NFTBAN_MIN_BASH_VERSION" ]]; then
        echo "ERROR: Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} is too old. Need >= $NFTBAN_MIN_BASH_VERSION" >&2
        status=1
    fi

    # Check nftables version (if nft is available)
    if command -v nft &>/dev/null; then
        local nft_version
        nft_version=$(nft --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

        if [[ -n "$nft_version" ]]; then
            # Simple version comparison (works for most cases)
            if [[ "$nft_version" < "$NFTBAN_MIN_NFT_VERSION" ]]; then
                echo "WARNING: nftables $nft_version may be too old. Recommend >= $NFTBAN_MIN_NFT_VERSION" >&2
            fi
        fi
    fi

    return $status
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_version_full
export -f nftban_version_short
export -f nftban_version_numeric
export -f nftban_version_check
export -f nftban_version_info
export -f nftban_version_check_requirements

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_VERSION_LOADED=1
export NFTBAN_VERSION_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
