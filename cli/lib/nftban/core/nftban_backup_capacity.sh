#!/usr/bin/env bash
# =============================================================================
# NFTBan - Path-local storage safety authority (v1.229.3 P0-3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_backup_capacity"
# meta:type="core"
# meta:header="Path-local storage safety"
# meta:version="1.229.3"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:created_date="2026-08-16"
# meta:description="Path-local byte and entry/inode safety verdict for NFTBan persistent roots. Each root is evaluated against the filesystem that actually backs THAT path; roots sharing a device share one physical envelope and never double-count free capacity. Observation failure yields UNKNOWN, which can never authorize destructive action."
# meta:inventory.files="/var/lib/nftban,/var/log/nftban"
# meta:inventory.privileges="none"
# =============================================================================
#
# THIS IS A SAFETY AND REFUSAL AUTHORITY, NOT A RETENTION ENGINE.
#   It answers "can the policy's recovery generations safely fit here?" It never
#   decides how much history to keep -- that is lifecycle policy (P0-2B: min 1,
#   max 2). Available capacity never authorizes MORE history.
#
# PATH INDEPENDENCE (INV-I).
#   /var/log/nftban and /var/lib/nftban are NEVER assumed to share a filesystem,
#   capacity, inode pool, budget or lifecycle. The 2026-08-16 fleet sweep found
#   them on the same device on 11/11 hosts -- that is an OBSERVATION, not licence
#   to hardcode, and a separate /var/lib volume is a normal deployment.
#
# SHARED-DEVICE ACCOUNTING.
#   When two roots DO resolve to the same filesystem they share ONE physical
#   byte/inode envelope; their needs are summed rather than each independently
#   assuming the same free space.
#
# TWO DIMENSIONS, because bytes alone never bind for this class. The fleet sweep
# measured backup/ holding 100k-216k directory entries per production host while
# occupying only 22-483 MB: a byte-only budget stays green while NFTBan consumes
# the majority of a filesystem's used inodes (61.1% on monitor).
#
# NO MEAN-SIZE FORECASTING. Per-set size varied 26x across the fleet
# (2,971 -> 86,439 bytes), so `budget / mean_set_size` is not a safety bound.
# Callers evaluate ACTUAL candidate objects.

# _bcap_fs_facts <path> — device id, avail bytes, avail inodes for the filesystem
# that ACTUALLY backs <path> (device identity, never a path-prefix guess).
# Returns non-zero on any observation failure; prints nothing.
_bcap_fs_facts() {
    local _p="$1" _dev _b _i
    [[ -n "$_p" && -e "$_p" ]] || return 1
    _dev=$(stat -c %d "$_p" 2>/dev/null) || return 1
    [[ -n "$_dev" ]] || return 1
    # -B1 for byte-exact output; Avail is the non-root-available figure, matching
    # the Bavail convention used by internal/logretention/disk.go.
    _b=$(df -P -B1 "$_p" 2>/dev/null | awk 'NR==2{print $4}') || return 1
    _i=$(df -P -i  "$_p" 2>/dev/null | awk 'NR==2{print $4}') || return 1
    [[ "$_b" =~ ^[0-9]+$ && "$_i" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s %s\n' "$_dev" "$_b" "$_i"
}

# _bcap_same_device <a> <b> — 0 when both paths resolve to the same filesystem.
# Compared by device id, never by path prefix.
_bcap_same_device() {
    local _da _db
    _da=$(stat -c %d "$1" 2>/dev/null) || return 1
    _db=$(stat -c %d "$2" 2>/dev/null) || return 1
    [[ -n "$_da" && "$_da" == "$_db" ]]
}

# _bcap_object_cost <dir> — ACTUAL bytes and entry count of one object.
# No estimate, no mean, no extrapolation.
_bcap_object_cost() {
    local _d="$1" _b _e
    [[ -n "$_d" && -d "$_d" ]] || return 1
    _b=$(du -sb "$_d" 2>/dev/null | cut -f1) || return 1
    _e=$(find "$_d" 2>/dev/null | wc -l) || return 1
    [[ "$_b" =~ ^[0-9]+$ && "$_e" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$_b" "$_e"
}

# _bcap_verdict <path> <need_bytes> <need_entries> [peer_path]
#
#   FITS     the need fits within the safety margin of the backing filesystem
#   NO_FIT   it does not
#   UNKNOWN  the state could not be observed
#
# UNKNOWN is never FITS. An unreadable filesystem must not authorize retention
# decisions, and must never be read as "plenty of room".
#
# When <peer_path> shares the device, the peer's own margin is charged against the
# same envelope so the two roots cannot each spend the same free capacity.
_bcap_verdict() {
    local _p="$1" _nb="$2" _ne="$3" _peer="${4:-}"
    local _facts _avail_b _avail_i
    _facts=$(_bcap_fs_facts "$_p") || { echo "UNKNOWN"; return 0; }
    _avail_b=$(awk '{print $2}' <<<"$_facts")
    _avail_i=$(awk '{print $3}' <<<"$_facts")
    [[ "$_nb" =~ ^[0-9]+$ && "$_ne" =~ ^[0-9]+$ ]] || { echo "UNKNOWN"; return 0; }

    # Reserve headroom so a decision never consumes the last of either dimension.
    local _res_b=$(( _avail_b / 10 ))      # 10% byte headroom
    local _res_i=$(( _avail_i / 10 ))      # 10% inode headroom

    if [[ -n "$_peer" ]] && _bcap_same_device "$_p" "$_peer"; then
        # SHARED ENVELOPE: the peer root is backed by the same filesystem, so the
        # same free space must not be counted twice. Charge a second reservation.
        _res_b=$(( _res_b * 2 ))
        _res_i=$(( _res_i * 2 ))
    fi

    if (( _nb + _res_b > _avail_b )) || (( _ne + _res_i > _avail_i )); then
        echo "NO_FIT"; return 0
    fi
    echo "FITS"
}
