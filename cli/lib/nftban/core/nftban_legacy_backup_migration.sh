#!/usr/bin/env bash
# =============================================================================
# NFTBan - Legacy rebuild_* backup migration (v1.229.3 0C)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_legacy_backup_migration"
# meta:type="core"
# meta:header="Legacy backup migration"
# meta:version="1.229.3"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:created_date="2026-08-16"
# meta:description="Bounded ONE-TIME migration of the pre-0B rebuild_* recovery population that carries no transaction terminal discriminator. Runs under the canonical /run/nftban/nft_operations.lock so a participating rebuild cannot execute its protected section concurrently. Preserves the newest 2 legacy generations, never backfills terminal state, and keeps everything it cannot positively classify."
# meta:inventory.files="/var/lib/nftban/backup"
# meta:inventory.privileges="root"
# =============================================================================
#
# WHY THIS IS NOT RETENTION.
#   0B made ACTIVE vs TERMINAL structurally observable, but only for rebuilds
#   created after it shipped. The pre-existing population -- ~100k-216k
#   directories per production host, created on the 15-minute maintenance cadence
#   -- carries no discriminator, so under 0B's fail-closed rule every one of them
#   is permanently non-prunable. This module exists solely to resolve that, once.
#
#   It is NOT the steady-state retention engine. Ordinary-history policy
#   (P0-2A/P0-2B) and the capacity/inode budget (P0-3) are separate lanes.
#
# THE GOVERNING DISTINCTION.
#
#     CURRENT QUIESCENCE  !=  HISTORICAL COMPLETION PROOF
#
#   Holding the canonical lock proves a present-tense fact: no participating
#   rebuild is executing its protected section right now. It proves NOTHING about
#   whether a given historical transaction completed. So this module is permitted
#   to dispose of legacy artifacts safely, but is NEVER permitted to write
#   TERMINAL_SUCCESS/TERMINAL_FAILURE onto them and claim their outcome is known.
#
#     SAFE ONE-TIME LEGACY DISPOSAL  !=  HISTORICAL TRANSACTION COMPLETION PROVEN
#
#   Consequently there is no completion marker file either: idempotency is
#   STRUCTURAL. After a migration only the protected floor remains, so a rerun
#   computes an empty candidate set and deletes nothing.

# Canonical exclusive lock (internal/nftlock/lock.go). Same file the shell rebuild
# takes since P0-J -- so acquiring it genuinely excludes a rebuild, rather than
# merely looking like it does.
_LBM_LOCK_PATH="${NFTBAN_RUN_DIR:-/run/nftban}/nft_operations.lock"
_LBM_LOCK_WAIT="${NFTBAN_TIMEOUT_NFT_LOCK:-30}"

# Conservative floor for the migration itself. Deliberately 2, not 1: this is a
# crossing from an unclassified population into the new lifecycle, and one extra
# fallback costs nothing against a population of this size. It is MIGRATION
# conservatism, not steady-state retention policy -- do not reuse it as one.
_LBM_LEGACY_FLOOR=2

# _lbm_backup_dir — the ONLY namespace this module may touch.
_lbm_backup_dir() { echo "${NFTBAN_DATA_DIR:-/var/lib/nftban}/backup"; }

# _lbm_is_exact_namespace — a candidate must be a directory named exactly
# rebuild_YYYYMMDD_HHMMSS directly beneath backup/. This deliberately excludes
# ruleset_*.nft (a separate operator restore surface), the duplicate
# {white,black}list_ipv*.txt artifacts, the undeclared backups/ tree, and any
# similarly-named path. No broad sweep of /var/lib/nftban is performed anywhere.
_lbm_is_exact_namespace() {
    local _path="$1" _base
    [[ -n "$_path" && -d "$_path" ]] || return 1
    _base=$(basename -- "$_path")
    [[ "$_base" =~ ^rebuild_[0-9]{8}_[0-9]{6}$ ]] || return 1
    [[ "$(dirname -- "$_path")" == "$(_lbm_backup_dir)" ]] || return 1
    return 0
}

# _lbm_classify — LEGACY | NEW_FORMAT | UNKNOWN
#
#   NEW_FORMAT  any tx_state= line is present, whatever its value. 0B owns these
#               and its fail-closed eligibility already governs them; a malformed
#               tx_state is therefore NEW_FORMAT and is KEPT, never "repaired".
#   LEGACY      snapshot_state is present and readable and has no tx_state line.
#               This is the pre-0B shape and the only migration subject.
#   UNKNOWN     unreadable snapshot_state, or a missing one. A missing state file
#               is structurally unexpected after v1.228.10 and could equally be a
#               half-created directory, so it is kept rather than guessed at.
#
#       ABSENT TERMINAL RECORD  !=  SAFE TO MARK TERMINAL
_lbm_classify() {
    local _dir="$1"
    # NOTE: split deliberately. `local a="$1" b="$a/x"` expands the whole command's
    # words before any assignment takes effect, so $a is unbound under `set -u`.
    local _state="$_dir/snapshot_state"
    _lbm_is_exact_namespace "$_dir" || { echo "UNKNOWN"; return 0; }
    if [[ -e "$_state" && ! -r "$_state" ]]; then echo "UNKNOWN"; return 0; fi
    if [[ ! -e "$_state" ]]; then echo "UNKNOWN"; return 0; fi
    if grep -q '^tx_state=' "$_state" 2>/dev/null; then echo "NEW_FORMAT"; return 0; fi

    # POSITIVE recognition of the pre-0B schema. The absence of the new field is
    # NOT evidence that this is a valid legacy object:
    #
    #     ABSENCE_OF_NEW_FIELD  !=  PROOF_OF_VALID_LEGACY_OBJECT
    #
    # A readable but malformed/truncated state file would otherwise fall through
    # to LEGACY and become deletable. The grammar below is derived from the pre-0B
    # producer (_rebuild_snapshot_full), which writes state / reason /
    # nftban_table / list_rc / json_rc / captured_at together in one block, with
    # state constrained to the A2 closed set. Two anchors from that block are
    # required; anything else is ambiguous and kept.
    local _st
    _st=$(sed -n 's/^state=//p' "$_state" 2>/dev/null | head -1) || { echo "UNKNOWN"; return 0; }
    case "$_st" in
        VALID|EMPTY_VERIFIED|FAILED) : ;;
        *) echo "UNKNOWN"; return 0 ;;
    esac
    grep -q '^captured_at=' "$_state" 2>/dev/null || { echo "UNKNOWN"; return 0; }

    echo "LEGACY"
}

# _lbm_candidates — legacy directories eligible for disposal, oldest first.
#
# ORDERING AUTHORITY is the directory NAME, not mtime: rebuild_YYYYMMDD_HHMMSS is
# fixed-width, so a lexicographic sort is chronological, total, and cannot be
# perturbed by a touch(1). Names are unique (one per second, and a same-second
# rebuild reuses the same directory), so there are no ties to resolve. Filesystem
# enumeration order never decides which generations survive.
#
# Emits nothing and returns non-zero on ANY observation failure -- an unreadable
# backup directory must not be mistaken for an empty candidate set.
_lbm_candidates() {
    local _bk; _bk=$(_lbm_backup_dir)
    [[ -d "$_bk" && -r "$_bk" && -x "$_bk" ]] || return 1

    local _all=() _legacy=() _d _cls
    while IFS= read -r _d; do _all+=("$_d"); done < <(
        find "$_bk" -mindepth 1 -maxdepth 1 -type d -name 'rebuild_*' 2>/dev/null | LC_ALL=C sort
    ) || return 1

    for _d in "${_all[@]}"; do
        _cls=$(_lbm_classify "$_d")
        case "$_cls" in
            LEGACY) _legacy+=("$_d") ;;
            NEW_FORMAT|UNKNOWN) : ;;          # KEEP — never a migration subject
            *) return 1 ;;                     # unclassifiable => fail closed
        esac
    done

    local _n=${#_legacy[@]}
    (( _n > _LBM_LEGACY_FLOOR )) || return 0   # <= floor: nothing is eligible
    # _legacy is name-sorted ascending (oldest first); protect the newest floor.
    local _eligible=$(( _n - _LBM_LEGACY_FLOOR )) _i
    for (( _i = 0; _i < _eligible; _i++ )); do printf '%s\n' "${_legacy[$_i]}"; done
    return 0
}

# nftban_legacy_backup_migrate — the bounded one-time migration.
#
# Sequence: acquire canonical exclusive lock -> observe -> classify -> protect
# floor -> bounded removal -> release. Never "check whether a rebuild seems idle,
# sleep, check again": that is quiescence polling, not mutual exclusion.
#
# Any uncertainty keeps everything:
#   lock failure · unreadable backup dir · classification ambiguity ·
#   candidate-set failure · namespace mismatch  =>  zero deletion.
nftban_legacy_backup_migrate() {
    local _dry="${1:-}"
    local _bk; _bk=$(_lbm_backup_dir)
    [[ -d "$_bk" ]] || { echo "LBM_RESULT=NO_BACKUP_DIR removed=0"; return 0; }

    mkdir -p "$(dirname "$_LBM_LOCK_PATH")" 2>/dev/null || true
    if ! exec 8>>"$_LBM_LOCK_PATH"; then
        echo "LBM_RESULT=REFUSED_LOCK_OPEN removed=0"; return 1
    fi
    if ! flock -w "$_LBM_LOCK_WAIT" 8; then
        # A participating rebuild (or a known Go consumer) holds it. Migration is
        # optional work; it never preempts an in-flight transaction.
        echo "LBM_RESULT=REFUSED_LOCK_BUSY removed=0"
        exec 8>&-; return 1
    fi

    local _cands=() _c _removed=0 _rc=0 _out _crc
    # Status propagation matters here. `mapfile -t x < <(f)` returns MAPFILE's exit
    # status, not f's -- so a failing observation would be silently swallowed and
    # read as an empty candidate set, which is precisely the "observation failure
    # interpreted as nothing to do" defect this module must not have. Command
    # substitution propagates the callee's status, so it is checked explicitly.
    _out=$(_lbm_candidates); _crc=$?
    if [[ $_crc -ne 0 ]]; then
        echo "LBM_RESULT=REFUSED_OBSERVATION_FAILED removed=0"
        exec 8>&-; return 1
    fi
    if [[ -n "$_out" ]]; then mapfile -t _cands <<< "$_out"; fi

    for _c in "${_cands[@]}"; do
        [[ -n "$_c" ]] || continue
        # Re-validate immediately before removal: the namespace check is the last
        # gate, so a path that drifted between enumeration and mutation is skipped
        # rather than removed.
        if ! _lbm_is_exact_namespace "$_c"; then _rc=1; continue; fi
        if [[ "$_dry" == "--dry-run" ]]; then _removed=$((_removed+1)); continue; fi
        if rm -rf -- "$_c" 2>/dev/null; then _removed=$((_removed+1)); else _rc=1; fi
    done

    exec 8>&-
    echo "LBM_RESULT=OK removed=$_removed floor=$_LBM_LEGACY_FLOOR rc=$_rc"
    return "$_rc"
}
