#!/usr/bin/env bash
# =============================================================================
# NFTBan - Verified build-time fetch helper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fetch_verified"
# meta:type="installer"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="Resilient, checksum-verified, atomic build-time downloader"
# meta:input="url sha256 dest"
# meta:output="verified file at dest (or non-zero exit, no partial file)"
# meta:depends="curl, sha256sum, mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="curl,sha256sum,mktemp,mv,rm,dirname"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="https outbound (build-time artifact download)"
# meta:inventory.privileges="none"
# =============================================================================
# v1.157 PR-A (CI/release fetch hardening):
#   Single shared helper used by every build-time curl download site so the
#   retry / fail-fast / atomic-write / checksum-verify behaviour cannot drift
#   between build_nftban.sh (DEB path) and the CI workflows.
#
# Behaviour:
#   - download to a temp file with retry + fail-fast + bounded timeouts
#   - verify SHA256 of the temp file
#   - ONLY on success, atomically mv temp -> dest (never leaves a bad/partial
#     file at dest)
#   - fails closed (non-zero) on download OR checksum failure
#   - cleans up the temp file on failure
#   - set -e safe and sourceable (defines a function, runs nothing on source)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading (idempotent source).
[[ -n "${_NFTBAN_FETCH_VERIFIED_LOADED:-}" ]] && return 0
_NFTBAN_FETCH_VERIFIED_LOADED=1

# fetch_verified <url> <sha256> <dest>
# Returns 0 on success (verified file written atomically to <dest>),
# non-zero on any download or checksum failure (no file left at <dest>).
fetch_verified() {
    local url="$1"
    local sha="$2"
    local dest="$3"

    if [ -z "$url" ] || [ -z "$sha" ] || [ -z "$dest" ]; then
        echo "fetch_verified: usage: fetch_verified <url> <sha256> <dest>" >&2
        return 2
    fi

    local dest_dir
    dest_dir="$(dirname "$dest")"

    local tmp
    tmp="$(mktemp "${dest_dir}/.fetch_verified.XXXXXX")" || {
        echo "fetch_verified: failed to create temp file in ${dest_dir}" >&2
        return 1
    }

    # Retry: 5 attempts, retry on ANY transient error (incl. HTTP 5xx),
    # 3s between attempts, bounded connect + total time. --fail makes HTTP
    # errors non-zero; -sS keeps it quiet but still prints errors.
    if ! curl --fail --location --retry 5 --retry-all-errors --retry-delay 3 \
              --connect-timeout 10 --max-time 120 -sS -o "$tmp" "$url"; then
        echo "fetch_verified: download failed: ${url}" >&2
        rm -f "$tmp"
        return 1
    fi

    if ! echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null 2>&1; then
        echo "fetch_verified: checksum verification failed for ${url}" >&2
        echo "fetch_verified: expected ${sha}" >&2
        rm -f "$tmp"
        return 1
    fi

    if ! mv -f "$tmp" "$dest"; then
        echo "fetch_verified: failed to install verified file to ${dest}" >&2
        rm -f "$tmp"
        return 1
    fi

    return 0
}
