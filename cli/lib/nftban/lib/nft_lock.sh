#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.32.0 - Global nft Operation Lock (Shell)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_lock"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-03-21"
# meta:description="Shell-side flock wrapper for serializing nft kernel operations"
# meta:inventory.files="/usr/lib/nftban/lib/nft_lock.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Uses flock(1) on the same lock file as Go's syscall.Flock — guaranteed
# coordination between shell and Go nft operations.
#
# Contract:
#   - Exclusive lock for nft writes (add/delete/flush) and reconciliation
#   - Shared lock for rare direct kernel reads
#   - Exporters reading /run/nftban/set_counts.json need NO lock
#
# Design: DESIGN_HUGE_SET_COUNTING_ARCHITECTURE.md (P0-3a fix)
# =============================================================================

set -Eeuo pipefail

# Guard against double-sourcing
[[ -n "${_NFTBAN_NFT_LOCK_LOADED:-}" ]] && return 0
readonly _NFTBAN_NFT_LOCK_LOADED=1

# Canonical lock path — MUST match Go pkg/nftlock/lock.go LockPath
readonly NFTBAN_NFT_LOCK="/run/nftban/nft_operations.lock"

# Separate file descriptors for write and read locks to prevent
# FD reuse from silently releasing a held lock.
# Using high numbers to avoid conflicts with application FDs.
readonly _NFTBAN_NFT_LOCK_FD_WRITE=200
readonly _NFTBAN_NFT_LOCK_FD_READ=201

# _nftban_lock_log — safe logging that works even if log_warn is not loaded
_nftban_lock_log() {
    if type -t log_warn &>/dev/null; then
        log_warn "$1"
    else
        echo "[nft_lock] WARNING: $1" >&2
    fi
}

# nftban_nft_write_lock — acquire exclusive lock for nft write operations
# Usage: nftban_nft_write_lock [timeout_seconds]
# Returns: 0 on success, 1 on timeout
nftban_nft_write_lock() {
    local timeout="${1:-30}"
    # Ensure lock directory exists
    [[ -d /run/nftban ]] || mkdir -p /run/nftban 2>/dev/null
    exec 200<>"$NFTBAN_NFT_LOCK"
    if ! flock -x -w "$timeout" "$_NFTBAN_NFT_LOCK_FD_WRITE" 2>/dev/null; then
        _nftban_lock_log "nft write lock timeout after ${timeout}s"
        return 1
    fi
    return 0
}

# nftban_nft_read_lock — acquire shared lock for nft read operations
# Usage: nftban_nft_read_lock [timeout_seconds]
# Returns: 0 on success, 1 on timeout
nftban_nft_read_lock() {
    local timeout="${1:-5}"
    # Ensure lock directory exists
    [[ -d /run/nftban ]] || mkdir -p /run/nftban 2>/dev/null
    exec 201<>"$NFTBAN_NFT_LOCK"
    if ! flock -s -w "$timeout" "$_NFTBAN_NFT_LOCK_FD_READ" 2>/dev/null; then
        _nftban_lock_log "nft read lock timeout after ${timeout}s"
        return 1
    fi
    return 0
}

# nftban_nft_write_unlock — release the exclusive write lock
nftban_nft_write_unlock() {
    flock -u "$_NFTBAN_NFT_LOCK_FD_WRITE" 2>/dev/null
}

# nftban_nft_read_unlock — release the shared read lock
nftban_nft_read_unlock() {
    flock -u "$_NFTBAN_NFT_LOCK_FD_READ" 2>/dev/null
}

# nftban_nft_unlock — release any held lock (backward compat)
nftban_nft_unlock() {
    flock -u "$_NFTBAN_NFT_LOCK_FD_WRITE" 2>/dev/null
    flock -u "$_NFTBAN_NFT_LOCK_FD_READ" 2>/dev/null
}

# Export functions for subshells
export -f nftban_nft_write_lock
export -f nftban_nft_read_lock
export -f nftban_nft_write_unlock
export -f nftban_nft_read_unlock
export -f nftban_nft_unlock
export -f _nftban_lock_log
