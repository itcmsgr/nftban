#!/usr/bin/env bash
# =============================================================================
# NFTBan - write boundary for nft writes made outside nftband
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nft_writers"
# meta:type="library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-23"
# meta:description="v1.236 (design V1236_STAGE2_DESIGN_DRAFT.md §3). The shell side of the inner write boundary /run/nftban-writers/nft_writers.lock (root-owned, fhs-spec). nftband holds it SHARED for each kernel transaction; every nft write made outside the daemon holds it EXCLUSIVE, so it can never land between a firewall replacement's kernel read and its commit, nor inside a daemon transaction. One implementation for the replacement (_fw_atomic_load) and for every direct writer. Changes no shell options: safe to source from any script."
# meta:input="nft arguments"
# meta:output="nft output; rc of nft, or 75 when the boundary was busy (NOT applied)"
# meta:depends="bash,flock,nft"
# meta:inventory.files="/run/nftban-writers/nft_writers.lock, /run/nftban-writers/nft_writers.intent"
# meta:inventory.binaries="flock, nft"
# meta:inventory.env_vars="NFTBAN_WRITERS_DIR, NFTBAN_BOUNDARY_WAIT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

[[ -n "${_NFTBAN_NFT_WRITERS_LOADED:-}" ]] && return 0
_NFTBAN_NFT_WRITERS_LOADED=1

# Descriptor of the held lock while this shell is inside a section ("" otherwise).
_NFTBAN_WRITERS_FD=""

# nftban_writers_acquire — enter the boundary EXCLUSIVE. Publishes the intent (new daemon
# sections wait), then waits at most NFTBAN_BOUNDARY_WAIT (default 60 s) for every daemon
# transaction in flight to finish. Returns 0 held, 75 busy / cannot open (NOT held).
# The descriptor is not close-on-exec: children (nft) keep the lock if this shell dies.
# Rules while held: no daemon IPC, no daemon start/restart, no long-lived child.
nftban_writers_acquire() {
    local dir="${NFTBAN_WRITERS_DIR:-/run/nftban-writers}" fd=""
    if [[ -n "$_NFTBAN_WRITERS_FD" ]]; then
        echo "nftban: write boundary already held by this shell (nested acquire refused)" >&2
        return 75
    fi
    # tmpfiles creates it (fhs-spec); the parent (/run, or a test sandbox) exists, so no -p.
    [[ -d "$dir" ]] || mkdir -m 0700 -- "$dir" 2>/dev/null || true
    if ! { exec {fd}>>"$dir/nft_writers.lock"; } 2>/dev/null; then
        echo "nftban: cannot open $dir/nft_writers.lock — nft write NOT applied" >&2
        return 75
    fi
    printf 'pid=%s boot=%s\n' "$BASHPID" "$(</proc/sys/kernel/random/boot_id)" \
        > "$dir/nft_writers.intent" 2>/dev/null || true
    if ! flock -w "${NFTBAN_BOUNDARY_WAIT:-60}" "$fd"; then
        exec {fd}>&-
        _nftban_writers_drop_intent "$dir"
        echo "nftban: nft writes paused (firewall replacement or daemon transaction) for ${NFTBAN_BOUNDARY_WAIT:-60}s — NOT applied" >&2
        return 75
    fi
    _NFTBAN_WRITERS_FD="$fd"
    return 0
}

# nftban_writers_release — leave the boundary (no-op when not held).
nftban_writers_release() {
    [[ -n "$_NFTBAN_WRITERS_FD" ]] || return 0
    exec {_NFTBAN_WRITERS_FD}>&-
    _NFTBAN_WRITERS_FD=""
    _nftban_writers_drop_intent "${NFTBAN_WRITERS_DIR:-/run/nftban-writers}"
}

# =============================================================================
# v1.238 root locks (SEC-WRITE-BOUNDARY-LEGACY-ROOT-LOCKS-IN-NFTBAN-OWNED-RUN-DIR)
# nft_operations.lock (the OUTER nft lock), session_whitelist.lock and maintenance.lock live in
# this root-only directory (build/fhs-spec.yaml /run/nftban-writers), not in /run/nftban, which
# the nftban service account owns (it could unlink and recreate a lock there, so two root
# holders would lock different inodes). Lock order is unchanged: nft_operations.lock (outer)
# before nft_writers.lock (inner).
# For ONE release (v1.238) every holder also takes the LEGACY path in /run/nftban, AFTER the
# canonical one, so a v1.237 process still running during the package upgrade stays excluded.
# The legacy file is never unlinked or replaced and a symlink there is not used. Known
# limitation until v1.239 removes the compatibility acquisition: the legacy directory stays
# owned by the service account, which can still swap that inode; the exclusion between v1.238
# processes comes from the canonical lock.
# =============================================================================

# nftban_root_lock_path <name> — canonical path of a root lock file.
nftban_root_lock_path() { printf '%s/%s' "${NFTBAN_WRITERS_DIR:-/run/nftban-writers}" "$1"; }

# nftban_legacy_lock_path <name> — v1.237 path of the same lock.
nftban_legacy_lock_path() { printf '%s/%s' "${NFTBAN_RUN_DIR:-/run/nftban}" "$1"; }

# nftban_root_lock_dir_ready — the canonical directory exists (tmpfiles creates it; created
# 0700 here only when absent, e.g. a test sandbox).
nftban_root_lock_dir_ready() {
    local dir="${NFTBAN_WRITERS_DIR:-/run/nftban-writers}"
    [[ -d "$dir" ]] || mkdir -m 0700 -- "$dir" 2>/dev/null || true
}

# shellcheck disable=SC2034  # NFTBAN_LEGACY_LOCK_FD is the result, read by the callers
# nftban_legacy_lock_take <name> <-n | -w SECONDS | -b> [-s]   (-b = block, like plain flock)
# Takes the compatibility lock with the SAME wait policy as the caller's canonical lock.
# Sets NFTBAN_LEGACY_LOCK_FD (empty when nothing was taken). rc 0 = held, or skipped because the
# legacy directory is absent (nothing older can hold it) or a symlink sits at the name (not
# followed); rc 1 = busy or cannot be opened (the caller must release its canonical lock and
# refuse, exactly as for a busy canonical lock).
nftban_legacy_lock_take() {
    local name="$1" mode="$2" secs="" shared="" path dir fd=""
    [[ "$mode" == "-w" ]] && { secs="$3"; shift; }
    [[ "${3:-}" == "-s" ]] && shared="-s"
    NFTBAN_LEGACY_LOCK_FD=""
    path="$(nftban_legacy_lock_path "$name")"
    dir="${path%/*}"
    [[ -d "$dir" ]] || return 0
    # Same file as the canonical lock (both directories point at one place, e.g. a sandbox):
    # it is already held through the canonical descriptor; a second flock would conflict with it.
    [[ "$path" == "$(nftban_root_lock_path "$name")" ]] && return 0
    if [[ -L "$path" ]]; then
        echo "nftban: $path is a symlink; compatibility lock not taken" >&2
        return 0
    fi
    { exec {fd}>>"$path"; } 2>/dev/null || return 1
    if [[ "$mode" == "-w" ]]; then
        flock $shared -w "$secs" "$fd" || { exec {fd}>&-; return 1; }
    elif [[ "$mode" == "-b" ]]; then
        flock $shared "$fd" || { exec {fd}>&-; return 1; }
    else
        flock $shared -n "$fd" || { exec {fd}>&-; return 1; }
    fi
    NFTBAN_LEGACY_LOCK_FD="$fd"
    return 0
}

# nftban_legacy_lock_drop <fd-or-empty> — release a compatibility lock (no-op when empty).
nftban_legacy_lock_drop() {
    [[ -n "${1:-}" ]] || return 0
    eval "exec ${1}>&-" 2>/dev/null || true
}

# Remove the intent only if it is still ours (a later waiter may have replaced it).
_nftban_writers_drop_intent() {
    local ipath="$1/nft_writers.intent" own
    own="pid=$BASHPID "
    [[ "$(head -c ${#own} "$ipath" 2>/dev/null)" == "$own" ]] && rm -f "$ipath"
    return 0
}

# nftban_writers_run <command> [args...] — run a command (an nft call, or a shell function
# that reads handles and then writes) inside ONE section; inside a section already held by this
# shell it joins it. Returns the command's rc, or 75 (busy, NOT run). Functions run this way are
# named *_held by convention (scripts/ci/check-nft-write-boundary.sh accepts raw writes in them);
# they must not call the daemon. Note: the command runs on the left of `||`, so errexit does not
# apply inside it — such functions handle their own errors.
nftban_writers_run() {
    if [[ -n "$_NFTBAN_WRITERS_FD" ]]; then
        "$@"
        return
    fi
    local rc=0
    nftban_writers_acquire || return 75
    "$@" || rc=$?
    nftban_writers_release
    return "$rc"
}

# nftban_nft_write <nft args...> — run ONE `nft` write inside the boundary. Returns nft's rc,
# or 75 (busy, NOT applied). stdin is passed through (`nft -f -`).
nftban_nft_write() {
    nftban_writers_run nft "$@"
}
