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
# meta:description="v1.236 (design V1236_STAGE2_DESIGN_DRAFT.md §3). The shell side of the inner write boundary /run/nftban/nft_writers.lock. nftband holds it SHARED for each kernel transaction; every nft write made outside the daemon holds it EXCLUSIVE, so it can never land between a firewall replacement's kernel read and its commit, nor inside a daemon transaction. One implementation for the replacement (_fw_atomic_load) and for every direct writer. Changes no shell options: safe to source from any script."
# meta:input="nft arguments"
# meta:output="nft output; rc of nft, or 75 when the boundary was busy (NOT applied)"
# meta:depends="bash,flock,nft"
# meta:inventory.files="/run/nftban/nft_writers.lock, /run/nftban/nft_writers.intent"
# meta:inventory.binaries="flock, nft"
# meta:inventory.env_vars="NFTBAN_RUN_DIR, NFTBAN_BOUNDARY_WAIT"
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
    local dir="${NFTBAN_RUN_DIR:-/run/nftban}" fd=""
    if [[ -n "$_NFTBAN_WRITERS_FD" ]]; then
        echo "nftban: write boundary already held by this shell (nested acquire refused)" >&2
        return 75
    fi
    mkdir -p "$dir" 2>/dev/null || true
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
    _nftban_writers_drop_intent "${NFTBAN_RUN_DIR:-/run/nftban}"
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
