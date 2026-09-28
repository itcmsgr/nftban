#!/usr/bin/env bash
# =============================================================================
# NFTBan - Legacy rebuild_* backup migration (v1.229.3 0C)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_legacy_backup_migration"
# meta:type="core"
# meta:header="Legacy backup migration"
# meta:version="1.229.3"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:created_date="2026-08-16"
# meta:description="Bounded migration of the pre-0B rebuild_* recovery population that carries no transaction terminal discriminator. Classifies WITHOUT the canonical /run/nftban/nft_operations.lock and takes it ONLY to delete an already-decided, bounded batch after re-verifying that batch and the protected floor under it (zero candidates = zero lock acquisitions). A cheap population fingerprint plus an observation cache skips re-classifying an unchanged population. Preserves the newest 2 legacy generations, never backfills terminal state, and keeps everything it cannot positively classify."
# meta:inventory.files="/var/lib/nftban/backup,/var/lib/nftban/state/legacy-backup-migration.state"
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
#   Consequently there is no completion marker: idempotency is STRUCTURAL. After a
#   migration only the protected floor remains, so a rerun computes an empty
#   candidate set and deletes nothing.
#
# THE LOCK IS FOR THE MUTATION, NOT FOR THE LOOK (v1.234.0 R2).
#   MEASURED: taking the lock BEFORE the scan held it ~478-499 s per cycle on srv3
#   (12,344 unclassifiable dirs, 2 LEGACY = the floor, 0 candidates -- every cycle),
#   longer than the installer's whole ~180 s acquisition window, so security
#   updates ended REBUILD_REFUSED_BUSY. Now:
#     * classification runs WITHOUT the lock (it mutates nothing);
#     * ZERO candidates => ZERO lock acquisitions (a contract, not an optimisation);
#     * otherwise ONE lock window per invocation, for at most _LBM_MAX_MUTATION_BATCH
#       deletions, after RE-CLASSIFYING the batch AND the protected floor under the
#       lock. A rebuild writes mkdir -> snapshot_state -> tx_state while holding the
#       lock, so an unlocked scan can see an in-flight dir that is momentarily
#       LEGACY-shaped; counted among the newest it would shift the floor and nominate
#       an older, real LEGACY dir. Re-verifying the floor catches exactly that.
#     * the next maintenance cycle continues with the next batch -- never the same run.
#
# THE OBSERVATION CACHE IS NOT A COMPLETION MARKER.
#   legacy-backup-migration.state certifies ONLY that one fingerprinted population
#   was fully classified, without observation failure, and yielded the recorded
#   counts and no LEGACY candidate beyond the floor. It never says any dir is valid,
#   migrated, or safe to delete, nor anything about historical outcomes, nor
#   "done". A hit can only cause INACTION: every deletion needs a fresh scan plus
#   in-lock re-verification, so a stale or forged cache can delay a deletion but
#   never cause one.

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

# One lock window deletes at most this many dirs; the next maintenance cycle takes
# the next batch. Bounds the hold by a constant, never by population or candidates.
# FROZEN at 32 (owner, 2026-09-24): correctness / bounded lock ownership > drain speed.
#   Measured with 64, package-native, clean: DEB 2.5-2.7 s, RPM up to 4.14 s per window;
#   srv3 runs this path ~6x slower (projection ~25 s -- too close to the installer's
#   30 s per-attempt wait). Contract: lab window <= 5.0 s at 32 (measured on DEB + RPM),
#   production target <= 15 s. Never raise it to make a slow host pass.
_LBM_MAX_MUTATION_BATCH=32

# Observation cache (NOT a completion marker -- see the header).
_LBM_CACHE_SCHEMA="legacy-backup-migration-v1"
# ⛔ Bump on ANY change to _lbm_classify / _lbm_is_exact_namespace: a cached
#    observation made by a different classifier must never be a hit.
_LBM_CLASSIFIER_VERSION="1"
# Liveness backstop: force one lock-free full scan at least this often. A constant,
# deliberately not configurable (owner ruling 2026-09-23).
_LBM_CACHE_TTL_S=604800

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

# _lbm_ms_into VAR — wall clock in ms, via the EPOCHREALTIME builtin (no fork).
_lbm_ms_into() {
    local _t="${EPOCHREALTIME/[.,]/}"
    printf -v "$1" '%d' "$(( _t / 1000 ))"
}

# _lbm_cache_path — the observation cache (root:root 0600, FHS-declared).
_lbm_cache_path() { echo "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/legacy-backup-migration.state"; }

# _lbm_fingerprint — identity of the rebuild_* population: every name + the dir's own
# mtime, one find | sort | sha256sum. No per-directory fork and no file reads
# (measured on srv3: ~0.3 s and 5 execs for 12,352 dirs, vs ~480 s to classify).
# Detects dirs created or removed and entries created or removed inside a dir. It
# cannot see an in-place file edit; the only one any producer makes (appending
# tx_state) turns a dir INTO NEW_FORMAT, which can never create a candidate.
# Prints 64 hex; non-zero on any observation failure.
_lbm_fingerprint() {
    local _bk _out
    _bk=$(_lbm_backup_dir)
    [[ -d "$_bk" && -r "$_bk" && -x "$_bk" ]] || return 1
    _out=$( set -o pipefail
            find "$_bk" -mindepth 1 -maxdepth 1 -type d -name 'rebuild_*' -printf '%f %T@\n' 2>/dev/null \
              | LC_ALL=C sort | sha256sum ) || return 1
    _out="${_out%% *}"
    [[ "$_out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$_out"
}

# _lbm_scan — ONE lock-free classification pass over the exact backup namespace.
# Sets _LBM_S_* counters and _LBM_S_LEGACY (name-sorted ascending = oldest first).
# Returns non-zero on ANY observation failure -- an unreadable backup directory must
# never be mistaken for an empty population.
_lbm_scan() {
    local _bk _list _d _cls
    _bk=$(_lbm_backup_dir)
    _LBM_S_POP=0; _LBM_S_NEW=0; _LBM_S_UNK_NS=0; _LBM_S_UNK_UNREAD=0
    _LBM_S_UNK_MISSING=0; _LBM_S_UNK_GRAMMAR=0; _LBM_S_LEGACY=()
    [[ -d "$_bk" && -r "$_bk" && -x "$_bk" ]] || return 1
    # Command substitution + pipefail propagates find's status; `done < <(find)`
    # would not, and a failed observation would read as an empty candidate set.
    _list=$( set -o pipefail
             find "$_bk" -mindepth 1 -maxdepth 1 -type d -name 'rebuild_*' 2>/dev/null | LC_ALL=C sort ) || return 1
    while IFS= read -r _d; do
        [[ -n "$_d" ]] || continue
        _LBM_S_POP=$((_LBM_S_POP + 1))
        _cls=$(_lbm_classify "$_d")
        case "$_cls" in
            LEGACY)     _LBM_S_LEGACY+=("$_d") ;;
            NEW_FORMAT) _LBM_S_NEW=$((_LBM_S_NEW + 1)) ;;
            UNKNOWN)
                # Which branch of _lbm_classify said UNKNOWN, in its own order
                # (:namespace, :unreadable, :missing, else grammar). Pure bash, no fork.
                if ! [[ "${_d##*/}" =~ ^rebuild_[0-9]{8}_[0-9]{6}$ && "${_d%/*}" == "$_bk" ]]; then
                    _LBM_S_UNK_NS=$((_LBM_S_UNK_NS + 1))
                elif [[ -e "$_d/snapshot_state" && ! -r "$_d/snapshot_state" ]]; then
                    _LBM_S_UNK_UNREAD=$((_LBM_S_UNK_UNREAD + 1))
                elif [[ ! -e "$_d/snapshot_state" ]]; then
                    _LBM_S_UNK_MISSING=$((_LBM_S_UNK_MISSING + 1))
                else
                    _LBM_S_UNK_GRAMMAR=$((_LBM_S_UNK_GRAMMAR + 1))
                fi ;;
            *) return 1 ;;                     # unclassifiable => fail closed
        esac
    done <<< "$_list"
    return 0
}

# _lbm_candidates — ALL legacy directories eligible for disposal, oldest first
# (the newest _LBM_LEGACY_FLOOR are protected). One lock-free scan.
#
# ORDERING AUTHORITY is the directory NAME, not mtime: rebuild_YYYYMMDD_HHMMSS is
# fixed-width, so a lexicographic sort is chronological, total, and cannot be
# perturbed by a touch(1). Filesystem enumeration order never decides which
# generations survive.
#
# Emits nothing and returns non-zero on ANY observation failure.
_lbm_candidates() {
    _lbm_scan || return 1
    local _n=${#_LBM_S_LEGACY[@]} _i
    (( _n > _LBM_LEGACY_FLOOR )) || return 0   # <= floor: nothing is eligible
    for (( _i = 0; _i < _n - _LBM_LEGACY_FLOOR; _i++ )); do printf '%s\n' "${_LBM_S_LEGACY[$_i]}"; done
    return 0
}

# _lbm_cache_check FP — sets _LBM_CACHE (hit|miss|expired|invalid|absent) and, on a
# readable record, _LBM_C_* counts. hit ONLY for a valid, matching, unexpired,
# zero-candidate observation of this exact population by this classifier and floor.
_lbm_cache_check() {
    local _fp="$1" _p _k _v _now
    local -A _r=()
    _LBM_CACHE=absent
    _p=$(_lbm_cache_path)
    [[ -e "$_p" ]] || return 0
    _LBM_CACHE=invalid
    [[ -f "$_p" && -r "$_p" ]] || return 0
    while IFS='=' read -r _k _v; do
        [[ "$_k" =~ ^[A-Z_]+$ ]] || continue
        _r[$_k]="$_v"
    done < "$_p" || return 0
    [[ "${_r[SCHEMA]:-}" == "$_LBM_CACHE_SCHEMA" \
       && "${_r[CLASSIFIER_VERSION]:-}" == "$_LBM_CLASSIFIER_VERSION" \
       && "${_r[FLOOR]:-}" == "$_LBM_LEGACY_FLOOR" \
       && "${_r[BACKUP_DIR]:-}" == "$(_lbm_backup_dir)" \
       && "${_r[DELETION_CANDIDATES]:-}" == "0" \
       && "${_r[OBSERVED_AT_EPOCH]:-}" =~ ^[0-9]+$ ]] || return 0
    for _k in POPULATION LEGACY NEW_FORMAT UNKNOWN_NAMESPACE UNKNOWN_UNREADABLE UNKNOWN_MISSING_SNAPSHOT_STATE UNKNOWN_GRAMMAR; do
        [[ "${_r[$_k]:-}" =~ ^[0-9]+$ ]] || return 0
    done
    _LBM_C_POP=${_r[POPULATION]}; _LBM_C_LEGACY=${_r[LEGACY]}; _LBM_C_NEW=${_r[NEW_FORMAT]}
    _LBM_C_UNK_NS=${_r[UNKNOWN_NAMESPACE]}; _LBM_C_UNK_UNREAD=${_r[UNKNOWN_UNREADABLE]}
    _LBM_C_UNK_MISSING=${_r[UNKNOWN_MISSING_SNAPSHOT_STATE]}; _LBM_C_UNK_GRAMMAR=${_r[UNKNOWN_GRAMMAR]}
    _now=${EPOCHREALTIME%%[.,]*}
    # a timestamp from the future is not an observation -- treat it as invalid
    (( ${_r[OBSERVED_AT_EPOCH]} <= _now + 300 )) || return 0
    if [[ -z "$_fp" || "${_r[POPULATION_FINGERPRINT]:-}" != "sha256:$_fp" ]]; then _LBM_CACHE=miss; return 0; fi
    if (( _now - ${_r[OBSERVED_AT_EPOCH]} >= _LBM_CACHE_TTL_S )); then _LBM_CACHE=expired; return 0; fi
    _LBM_CACHE=hit
    return 0
}

# _lbm_cache_write FP SCAN_MS — record a completed, failure-free, zero-candidate
# observation. Full durability contract: fsync(temp) -> rename -> fsync(parent dir).
# 0 = durable; 1 = not written (the old record, if any, stays intact);
# 2 = atomically replaced but the directory fsync failed (atomic, NOT power-loss durable).
_lbm_cache_write() {
    local _fp="$1" _scan_ms="$2" _p _dir _tmp _now
    _p=$(_lbm_cache_path); _dir="${_p%/*}"
    [[ -d "$_dir" && -w "$_dir" ]] || return 1
    _tmp=$(mktemp "$_dir/.legacy-backup-migration.state.XXXXXX" 2>/dev/null) || return 1
    _now=${EPOCHREALTIME%%[.,]*}
    if ! {
        printf '# NFTBan legacy-backup-migration OBSERVATION CACHE -- machine-written, do not edit.\n'
        printf '# Certifies ONE observation: this fingerprinted rebuild_* population was fully\n'
        printf '# classified and yielded no LEGACY candidate beyond FLOOR. NOT a migration record.\n'
        printf 'SCHEMA=%s\n' "$_LBM_CACHE_SCHEMA"
        printf 'CLASSIFIER_VERSION=%s\n' "$_LBM_CLASSIFIER_VERSION"
        printf 'FLOOR=%s\n' "$_LBM_LEGACY_FLOOR"
        printf 'BACKUP_DIR=%s\n' "$(_lbm_backup_dir)"
        printf 'POPULATION_FINGERPRINT=sha256:%s\n' "$_fp"
        TZ=UTC printf 'OBSERVED_AT=%(%Y-%m-%dT%H:%M:%SZ)T\n' "$_now"
        printf 'OBSERVED_AT_EPOCH=%s\n' "$_now"
        printf 'POPULATION=%s\n' "$_LBM_S_POP"
        printf 'LEGACY=%s\n' "${#_LBM_S_LEGACY[@]}"
        printf 'NEW_FORMAT=%s\n' "$_LBM_S_NEW"
        printf 'UNKNOWN_NAMESPACE=%s\n' "$_LBM_S_UNK_NS"
        printf 'UNKNOWN_UNREADABLE=%s\n' "$_LBM_S_UNK_UNREAD"
        printf 'UNKNOWN_MISSING_SNAPSHOT_STATE=%s\n' "$_LBM_S_UNK_MISSING"
        printf 'UNKNOWN_GRAMMAR=%s\n' "$_LBM_S_UNK_GRAMMAR"
        printf 'DELETION_CANDIDATES=0\n'
        printf 'SCAN_MS=%s\n' "$_scan_ms"
    } > "$_tmp"; then rm -f -- "$_tmp"; return 1; fi
    chmod 0600 -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    sync -- "$_tmp" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    mv -f -- "$_tmp" "$_p" 2>/dev/null || { rm -f -- "$_tmp"; return 1; }
    sync -- "$_dir" 2>/dev/null || return 2
    return 0
}

# _lbm_emit VERDICT — the ONE result line, emitted on EVERY path (no silent no-op).
# The first four tokens keep their historical order; the rest are appended.
# Reads the caller's locals by dynamic scope.
_lbm_emit() {
    printf 'LBM_RESULT=%s removed=%d floor=%d rc=%d mode=%s cache=%s cache_write=%s population=%d legacy=%d new_format=%d unknown_namespace=%d unknown_unreadable=%d unknown_missing_state=%d unknown_grammar=%d candidates=%d batch=%d remaining=%d fastpath_ms=%d scan_ms=%d lock_acquisitions=%d lock_ms=%d\n' \
        "$1" "$_removed" "$_LBM_LEGACY_FLOOR" "$_rc" "$_mode" "$_cache" "$_cwrite" \
        "$_pop" "$_legacy" "$_new" "$_u_ns" "$_u_unread" "$_u_missing" "$_u_grammar" \
        "$_cand" "$_batch_n" "$(( _cand - _removed ))" "$_fp_ms" "$_scan_ms" "$_locks" "$_lock_ms"
}

# nftban_legacy_backup_migrate [--dry-run]
#
#   A  fingerprint + observation cache      (no lock)  hit => return; dry-run reports and continues
#   B  full classification                   (no lock)  any observation failure => refuse
#   C  0 candidates                          (no lock)  write the observation cache (not in dry-run)
#   D  candidates                            ONE bounded lock window: re-verify batch + floor,
#                                            delete the batch, release; never re-acquire this run
#
# Never "check whether a rebuild seems idle, sleep, check again": that is quiescence
# polling, not mutual exclusion. Any uncertainty keeps everything.
nftban_legacy_backup_migrate() {
    local _dry="${1:-}" _mode=apply
    [[ "$_dry" == "--dry-run" ]] && _mode=dry-run
    local _removed=0 _rc=0 _cache=off _cwrite=none _fp="" _fp_after=""
    local _pop=0 _legacy=0 _new=0 _u_ns=0 _u_unread=0 _u_missing=0 _u_grammar=0
    local _cand=0 _batch_n=0 _fp_ms=0 _scan_ms=0 _locks=0 _lock_ms=0 _t0=0 _t1=0
    local _bk; _bk=$(_lbm_backup_dir)
    [[ -d "$_bk" ]] || { _lbm_emit NO_BACKUP_DIR; return 0; }

    # --- A. fast path: cheap fingerprint vs the observation cache (no lock) ---
    _lbm_ms_into _t0
    if _fp=$(_lbm_fingerprint); then _lbm_cache_check "$_fp"; else _fp=""; _LBM_CACHE=unobservable; fi
    _cache=$_LBM_CACHE
    _lbm_ms_into _t1; _fp_ms=$(( _t1 - _t0 ))
    if [[ "$_cache" == hit ]]; then
        _pop=$_LBM_C_POP; _legacy=$_LBM_C_LEGACY; _new=$_LBM_C_NEW; _u_ns=$_LBM_C_UNK_NS
        _u_unread=$_LBM_C_UNK_UNREAD; _u_missing=$_LBM_C_UNK_MISSING; _u_grammar=$_LBM_C_UNK_GRAMMAR
        if [[ "$_mode" == apply ]]; then _lbm_emit OK; return 0; fi
    fi
    # dry-run answers "what would happen NOW": it reports the cache verdict and still classifies.
    [[ "$_mode" == dry-run ]] && _cache="would-$_cache"

    # --- B. full classification, WITHOUT the lock ---
    _lbm_ms_into _t0
    if ! _lbm_scan; then
        _lbm_ms_into _t1; _scan_ms=$(( _t1 - _t0 )); _rc=1
        _pop=0; _legacy=0; _new=0; _u_ns=0; _u_unread=0; _u_missing=0; _u_grammar=0
        _lbm_emit REFUSED_OBSERVATION_FAILED; return 1
    fi
    _lbm_ms_into _t1; _scan_ms=$(( _t1 - _t0 ))
    _pop=$_LBM_S_POP; _legacy=${#_LBM_S_LEGACY[@]}; _new=$_LBM_S_NEW; _u_ns=$_LBM_S_UNK_NS
    _u_unread=$_LBM_S_UNK_UNREAD; _u_missing=$_LBM_S_UNK_MISSING; _u_grammar=$_LBM_S_UNK_GRAMMAR
    (( _legacy > _LBM_LEGACY_FLOOR )) && _cand=$(( _legacy - _LBM_LEGACY_FLOOR ))
    _batch_n=$(( _cand < _LBM_MAX_MUTATION_BATCH ? _cand : _LBM_MAX_MUTATION_BATCH ))

    # --- C. zero candidates: ZERO lock acquisitions ---
    if (( _cand == 0 )); then
        if [[ "$_mode" == apply ]]; then
            # Cache only an observation of a STABLE population: if it changed while we
            # scanned, the counts would describe a different fingerprint.
            if [[ -n "$_fp" ]] && _fp_after=$(_lbm_fingerprint) && [[ "$_fp_after" == "$_fp" ]]; then
                _lbm_cache_write "$_fp" "$_scan_ms"
                case $? in 0) _cwrite=durable ;; 2) _cwrite=atomic-not-durable ;; *) _cwrite=failed ;; esac
            else
                _cwrite=skipped-unstable
            fi
        fi
        _lbm_emit OK; return 0
    fi

    # --- D. candidates: dry-run stops here (no lock, no deletion, no cache write) ---
    if [[ "$_mode" == dry-run ]]; then _lbm_emit OK; return 0; fi

    local _batch=() _floor=() _x _i _verify_ok=1 _bad=""
    for (( _i = 0; _i < _batch_n; _i++ )); do _batch+=("${_LBM_S_LEGACY[$_i]}"); done
    for (( _i = _legacy - _LBM_LEGACY_FLOOR; _i < _legacy; _i++ )); do _floor+=("${_LBM_S_LEGACY[$_i]}"); done

    mkdir -p "$(dirname "$_LBM_LOCK_PATH")" 2>/dev/null || true
    if ! exec 8>>"$_LBM_LOCK_PATH"; then
        _rc=1; _lbm_emit REFUSED_LOCK_OPEN; return 1
    fi
    if ! flock -w "$_LBM_LOCK_WAIT" 8; then
        # A participating rebuild (or a known Go consumer) holds it. Migration is
        # optional work; it never preempts an in-flight transaction.
        exec 8>&-; _rc=1; _lbm_emit REFUSED_LOCK_BUSY; return 1
    fi
    _locks=1; _lbm_ms_into _t0

    # Re-verify the batch AND the protected floor under the lock: the pre-lock
    # decision stands only if every one of them is still an exact-namespace LEGACY dir.
    for _x in "${_batch[@]}" "${_floor[@]}"; do
        if ! _lbm_is_exact_namespace "$_x" || [[ "$(_lbm_classify "$_x")" != "LEGACY" ]]; then
            _verify_ok=0; _bad+="${_x##*/},"
        fi
    done
    if (( _verify_ok == 0 )); then
        exec 8>&-; _lbm_ms_into _t1; _lock_ms=$(( _t1 - _t0 )); _rc=1
        echo "LBM_TOCTOU changed_under_lock=${_bad%,}"
        _lbm_emit ABORTED_TOCTOU; return 1
    fi
    for _x in "${_batch[@]}"; do
        if rm -rf -- "$_x" 2>/dev/null; then _removed=$((_removed + 1)); else _rc=1; fi
    done
    exec 8>&-
    _lbm_ms_into _t1; _lock_ms=$(( _t1 - _t0 ))
    # No cache write after a mutation: the next run certifies from pure observation.
    _lbm_emit OK
    return "$_rc"
}
